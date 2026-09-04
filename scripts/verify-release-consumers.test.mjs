import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { createRequire } from 'node:module'
import { Readable } from 'node:stream'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { prepareReleaseContainer } from './prepare-release-container.mjs'
import {
  homebrewArchiveDownloadArguments,
  homebrewArchiveDownloadPolicy,
  parseHomebrewFormula,
} from './verify-homebrew-formula.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const activePackageVersion = JSON.parse(
  fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'),
).version
const require = createRequire(import.meta.url)
const installer = require(path.join(repositoryRoot, 'install.js'))
const https = require('node:https')

function archiveFilesystem({
  mode = 0o100755,
  resolved = '/usr/bin/tar',
  rootOwned = true,
  symbolicLink = false,
  regular = true,
} = {}) {
  return {
    accessSync() {},
    closeSync() {},
    fstatSync() {
      return this.lstatSync()
    },
    lstatSync() {
      return {
        ctimeMs: 4,
        dev: 1,
        ino: 2,
        isFile: () => regular,
        isSymbolicLink: () => symbolicLink,
        mode,
        mtimeMs: 3,
        size: 10,
        uid: rootOwned ? 0 : 501,
      }
    },
    openSync() {
      return 7
    },
    realpathSync() {
      return resolved
    },
  }
}

function windowsSystemFilesystem({
  executableName = 'tar.exe',
  redirected = undefined,
  redirectedAfter = undefined,
  replaced = undefined,
  symbolicLink = undefined,
  wrongType = undefined,
  emptyFile = false,
} = {}) {
  const locations = {
    root: 'D:\\Windows',
    system32: 'D:\\Windows\\System32',
    file: `D:\\Windows\\System32\\${executableName}`,
  }
  const redirects = {
    root: 'D:\\Redirected\\Windows',
    system32: 'D:\\Windows\\RedirectedSystem32',
    file: `D:\\Windows\\System32\\redirected-${executableName}`,
  }
  const realpathCalls = new Map()
  const lstatCalls = new Map()
  const key = value => path.win32.normalize(value.replace(/^\\\\\?\\/, '')).toLowerCase()
  const classify = value => Object.keys(locations).find(name => key(locations[name]) === key(value))
  const identity = (name, changed = false) => ({
    ctimeNs: 4n,
    dev: 1n,
    ino: BigInt({ root: 10, system32: 20, file: 30 }[name] + (changed ? 100 : 0)),
    isDirectory: () => name !== 'file' && wrongType !== name,
    isFile: () => name === 'file' && wrongType !== name,
    isSymbolicLink: () => symbolicLink === name,
    mode: BigInt(name === 'file' ? 0o100755 : 0o40755),
    mtimeNs: 3n,
    nlink: 1n,
    size: name === 'file' ? (emptyFile ? 0n : 4096n) : 0n,
  })
  return {
    accessSync(candidate) {
      assert.equal(classify(candidate), 'file')
    },
    closeSync(descriptor) {
      assert.equal(descriptor, 7)
    },
    fstatSync(descriptor) {
      assert.equal(descriptor, 7)
      return identity('file', replaced === 'opened-file')
    },
    lstatSync(candidate) {
      const name = classify(candidate)
      if (name === undefined) throw new Error(`unexpected lstat ${candidate}`)
      const calls = (lstatCalls.get(name) ?? 0) + 1
      lstatCalls.set(name, calls)
      return identity(name, replaced === name && calls > 1)
    },
    openSync(candidate) {
      assert.equal(classify(candidate), 'file')
      return 7
    },
    realpathSync(candidate) {
      const name = classify(candidate)
      if (name === undefined) throw new Error(`unexpected realpath ${candidate}`)
      const calls = (realpathCalls.get(name) ?? 0) + 1
      realpathCalls.set(name, calls)
      if (redirected === name || (redirectedAfter === name && calls > 1)) return redirects[name]
      return locations[name]
    },
  }
}

