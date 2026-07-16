import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

import {
  repositoryRoot,
  validateBenchmarkArchive,
  validateBenchmarkArchiveContract,
  validateBenchmarkArchiveWorkflow,
  validateBenchmarkArchiveWorkflowSource,
  writeBenchmarkArchive,
} from './archive-benchmark-report.mjs'
import { summarizeSamples } from './report-benchmark-statistics.mjs'

const samples = Array.from({ length: 20 }, (_, index) => String(index + 1))
const statistics = summarizeSamples(samples)
const memoryFields = [
  ['totalAllocatedBytes', 'bytes'],
  ['totalFreedBytes', 'bytes'],
  ['peakLiveBytes', 'bytes'],
  ['retainedResultBytes', 'bytes'],
  ['allocationCount', 'count'],
  ['deallocationCount', 'count'],
  ['resizeCount', 'count'],
]
const provenance = {
  commit: 'a'.repeat(40),
  runId: '1234567890123456789',
  runAttempt: '2',
}

function reportedSeries(mode, metric, tool, corpus, unit, field) {
  return {
    mode,
    metric,
    tool,
    corpus,
    ...(field === undefined ? {} : { field }),
    unit,
    samples,
    statistics,
  }
}

function completeReport() {
  const series = []
  for (const mode of ['cold-cli', 'warm-cli']) {
    for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
      for (const tool of ['zigcss', 'esbuild', 'lightningcss']) {
        series.push(reportedSeries(mode, 'latency-nanoseconds', tool, corpus, 'nanoseconds'))
      }
    }
  }
  for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
    series.push(reportedSeries('in-process-api', 'latency-nanoseconds', 'zigcss', corpus, 'nanoseconds'))
  }
  for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
    for (const [field, unit] of memoryFields) {
      series.push(reportedSeries('memory', 'allocator-requested-bytes', 'zigcss', corpus, unit, field))
    }
  }
  series.push(reportedSeries(
    'throughput',
    'input-bytes-per-second',
    'zigcss',
    'all-v1',
    'input-bytes-per-second',
  ))
  return {
    schemaVersion: 1,
    generatedAt: '2026-07-13T00:00:00.000Z',
    environment: {
      platform: 'linux',
      release: '6.8.0-controlled',
      architecture: 'x64',
      cpuModel: 'Controlled Benchmark CPU',
      logicalCpuCount: 8,
      totalMemoryBytes: '17179869184',
      nodeVersion: 'v22.0.0',
      zigVersion: '0.15.2',
      optimizationMode: 'ReleaseFast',
      clock: 'monotonic-nanoseconds',
      runnerExecutableSha256: 'e'.repeat(64),
      tools: [
        { id: 'zigcss', version: '0.4.0-rc.3', executableSha256: 'b'.repeat(64) },
        { id: 'esbuild', version: '0.28.1', executableSha256: 'c'.repeat(64) },
        { id: 'lightningcss', version: '1.30.1', executableSha256: 'd'.repeat(64) },
      ],
    },
    corpus: {
      version: 'v1',
      manifestSha256: 'f'.repeat(64),
    },
    series,
  }
}

function createArchiveDirectory(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-archive-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  fs.writeFileSync(
    path.join(directory, 'benchmark-report.json'),
    `${JSON.stringify(completeReport(), null, 2)}\n`,
    { mode: 0o600 },
  )
  return directory
}

test('archive contract and scheduled controlled-runner workflow are closed', () => {
  const contract = validateBenchmarkArchiveContract(repositoryRoot)
  assert.equal(contract.benchmarkId, 'zigcss-benchmark-v1')
  assert.deepEqual(contract.runner.labels, ['self-hosted', 'linux', 'x64', 'zigcss-benchmark-v1'])
  assert.equal(contract.artifact.retentionDays, 90)
  assert.equal(validateBenchmarkArchiveWorkflow(repositoryRoot), true)
})

