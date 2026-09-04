import fs from 'node:fs'
import path from 'node:path'
import { gzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)

export const maximumBinaryBytes = 256 * 1024 * 1024
export const maximumArchiveBytes = 512 * 1024 * 1024
export const maximumPathBytes = 4096
export const maximumSourceDateEpoch = 0xffff_ffff

const tarBlockBytes = 512
const zipUtf8Flag = 0x0800
const zipStoredMethod = 0
const normalizedExecutableMode = 0o100755

function fail(message) {
  throw new Error(`release archive integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function validateFilesystemPath(value, label) {
  if (typeof value !== 'string' || value.length === 0) fail(`${label} must be a nonempty path`)
  if (Buffer.byteLength(value) > maximumPathBytes) fail(`${label} exceeds ${maximumPathBytes} bytes`)
  if (value.includes('\0') || value.includes('\r') || value.includes('\n')) {
    fail(`${label} contains an unsupported control byte`)
  }
  if (/^(?:\\\\|\/\/)/.test(value)) fail(`${label} must not be a network path`)
  if (/(?:^|[\\/])\.\.?(?:[\\/]|$)/.test(value)) fail(`${label} must not contain dot path segments`)
  if (/[\\/]$/.test(value)) fail(`${label} must name a file`)
  return path.resolve(value)
}

function parseSourceDateEpoch(value) {
  let epoch
  if (typeof value === 'number') {
    epoch = value
  } else if (typeof value === 'string' && /^(?:0|[1-9]\d*)$/.test(value)) {
    epoch = Number(value)
  } else {
    fail('SOURCE_DATE_EPOCH must be a canonical unsigned decimal integer')
  }
  if (!Number.isSafeInteger(epoch) || epoch < 0 || epoch > maximumSourceDateEpoch) {
    fail(`SOURCE_DATE_EPOCH must be between 0 and ${maximumSourceDateEpoch}`)
  }
  return epoch
}

export function parseArchiveArguments(args) {
  if (!Array.isArray(args) || args.length !== 6) {
    fail('expected exactly --binary, --archive, and --source-date-epoch')
  }
  const allowed = new Set(['--binary', '--archive', '--source-date-epoch'])
  const values = {}
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index]
    const value = args[index + 1]
    if (!allowed.has(option)) fail(`unsupported option ${JSON.stringify(option)}`)
    if (Object.hasOwn(values, option)) fail(`duplicate option ${option}`)
    if (typeof value !== 'string' || value.length === 0 || value.startsWith('--')) {
      fail(`${option} requires one value`)
    }
    values[option] = value
  }
  if (!same(Object.keys(values).sort(), [...allowed].sort())) fail('required archive options are missing')
  return Object.freeze({
    binary: values['--binary'],
    archive: values['--archive'],
    sourceDateEpoch: parseSourceDateEpoch(values['--source-date-epoch']),
  })
}

function archivePolicy(binaryPath, archivePath) {
  const binaryName = path.basename(binaryPath)
  if (archivePath.endsWith('.tar.gz')) {
    if (binaryName !== 'zigcss') fail('tar.gz input must be named zigcss')
    return Object.freeze({ format: 'tar.gz', entryName: 'zigcss' })
  }
  if (archivePath.endsWith('.zip')) {
    if (binaryName !== 'zigcss.exe') fail('zip input must be named zigcss.exe')
    return Object.freeze({ format: 'zip', entryName: 'zigcss.exe' })
  }
  fail('archive must end in .tar.gz or .zip')
}

function readBoundedBinary(binaryPath) {
  let pathStat
  try {
    pathStat = fs.lstatSync(binaryPath, { bigint: true })
  } catch (error) {
    fail(`binary is unavailable: ${error.message}`)
  }
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    fail('binary must be a regular non-symlink file')
  }
  if (pathStat.size <= 0n) fail('binary must not be empty')
  if (pathStat.size > BigInt(maximumBinaryBytes)) {
    fail(`binary exceeds ${maximumBinaryBytes} bytes`)
  }

  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  const closeOnExec = fs.constants.O_CLOEXEC ?? 0
  let descriptor
  try {
    descriptor = fs.openSync(binaryPath, fs.constants.O_RDONLY | noFollow | closeOnExec)
  } catch (error) {
    fail(`binary could not be opened safely: ${error.message}`)
  }

  try {
    const before = fs.fstatSync(descriptor, { bigint: true })
    if (!before.isFile()
      || before.dev !== pathStat.dev
      || before.ino !== pathStat.ino
      || before.size !== pathStat.size) {
      fail('binary changed while it was being opened')
    }
    const bytes = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor, { bigint: true })
    if (after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs
      || after.ctimeNs !== before.ctimeNs
      || BigInt(bytes.length) !== before.size) {
      fail('binary changed while it was being read')
    }
    return bytes
  } finally {
    fs.closeSync(descriptor)
  }
}

function writeTarOctal(header, offset, width, value) {
  const octal = value.toString(8)
  if (octal.length > width - 1) fail('tar metadata exceeds the normalized octal field')
  header.write(`${octal.padStart(width - 1, '0')}\0`, offset, width, 'ascii')
}

function createTarBytes(binary, entryName, sourceDateEpoch) {
  const header = Buffer.alloc(tarBlockBytes)
  header.write(entryName, 0, 100, 'ascii')
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

function createTarGzipArchive(binary, entryName, sourceDateEpoch) {
  const tar = createTarBytes(binary, entryName, sourceDateEpoch)
  const archive = gzipSync(tar, { level: 9, mtime: 0 })
  if (archive.length < 18 || archive[0] !== 0x1f || archive[1] !== 0x8b || archive[2] !== 0x08) {
    fail('internal gzip encoder returned an invalid stream')
  }
  if (archive[3] !== 0) fail('internal gzip encoder returned unexpected optional metadata')
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
  const time = (date.getUTCHours() << 11)
    | (date.getUTCMinutes() << 5)
    | Math.floor(date.getUTCSeconds() / 2)
  const day = ((date.getUTCFullYear() - 1980) << 9)
    | ((date.getUTCMonth() + 1) << 5)
    | date.getUTCDate()
  return { time, day }
}

function zipExtraFields(sourceDateEpoch) {
  const timestamp = Buffer.alloc(9)
  timestamp.writeUInt16LE(0x5455, 0)
  timestamp.writeUInt16LE(5, 2)
  timestamp[4] = 1
  timestamp.writeUInt32LE(sourceDateEpoch, 5)
  const owner = Buffer.from([0x75, 0x78, 0x05, 0x00, 0x01, 0x01, 0x00, 0x01, 0x00])
  return Buffer.concat([timestamp, owner])
}

function createZipArchive(binary, entryName, sourceDateEpoch) {
  const name = Buffer.from(entryName, 'utf8')
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

function writeCreateOnly(archivePath, bytes) {
  let descriptor
  let created = false
  try {
    descriptor = fs.openSync(
      archivePath,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_CLOEXEC ?? 0),
      0o644,
    )
    created = true
    fs.fchmodSync(descriptor, 0o644)
    fs.writeFileSync(descriptor, bytes)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = undefined
  } catch (error) {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor)
      } catch {}
    }
    if (created) {
      try {
        fs.unlinkSync(archivePath)
      } catch {}
    }
    fail(`archive could not be created exclusively: ${error.message}`)
  }
}

export function createReleaseArchive(options) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    fail('archive options must be an object')
  }
  const expectedKeys = ['archive', 'binary', 'sourceDateEpoch']
  if (!same(Object.keys(options).sort(), expectedKeys)) fail('archive options must use the closed contract')

  const binaryPath = validateFilesystemPath(options.binary, 'binary path')
  const archivePath = validateFilesystemPath(options.archive, 'archive path')
  if (binaryPath === archivePath) fail('binary and archive paths must differ')
  const sourceDateEpoch = parseSourceDateEpoch(options.sourceDateEpoch)
  const policy = archivePolicy(binaryPath, archivePath)

  const archiveParent = path.dirname(archivePath)
  let parentStat
  try {
    parentStat = fs.lstatSync(archiveParent)
  } catch (error) {
    fail(`archive parent is unavailable: ${error.message}`)
  }
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink()) {
    fail('archive parent must be a regular non-symlink directory')
  }

  const binary = readBoundedBinary(binaryPath)
  const bytes = policy.format === 'tar.gz'
    ? createTarGzipArchive(binary, policy.entryName, sourceDateEpoch)
    : createZipArchive(binary, policy.entryName, sourceDateEpoch)
  if (bytes.length <= 0 || bytes.length > maximumArchiveBytes) {
    fail(`archive exceeds ${maximumArchiveBytes} bytes`)
  }
  writeCreateOnly(archivePath, bytes)

  const outputStat = fs.lstatSync(archivePath)
  if (!outputStat.isFile() || outputStat.isSymbolicLink() || outputStat.size !== bytes.length) {
    try {
      fs.unlinkSync(archivePath)
    } catch {}
    fail('created archive failed its regular-file integrity check')
  }
  return Object.freeze({
    archive: archivePath,
    bytes: bytes.length,
    entry: policy.entryName,
    format: policy.format,
    sourceDateEpoch,
  })
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
    const result = createReleaseArchive(parseArchiveArguments(process.argv.slice(2)))
    process.stdout.write(`created ${result.format} archive with ${result.entry} (${result.bytes} bytes)\n`)
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