test('npm installation selects only finite verified absolute system archive readers', () => {
  if (process.platform === 'linux' || process.platform === 'darwin') {
    const executable = installer.archiveExecutable(process.platform)
    assert.equal(path.posix.isAbsolute(executable), true)
    assert.notEqual(executable, 'tar')
    const resolved = fs.realpathSync(executable)
    const stat = fs.lstatSync(resolved)
    assert.equal(stat.isFile(), true)
    assert.equal(stat.isSymbolicLink(), false)
    assert.equal(stat.uid, 0)
    assert.equal(stat.mode & 0o022, 0)
    assert.notEqual(stat.mode & 0o111, 0)
  }
  assert.equal(
    installer.archiveExecutable('linux', undefined, archiveFilesystem()),
    '/usr/bin/tar',
  )
  assert.equal(
    installer.archiveExecutable('darwin', undefined, archiveFilesystem({ resolved: '/usr/bin/bsdtar' })),
    '/usr/bin/tar',
  )
  assert.equal(
    installer.archiveExecutable('win32', 'D:\\Windows', windowsSystemFilesystem()),
    'D:\\Windows\\System32\\tar.exe',
  )
  assert.throws(() => installer.archiveExecutable('win32', undefined), /Windows system root/)
  assert.throws(() => installer.archiveExecutable('win32', '\\\\server\\Windows'), /Windows system root/)
  assert.throws(() => installer.archiveExecutable('win32', 'D:\\FakeRoot'), /Windows system root/)
  assert.throws(() => installer.archiveExecutable('win32', 'D:\\Nested\\Windows'), /Windows system root/)
  assert.throws(() => installer.archiveExecutable('freebsd'), /Unsupported archive platform/)
  for (const fileSystem of [
    archiveFilesystem({ resolved: '/tmp/tar' }),
    archiveFilesystem({ symbolicLink: true }),
    archiveFilesystem({ regular: false }),
    archiveFilesystem({ rootOwned: false }),
    archiveFilesystem({ mode: 0o100777 }),
    archiveFilesystem({ mode: 0o100644 }),
  ]) {
    assert.throws(
      () => installer.archiveExecutable('linux', undefined, fileSystem),
      /No trusted system tar executable/,
    )
  }
  for (const fileSystem of [
    windowsSystemFilesystem({ redirected: 'root' }),
    windowsSystemFilesystem({ redirected: 'system32' }),
    windowsSystemFilesystem({ redirected: 'file' }),
    windowsSystemFilesystem({ redirectedAfter: 'root' }),
    windowsSystemFilesystem({ redirectedAfter: 'system32' }),
    windowsSystemFilesystem({ redirectedAfter: 'file' }),
    windowsSystemFilesystem({ replaced: 'root' }),
    windowsSystemFilesystem({ replaced: 'system32' }),
    windowsSystemFilesystem({ replaced: 'file' }),
    windowsSystemFilesystem({ replaced: 'opened-file' }),
    windowsSystemFilesystem({ symbolicLink: 'root' }),
    windowsSystemFilesystem({ symbolicLink: 'system32' }),
    windowsSystemFilesystem({ symbolicLink: 'file' }),
    windowsSystemFilesystem({ wrongType: 'root' }),
    windowsSystemFilesystem({ wrongType: 'system32' }),
    windowsSystemFilesystem({ wrongType: 'file' }),
    windowsSystemFilesystem({ emptyFile: true }),
  ]) {
    assert.throws(
      () => installer.archiveExecutable('win32', 'D:\\Windows', fileSystem),
      /No trusted Windows system tar\.exe/,
    )
  }
})

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function elf(machine) {
  const binary = Buffer.alloc(64)
  binary.set([0x7f, 0x45, 0x4c, 0x46])
  binary[4] = 2
  binary[5] = 1
  binary.writeUInt16LE(machine, 18)
  return binary
}

function machO(cpu) {
  const binary = Buffer.alloc(32)
  binary.writeUInt32LE(0xfeedfacf, 0)
  binary.writeUInt32LE(cpu, 4)
  return binary
}

function pe(machine) {
  const binary = Buffer.alloc(256)
  binary.write('MZ', 0, 'ascii')
  binary.writeUInt32LE(0x80, 0x3c)
  binary.write('PE\0\0', 0x80, 'binary')
  binary.writeUInt16LE(machine, 0x84)
  return binary
}

function nativeIntegrityManifestText(version, digests = {}) {
  return `${JSON.stringify({
    schemaVersion: 1,
    package: 'zigcss',
    version,
    sourceDateEpoch: 1_700_000_000,
    archives: releaseTargets.map(policy => ({
      target: policy.target,
      filename: releaseAssetsFor(version, policy.target).archive,
      sha256: digests[policy.target] ?? '0'.repeat(64),
    })),
  }, null, 2)}\n`
}

function mockHttpsGet(responseFactory) {
  return (_url, _options, callback) => {
    const request = new EventEmitter()
    request.setTimeout = () => request
    request.destroy = error => queueMicrotask(() => request.emit('error', error))
    queueMicrotask(() => callback(responseFactory()))
    return request
  }
}

function makeArchive(temporary, archiveName, binary, extraEntry = false) {
  const staging = path.join(temporary, 'staging')
  fs.mkdirSync(staging)
  fs.writeFileSync(path.join(staging, 'zigcss'), binary, { mode: 0o755 })
  const entries = ['zigcss']
  if (extraEntry) {
    fs.writeFileSync(path.join(staging, 'unexpected.txt'), 'unexpected\n')
    entries.push('unexpected.txt')
  }

  const archive = path.join(temporary, archiveName)
  const result = spawnSync('tar', ['-czf', archive, '-C', staging, ...entries], {
    encoding: 'utf8',
  })
  assert.equal(result.error, undefined)
  assert.equal(result.status, 0, result.stderr)
  return archive
}

function makeInstallerFixture({
  binary = elf(62),
  extraEntry = false,
  manifestArchiveDigest = undefined,
  tamper = false,
} = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-consumer-'))
  const packageRoot = path.join(temporary, 'package')
  fs.mkdirSync(packageRoot)
  const assets = releaseAssetsFor('0.6.0-rc.2', 'x86_64-linux')
  const archive = makeArchive(temporary, assets.archive, binary, extraEntry)
  const archiveDigest = sha256(fs.readFileSync(archive))
  const sbom = Buffer.from('{"spdxVersion":"SPDX-2.3"}\n')
  const manifest = Buffer.from([
    `${manifestArchiveDigest ?? archiveDigest}  ${assets.archive}`,
    `${sha256(sbom)}  ${assets.sbom}`,
    '',
  ].join('\n'))
  if (tamper) fs.appendFileSync(archive, 'tamper')

  const downloads = new Map([
    [assets.archive, archive],
    [assets.checksums, manifest],
  ])
  const requested = []
  const downloadFile = async (url, destination, maximumBytes) => {
    const name = path.basename(new URL(url).pathname)
    requested.push({ name, maximumBytes })
    const source = downloads.get(name)
    assert.notEqual(source, undefined, `unexpected download ${url}`)
    if (Buffer.isBuffer(source)) {
      assert.ok(source.length <= maximumBytes)
      fs.writeFileSync(destination, source, { flag: 'wx', mode: 0o600 })
    } else {
      assert.ok(fs.statSync(source).size <= maximumBytes)
      fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL)
    }
  }

  return {
    assets,
    downloadFile,
    integrityManifestText: nativeIntegrityManifestText('0.6.0-rc.2', {
      'x86_64-linux': archiveDigest,
    }),
    packageRoot,
    requested,
    cleanup() {
      fs.rmSync(temporary, { recursive: true, force: true })
    },
  }
}