test('archive binds a complete validated report to source, run, and hardware identity', t => {
  const directory = createArchiveDirectory(t)
  const manifest = writeBenchmarkArchive(directory, provenance)
  assert.equal(manifest.source.commit, provenance.commit)
  assert.equal(manifest.run.id, provenance.runId)
  assert.equal(manifest.controlledHardware.cpuModel, 'Controlled Benchmark CPU')
  assert.match(manifest.controlledHardware.fingerprint, /^[0-9a-f]{64}$/)
  assert.equal(validateBenchmarkArchive(directory, provenance).report.path, 'benchmark-report.json')
  assert.deepEqual(fs.readdirSync(directory).sort(), ['benchmark-archive.json', 'benchmark-report.json'])

  const checked = spawnSync(process.execPath, [
    'scripts/archive-benchmark-report.mjs',
    '--check',
    '--directory', directory,
    '--commit', provenance.commit,
    '--run-id', provenance.runId,
    '--run-attempt', provenance.runAttempt,
  ], { cwd: repositoryRoot, encoding: 'utf8' })
  assert.equal(checked.status, 0, checked.stderr)
  assert.match(checked.stdout, /Benchmark archive verified: zigcss-benchmark-v1-/)
})

test('report, provenance, manifest, and inventory tampering fail closed', t => {
  const directory = createArchiveDirectory(t)
  writeBenchmarkArchive(directory, provenance)

  assert.throws(
    () => validateBenchmarkArchive(directory, { ...provenance, commit: 'b'.repeat(40) }),
    /source provenance/,
  )

  fs.appendFileSync(path.join(directory, 'benchmark-report.json'), ' ')
  assert.throws(() => validateBenchmarkArchive(directory, provenance), /report digest or size/)
  fs.truncateSync(
    path.join(directory, 'benchmark-report.json'),
    fs.statSync(path.join(directory, 'benchmark-report.json')).size - 1,
  )

  fs.writeFileSync(path.join(directory, 'extra.json'), '{}\n')
  assert.throws(() => validateBenchmarkArchive(directory, provenance), /archive inventory/)
})

test('archive rejects symlink substitution and uncontrolled hardware reports', t => {
  const directory = createArchiveDirectory(t)
  const reportPath = path.join(directory, 'benchmark-report.json')
  const report = completeReport()
  report.environment.platform = 'darwin'
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`)
  assert.throws(() => writeBenchmarkArchive(directory, provenance), /controlled hardware platform/)

  fs.rmSync(reportPath)
  fs.symlinkSync(path.join(repositoryRoot, 'benchmarks', 'statistics.json'), reportPath)
  assert.throws(() => writeBenchmarkArchive(directory, provenance), /regular non-symlink file/)
})

test('schedule, runner, retention, cleanup, and build-gate drift fail closed', () => {
  const benchmarkWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'benchmarks.yml'),
    'utf8',
  )
  const buildWorkflow = fs.readFileSync(path.join(repositoryRoot, '.github', 'workflows', 'build.yml'), 'utf8')

  assert.doesNotMatch(
    benchmarkWorkflow,
    /^    env:\n      BENCHMARK_ARCHIVE_DIR: \$\{\{ runner\.temp \}\}/m,
    'runner context is unavailable in jobs.<job_id>.env',
  )
  assert.equal(
    benchmarkWorkflow.match(/^        env:\n          BENCHMARK_ARCHIVE_DIR: \$\{\{ runner\.temp \}\}\/zigcss-benchmark-archive$/gm)?.length,
    4,
    'each archive step must resolve runner.temp only after runner assignment',
  )

  assert.throws(
    () => validateBenchmarkArchiveWorkflowSource(
      benchmarkWorkflow.replace("cron: '17 4 * * 1'", "cron: '0 0 * * *'"),
      buildWorkflow,
    ),
    /schedule/,
  )
  assert.throws(
    () => validateBenchmarkArchiveWorkflowSource(
      benchmarkWorkflow.replace('[self-hosted, linux, x64, zigcss-benchmark-v1]', 'ubuntu-latest'),
      buildWorkflow,
    ),
    /controlled runner/,
  )
  assert.throws(
    () => validateBenchmarkArchiveWorkflowSource(
      benchmarkWorkflow.replace('retention-days: 90', 'retention-days: 7'),
      buildWorkflow,
    ),
    /artifact retention/,
  )
  assert.throws(
    () => validateBenchmarkArchiveWorkflowSource(
      benchmarkWorkflow.replace('if: always()', 'if: success()'),
      buildWorkflow,
    ),
    /cleanup/,
  )
  assert.throws(
    () => validateBenchmarkArchiveWorkflowSource(
      benchmarkWorkflow,
      buildWorkflow.replace('- name: Validate benchmark archive policy', '- name: Removed archive gate'),
    ),
    /build workflow/,
  )
})
