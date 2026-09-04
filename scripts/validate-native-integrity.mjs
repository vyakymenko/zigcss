import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const maximumArchiveBytes = 512 * 1024 * 1024
export const maximumManifestBytes = 64 * 1024
export const maximumPackageManifestBytes = 256 * 1024
export const maximumPathBytes = 4096
export const maximumSourceDateEpoch = 0xffff_ffff

const utf8Decoder = new TextDecoder('utf-8', { fatal: true })
const manifestKeys = Object.freeze(['schemaVersion', 'package', 'version', 'sourceDateEpoch', 'archives'])
const archiveKeys = Object.freeze(['target', 'filename', 'sha256'])

function fail(message) {
  throw new Error(`native integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function canonicalRoot(root) {
  if (typeof root !== 'string' || root.length === 0 || Buffer.byteLength(root) > maximumPathBytes) {
    fail('repository root must be a bounded nonempty path')
  }
  let stat
  try {
    stat = fs.lstatSync(root)
  } catch (error) {
    fail(`repository root is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('repository root must be a regular non-symlink directory')
  }
  return fs.realpathSync(root)
}

function validateInputPath(filename, label) {
  if (typeof filename !== 'string' || filename.length === 0) fail(`${label} must be a nonempty path`)
  if (Buffer.byteLength(filename) > maximumPathBytes) fail(`${label} exceeds ${maximumPathBytes} bytes`)
  if (filename.includes('\0') || filename.includes('\r') || filename.includes('\n')) {
    fail(`${label} contains an unsupported control byte`)
  }
  if (/^(?:\\\\|\/\/)/.test(filename)) fail(`${label} must not be a network path`)
  if (/[\\\/]$/.test(filename)) fail(`${label} must name a file`)
  return path.resolve(filename)
}

function openRegularFile(filename, label, maximumBytes) {
  let pathStat
  try {
    pathStat = fs.lstatSync(filename, { bigint: true })
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    fail(`${label} must be a regular non-symlink file`)
  }
  if (pathStat.size === 0n) fail(`${label} must not be empty`)
  if (pathStat.size > BigInt(maximumBytes)) fail(`${label} exceeds ${maximumBytes} bytes`)

  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  const closeOnExec = fs.constants.O_CLOEXEC ?? 0
  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | noFollow | closeOnExec)
  } catch (error) {
    fail(`${label} could not be opened safely: ${error.message}`)
  }

  try {
    const before = fs.fstatSync(descriptor, { bigint: true })
    let openedPathStat
    try {
      openedPathStat = fs.lstatSync(filename, { bigint: true })
    } catch {
      fail(`${label} changed while it was being opened`)
    }
    if (!before.isFile()
      || !openedPathStat.isFile()
      || openedPathStat.isSymbolicLink()
      || before.dev !== pathStat.dev
      || before.ino !== pathStat.ino
      || before.size !== pathStat.size
      || openedPathStat.dev !== before.dev
      || openedPathStat.ino !== before.ino
      || openedPathStat.size !== before.size) {
      fail(`${label} changed while it was being opened`)
    }
    return { descriptor, before }
  } catch (error) {
    fs.closeSync(descriptor)
    throw error
  }
}

function validateStableFile(filename, descriptor, before, bytesRead, label) {
  const after = fs.fstatSync(descriptor, { bigint: true })
  let finalPathStat
  try {
    finalPathStat = fs.lstatSync(filename, { bigint: true })
  } catch {
    fail(`${label} changed while it was being read`)
  }
  if (!after.isFile()
    || !finalPathStat.isFile()
    || finalPathStat.isSymbolicLink()
    || after.dev !== before.dev
    || after.ino !== before.ino
    || after.size !== before.size
    || after.mtimeNs !== before.mtimeNs
    || after.ctimeNs !== before.ctimeNs
    || finalPathStat.dev !== after.dev
    || finalPathStat.ino !== after.ino
    || finalPathStat.size !== after.size
    || BigInt(bytesRead) !== before.size) {
    fail(`${label} changed while it was being read`)
  }
}

