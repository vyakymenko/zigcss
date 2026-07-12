import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { createRequire } from 'node:module'
import { Readable } from 'node:stream'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { prepareReleaseContainer } from './prepare-release-container.mjs'
import { parseHomebrewFormula } from './verify-homebrew-formula.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const require = createRequire(import.meta.url)
const installer = require(path.join(repositoryRoot, 'install.js'))
const https = require('node:https')

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

function makeInstallerFixture({ binary = elf(62), extraEntry = false, tamper = false } = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-consumer-'))
  const packageRoot = path.join(temporary, 'package')
  fs.mkdirSync(packageRoot)
  const assets = releaseAssetsFor('0.4.0-rc.1', 'x86_64-linux')
  const archive = makeArchive(temporary, assets.archive, binary, extraEntry)
  const sbom = Buffer.from('{"spdxVersion":"SPDX-2.3"}\n')
  const manifest = Buffer.from([
    `${sha256(fs.readFileSync(archive))}  ${assets.archive}`,
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
    packageRoot,
    requested,
    cleanup() {
      fs.rmSync(temporary, { recursive: true, force: true })
    },
  }
}

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
  fs.writeFileSync(path.join(temporary, 'package.json'), '{"version":"0.4.0-rc.1"}\n')

  const assets = releaseAssetsFor('0.4.0-rc.1', target)
  const archive = makeArchive(temporary, assets.archive, binary, extraEntry)
  const confinedArchive = path.join(assetsRoot, assets.archive)
  fs.renameSync(archive, confinedArchive)
  const sbom = Buffer.from('{"spdxVersion":"SPDX-2.3"}\n')
  const manifest = [
    `${sha256(fs.readFileSync(confinedArchive))}  ${assets.archive}`,
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
    const descriptor = installer.releaseDescriptor('0.4.0-rc.1', platform, arch)
    assert.equal(descriptor.target, policy.target)
    assert.equal(descriptor.binaryName, policy.binaryName)
    assert.deepEqual(descriptor.assets, releaseAssetsFor('0.4.0-rc.1', policy.target))
    assert.equal(
      descriptor.archiveUrl,
      `https://github.com/vyakymenko/zigcss/releases/download/v0.4.0-rc.1/${descriptor.assets.archive}`,
    )
  }

  for (const [platform, arch] of [['win32', 'arm64'], ['linux', 'ia32'], ['freebsd', 'x64']]) {
    assert.throws(
      () => installer.releaseDescriptor('0.4.0-rc.1', platform, arch),
      /Unsupported platform and architecture/,
    )
  }
  assert.throws(() => installer.releaseDescriptor('../release', 'linux', 'x64'), /canonical Semantic Versioning/)
})

