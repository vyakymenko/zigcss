import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'
import { gzipSync, gunzipSync } from 'node:zlib'
import {
  maximumArchiveBytes,
  maximumBinaryBytes,
  maximumPathBytes,
  maximumSourceDateEpoch,
} from './create-release-archive.mjs'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { validateNativeIntegritySources } from './validate-native-integrity.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'
import { assertArtifactMatchesTarget } from './verify-artifact-target.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const outputRelativePath = 'native-integrity.json'
export const maximumManifestBytes = 64 * 1024

const maximumPackageManifestBytes = 256 * 1024
const maximumVersionBytes = 1024
const tarBlockBytes = 512
const normalizedExecutableMode = 0o100755
const zipStoredMethod = 0
const zipUtf8Flag = 0x0800
const utf8Decoder = new TextDecoder('utf-8', { fatal: true })

function fail(message) {
  throw new Error(`native integrity generation: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function equalBytes(left, right) {
  return left.length === right.length && crypto.timingSafeEqual(left, right)
}

function canonicalRoot(root) {
  if (typeof root !== 'string' || root.length === 0 || !path.isAbsolute(root)) {
    fail('repository root must be an absolute path')
  }
  if (Buffer.byteLength(root) > maximumPathBytes || /[\0\r\n]/u.test(root)) {
    fail('repository root is invalid or oversized')
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

function archivePath(value) {
  if (typeof value !== 'string' || value.length === 0 || !path.isAbsolute(value)) {
    fail('every archive path must be absolute')
  }
  if (Buffer.byteLength(value) > maximumPathBytes || /[\0\r\n]/u.test(value)) {
    fail('archive path is invalid or oversized')
  }
  if (/^(?:\\\\|\/\/)/u.test(value) || /[\\/]$/u.test(value)) {
    fail('archive path must name a local file')
  }
  return path.normalize(value)
}

function parseSourceDateEpoch(value) {
  let epoch
  if (typeof value === 'number') {
    epoch = value
  } else if (typeof value === 'string' && /^(?:0|[1-9]\d*)$/u.test(value)) {
    epoch = Number(value)
  } else {
    fail('sourceDateEpoch must be a canonical unsigned decimal integer')
  }
  if (!Number.isSafeInteger(epoch) || epoch < 0 || epoch > maximumSourceDateEpoch) {
    fail(`sourceDateEpoch must be between 0 and ${maximumSourceDateEpoch}`)
  }
  return epoch
}

function readStableRegularFile(filename, label, maximumBytes) {
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
    const opened = fs.lstatSync(filename, { bigint: true })
    if (!before.isFile()
      || !opened.isFile()
      || opened.isSymbolicLink()
      || before.dev !== pathStat.dev
      || before.ino !== pathStat.ino
      || before.size !== pathStat.size
      || opened.dev !== before.dev
      || opened.ino !== before.ino
      || opened.size !== before.size) {
      fail(`${label} changed while it was being opened`)
    }
    const bytes = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor, { bigint: true })
    const finalPath = fs.lstatSync(filename, { bigint: true })
    if (!after.isFile()
      || !finalPath.isFile()
      || finalPath.isSymbolicLink()
      || after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs
      || after.ctimeNs !== before.ctimeNs
      || finalPath.dev !== after.dev
      || finalPath.ino !== after.ino
      || finalPath.size !== after.size
      || BigInt(bytes.length) !== before.size) {
      fail(`${label} changed while it was being read`)
    }
    return Object.freeze({ bytes, stat: after })
  } finally {
    fs.closeSync(descriptor)
  }
}

function readUtf8File(root, relativePath, label, maximumBytes) {
  const candidate = path.resolve(root, relativePath)
  const relative = path.relative(root, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the repository`)
  }
  const { bytes } = readStableRegularFile(candidate, label, maximumBytes)
  try {
    return utf8Decoder.decode(bytes)
  } catch (error) {
    fail(`${label} is not valid UTF-8: ${error.message}`)
  }
}

