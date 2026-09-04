import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  renderBenchmarkPublication,
  repositoryRoot,
  validateBenchmarkPublication,
  validateBenchmarkPublicationWorkflow,
  validateBenchmarkPublicationWorkflowSource,
  writeBenchmarkPublication,
} from './publish-benchmark-report.mjs'
import { writeBenchmarkArchive } from './archive-benchmark-report.mjs'
import { summarizeSamples } from './report-benchmark-statistics.mjs'

const provenance = {
  commit: 'a'.repeat(40),
  runId: '1234567890123456789',
  runAttempt: '2',
}
const artifactUrl = `https://github.com/vyakymenko/zigcss/actions/runs/${provenance.runId}/artifacts/987654321`
const memoryFields = [
  ['totalAllocatedBytes', 'bytes'],
  ['totalFreedBytes', 'bytes'],
  ['peakLiveBytes', 'bytes'],
  ['retainedResultBytes', 'bytes'],
  ['allocationCount', 'count'],
  ['deallocationCount', 'count'],
  ['resizeCount', 'count'],
]

function reportedSeries(index, mode, metric, tool, corpus, unit, field) {
  const start = BigInt((index + 1) * 10_000)
  const samples = Array.from({ length: 20 }, (_, sample) => (start + BigInt(sample + 1)).toString())
  return {
    mode,
    metric,
    tool,
    corpus,
    ...(field === undefined ? {} : { field }),
    unit,
    samples,
    statistics: summarizeSamples(samples),
  }
}

