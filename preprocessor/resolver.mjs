import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const allowedKinds = new Set(['import', 'use', 'forward', 'reference'])
const defaultLimits = Object.freeze({
  maxFileBytes: 10 * 1024 * 1024,
  maxTotalBytes: 40 * 1024 * 1024,
  maxFiles: 4096,
  maxReads: 8192,
  maxDepth: 64,
})
const hardLimits = Object.freeze({
  maxFileBytes: 10 * 1024 * 1024,
  maxTotalBytes: 40 * 1024 * 1024,
  maxFiles: 4096,
  maxReads: 8192,
  maxDepth: 128,
})

export class ResolverError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'ResolverError'
    this.code = code
  }
}

function fail(code, message) {
  throw new ResolverError(code, message)
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function containsPath(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

function filesystemCode(error, fallback) {
  if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return 'RESOLVER_MISSING'
  if (error?.code === 'EACCES' || error?.code === 'EPERM') return 'RESOLVER_UNREADABLE'
  if (error?.code === 'ELOOP') return 'RESOLVER_SYMLINK'
  return fallback
}

function normalizeLimits(value) {
  if (value === undefined) return { ...defaultLimits }
  if (!isPlainObject(value)) fail('RESOLVER_LIMIT_INVALID', 'limits must be an object')
  const keys = Object.keys(value)
  for (const key of keys) {
    if (!Object.hasOwn(defaultLimits, key)) {
      fail('RESOLVER_LIMIT_INVALID', 'limits contain an unknown field')
    }
  }
  const limits = { ...defaultLimits, ...value }
  for (const [key, maximum] of Object.entries(hardLimits)) {
    if (!Number.isSafeInteger(limits[key]) || limits[key] < 1 || limits[key] > maximum) {
      fail('RESOLVER_LIMIT_INVALID', `${key} is outside its allowed range`)
    }
  }
  return limits
}

function normalizeRoots(roots) {
  if (!Array.isArray(roots) || roots.length === 0 || roots.length > 64) {
    fail('RESOLVER_ROOT_INVALID', 'roots must be a nonempty bounded array')
  }
  const normalized = []
  const identities = new Set()
  for (const root of roots) {
    if (
      typeof root !== 'string' ||
      !path.isAbsolute(root) ||
      root.length === 0 ||
      Buffer.byteLength(root) > 4096 ||
      /[\u0000\r\n]/.test(root)
    ) {
      fail('RESOLVER_ROOT_INVALID', 'each root must be a bounded absolute path')
    }
    const input = path.resolve(root)
    let stat
    let canonical
    try {
      stat = fs.lstatSync(input)
      canonical = fs.realpathSync(input)
    } catch {
      fail('RESOLVER_ROOT_INVALID', 'resolver root is unavailable')
    }
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      fail('RESOLVER_ROOT_INVALID', 'resolver root must be a regular non-symlink directory')
    }
    const identity = process.platform === 'win32' ? canonical.toLowerCase() : canonical
    if (identities.has(identity)) fail('RESOLVER_ROOT_INVALID', 'resolver roots must be unique')
    identities.add(identity)
    normalized.push(Object.freeze({ input, canonical }))
  }
  normalized.sort((left, right) => Buffer.from(left.canonical).compare(Buffer.from(right.canonical)))
  return Object.freeze(normalized)
}

function parseFileUrl(value, schemeCode = 'RESOLVER_SCHEME', invalidCode = 'RESOLVER_URL_INVALID') {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > 8192) {
    fail(invalidCode, 'dependency URL must be a bounded string')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail(invalidCode, 'dependency URL is invalid')
  }
  if (parsed.protocol !== 'file:') fail(schemeCode, 'only local file URLs are admitted')
  if (parsed.search !== '' || parsed.hash !== '' || parsed.username !== '' || parsed.password !== '') {
    fail(invalidCode, 'file URL cannot contain credentials, query, or fragment')
  }
  let filename
  try {
    filename = fileURLToPath(parsed)
  } catch {
    fail(invalidCode, 'file URL cannot be converted to a local path')
  }
  if (!path.isAbsolute(filename) || /[\u0000\r\n]/.test(filename)) {
    fail(invalidCode, 'file URL must identify a bounded absolute local path')
  }
  return path.resolve(filename)
}

function lexicalRoot(roots, candidate) {
  for (const root of roots) {
    if (containsPath(root.input, candidate)) return { root, base: root.input }
    if (containsPath(root.canonical, candidate)) return { root, base: root.canonical }
  }
  fail('RESOLVER_PATH_ESCAPE', 'dependency path escapes every explicit root')
}

