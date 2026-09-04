import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { gunzipSync } from 'node:zlib'
import {
  createReleaseArchive,
  maximumArchiveBytes,
  maximumBinaryBytes,
  maximumPathBytes,
  maximumSourceDateEpoch,
  parseArchiveArguments,
} from './create-release-archive.mjs'
import { readStableRegularFile } from './bounded-filesystem.mjs'

const scriptPath = fileURLToPath(new URL('./create-release-archive.mjs', import.meta.url))
const sourceDateEpoch = 1_700_000_001
const binaryFixture = Buffer.from([0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff, 0x5a, 0x49, 0x47, 0x43, 0x53, 0x53])

function temporaryDirectory(t, prefix) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  return directory
}

function writeBinary(directory, name) {
  const binary = path.join(directory, name)
  fs.writeFileSync(binary, binaryFixture, { mode: 0o700 })
  return binary
}

function tarOctal(header, offset, width) {
  const field = header.subarray(offset, offset + width).toString('ascii').replace(/[\0 ]+$/u, '')
  return Number.parseInt(field || '0', 8)
}

function assertAllZero(bytes, label) {
  assert.equal(bytes.every(byte => byte === 0), true, label)
}

function parseTarGzip(archive) {
  assert.equal(archive[0], 0x1f)
  assert.equal(archive[1], 0x8b)
  assert.equal(archive[2], 0x08)
  assert.equal(archive[3], 0)
  assert.equal(archive.readUInt32LE(4), 0)
  assert.equal(archive[9], 0xff)
  const tar = gunzipSync(archive)
  const header = tar.subarray(0, 512)
  const storedChecksum = tarOctal(header, 148, 8)
  const checksumHeader = Buffer.from(header)
  checksumHeader.fill(0x20, 148, 156)
  assert.equal(checksumHeader.reduce((sum, byte) => sum + byte, 0), storedChecksum)
  const name = header.subarray(0, 100).toString('utf8').split('\0', 1)[0]
  const size = tarOctal(header, 124, 12)
  const paddedSize = Math.ceil(size / 512) * 512
  assert.equal(tar.length, 512 + paddedSize + 1024)
  assertAllZero(tar.subarray(512 + size), 'tar padding and end markers must be zero')
  return {
    bytes: tar.subarray(512, 512 + size),
    devMajor: tarOctal(header, 329, 8),
    devMinor: tarOctal(header, 337, 8),
    gid: tarOctal(header, 116, 8),
    gname: header.subarray(297, 329),
    magic: header.subarray(257, 265).toString('ascii'),
    mode: tarOctal(header, 100, 8),
    mtime: tarOctal(header, 136, 12),
    name,
    type: String.fromCharCode(header[156]),
    uid: tarOctal(header, 108, 8),
    uname: header.subarray(265, 297),
  }
}

function parseExtraFields(bytes) {
  const fields = new Map()
  let offset = 0
  while (offset < bytes.length) {
    assert.ok(offset + 4 <= bytes.length)
    const id = bytes.readUInt16LE(offset)
    const length = bytes.readUInt16LE(offset + 2)
    offset += 4
    assert.ok(offset + length <= bytes.length)
    assert.equal(fields.has(id), false, `duplicate ZIP extra field ${id}`)
    fields.set(id, bytes.subarray(offset, offset + length))
    offset += length
  }
  assert.equal(offset, bytes.length)
  return fields
}

