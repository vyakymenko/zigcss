import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  archiveExecutable,
  nativeSmokeTargets,
  parseSmokeArguments,
  validateReleaseSmokeWorkflowSources,
} from './smoke-release-artifact.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

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
    '--archive', 'release-assets/zigcss-v0.4.0-rc.3-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.4.0-rc.3',
  ]), {
    archive: 'release-assets/zigcss-v0.4.0-rc.3-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.4.0-rc.3',
  })

  for (const invalid of [
    [],
    ['--target', 'aarch64-macos'],
    ['--archive', 'a', '--binary', 'b', '--target', 'unknown', '--version', '0.4.0-rc.3'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '../tag'],
    ['--archive', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.4.0-rc.3'],
    ['--unknown', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.4.0-rc.3'],
  ]) {
    assert.throws(() => parseSmokeArguments(invalid), /release smoke integrity/)
  }
})

test('npm lifecycle preload serves only the two exact local release URLs', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-'))
  try {
    const archive = 'zigcss-v0.4.0-rc.3-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.4.0-rc.3-aarch64-macos.sha256'
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
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.4.0-rc.3',
    }
    const allowed = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.4.0-rc.3/${checksums}', response => {`,
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

    const runtimeBlocked = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.4.0-rc.3/${archive}', () => { process.exitCode = 2 })`,
      "  .on('error', error => process.stdout.write(error.message))",
    ].join('\n')], {
      encoding: 'utf8',
      env: { ...env, ZIGCSS_RELEASE_SMOKE_RUNTIME: '1' },
    })
    assert.equal(runtimeBlocked.error, undefined)
    assert.equal(runtimeBlocked.status, 0, runtimeBlocked.stderr)
    assert.match(runtimeBlocked.stdout, /blocked unexpected HTTPS request/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('canonical provider host installs a process-wide deny-network policy', () => {
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

test('build and release workflows require native archive and npm installation smokes', () => {
  const build = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const release = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/release.yml'), 'utf8')
  assert.deepEqual(validateReleaseSmokeWorkflowSources(build, release), {
    buildTargets: 5,
    releaseTargets: 5,
    smokeCommands: 2,
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