async function inspectPathComponents(base, candidate) {
  const relative = path.relative(base, candidate)
  const components = relative === '' ? [] : relative.split(path.sep)
  let current = base
  for (let index = 0; index < components.length; index += 1) {
    current = path.join(current, components[index])
    let stat
    try {
      stat = await fs.promises.lstat(current)
    } catch (error) {
      fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency path cannot be inspected')
    }
    if (stat.isSymbolicLink()) fail('RESOLVER_SYMLINK', 'dependency path contains a symlink')
    if (index < components.length - 1 && !stat.isDirectory()) {
      fail('RESOLVER_PARENT_NOT_DIRECTORY', 'dependency parent is not a directory')
    }
    if (index === components.length - 1 && !stat.isFile()) {
      if (stat.isDirectory()) fail('RESOLVER_DIRECTORY', 'dependency is a directory')
      fail('RESOLVER_NOT_REGULAR', 'dependency is not a regular file')
    }
  }
}

function inspectPathComponentsSync(base, candidate) {
  const relative = path.relative(base, candidate)
  const components = relative === '' ? [] : relative.split(path.sep)
  let current = base
  for (let index = 0; index < components.length; index += 1) {
    current = path.join(current, components[index])
    let stat
    try {
      stat = fs.lstatSync(current)
    } catch (error) {
      fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency path cannot be inspected')
    }
    if (stat.isSymbolicLink()) fail('RESOLVER_SYMLINK', 'dependency path contains a symlink')
    if (index < components.length - 1 && !stat.isDirectory()) {
      fail('RESOLVER_PARENT_NOT_DIRECTORY', 'dependency parent is not a directory')
    }
    if (index === components.length - 1 && !stat.isFile()) {
      if (stat.isDirectory()) fail('RESOLVER_DIRECTORY', 'dependency is a directory')
      fail('RESOLVER_NOT_REGULAR', 'dependency is not a regular file')
    }
  }
}

async function canonicalCandidate(roots, candidateUrl) {
  const candidate = parseFileUrl(candidateUrl)
  const lexical = lexicalRoot(roots, candidate)
  await inspectPathComponents(lexical.base, candidate)
  let canonical
  try {
    canonical = await fs.promises.realpath(candidate)
  } catch (error) {
    fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency path cannot be resolved')
  }
  if (!roots.some(root => containsPath(root.canonical, canonical))) {
    fail('RESOLVER_PATH_ESCAPE', 'canonical dependency path escapes every explicit root')
  }
  return {
    filename: canonical,
    url: pathToFileURL(canonical).href,
  }
}

function canonicalCandidateSync(roots, candidateUrl) {
  const candidate = parseFileUrl(candidateUrl)
  const lexical = lexicalRoot(roots, candidate)
  inspectPathComponentsSync(lexical.base, candidate)
  let canonical
  try {
    canonical = fs.realpathSync(candidate)
  } catch (error) {
    fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency path cannot be resolved')
  }
  if (!roots.some(root => containsPath(root.canonical, canonical))) {
    fail('RESOLVER_PATH_ESCAPE', 'canonical dependency path escapes every explicit root')
  }
  return {
    filename: canonical,
    url: pathToFileURL(canonical).href,
  }
}

function canonicalAncestry(roots, ancestry, limits) {
  if (!Array.isArray(ancestry)) {
    fail('RESOLVER_ANCESTRY_INVALID', 'ancestry must be an array of canonical file URLs')
  }
  if (ancestry.length > hardLimits.maxDepth) {
    fail('RESOLVER_DEPTH_LIMIT', 'dependency depth exceeds its limit')
  }
  const seen = new Set()
  const canonical = ancestry.map(value => {
    const filename = parseFileUrl(
      value,
      'RESOLVER_ANCESTRY_INVALID',
      'RESOLVER_ANCESTRY_INVALID',
    )
    const canonical = pathToFileURL(filename).href
    if (
      canonical !== value ||
      !roots.some(root => containsPath(root.canonical, filename))
    ) {
      fail('RESOLVER_ANCESTRY_INVALID', 'ancestry entries must be canonical file URLs')
    }
    if (seen.has(canonical)) fail('RESOLVER_CYCLE', 'dependency ancestry already contains a cycle')
    seen.add(canonical)
    return canonical
  })
  if (canonical.length + 1 > limits.maxDepth) {
    fail('RESOLVER_DEPTH_LIMIT', 'dependency depth exceeds its limit')
  }
  return canonical
}

function sameIdentity(left, right) {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs
  )
}

