import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import {
  maximumArchiveBytes,
  maximumManifestBytes,
  parseNativeIntegrityArguments,
  validateNativeIntegrity,
  validateNativeIntegritySources,
  verifyNativeArchive,
} from './validate-native-integrity.mjs'

const scriptPath = fileURLToPath(new URL('./validate-native-integrity.mjs', import.meta.url))
const version = '0.7.0-rc.1'
const sourceDateEpoch = 1_788_438_195
const historicalStableVersion = '0.6.0'

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function canonicalJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-native-integrity-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const archiveDirectory = path.join(root, 'release-assets')
  fs.mkdirSync(archiveDirectory)
  const archives = releaseTargets.map((target, index) => {
    const bytes = Buffer.from(`zigcss native archive fixture ${index} ${target.target}\n`)
    const filename = releaseAssetsFor(version, target.target).archive
    fs.writeFileSync(path.join(archiveDirectory, filename), bytes)
    return {
      target: target.target,
      filename,
      sha256: sha256(bytes),
    }
  })
  const manifest = {
    schemaVersion: 1,
    package: 'zigcss',
    version,
    sourceDateEpoch,
    archives,
  }
  const sources = {
    manifest: canonicalJson(manifest),
    packageManifest: canonicalJson({ name: 'zigcss', version }),
    version: `${version}\n`,
  }
  fs.writeFileSync(path.join(root, 'native-integrity.json'), sources.manifest)
  fs.writeFileSync(path.join(root, 'package.json'), sources.packageManifest)
  fs.writeFileSync(path.join(root, 'VERSION'), sources.version)
  return { root, archiveDirectory, archives, manifest, sources }
}

function sourceMutation(base, mutate) {
  const manifest = structuredClone(base.manifest)
  mutate(manifest)
  return { ...base.sources, manifest: canonicalJson(manifest) }
}

test('committed manifest owns the exact five-target release inventory and stable epoch', () => {
  const result = validateNativeIntegrity()
  assert.equal(result.schemaVersion, 1)
  assert.equal(result.package, 'zigcss')
  assert.equal(result.version, version)
  assert.equal(result.sourceDateEpoch, sourceDateEpoch)
  assert.deepEqual(result.archives.map(archive => archive.target), releaseTargets.map(target => target.target))
  assert.deepEqual(
    result.archives.map(archive => archive.filename),
    releaseTargets.map(target => releaseAssetsFor(result.version, target.target).archive),
  )
  assert.equal(new Set(result.archives.map(archive => archive.sha256)).size, releaseTargets.length)
})

test('CLI is closed and prints only the manifest-owned epoch for the exact version', () => {
  const archive = `release-assets/${releaseAssetsFor(version, 'aarch64-macos').archive}`
  assert.deepEqual(parseNativeIntegrityArguments(['--check']), { mode: 'check' })
  assert.deepEqual(
    parseNativeIntegrityArguments(['--print-source-date-epoch', '--version', version]),
    { mode: 'print-source-date-epoch', version },
  )
  assert.deepEqual(parseNativeIntegrityArguments([
    '--target', 'aarch64-macos',
    '--version', version,
    '--archive', archive,
  ]), {
    mode: 'verify-archive',
    archive,
    target: 'aarch64-macos',
    version,
  })

  for (const args of [
    [],
    ['--check', '--extra'],
    ['--print-source-date-epoch'],
    ['--version', version, '--print-source-date-epoch'],
    ['--print-source-date-epoch', '--version', ''],
    ['--archive', 'a', '--target', 'x86_64-linux'],
    ['--archive', 'a', '--archive', 'b', '--version', version],
    ['--archive', 'a', '--target', 'x86_64-linux', '--unknown', version],
    ['--archive', '--target', '--target', 'x86_64-linux', '--version', version],
  ]) {
    assert.throws(() => parseNativeIntegrityArguments(args), /native integrity:/)
  }

  const printed = spawnSync(process.execPath, [scriptPath, '--print-source-date-epoch', '--version', version], {
    encoding: 'utf8',
  })
  assert.equal(printed.status, 0, printed.stderr)
  assert.equal(printed.stdout, `${sourceDateEpoch}\n`)
  assert.equal(printed.stderr, '')

  const checked = spawnSync(process.execPath, [scriptPath, '--check'], { encoding: 'utf8' })
  assert.equal(checked.status, 0, checked.stderr)
  assert.equal(checked.stdout, `Native integrity verified: 5 archives for zigcss@${version}.\n`)
  assert.equal(checked.stderr, '')

  const extra = spawnSync(process.execPath, [scriptPath, '--check', '--extra'], { encoding: 'utf8' })
  assert.notEqual(extra.status, 0)
  assert.match(extra.stderr, /native integrity:/)

  const wrongVersion = spawnSync(
    process.execPath,
    [scriptPath, '--print-source-date-epoch', '--version', historicalStableVersion],
    { encoding: 'utf8' },
  )
  assert.notEqual(wrongVersion.status, 0)
  assert.match(wrongVersion.stderr, /requested version must be 0\.7\.0-rc\.1/)
})

