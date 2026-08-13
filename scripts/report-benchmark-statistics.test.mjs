import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  repositoryRoot,
  summarizeSamples,
  validateBenchmarkReport,
  validateBenchmarkStatisticsContract,
  validateBenchmarkStatisticsWorkflow,
} from './report-benchmark-statistics.mjs'

const samples = Array.from({ length: 20 }, (_, index) => String(index + 1))

function sampleReport() {
  const statistics = summarizeSamples(samples)
  return {
    schemaVersion: 1,
    generatedAt: '2026-07-13T00:00:00.000Z',
    environment: {
      platform: 'linux',
      release: 'fixture',
      architecture: 'x64',
      cpuModel: 'fixture cpu',
      logicalCpuCount: 4,
      totalMemoryBytes: '1073741824',
      nodeVersion: 'v22.0.0',
      zigVersion: '0.15.2',
      optimizationMode: 'ReleaseFast',
      clock: 'monotonic-nanoseconds',
      runnerExecutableSha256: 'e'.repeat(64),
      tools: [
        { id: 'zigcss', version: '0.6.0-rc.2', executableSha256: 'a'.repeat(64) },
        { id: 'esbuild', version: '0.28.1', executableSha256: 'b'.repeat(64) },
        { id: 'lightningcss', version: '1.30.1', executableSha256: 'c'.repeat(64) },
      ],
    },
    corpus: {
      version: 'v1',
      manifestSha256: 'd'.repeat(64),
    },
    series: [
      {
        mode: 'cold-cli',
        metric: 'latency-nanoseconds',
        tool: 'zigcss',
        corpus: 'small-flat',
        unit: 'nanoseconds',
        samples,
        statistics,
      },
    ],
  }
}

test('statistics report exact median, nearest-rank p95, and population variance', () => {
  assert.deepEqual(summarizeSamples(samples), {
    count: 20,
    median: '10.5',
    p95: '19',
    variance: '33.25',
  })
})

test('statistics reject incomplete, negative, unsafe, and altered raw samples', () => {
  assert.throws(() => summarizeSamples(samples.slice(1)), /exactly 20 raw samples/)
  assert.throws(() => summarizeSamples([...samples.slice(0, 19), '-1']), /unsigned decimal/)
  assert.throws(
    () => summarizeSamples([...samples.slice(0, 19), '18446744073709551616']),
    /64-bit range/,
  )

  const report = sampleReport()
  report.series[0].statistics.p95 = '20'
  assert.throws(() => validateBenchmarkReport(report, { requireCompleteSeries: false }), /statistics drifted/)
})

test('statistics contract is closed and requires twenty measured observations', () => {
  const contract = validateBenchmarkStatisticsContract(repositoryRoot)
  assert.equal(contract.schemaVersion, 1)
  assert.equal(contract.sampleCount, 20)
  assert.deepEqual(contract.statistics, {
    median: 'sorted-middle-average',
    p95: 'nearest-rank',
    variance: 'population',
  })
  assert.equal(contract.rawSamples, 'required')
  assert.equal(contract.sampleEncoding, 'unsigned-decimal-string')
})

test('statistics manifest drift and symlink substitution fail closed', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-statistics-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks'), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), path.join(root, 'package.json'))
  fs.copyFileSync(
    path.join(repositoryRoot, 'benchmarks', 'modes.json'),
    path.join(root, 'benchmarks', 'modes.json'),
  )
  const source = path.join(repositoryRoot, 'benchmarks', 'statistics.json')
  const target = path.join(root, 'benchmarks', 'statistics.json')
  fs.copyFileSync(source, target)

  const contract = JSON.parse(fs.readFileSync(target, 'utf8'))
  contract.sampleCount = 1
  fs.writeFileSync(target, `${JSON.stringify(contract, null, 2)}\n`)
  assert.throws(
    () => validateBenchmarkStatisticsContract(root),
    /statistics manifest does not match the closed reporting contract/,
  )

  fs.rmSync(target)
  fs.symlinkSync(source, target)
  assert.throws(() => validateBenchmarkStatisticsContract(root), /regular non-symlink file/)
})

test('reports retain raw samples and complete environment metadata', () => {
  const report = sampleReport()
  assert.equal(validateBenchmarkReport(report, { requireCompleteSeries: false }), true)

  delete report.environment.cpuModel
  assert.throws(() => validateBenchmarkReport(report, { requireCompleteSeries: false }), /environment/)
})

test('workflow builds optimized runners and reports statistics after mode validation', () => {
  assert.equal(validateBenchmarkStatisticsWorkflow(repositoryRoot), true)

  const source = fs.readFileSync(path.join(repositoryRoot, 'src', 'benchmarks.zig'), 'utf8')
  assert.match(source, /--raw-report/)
  assert.match(source, /statistical_sample_count = 20/)
  assert.match(source, /ReleaseFast/)
  assert.match(source, /std\.json\.Stringify/)
  assert.doesNotMatch(source, /std\.debug\.print\([^)]*duration_ns/)
})