async function stableRead(filename, limits, consumedBytes) {
  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  let handle
  try {
    handle = await fs.promises.open(filename, fs.constants.O_RDONLY | noFollow)
  } catch (error) {
    fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency cannot be opened')
  }
  try {
    let before
    try {
      before = await handle.stat({ bigint: true })
    } catch {
      fail('RESOLVER_UNREADABLE', 'dependency identity cannot be read')
    }
    if (!before.isFile()) fail('RESOLVER_NOT_REGULAR', 'dependency is not a regular file')
    if (before.size > BigInt(limits.maxFileBytes)) {
      fail('RESOLVER_FILE_LIMIT', 'dependency exceeds its per-file byte limit')
    }
    if (BigInt(consumedBytes) + before.size > BigInt(limits.maxTotalBytes)) {
      fail('RESOLVER_TOTAL_LIMIT', 'dependencies exceed their cumulative byte limit')
    }

    const size = Number(before.size)
    const contents = Buffer.allocUnsafe(size)
    let offset = 0
    while (offset < size) {
      let read
      try {
        read = await handle.read(contents, offset, size - offset, offset)
      } catch {
        fail('RESOLVER_UNREADABLE', 'dependency cannot be read')
      }
      if (read.bytesRead === 0) fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
      offset += read.bytesRead
    }
    const probe = Buffer.allocUnsafe(1)
    let extra
    try {
      extra = await handle.read(probe, 0, 1, size)
    } catch {
      fail('RESOLVER_UNREADABLE', 'dependency cannot be read')
    }
    if (extra.bytesRead !== 0) {
      if (size >= limits.maxFileBytes) {
        fail('RESOLVER_FILE_LIMIT', 'dependency exceeds its per-file byte limit')
      }
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }

    let after
    let pathIdentity
    try {
      after = await handle.stat({ bigint: true })
      pathIdentity = await fs.promises.lstat(filename, { bigint: true })
    } catch {
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }
    if (!after.isFile() || !pathIdentity.isFile() || !sameIdentity(before, after) || !sameIdentity(after, pathIdentity)) {
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }
    return contents
  } finally {
    await handle.close().catch(() => {})
  }
}

function stableReadSync(filename, limits, consumedBytes) {
  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | noFollow)
  } catch (error) {
    fail(filesystemCode(error, 'RESOLVER_UNREADABLE'), 'dependency cannot be opened')
  }
  try {
    let before
    try {
      before = fs.fstatSync(descriptor, { bigint: true })
    } catch {
      fail('RESOLVER_UNREADABLE', 'dependency identity cannot be read')
    }
    if (!before.isFile()) fail('RESOLVER_NOT_REGULAR', 'dependency is not a regular file')
    if (before.size > BigInt(limits.maxFileBytes)) {
      fail('RESOLVER_FILE_LIMIT', 'dependency exceeds its per-file byte limit')
    }
    if (BigInt(consumedBytes) + before.size > BigInt(limits.maxTotalBytes)) {
      fail('RESOLVER_TOTAL_LIMIT', 'dependencies exceed their cumulative byte limit')
    }

    const size = Number(before.size)
    const contents = Buffer.allocUnsafe(size)
    let offset = 0
    while (offset < size) {
      let bytesRead
      try {
        bytesRead = fs.readSync(descriptor, contents, offset, size - offset, offset)
      } catch {
        fail('RESOLVER_UNREADABLE', 'dependency cannot be read')
      }
      if (bytesRead === 0) fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
      offset += bytesRead
    }
    const probe = Buffer.allocUnsafe(1)
    let extra
    try {
      extra = fs.readSync(descriptor, probe, 0, 1, size)
    } catch {
      fail('RESOLVER_UNREADABLE', 'dependency cannot be read')
    }
    if (extra !== 0) {
      if (size >= limits.maxFileBytes) {
        fail('RESOLVER_FILE_LIMIT', 'dependency exceeds its per-file byte limit')
      }
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }

    let after
    let pathIdentity
    try {
      after = fs.fstatSync(descriptor, { bigint: true })
      pathIdentity = fs.lstatSync(filename, { bigint: true })
    } catch {
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }
    if (
      !after.isFile() ||
      !pathIdentity.isFile() ||
      !sameIdentity(before, after) ||
      !sameIdentity(after, pathIdentity)
    ) {
      fail('RESOLVER_FILE_CHANGED', 'dependency changed while loading')
    }
    return contents
  } finally {
    try {
      fs.closeSync(descriptor)
    } catch {}
  }
}