function readRegularText(root, relativePath, label, maximumBytes) {
  const filename = path.join(root, relativePath)
  const { descriptor, before } = openRegularFile(filename, label, maximumBytes)
  try {
    const bytes = fs.readFileSync(descriptor)
    validateStableFile(filename, descriptor, before, bytes.length, label)
    try {
      return utf8Decoder.decode(bytes)
    } catch (error) {
      fail(`${label} is not valid UTF-8: ${error.message}`)
    }
  } finally {
    fs.closeSync(descriptor)
  }
}

function parseJson(source, label) {
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function exactObjectKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value)
  if (!same(actual, expected)) {
    fail(`${label} keys must be exactly ${expected.join(', ')}`)
  }
}

export function validateNativeIntegritySources(sources) {
  if (sources === null || typeof sources !== 'object' || Array.isArray(sources)) {
    fail('source set must be an object')
  }
  exactObjectKeys(sources, ['manifest', 'packageManifest', 'version'], 'source set')
  for (const [name, source] of Object.entries(sources)) {
    if (typeof source !== 'string') fail(`${name} source must be text`)
  }

  if (!sources.version.endsWith('\n') || sources.version.trim() + '\n' !== sources.version) {
    fail('VERSION must contain one canonical version and a final newline')
  }
  const version = parseReleaseVersion(sources.version.trim(), 'native integrity VERSION').value
  const packageManifest = parseJson(sources.packageManifest, 'package.json')
  if (packageManifest === null || typeof packageManifest !== 'object' || Array.isArray(packageManifest)) {
    fail('package.json must contain an object')
  }
  if (packageManifest.name !== 'zigcss') fail('package.json package name must be zigcss')
  if (packageManifest.version !== version) fail(`package.json version must be ${version}`)

  const manifest = parseJson(sources.manifest, 'native-integrity.json')
  exactObjectKeys(manifest, manifestKeys, 'native-integrity.json')
  if (JSON.stringify(manifest, null, 2) + '\n' !== sources.manifest) {
    fail('native-integrity.json must use the canonical JSON representation')
  }
  if (manifest.schemaVersion !== 1) fail('schemaVersion must be exactly 1')
  if (manifest.package !== packageManifest.name) fail('manifest package must match package.json')
  if (manifest.version !== version) fail(`manifest version must be ${version}`)
  if (!Number.isSafeInteger(manifest.sourceDateEpoch)
    || manifest.sourceDateEpoch < 0
    || manifest.sourceDateEpoch > maximumSourceDateEpoch) {
    fail(`sourceDateEpoch must be an integer from 0 through ${maximumSourceDateEpoch}`)
  }
  if (!Array.isArray(manifest.archives) || manifest.archives.length !== releaseTargets.length) {
    fail(`archive inventory must contain exactly ${releaseTargets.length} entries`)
  }

  const digests = new Set()
  for (const [index, target] of releaseTargets.entries()) {
    const archive = manifest.archives[index]
    exactObjectKeys(archive, archiveKeys, `archive entry ${index}`)
    if (archive.target !== target.target) {
      fail(`archive entry ${index} target must be ${target.target}`)
    }
    const expectedFilename = releaseAssetsFor(version, target.target).archive
    if (archive.filename !== expectedFilename) {
      fail(`archive entry ${index} filename must be ${expectedFilename}`)
    }
    if (typeof archive.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(archive.sha256)) {
      fail(`archive entry ${index} sha256 must contain 64 lowercase hexadecimal characters`)
    }
    if (digests.has(archive.sha256)) fail('archive SHA-256 digests must be unique')
    digests.add(archive.sha256)
  }

  return Object.freeze({
    schemaVersion: manifest.schemaVersion,
    package: manifest.package,
    version: manifest.version,
    sourceDateEpoch: manifest.sourceDateEpoch,
    archives: Object.freeze(manifest.archives.map(archive => Object.freeze({ ...archive }))),
  })
}

export function validateNativeIntegrity(root = repositoryRoot) {
  const canonical = canonicalRoot(root)
  return validateNativeIntegritySources({
    manifest: readRegularText(canonical, 'native-integrity.json', 'native-integrity.json', maximumManifestBytes),
    packageManifest: readRegularText(canonical, 'package.json', 'package.json', maximumPackageManifestBytes),
    version: readRegularText(canonical, 'VERSION', 'VERSION', 1024),
  })
}

