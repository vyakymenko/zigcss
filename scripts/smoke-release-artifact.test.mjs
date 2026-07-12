import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  nativeSmokeTargets,
  parseSmokeArguments,
  validateReleaseSmokeWorkflowSources,
} from './smoke-release-artifact.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

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
      runner: 'macos-latest',
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
    '--archive', 'release-assets/zigcss-v0.4.0-rc.1-aarch64-macos.tar.gz',
    '--binary', 'zig-out/bin/zigcss',
    '--target', 'aarch64-macos',
    '--version', '0.4.0-rc.1',
  ]), {
    archive: 'release-assets/zigcss-v0.4.0-rc.1-aarch64-macos.tar.gz',
    binary: 'zig-out/bin/zigcss',
    target: 'aarch64-macos',
    version: '0.4.0-rc.1',
  })

  for (const invalid of [
    [],
    ['--target', 'aarch64-macos'],
    ['--archive', 'a', '--binary', 'b', '--target', 'unknown', '--version', '0.4.0-rc.1'],
    ['--archive', 'a', '--binary', 'b', '--target', 'aarch64-macos', '--version', '../tag'],
    ['--archive', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.4.0-rc.1'],
    ['--unknown', 'a', '--archive', 'b', '--binary', 'c', '--target', 'aarch64-macos', '--version', '0.4.0-rc.1'],
  ]) {
    assert.throws(() => parseSmokeArguments(invalid), /release smoke integrity/)
  }
})

test('npm lifecycle preload serves only the two exact local release URLs', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-preload-'))
  try {
    const archive = 'zigcss-v0.4.0-rc.1-aarch64-macos.tar.gz'
    const checksums = 'zigcss-v0.4.0-rc.1-aarch64-macos.sha256'
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
      ZIGCSS_RELEASE_SMOKE_VERSION: '0.4.0-rc.1',
    }
    const allowed = spawnSync(process.execPath, ['-e', [
      "const https = require('node:https')",
      `https.get('https://github.com/vyakymenko/zigcss/releases/download/v0.4.0-rc.1/${checksums}', response => {`,
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