test('POSIX npm extraction ignores lifecycle PATH shadows and archive environment injection', {
  skip: process.platform === 'win32',
}, async () => {
  const fixture = makeInstallerFixture()
  const shadow = path.join(path.dirname(fixture.packageRoot), 'shadow-bin')
  const marker = path.join(path.dirname(fixture.packageRoot), 'shadow-executed')
  fs.mkdirSync(shadow)
  for (const name of ['tar', 'gzip']) {
    const executable = path.join(shadow, name)
    fs.writeFileSync(executable, `#!/bin/sh\nprintf shadow > ${JSON.stringify(marker)}\nexit 99\n`)
    fs.chmodSync(executable, 0o755)
  }
  const original = {
    GZIP: process.env.GZIP,
    PATH: process.env.PATH,
    TAR_OPTIONS: process.env.TAR_OPTIONS,
  }
  process.env.PATH = shadow
  process.env.GZIP = '--definitely-invalid-zigcss-option'
  process.env.TAR_OPTIONS = '--definitely-invalid-zigcss-option'
  try {
    await installer.install({
      version: '0.6.0-rc.2',
      platform: 'linux',
      arch: 'x64',
      packageRoot: fixture.packageRoot,
      downloadFile: fixture.downloadFile,
      integrityManifestText: fixture.integrityManifestText,
      log() {},
    })
    assert.equal(fs.existsSync(marker), false)
    assert.deepEqual(
      fs.readFileSync(path.join(fixture.packageRoot, 'bin', 'zigcss')),
      elf(62),
    )
  } finally {
    for (const [name, value] of Object.entries(original)) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
    fixture.cleanup()
  }
})