function writeTarOctal(header, offset, width, value) {
  const octal = value.toString(8)
  if (octal.length > width - 1) fail('tar metadata exceeds the normalized octal field')
  header.write(`${octal.padStart(width - 1, '0')}\0`, offset, width, 'ascii')
}

function canonicalTarBytes(binary, sourceDateEpoch) {
  const header = Buffer.alloc(tarBlockBytes)
  header.write('zigcss', 0, 100, 'ascii')
  writeTarOctal(header, 100, 8, 0o755)
  writeTarOctal(header, 108, 8, 0)
  writeTarOctal(header, 116, 8, 0)
  writeTarOctal(header, 124, 12, binary.length)
  writeTarOctal(header, 136, 12, sourceDateEpoch)
  header.fill(0x20, 148, 156)
  header[156] = 0x30
  header.write('ustar\0', 257, 6, 'ascii')
  header.write('00', 263, 2, 'ascii')
  writeTarOctal(header, 329, 8, 0)
  writeTarOctal(header, 337, 8, 0)
  const checksum = header.reduce((sum, byte) => sum + byte, 0)
  const checksumText = checksum.toString(8)
  if (checksumText.length > 6) fail('tar header checksum exceeds its normalized field')
  header.write(`${checksumText.padStart(6, '0')}\0 `, 148, 8, 'ascii')

  const paddedBinaryBytes = Math.ceil(binary.length / tarBlockBytes) * tarBlockBytes
  const tar = Buffer.alloc(tarBlockBytes + paddedBinaryBytes + (2 * tarBlockBytes))
  header.copy(tar, 0)
  binary.copy(tar, tarBlockBytes)
  return tar
}

function canonicalTarGzip(binary, sourceDateEpoch) {
  const archive = gzipSync(canonicalTarBytes(binary, sourceDateEpoch), { level: 9, mtime: 0 })
  if (archive.length < 18 || archive[3] !== 0) fail('canonical gzip encoder returned invalid metadata')
  archive.writeUInt32LE(0, 4)
  archive[9] = 0xff
  return archive
}

const crc32Table = (() => {
  const table = new Uint32Array(256)
  for (let index = 0; index < table.length; index += 1) {
    let value = index
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 1 ? (0xedb8_8320 ^ (value >>> 1)) : (value >>> 1)
    }
    table[index] = value >>> 0
  }
  return table
})()

function crc32(bytes) {
  let value = 0xffff_ffff
  for (const byte of bytes) value = crc32Table[(value ^ byte) & 0xff] ^ (value >>> 8)
  return (value ^ 0xffff_ffff) >>> 0
}