function parseZip(archive) {
  const endOffset = archive.length - 22
  assert.equal(archive.readUInt32LE(endOffset), 0x0605_4b50)
  assert.equal(archive.readUInt16LE(endOffset + 4), 0)
  assert.equal(archive.readUInt16LE(endOffset + 6), 0)
  assert.equal(archive.readUInt16LE(endOffset + 8), 1)
  assert.equal(archive.readUInt16LE(endOffset + 10), 1)
  assert.equal(archive.readUInt16LE(endOffset + 20), 0)
  const centralSize = archive.readUInt32LE(endOffset + 12)
  const centralOffset = archive.readUInt32LE(endOffset + 16)
  assert.equal(centralOffset + centralSize, endOffset)

  assert.equal(archive.readUInt32LE(centralOffset), 0x0201_4b50)
  assert.equal(archive.readUInt16LE(centralOffset + 4), 0x0314)
  assert.equal(archive.readUInt16LE(centralOffset + 8), 0x0800)
  assert.equal(archive.readUInt16LE(centralOffset + 10), 0)
  assert.equal(archive.readUInt16LE(centralOffset + 34), 0)
  assert.equal(archive.readUInt16LE(centralOffset + 36), 0)
  assert.equal(archive.readUInt32LE(centralOffset + 42), 0)
  assert.equal(archive.readUInt32LE(centralOffset + 38) >>> 16, 0o100755)
  const centralNameLength = archive.readUInt16LE(centralOffset + 28)
  const centralExtraLength = archive.readUInt16LE(centralOffset + 30)
  const centralCommentLength = archive.readUInt16LE(centralOffset + 32)
  const centralNameStart = centralOffset + 46
  const centralName = archive.subarray(centralNameStart, centralNameStart + centralNameLength).toString('utf8')
  const centralExtra = archive.subarray(
    centralNameStart + centralNameLength,
    centralNameStart + centralNameLength + centralExtraLength,
  )
  assert.equal(46 + centralNameLength + centralExtraLength + centralCommentLength, centralSize)

  assert.equal(archive.readUInt32LE(0), 0x0403_4b50)
  assert.equal(archive.readUInt16LE(4), 20)
  assert.equal(archive.readUInt16LE(6), 0x0800)
  assert.equal(archive.readUInt16LE(8), 0)
  const compressedSize = archive.readUInt32LE(18)
  const uncompressedSize = archive.readUInt32LE(22)
  assert.equal(compressedSize, uncompressedSize)
  const localNameLength = archive.readUInt16LE(26)
  const localExtraLength = archive.readUInt16LE(28)
  const localNameStart = 30
  const localName = archive.subarray(localNameStart, localNameStart + localNameLength).toString('utf8')
  const localExtraStart = localNameStart + localNameLength
  const localExtra = archive.subarray(localExtraStart, localExtraStart + localExtraLength)
  const dataStart = localExtraStart + localExtraLength
  assert.equal(dataStart + compressedSize, centralOffset)
  assert.equal(archive.readUInt32LE(14), archive.readUInt32LE(centralOffset + 16))
  assert.equal(compressedSize, archive.readUInt32LE(centralOffset + 20))
  assert.equal(uncompressedSize, archive.readUInt32LE(centralOffset + 24))
  assert.equal(localName, centralName)
  assert.deepEqual(localExtra, centralExtra)
  return {
    bytes: archive.subarray(dataStart, dataStart + compressedSize),
    extra: parseExtraFields(localExtra),
    name: localName,
  }
}

function assertNormalizedExtraFields(fields) {
  assert.deepEqual([...fields.keys()], [0x5455, 0x7875])
  const timestamp = fields.get(0x5455)
  assert.equal(timestamp.length, 5)
  assert.equal(timestamp[0], 1)
  assert.equal(timestamp.readUInt32LE(1), sourceDateEpoch)
  assert.deepEqual(fields.get(0x7875), Buffer.from([1, 1, 0, 1, 0]))
}

function assertTarExtractionWhenAvailable(t, archive, entry, expected) {
  const probe = spawnSync('tar', ['--version'], { encoding: 'utf8' })
  if (probe.error?.code === 'ENOENT') {
    t.diagnostic('tar is unavailable; internal archive parsing still ran')
    return
  }
  assert.equal(probe.status, 0, probe.stderr)
  const listing = spawnSync('tar', ['-tf', archive], { encoding: 'utf8' })
  assert.equal(listing.status, 0, listing.stderr)
  assert.deepEqual(listing.stdout.trim().split(/\r?\n/u), [entry])
  const extraction = spawnSync('tar', ['-xOf', archive, entry], { encoding: null, maxBuffer: 1024 * 1024 })
  assert.equal(extraction.status, 0, extraction.stderr?.toString())
  assert.deepEqual(extraction.stdout, expected)
}