class ResolutionSession {
  constructor(roots, limits) {
    this.roots = roots
    this.limits = limits
    this.closed = false
    this.reads = 0
    this.bytes = 0
    this.dependencyList = []
    this.dependencyUrls = new Set()
    this.loadTail = Promise.resolve()
    this.pendingLoads = 0
  }

  async load(candidateUrl, options = {}) {
    const { kind, lineage } = this.prepareLoad(options)
    this.pendingLoads += 1
    const operation = this.loadTail.then(() => this.loadSerial(candidateUrl, kind, lineage))
    this.loadTail = operation.then(() => undefined, () => undefined)
    try {
      return await operation
    } finally {
      this.pendingLoads -= 1
    }
  }

  loadSync(candidateUrl, options = {}) {
    const { kind, lineage } = this.prepareLoad(options)
    if (this.pendingLoads !== 0) {
      fail('RESOLVER_SESSION_BUSY', 'synchronous dependency reads require an idle session')
    }
    return this.loadSerialSync(candidateUrl, kind, lineage)
  }

  prepareLoad(options) {
    if (this.closed) fail('RESOLVER_SESSION_CLOSED', 'resolver session is closed')
    if (
      !isPlainObject(options) ||
      Object.keys(options).sort().join(',') !== 'ancestry,kind'
    ) {
      fail('RESOLVER_LOAD_OPTIONS_INVALID', 'load options require exactly kind and ancestry')
    }
    const { kind, ancestry } = options
    if (!allowedKinds.has(kind)) fail('RESOLVER_KIND_INVALID', 'dependency kind is invalid')
    return {
      kind,
      lineage: canonicalAncestry(this.roots, ancestry, this.limits),
    }
  }

  async loadSerial(candidateUrl, kind, lineage) {
    const candidate = await canonicalCandidate(this.roots, candidateUrl)
    if (lineage.includes(candidate.url)) fail('RESOLVER_CYCLE', 'dependency ancestry contains a cycle')
    if (this.reads >= this.limits.maxReads) {
      fail('RESOLVER_READ_COUNT_LIMIT', 'dependency read count exceeds its limit')
    }
    const isNew = !this.dependencyUrls.has(candidate.url)
    if (isNew && this.dependencyList.length >= this.limits.maxFiles) {
      fail('RESOLVER_FILE_COUNT_LIMIT', 'unique dependency count exceeds its limit')
    }
    this.reads += 1
    const contents = await stableRead(candidate.filename, this.limits, this.bytes)
    this.bytes += contents.length
    if (isNew) {
      this.dependencyUrls.add(candidate.url)
      this.dependencyList.push(Object.freeze({ url: candidate.url, kind }))
    }
    return Object.freeze({ url: candidate.url, contents })
  }

  loadSerialSync(candidateUrl, kind, lineage) {
    const candidate = canonicalCandidateSync(this.roots, candidateUrl)
    if (lineage.includes(candidate.url)) fail('RESOLVER_CYCLE', 'dependency ancestry contains a cycle')
    if (this.reads >= this.limits.maxReads) {
      fail('RESOLVER_READ_COUNT_LIMIT', 'dependency read count exceeds its limit')
    }
    const isNew = !this.dependencyUrls.has(candidate.url)
    if (isNew && this.dependencyList.length >= this.limits.maxFiles) {
      fail('RESOLVER_FILE_COUNT_LIMIT', 'unique dependency count exceeds its limit')
    }
    this.reads += 1
    const contents = stableReadSync(candidate.filename, this.limits, this.bytes)
    this.bytes += contents.length
    if (isNew) {
      this.dependencyUrls.add(candidate.url)
      this.dependencyList.push(Object.freeze({ url: candidate.url, kind }))
    }
    return Object.freeze({ url: candidate.url, contents })
  }

  dependencies() {
    return this.dependencyList.map(dependency => ({ ...dependency }))
  }

  stats() {
    return {
      reads: this.reads,
      files: this.dependencyList.length,
      bytes: this.bytes,
    }
  }

  close() {
    this.closed = true
  }
}

export function createConfinedResolver(options = {}) {
  if (
    !isPlainObject(options) ||
    Object.keys(options).some(key => key !== 'roots' && key !== 'limits')
  ) {
    fail('RESOLVER_OPTIONS_INVALID', 'resolver options may contain only roots and limits')
  }
  const { roots, limits } = options
  const normalizedRoots = normalizeRoots(roots)
  const normalizedLimits = Object.freeze(normalizeLimits(limits))
  return Object.freeze({
    roots: Object.freeze(normalizedRoots.map(root => root.canonical)),
    limits: normalizedLimits,
    createSession() {
      return new ResolutionSession(normalizedRoots, normalizedLimits)
    },
  })
}
