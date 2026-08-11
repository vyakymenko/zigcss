import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  archiveExecutable,
  nativePreprocessorSmokeCases,
  nativeSmokeTargets,
  parseSmokeArguments,
  validateReleaseSmokeWorkflowSources,
} from './smoke-release-artifact.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

function runtimeTraceFixture(temporary) {
  const archive = 'zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz'
  const checksums = 'zigcss-v0.5.0-rc.1-aarch64-macos.sha256'
  const trace = path.join(temporary, 'runtime-trace.jsonl')
  fs.writeFileSync(path.join(temporary, archive), 'archive fixture')
  fs.writeFileSync(path.join(temporary, checksums), 'manifest fixture')
  fs.writeFileSync(trace, '')
  const preload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
  const nativeInput = process.platform === 'win32'
    ? process.env.ComSpec
    : '/bin/sh'
  assert.equal(typeof nativeInput, 'string')
  const nativeSource = fs.realpathSync(nativeInput)
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
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.5.0-rc.1',
      ZIGCSS_RELEASE_SMOKE_RUNTIME: '1',
      ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY: native,
      ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE: trace,
      ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT: temporary,
    },
  }
}

test('Windows release smoke selects the native archive reader instead of Git tar', () => {
  assert.equal(archiveExecutable('linux'), 'tar')
  assert.equal(archiveExecutable('darwin'), 'tar')
  assert.equal(
    archiveExecutable('win32', 'D:\\Windows'),
    'D:\\Windows\\System32\\tar.exe',
  )
  assert.throws(() => archiveExecutable('win32', undefined), /Windows system root/)
  assert.throws(() => archiveExecutable('win32', '\\\\server\\Windows'), /Windows system root/)
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

test('smoke CLI accepts only the exact archive, binary, target, and version contract', () => {
  assert.deepEqual(parseSmokeArguments([
    '--archive', 'release-assets/zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.5.0-rc.1',
  ]), {
    archive: 'release-assets/zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.5.0-rc.1',
  })

  const commit = '0123456789abcdef0123456789abcdef01234567'
  assert.deepEqual(parseSmokeArguments([
    '--archive', 'release-assets/zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.5.0-rc.1',
    '--commit', commit,
    '--evidence', 'native-target-evidence/aarch64-macos.json',
  ]), {
    archive: 'release-assets/zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.5.0-rc.1',
    commit,
    evidence: 'native-target-evidence/aarch64-macos.json',
  })

  for (const invalid of [
    [],
    ['--target', 'aarch64-macos'],
    ['--archive', 'a', '--binary', 'b', '--target', 'unknown', '--version', '0.5.0-rc.1'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '../tag'],
    ['--archive', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.5.0-rc.1'],
    ['--unknown', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.5.0-rc.1'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.5.0-rc.1', '--commit', commit],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.5.0-rc.1', '--commit', 'ABC', '--evidence', 'native-target-evidence/aarch64-macos.json'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '0.5.0-rc.1', '--commit', commit, '--evidence', '../aarch64-macos.json'],
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
    npmPackage: 'zigcss-0.5.0-rc.1.tgz',
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
  }
  const evidence = smoke.nativeTargetEvidence(result, {
    commit,
    version: '0.5.0-rc.1',
    platform: 'darwin',
    arch: 'arm64',
  })
  assert.deepEqual(evidence, {
    schemaVersion: 1,
    commit,
    version: '0.5.0-rc.1',
    target: 'aarch64-macos',
    runner: 'macos-15',
    host: {
      platform: 'darwin',
      arch: 'arm64',
    },
    languages: ['css', 'scss', 'sass', 'less', 'stylus'],
    artifacts: {
      archive: 'zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz',
      archiveSha256: 'a'.repeat(64),
      binary: 'zigcss',
      binarySha256: 'b'.repeat(64),
      checksums: 'zigcss-v0.5.0-rc.1-aarch64-macos.sha256',
      checksumsSha256: 'c'.repeat(64),
      npmPackage: 'zigcss-0.5.0-rc.1.tgz',
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
      version: '0.5.0-rc.1',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /commit/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence({ ...result, directStylesheetSmokes: 4 }, {
      commit,
      version: '0.5.0-rc.1',
      platform: 'darwin',
      arch: 'arm64',
    }),
    /five-language/,
  )
  assert.throws(
    () => smoke.nativeTargetEvidence(result, {
      commit,
      version: '0.5.0-rc.1',
      platform: 'darwin',
      arch: 'x64',
    }),
    /matching runner/,
  )
})

test('npm lifecycle preload serves only the two exact local release URLs', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-'))
  try {
    const archive = 'zigcss-v0.5.0-rc.1-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.5.0-rc.1-aarch64-macos.sha256'
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
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.5.0-rc.1',
    }
    const allowed = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.5.0-rc.1/${checksums}', response => {`,
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

    const runtimeFixture = runtimeTraceFixture(temporary)
    const runtimeBlocked = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.5.0-rc.1/${archive}', () => { process.exitCode = 2 })`,
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

test('offline installed native package runtime trace admits one native child and zero network access', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'), 'utf8')
  const preload = fs.readFileSync(path.join(repositoryRoot, 'scripts/release-smoke-preload.cjs'), 'utf8')
  assert.match(source, /const offlineRuntimeTrace = createRuntimeTrace\(/)
  assert.match(source, /validateRuntimeTrace\(offlineRuntimeTrace, 6,/)
  assert.match(source, /checkCompiler\([\s\S]*?offlineEnvironment,/)
  assert.match(preload, /childProcess\.spawn = function tracedNativeSpawn/)
  assert.match(preload, /childProcess\.ChildProcess\.prototype\.spawn = function guardedChildSpawn/)
  assert.match(preload, /\['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild'\]/)
  for (const token of [
    'http.request',
    'https.request',
    'net.connect',
    'net.Server.prototype.listen',
    'tls.connect',
    'dgram.createSocket',
    'dns.lookup',
    'globalThis.fetch',
  ]) {
    assert.match(preload, new RegExp(token.replaceAll('.', '\\.')))
  }

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-runtime-denial-'))
  try {
    const fixture = runtimeTraceFixture(temporary)
    const result = spawnSync(process.execPath, ['-e', [
      "const childProcess = require('node:child_process')",
      "const dns = require('node:dns')",
      "const https = require('node:https')",
      "const net = require('node:net')",
      'const codes = []',
      "try { childProcess.spawnSync(process.execPath, ['--version']) } catch (error) { codes.push(error.code) }",
      `try { new childProcess.ChildProcess().spawn({ file: ${JSON.stringify(fixture.native)}, args: ${JSON.stringify([fixture.native, ...fixture.nativeArgs])}, cwd: process.cwd(), stdio: 'inherit' }) } catch (error) { codes.push(error.code) }`,
      `try { childProcess.spawn(${JSON.stringify(fixture.native)}, ${JSON.stringify(fixture.nativeArgs)}, { stdio: 'inherit', cwd: process.cwd(), shell: ${JSON.stringify(fixture.native)} }) } catch (error) { codes.push(error.code) }`,
      "const resolverCode = (() => { try { new dns.Resolver(); return 'unexpected' } catch (error) { return error.code } })()",
      "const listenerCode = (() => { try { new net.Server().listen(0); return 'unexpected' } catch (error) { return error.code } })()",
      "const requestCode = request => new Promise((resolve, reject) => request.on('error', error => error.code ? resolve(error.code) : reject(error)))",
      "Promise.all([Promise.resolve(resolverCode), Promise.resolve(listenerCode), requestCode(https.get('https://example.invalid')), requestCode(net.connect(443, 'example.invalid')), fetch('https://example.invalid').then(() => 'unexpected', error => error.code)])",
      "  .then(networkCodes => process.stdout.write(JSON.stringify({ codes, networkCodes })))",
    ].join('\n')], {
      encoding: 'utf8',
      env: fixture.env,
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(JSON.parse(result.stdout), {
      codes: [
        'ZIGCSS_PROCESS_DISABLED',
        'ZIGCSS_PROCESS_DISABLED',
        'ZIGCSS_PROCESS_DISABLED',
      ],
      networkCodes: [
        'ZIGCSS_NETWORK_DISABLED',
        'ZIGCSS_NETWORK_DISABLED',
        'ZIGCSS_NETWORK_DISABLED',
        'ZIGCSS_NETWORK_DISABLED',
        'ZIGCSS_NETWORK_DISABLED',
      ],
    })
    const records = fs.readFileSync(fixture.trace, 'utf8')
      .trimEnd()
      .split('\n')
      .map(line => JSON.parse(line))
    assert.equal(records.filter(record => record.event === 'process-denied').length, 3)
    assert.equal(records.filter(record => record.event === 'network-denied').length, 5)
    assert.deepEqual(records.at(-1), {
      event: 'runtime-summary',
      pid: records[0].pid,
      nativeSpawns: 0,
      networkAttempts: 5,
      deniedProcessAttempts: 3,
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
