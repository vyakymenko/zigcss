import { createHash } from 'node:crypto'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createConfinedResolver } from '../resolver.mjs'

export const STYLUS_IMPORT_SENTINEL = 'ZIGCSS_STYLUS_IMPORT_FAILURE'

const require = createRequire(import.meta.url)
const stylusRequire = createRequire(require.resolve('stylus/package.json'))
const { globIterateSync, hasMagic } = stylusRequire('glob')
const absentCodes = new Set([
  'RESOLVER_MISSING',
  'RESOLVER_DIRECTORY',
  'RESOLVER_PARENT_NOT_DIRECTORY',
])
const utf8 = new TextDecoder('utf-8', { fatal: true })
const MAX_GLOB_MATCHES = 4096

function containsPath(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

export function stylusPathIdentity(value, platform = process.platform) {
  if (typeof value !== 'string') return null
  return platform === 'win32' ? value.toLowerCase() : value
}

function uniquePaths(values) {
  const seen = new Set()
  const output = []
  for (const value of values) {
    if (value === null) continue
    const normalized = path.resolve(value)
    const key = stylusPathIdentity(normalized)
    if (seen.has(key)) continue
    seen.add(key)
    output.push(normalized)
  }
  return output
}

function resolverFailure(error) {
  if (error?.code === 'RESOLVER_CYCLE') {
    return ['STYLUS_IMPORT_CYCLE', 'Stylus dependency resolution detected an import cycle']
  }
  if (error?.code === 'RESOLVER_DEPTH_LIMIT') {
    return ['STYLUS_IMPORT_DEPTH_LIMIT', 'Stylus dependency resolution exceeded its depth limit']
  }
  if (
    error?.code === 'RESOLVER_FILE_LIMIT' ||
    error?.code === 'RESOLVER_TOTAL_LIMIT' ||
    error?.code === 'RESOLVER_FILE_COUNT_LIMIT' ||
    error?.code === 'RESOLVER_READ_COUNT_LIMIT'
  ) {
    return ['STYLUS_IMPORT_LIMIT', 'Stylus dependency resolution exceeded a resource limit']
  }
  if (
    error?.code === 'RESOLVER_PATH_ESCAPE' ||
    error?.code === 'RESOLVER_SYMLINK' ||
    error?.code === 'RESOLVER_SCHEME' ||
    error?.code === 'RESOLVER_URL_INVALID' ||
    error?.code === 'RESOLVER_ANCESTRY_INVALID'
  ) {
    return ['STYLUS_IMPORT_POLICY', 'Stylus dependency resolution crossed the allowed file boundary']
  }
  if (
    error?.code === 'RESOLVER_UNREADABLE' ||
    error?.code === 'RESOLVER_NOT_REGULAR' ||
    error?.code === 'RESOLVER_FILE_CHANGED'
  ) {
    return ['STYLUS_IMPORT_IO', 'A confined Stylus dependency could not be read safely']
  }
  return ['STYLUS_IMPORT_FAILURE', 'Stylus dependency resolution failed']
}

function validSpecifier(value) {
  return (
    typeof value === 'string' &&
    value.length !== 0 &&
    Buffer.byteLength(value, 'utf8') <= 8192 &&
    !/[\u0000\r\n]/.test(value) &&
    !/[?#]/.test(value) &&
    !/%2f|%5c|%00/i.test(value) &&
    !/^[\\/]{2}/.test(value)
  )
}

function lexicalDirectory(rootRecords, candidate) {
  for (const root of rootRecords) {
    if (containsPath(root.input, candidate)) return { root, base: root.input }
    if (containsPath(root.canonical, candidate)) return { root, base: root.canonical }
  }
  return null
}

function inspectDirectory(rootRecords, candidate) {
  const normalized = path.resolve(candidate)
  const lexical = lexicalDirectory(rootRecords, normalized)
  if (lexical === null) {
    return { failure: ['STYLUS_IMPORT_POLICY', 'Stylus dependency resolution crossed the allowed file boundary'] }
  }
  const relative = path.relative(lexical.base, normalized)
  const components = relative === '' ? [] : relative.split(path.sep)
  let current = lexical.base
  for (const component of components) {
    current = path.join(current, component)
    let stat
    try {
      stat = fs.lstatSync(current)
    } catch (error) {
      if (error?.code === 'ENOENT' || error?.code === 'ENOTDIR') return { missing: true }
      if (error?.code === 'EACCES' || error?.code === 'EPERM') {
        return { failure: ['STYLUS_IMPORT_IO', 'A confined Stylus dependency could not be read safely'] }
      }
      return { failure: ['STYLUS_IMPORT_FAILURE', 'Stylus dependency resolution failed'] }
    }
    if (stat.isSymbolicLink()) {
      return { failure: ['STYLUS_IMPORT_POLICY', 'Stylus dependency resolution crossed the allowed file boundary'] }
    }
    if (!stat.isDirectory()) return { missing: true }
  }
  let canonical
  try {
    canonical = fs.realpathSync.native(normalized)
  } catch {
    return { failure: ['STYLUS_IMPORT_IO', 'A confined Stylus dependency could not be read safely'] }
  }
  if (!rootRecords.some(root => containsPath(root.canonical, canonical))) {
    return { failure: ['STYLUS_IMPORT_POLICY', 'Stylus dependency resolution crossed the allowed file boundary'] }
  }
  return { directory: canonical }
}

function parsePackage(contents) {
  let value
  try {
    value = JSON.parse(utf8.decode(contents))
  } catch {
    return null
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null
  if (value.main === undefined || value.main === null || value.main === '') return { main: null }
  if (
    typeof value.main !== 'string' ||
    value.main.length === 0 ||
    Buffer.byteLength(value.main, 'utf8') > 4096 ||
    /[\u0000\r\n?#]/.test(value.main) ||
    /%2f|%5c|%00/i.test(value.main)
  ) {
    return null
  }
  return { main: value.main }
}

export function createStylusImportAuthority({
  roots,
  source,
  sourceUrl,
  entryFilename,
  virtualDirectory,
  virtualSourceUrl,
  signal,
}) {
  let failure = null
  const inputRoots = roots.map(root => path.resolve(root))
  const resolver = roots.length === 0
    ? null
    : createConfinedResolver({ roots, limits: { maxDepth: 32 } })
  const session = resolver?.createSession() ?? null
  const rootRecords = inputRoots.map(input => ({
    input,
    canonical: fs.realpathSync.native(input),
  }))
  const canonicalRoots = rootRecords.map(root => root.canonical)
  const byVirtualFilename = new Map()
  const byActualUrl = new Map()
  const mapSources = new Map()
  const entryMapSource = path.relative(virtualDirectory, entryFilename).split(path.sep).join('/')
  let entryDirectory = null
  let entryActualUrl = null

  const entryRecord = Object.freeze({
    actualUrl: null,
    diagnosticUrl: sourceUrl,
    source,
    sourceUrl: sourceUrl ?? virtualSourceUrl,
    virtualFilename: entryFilename,
  })
  byVirtualFilename.set(stylusPathIdentity(entryFilename), entryRecord)
  mapSources.set(entryMapSource, entryRecord)

  if (sourceUrl !== null) {
    const filename = fileURLToPath(sourceUrl)
    for (const root of rootRecords) {
      if (containsPath(root.input, filename)) {
        const actualFilename = path.resolve(
          root.canonical,
          path.relative(root.input, filename),
        )
        entryDirectory = path.dirname(actualFilename)
        entryActualUrl = pathToFileURL(actualFilename).href
        break
      }
      if (containsPath(root.canonical, filename)) {
        entryDirectory = path.dirname(filename)
        entryActualUrl = pathToFileURL(filename).href
        break
      }
    }
  }

  function setFailure(code, message) {
    if (failure === null) failure = Object.freeze({ code, message })
  }

  function abort(code, message) {
    setFailure(code, message)
    throw new Error(STYLUS_IMPORT_SENTINEL)
  }

  function abortResolver(error) {
    const [code, message] = resolverFailure(error)
    abort(code, message)
  }

  function checkCancellation() {
    if (signal?.aborted === true) abort('STYLUS_CANCELLED', 'Stylus compilation was cancelled')
  }

  function contextFor(virtualFilename) {
    const current = byVirtualFilename.get(stylusPathIdentity(virtualFilename))
    if (current === undefined) {
      abort('STYLUS_IMPORT_IDENTITY', 'Stylus returned an unknown dependency identity')
    }
    const currentDirectory = current.actualUrl === null
      ? entryDirectory
      : path.dirname(fileURLToPath(current.actualUrl))
    return uniquePaths([currentDirectory, ...[...canonicalRoots].reverse()])
  }

  function registerLoaded(loaded) {
    const existing = byActualUrl.get(loaded.url)
    if (existing !== undefined) return existing
    let decoded
    try {
      decoded = utf8.decode(loaded.contents)
    } catch {
      abort('STYLUS_IMPORT_ENCODING', 'A confined Stylus dependency is not valid UTF-8')
    }
    const hash = createHash('sha256').update(loaded.url).digest('hex')
    const virtualFilename = path.join(virtualDirectory, 'dependencies', `${hash}.styl`)
    const sourceUrl = loaded.url
    const record = Object.freeze({
      actualUrl: loaded.url,
      diagnosticUrl: sourceUrl,
      source: decoded,
      sourceUrl,
      virtualFilename,
    })
    const key = stylusPathIdentity(virtualFilename)
    const collision = byVirtualFilename.get(key)
    if (collision !== undefined && collision.actualUrl !== loaded.url) {
      abort('STYLUS_IMPORT_IDENTITY', 'Stylus dependency identity collided')
    }
    byVirtualFilename.set(key, record)
    byActualUrl.set(loaded.url, record)
    const mapSource = path.relative(virtualDirectory, virtualFilename).split(path.sep).join('/')
    mapSources.set(mapSource, record)
    return record
  }

  function loadCandidate(filename, ancestry, kind) {
    if (session === null) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus local imports require an explicit confined load root')
    }
    checkCancellation()
    let loaded
    try {
      loaded = session.loadSync(pathToFileURL(filename).href, { ancestry, kind })
    } catch (error) {
      if (absentCodes.has(error?.code)) return null
      abortResolver(error)
    }
    return registerLoaded(loaded)
  }

  function loadAssetCandidate(filename, ancestry) {
    checkCancellation()
    let loaded
    try {
      loaded = session.loadSync(pathToFileURL(filename).href, {
        ancestry,
        kind: 'reference',
      })
    } catch (error) {
      if (absentCodes.has(error?.code)) return null
      abortResolver(error)
    }
    return loaded
  }

  function findConcrete(pattern, bases, ancestry, kind) {
    if (path.isAbsolute(pattern)) return loadCandidate(path.resolve(pattern), ancestry, kind)
    for (const base of bases) {
      const loaded = loadCandidate(path.resolve(base, pattern), ancestry, kind)
      if (loaded !== null) return loaded
    }
    return null
  }

  function findGlob(pattern, bases, ancestry, kind) {
    if (pattern.split(/[\\/]/).includes('..')) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus import globs cannot traverse parent directories')
    }
    const candidates = path.isAbsolute(pattern)
      ? [path.resolve(pattern)]
      : bases.map(base => path.resolve(base, pattern))
    for (const candidate of candidates) {
      const parsed = path.parse(candidate)
      const components = path.relative(parsed.root, candidate).split(path.sep)
      let staticDirectory = parsed.root
      for (const component of components) {
        if (hasMagic(component, { windowsPathsNoEscape: true })) break
        staticDirectory = path.join(staticDirectory, component)
      }
      const inspected = inspectDirectory(rootRecords, staticDirectory)
      if (inspected.failure !== undefined) abort(...inspected.failure)
      if (inspected.missing) continue
      checkCancellation()
      const matches = []
      try {
        for (const filename of globIterateSync(candidate, {
          absolute: true,
          cwd: inspected.directory,
          follow: false,
          maxDepth: 32,
          nodir: true,
          posix: true,
          windowsPathsNoEscape: true,
        })) {
          matches.push(filename)
          if (matches.length > MAX_GLOB_MATCHES) {
            abort('STYLUS_IMPORT_LIMIT', 'Stylus dependency resolution exceeded a resource limit')
          }
        }
      } catch {
        if (failure !== null) throw new Error(STYLUS_IMPORT_SENTINEL)
        abort('STYLUS_IMPORT_FAILURE', 'Stylus dependency glob resolution failed')
      }
      if (matches.length === 0) continue
      matches.sort()
      const loaded = matches.map(filename => loadCandidate(filename, ancestry, kind))
      if (loaded.some(value => value === null)) {
        abort('STYLUS_IMPORT_IO', 'A confined Stylus dependency changed during glob resolution')
      }
      return loaded
    }
    return null
  }

  function find(pattern, bases, ancestry, kind) {
    return hasMagic(pattern, { windowsPathsNoEscape: true })
      ? findGlob(pattern, bases, ancestry, kind)
      : (() => {
          const loaded = findConcrete(pattern, bases, ancestry, kind)
          return loaded === null ? null : [loaded]
        })()
  }

  function packageLookup(name, bases, ancestry, kind) {
    if (name.includes('node_modules')) return null
    for (const packageName of [name, `${name}.styl`]) {
      const packageDirectory = path.join('node_modules', packageName)
      const packageRecord = findConcrete(
        path.join(packageDirectory, 'package.json'),
        bases,
        ancestry,
        kind,
      )
      if (packageRecord === null) {
        if (!/\.styl$/i.test(packageName)) continue
        const indexed = find(
          path.join(packageDirectory, 'index.styl'),
          bases,
          ancestry,
          kind,
        )
        if (indexed !== null) return indexed
        return find(
          path.join(
            packageDirectory,
            `${path.basename(packageDirectory).replace(/\.styl$/i, '')}.styl`,
          ),
          bases,
          ancestry,
          kind,
        )
      }
      const metadata = parsePackage(Buffer.from(packageRecord.source, 'utf8'))
      if (metadata === null) {
        abort('STYLUS_IMPORT_PACKAGE', 'A confined Stylus package has invalid metadata')
      }
      if (metadata.main !== null) {
        return find(
          path.join(packageDirectory, metadata.main),
          bases,
          ancestry,
          kind,
        )
      }
      const indexed = find(
        path.join(packageDirectory, 'index.styl'),
        bases,
        ancestry,
        kind,
      )
      if (indexed !== null) return indexed
      return find(
        path.join(
          packageDirectory,
          `${path.basename(packageDirectory).replace(/\.styl$/i, '')}.styl`,
        ),
        bases,
        ancestry,
        kind,
      )
    }
    return null
  }

  function resolve(
    specifier,
    currentVirtualFilename,
    { ancestry = [], kind = 'import', literal = false } = {},
  ) {
    if (!validSpecifier(specifier)) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus dependency resolution received an invalid path')
    }
    if (!path.isAbsolute(specifier) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier)) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus dependency resolution permits only confined local files')
    }
    if (session === null) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus local imports require an explicit confined load root')
    }
    const bases = contextFor(currentVirtualFilename)
    const lineage = entryActualUrl === null ? [...ancestry] : [entryActualUrl, ...ancestry]
    const directName = literal || /\.styl$/i.test(specifier)
      ? specifier
      : `${specifier}.styl`
    let found = find(directName, bases, lineage, kind)
    if (found === null) {
      found = find(
        path.join(specifier, 'index.styl'),
        bases,
        lineage,
        kind,
      )
    }
    if (found === null) {
      found = find(
        path.join(
          specifier,
          `${path.basename(specifier).replace(/\.styl$/i, '')}.styl`,
        ),
        bases,
        lineage,
        kind,
      )
    }
    if (found === null) {
      found = packageLookup(specifier, bases, lineage, kind)
    }
    if (found === null) {
      abort('STYLUS_IMPORT_MISSING', 'Stylus could not locate an imported stylesheet')
    }
    return found
  }

  function loadAsset(
    specifier,
    currentVirtualFilename,
    { ancestry = [], optional = false } = {},
  ) {
    if (
      !validSpecifier(specifier) ||
      hasMagic(specifier, { windowsPathsNoEscape: true }) ||
      (!path.isAbsolute(specifier) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier))
    ) {
      abort('STYLUS_IMPORT_POLICY', 'Stylus dependency resolution received an invalid asset path')
    }
    if (session === null) {
      if (optional) return null
      abort('STYLUS_IMPORT_POLICY', 'Stylus local assets require an explicit confined load root')
    }
    const bases = contextFor(currentVirtualFilename)
    const lineage = entryActualUrl === null ? [...ancestry] : [entryActualUrl, ...ancestry]
    if (path.isAbsolute(specifier)) {
      const loaded = loadAssetCandidate(path.resolve(specifier), lineage)
      if (loaded !== null) return loaded
    } else {
      for (const base of bases) {
        const loaded = loadAssetCandidate(path.resolve(base, specifier), lineage)
        if (loaded !== null) return loaded
      }
    }
    if (optional) return null
    abort('STYLUS_ASSET_MISSING', 'Stylus could not locate a referenced asset')
  }

  function sourceUrlForVirtual(filename) {
    return byVirtualFilename.get(stylusPathIdentity(filename))?.diagnosticUrl
  }

  function sourceMapRecord(sourceName) {
    if (
      typeof sourceName !== 'string' ||
      sourceName.length === 0 ||
      path.isAbsolute(sourceName) ||
      sourceName.includes('\\')
    ) {
      return null
    }
    const normalized = path.posix.normalize(sourceName)
    if (normalized === '..' || normalized.startsWith('../')) return null
    return mapSources.get(normalized) ?? null
  }

  return Object.freeze({
    close() {
      session?.close()
    },
    dependencies() {
      return session?.dependencies() ?? []
    },
    get failure() {
      return failure
    },
    loadAsset,
    resolve,
    sourceMapRecord,
    sourceUrlForVirtual,
  })
}