test('exact schema, package identity, version, epoch, inventory, filenames, and digests fail closed', t => {
  const base = fixture(t)
  assert.deepEqual(validateNativeIntegritySources(base.sources), {
    ...base.manifest,
    archives: base.archives,
  })

  const manifestMutations = [
    [manifest => { manifest.schemaVersion = 2 }, /schemaVersion must be exactly 1/],
    [manifest => { manifest.package = 'other' }, /manifest package must match/],
    [manifest => { manifest.version = historicalStableVersion }, /manifest version must be/],
    [manifest => { manifest.sourceDateEpoch = -1 }, /sourceDateEpoch must be an integer/],
    [manifest => { manifest.sourceDateEpoch = 1.5 }, /sourceDateEpoch must be an integer/],
    [manifest => { manifest.sourceDateEpoch = '1787048004' }, /sourceDateEpoch must be an integer/],
    [manifest => { manifest.sourceDateEpoch = 0x1_0000_0000 }, /sourceDateEpoch must be an integer/],
    [manifest => { manifest.archives.pop() }, /archive inventory must contain exactly 5/],
    [manifest => { manifest.archives.push(structuredClone(manifest.archives[0])) }, /archive inventory must contain exactly 5/],
    [manifest => { manifest.archives.reverse() }, /archive entry 0 target must be/],
    [manifest => { manifest.archives[0].target = 'riscv64-linux' }, /archive entry 0 target must be/],
    [manifest => { manifest.archives[0].filename = 'zigcss.tar.gz' }, /archive entry 0 filename must be/],
    [manifest => { manifest.archives[0].sha256 = 'A'.repeat(64) }, /64 lowercase hexadecimal/],
    [manifest => { manifest.archives[0].sha256 = '0'.repeat(63) }, /64 lowercase hexadecimal/],
    [manifest => { manifest.archives[1].sha256 = manifest.archives[0].sha256 }, /digests must be unique/],
    [manifest => { delete manifest.archives[0].filename }, /archive entry 0 keys must be exactly/],
    [manifest => { manifest.archives[0].size = 1 }, /archive entry 0 keys must be exactly/],
    [manifest => { delete manifest.sourceDateEpoch }, /native-integrity\.json keys must be exactly/],
    [manifest => { manifest.untrusted = true }, /native-integrity\.json keys must be exactly/],
  ]
  for (const [mutate, expression] of manifestMutations) {
    assert.throws(() => validateNativeIntegritySources(sourceMutation(base, mutate)), expression)
  }

  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, packageManifest: canonicalJson({ name: 'other', version }) }),
    /package name must be zigcss/,
  )
  assert.throws(
    () => validateNativeIntegritySources({
      ...base.sources,
      packageManifest: canonicalJson({ name: 'zigcss', version: historicalStableVersion }),
    }),
    /package\.json version must be 0\.7\.0-rc\.1/,
  )
  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, version: `${historicalStableVersion}\n` }),
    /package\.json version must be 0\.6\.0/,
  )
  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, version: ` ${version}\n` }),
    /VERSION must contain one canonical version/,
  )
  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, manifest: `${base.sources.manifest}\n` }),
    /canonical JSON representation/,
  )
  assert.throws(
    () => validateNativeIntegritySources({
      ...base.sources,
      manifest: base.sources.manifest.replace(
        '  "package": "zigcss",',
        '  "package": "zigcss",\n  "package": "zigcss",',
      ),
    }),
    /canonical JSON representation/,
  )
  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, manifest: '{' }),
    /not valid JSON/,
  )
  assert.throws(
    () => validateNativeIntegritySources({ ...base.sources, extra: '' }),
    /source set keys must be exactly/,
  )
})