function assertZipTarExtractionWhenSupported(t, archive, entry, expected) {
  const listing = spawnSync('tar', ['-tf', archive], { encoding: 'utf8' })
  if (listing.error?.code === 'ENOENT' || listing.status !== 0) {
    t.diagnostic('the available tar does not read ZIP; internal ZIP extraction still ran')
    return
  }
  assert.deepEqual(listing.stdout.trim().split(/\r?\n/u), [entry])
  const extraction = spawnSync('tar', ['-xOf', archive, entry], { encoding: null, maxBuffer: 1024 * 1024 })
  assert.equal(extraction.status, 0, extraction.stderr?.toString())
  assert.deepEqual(extraction.stdout, expected)
}

test('tar.gz bytes are repeatable despite source metadata and contain one normalized exact entry', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-tar-')
  const binary = writeBinary(directory, 'zigcss')
  const first = path.join(directory, 'first.tar.gz')
  const second = path.join(directory, 'second.tar.gz')
  fs.utimesSync(binary, new Date(1_000), new Date(2_000))
  const firstResult = createReleaseArchive({ binary, archive: first, sourceDateEpoch })
  fs.utimesSync(binary, new Date(3_000_000), new Date(4_000_000))
  if (process.platform !== 'win32') fs.chmodSync(binary, 0o777)
  const secondResult = createReleaseArchive({ binary, archive: second, sourceDateEpoch })
  const firstBytes = readStableRegularFile(first, {
    label: 'first tar archive',
    maximumBytes: maximumArchiveBytes,
    reject: assert.fail,
  })
  const secondBytes = readStableRegularFile(second, {
    label: 'second tar archive',
    maximumBytes: maximumArchiveBytes,
    reject: assert.fail,
  })

  assert.deepEqual(firstResult, {
    archive: first,
    bytes: firstBytes.length,
    entry: 'zigcss',
    format: 'tar.gz',
    sourceDateEpoch,
  })
  assert.equal(secondResult.bytes, firstResult.bytes)
  assert.deepEqual(firstBytes, secondBytes)
  const entry = parseTarGzip(firstBytes)
  assert.equal(entry.name, 'zigcss')
  assert.equal(entry.mode, 0o755)
  assert.equal(entry.uid, 0)
  assert.equal(entry.gid, 0)
  assert.equal(entry.mtime, sourceDateEpoch)
  assert.equal(entry.type, '0')
  assert.equal(entry.magic, `ustar${String.fromCharCode(0)}00`)
  assert.equal(entry.devMajor, 0)
  assert.equal(entry.devMinor, 0)
  assertAllZero(entry.uname, 'tar uname must be empty')
  assertAllZero(entry.gname, 'tar gname must be empty')
  assert.deepEqual(entry.bytes, binaryFixture)
  assertTarExtractionWhenAvailable(t, first, 'zigcss', binaryFixture)
  if (process.platform !== 'win32') assert.equal(fs.statSync(first).mode & 0o777, 0o644)
})

test('zip bytes are repeatable despite source metadata and contain one normalized exact entry', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-zip-')
  const binary = writeBinary(directory, 'zigcss.exe')
  const first = path.join(directory, 'first.zip')
  const second = path.join(directory, 'second.zip')
  fs.utimesSync(binary, new Date(10_000), new Date(20_000))
  const firstResult = createReleaseArchive({ binary, archive: first, sourceDateEpoch })
  fs.utimesSync(binary, new Date(30_000_000), new Date(40_000_000))
  if (process.platform !== 'win32') fs.chmodSync(binary, 0o600)
  const secondResult = createReleaseArchive({ binary, archive: second, sourceDateEpoch })
  const firstBytes = readStableRegularFile(first, {
    label: 'first ZIP archive',
    maximumBytes: maximumArchiveBytes,
    reject: assert.fail,
  })
  const secondBytes = readStableRegularFile(second, {
    label: 'second ZIP archive',
    maximumBytes: maximumArchiveBytes,
    reject: assert.fail,
  })

  assert.equal(firstResult.entry, 'zigcss.exe')
  assert.equal(firstResult.format, 'zip')
  assert.equal(secondResult.bytes, firstResult.bytes)
  assert.deepEqual(firstBytes, secondBytes)
  const entry = parseZip(firstBytes)
  assert.equal(entry.name, 'zigcss.exe')
  assert.deepEqual(entry.bytes, binaryFixture)
  assertNormalizedExtraFields(entry.extra)
  assertZipTarExtractionWhenSupported(t, first, 'zigcss.exe', binaryFixture)
  if (process.platform !== 'win32') assert.equal(fs.statSync(first).mode & 0o777, 0o644)
})

