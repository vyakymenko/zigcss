import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  compilerWarningForVersion,
  archiveExecutable,
  lifecycleShellExecutable,
  nativePreprocessorSmokeCases,
  nativeSmokeTargets,
  parseSmokeArguments,
  stageDevelopmentPackage,
  validateReleaseSmokeWorkflowSources,
} from './smoke-release-artifact.mjs'
import { createReleaseArchive } from './create-release-archive.mjs'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const repositoryInstaller = createRequire(import.meta.url)(path.join(repositoryRoot, 'install.js'))

function fixtureWindowsSystemRoot(configured = process.env.SystemRoot) {
  const normalized = typeof configured === 'string'
    ? path.win32.normalize(configured).replace(/[\\/]$/, '').toLowerCase()
    : ''
  switch (normalized) {
    case 'a:\\windows': return 'A:\\Windows'
    case 'b:\\windows': return 'B:\\Windows'
    case 'c:\\windows': return 'C:\\Windows'
    case 'd:\\windows': return 'D:\\Windows'
    case 'e:\\windows': return 'E:\\Windows'
    case 'f:\\windows': return 'F:\\Windows'
    case 'g:\\windows': return 'G:\\Windows'
    case 'h:\\windows': return 'H:\\Windows'
    case 'i:\\windows': return 'I:\\Windows'
    case 'j:\\windows': return 'J:\\Windows'
    case 'k:\\windows': return 'K:\\Windows'
    case 'l:\\windows': return 'L:\\Windows'
    case 'm:\\windows': return 'M:\\Windows'
    case 'n:\\windows': return 'N:\\Windows'
    case 'o:\\windows': return 'O:\\Windows'
    case 'p:\\windows': return 'P:\\Windows'
    case 'q:\\windows': return 'Q:\\Windows'
    case 'r:\\windows': return 'R:\\Windows'
    case 's:\\windows': return 'S:\\Windows'
    case 't:\\windows': return 'T:\\Windows'
    case 'u:\\windows': return 'U:\\Windows'
    case 'v:\\windows': return 'V:\\Windows'
    case 'w:\\windows': return 'W:\\Windows'
    case 'x:\\windows': return 'X:\\Windows'
    case 'y:\\windows': return 'Y:\\Windows'
    case 'z:\\windows': return 'Z:\\Windows'
    default: throw new Error('test fixture requires the finite Windows system directory')
  }
}

function localNpmCliPath() {
  const executableDirectory = path.dirname(process.execPath)
  const candidates = [
    path.resolve(executableDirectory, '../lib/node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, '../node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, 'node_modules/npm/bin/npm-cli.js'),
  ]
  for (const candidate of candidates) {
    let descriptor
    try {
      const canonical = fs.realpathSync(candidate)
      descriptor = fs.openSync(
        canonical,
        fs.constants.O_RDONLY |
          (fs.constants.O_NOFOLLOW ?? 0) |
          (fs.constants.O_NONBLOCK ?? 0) |
          (fs.constants.O_CLOEXEC ?? 0),
      )
      const opened = fs.fstatSync(descriptor, { bigint: true })
      const pathStat = fs.lstatSync(canonical, { bigint: true })
      if (
        opened.isFile() && pathStat.isFile() && !pathStat.isSymbolicLink() &&
        opened.dev === pathStat.dev && opened.ino === pathStat.ino &&
        opened.size === pathStat.size && opened.size > 0n && opened.size <= 16n * 1024n * 1024n
      ) return canonical
    } catch {
      // Try only the next path adjacent to the already-running Node executable.
    } finally {
      if (descriptor !== undefined) fs.closeSync(descriptor)
    }
  }
  throw new Error('npm CLI is unavailable beside the active Node executable')
}

test('release smokes emit the safety notice only for prerelease binaries', () => {
  assert.equal(compilerWarningForVersion('0.6.0'), '')
  assert.equal(
    compilerWarningForVersion('0.6.0-rc.2'),
    'Warning: ZigCSS 0.6.0-rc.2 is an experimental release candidate; do not use it for production CSS.\n',
  )
})

function runtimeTraceFixture(temporary) {
  const archive = 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz'
  const checksums = 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256'
  const trace = path.join(temporary, 'runtime-trace.jsonl')
  fs.writeFileSync(path.join(temporary, archive), 'archive fixture')
  fs.writeFileSync(path.join(temporary, checksums), 'manifest fixture')
  fs.writeFileSync(trace, '')
  const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
  const nativeSource = fs.realpathSync(lifecycleShellExecutable(
    process.platform,
    process.platform === 'win32' ? fixtureWindowsSystemRoot() : undefined,
  ))
  // Apple platform binaries retain an arm64e signature that the kernel kills
  // after copying. The system shell is already a regular non-symlink file on
  // macOS; hosted release smokes still exercise the real extracted Zig binary.
  const native = process.platform === 'darwin'
    ? nativeSource
    : path.join(temporary, process.platform === 'win32' ? 'native-fixture.exe' : 'sh')
  if (native !== nativeSource) {
    fs.copyFileSync(nativeSource, native)
    if (process.platform !== 'win32') fs.chmodSync(native, 0o700)
  }
  const nativeStat = fs.lstatSync(native)
  assert.equal(nativeStat.isFile(), true)
  assert.equal(nativeStat.isSymbolicLink(), false)
  const nativeArgs = process.platform === 'win32'
    ? ['/d', '/s', '/c', 'exit 0']
    : ['-c', 'exit 0']
  return {
    native,
    nativeArgs,
    trace,
    env: {
      ...process.env,
      NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: temporary,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.6.0-rc.2',
      ZIGCSS_RELEASE_SMOKE_RUNTIME: '1',
      ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY: native,
      ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE: trace,
      ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT: temporary,
    },
  }
}