function zipTimestamp(sourceDateEpoch) {
  const minimumDosEpoch = Date.UTC(1980, 0, 1) / 1000
  const date = new Date(Math.max(sourceDateEpoch, minimumDosEpoch) * 1000)
  return {
    time: (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | Math.floor(date.getUTCSeconds() / 2),
    day: ((date.getUTCFullYear() - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate(),
  }
}

function zipExtraFields(sourceDateEpoch) {
  const timestamp = Buffer.alloc(9)
  timestamp.writeUInt16LE(0x5455, 0)
  timestamp.writeUInt16LE(5, 2)
  timestamp[4] = 1
  timestamp.writeUInt32LE(sourceDateEpoch, 5)
  return Buffer.concat([timestamp, Buffer.from([0x75, 0x78, 0x05, 0x00, 0x01, 0x01, 0x00, 0x01, 0x00])])
}

function canonicalZip(binary, sourceDateEpoch) {
  const name = Buffer.from('zigcss.exe', 'utf8')
  const extra = zipExtraFields(sourceDateEpoch)
  const checksum = crc32(binary)
  const timestamp = zipTimestamp(sourceDateEpoch)

  const localHeader = Buffer.alloc(30)
  localHeader.writeUInt32LE(0x0403_4b50, 0)
  localHeader.writeUInt16LE(20, 4)
  localHeader.writeUInt16LE(zipUtf8Flag, 6)
  localHeader.writeUInt16LE(zipStoredMethod, 8)
  localHeader.writeUInt16LE(timestamp.time, 10)
  localHeader.writeUInt16LE(timestamp.day, 12)
  localHeader.writeUInt32LE(checksum, 14)
  localHeader.writeUInt32LE(binary.length, 18)
  localHeader.writeUInt32LE(binary.length, 22)
  localHeader.writeUInt16LE(name.length, 26)
  localHeader.writeUInt16LE(extra.length, 28)
  const local = Buffer.concat([localHeader, name, extra, binary])

  const centralHeader = Buffer.alloc(46)
  centralHeader.writeUInt32LE(0x0201_4b50, 0)
  centralHeader.writeUInt16LE(0x0314, 4)
  centralHeader.writeUInt16LE(20, 6)
  centralHeader.writeUInt16LE(zipUtf8Flag, 8)
  centralHeader.writeUInt16LE(zipStoredMethod, 10)
  centralHeader.writeUInt16LE(timestamp.time, 12)
  centralHeader.writeUInt16LE(timestamp.day, 14)
  centralHeader.writeUInt32LE(checksum, 16)
  centralHeader.writeUInt32LE(binary.length, 20)
  centralHeader.writeUInt32LE(binary.length, 24)
  centralHeader.writeUInt16LE(name.length, 28)
  centralHeader.writeUInt16LE(extra.length, 30)
  centralHeader.writeUInt16LE(0, 32)
  centralHeader.writeUInt16LE(0, 34)
  centralHeader.writeUInt16LE(0, 36)
  centralHeader.writeUInt32LE((normalizedExecutableMode << 16) >>> 0, 38)
  centralHeader.writeUInt32LE(0, 42)
  const central = Buffer.concat([centralHeader, name, extra])

  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x0605_4b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(1, 8)
  end.writeUInt16LE(1, 10)
  end.writeUInt32LE(central.length, 12)
  end.writeUInt32LE(local.length, 16)
  end.writeUInt16LE(0, 20)
  return Buffer.concat([local, central, end])
}

export function renderCanonicalArchive(binary, format, sourceDateEpochInput) {
  if (!Buffer.isBuffer(binary)) fail('archive rendering binary must be a Buffer')
  if (binary.length === 0 || binary.length > maximumBinaryBytes) {
    fail('archive rendering binary size is invalid')
  }
  const sourceDateEpoch = parseSourceDateEpoch(sourceDateEpochInput)
  if (format === 'tar.gz') return canonicalTarGzip(binary, sourceDateEpoch)
  if (format === 'zip') return canonicalZip(binary, sourceDateEpoch)
  fail(`unsupported archive rendering format ${JSON.stringify(format)}`)
}

function tarBinary(archive) {
  if (archive.length < 18
    || archive[0] !== 0x1f
    || archive[1] !== 0x8b
    || archive[2] !== 0x08) {
    fail('tar.gz archive has an invalid gzip header')
  }
  const maximumTarBytes = maximumBinaryBytes + (3 * tarBlockBytes)
  const advertisedBytes = archive.readUInt32LE(archive.length - 4)
  if (advertisedBytes < 3 * tarBlockBytes || advertisedBytes > maximumTarBytes) {
    fail('tar.gz archive advertises an invalid uncompressed size')
  }
  let tar
  try {
    tar = gunzipSync(archive, { maxOutputLength: maximumTarBytes })
  } catch (error) {
    fail(`tar.gz archive could not be decoded: ${error.message}`)
  }
  if (tar.length < 3 * tarBlockBytes) fail('tar.gz archive is truncated')
  const header = tar.subarray(0, tarBlockBytes)
  const nameEnd = header.indexOf(0)
  if (nameEnd === -1 || header.subarray(0, nameEnd).toString('ascii') !== 'zigcss') {
    fail('tar.gz archive must contain exactly the zigcss entry')
  }
  const sizeField = header.subarray(124, 136).toString('ascii')
  if (!/^[0-7]{11}\0$/u.test(sizeField)) fail('tar.gz archive size field is not canonical')
  const binaryBytes = Number.parseInt(sizeField.slice(0, -1), 8)
  if (!Number.isSafeInteger(binaryBytes) || binaryBytes <= 0 || binaryBytes > maximumBinaryBytes) {
    fail('tar.gz archive binary size is invalid')
  }
  const paddedBytes = Math.ceil(binaryBytes / tarBlockBytes) * tarBlockBytes
  const expectedBytes = tarBlockBytes + paddedBytes + (2 * tarBlockBytes)
  if (tar.length !== expectedBytes) fail('tar.gz archive must contain exactly one entry')
  return Buffer.from(tar.subarray(tarBlockBytes, tarBlockBytes + binaryBytes))
}

function zipBinary(archive) {
  if (archive.length < 52 || archive.readUInt32LE(0) !== 0x0403_4b50) {
    fail('ZIP archive has an invalid local header')
  }
  const method = archive.readUInt16LE(8)
  const compressedBytes = archive.readUInt32LE(18)
  const binaryBytes = archive.readUInt32LE(22)
  const nameBytes = archive.readUInt16LE(26)
  const extraBytes = archive.readUInt16LE(28)
  if (method !== 0 || compressedBytes !== binaryBytes) {
    fail('ZIP archive must contain one stored executable')
  }
  if (binaryBytes === 0 || binaryBytes > maximumBinaryBytes || nameBytes === 0 || nameBytes > 256 || extraBytes > 1024) {
    fail('ZIP archive entry sizes are invalid')
  }
  const nameStart = 30
  const binaryStart = nameStart + nameBytes + extraBytes
  const binaryEnd = binaryStart + binaryBytes
  if (binaryEnd > archive.length) fail('ZIP archive entry is truncated')
  if (archive.subarray(nameStart, nameStart + nameBytes).toString('utf8') !== 'zigcss.exe') {
    fail('ZIP archive must contain exactly the zigcss.exe entry')
  }
  return Buffer.from(archive.subarray(binaryStart, binaryEnd))
}

function inspectArchive(bytes, policy, sourceDateEpoch) {
  const format = policy.archiveExtension
  const binary = format === 'tar.gz'
    ? tarBinary(bytes)
    : format === 'zip'
      ? zipBinary(bytes)
      : fail(`unsupported release archive format ${JSON.stringify(format)}`)

  let identity
  try {
    identity = assertArtifactMatchesTarget(binary, policy.target)
  } catch (error) {
    fail(`${policy.target} archive target is invalid: ${error.message}`)
  }
  const canonical = renderCanonicalArchive(binary, format, sourceDateEpoch)
  if (!equalBytes(bytes, canonical)) {
    fail(`${policy.target} archive is not the canonical deterministic ${format} encoding`)
  }
  return Object.freeze({
    arch: identity.arch,
    binaryBytes: binary.length,
    format: identity.format,
  })
}

export function parseGenerateNativeIntegrityArguments(args) {
  if (!Array.isArray(args) || args.length !== 13 || !['--check', '--write'].includes(args[0])) {
    fail('usage: --check|--write --source-date-epoch integer plus exactly five --archive absolute-path arguments')
  }
  const archives = []
  let sourceDateEpoch
  for (let index = 1; index < args.length; index += 2) {
    const option = args[index]
    const value = args[index + 1]
    if (value === undefined || value.startsWith('--')) fail(`${option} requires one value`)
    if (option === '--archive') {
      archives.push(archivePath(value))
    } else if (option === '--source-date-epoch' && sourceDateEpoch === undefined) {
      sourceDateEpoch = parseSourceDateEpoch(value)
    } else {
      fail(`unsupported or duplicate option ${JSON.stringify(option)}`)
    }
  }
  if (sourceDateEpoch === undefined || archives.length !== releaseTargets.length) {
    fail('one source date epoch and exactly five archives are required')
  }
  return Object.freeze({
    mode: args[0].slice(2),
    sourceDateEpoch,
    archives: Object.freeze(archives),
  })
}

function normalizeBuildOptions(options) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    fail('generation options must be an object')
  }
  if (!same(Object.keys(options).sort(), ['archives', 'root', 'sourceDateEpoch'])) {
    fail('generation options must use the closed contract')
  }
  if (!Array.isArray(options.archives) || options.archives.length !== releaseTargets.length) {
    fail(`exactly ${releaseTargets.length} archives are required`)
  }
  return Object.freeze({
    root: canonicalRoot(options.root),
    sourceDateEpoch: parseSourceDateEpoch(options.sourceDateEpoch),
    archives: Object.freeze(options.archives.map(archivePath)),
  })
}

export function buildNativeIntegrityManifest(options) {
  const normalized = normalizeBuildOptions(options)
  if (new Set(normalized.archives).size !== normalized.archives.length) {
    fail('archive paths must be unique')
  }

  const versionSource = readUtf8File(normalized.root, 'VERSION', 'VERSION', maximumVersionBytes)
  if (!versionSource.endsWith('\n') || versionSource.trim() + '\n' !== versionSource) {
    fail('VERSION must contain one canonical version and a final newline')
  }
  const version = parseReleaseVersion(versionSource.trim(), 'native integrity generation VERSION').value
  const packageSource = readUtf8File(
    normalized.root,
    'package.json',
    'package.json',
    maximumPackageManifestBytes,
  )
  let packageManifest
  try {
    packageManifest = JSON.parse(packageSource)
  } catch (error) {
    fail(`package.json is not valid JSON: ${error.message}`)
  }
  if (packageManifest?.name !== 'zigcss' || packageManifest.version !== version) {
    fail('package.json identity must match VERSION and package zigcss')
  }

  const expectedByFilename = new Map(releaseTargets.map(policy => [
    releaseAssetsFor(version, policy.target).archive,
    policy,
  ]))
  const records = new Map()
  const inspections = new Map()
  for (const filename of normalized.archives) {
    const basename = path.basename(filename)
    const policy = expectedByFilename.get(basename)
    if (policy === undefined) fail(`unexpected native archive filename ${JSON.stringify(basename)}`)
    if (records.has(policy.target)) fail(`duplicate native archive target ${policy.target}`)
    const { bytes } = readStableRegularFile(filename, `${policy.target} archive`, maximumArchiveBytes)
    inspections.set(policy.target, inspectArchive(bytes, policy, normalized.sourceDateEpoch))
    records.set(policy.target, Object.freeze({
      target: policy.target,
      filename: basename,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    }))
  }
  if (records.size !== releaseTargets.length) fail('native archive target inventory is incomplete')

  const manifest = {
    schemaVersion: 1,
    package: packageManifest.name,
    version,
    sourceDateEpoch: normalized.sourceDateEpoch,
    archives: releaseTargets.map(policy => records.get(policy.target)),
  }
  const text = `${JSON.stringify(manifest, null, 2)}\n`
  if (Buffer.byteLength(text) > maximumManifestBytes) fail('generated native integrity manifest is oversized')
  validateNativeIntegritySources({
    manifest: text,
    packageManifest: packageSource,
    version: versionSource,
  })
  return Object.freeze({
    manifest: Object.freeze(manifest),
    text,
    inspections: Object.freeze(Object.fromEntries(inspections)),
  })
}

function outputPath(root) {
  return path.join(root, outputRelativePath)
}

function readExistingOutput(filename) {
  try {
    fs.lstatSync(filename)
  } catch (error) {
    if (error.code === 'ENOENT') return null
    fail(`native integrity output is unavailable: ${error.message}`)
  }
  return readStableRegularFile(filename, 'native integrity output', maximumManifestBytes)
}

function sameStat(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.size === right.size
    && left.mtimeNs === right.mtimeNs
    && left.ctimeNs === right.ctimeNs
}

function syncDirectory(directory) {
  let descriptor
  try {
    descriptor = fs.openSync(directory, fs.constants.O_RDONLY | (fs.constants.O_CLOEXEC ?? 0))
    fs.fsyncSync(descriptor)
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

function commitOutput(filename, text) {
  const expected = Buffer.from(text, 'utf8')
  const existing = readExistingOutput(filename)
  if (existing !== null && equalBytes(existing.bytes, expected)) return 'identical'

  const temporary = path.join(
    path.dirname(filename),
    `.${path.basename(filename)}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`,
  )
  let descriptor
  try {
    descriptor = fs.openSync(
      temporary,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_CLOEXEC ?? 0),
      0o600,
    )
    fs.fchmodSync(descriptor, 0o644)
    fs.writeFileSync(descriptor, expected)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = undefined

    if (existing === null) {
      try {
        fs.linkSync(temporary, filename)
      } catch (error) {
        fail(`native integrity output could not be created exclusively: ${error.message}`)
      }
      fs.unlinkSync(temporary)
      syncDirectory(path.dirname(filename))
      return 'created'
    }

    let finalStat
    try {
      finalStat = fs.lstatSync(filename, { bigint: true })
    } catch {
      fail('native integrity output changed before replacement')
    }
    if (!finalStat.isFile() || finalStat.isSymbolicLink() || !sameStat(existing.stat, finalStat)) {
      fail('native integrity output changed before replacement')
    }
    fs.renameSync(temporary, filename)
    syncDirectory(path.dirname(filename))
    return 'updated'
  } finally {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor)
      } catch {}
    }
    try {
      fs.unlinkSync(temporary)
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
  }
}

