import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const actionDirectory = path.join(repositoryRoot, '.github', 'actions', 'setup-zig')
const modulePath = path.join(actionDirectory, 'setup-zig.mjs')
const cachePin = '27d5ce7f107fe9357f9df03efb73ab90386fccae'

async function loadSetupModule() {
  assert.equal(fs.existsSync(modulePath), true, 'repository-owned Zig setup module is missing')
  return import(`${pathToFileURL(modulePath).href}?test=${Date.now()}-${Math.random()}`)
}

test('the repository-owned Zig setup action is a closed Node 24-compatible composite', () => {
  assert.equal(fs.existsSync(actionDirectory), true, 'repository-owned Zig setup action is missing')
  assert.deepEqual(fs.readdirSync(actionDirectory).sort(), ['action.yml', 'setup-zig.mjs'])

  const manifest = fs.readFileSync(path.join(actionDirectory, 'action.yml'), 'utf8')
  assert.match(manifest, /^name: Setup Zig 0\.15\.2$/m)
  assert.match(manifest, /runs:\n  using: composite\n/)
  assert.equal(manifest.split(`uses: actions/cache@${cachePin} # v5.0.5`).length - 1, 2)
  assert.match(manifest, /required: true/)
  assert.match(manifest, /node "\$\{\{ github\.action_path \}\}\/setup-zig\.mjs" --install/)
  assert.match(manifest, /zigcss-zig-archive-v1-/)
  assert.match(manifest, /zigcss-zig-build-v1-/)
  assert.doesNotMatch(manifest, /mlugg\/setup-zig|node20/)
})

test('the exact Zig 0.15.2 host archive terminal is checksum and size bound', async () => {
  const setup = await loadSetupModule()
  assert.equal(setup.zigVersion, '0.15.2')
  assert.deepEqual(setup.artifactRecords, [
    {
      platform: 'darwin',
      arch: 'arm64',
      target: 'aarch64-macos',
      extension: '.tar.xz',
      size: 50_635_984,
      sha256: '3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b',
    },
    {
      platform: 'darwin',
      arch: 'x64',
      target: 'x86_64-macos',
      extension: '.tar.xz',
      size: 55_800_460,
      sha256: '375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f',
    },
    {
      platform: 'linux',
      arch: 'arm64',
      target: 'aarch64-linux',
      extension: '.tar.xz',
      size: 49_471_996,
      sha256: '958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f',
    },
    {
      platform: 'linux',
      arch: 'x64',
      target: 'x86_64-linux',
      extension: '.tar.xz',
      size: 53_733_924,
      sha256: '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239',
    },
    {
      platform: 'win32',
      arch: 'x64',
      target: 'x86_64-windows',
      extension: '.zip',
      size: 92_614_574,
      sha256: '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c',
    },
  ])

  for (const record of setup.artifactRecords) {
    const artifact = setup.resolveArtifact(record.platform, record.arch, setup.zigVersion)
    assert.equal(artifact.filename, `zig-${record.target}-${setup.zigVersion}${record.extension}`)
    assert.equal(artifact.url, `https://ziglang.org/download/${setup.zigVersion}/${artifact.filename}`)
    assert.equal(artifact.root, `zig-${record.target}-${setup.zigVersion}`)
  }
  assert.throws(() => setup.resolveArtifact('linux', 'ia32', setup.zigVersion), /unsupported Zig host/)
  assert.throws(() => setup.resolveArtifact('linux', 'x64', '0.15.3'), /only Zig 0\.15\.2/)
})

test('Windows archive extraction ignores Git Bash PATH shadowing', async () => {
  const setup = await loadSetupModule()
  const environment = {
    PATH: 'C:\\Program Files\\Git\\usr\\bin;C:\\Windows\\System32',
    SystemRoot: 'C:\\Windows',
  }

  assert.equal(
    setup.resolveArchiveCommand('win32', environment),
    'C:\\Windows\\System32\\tar.exe',
  )
  assert.equal(setup.resolveArchiveCommand('linux', environment), 'tar')
  assert.equal(setup.resolveArchiveCommand('darwin', environment), 'tar')

  for (const SystemRoot of [undefined, '', 'Windows', '\\\\server\\Windows', 'C:\\Windows\n']) {
    assert.throws(
      () => setup.resolveArchiveCommand('win32', { ...environment, SystemRoot }),
      /SystemRoot/,
    )
  }
})

