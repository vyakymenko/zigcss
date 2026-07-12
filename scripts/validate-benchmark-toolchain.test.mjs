import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  repositoryRoot,
  validateBenchmarkWorkflow,
  validateToolchainContract,
  verifyInstalledToolchain,
} from './validate-benchmark-toolchain.mjs'

test('benchmark competitors are a closed exact manifest synchronized to the npm lock', () => {
  const manifest = validateToolchainContract(repositoryRoot)

  assert.equal(manifest.schemaVersion, 1)
  assert.deepEqual(manifest.competitors, [
    {
      id: 'esbuild',
      package: 'esbuild',
      version: '0.28.1',
      license: 'MIT',
      versionOutput: '0.28.1',
    },
    {
      id: 'lightningcss',
      package: 'lightningcss-cli',
      version: '1.30.1',
      license: 'MPL-2.0',
      versionOutput: 'lightningcss 1.0.0-alpha.66',
    },
  ])
})

test('every competitor executes from its preinstalled checksum-locked native package', () => {
  const tools = verifyInstalledToolchain(repositoryRoot)

  assert.deepEqual(tools.map(tool => ({ id: tool.id, version: tool.version })), [
    { id: 'esbuild', version: '0.28.1' },
    { id: 'lightningcss', version: '1.30.1' },
  ])
  for (const tool of tools) {
    assert.equal(path.isAbsolute(tool.executable), true)
    assert.equal(fs.lstatSync(tool.executable).isFile(), true)
    assert.equal(fs.lstatSync(tool.executable).isSymbolicLink(), false)
    assert.equal(path.relative(path.join(repositoryRoot, 'node_modules'), tool.executable).startsWith('..'), false)
  }
})

test('toolchain validation rejects version drift, ranges, and unowned competitors', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-toolchain-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks'), { recursive: true })

  for (const file of ['package.json', 'package-lock.json']) {
    fs.copyFileSync(path.join(repositoryRoot, file), path.join(root, file))
  }
  fs.copyFileSync(
    path.join(repositoryRoot, 'benchmarks', 'toolchain.json'),
    path.join(root, 'benchmarks', 'toolchain.json'),
  )

  const manifestPath = path.join(root, 'benchmarks', 'toolchain.json')
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  manifest.competitors.push({ id: 'ambient', package: 'ambient', version: '1.0.0', license: 'MIT' })
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  assert.throws(() => validateToolchainContract(root), /manifest does not match the closed competitor inventory/)

  fs.copyFileSync(
    path.join(repositoryRoot, 'benchmarks', 'toolchain.json'),
    manifestPath,
  )
  const packagePath = path.join(root, 'package.json')
  const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
  packageJson.devDependencies.esbuild = '^0.28.1'
  fs.writeFileSync(packagePath, JSON.stringify(packageJson))
  assert.throws(() => validateToolchainContract(root), /package\.json must pin esbuild to 0\.28\.1/)

  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), packagePath)
  const lockPath = path.join(root, 'package-lock.json')
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
  lock.packages['node_modules/esbuild'].version = '0.28.0'
  fs.writeFileSync(lockPath, JSON.stringify(lock))
  assert.throws(() => validateToolchainContract(root), /lockfile must pin esbuild to 0\.28\.1/)
})

test('legacy networked benchmark runner and unverifiable timing archives are absent', () => {
  for (const file of [
    'benchmark-competitors.js',
    'benchmark-results.json',
    'benchmark-tailwind-results.json',
  ]) {
    assert.equal(fs.existsSync(path.join(repositoryRoot, file)), false, `${file} must not remain an active benchmark surface`)
  }

  const validator = fs.readFileSync(path.join(repositoryRoot, 'scripts', 'validate-benchmark-toolchain.mjs'), 'utf8')
  assert.doesNotMatch(validator, /\bnpx\b|npm install|-g\b|shell:\s*true/)
})

test('benchmark toolchain check is required after locked install and before execution', () => {
  assert.equal(validateBenchmarkWorkflow(repositoryRoot), true)

  const result = spawnSync(process.execPath, ['scripts/validate-benchmark-toolchain.mjs', '--check'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(
    result.stdout,
    'Benchmark toolchain verified: esbuild 0.28.1, lightningcss 1.30.1; 2 local checksum-locked executables.\n',
  )
})