test('closed CLI accepts only the three exact bounded inputs', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-cli-')
  const binary = writeBinary(directory, 'zigcss')
  const archive = path.join(directory, 'cli.tar.gz')
  assert.deepEqual(parseArchiveArguments([
    '--source-date-epoch', String(sourceDateEpoch),
    '--archive', archive,
    '--binary', binary,
  ]), { binary, archive, sourceDateEpoch })

  for (const invalid of [
    [],
    ['--binary', binary, '--archive', archive],
    ['--binary', binary, '--archive', archive, '--unknown', '1'],
    ['--binary', binary, '--archive', archive, '--archive', archive],
    ['--binary', binary, '--archive', archive, '--source-date-epoch', '01'],
    ['--binary', binary, '--archive', '--source-date-epoch', '1', '--unknown'],
  ]) {
    assert.throws(() => parseArchiveArguments(invalid), /release archive integrity/)
  }

  const run = spawnSync(process.execPath, [
    scriptPath,
    '--binary', binary,
    '--archive', archive,
    '--source-date-epoch', String(sourceDateEpoch),
  ], { encoding: 'utf8' })
  assert.equal(run.status, 0, run.stderr)
  assert.match(run.stdout, /^created tar\.gz archive with zigcss \(\d+ bytes\)\n$/u)
  assert.deepEqual(parseTarGzip(fs.readFileSync(archive)).bytes, binaryFixture)

  const rejected = spawnSync(process.execPath, [scriptPath, '--binary', binary], { encoding: 'utf8' })
  assert.equal(rejected.status, 1)
  assert.match(rejected.stderr, /^release archive integrity:/u)
})

test('malformed paths, symlinks, non-binaries, and unsupported formats fail closed', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-invalid-')
  const binary = writeBinary(directory, 'zigcss')
  const zipBinary = writeBinary(directory, 'zigcss.exe')
  const empty = path.join(directory, 'empty', 'zigcss')
  fs.mkdirSync(path.dirname(empty))
  fs.writeFileSync(empty, '')
  const binaryDirectory = path.join(directory, 'directory', 'zigcss')
  fs.mkdirSync(binaryDirectory, { recursive: true })
  const binaryLink = path.join(directory, 'linked', 'zigcss')
  fs.mkdirSync(path.dirname(binaryLink))
  fs.symlinkSync(binary, binaryLink)
  const realArchiveParent = path.join(directory, 'real-output')
  const linkedArchiveParent = path.join(directory, 'linked-output')
  fs.mkdirSync(realArchiveParent)
  fs.symlinkSync(realArchiveParent, linkedArchiveParent)

  const invalidCases = [
    [{ binary, archive: path.join(directory, 'bad.tgz'), sourceDateEpoch }, /\.tar\.gz or \.zip/],
    [{ binary, archive: path.join(directory, 'bad.zip'), sourceDateEpoch }, /zip input must be named zigcss\.exe/],
    [{ binary: zipBinary, archive: path.join(directory, 'bad.tar.gz'), sourceDateEpoch }, /tar\.gz input must be named zigcss/],
    [{ binary: empty, archive: path.join(directory, 'empty.tar.gz'), sourceDateEpoch }, /must not be empty/],
    [{ binary: binaryDirectory, archive: path.join(directory, 'directory.tar.gz'), sourceDateEpoch }, /regular non-symlink/],
    [{ binary: binaryLink, archive: path.join(directory, 'linked.tar.gz'), sourceDateEpoch }, /regular non-symlink/],
    [{ binary, archive: path.join(linkedArchiveParent, 'linked.tar.gz'), sourceDateEpoch }, /non-symlink directory/],
    [{ binary, archive: path.join(directory, 'missing', 'out.tar.gz'), sourceDateEpoch }, /archive parent is unavailable/],
    [{ binary: `${directory}/../${path.basename(directory)}/zigcss`, archive: path.join(directory, 'dot.tar.gz'), sourceDateEpoch }, /dot path segments/],
    [{ binary, archive: `${path.join(directory, 'newline.tar.gz')}\n`, sourceDateEpoch }, /control byte/],
    [{ binary: `zigcss\0hidden`, archive: path.join(directory, 'nul.tar.gz'), sourceDateEpoch }, /control byte/],
    [{ binary, archive: `${'x'.repeat(maximumPathBytes)}.tar.gz`, sourceDateEpoch }, /exceeds 4096 bytes/],
    [{ binary, archive: path.join(directory, 'extra.tar.gz'), sourceDateEpoch, extra: true }, /closed contract/],
  ]
  for (const [options, expression] of invalidCases) {
    assert.throws(() => createReleaseArchive(options), expression)
  }
})

