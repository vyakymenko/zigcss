import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  admitThroughputSample,
  repositoryRoot,
  validateBenchmarkModeContract,
  validateBenchmarkModeWorkflow,
} from './validate-benchmark-modes.mjs'

const input = '.fixture{color:#aabbcc;margin:0px}\n'
const output = '.fixture{margin:0;color:#abc}'

test('benchmark modes are closed, disjoint, and cover comparable tools', () => {
  const manifest = validateBenchmarkModeContract(repositoryRoot)

  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.clock, 'monotonic-nanoseconds')
  assert.equal(manifest.outputValidation, 'after-timing-before-admission')
  assert.deepEqual(manifest.modes.map(mode => mode.id), [
    'cold-cli',
    'warm-cli',
    'in-process-api',
    'memory',
    'throughput',
  ])

  const [cold, warm, api, memory, throughput] = manifest.modes
  assert.deepEqual(cold.tools, ['zigcss', 'esbuild', 'lightningcss'])
  assert.deepEqual(warm.tools, cold.tools)
  assert.deepEqual(api.tools, ['zigcss'])
  assert.deepEqual(throughput.tools, ['zigcss'])
  assert.deepEqual(memory.tools, ['zigcss'])
  assert.equal(cold.warmupIterations, 0)
  assert.ok(warm.warmupIterations > 0)
  assert.equal(cold.cachePreparation, 'no-mode-local-warmup')
  assert.equal(warm.cachePreparation, 'one-validated-mode-local-warmup')
  assert.equal(cold.includesProcessStartup, true)
  assert.equal(warm.includesProcessStartup, true)
  assert.equal(api.includesProcessStartup, false)
  assert.equal(throughput.includesProcessStartup, false)
  assert.equal(memory.timed, false)
  assert.equal(memory.metric, 'allocator-requested-bytes')
})

test('mode manifest drift and symlink substitution fail closed', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-modes-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks'), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), path.join(root, 'package.json'))
  const source = path.join(repositoryRoot, 'benchmarks', 'modes.json')
  const target = path.join(root, 'benchmarks', 'modes.json')
  fs.copyFileSync(source, target)

  const manifest = JSON.parse(fs.readFileSync(target, 'utf8'))
  manifest.modes[0].includesProcessStartup = false
  fs.writeFileSync(target, `${JSON.stringify(manifest, null, 2)}\n`)
  assert.throws(
    () => validateBenchmarkModeContract(root),
    /mode manifest does not match the closed execution contract/,
  )

  fs.rmSync(target)
  fs.symlinkSync(source, target)
  assert.throws(() => validateBenchmarkModeContract(root), /must be a regular non-symlink file/)
})

test('throughput admission validates every timed output before accepting duration', () => {
  const samples = []
  assert.throws(
    () =>
      admitThroughputSample(samples, 19n, [
        { input, output, label: 'valid operation' },
        { input, output: `${output}.extra{color:red}`, label: 'corrupt operation' },
      ]),
    /benchmark output:/,
  )
  assert.deepEqual(samples, [])

  admitThroughputSample(samples, 19n, [
    { input, output, label: 'first operation' },
    { input, output, label: 'second operation' },
  ])
  assert.deepEqual(samples, [19n])
})

test('workflow runs mode validation after output acceptance and before mode smoke', () => {
  assert.equal(validateBenchmarkModeWorkflow(repositoryRoot), true)

  const source = fs.readFileSync(path.join(repositoryRoot, 'src', 'benchmarks.zig'), 'utf8')
  assert.match(source, /\.profile = profile/)
  assert.match(source, /compile\(allocator, corpus, true\)/)
  assert.match(source, /in-process API latency/)
  assert.match(source, /allocator-requested memory/)
  assert.match(source, /in-process throughput/)
  assert.doesNotMatch(source, /std\.debug\.print\([^)]*duration|std\.debug\.print\([^)]*peak_live/s)
})

test('workflow mode validation cannot be removed or moved after the smoke', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-mode-workflow-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true })
  const source = fs.readFileSync(path.join(repositoryRoot, '.github', 'workflows', 'build.yml'), 'utf8')
  fs.writeFileSync(
    path.join(root, '.github', 'workflows', 'build.yml'),
    source.replace('- name: Validate benchmark modes', '- name: Removed benchmark mode gate'),
  )

  assert.throws(
    () => validateBenchmarkModeWorkflow(root),
    /separate benchmark modes after output acceptance and before their smoke/,
  )
})