test('archive extraction escalates SIGTERM to bounded SIGKILL and removes partial output', {
  skip: process.platform === 'win32',
}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-extractor-timeout-'))
  try {
    const script = path.join(temporary, 'ignore-term.cjs')
    const pidFile = path.join(temporary, 'pid')
    const termFile = path.join(temporary, 'term')
    const archive = path.join(temporary, 'fixture.tar.gz')
    const destination = path.join(temporary, 'partial')
    fs.writeFileSync(archive, 'fixture')
    fs.writeFileSync(script, [
      "const fs = require('node:fs')",
      'fs.writeFileSync(process.argv[2], String(process.pid))',
      "process.on('SIGTERM', () => fs.writeFileSync(process.argv[3], 'term'))",
      "process.stdout.write('partial-output')",
      'setInterval(() => {}, 1_000)',
      '',
    ].join('\n'))
    let observed
    const started = Date.now()
    await assert.rejects(
      installer.runArchiveExtractor('/usr/bin/tar', archive, destination, 'zigcss', {
        forceKillWaitMs: 500,
        spawnProcess(_executable, _args, options) {
          observed = options
          return spawn(process.execPath, [script, pidFile, termFile], options)
        },
        terminationGraceMs: 100,
        timeoutMs: 300,
      }),
      /Archive extraction timed out after 300 ms/,
    )
    assert.ok(Date.now() - started < 2_000)
    assert.equal(observed.cwd, temporary)
    assert.deepEqual(observed.env, { LANG: 'C', LC_ALL: 'C', PATH: '/usr/bin:/bin' })
    assert.equal(fs.readFileSync(termFile, 'utf8'), 'term')
    assert.equal(fs.existsSync(destination), false)
    const pid = Number(fs.readFileSync(pidFile, 'utf8'))
    assert.throws(() => process.kill(pid, 0), error => error?.code === 'ESRCH')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

function makeContainerFixture({
  target = 'x86_64-linux',
  binary = target === 'aarch64-linux' ? elf(183) : elf(62),
  extraEntry = false,
  tamper = false,
  tamperSbom = false,
} = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-container-'))
  const assetsRoot = path.join(temporary, 'release-assets')
  fs.mkdirSync(assetsRoot)
  fs.writeFileSync(path.join(temporary, 'package.json'), '{"version":"0.6.0-rc.2"}\n')

  const assets = releaseAssetsFor('0.6.0-rc.2', target)
  const archive = makeArchive(temporary, assets.archive, binary, extraEntry)
  const confinedArchive = path.join(assetsRoot, assets.archive)
  fs.renameSync(archive, confinedArchive)
  const archiveDigest = sha256(fs.readFileSync(confinedArchive))
  const sbom = Buffer.from('{"spdxVersion":"SPDX-2.3"}\n')
  const manifest = [
    `${archiveDigest}  ${assets.archive}`,
    `${sha256(sbom)}  ${assets.sbom}`,
    '',
  ].join('\n')
  fs.writeFileSync(path.join(assetsRoot, assets.sbom), sbom)
  fs.writeFileSync(path.join(assetsRoot, assets.checksums), manifest)
  fs.writeFileSync(path.join(assetsRoot, assets.provenanceBundle), '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n')
  fs.writeFileSync(path.join(assetsRoot, assets.sbomBundle), '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n')
  if (tamper) fs.appendFileSync(confinedArchive, 'tamper')
  if (tamperSbom) fs.appendFileSync(path.join(assetsRoot, assets.sbom), 'tamper')

  return {
    assets,
    assetsRoot,
    binary,
    integrityManifestText: nativeIntegrityManifestText('0.6.0-rc.2', {
      [target]: archiveDigest,
    }),
    outputDirectory: 'container-root',
    root: temporary,
    target,
    cleanup() {
      fs.rmSync(temporary, { recursive: true, force: true })
    },
  }
}

test('npm installer derives exactly the release workflow asset contract', () => {
  const nodePlatforms = new Map([
    ['x86_64-linux', ['linux', 'x64']],
    ['aarch64-linux', ['linux', 'arm64']],
    ['x86_64-macos', ['darwin', 'x64']],
    ['aarch64-macos', ['darwin', 'arm64']],
    ['x86_64-windows', ['win32', 'x64']],
  ])

  for (const policy of releaseTargets) {
    const [platform, arch] = nodePlatforms.get(policy.target)
    const descriptor = installer.releaseDescriptor('0.6.0-rc.2', platform, arch)
    assert.equal(descriptor.target, policy.target)
    assert.equal(descriptor.binaryName, policy.binaryName)
    assert.deepEqual(descriptor.assets, releaseAssetsFor('0.6.0-rc.2', policy.target))
    assert.equal(
      descriptor.archiveUrl,
      `https://github.com/vyakymenko/zigcss/releases/download/v0.6.0-rc.2/${descriptor.assets.archive}`,
    )
  }

  for (const [platform, arch] of [['win32', 'arm64'], ['linux', 'ia32'], ['freebsd', 'x64']]) {
    assert.throws(
      () => installer.releaseDescriptor('0.6.0-rc.2', platform, arch),
      /Unsupported platform and architecture/,
    )
  }
  assert.throws(() => installer.releaseDescriptor('../release', 'linux', 'x64'), /canonical Semantic Versioning/)
})

test('npm installer accepts only the exact release checksum manifest', () => {
  const assets = releaseAssetsFor('0.6.0-rc.2', 'x86_64-linux')
  const archiveDigest = 'a'.repeat(64)
  const sbomDigest = 'b'.repeat(64)
  const valid = `${archiveDigest}  ${assets.archive}\n${sbomDigest}  ${assets.sbom}\n`
  assert.equal(
    installer.parseChecksumManifest(valid, assets.archive, assets.sbom),
    archiveDigest,
  )

  for (const invalid of [
    `${archiveDigest} ${assets.archive}\n${sbomDigest}  ${assets.sbom}\n`,
    `${archiveDigest.toUpperCase()}  ${assets.archive}\n${sbomDigest}  ${assets.sbom}\n`,
    `${archiveDigest}  ../${assets.archive}\n${sbomDigest}  ${assets.sbom}\n`,
    `${archiveDigest}  ${assets.archive}\n`,
    `${archiveDigest}  ${assets.archive}\n${sbomDigest}  ${assets.sbom}\n${archiveDigest}  extra\n`,
  ]) {
    assert.throws(
      () => installer.parseChecksumManifest(invalid, assets.archive, assets.sbom),
      /checksum manifest/,
    )
  }
})

test('npm package binds every native archive to one exact version and digest inventory', () => {
  const version = '0.6.0-rc.2'
  const descriptor = installer.releaseDescriptor(version, 'linux', 'x64')
  const digest = 'a'.repeat(64)
  const valid = nativeIntegrityManifestText(version, { 'x86_64-linux': digest })
  assert.equal(installer.parseNativeIntegrityManifest(valid, descriptor), digest)

  const parsed = JSON.parse(valid)
  const invalid = [
    { ...parsed, extra: true },
    { ...parsed, schemaVersion: 2 },
    { ...parsed, package: 'other' },
    { ...parsed, version: '0.6.0' },
    { ...parsed, sourceDateEpoch: -1 },
    { ...parsed, sourceDateEpoch: 0x1_0000_0000 },
    { ...parsed, sourceDateEpoch: 1.5 },
    { ...parsed, sourceDateEpoch: '1700000000' },
    { ...parsed, archives: parsed.archives.slice(0, -1) },
    { ...parsed, archives: [parsed.archives[1], parsed.archives[0], ...parsed.archives.slice(2)] },
    { ...parsed, archives: parsed.archives.map((entry, index) => index === 0 ? { ...entry, filename: 'other.tar.gz' } : entry) },
    { ...parsed, archives: parsed.archives.map((entry, index) => index === 0 ? { ...entry, target: 'other' } : entry) },
    { ...parsed, archives: parsed.archives.map((entry, index) => index === 0 ? { ...entry, sha256: entry.sha256.toUpperCase() } : entry) },
    { ...parsed, archives: parsed.archives.map((entry, index) => index === 0 ? { ...entry, extra: true } : entry) },
  ]
  for (const value of invalid) {
    assert.throws(
      () => installer.parseNativeIntegrityManifest(`${JSON.stringify(value)}\n`, descriptor),
      /native integrity/,
    )
  }

  const current = installer.readNativeIntegrityManifest()
  for (const [platform, arch] of [['linux', 'x64'], ['linux', 'arm64'], ['darwin', 'x64'], ['darwin', 'arm64'], ['win32', 'x64']]) {
    const release = installer.releaseDescriptor(activePackageVersion, platform, arch)
    assert.match(installer.parseNativeIntegrityManifest(current, release), /^[0-9a-f]{64}$/)
  }
})

test('npm installer rejects same-origin checksum substitution before downloading an archive', async () => {
  const fixture = makeInstallerFixture({ manifestArchiveDigest: 'f'.repeat(64) })
  try {
    await assert.rejects(
      installer.install({
        version: '0.6.0-rc.2',
        platform: 'linux',
        arch: 'x64',
        packageRoot: fixture.packageRoot,
        downloadFile: fixture.downloadFile,
        integrityManifestText: fixture.integrityManifestText,
        log() {},
      }),
      /independently published npm package digest/,
    )
    assert.deepEqual(fixture.requested.map(item => item.name), [fixture.assets.checksums])
    assert.deepEqual(fs.readdirSync(path.join(fixture.packageRoot, 'bin')), [])
  } finally {
    fixture.cleanup()
  }
})

test('npm installer reads its trust manifest only from a bounded regular stable UTF-8 file', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-installer-integrity-'))
  try {
    const valid = path.join(temporary, 'valid.json')
    const source = nativeIntegrityManifestText('0.6.0-rc.2')
    fs.writeFileSync(valid, source)
    assert.equal(installer.readNativeIntegrityManifest(valid), source)

    const link = path.join(temporary, 'link.json')
    fs.symlinkSync(valid, link)
    assert.throws(() => installer.readNativeIntegrityManifest(link), /regular non-symlink file/)

    const invalidUtf8 = path.join(temporary, 'invalid-utf8.json')
    fs.writeFileSync(invalidUtf8, Buffer.from([0xff, 0xfe]))
    assert.throws(() => installer.readNativeIntegrityManifest(invalidUtf8), /valid UTF-8/)

    const oversized = path.join(temporary, 'oversized.json')
    fs.writeFileSync(oversized, Buffer.alloc(installer.installLimits.maximumManifestBytes + 1, 0x20))
    assert.throws(() => installer.readNativeIntegrityManifest(oversized), /must contain 1 through/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm installer verifies checksum and target before atomic replacement', async () => {
  const fixture = makeInstallerFixture()
  try {
    const binDirectory = path.join(fixture.packageRoot, 'bin')
    fs.mkdirSync(binDirectory)
    const installed = path.join(binDirectory, 'zigcss')
    fs.writeFileSync(installed, 'old binary\n')

    const result = await installer.install({
      version: '0.6.0-rc.2',
      platform: 'linux',
      arch: 'x64',
      packageRoot: fixture.packageRoot,
      downloadFile: fixture.downloadFile,
      integrityManifestText: fixture.integrityManifestText,
      log() {},
    })

    assert.equal(result.target, 'x86_64-linux')
    assert.deepEqual(fixture.requested.map(item => item.name), [
      fixture.assets.checksums,
      fixture.assets.archive,
    ])
    assert.deepEqual(fs.readFileSync(installed), elf(62))
    assert.equal(fs.statSync(installed).mode & 0o111, 0o111)
    assert.deepEqual(fs.readdirSync(binDirectory), ['zigcss'])
  } finally {
    fixture.cleanup()
  }
})

test('npm installer preserves an existing binary and cleans temporary files on checksum failure', async () => {
  const fixture = makeInstallerFixture({ tamper: true })
  try {
    const binDirectory = path.join(fixture.packageRoot, 'bin')
    fs.mkdirSync(binDirectory)
    const installed = path.join(binDirectory, 'zigcss')
    fs.writeFileSync(installed, 'keep me\n')

    await assert.rejects(
      installer.install({
        version: '0.6.0-rc.2',
        platform: 'linux',
        arch: 'x64',
        packageRoot: fixture.packageRoot,
        downloadFile: fixture.downloadFile,
        integrityManifestText: fixture.integrityManifestText,
        log() {},
      }),
      /archive checksum does not match/,
    )
    assert.equal(fs.readFileSync(installed, 'utf8'), 'keep me\n')
    assert.deepEqual(fs.readdirSync(binDirectory), ['zigcss'])
  } finally {
    fixture.cleanup()
  }
})

test('npm installer rejects wrong-target and multi-entry archives before replacement', async () => {
  for (const options of [{ binary: elf(183) }, { extraEntry: true }]) {
    const fixture = makeInstallerFixture(options)
    try {
      const binDirectory = path.join(fixture.packageRoot, 'bin')
      fs.mkdirSync(binDirectory)
      const installed = path.join(binDirectory, 'zigcss')
      fs.writeFileSync(installed, 'keep me\n')

      await assert.rejects(
        installer.install({
          version: '0.6.0-rc.2',
          platform: 'linux',
          arch: 'x64',
          packageRoot: fixture.packageRoot,
          downloadFile: fixture.downloadFile,
          integrityManifestText: fixture.integrityManifestText,
          log() {},
        }),
        /(?:does not match target|archive must contain exactly)/,
      )
      assert.equal(fs.readFileSync(installed, 'utf8'), 'keep me\n')
      assert.deepEqual(fs.readdirSync(binDirectory), ['zigcss'])
    } finally {
      fixture.cleanup()
    }
  }
})

test('npm installer download policy is HTTPS-only, bounded, and credential-free', () => {
  assert.equal(
    installer.validateDownloadUrl('https://github.com/vyakymenko/zigcss/releases/download/v1/a'),
    'https://github.com/vyakymenko/zigcss/releases/download/v1/a',
  )
  for (const invalid of [
    'http://github.com/vyakymenko/zigcss/releases/download/v1/a',
    'https://user:secret@github.com/vyakymenko/zigcss/releases/download/v1/a',
    'https://github.com/vyakymenko/zigcss/releases/download/v1/a#fragment',
  ]) {
    assert.throws(() => installer.validateDownloadUrl(invalid), /download URL/)
  }
  assert.equal(installer.installLimits.maximumRedirects, 5)
  assert.equal(installer.installLimits.maximumArchiveBytes, 512 * 1024 * 1024)
  assert.ok(installer.installLimits.downloadDeadlineMs > installer.installLimits.requestTimeoutMs)
  assert.ok(installer.installLimits.requestTimeoutMs > 0)
})

test('npm installer enforces streamed download limits and removes partial files', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-download-policy-'))
  const originalGet = https.get
  try {
    const success = path.join(temporary, 'success')
    https.get = mockHttpsGet(() => Object.assign(Readable.from([Buffer.from('asset')]), {
      statusCode: 200,
      headers: { 'content-length': '5' },
    }))
    await installer.boundedDownload('https://example.test/asset', success, 5)
    assert.equal(fs.readFileSync(success, 'utf8'), 'asset')

    const oversized = path.join(temporary, 'oversized')
    https.get = mockHttpsGet(() => Object.assign(Readable.from([Buffer.from('four')]), {
      statusCode: 200,
      headers: {},
    }))
    await assert.rejects(
      installer.boundedDownload('https://example.test/asset', oversized, 3),
      /exceeds 3 bytes/,
    )
    assert.equal(fs.existsSync(oversized), false)

    const redirected = path.join(temporary, 'redirected')
    https.get = mockHttpsGet(() => Object.assign(Readable.from([]), {
      statusCode: 302,
      headers: { location: 'http://example.test/insecure' },
    }))
    await assert.rejects(
      installer.boundedDownload('https://example.test/asset', redirected, 3),
      /must use HTTPS/,
    )
    assert.equal(fs.existsSync(redirected), false)
  } finally {
    https.get = originalGet
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm installer enforces one total deadline across the complete download', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-download-deadline-'))
  const destination = path.join(temporary, 'partial')
  const originalGet = https.get
  try {
    https.get = (_url, _options, callback) => {
      const request = new EventEmitter()
      const response = Object.assign(new Readable({ read() {} }), {
        statusCode: 200,
        headers: {},
      })
      request.setTimeout = () => request
      request.destroy = error => {
        response.destroy(error)
        queueMicrotask(() => request.emit('error', error))
      }
      queueMicrotask(() => callback(response))
      return request
    }

    await assert.rejects(
      installer.boundedDownload(
        'https://example.test/slow-asset',
        destination,
        1024,
        { deadlineMs: 5 },
      ),
      /5 ms total deadline/,
    )
    assert.equal(fs.existsSync(destination), false)
    await assert.rejects(
      installer.boundedDownload('https://example.test/asset', destination, 1, { deadlineMs: 0 }),
      /download deadline/,
    )
    await assert.rejects(
      installer.boundedDownload('https://example.test/asset', destination, 1, []),
      /download options/,
    )
  } finally {
    https.get = originalGet
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm installer independently validates all five executable target headers', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-installer-targets-'))
  try {
    const fixtures = [
      ['x86_64-linux', elf(62)],
      ['aarch64-linux', elf(183)],
      ['x86_64-macos', machO(0x01000007)],
      ['aarch64-macos', machO(0x0100000c)],
      ['x86_64-windows', pe(0x8664)],
    ]
    for (const [target, bytes] of fixtures) {
      const filename = path.join(temporary, target)
      fs.writeFileSync(filename, bytes)
      assert.equal(installer.assertBinaryMatchesTarget(filename, target).arch, target.split('-')[0])
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm installer rejects a symlinked binary directory before downloading', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-installer-symlink-'))
  const packageRoot = path.join(temporary, 'package')
  const outside = path.join(temporary, 'outside')
  try {
    fs.mkdirSync(packageRoot)
    fs.mkdirSync(outside)
    fs.symlinkSync(outside, path.join(packageRoot, 'bin'))
    await assert.rejects(
      installer.install({
        version: '0.6.0-rc.2',
        platform: 'linux',
        arch: 'x64',
        packageRoot,
        integrityManifestText: nativeIntegrityManifestText('0.6.0-rc.2'),
        async downloadFile() {
          assert.fail('download must not begin through a symlinked binary directory')
        },
        log() {},
      }),
      /regular non-symlink directory/,
    )
    assert.deepEqual(fs.readdirSync(outside), [])
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('Homebrew formula pins immutable verified source and the supported Zig toolchain', () => {
  const formula = fs.readFileSync(path.join(repositoryRoot, 'Formula/zigcss.rb'), 'utf8')
  assert.deepEqual(parseHomebrewFormula(formula), {
    digest: '059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010',
    sourceCommit: '6786655d66ca65c5a06421c8ed70d84183722dce',
    url: 'https://github.com/vyakymenko/zigcss/archive/6786655d66ca65c5a06421c8ed70d84183722dce.tar.gz',
    version: '0.6.0',
  })
  assert.match(
    formula,
    /^  url "https:\/\/github\.com\/vyakymenko\/zigcss\/archive\/6786655d66ca65c5a06421c8ed70d84183722dce\.tar\.gz"$/m,
  )
  assert.match(formula, /^  version "0\.6\.0"$/m)
  assert.match(formula, /^  sha256 "059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010"$/m)
  assert.match(formula, /^  depends_on "zig@0\.15" => :build$/m)
  assert.match(
    formula,
    /^    system formula_opt_bin\("zig@0\.15"\)\/"zig", "build", "-Doptimize=ReleaseFast"$/m,
  )
  assert.match(formula, /assert_equal "zigcss #\{version\}\\n", shell_output\("#\{bin\}\/zigcss --version"\)/)
  assert.match(formula, /assert_equal "\.test\{color:red\}", shell_output\("#\{bin\}\/zigcss test\.css --minify"\)/)
  assert.doesNotMatch(formula, /^  head /m)
  assert.doesNotMatch(formula, /^  sha256 ""$/m)
})

test('Homebrew source download is hermetic, bounded, and retryable', () => {
  assert.deepEqual(homebrewArchiveDownloadPolicy, {
    attempts: 5,
    connectTimeoutSeconds: 10,
    maximumArchiveBytes: 64 * 1024 * 1024,
    requestTimeoutSeconds: 60,
    retryDelaySeconds: 1,
    retryWindowSeconds: 240,
  })
  assert.deepEqual(homebrewArchiveDownloadArguments('/tmp/source.tar.gz', 'https://github.com/example/archive.tar.gz'), [
    '--disable',
    '--fail',
    '--location',
    '--silent',
    '--show-error',
    '--proto', '=https',
    '--proto-redir', '=https',
    '--max-redirs', '5',
    '--connect-timeout', '10',
    '--max-time', '60',
    '--retry', '4',
    '--retry-all-errors',
    '--retry-delay', '1',
    '--retry-max-time', '240',
    '--remove-on-error',
    '--max-filesize', String(64 * 1024 * 1024),
    '--output', '/tmp/source.tar.gz',
    'https://github.com/example/archive.tar.gz',
  ])
})

test('Homebrew formula policy rejects mutable sources, missing trust data, and second downloads', () => {
  const formula = fs.readFileSync(path.join(repositoryRoot, 'Formula/zigcss.rb'), 'utf8')
  const invalid = [
    [
      formula.replace('archive/6786655d66ca65c5a06421c8ed70d84183722dce.tar.gz', 'archive/v0.6.0.tar.gz'),
      /full lowercase commit identity/,
    ],
    [
      formula.replace('sha256 "059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010"', 'sha256 ""'),
      /source SHA-256 must occur exactly once/,
    ],
    [formula.replace('6786655d66ca65c5a06421c8ed70d84183722dce', '0'.repeat(40)), /stable source commit/],
    [formula.replace('version "0.6.0"', 'version "0.6.1"'), /stable source version/],
    [
      formula.replace('059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010', '0'.repeat(64)),
      /stable source archive SHA-256/,
    ],
    [formula.replace('  license "MIT"', '  license "MIT"\n  head "https://github.com/vyakymenko/zigcss.git"'), /unverified head build/],
    [formula.replace('depends_on "zig@0.15"', 'depends_on "zig"'), /Zig 0.15 build dependency/],
    [
      formula.replace('formula_opt_bin("zig@0.15")/"zig"', 'Formula["zig@0.15"].opt_bin/"zig"'),
      /toolchain-pinned build command/,
    ],
    [formula.replace('  def install', '  def install\n    system "curl", "https://example.invalid/binary"'), /second download/],
  ]
  for (const [source, expression] of invalid) assert.throws(() => parseHomebrewFormula(source), expression)
})

test('npm package runs one installer lifecycle and CI gates it before dependency installation', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  assert.equal(manifest.scripts.install, undefined)
  assert.equal(manifest.scripts.postinstall, 'node install.js')
  assert.equal(manifest.scripts['test:release-smoke'], 'node --test scripts/smoke-release-artifact.test.mjs')
  assert.equal(manifest.scripts['test:release-consumers'], 'node --test scripts/verify-release-consumers.test.mjs')
  assert.equal(manifest.scripts['test:release-container'], 'node scripts/test-release-container.mjs')
  assert.equal(manifest.scripts['test:release-homebrew'], 'node scripts/verify-homebrew-formula.mjs --smoke')
  assert.equal(manifest.scripts['test:node-api'], 'node --test scripts/verify-node-api.test.mjs')

  const workflow = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const metadataTests = workflow.indexOf('npm run test:release-metadata')
  const integrityTests = workflow.indexOf('node --test scripts/validate-native-integrity.test.mjs', metadataTests)
  const metadataCheck = workflow.indexOf('npm run check:release-metadata', integrityTests)
  const integrityCheck = workflow.indexOf('node scripts/validate-native-integrity.mjs --check', metadataCheck)
  const npmPublication = workflow.indexOf('npm run test:npm-publication', integrityCheck)
  const smoke = workflow.indexOf('npm run test:release-smoke', npmPublication)
  const consumers = workflow.indexOf('npm run test:release-consumers', smoke)
  const container = workflow.indexOf('npm run test:release-container', consumers)
  const homebrew = workflow.indexOf('npm run test:release-homebrew', container)
  const nodeApi = workflow.indexOf('npm run test:node-api', homebrew)
  const install = workflow.indexOf('npm ci --ignore-scripts', nodeApi)
  assert.ok(metadataTests >= 0)
  assert.ok(integrityTests > metadataTests)
  assert.ok(metadataCheck > integrityTests)
  assert.ok(integrityCheck > metadataCheck)
  assert.ok(npmPublication > integrityCheck)
  assert.ok(smoke > npmPublication)
  assert.ok(consumers > smoke)
  assert.ok(container > consumers)
  assert.ok(homebrew > container)
  assert.ok(nodeApi > homebrew)
  assert.ok(install > nodeApi)
  assert.equal(workflow.indexOf('npm run test:release-consumers', consumers + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-smoke', smoke + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-container', container + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-homebrew', homebrew + 1), -1)
  assert.equal(workflow.indexOf('npm run test:node-api', nodeApi + 1), -1)
})

test('release container preparation verifies and confines a local Linux archive', async () => {
  const fixture = makeContainerFixture()
  try {
    const result = await prepareReleaseContainer({
      root: fixture.root,
      outputDirectory: fixture.outputDirectory,
      target: fixture.target,
      version: '0.6.0-rc.2',
      integrityManifestText: fixture.integrityManifestText,
    })
    assert.equal(result.target, fixture.target)
    assert.equal(result.version, '0.6.0-rc.2')
    assert.deepEqual(fs.readFileSync(result.binary), fixture.binary)
    assert.equal(fs.statSync(result.binary).mode & 0o777, 0o555)
    assert.deepEqual(fs.readdirSync(path.join(fixture.root, fixture.outputDirectory)), ['bin'])
    assert.deepEqual(fs.readdirSync(path.dirname(result.binary)), ['zigcss'])
  } finally {
    fixture.cleanup()
  }
})

test('release container preparation removes output after trust failures', async () => {
  for (const options of [
    { tamper: true },
    { tamperSbom: true },
    { target: 'aarch64-linux', binary: elf(62) },
    { extraEntry: true },
  ]) {
    const fixture = makeContainerFixture(options)
    try {
      await assert.rejects(
        prepareReleaseContainer({
          root: fixture.root,
          outputDirectory: fixture.outputDirectory,
          target: fixture.target,
          version: '0.6.0-rc.2',
          integrityManifestText: fixture.integrityManifestText,
        }),
        /(?:checksum does not match|does not match target|archive must contain exactly)/,
      )
      assert.equal(fs.existsSync(path.join(fixture.root, fixture.outputDirectory)), false)
    } finally {
      fixture.cleanup()
    }
  }
})

test('release container preparation rejects inventory drift and symlink substitution before output', async () => {
  for (const mode of ['extra', 'missing', 'symlink']) {
    const fixture = makeContainerFixture()
    try {
      if (mode === 'extra') {
        fs.writeFileSync(path.join(fixture.assetsRoot, 'unreviewed'), 'asset\n')
      } else if (mode === 'missing') {
        fs.rmSync(path.join(fixture.assetsRoot, fixture.assets.sbomBundle))
      } else {
        const manifest = path.join(fixture.assetsRoot, fixture.assets.checksums)
        const outside = path.join(fixture.root, 'outside.sha256')
        fs.renameSync(manifest, outside)
        fs.symlinkSync(outside, manifest)
      }
      await assert.rejects(
        prepareReleaseContainer({
          root: fixture.root,
          outputDirectory: fixture.outputDirectory,
          target: fixture.target,
          version: '0.6.0-rc.2',
          integrityManifestText: fixture.integrityManifestText,
        }),
        /(?:must contain exactly|is unavailable|regular non-symlink file)/,
      )
      assert.equal(fs.existsSync(path.join(fixture.root, fixture.outputDirectory)), false)
    } finally {
      fixture.cleanup()
    }
  }
})

test('release Dockerfile copies only a locally verified binary into a non-root scratch image', () => {
  const dockerfile = fs.readFileSync(path.join(repositoryRoot, 'Dockerfile.release'), 'utf8')
  assert.match(
    dockerfile,
    /^# syntax=docker\/dockerfile:1\.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e$/m,
  )
  assert.match(dockerfile, /^FROM node:22-alpine@sha256:[0-9a-f]{64} AS verifier$/m)
  assert.match(dockerfile, /linux\/amd64\) zigcss_target=x86_64-linux/)
  assert.match(dockerfile, /linux\/arm64\) zigcss_target=aarch64-linux/)
  assert.match(dockerfile, /^COPY package\.json install\.js native-integrity\.json \.\/$/m)
  assert.match(dockerfile, /node scripts\/prepare-release-container\.mjs/)
  assert.match(dockerfile, /^FROM scratch AS runtime$/m)
  assert.match(dockerfile, /^COPY --from=verifier --chmod=0555 \/verify\/container-root\/bin\/zigcss \/usr\/local\/bin\/zigcss$/m)
  assert.match(dockerfile, /^USER 65532:65532$/m)
  assert.match(dockerfile, /^ENTRYPOINT \["\/usr\/local\/bin\/zigcss"\]$/m)
  assert.doesNotMatch(dockerfile, /\b(?:curl|wget|zig build)\b|ADD https?:/)
})
