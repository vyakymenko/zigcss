import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { createReleaseArchive } from './create-release-archive.mjs'
import {
  buildNativeIntegrityManifest,
  checkNativeIntegrityManifest,
  parseGenerateNativeIntegrityArguments,
  renderCanonicalArchive,
  writeNativeIntegrityManifest,
} from './generate-native-integrity.mjs'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { validateNativeIntegrity } from './validate-native-integrity.mjs'

const version = '0.7.0-rc.1'
const sourceDateEpoch = 1_800_000_000

function temporaryDirectory(t, prefix = 'zigcss-native-integrity-generation-') {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  return directory
}

function writeSourceIdentity(root) {
  fs.writeFileSync(path.join(root, 'VERSION'), `${version}\n`)
  fs.writeFileSync(path.join(root, 'package.json'), `${JSON.stringify({ name: 'zigcss', version }, null, 2)}\n`)
}

function executableFor(target) {
  if (target.endsWith('-linux')) {
    const binary = Buffer.alloc(64)
    binary.write('\x7fELF', 0, 'binary')
    binary[4] = 2
    binary[5] = 1
    binary.writeUInt16LE(target.startsWith('x86_64') ? 62 : 183, 18)
    return binary
  }
  if (target.endsWith('-macos')) {
    const binary = Buffer.alloc(64)
    binary.writeUInt32LE(0xfeed_facf, 0)
    binary.writeUInt32LE(target.startsWith('x86_64') ? 0x0100_0007 : 0x0100_000c, 4)
    return binary
  }
  const binary = Buffer.alloc(128)
  binary.write('MZ', 0, 'ascii')
  binary.writeUInt32LE(0x40, 0x3c)
  binary.write('PE\0\0', 0x40, 'binary')
  binary.writeUInt16LE(0x8664, 0x44)
  return binary
}

function createArchiveSet(root, epoch = sourceDateEpoch, transform = undefined) {
  const archiveDirectory = path.join(root, 'archives')
  fs.mkdirSync(archiveDirectory, { recursive: true })
  const archives = []
  for (const policy of releaseTargets) {
    const targetRoot = path.join(root, 'binaries', policy.target)
    fs.mkdirSync(targetRoot, { recursive: true })
    const binary = path.join(targetRoot, policy.binaryName)
    const bytes = transform?.(policy, executableFor(policy.target)) ?? executableFor(policy.target)
    fs.writeFileSync(binary, bytes, { mode: 0o755 })
    const archive = path.join(archiveDirectory, releaseAssetsFor(version, policy.target).archive)
    createReleaseArchive({ archive, binary, sourceDateEpoch: epoch })
    archives.push(archive)
  }
  return archives
}

function generationOptions(root, archives, epoch = sourceDateEpoch) {
  return { archives, root, sourceDateEpoch: epoch }
}

test('optimized release executables strip path-sensitive build metadata', () => {
  const buildSource = fs.readFileSync(new URL('../build.zig', import.meta.url), 'utf8')
  const executableModule = buildSource.match(
    /const executable_module = b\.createModule\(\.\{(?<options>[\s\S]*?)\n    \}\);/,
  )

  assert.ok(executableModule, 'build.zig must define the production executable module')
  assert.match(executableModule.groups.options, /\.strip = optimize != \.Debug,/)
})

test('CLI parsing requires one explicit mode, one epoch, and exactly five absolute archives', () => {
  const archives = releaseTargets.map((policy, index) => `/tmp/${index}-${policy.target}.archive`)
  const parsed = parseGenerateNativeIntegrityArguments([
    '--write',
    '--source-date-epoch', String(sourceDateEpoch),
    ...archives.flatMap(archive => ['--archive', archive]),
  ])
  assert.deepEqual(parsed, {
    mode: 'write',
    sourceDateEpoch,
    archives,
  })

  assert.throws(() => parseGenerateNativeIntegrityArguments([]), /usage/)
  assert.throws(
    () => parseGenerateNativeIntegrityArguments([
      '--write',
      '--source-date-epoch', String(sourceDateEpoch),
      ...archives.slice(0, 4).flatMap(archive => ['--archive', archive]),
    ]),
    /usage/,
  )
  assert.throws(
    () => parseGenerateNativeIntegrityArguments([
      '--write',
      '--source-date-epoch', String(sourceDateEpoch),
      ...archives.slice(0, 4).flatMap(archive => ['--archive', archive]),
      '--archive', 'relative.tar.gz',
    ]),
    /absolute/,
  )
  assert.throws(
    () => parseGenerateNativeIntegrityArguments([
      '--write',
      '--source-date-epoch', String(sourceDateEpoch),
      ...archives.slice(0, 4).flatMap(archive => ['--archive', archive]),
      '--source-date-epoch', String(sourceDateEpoch),
    ]),
    /duplicate option/,
  )
})