test('cached Zig archives fail closed on type, size, or digest drift', async t => {
  const setup = await loadSetupModule()
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-setup-zig-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const archive = path.join(temporary, 'archive.bin')
  const bytes = Buffer.from('verified archive bytes')
  fs.writeFileSync(archive, bytes)
  const expected = {
    size: bytes.length,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
  }

  await setup.verifyArchive(archive, expected)
  await assert.rejects(setup.verifyArchive(archive, { ...expected, size: bytes.length - 1 }), /size/)
  await assert.rejects(setup.verifyArchive(archive, { ...expected, sha256: '0'.repeat(64) }), /SHA-256/)

  const link = path.join(temporary, 'archive-link.bin')
  fs.symlinkSync(archive, link)
  await assert.rejects(setup.verifyArchive(link, expected), /regular non-symlink file/)
})

test('archive inventory validation admits one root and rejects escape or resource drift', async () => {
  const setup = await loadSetupModule()
  const root = 'zig-x86_64-linux-0.15.2'
  assert.deepEqual(setup.validateArchiveEntries([
    `${root}/`,
    `${root}/zig`,
    `${root}/lib/std/std.zig`,
  ], root), { entries: 3 })

  for (const invalid of [
    ['/absolute'],
    ['../escape'],
    [`${root}/../escape`],
    [`${root}\\zig.exe`],
    ['different-root/zig'],
    [`${root}/bad\0name`],
  ]) {
    assert.throws(() => setup.validateArchiveEntries(invalid, root), /archive entry/)
  }

  const terminal = Array.from({ length: setup.maximumArchiveEntries }, (_, index) => `${root}/lib/${index}`)
  assert.equal(setup.validateArchiveEntries(terminal, root).entries, setup.maximumArchiveEntries)
  assert.throws(
    () => setup.validateArchiveEntries([...terminal, `${root}/over-limit`], root),
    /entry limit/,
  )
})

test('Zig cache accounting covers lower, terminal, and over-limit byte boundaries', async t => {
  const setup = await loadSetupModule()
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-zig-cache-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))

  fs.writeFileSync(path.join(temporary, 'lower'), Buffer.alloc(3))
  fs.mkdirSync(path.join(temporary, 'nested'))
  fs.writeFileSync(path.join(temporary, 'nested', 'terminal'), Buffer.alloc(5))
  assert.deepEqual(await setup.measureCacheDirectory(temporary, 8), { bytes: 8, overLimit: false })

  fs.writeFileSync(path.join(temporary, 'over'), Buffer.alloc(1))
  assert.deepEqual(await setup.measureCacheDirectory(temporary, 8), { bytes: 9, overLimit: true })
})

test('Zig cache preparation preserves separate local and global namespaces', async t => {
  const setup = await loadSetupModule()
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-zig-workspace-'))
  t.after(() => fs.rmSync(workspace, { recursive: true, force: true }))

  const cache = await setup.prepareCache(workspace)
  const canonicalWorkspace = fs.realpathSync(workspace)
  assert.deepEqual(cache, {
    rootDirectory: path.join(canonicalWorkspace, '.zig-cache'),
    globalDirectory: path.join(canonicalWorkspace, '.zig-cache', 'global'),
    localDirectory: path.join(canonicalWorkspace, '.zig-cache', 'local'),
  })
  assert.equal(fs.lstatSync(cache.globalDirectory).isDirectory(), true)
  assert.equal(fs.lstatSync(cache.localDirectory).isDirectory(), true)
  assert.notEqual(cache.globalDirectory, cache.localDirectory)
})