test('release smoke preload rejects asset roots outside its finite fixture roots', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-root-denial-'))
  try {
    const fixture = runtimeTraceFixture(temporary)
    const result = spawnSync(process.execPath, ['-e', "process.stdout.write('unexpected')"], {
      encoding: 'utf8',
      env: {
        ...fixture.env,
        ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: path.parse(repositoryRoot).root,
      },
    })
    assert.equal(result.error, undefined)
    assert.notEqual(result.status, 0)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /asset root must be the repository assets or remain inside the smoke temporary root/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('runtime binary admission uses the canonical root beneath a symlinked OS temp prefix', {
  skip: process.platform === 'win32',
}, () => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-temp-alias-'))
  try {
    const realTemporary = path.join(parent, 'real')
    const linkedTemporary = path.join(parent, 'linked')
    fs.mkdirSync(realTemporary, { mode: 0o700 })
    fs.symlinkSync(realTemporary, linkedTemporary, 'dir')
    const traceRoot = fs.mkdtempSync(path.join(linkedTemporary, 'zigcss-release-runtime-trace-'))
    const canonicalTraceRoot = fs.realpathSync(traceRoot)
    assert.notEqual(traceRoot, canonicalTraceRoot)

    const archive = 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256'
    const trace = path.join(traceRoot, 'runtime-trace.jsonl')
    const direct = path.join(traceRoot, 'direct')
    fs.mkdirSync(direct, { mode: 0o700 })
    const binary = path.join(direct, 'zigcss')
    fs.writeFileSync(path.join(traceRoot, archive), 'archive fixture')
    fs.writeFileSync(path.join(traceRoot, checksums), 'manifest fixture')
    fs.writeFileSync(trace, '')
    fs.writeFileSync(binary, 'finite canonical binary fixture\n', { mode: 0o700 })
    const canonicalBinary = fs.realpathSync(binary)
    assert.equal(canonicalBinary, path.join(canonicalTraceRoot, 'direct', 'zigcss'))

    const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
    const result = spawnSync(process.execPath, ['-e', ''], {
      encoding: 'utf8',
      env: {
        ...process.env,
        NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
        TMPDIR: linkedTemporary,
        ZIGCSS_RELEASE_SMOKE: '1',
        ZIGCSS_RELEASE_SMOKE_ARCHIVE: archive,
        ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: traceRoot,
        ZIGCSS_RELEASE_SMOKE_CHECKSUMS: checksums,
        ZIGCSS_RELEASE_SMOKE_RUNTIME: '1',
        ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY: canonicalBinary,
        ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE: trace,
        ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT: traceRoot,
        ZIGCSS_RELEASE_SMOKE_VERSION: '0.6.0-rc.2',
      },
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, '')
    const records = fs.readFileSync(trace, 'utf8').trimEnd().split('\n').map(line => JSON.parse(line))
    assert.deepEqual(records.map(record => record.event), ['runtime-start', 'runtime-summary'])
    assert.equal(records.at(-1).nativeSpawns, 0)
  } finally {
    fs.rmSync(parent, { recursive: true, force: true })
  }
})

test('release preload reports only a finite lifecycle rejection stage', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-'))
  try {
    const archive = 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256'
    fs.writeFileSync(path.join(temporary, archive), 'archive fixture')
    fs.writeFileSync(path.join(temporary, checksums), 'manifest fixture')
    const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
    const env = {
      ...process.env,
      NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
      ZIGCSS_PRIVATE_SENTINEL: 'must-not-appear-in-release-diagnostics',
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: temporary,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.6.0-rc.2',
    }
    delete env.npm_config_script_shell
    const result = spawnSync(process.execPath, ['-e', [
      "const childProcess = require('node:child_process')",
      "try { childProcess.spawn(process.execPath, ['--version']) } catch (error) {",
      "  if (error.code !== 'ZIGCSS_PROCESS_DISABLED') throw error",
      '  process.exitCode = 1',
      '}',
    ].join('\n')], { encoding: 'utf8', env })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, 'release smoke preload: lifecycle child rejected-shell\n')
    assert.doesNotMatch(result.stderr, /must-not-appear-in-release-diagnostics/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

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
      return identity(name, replaced === name && (name === 'file' || calls > 1))
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

test('release smoke selects only finite verified absolute system archive readers', () => {
  if (process.platform === 'linux' || process.platform === 'darwin') {
    const executable = process.platform === 'linux'
      ? archiveExecutable('linux', undefined)
      : archiveExecutable('darwin', undefined)
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
  assert.equal(archiveExecutable('linux', undefined, archiveFilesystem()), '/usr/bin/tar')
  assert.equal(
    archiveExecutable('darwin', undefined, archiveFilesystem({ resolved: '/usr/bin/bsdtar' })),
    '/usr/bin/tar',
  )
  assert.equal(
    archiveExecutable('win32', 'D:\\Windows', windowsSystemFilesystem()),
    'D:\\Windows\\System32\\tar.exe',
  )
  assert.throws(() => archiveExecutable('win32', undefined), /Windows system root/)
  assert.throws(() => archiveExecutable('win32', '\\\\server\\Windows'), /Windows system root/)
  assert.throws(() => archiveExecutable('win32', 'D:\\FakeRoot'), /Windows system root/)
  assert.throws(() => archiveExecutable('win32', 'D:\\Nested\\Windows'), /Windows system root/)
  assert.throws(() => archiveExecutable('freebsd'), /unsupported archive platform/)
  for (const fileSystem of [
    archiveFilesystem({ resolved: '/tmp/tar' }),
    archiveFilesystem({ symbolicLink: true }),
    archiveFilesystem({ regular: false }),
    archiveFilesystem({ rootOwned: false }),
    archiveFilesystem({ mode: 0o100777 }),
    archiveFilesystem({ mode: 0o100644 }),
  ]) {
    assert.throws(
      () => archiveExecutable('linux', undefined, fileSystem),
      /no trusted system tar executable/,
    )
  }
  assert.equal(lifecycleShellExecutable('linux', undefined, archiveFilesystem()), '/bin/sh')
  assert.equal(lifecycleShellExecutable('darwin', undefined, archiveFilesystem()), '/bin/sh')
  assert.equal(
    lifecycleShellExecutable(
      'win32',
      'D:\\Windows',
      windowsSystemFilesystem({ executableName: 'cmd.exe' }),
    ),
    'D:\\Windows\\System32\\cmd.exe',
  )
  assert.throws(
    () => lifecycleShellExecutable('linux', undefined, archiveFilesystem({ rootOwned: false })),
    /trusted lifecycle shell/,
  )
  assert.throws(() => lifecycleShellExecutable('freebsd'), /unsupported lifecycle shell platform/)

  const windowsMutations = [
    { redirected: 'root' },
    { redirected: 'system32' },
    { redirected: 'file' },
    { redirectedAfter: 'root' },
    { redirectedAfter: 'system32' },
    { redirectedAfter: 'file' },
    { replaced: 'root' },
    { replaced: 'system32' },
    { replaced: 'file' },
    { replaced: 'opened-file' },
    { symbolicLink: 'root' },
    { symbolicLink: 'system32' },
    { symbolicLink: 'file' },
    { wrongType: 'root' },
    { wrongType: 'system32' },
    { wrongType: 'file' },
    { emptyFile: true },
  ]
  for (const [selector, executableName] of [
    [archiveExecutable, 'tar.exe'],
    [lifecycleShellExecutable, 'cmd.exe'],
  ]) {
    for (const mutation of windowsMutations) {
      assert.throws(
        () => selector(
          'win32',
          'D:\\Windows',
          windowsSystemFilesystem({ executableName, ...mutation }),
        ),
        new RegExp(`trusted Windows system ${executableName.replace('.', '\\.')}`),
      )
    }
  }
})

test('native smoke policy covers every release target on one matching runner', () => {
  assert.deepEqual(nativeSmokeTargets, [
    {
      target: 'x86_64-linux',
      runner: 'ubuntu-latest',
      nodePlatform: 'linux',
      nodeArch: 'x64',
      binaryName: 'zigcss',
    },
    {
      target: 'aarch64-linux',
      runner: 'ubuntu-24.04-arm',
      nodePlatform: 'linux',
      nodeArch: 'arm64',
      binaryName: 'zigcss',
    },
    {
      target: 'x86_64-macos',
      runner: 'macos-15-intel',
      nodePlatform: 'darwin',
      nodeArch: 'x64',
      binaryName: 'zigcss',
    },
    {
      target: 'aarch64-macos',
      runner: 'macos-15',
      nodePlatform: 'darwin',
      nodeArch: 'arm64',
      binaryName: 'zigcss',
    },
    {
      target: 'x86_64-windows',
      runner: 'windows-latest',
      nodePlatform: 'win32',
      nodeArch: 'x64',
      binaryName: 'zigcss.exe',
    },
  ])
  assert.equal(new Set(nativeSmokeTargets.map(item => item.target)).size, 5)
  assert.equal(new Set(nativeSmokeTargets.map(item => `${item.nodePlatform}/${item.nodeArch}`)).size, 5)
})

test('development smoke stages an isolated package trust manifest for its fresh archive', t => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-development-package-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const destination = path.join(temporary, 'package')
  const originalSource = fs.readFileSync(path.join(repositoryRoot, 'native-integrity.json'), 'utf8')
  const original = JSON.parse(originalSource)
  const digest = '0'.repeat(64)

  assert.equal(
    stageDevelopmentPackage(repositoryRoot, destination, 'aarch64-macos', digest),
    path.join(fs.realpathSync(temporary), 'package'),
  )
  assert.equal(fs.readFileSync(path.join(repositoryRoot, 'native-integrity.json'), 'utf8'), originalSource)
  const staged = JSON.parse(fs.readFileSync(path.join(destination, 'native-integrity.json'), 'utf8'))
  assert.equal(staged.archives.find(item => item.target === 'aarch64-macos').sha256, digest)
  assert.deepEqual(
    staged.archives.filter(item => item.target !== 'aarch64-macos'),
    original.archives.filter(item => item.target !== 'aarch64-macos'),
  )

  const inventory = []
  function visit(relative = '') {
    for (const entry of fs.readdirSync(path.join(destination, relative), { withFileTypes: true })) {
      const next = path.join(relative, entry.name)
      if (entry.isDirectory()) visit(next)
      else inventory.push(next.split(path.sep).join('/'))
    }
  }
  visit()
  assert.deepEqual(inventory.sort(), [...expectedPackedFiles])
  assert.throws(
    () => stageDevelopmentPackage(repositoryRoot, destination, 'aarch64-macos', digest),
    /new direct child directory/,
  )
  assert.throws(
    () => stageDevelopmentPackage(repositoryRoot, path.join(temporary, 'bad-target'), 'unknown', digest),
    /unsupported development package target/,
  )
  assert.throws(
    () => stageDevelopmentPackage(repositoryRoot, path.join(temporary, 'bad-digest'), 'aarch64-macos', 'ABC'),
    /64 lowercase hexadecimal/,
  )
})

test('smoke CLI accepts only the exact archive, binary, target, version, and optional npm package contract', () => {
  assert.deepEqual(parseSmokeArguments([
    '--archive', 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.6.0-rc.2',
  ]), {
    archive: 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.6.0-rc.2',
  })

  const commit = '0123456789abcdef0123456789abcdef01234567'
  assert.deepEqual(parseSmokeArguments([
    '--archive', 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.6.0-rc.2',
    '--commit', commit,
    '--evidence', 'native-target-evidence/aarch64-macos.json',
  ]), {
    archive: 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.6.0-rc.2',
    commit,
    evidence: 'native-target-evidence/aarch64-macos.json',
  })

  const npmPackage = path.resolve('zigcss-0.6.0-rc.2.tgz')
  assert.deepEqual(parseSmokeArguments([
    '--archive', 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.6.0-rc.2',
    '--npm-package', npmPackage,
  ]), {
    archive: 'release-assets/zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.6.0-rc.2',
    npmPackage,
  })

  for (const invalid of [
    [],
    ['--target', 'aarch64-macos'],
    ['--archive', 'a', '--binary', 'b', '--target', 'unknown', '--version', '0.6.0-rc.2'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '../tag'],
    ['--archive', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2'],
    ['--unknown', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2', '--commit', commit],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2', '--npm-package', 'zigcss-0.6.0-rc.2.tgz'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2', '--npm-package', path.resolve('zigcss-0.6.0.tgz')],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2', '--commit', 'ABC', '--evidence', 'native-target-evidence/aarch64-macos.json'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.6.0-rc.2', '--commit', commit, '--evidence', '../aarch64-macos.json'],
  ]) {
    assert.throws(() => parseSmokeArguments(invalid), /release smoke integrity/)
  }
})

test('native smoke builds a canonical commit-bound five-target receipt', async () => {
  const smoke = await import('./smoke-release-artifact.mjs')
  assert.equal(typeof smoke.nativeTargetEvidence, 'function')
  assert.equal(typeof smoke.writeNativeTargetEvidence, 'function')

  const commit = '0123456789abcdef0123456789abcdef01234567'
  const result = {
    target: 'aarch64-macos',
    archiveSha256: 'a'.repeat(64),
    binarySha256: 'b'.repeat(64),
    checksumsSha256: 'c'.repeat(64),
    installedBytes: 3_575_623,
    installedEntries: 10,
    npmPackage: 'zigcss-0.6.0-rc.2.tgz',
    directStylesheetSmokes: 5,
    offlinePackageStylesheetSmokes: 5,
    directRuntimeTrace: {
      invocations: 6,
      nativeSpawns: 6,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    },
    offlinePackageRuntimeTrace: {
      invocations: 6,
      nativeSpawns: 6,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    },
    offlineNodeApiSmokes: 2,
    offlineNodeApiOptionRejections: 1,
    offlineNodeApiRuntimeTrace: {
      invocations: 3,
      nativeSpawns: 3,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    },
  }
  const evidence = smoke.nativeTargetEvidence(result, {
    commit,
    version: '0.6.0-rc.2',
    platform: 'darwin',
    arch: 'arm64',
  })
  assert.deepEqual(evidence, {
    schemaVersion: 2,
    commit,
    version: '0.6.0-rc.2',
    target: 'aarch64-macos',
    runner: 'macos-15',
    host: {
      platform: 'darwin',
      arch: 'arm64',
    },
    languages: ['css', 'scss', 'sass', 'less', 'stylus'],
    artifacts: {
      archive: 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz',
      archiveSha256: 'a'.repeat(64),
      binary: 'zigcss',
      binarySha256: 'b'.repeat(64),
      checksums: 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256',
      checksumsSha256: 'c'.repeat(64),
      npmPackage: 'zigcss-0.6.0-rc.2.tgz',
    },
    directArchive: {
      stylesheetCompilations: 5,
      tracedInvocations: 6,
      nativeSpawns: 6,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    },
    offlineInstalledPackage: {
      stylesheetCompilations: 5,
      tracedInvocations: 6,
      nativeSpawns: 6,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
      nodeApi: {
        modules: ['commonjs', 'esm'],
        compilations: 2,
        optionRejections: 1,
        tracedInvocations: 3,
        nativeSpawns: 3,
        networkAttempts: 0,
        deniedProcessAttempts: 0,
      },
      entries: 10,
      bytes: 3_575_623,
    },
  })

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-native-target-evidence-'))
  try {
    const relative = 'native-target-evidence/aarch64-macos.json'
    assert.equal(smoke.writeNativeTargetEvidence(temporary, relative, evidence), relative)
    assert.equal(
      fs.readFileSync(path.join(temporary, relative), 'utf8'),
      `${JSON.stringify(evidence, null, 2)}\n`,
    )
    assert.throws(
      () => smoke.writeNativeTargetEvidence(temporary, relative, evidence),
      /already exists/,
    )
    assert.throws(
      () => smoke.writeNativeTargetEvidence(temporary, '../aarch64-macos.json', evidence),
      /evidence path/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }

  assert.throws(
    () => smoke.nativeTargetEvidence(result, {
      commit: commit.toUpperCase(),
      version: '0.6.0-rc.2',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /commit/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence({ ...result, directStylesheetSmokes: 4 }, {
      commit,
      version: '0.6.0-rc.2',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /five-language/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence({ ...result, offlineNodeApiSmokes: 1 }, {
      commit,
      version: '0.6.0-rc.2',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /process\/network trace/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence({ ...result, offlineNodeApiOptionRejections: 0 }, {
      commit,
      version: '0.6.0-rc.2',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /process\/network trace/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence(result, {
      commit,
      version: '0.6.0-rc.2',
      platform: 'darwin',
      arch: 'x64',
    }),
    /matching runner/,
  )
})

test('npm lifecycle preload serves only the two exact local release URLs', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-'))
  try {
    const archive = 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256'
    fs.writeFileSync(path.join(temporary, archive), 'archive fixture')
    fs.writeFileSync(path.join(temporary, checksums), 'manifest fixture')
    const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
    const env = {
      ...process.env,
      NODE_OPTIONS: `--require="${preload}"`,
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: temporary,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.6.0-rc.2',
    }
    const allowed = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.6.0-rc.2/${checksums}', response => {`,
      "  let text = ''",
      "  response.setEncoding('utf8')",
      "  response.on('data', chunk => { text += chunk })",
      "  response.on('end', () => process.stdout.write(text))",
      "}).on('error', error => { throw error })",
    ].join('\n')], { encoding: 'utf8', env })
    assert.equal(allowed.error, undefined)
    assert.equal(allowed.status, 0, allowed.stderr)
    assert.equal(allowed.stdout, 'manifest fixture')

    const blocked = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      "https.get('https://example.invalid/unexpected', () => { process.exitCode = 2 })",
      "  .on('error', error => process.stdout.write(error.message))",
    ].join('\n')], { encoding: 'utf8', env })
    assert.equal(blocked.error, undefined)
    assert.equal(blocked.status, 0, blocked.stderr)
    assert.match(blocked.stdout, /blocked unexpected HTTPS request/)

    const escaped = spawnSync(process.execPath, ['-e', [
      "'use strict'",
      "const childProcess = require('node:child_process')",
      "const cluster = require('node:cluster')",
      "const dgram = require('node:dgram')",
      "const dns = require('node:dns')",
      "const dnsPromises = require('node:dns/promises')",
      "const http = require('node:http')",
      "const inspector = require('node:inspector')",
      "const net = require('node:net')",
      "const { Worker } = require('node:worker_threads')",
      'const sync = {}',
      'let coercions = 0',
      "const coercingBinding = { [Symbol.toPrimitive]() { coercions += 1; return 'tcp_wrap' } }",
      'const capture = (name, operation) => { try { operation(); sync[name] = \'returned\' } catch (error) { sync[name] = error.code } }',
      "capture('spawnSync', () => childProcess.spawnSync(process.execPath, ['-e', 'require(\\\"node:net\\\").createServer().listen(0)'], { env: {} }))",
      "capture('childPrototype', () => new childProcess.ChildProcess().spawn({ file: process.execPath, args: [process.execPath] }))",
      "capture('worker', () => new Worker('require(\\\"node:net\\\").createServer().listen(0)', { eval: true, execArgv: [], env: {} }))",
      "capture('cluster', () => cluster.fork())",
      "capture('processSpawnBinding', () => process.binding('spawn_sync'))",
      "capture('processTcpBinding', () => process.binding('tcp_wrap'))",
      "capture('processBoxedBinding', () => process.binding(new String('tcp_wrap')))",
      "capture('processCoercingBinding', () => process.binding(coercingBinding))",
      "capture('processLinkedBinding', () => process._linkedBinding('tcp_wrap'))",
      "if (typeof process._kill === 'function') capture('processKill', () => process._kill(process.pid, 0))",
      "capture('listener', () => new net.Server().listen(0))",
      "capture('datagram', () => new dgram.Socket())",
      "capture('clientRequest', () => new http.ClientRequest('http://127.0.0.1:9'))",
      "capture('inspector', () => inspector.open(0, '127.0.0.1'))",
      "capture('resolver', () => new dns.Resolver())",
      "capture('setServers', () => dns.setServers(['127.0.0.1']))",
      "capture('promiseSetServers', () => dnsPromises.setServers(['127.0.0.1']))",
      "capture('mutateWorker', () => { require('node:worker_threads').Worker = class EscapedWorker {} })",
      'const requestCode = request => new Promise((resolve, reject) => request.on(\'error\', error => error.code ? resolve(error.code) : reject(error)))',
      'const asyncChecks = [',
      "  dnsPromises.lookup('example.invalid').then(() => 'returned', error => error.code),",
      "  fetch('https://example.invalid').then(() => 'returned', error => error.code),",
      "  requestCode(net.connect(443, 'example.invalid')),",
      ']',
      "if (typeof dns.resolveTlsa === 'function') asyncChecks.push(new Promise((resolve, reject) => dns.resolveTlsa('example.invalid', error => error?.code ? resolve(error.code) : reject(error ?? new Error('returned')))))",
      'Promise.all(asyncChecks).then(asyncCodes => process.stdout.write(JSON.stringify({ asyncCodes, coercions, descriptors: {',
      "  child: Object.getOwnPropertyDescriptor(childProcess, 'spawnSync').writable,",
      "  listener: Object.getOwnPropertyDescriptor(net.Server.prototype, 'listen').writable,",
      "  worker: Object.getOwnPropertyDescriptor(require('node:worker_threads'), 'Worker').writable,",
      '}, sync })))',
    ].join('\n')], { encoding: 'utf8', env })
    assert.equal(escaped.error, undefined)
    assert.equal(escaped.status, 0, escaped.stderr)
    const boundary = JSON.parse(escaped.stdout)
    assert.deepEqual(boundary.descriptors, { child: false, listener: false, worker: false })
    assert.equal(boundary.coercions, 0)
    assert.equal(boundary.sync.mutateWorker, undefined)
    for (const [operation, code] of Object.entries(boundary.sync)) {
      assert.equal(
        code,
        operation.includes('Tcp') || [
          'clientRequest', 'datagram', 'inspector', 'listener', 'resolver',
          'setServers', 'promiseSetServers',
        ].includes(operation)
          ? 'ZIGCSS_NETWORK_DISABLED'
          : 'ZIGCSS_PROCESS_DISABLED',
        `${operation} escaped the asset boundary`,
      )
    }
    assert.equal(boundary.asyncCodes.every(code => code === 'ZIGCSS_NETWORK_DISABLED'), true)

    const runtimeFixture = runtimeTraceFixture(temporary)
    const runtimeBlocked = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.6.0-rc.2/${archive}', () => { process.exitCode = 2 })`,
      "  .on('error', error => process.stdout.write(error.message))",
    ].join('\n')], {
      encoding: 'utf8',
      env: runtimeFixture.env,
    })
    assert.equal(runtimeBlocked.error, undefined)
    assert.equal(runtimeBlocked.status, 0, runtimeBlocked.stderr)
    assert.equal(runtimeBlocked.stdout, 'release smoke blocked https.get')
    const runtimeRecords = fs.readFileSync(runtimeFixture.trace, 'utf8')
      .trimEnd()
      .split('\n')
      .map(line => JSON.parse(line))
    assert.equal(runtimeRecords.at(-1).nativeSpawns, 0)
    assert.equal(runtimeRecords.at(-1).networkAttempts, 1)
    assert.equal(runtimeRecords.at(-1).deniedProcessAttempts, 0)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm lifecycle preload serves descriptor-admitted assets through Yarn PnP fs interposition', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-pnp-'))
  try {
    const archive = 'zigcss-v0.6.0-rc.2-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.6.0-rc.2-aarch64-macos.sha256'
    fs.writeFileSync(path.join(temporary, archive), 'archive fixture')
    fs.writeFileSync(path.join(temporary, checksums), 'manifest fixture')
    const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
    const result = spawnSync(process.execPath, ['-e', [
      "const fs = require('node:fs')",
      "const https = require('node:https')",
      "fs.createReadStream = pathValue => { throw new Error(pathValue === undefined ? 'Unsupported path type' : 'unexpected path reopen') }",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.6.0-rc.2/${archive}', response => {`,
      "  let text = ''",
      "  response.setEncoding('utf8')",
      "  response.on('data', chunk => { text += chunk })",
      "  response.on('end', () => process.stdout.write(text))",
      "}).on('error', error => { throw error })",
    ].join('\n')], {
      encoding: 'utf8',
      env: {
        ...process.env,
        NODE_OPTIONS: `--require="${preload}"`,
        ZIGCSS_RELEASE_SMOKE: '1',
        ZIGCSS_RELEASE_SMOKE_ARCHIVE: archive,
        ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: temporary,
        ZIGCSS_RELEASE_SMOKE_CHECKSUMS: checksums,
        ZIGCSS_RELEASE_SMOKE_VERSION: '0.6.0-rc.2',
      },
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, 'archive fixture')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

function checkNpmLifecyclePaths(t, pathVariant) {
  let temporaryBase = os.tmpdir()
  const temporaryEnvironment = {}
  if (pathVariant === 'OS path aliases' && process.platform !== 'win32') {
    const aliasRoot = fs.mkdtempSync(path.join(temporaryBase, 'zigcss-release-lifecycle-alias-'))
    t.after(() => fs.rmSync(aliasRoot, { recursive: true, force: true }))
    const realRoot = path.join(aliasRoot, 'real')
    const linkedRoot = path.join(aliasRoot, 'linked')
    fs.mkdirSync(realRoot, { mode: 0o700 })
    fs.symlinkSync(realRoot, linkedRoot, 'dir')
    temporaryBase = linkedRoot
    temporaryEnvironment.TMPDIR = linkedRoot
  }
  const createdTemporary = fs.mkdtempSync(path.join(temporaryBase, 'zigcss-release-lifecycle-'))
  t.after(() => fs.rmSync(createdTemporary, { recursive: true, force: true }))
  const canonicalTemporary = fs.realpathSync(createdTemporary)
  const temporary = pathVariant === 'OS path aliases' && process.platform === 'win32'
    ? canonicalTemporary.replace(/^[A-Za-z]/, letter => letter === letter.toUpperCase()
      ? letter.toLowerCase()
      : letter.toUpperCase())
    : createdTemporary
  if (pathVariant === 'OS path aliases') {
    assert.notEqual(temporary, canonicalTemporary, 'fixture must exercise a real path alias')
  }
  let descriptor
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
    descriptor = repositoryInstaller.releaseDescriptor(manifest.version, process.platform, process.arch)
  } catch (error) {
    t.skip(`current host is not a release target: ${error.message}`)
    return
  }

  const releaseRoot = path.join(temporary, 'release')
  const binaryRoot = path.join(temporary, 'binary')
  const packageRoot = path.join(temporary, 'package')
  const packRoot = path.join(temporary, 'pack')
  const consumer = path.join(temporary, 'consumer')
  for (const directory of [releaseRoot, binaryRoot, packRoot, consumer]) {
    fs.mkdirSync(directory, { mode: 0o700 })
  }
  const binary = path.join(binaryRoot, descriptor.binaryName)
  fs.copyFileSync(process.execPath, binary, fs.constants.COPYFILE_EXCL)
  if (process.platform !== 'win32') fs.chmodSync(binary, 0o755)
  repositoryInstaller.assertBinaryMatchesTarget(binary, descriptor.target)
  const archive = path.join(releaseRoot, descriptor.assets.archive)
  const integrity = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'native-integrity.json'), 'utf8'))
  createReleaseArchive({ archive, binary, sourceDateEpoch: integrity.sourceDateEpoch })
  const digest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex')
  const sbomDigest = crypto.createHash('sha256').update('release lifecycle fixture SBOM\n').digest('hex')
  fs.writeFileSync(
    path.join(releaseRoot, descriptor.assets.checksums),
    `${digest}  ${descriptor.assets.archive}\n${sbomDigest}  ${descriptor.assets.sbom}\n`,
    { encoding: 'utf8', flag: 'wx', mode: 0o600 },
  )
  stageDevelopmentPackage(repositoryRoot, packageRoot, descriptor.target, digest)
  fs.writeFileSync(
    path.join(consumer, 'package.json'),
    '{"name":"zigcss-release-lifecycle-consumer","private":true,"version":"1.0.0"}\n',
    { encoding: 'utf8', flag: 'wx', mode: 0o600 },
  )

  const npmCli = localNpmCliPath()
  const npmEnvironment = {
    ...process.env,
    ...temporaryEnvironment,
    npm_config_audit: 'false',
    npm_config_cache: path.join(temporary, 'npm-cache'),
    npm_config_fund: 'false',
    npm_config_update_notifier: 'false',
  }
  const packed = spawnSync(process.execPath, [npmCli,
    'pack', packageRoot, '--ignore-scripts', '--pack-destination', packRoot,
  ], { cwd: temporary, encoding: 'utf8', env: npmEnvironment })
  assert.equal(packed.error, undefined)
  assert.equal(packed.status, 0, packed.stderr)
  const packageArchive = path.join(packRoot, `zigcss-${descriptor.version}.tgz`)
  const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
  const shadowRoot = path.join(temporary, 'path-shadow')
  const shadowMarker = path.join(temporary, 'shadow-executed')
  fs.mkdirSync(shadowRoot, { mode: 0o700 })
  if (process.platform === 'win32') {
    fs.writeFileSync(
      path.join(shadowRoot, 'node.cmd'),
      `@echo shadow>"${shadowMarker}"\r\n@exit /b 97\r\n`,
      { encoding: 'utf8', flag: 'wx', mode: 0o700 },
    )
  } else {
    fs.writeFileSync(
      path.join(shadowRoot, 'node'),
      `#!/bin/sh\nprintf shadow > '${shadowMarker}'\nexit 97\n`,
      { encoding: 'utf8', flag: 'wx', mode: 0o700 },
    )
  }
  const installed = spawnSync(process.execPath, [npmCli,
    'install', packageArchive, '--offline', '--foreground-scripts', '--no-audit', '--no-fund',
  ], {
    cwd: consumer,
    encoding: 'utf8',
    env: {
      ...npmEnvironment,
      NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: descriptor.assets.archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: releaseRoot,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: descriptor.assets.checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: descriptor.version,
      npm_config_script_shell: pathVariant === 'OS path aliases' && process.platform === 'win32'
        ? lifecycleShellExecutable().toUpperCase()
        : lifecycleShellExecutable(),
      PATH: `${shadowRoot}${path.delimiter}${npmEnvironment.PATH}`,
    },
    timeout: 30_000,
  })
  assert.equal(installed.error, undefined)
  assert.equal(installed.status, 0, installed.stderr || installed.stdout)
  assert.equal(fs.existsSync(shadowMarker), false, 'PATH-shadowed node must never execute')
  const installedBinary = path.join(consumer, 'node_modules', 'zigcss', 'bin', descriptor.binaryName)
  assert.equal(
    crypto.createHash('sha256').update(fs.readFileSync(installedBinary)).digest('hex'),
    crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),
  )
}

for (const pathVariant of ['native paths', 'OS path aliases']) {
  test(`npm lifecycle preload admits one exact installer and two archive operations with ${pathVariant}`, t => {
    checkNpmLifecyclePaths(t, pathVariant)
  })
}

test('development reference provider host installs a process-wide deny-network policy', () => {
  const policy = path.join(repositoryRoot, 'preprocessor', 'network-policy.mjs')
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', [
    "import https from 'node:https'",
    "import net from 'node:net'",
    `const { disableNetworkAccess } = await import(${JSON.stringify(pathToFileURL(policy).href)})`,
    'disableNetworkAccess()',
    "for (const operation of [() => https.get('https://example.invalid'), () => net.connect(443, 'example.invalid')]) {",
    "  try { operation(); process.exit(2) } catch (error) { if (error.code !== 'ZIGCSS_NETWORK_DISABLED') throw error }",
    '}',
    'try { await fetch(\'https://example.invalid\'); process.exit(3) } catch (error) { if (error.code !== \'ZIGCSS_NETWORK_DISABLED\') throw error }',
    "process.stdout.write('denied')",
  ].join('\n')], { encoding: 'utf8' })
  assert.equal(result.error, undefined)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'denied')
})