function hashRegularArchive(filename) {
  const { descriptor, before } = openRegularFile(filename, 'native archive', maximumArchiveBytes)
  const hash = crypto.createHash('sha256')
  const buffer = Buffer.allocUnsafe(64 * 1024)
  let total = 0
  try {
    while (true) {
      const length = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (length === 0) break
      total += length
      if (total > maximumArchiveBytes) fail(`native archive exceeds ${maximumArchiveBytes} bytes`)
      hash.update(buffer.subarray(0, length))
    }
    validateStableFile(filename, descriptor, before, total, 'native archive')
  } finally {
    fs.closeSync(descriptor)
  }
  return { digest: hash.digest('hex'), bytes: total }
}

export function verifyNativeArchive(options) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    fail('archive verification options must be an object')
  }
  const keys = Object.keys(options).sort()
  const allowed = options.root === undefined
    ? ['archive', 'target', 'version']
    : ['archive', 'root', 'target', 'version']
  if (!same(keys, allowed)) fail('archive verification options use a closed contract')
  const manifest = validateNativeIntegrity(options.root ?? repositoryRoot)
  const version = parseReleaseVersion(options.version, 'native archive version').value
  if (version !== manifest.version) fail(`native archive version must be ${manifest.version}`)
  const record = manifest.archives.find(archive => archive.target === options.target)
  if (record === undefined) fail(`unsupported native archive target ${JSON.stringify(options.target)}`)

  const filename = validateInputPath(options.archive, 'native archive')
  if (path.basename(filename) !== record.filename) {
    fail(`native archive filename must be ${record.filename}`)
  }
  const { digest, bytes } = hashRegularArchive(filename)
  const actual = Buffer.from(digest, 'hex')
  const expected = Buffer.from(record.sha256, 'hex')
  if (actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) {
    fail(`native archive SHA-256 does not match the committed digest for ${record.target}`)
  }
  return Object.freeze({
    target: record.target,
    version: manifest.version,
    filename: record.filename,
    sha256: digest,
    bytes,
  })
}

export function parseNativeIntegrityArguments(args) {
  if (!Array.isArray(args)) fail('command arguments must be an array')
  if (same(args, ['--check'])) return Object.freeze({ mode: 'check' })
  if (args.length === 3 && args[0] === '--print-source-date-epoch' && args[1] === '--version') {
    if (typeof args[2] !== 'string' || args[2].length === 0 || args[2].startsWith('--')) {
      fail('--version requires one value')
    }
    return Object.freeze({ mode: 'print-source-date-epoch', version: args[2] })
  }
  if (args.length !== 6) {
    fail('expected --check, --print-source-date-epoch with --version, or exactly --archive, --target, and --version')
  }
  const allowed = new Set(['--archive', '--target', '--version'])
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index]
    const value = args[index + 1]
    if (!allowed.has(option)) fail(`unsupported option ${JSON.stringify(option)}`)
    if (values.has(option)) fail(`duplicate option ${option}`)
    if (typeof value !== 'string' || value.length === 0 || value.startsWith('--')) {
      fail(`${option} requires one value`)
    }
    values.set(option, value)
  }
  if (!same([...values.keys()].sort(), [...allowed].sort())) fail('required archive verification options are missing')
  return Object.freeze({
    mode: 'verify-archive',
    archive: values.get('--archive'),
    target: values.get('--target'),
    version: values.get('--version'),
  })
}

function main() {
  const command = parseNativeIntegrityArguments(process.argv.slice(2))
  if (command.mode === 'check') {
    const manifest = validateNativeIntegrity()
    process.stdout.write(
      `Native integrity verified: ${manifest.archives.length} archives for ${manifest.package}@${manifest.version}.\n`,
    )
    return
  }
  if (command.mode === 'print-source-date-epoch') {
    const manifest = validateNativeIntegrity()
    if (command.version !== manifest.version) fail(`requested version must be ${manifest.version}`)
    process.stdout.write(`${manifest.sourceDateEpoch}\n`)
    return
  }
  const result = verifyNativeArchive({
    archive: command.archive,
    target: command.target,
    version: command.version,
  })
  process.stdout.write(`Verified ${result.filename}: ${result.sha256}.\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