function completeReport() {
  const series = []
  for (const mode of ['cold-cli', 'warm-cli']) {
    for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
      for (const tool of ['zigcss', 'esbuild', 'lightningcss']) {
        series.push(reportedSeries(
          series.length,
          mode,
          'latency-nanoseconds',
          tool,
          corpus,
          'nanoseconds',
        ))
      }
    }
  }
  for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
    series.push(reportedSeries(
      series.length,
      'in-process-api',
      'latency-nanoseconds',
      'zigcss',
      corpus,
      'nanoseconds',
    ))
  }
  for (const corpus of ['small-flat', 'medium-flat', 'large-flat']) {
    for (const [field, unit] of memoryFields) {
      series.push(reportedSeries(
        series.length,
        'memory',
        'allocator-requested-bytes',
        'zigcss',
        corpus,
        unit,
        field,
      ))
    }
  }
  series.push(reportedSeries(
    series.length,
    'throughput',
    'input-bytes-per-second',
    'zigcss',
    'all-v1',
    'input-bytes-per-second',
  ))
  return {
    schemaVersion: 2,
    generatedAt: '2026-07-13T00:00:00.000Z',
    environment: {
      platform: 'linux',
      release: '6.8.0-controlled',
      architecture: 'x64',
      cpuModel: 'Controlled Benchmark CPU',
      logicalCpuCount: 8,
      totalMemoryBytes: '17179869184',
      nodeVersion: 'v24.20.0',
      zigVersion: '0.15.2',
      optimizationMode: 'ReleaseFast',
      hostAttestation: {
        schemaVersion: 1,
        status: 'verified-bare-metal',
        detector: {
          executable: '/usr/bin/systemd-detect-virt',
          version: 'systemd 255 (255.4-1)',
          vm: 'none',
          container: 'none',
        },
        cpuHypervisorFlag: false,
        sysHypervisorType: 'none',
        containerMarkers: [],
        dmi: {
          systemVendor: 'Example Systems',
          productName: 'Dedicated Benchmark Host',
          boardVendor: 'Example Boards',
        },
      },
      clock: 'monotonic-nanoseconds',
      runnerExecutableSha256: 'e'.repeat(64),
      tools: [
        { id: 'zigcss', version: '0.6.0-rc.2', executableSha256: 'b'.repeat(64) },
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

function createArchiveDirectory(t, root = repositoryRoot) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-publication-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  fs.writeFileSync(
    path.join(directory, 'benchmark-report.json'),
    `${JSON.stringify(completeReport(), null, 2)}\n`,
    { mode: 0o600 },
  )
  writeBenchmarkArchive(directory, provenance, root)
  return directory
}

test('repository report remains an exact withdrawal until a controlled archive is selected', () => {
  const result = validateBenchmarkPublication(repositoryRoot)
  assert.equal(result.status, 'withdrawn')
  const report = fs.readFileSync(path.join(repositoryRoot, 'BENCHMARK_REPORT.md'), 'utf8')
  assert.match(report, /Performance claims are withdrawn/)
  assert.match(report, /no controlled scheduled archive has been selected/i)
  assert.doesNotMatch(report, /\| cold CLI \|/)
  assert.equal(validateBenchmarkPublicationWorkflow(repositoryRoot), true)
})

test('a complete verified archive renders deterministic provenance-bound Markdown', t => {
  const directory = createArchiveDirectory(t)
  const first = renderBenchmarkPublication(directory, artifactUrl)
  const second = renderBenchmarkPublication(directory, artifactUrl)

  assert.equal(first, second)
  assert.match(first, /^# ZigCSS controlled benchmark report/m)
  assert.match(first, /Experimental benchmark evidence, not a production-readiness claim/)
  assert.match(first, /scheduled run 1234567890123456789/)
  assert.match(first, /zigcss-benchmark-v1-a{40}-1234567890123456789-2/)
  assert.match(first, /benchmarks\/publications\/zigcss-benchmark-v1-a{40}-1234567890123456789-2\/benchmark-report\.json/)
  assert.match(first, /\| cold CLI \| small-flat \| zigcss \| 10010\.5 \| 10019 \| 33\.25 \|/)
  assert.match(first, /\| warm CLI \| large-flat \|/)
  assert.match(first, /Allocator-requested memory is not RSS/)
  assert.match(first, /Raw samples are retained only in the committed verified archive/)
  assert.match(first, /Report SHA-256.*[0-9a-f]{64}/)
  assert.match(first, /\| Host isolation \| verified-bare-metal \|/)
  assert.match(first, /VM=none; container=none/)
  assert.equal(first.match(/\| cold CLI \| small-flat \| zigcss \|/g)?.length, 1)
  assert.doesNotMatch(first, /"samples"/)
})

test('publication rejects report tampering and artifact links outside the bound scheduled run', t => {
  const directory = createArchiveDirectory(t)
  assert.throws(
    () => renderBenchmarkPublication(
      directory,
      'https://github.com/vyakymenko/zigcss/actions/runs/999/artifacts/987654321',
    ),
    /artifact URL.*run/i,
  )
  assert.throws(
    () => renderBenchmarkPublication(
      directory,
      `https://example.com/vyakymenko/zigcss/actions/runs/${provenance.runId}/artifacts/987654321`,
    ),
    /artifact URL/i,
  )

  fs.appendFileSync(path.join(directory, 'benchmark-report.json'), ' ')
  assert.throws(() => renderBenchmarkPublication(directory, artifactUrl), /digest or size/)
})

test('publication escapes bounded runner metadata instead of admitting Markdown or HTML', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-publication-escaping-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const report = completeReport()
  report.environment.cpuModel = '<unsafe>|CPU'
  fs.writeFileSync(
    path.join(directory, 'benchmark-report.json'),
    `${JSON.stringify(report, null, 2)}\n`,
    { mode: 0o600 },
  )
  writeBenchmarkArchive(directory, provenance)
  const rendered = renderBenchmarkPublication(directory, artifactUrl)
  assert.match(rendered, /&lt;unsafe&gt;\\\|CPU/)
  assert.doesNotMatch(rendered, /<unsafe>/)
})

test('publication output is create-only and byte-identical to the renderer', t => {
  const directory = createArchiveDirectory(t)
  const outputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-markdown-'))
  t.after(() => fs.rmSync(outputDirectory, { recursive: true, force: true }))
  const output = path.join(outputDirectory, 'report.md')

  const rendered = writeBenchmarkPublication(directory, artifactUrl, output)
  assert.equal(fs.readFileSync(output, 'utf8'), rendered)
  assert.throws(() => writeBenchmarkPublication(directory, artifactUrl, output), /exist|create/i)
})

test('repository publication state requires a confined archive and exact generated bytes', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-publication-root-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'benchmarks', 'publications'), { recursive: true })
  fs.mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, 'benchmarks', 'archive.json'), path.join(root, 'benchmarks', 'archive.json'))
  fs.copyFileSync(path.join(repositoryRoot, 'package.json'), path.join(root, 'package.json'))

  const artifactName = `zigcss-benchmark-v1-${provenance.commit}-${provenance.runId}-${provenance.runAttempt}`
  const directory = path.join(root, 'benchmarks', 'publications', artifactName)
  fs.mkdirSync(directory)
  fs.writeFileSync(
    path.join(directory, 'benchmark-report.json'),
    `${JSON.stringify(completeReport(), null, 2)}\n`,
    { mode: 0o600 },
  )
  writeBenchmarkArchive(directory, provenance, root)
  fs.writeFileSync(path.join(root, 'benchmarks', 'publication.json'), `${JSON.stringify({
    schemaVersion: 1,
    status: 'published',
    output: 'BENCHMARK_REPORT.md',
    archiveDirectory: `benchmarks/publications/${artifactName}`,
    artifactUrl,
  }, null, 2)}\n`)
  fs.writeFileSync(
    path.join(root, 'BENCHMARK_REPORT.md'),
    renderBenchmarkPublication(directory, artifactUrl, root),
  )

  assert.equal(validateBenchmarkPublication(root).status, 'published')
  fs.appendFileSync(path.join(root, 'BENCHMARK_REPORT.md'), 'invented claim\n')
  assert.throws(() => validateBenchmarkPublication(root), /generated report.*drift/i)
})

test('build and scheduled workflows cannot remove or reorder the publication gate', () => {
  const build = fs.readFileSync(path.join(repositoryRoot, '.github', 'workflows', 'build.yml'), 'utf8')
  const scheduled = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'benchmarks.yml'),
    'utf8',
  )
  assert.equal(validateBenchmarkPublicationWorkflowSource(build, scheduled), true)
  assert.throws(
    () => validateBenchmarkPublicationWorkflowSource(
      build.replace('- name: Validate benchmark publication', '- name: Removed publication gate'),
      scheduled,
    ),
    /build workflow/,
  )
  assert.throws(
    () => validateBenchmarkPublicationWorkflowSource(
      build,
      scheduled.replace(
        'npm run test:benchmark-publication && npm run check:benchmark-publication',
        'node -e "process.exit(0)"',
      ),
    ),
    /scheduled workflow/,
  )
})