export function writeNativeIntegrityManifest(options) {
  const result = buildNativeIntegrityManifest(options)
  const root = canonicalRoot(options.root)
  const status = commitOutput(outputPath(root), result.text)
  const written = readStableRegularFile(outputPath(root), 'native integrity output', maximumManifestBytes)
  if (!equalBytes(written.bytes, Buffer.from(result.text, 'utf8'))) {
    fail('native integrity output failed byte-exact readback')
  }
  return Object.freeze({ ...result, status })
}

export function checkNativeIntegrityManifest(options) {
  const result = buildNativeIntegrityManifest(options)
  const root = canonicalRoot(options.root)
  const existing = readExistingOutput(outputPath(root))
  if (existing === null || !equalBytes(existing.bytes, Buffer.from(result.text, 'utf8'))) {
    fail('native-integrity.json is stale; rerun with --write and the exact five archives')
  }
  return Object.freeze({ ...result, status: 'verified' })
}

function invokedAsMain() {
  if (typeof process.argv[1] !== 'string') return false
  try {
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(scriptPath)
  } catch {
    return path.resolve(process.argv[1]) === path.resolve(scriptPath)
  }
}

if (invokedAsMain()) {
  try {
    const command = parseGenerateNativeIntegrityArguments(process.argv.slice(2))
    const operation = command.mode === 'write' ? writeNativeIntegrityManifest : checkNativeIntegrityManifest
    const result = operation({
      archives: command.archives,
      root: repositoryRoot,
      sourceDateEpoch: command.sourceDateEpoch,
    })
    process.stdout.write(
      `Native integrity ${result.status}: ${result.manifest.archives.length} canonical archives for ${result.manifest.package}@${result.manifest.version}.\n`,
    )
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