test('direct native archive compiles the finite five-language syntax set', () => {
  assert.deepEqual(
    nativePreprocessorSmokeCases.map(({ extension, syntax }) => ({ extension, syntax })),
    [
      { extension: 'scss', syntax: 'scss' },
      { extension: 'sass', syntax: 'sass' },
      { extension: 'less', syntax: 'less' },
      { extension: 'styl', syntax: 'stylus' },
    ],
  )
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
  assert.match(source, /function checkNativePreprocessors\(/)
  assert.match(source, /'--experimental-native',[\s\S]*?'--syntax'/)
  assert.match(
    source,
    /const directNativeSmokes = checkNativePreprocessors\(\s*process\.execPath,\s*directArgs,/,
  )
  assert.match(source, /directStylesheetSmokes:\s*1 \+ directNativeSmokes/)
})

test('offline installed native package compiles the finite five-language syntax set', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
  assert.match(
    source,
    /const offlineNativeSmokes = checkNativePreprocessors\(\s*process\.execPath,\s*\[wrapper\],/,
  )
  assert.match(source, /offlinePackageStylesheetSmokes:\s*1 \+ offlineNativeSmokes/)
  assert.doesNotMatch(source, /function checkCanonicalPreprocessors\(/)
  assert.doesNotMatch(source, /function checkCanonicalApi\(/)
  assert.doesNotMatch(source, /zigcss\/api/)
})

test('offline installed package exercises root CommonJS and ESM APIs against the packaged binary', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
  assert.match(source, /function checkInstalledNodeApis\(/)
  assert.match(source, /require\('zigcss'\)/)
  assert.match(source, /import zigcss, \{ compileFile \} from 'zigcss'/)
  assert.match(source, /browsers: 'safari >= 7, ie >= 11'/)
  assert.match(source, /compileFile\(entry, \{ format: 'minified', sourceMap: true \}\)/)
  assert.match(source, /result\.dependencies\[0\]\.url !== pathToFileURL\(dependency\)\.href/)
  assert.match(source, /browsers: 'defaults'/)
  assert.match(source, /error instanceof zigcss\.ZigCssCompileError/)
  assert.match(source, /error\.code !== 'NODE_OPTIONS'/)
  assert.match(source, /'css' in error \|\| 'result' in error/)
  assert.match(source, /const nodeApiSmokes = checkInstalledNodeApis\(consumer, nodeApiEnvironment\)/)
  assert.match(source, /validateRuntimeTrace\(\s*nodeApiRuntimeTrace,\s*nodeApiSmokes\.invocations,/)
  assert.match(source, /offlineNodeApiSmokes: nodeApiSmokes\.compilations,\s*offlineNodeApiOptionRejections: nodeApiSmokes\.optionRejections,\s*offlineNodeApiRuntimeTraces: nodeApiTrace\.invocations/)
})

test('direct native archive runtime trace admits one native child and zero network access', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-runtime-trace-'))
  try {
    const fixture = runtimeTraceFixture(temporary)
    const result = spawnSync(process.execPath, ['-e', [
      "const { spawn } = require('node:child_process')",
      'const child = spawn(process.argv[1], process.argv.slice(2), { stdio: \'inherit\', cwd: process.cwd() })',
      "child.on('error', error => { throw error })",
      "child.on('exit', (code, signal) => { if (signal) process.kill(process.pid, signal); else process.exitCode = code ?? 1 })",
    ].join('\n'), fixture.native, ...fixture.nativeArgs], {
      encoding: 'utf8',
      env: fixture.env,
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    const records = fs.readFileSync(fixture.trace, 'utf8')
      .trimEnd()
      .split('\n')
      .map(line => JSON.parse(line))
    assert.deepEqual(records.map(record => record.event), [
      'runtime-start',
      'native-spawn',
      'runtime-summary',
    ])
    assert.equal(records[0].pid, records[1].pid)
    assert.equal(records[1].pid, records[2].pid)
    assert.deepEqual(records[2], {
      event: 'runtime-summary',
      pid: records[0].pid,
      nativeSpawns: 1,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    })

    const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
    assert.match(source, /const directRuntimeTrace = createRuntimeTrace\(/)
    assert.match(source, /validateRuntimeTrace\(directRuntimeTrace, 6,/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('release runtime trace admits only the exact framed Node API spawn shape', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-node-api-trace-'))
  try {
    const fixture = runtimeTraceFixture(temporary)
    const result = spawnSync(process.execPath, ['-e', [
      "const { spawn } = require('node:child_process')",
      "const child = spawn(process.argv[1], ['--internal-node-v1'], { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })",
      'child.stdout.resume()',
      'child.stderr.resume()',
      "child.on('close', () => process.stdout.write('admitted'))",
    ].join('\n'), fixture.native], {
      encoding: 'utf8',
      env: fixture.env,
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, 'admitted')
    const records = fs.readFileSync(fixture.trace, 'utf8')
      .trimEnd()
      .split('\n')
      .map(line => JSON.parse(line))
    assert.deepEqual(records.map(record => record.event), [
      'runtime-start',
      'native-spawn',
      'runtime-summary',
    ])
    assert.equal(records.at(-1).nativeSpawns, 1)
    assert.equal(records.at(-1).networkAttempts, 0)
    assert.equal(records.at(-1).deniedProcessAttempts, 0)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('offline installed native package runtime trace admits one native child and zero network access', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
  const preload = fs.readFileSync(path.join(repositoryRoot, 'scripts/release-smoke-preload.cjs'), 'utf8')
  assert.match(source, /const offlineRuntimeTrace = createRuntimeTrace\(/)
  assert.match(source, /validateRuntimeTrace\(offlineRuntimeTrace, 6,/)
  assert.match(source, /checkCompiler\([\s\S]*?offlineEnvironment,/)
  assert.match(preload, /immutableFunction\(childProcess, 'spawn', function tracedNativeSpawn/)
  assert.match(preload, /immutableFunction\(childProcess\.ChildProcess\.prototype, 'spawn', function guardedChildSpawn/)
  assert.match(preload, /\['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild'\]/)
  for (const token of [
    "immutableFunction(http, 'request'",
    "immutableFunction(https, 'request'",
    "immutableFunction(net, 'connect'",
    "immutableFunction(net.Server.prototype, 'listen'",
    "immutableFunction(tls, 'connect'",
    "immutableFunction(dgram, 'createSocket'",
    'for (const name of Object.keys(dns))',
    'allowedDnsConfigurationFunctions',
    "immutableValue(\n    globalThis,\n    'fetch'",
    "immutableValue(workerThreads, 'Worker'",
  ]) {
    assert.equal(preload.includes(token), true, `missing release boundary anchor ${token}`)
  }

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-runtime-denial-'))
  try {
    const fixture = runtimeTraceFixture(temporary)
    const result = spawnSync(process.execPath, ['-e', [
      "'use strict'",
      "const childProcess = require('node:child_process')",
      "const cluster = require('node:cluster')",
      "const dgram = require('node:dgram')",
      "const dns = require('node:dns')",
      "const dnsPromises = require('node:dns/promises')",
      "const http = require('node:http')",
      "const https = require('node:https')",
      "const inspector = require('node:inspector')",
      "const net = require('node:net')",
      "const workerThreads = require('node:worker_threads')",
      'const codes = []',
      'const networkCodes = []',
      'const native = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY',
      "const nativeArgs = process.platform === 'win32' ? ['/d', '/s', '/c', 'exit 0'] : ['-c', 'exit 0']",
      "const capture = (target, operation) => { try { operation(); target.push('unexpected') } catch (error) { target.push(error.code) } }",
      "const nonCanonicalStdio = ['pipe', 'pipe', 'pipe']",
      'nonCanonicalStdio.extra = true',
      "capture(codes, () => childProcess.spawnSync(process.execPath, ['--version']))",
      "capture(codes, () => new childProcess.ChildProcess().spawn({ file: native, args: [native, ...nativeArgs], cwd: process.cwd(), stdio: 'inherit' }))",
      "capture(codes, () => childProcess.spawn(native, nativeArgs, { stdio: 'inherit', cwd: process.cwd(), shell: native }))",
      "capture(codes, () => childProcess.spawn(native, ['--internal-node-v1', 'extra'], { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }))",
      "capture(codes, () => childProcess.spawn(native, ['--internal-node-v1'], { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], cwd: process.cwd() }))",
      "capture(codes, () => childProcess.spawn(native, ['--internal-node-v1'], { shell: false, windowsHide: true, stdio: nonCanonicalStdio }))",
      "capture(codes, () => new workerThreads.Worker('require(\\\"node:net\\\").createServer().listen(0)', { eval: true, execArgv: [], env: {} }))",
      "capture(codes, () => cluster.fork())",
      "capture(codes, () => process.binding('spawn_sync'))",
      "capture(codes, () => process._linkedBinding('process_wrap'))",
      "if (typeof process.dlopen === 'function') capture(codes, () => process.dlopen({}, '/missing.node'))",
      "if (typeof process._kill === 'function') capture(codes, () => process._kill(process.pid, 0))",
      "capture(networkCodes, () => new dns.Resolver())",
      "capture(networkCodes, () => new net.Server().listen(0))",
      "capture(networkCodes, () => new dgram.Socket())",
      "capture(networkCodes, () => new http.ClientRequest('http://127.0.0.1:9'))",
      "capture(networkCodes, () => inspector.open(0, '127.0.0.1'))",
      "capture(networkCodes, () => process.binding('tcp_wrap'))",
      "capture(networkCodes, () => dns.setServers(['127.0.0.1']))",
      "capture(networkCodes, () => dnsPromises.setServers(['127.0.0.1']))",
      "const requestCode = request => new Promise((resolve, reject) => request.on('error', error => error.code ? resolve(error.code) : reject(error)))",
      "const pending = [requestCode(https.get('https://example.invalid')), requestCode(net.connect(443, 'example.invalid')), fetch('https://example.invalid').then(() => 'unexpected', error => error.code), dnsPromises.lookup('example.invalid').then(() => 'unexpected', error => error.code)]",
      "if (typeof dns.resolveTlsa === 'function') pending.push(new Promise((resolve, reject) => dns.resolveTlsa('example.invalid', error => error?.code ? resolve(error.code) : reject(error ?? new Error('unexpected')))))",
      "Promise.all(pending).then(asyncCodes => process.stdout.write(JSON.stringify({ codes, descriptors: { child: Object.getOwnPropertyDescriptor(childProcess, 'spawnSync').writable, listener: Object.getOwnPropertyDescriptor(net.Server.prototype, 'listen').writable, worker: Object.getOwnPropertyDescriptor(workerThreads, 'Worker').writable }, networkCodes: [...networkCodes, ...asyncCodes] })))",
    ].join('\n')], {
      encoding: 'utf8',
      env: fixture.env,
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    const denial = JSON.parse(result.stdout)
    assert.equal(denial.codes.length >= 10, true)
    assert.equal(denial.codes.every(code => code === 'ZIGCSS_PROCESS_DISABLED'), true)
    assert.equal(denial.networkCodes.length >= 12, true)
    assert.equal(denial.networkCodes.every(code => code === 'ZIGCSS_NETWORK_DISABLED'), true)
    assert.deepEqual(denial.descriptors, { child: false, listener: false, worker: false })
    const records = fs.readFileSync(fixture.trace, 'utf8')
      .trimEnd()
      .split('\n')
      .map(line => JSON.parse(line))
    assert.equal(records.filter(record => record.event === 'process-denied').length, denial.codes.length)
    assert.equal(records.filter(record => record.event === 'network-denied').length, denial.networkCodes.length)
    assert.deepEqual(records.at(-1), {
      event: 'runtime-summary',
      pid: records[0].pid,
      nativeSpawns: 0,
      networkAttempts: denial.networkCodes.length,
      deniedProcessAttempts: denial.codes.length,
    })
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('build and release workflows require native archive and npm installation smokes', () => {
  const build = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const release = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/release.yml'), 'utf8')
  assert.deepEqual(validateReleaseSmokeWorkflowSources(build, release), {
    buildTargets: 5,
    releaseTargets: 5,
    smokeCommands: 2,
    buildTargetReceipts: 5,
    nodeApiCommands: 2,
  })

  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build.replace('- name: Smoke Native Archive and npm Installation', '- name: Removed native smoke'),
      release,
    ),
    /build native smoke step/,
  )
  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build,
      release.replace('ubuntu-24.04-arm', 'ubuntu-latest'),
    ),
    /native runner matrix/,
  )
  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build,
      release.replace('- name: Smoke Native Archive and npm Installation', '- name: Removed native smoke'),
    ),
    /release native smoke step/,
  )
  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build.replace('npm run test:node-api', 'npm run removed-node-api'),
      release,
    ),
    /build packaged Node API/,
  )
  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build,
      release.replace('npm run test:node-api', 'npm run removed-node-api'),
    ),
    /release packaged Node API/,
  )
  assert.throws(
    () => validateReleaseSmokeWorkflowSources(
      build,
      release.replace('--npm-package "$NPM_PACKAGE_ARCHIVE"', '--removed-npm-package'),
    ),
    /release exact npm package argument/,
  )
})

test('build matrix uploads one commit-bound native receipt from every matching runner', () => {
  const build = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const release = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/release.yml'), 'utf8')
  assert.equal(validateReleaseSmokeWorkflowSources(build, release).buildTargetReceipts, 5)

  for (const changed of [
    build.replace(
      '            --commit "$GITHUB_SHA" \\\n            --evidence',
      '            --commit "0000000000000000000000000000000000000000" \\\n            --evidence',
    ),
    build.replace('--evidence "native-target-evidence/${{ matrix.target }}.json"', '--evidence "native-target-evidence/shared.json"'),
    build.replace('native-target-evidence/${{ matrix.target }}.json', 'native-target-evidence/missing.json'),
  ]) {
    assert.throws(
      () => validateReleaseSmokeWorkflowSources(changed, release),
      /native target evidence|receipt/,
    )
  }
})
