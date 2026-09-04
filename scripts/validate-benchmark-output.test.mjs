import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  admitTimingSample,
  benchmarkCompilerPath,
  renderZigCssStderr,
  repositoryRoot,
  validateBenchmarkOutputContract,
  validateBenchmarkOutputWorkflow,
  validateOutput,
} from './validate-benchmark-output.mjs'

const input =
  '.component-0000{color:#aabbcc;background:#112233;padding:0px 0px;margin:0px;border-radius:0px}\n'
const equivalentOutput =
  '.component-0000{border-radius:0;margin:0;padding:0;background:#123;color:#abc}'

test('ZigCSS benchmark stderr is exact for stable and prerelease compilers', () => {
  assert.equal(
    renderZigCssStderr('0.7.0-rc.1', '/input.css', '/output.css'),
    'Warning: ZigCSS 0.7.0-rc.1 is an experimental release candidate; do not use it for production CSS.\n' +
      'Compiled: /input.css -> /output.css\n',
  )
  assert.equal(
    renderZigCssStderr('0.7.0', '/input.css', '/output.css'),
    'Compiled: /input.css -> /output.css\n',
  )
  assert.throws(
    () => renderZigCssStderr('v0.7.0-rc.1', '/input.css', '/output.css'),
    /not canonical Semantic Versioning/,
  )
})

test('benchmark output validation accepts only recovery-free semantic equivalence', () => {
  const report = validateOutput(input, equivalentOutput, 'equivalent fixture')

  assert.equal(report.inputBytes, Buffer.byteLength(input))
  assert.equal(report.outputBytes, Buffer.byteLength(equivalentOutput))
  assert.match(report.canonicalSha256, /^[0-9a-f]{64}$/)
})

test('benchmark compiler selection is pinned to the repository ReleaseFast binary', () => {
  const expected = path.join(
    repositoryRoot,
    'zig-out',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  )
  assert.equal(benchmarkCompilerPath(repositoryRoot, undefined), expected)
  assert.equal(benchmarkCompilerPath(repositoryRoot, expected), expected)
  assert.throws(
    () => benchmarkCompilerPath(repositoryRoot, path.join(repositoryRoot, 'attacker-controlled')),
    /repository ReleaseFast binary/,
  )
})

test('invalid output cannot enter a timing sample collection', () => {
  const corruptions = [
    '',
    '.component-0000{color:#abc',
    '.component-0000{color:#abc;background:#123;padding:0;margin:0}',
    '.component-0000{color:red;background:#123;padding:0;margin:0;border-radius:0}',
    `${equivalentOutput}.unexpected{color:red}`,
  ]

  for (const output of corruptions) {
    const samples = []
    assert.throws(
      () => admitTimingSample(samples, 17n, input, output, 'corrupt fixture'),
      /benchmark output:/,
    )
    assert.deepEqual(samples, [])
  }

  const samples = []
  assert.throws(
    () => admitTimingSample(samples, 0n, input, equivalentOutput, 'zero-duration fixture'),
    /duration must be a positive bigint/,
  )
  assert.deepEqual(samples, [])
  admitTimingSample(samples, 17n, input, equivalentOutput, 'equivalent fixture')
  assert.deepEqual(samples, [17n])
})

test('output acceptance manifest is closed and synchronized to the installed oracle', () => {
  const manifest = validateBenchmarkOutputContract(repositoryRoot)

  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.oracle.package, 'lightningcss')
  assert.equal(manifest.oracle.version, '1.30.1')
  assert.equal(manifest.oracle.errorRecovery, false)
  assert.deepEqual(manifest.corpora, ['small-flat', 'medium-flat', 'large-flat'])
  assert.deepEqual(manifest.tools.map(tool => tool.id), ['zigcss', 'esbuild', 'lightningcss'])
})

test('output acceptance rejects manifest drift and symlink substitution', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-output-contract-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks'), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), path.join(root, 'package.json'))
  const source = path.join(repositoryRoot, 'benchmarks', 'output-validation.json')
  const target = path.join(root, 'benchmarks', 'output-validation.json')
  fs.copyFileSync(source, target)

  const manifest = JSON.parse(fs.readFileSync(target, 'utf8'))
  manifest.oracle.errorRecovery = true
  fs.writeFileSync(target, `${JSON.stringify(manifest, null, 2)}\n`)
  assert.throws(
    () => validateBenchmarkOutputContract(root),
    /manifest does not match the closed acceptance contract/,
  )

  fs.rmSync(target)
  fs.symlinkSync(source, target)
  assert.throws(() => validateBenchmarkOutputContract(root), /must be a regular non-symlink file/)
})

test('workflow validates every tool output before the benchmark smoke can run', () => {
  assert.equal(validateBenchmarkOutputWorkflow(repositoryRoot), true)

  const benchmarkSource = fs.readFileSync(path.join(repositoryRoot, 'src', 'benchmarks.zig'), 'utf8')
  const legacyProfiler = fs.readFileSync(path.join(repositoryRoot, 'src', 'profiler.zig'), 'utf8')
  assert.doesNotMatch(benchmarkSource, /parser\.zig|optimizer\.zig|codegen\.zig|nanoTimestamp|benchmarkCompilation/)
  assert.match(benchmarkSource, /zigcss\.compile/)
  assert.match(benchmarkSource, /equivalence\.equivalent/)
  assert.doesNotMatch(legacyProfiler, /benchmarkCompilation|BenchmarkResult/)
})

test('workflow output validation cannot be removed or moved after the smoke', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-output-workflow-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true })
  const source = fs.readFileSync(path.join(repositoryRoot, '.github', 'workflows', 'build.yml'), 'utf8')
  fs.writeFileSync(
    path.join(root, '.github', 'workflows', 'build.yml'),
    source.replace('- name: Validate benchmark outputs', '- name: Removed benchmark output gate'),
  )

  assert.throws(
    () => validateBenchmarkOutputWorkflow(root),
    /validate every benchmark output before the benchmark smoke/,
  )
})