test('manifest, package, and VERSION must remain bounded regular non-symlink UTF-8 files', t => {
  {
    const item = fixture(t)
    const manifest = path.join(item.root, 'native-integrity.json')
    fs.rmSync(manifest)
    fs.symlinkSync(path.join(item.root, 'package.json'), manifest)
    assert.throws(() => validateNativeIntegrity(item.root), /native-integrity\.json must be a regular non-symlink file/)
  }
  {
    const item = fixture(t)
    const packageManifest = path.join(item.root, 'package.json')
    fs.rmSync(packageManifest)
    fs.mkdirSync(packageManifest)
    assert.throws(() => validateNativeIntegrity(item.root), /package\.json must be a regular non-symlink file/)
  }
  {
    const item = fixture(t)
    fs.writeFileSync(path.join(item.root, 'VERSION'), Buffer.from([0xff, 0xfe]))
    assert.throws(() => validateNativeIntegrity(item.root), /VERSION is not valid UTF-8/)
  }
  {
    const item = fixture(t)
    fs.truncateSync(path.join(item.root, 'native-integrity.json'), maximumManifestBytes + 1)
    assert.throws(() => validateNativeIntegrity(item.root), /native-integrity\.json exceeds 65536 bytes/)
  }
  {
    const item = fixture(t)
    const link = `${item.root}-link`
    fs.symlinkSync(item.root, link, 'dir')
    t.after(() => fs.rmSync(link, { force: true }))
    assert.throws(() => validateNativeIntegrity(link), /repository root must be a regular non-symlink directory/)
  }
})

test('all five exact archive filenames and SHA-256 digests verify from bounded descriptors', t => {
  const item = fixture(t)
  for (const archive of item.archives) {
    const result = verifyNativeArchive({
      root: item.root,
      archive: path.join(item.archiveDirectory, archive.filename),
      target: archive.target,
      version,
    })
    assert.deepEqual(result, {
      target: archive.target,
      version,
      filename: archive.filename,
      sha256: archive.sha256,
      bytes: fs.statSync(path.join(item.archiveDirectory, archive.filename)).size,
    })
  }
})

test('archive verification rejects tampering, wrong identity, unsafe files, and resource abuse', t => {
  const item = fixture(t)
  const record = item.archives[0]
  const archive = path.join(item.archiveDirectory, record.filename)

  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version: historicalStableVersion }),
    /native archive version must be 0\.7\.0-rc\.1/,
  )
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: 'riscv64-linux', version }),
    /unsupported native archive target/,
  )
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive }),
    /closed contract/,
  )
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version, extra: true }),
    /closed contract/,
  )

  const wrongName = path.join(item.archiveDirectory, 'renamed.tar.gz')
  fs.copyFileSync(archive, wrongName)
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive: wrongName, target: record.target, version }),
    /native archive filename must be/,
  )
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive: `${archive}\n`, target: record.target, version }),
    /unsupported control byte/,
  )
  assert.throws(
    () => verifyNativeArchive({
      root: item.root,
      archive: path.join(item.archiveDirectory, 'missing', record.filename),
      target: record.target,
      version,
    }),
    /native archive is unavailable/,
  )

  fs.appendFileSync(archive, 'tamper')
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version }),
    /SHA-256 does not match/,
  )

  fs.rmSync(archive)
  fs.symlinkSync(path.join(item.archiveDirectory, item.archives[1].filename), archive)
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version }),
    /regular non-symlink file/,
  )

  fs.rmSync(archive)
  fs.mkdirSync(archive)
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version }),
    /regular non-symlink file/,
  )

  fs.rmSync(archive, { recursive: true })
  fs.writeFileSync(archive, '')
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version }),
    /must not be empty/,
  )

  fs.truncateSync(archive, maximumArchiveBytes + 1)
  assert.throws(
    () => verifyNativeArchive({ root: item.root, archive, target: record.target, version }),
    /exceeds 536870912 bytes/,
  )
})