test('five canonical archives produce one ordered version-bound manifest with exact hashes and targets', t => {
  const root = temporaryDirectory(t)
  writeSourceIdentity(root)
  const archives = createArchiveSet(root)
  const result = buildNativeIntegrityManifest(generationOptions(root, archives.toReversed()))

  assert.deepEqual(result.manifest, {
    schemaVersion: 1,
    package: 'zigcss',
    version,
    sourceDateEpoch,
    archives: releaseTargets.map(policy => {
      const filename = releaseAssetsFor(version, policy.target).archive
      const archive = archives.find(candidate => path.basename(candidate) === filename)
      return {
        target: policy.target,
        filename,
        sha256: crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex'),
      }
    }),
  })
  assert.equal(result.text, `${JSON.stringify(result.manifest, null, 2)}\n`)
  assert.deepEqual(
    Object.fromEntries(Object.entries(result.inspections).map(([target, item]) => [target, `${item.format}/${item.arch}`])),
    {
      'x86_64-linux': 'elf/x86_64',
      'aarch64-linux': 'elf/aarch64',
      'x86_64-macos': 'macho/x86_64',
      'aarch64-macos': 'macho/aarch64',
      'x86_64-windows': 'pe/x86_64',
    },
  )
})

test('archive rendering is deterministic and rejects an open or oversized contract', () => {
  const binary = executableFor('x86_64-linux')
  assert.deepEqual(
    renderCanonicalArchive(binary, 'tar.gz', sourceDateEpoch),
    renderCanonicalArchive(binary, 'tar.gz', sourceDateEpoch),
  )
  assert.throws(
    () => renderCanonicalArchive(binary, 'rar', sourceDateEpoch),
    /unsupported archive rendering format/,
  )
  assert.throws(
    () => renderCanonicalArchive(new Uint8Array(binary), 'tar.gz', sourceDateEpoch),
    /must be a Buffer/,
  )
})

test('generation rejects missing, duplicate, renamed, linked, noncanonical, and wrong-target archives', t => {
  const root = temporaryDirectory(t)
  writeSourceIdentity(root)
  const archives = createArchiveSet(root)

  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(root, archives.slice(0, 4))),
    /exactly 5 archives/,
  )
  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(root, [...archives.slice(0, 4), archives[0]])),
    /archive paths must be unique/,
  )

  const renamedDirectory = path.join(root, 'renamed')
  fs.mkdirSync(renamedDirectory)
  const renamed = path.join(renamedDirectory, 'zigcss-unexpected.tar.gz')
  fs.copyFileSync(archives[0], renamed)
  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(root, [renamed, ...archives.slice(1)])),
    /unexpected native archive filename/,
  )

  const linkedDirectory = path.join(root, 'linked')
  fs.mkdirSync(linkedDirectory)
  const linked = path.join(linkedDirectory, path.basename(archives[0]))
  fs.symlinkSync(archives[0], linked)
  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(root, [linked, ...archives.slice(1)])),
    /regular non-symlink file/,
  )

  const noncanonicalDirectory = path.join(root, 'noncanonical')
  fs.mkdirSync(noncanonicalDirectory)
  const noncanonical = path.join(noncanonicalDirectory, path.basename(archives[0]))
  fs.writeFileSync(noncanonical, Buffer.concat([fs.readFileSync(archives[0]), Buffer.from([0])]))
  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(root, [noncanonical, ...archives.slice(1)])),
    /invalid uncompressed size|not the canonical deterministic/,
  )

  const wrongRoot = temporaryDirectory(t, 'zigcss-native-integrity-wrong-target-')
  writeSourceIdentity(wrongRoot)
  const wrong = createArchiveSet(wrongRoot, sourceDateEpoch, (policy, bytes) => (
    policy.target === 'aarch64-linux' ? executableFor('x86_64-linux') : bytes
  ))
  assert.throws(
    () => buildNativeIntegrityManifest(generationOptions(wrongRoot, wrong)),
    /aarch64-linux archive target is invalid/,
  )
})

test('explicit writes create, preserve identical bytes, replace drift atomically, and support exact checks', t => {
  const root = temporaryDirectory(t)
  writeSourceIdentity(root)
  const archives = createArchiveSet(root)
  const options = generationOptions(root, archives)
  const output = path.join(root, 'native-integrity.json')

  const created = writeNativeIntegrityManifest(options)
  assert.equal(created.status, 'created')
  assert.equal(fs.readFileSync(output, 'utf8'), created.text)
  assert.equal(validateNativeIntegrity(root).version, version)

  const identical = writeNativeIntegrityManifest(options)
  assert.equal(identical.status, 'identical')
  assert.equal(checkNativeIntegrityManifest(options).status, 'verified')

  fs.writeFileSync(output, '{}\n')
  assert.throws(() => checkNativeIntegrityManifest(options), /is stale/)
  const updated = writeNativeIntegrityManifest(options)
  assert.equal(updated.status, 'updated')
  assert.equal(fs.readFileSync(output, 'utf8'), updated.text)

  fs.unlinkSync(output)
  const outside = path.join(root, 'outside.json')
  fs.writeFileSync(outside, 'preserve\n')
  fs.symlinkSync(outside, output)
  assert.throws(() => writeNativeIntegrityManifest(options), /regular non-symlink file/)
  assert.equal(fs.readFileSync(outside, 'utf8'), 'preserve\n')
})