test('SOURCE_DATE_EPOCH and input/output byte bounds fail closed', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-bounds-')
  const binary = writeBinary(directory, 'zigcss')
  for (const [index, invalid] of [-1, 1.5, Number.NaN, maximumSourceDateEpoch + 1, '1.0', '+1', '01'].entries()) {
    assert.throws(
      () => createReleaseArchive({
        binary,
        archive: path.join(directory, `epoch-${index}.tar.gz`),
        sourceDateEpoch: invalid,
      }),
      /SOURCE_DATE_EPOCH/,
    )
  }

  const oversizedDirectory = path.join(directory, 'oversized')
  fs.mkdirSync(oversizedDirectory)
  const oversized = path.join(oversizedDirectory, 'zigcss')
  fs.writeFileSync(oversized, 'x')
  fs.truncateSync(oversized, maximumBinaryBytes + 1)
  assert.throws(
    () => createReleaseArchive({
      binary: oversized,
      archive: path.join(directory, 'oversized.tar.gz'),
      sourceDateEpoch,
    }),
    /binary exceeds/,
  )
  assert.equal(fs.existsSync(path.join(directory, 'oversized.tar.gz')), false)
  assert.equal(maximumArchiveBytes, 2 * maximumBinaryBytes)
})

test('archive publication is create-only and cleans partial output failures', t => {
  const directory = temporaryDirectory(t, 'zigcss-release-exclusive-')
  const binary = writeBinary(directory, 'zigcss')
  const archive = path.join(directory, 'existing.tar.gz')
  fs.writeFileSync(archive, 'preserve me')
  assert.throws(
    () => createReleaseArchive({ binary, archive, sourceDateEpoch }),
    /created exclusively/,
  )
  assert.equal(fs.readFileSync(archive, 'utf8'), 'preserve me')

  const victim = path.join(directory, 'victim')
  const linkedArchive = path.join(directory, 'linked.tar.gz')
  fs.writeFileSync(victim, 'preserve victim')
  fs.symlinkSync(victim, linkedArchive)
  assert.throws(
    () => createReleaseArchive({ binary, archive: linkedArchive, sourceDateEpoch }),
    /created exclusively/,
  )
  assert.equal(fs.readFileSync(victim, 'utf8'), 'preserve victim')
  assert.equal(fs.lstatSync(linkedArchive).isSymbolicLink(), true)

  const partial = path.join(directory, 'partial.tar.gz')
  const originalWriteFileSync = fs.writeFileSync
  fs.writeFileSync = (target, bytes, ...rest) => {
    if (typeof target === 'number') {
      fs.writeSync(target, bytes.subarray(0, Math.min(bytes.length, 8)))
      throw new Error('injected partial write')
    }
    return originalWriteFileSync(target, bytes, ...rest)
  }
  try {
    assert.throws(
      () => createReleaseArchive({ binary, archive: partial, sourceDateEpoch }),
      /injected partial write/,
    )
  } finally {
    fs.writeFileSync = originalWriteFileSync
  }
  assert.equal(fs.existsSync(partial), false)
})