test('npm installer accepts only the exact release checksum manifest', () => {
  const assets = releaseAssetsFor('0.4.0-rc.1', 'x86_64-linux')
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

test('npm installer verifies checksum and target before atomic replacement', async () => {
  const fixture = makeInstallerFixture()
  try {
    const binDirectory = path.join(fixture.packageRoot, 'bin')
    fs.mkdirSync(binDirectory)
    const installed = path.join(binDirectory, 'zigcss')
    fs.writeFileSync(installed, 'old binary\n')

    const result = await installer.install({
      version: '0.4.0-rc.1',
      platform: 'linux',
      arch: 'x64',
      packageRoot: fixture.packageRoot,
      downloadFile: fixture.downloadFile,
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
        version: '0.4.0-rc.1',
        platform: 'linux',
        arch: 'x64',
        packageRoot: fixture.packageRoot,
        downloadFile: fixture.downloadFile,
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
          version: '0.4.0-rc.1',
          platform: 'linux',
          arch: 'x64',
          packageRoot: fixture.packageRoot,
          downloadFile: fixture.downloadFile,
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
        version: '0.4.0-rc.1',
        platform: 'linux',
        arch: 'x64',
        packageRoot,
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
    digest: '2fc630a41af5b5fef1d1e4db551604deac048c1b02ff249d5abbb061ebd5c906',
    sourceCommit: '3fada2359ab1fa262b782a33e9ab2a7bab2c46ca',
    url: 'https://github.com/vyakymenko/zigcss/archive/3fada2359ab1fa262b782a33e9ab2a7bab2c46ca.tar.gz',
    version: '0.4.0-rc.1',
  })
  assert.match(
    formula,
    /^  url "https:\/\/github\.com\/vyakymenko\/zigcss\/archive\/3fada2359ab1fa262b782a33e9ab2a7bab2c46ca\.tar\.gz"$/m,
  )
  assert.match(formula, /^  version "0\.4\.0-rc\.1"$/m)
  assert.match(formula, /^  sha256 "2fc630a41af5b5fef1d1e4db551604deac048c1b02ff249d5abbb061ebd5c906"$/m)
  assert.match(formula, /^  depends_on "zig@0\.15" => :build$/m)
  assert.match(
    formula,
    /^    system Formula\["zig@0\.15"\]\.opt_bin\/"zig", "build", "-Doptimize=ReleaseFast"$/m,
  )
  assert.match(formula, /assert_equal "zigcss #\{version\}\\n", shell_output\("#\{bin\}\/zigcss --version"\)/)
  assert.match(formula, /assert_equal "\.test\{color:red\}", shell_output\("#\{bin\}\/zigcss test\.css --minify"\)/)
  assert.doesNotMatch(formula, /^  head /m)
  assert.doesNotMatch(formula, /^  sha256 ""$/m)
})

test('Homebrew formula policy rejects mutable sources, missing trust data, and second downloads', () => {
  const formula = fs.readFileSync(path.join(repositoryRoot, 'Formula/zigcss.rb'), 'utf8')
  const invalid = [
    [
      formula.replace('archive/3fada2359ab1fa262b782a33e9ab2a7bab2c46ca.tar.gz', 'archive/v0.4.0-rc.1.tar.gz'),
      /full lowercase commit identity/,
    ],
    [
      formula.replace('sha256 "2fc630a41af5b5fef1d1e4db551604deac048c1b02ff249d5abbb061ebd5c906"', 'sha256 ""'),
      /source SHA-256 must occur exactly once/,
    ],
    [formula.replace('  license "MIT"', '  license "MIT"\n  head "https://github.com/vyakymenko/zigcss.git"'), /unverified head build/],
    [formula.replace('depends_on "zig@0.15"', 'depends_on "zig"'), /Zig 0.15 build dependency/],
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

  const workflow = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const metadata = workflow.indexOf('npm run test:release-metadata && npm run check:release-metadata')
  const smoke = workflow.indexOf('npm run test:release-smoke', metadata)
  const consumers = workflow.indexOf('npm run test:release-consumers', smoke)
  const container = workflow.indexOf('npm run test:release-container', consumers)
  const homebrew = workflow.indexOf('npm run test:release-homebrew', container)
  const install = workflow.indexOf('npm ci --ignore-scripts', homebrew)
  assert.ok(metadata >= 0)
  assert.ok(smoke > metadata)
  assert.ok(consumers > smoke)
  assert.ok(container > consumers)
  assert.ok(homebrew > container)
  assert.ok(install > homebrew)
  assert.equal(workflow.indexOf('npm run test:release-consumers', consumers + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-smoke', smoke + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-container', container + 1), -1)
  assert.equal(workflow.indexOf('npm run test:release-homebrew', homebrew + 1), -1)
})

test('release container preparation verifies and confines a local Linux archive', async () => {
  const fixture = makeContainerFixture()
  try {
    const result = await prepareReleaseContainer({
      root: fixture.root,
      outputDirectory: fixture.outputDirectory,
      target: fixture.target,
      version: '0.4.0-rc.1',
    })
    assert.equal(result.target, fixture.target)
    assert.equal(result.version, '0.4.0-rc.1')
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
          version: '0.4.0-rc.1',
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
          version: '0.4.0-rc.1',
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
  assert.match(dockerfile, /^# syntax=docker\/dockerfile:1$/m)
  assert.match(dockerfile, /^FROM node:22-alpine@sha256:[0-9a-f]{64} AS verifier$/m)
  assert.match(dockerfile, /linux\/amd64\) zigcss_target=x86_64-linux/)
  assert.match(dockerfile, /linux\/arm64\) zigcss_target=aarch64-linux/)
  assert.match(dockerfile, /node scripts\/prepare-release-container\.mjs/)
  assert.match(dockerfile, /^FROM scratch AS runtime$/m)
  assert.match(dockerfile, /^COPY --from=verifier --chmod=0555 \/verify\/container-root\/bin\/zigcss \/usr\/local\/bin\/zigcss$/m)
  assert.match(dockerfile, /^USER 65532:65532$/m)
  assert.match(dockerfile, /^ENTRYPOINT \["\/usr\/local\/bin\/zigcss"\]$/m)
  assert.doesNotMatch(dockerfile, /\b(?:curl|wget|zig build)\b|ADD https?:/)
})
