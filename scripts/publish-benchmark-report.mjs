import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateBenchmarkArchive } from './archive-benchmark-report.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const maximumManifestBytes = 128 * 1024
const maximumReportBytes = 4 * 1024 * 1024
const publicationStatuses = ['published', 'withdrawn']
const tools = ['zigcss', 'esbuild', 'lightningcss']
const corpora = ['small-flat', 'medium-flat', 'large-flat']
const memoryFields = [
  'totalAllocatedBytes',
  'totalFreedBytes',
  'peakLiveBytes',
  'retainedResultBytes',
  'allocationCount',
  'deallocationCount',
  'resizeCount',
]
const packageScripts = {
  'check:benchmark-publication': 'node scripts/publish-benchmark-report.mjs --check',
  'test:benchmark-publication': 'node --test scripts/publish-benchmark-report.test.mjs',
}

export const withdrawnReport = `# ZigCSS benchmark status

> **Performance claims are withdrawn.** The historical measurements previously stored in this file are not semantically equivalent comparisons and must not be cited as product evidence.

The old benchmark path timed compiler outputs before proving that each tool accepted equivalent input and produced equivalent CSS semantics. It also compared a local native executable with some tools launched through \`npx\`, which mixed process and package-runner overhead into compiler timing. The legacy ZigCSS optimizer used by those runs is disabled because audit fixtures demonstrate corruption, invalid emission, unsafe reordering, and crash paths.

Historical raw data remains in repository history for auditability, but it is intentionally not presented as a current result.

## Current evidence state

The reproducible corpus, pinned competitor binaries, semantics-first output admission, separated execution modes, complete raw statistics, and controlled scheduled archive contracts are implemented under \`BENCH-001\` through \`BENCH-006\`. No controlled scheduled archive has been selected for \`BENCH-007\`, so ZigCSS publishes no current timing, memory, throughput, ranking, or ratio claim.

## Publication gate

\`scripts/publish-benchmark-report.mjs\` accepts only the exact two-file archive created by the controlled schedule. It revalidates all 43 ordered series and 860 retained raw observations, machine-verified bare-metal host attestation, report and hardware identity, source/run provenance, artifact link, and archive digest before rendering deterministic Markdown. The repository remains on this exact withdrawal notice until a retained scheduled artifact is explicitly reviewed, committed under \`benchmarks/publications/\`, selected by \`benchmarks/publication.json\`, and reproduced byte-for-byte by the publication gate.

Any future report must keep cold and warm CLI comparisons separate, label ZigCSS-only API, allocator-memory, and throughput metrics as non-comparative, link the retained raw archive, and state the controlled-host and corpus limits. A generated report is benchmark evidence for the exact archived run, not a production-readiness claim.
`

function fail(message) {
  throw new Error(`benchmark publication: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (!same(actual, wanted)) fail(`${label} fields drifted`)
}

function requireRegularFile(file, label, maximumBytes) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (maximumBytes !== undefined && stat.size > maximumBytes) {
    fail(`${label} exceeds the ${maximumBytes}-byte limit`)
  }
  return stat
}

function requireRealDirectory(directory, label) {
  if (!path.isAbsolute(directory)) fail(`${label} must be absolute`)
  let stat
  try {
    stat = fs.lstatSync(directory)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a real non-symlink directory`)
  return fs.realpathSync(directory)
}

function readJson(file, label, maximumBytes) {
  requireRegularFile(file, label, maximumBytes)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function markdownCell(value) {
  const text = String(value)
  if (Buffer.byteLength(text, 'utf8') > 512 || /[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(text)) {
    fail('report presentation text is unsafe or exceeds 512 bytes')
  }
  return text
    .replace(/\r\n|\r|\n/g, ' ')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/([\\|`*_[\]])/g, '\\$1')
}

function seriesIdentity(mode, tool, corpus, field = '') {
  return [mode, tool, corpus, field].join('/')
}

function reportSeries(report) {
  return new Map(report.series.map(series => [
    seriesIdentity(series.mode, series.tool, series.corpus, series.field),
    series,
  ]))
}

function requireSeries(series, mode, tool, corpus, field) {
  const value = series.get(seriesIdentity(mode, tool, corpus, field))
  if (value === undefined) fail(`validated report is missing ${seriesIdentity(mode, tool, corpus, field)}`)
  return value
}

function tableStatisticCells(series) {
  return [series.statistics.median, series.statistics.p95, series.statistics.variance]
    .map(markdownCell)
    .join(' | ')
}

function publicationArchive(directory, root = repositoryRoot) {
  const realDirectory = requireRealDirectory(directory, 'archive directory')
  const reportPath = path.join(realDirectory, 'benchmark-report.json')
  const manifestPath = path.join(realDirectory, 'benchmark-archive.json')
  requireRegularFile(reportPath, 'benchmark report', maximumReportBytes)
  const manifest = readJson(manifestPath, 'benchmark archive manifest', maximumManifestBytes)
  const provenance = {
    commit: manifest?.source?.commit,
    runId: manifest?.run?.id,
    runAttempt: manifest?.run?.attempt,
  }
  const verifiedManifest = validateBenchmarkArchive(realDirectory, provenance, root)
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
  return { manifest: verifiedManifest, report }
}

function validateArtifactUrl(value, manifest) {
  if (typeof value !== 'string' || value.length > 512) fail('artifact URL is invalid')
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail('artifact URL is invalid')
  }
  const segments = parsed.pathname.split('/')
  if (
    parsed.protocol !== 'https:' ||
    parsed.hostname !== 'github.com' ||
    parsed.port !== '' ||
    parsed.username !== '' ||
    parsed.password !== '' ||
    parsed.search !== '' ||
    parsed.hash !== '' ||
    !same(segments.slice(0, 5), ['', 'vyakymenko', 'zigcss', 'actions', 'runs']) ||
    segments[5] !== manifest.run.id ||
    segments[6] !== 'artifacts' ||
    !/^[1-9][0-9]{0,31}$/.test(segments[7] ?? '') ||
    segments.length !== 8
  ) {
    fail('artifact URL must identify the retained artifact for the bound scheduled run')
  }
  return parsed.toString()
}

export function renderBenchmarkPublication(directory, artifactUrl, root = repositoryRoot) {
  const archive = publicationArchive(directory, root)
  const url = validateArtifactUrl(artifactUrl, archive.manifest)
  const report = archive.report
  const manifest = archive.manifest
  const host = report.environment.hostAttestation
  const series = reportSeries(report)
  const committedArchive = `benchmarks/publications/${manifest.run.artifactName}`
  const runUrl = `https://github.com/vyakymenko/zigcss/actions/runs/${manifest.run.id}`
  const sourceUrl = `https://github.com/vyakymenko/zigcss/commit/${manifest.source.commit}`
  const lines = [
    '# ZigCSS controlled benchmark report',
    '',
    '> **Experimental benchmark evidence, not a production-readiness claim.** Every displayed statistic is generated from one retained, semantics-validated, controlled scheduled archive. No hand-copied timing or cross-mode ratio is accepted.',
    '',
    '## Archive provenance',
    '',
    `- Source: [commit \`${manifest.source.commit}\`](${sourceUrl}) on \`${manifest.source.ref}\`.`,
    `- Scheduled run: [scheduled run ${manifest.run.id}](${runUrl}), attempt ${manifest.run.attempt}.`,
    `- Scheduled artifact provenance: [\`${manifest.run.artifactName}\`](${url}).`,
    `- Committed raw archive: [\`benchmark-report.json\`](${committedArchive}/benchmark-report.json) and [\`benchmark-archive.json\`](${committedArchive}/benchmark-archive.json).`,
    `- Generated at: \`${report.generatedAt}\`.`,
    `- Report SHA-256: \`${manifest.report.sha256}\` (${manifest.report.sizeBytes} bytes).`,
    `- Controlled hardware fingerprint: \`${manifest.controlledHardware.fingerprint}\`.`,
    `- Corpus: \`${report.corpus.version}\`, manifest SHA-256 \`${report.corpus.manifestSha256}\`.`,
    '- Sampling: 20 retained raw observations per each of 43 ordered series; median uses the sorted middle, p95 uses nearest rank, and variance is population variance.',
    '',
    'Raw samples are retained only in the committed verified archive linked above. This Markdown contains generated summaries so reviewers can recompute every displayed value from the digest-bound JSON report even after the scheduled artifact retention window closes.',
    '',
    '## Controlled environment',
    '',
    '| Field | Value |',
    '|---|---|',
    `| Platform | ${markdownCell(report.environment.platform)} ${markdownCell(report.environment.release)} |`,
    `| Architecture | ${markdownCell(report.environment.architecture)} |`,
    `| CPU | ${markdownCell(report.environment.cpuModel)} |`,
    `| Logical CPUs | ${markdownCell(report.environment.logicalCpuCount)} |`,
    `| Total memory (bytes) | ${markdownCell(report.environment.totalMemoryBytes)} |`,
    `| Host isolation | ${markdownCell(host.status)} |`,
    `| Virtualization detector | ${markdownCell(host.detector.version)}; VM=${markdownCell(host.detector.vm)}; container=${markdownCell(host.detector.container)} |`,
    `| System | ${markdownCell(host.dmi.systemVendor)} ${markdownCell(host.dmi.productName)} |`,
    `| Board vendor | ${markdownCell(host.dmi.boardVendor)} |`,
    `| Node | ${markdownCell(report.environment.nodeVersion)} |`,
    `| Zig | ${markdownCell(report.environment.zigVersion)} |`,
    `| Optimization | ${markdownCell(report.environment.optimizationMode)} |`,
    `| Clock | ${markdownCell(report.environment.clock)} |`,
    `| Private runner SHA-256 | \`${report.environment.runnerExecutableSha256}\` |`,
    '',
    '| Tool | Version | Executable SHA-256 |',
    '|---|---|---|',
    ...report.environment.tools.map(tool => (
      `| ${markdownCell(tool.id)} | ${markdownCell(tool.version)} | \`${tool.executableSha256}\` |`
    )),
    '',
    '## Comparable CLI latency',
    '',
    'Cold CLI and warm CLI are separate new-process boundaries. Cold includes startup with no mode-local warmup. Warm uses the identical command after one separately validated mode-local invocation; it does not claim a purged operating-system cache.',
    '',
    '| Mode | Corpus | Tool | Median (ns) | p95 (ns) | Population variance (ns²) |',
    '|---|---|---|---:|---:|---:|',
  ]
  for (const mode of ['cold-cli', 'warm-cli']) {
    for (const corpus of corpora) {
      for (const tool of tools) {
        const value = requireSeries(series, mode, tool, corpus)
        lines.push(`| ${mode === 'cold-cli' ? 'cold CLI' : 'warm CLI'} | ${corpus} | ${tool} | ${tableStatisticCells(value)} |`)
      }
    }
  }

  lines.push(
    '',
    '## ZigCSS-only measurements',
    '',
    'These modes are not cross-tool comparisons. Direct API latency excludes process startup; throughput retains all two-pass results through the measured region; allocator fields describe requested ownership only.',
    '',
    '### Direct API latency',
    '',
    '| Corpus | Median (ns) | p95 (ns) | Population variance (ns²) |',
    '|---|---:|---:|---:|',
  )
  for (const corpus of corpora) {
    const value = requireSeries(series, 'in-process-api', 'zigcss', corpus)
    lines.push(`| ${corpus} | ${tableStatisticCells(value)} |`)
  }

  lines.push(
    '',
    '### Allocator-requested memory',
    '',
    '**Allocator-requested memory is not RSS, heap capacity, or a platform-wide peak-memory claim.** Counts and byte fields are reported exactly as requested through the ZigCSS compile allocator.',
    '',
    '| Corpus | Field | Unit | Median | p95 | Population variance |',
    '|---|---|---|---:|---:|---:|',
  )
  for (const corpus of corpora) {
    for (const field of memoryFields) {
      const value = requireSeries(series, 'memory', 'zigcss', corpus, field)
      lines.push(`| ${corpus} | ${field} | ${value.unit} | ${tableStatisticCells(value)} |`)
    }
  }
  const throughput = requireSeries(series, 'throughput', 'zigcss', 'all-v1')
  lines.push(
    '',
    '### Two-pass corpus throughput',
    '',
    '| Corpus | Unit | Median | p95 | Population variance |',
    '|---|---|---:|---:|---:|',
    `| all-v1 | ${throughput.unit} | ${tableStatisticCells(throughput)} |`,
    '',
    '## Interpretation limits',
    '',
    '- This is one scheduled run on one controlled Linux x64 host fingerprint, not a cross-machine or long-term trend.',
    '- The versioned corpus contains three deterministic flat CSS workloads; it does not represent every stylesheet shape, platform, or cache state.',
    '- Every timed output was parsed with recovery disabled and compared to the exact corpus semantics before admission. That supports workload equivalence; it does not prove browser behavior for unsupported CSS outside the corpus.',
    '- CLI rows compare only identical new-process file-input/file-output boundaries. ZigCSS-only API, memory, and throughput rows must not be compared to unmeasured competitor APIs.',
    '- No ranking, speedup ratio, or production recommendation is generated from a single archive.',
    '',
  )
  return `${lines.join('\n')}\n`
}

function validatePublicationContract(root) {
  const file = path.join(root, 'benchmarks', 'publication.json')
  const publication = readJson(file, 'benchmarks/publication.json', 16 * 1024)
  exactKeys(
    publication,
    ['schemaVersion', 'status', 'output', 'archiveDirectory', 'artifactUrl'],
    'publication contract',
  )
  if (publication.schemaVersion !== 1) fail('publication schema version drifted')
  if (!publicationStatuses.includes(publication.status)) fail('publication status is invalid')
  if (publication.output !== 'BENCHMARK_REPORT.md') fail('publication output path drifted')
  if (fs.readFileSync(file, 'utf8') !== `${JSON.stringify(publication, null, 2)}\n`) {
    fail('publication contract must use canonical JSON bytes')
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json', 256 * 1024)
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  return publication
}

function confinedPublicationDirectory(root, relative) {
  if (
    typeof relative !== 'string' ||
    !/^benchmarks\/publications\/zigcss-benchmark-v1-[0-9a-f]{40}-[1-9][0-9]{0,31}-[1-9][0-9]{0,31}$/.test(relative)
  ) {
    fail('published archive directory does not use the closed inventory path')
  }
  const rootReal = fs.realpathSync(root)
  const directory = path.resolve(root, ...relative.split('/'))
  const directoryReal = requireRealDirectory(directory, 'published archive directory')
  const confined = path.relative(rootReal, directoryReal)
  if (confined.startsWith('..') || path.isAbsolute(confined) || confined === '') {
    fail('published archive directory escapes the repository')
  }
  return directoryReal
}

export function validateBenchmarkPublication(root = repositoryRoot) {
  const publication = validatePublicationContract(root)
  const output = path.join(root, publication.output)
  requireRegularFile(output, 'benchmark publication', 1024 * 1024)
  if (publication.status === 'withdrawn') {
    if (publication.archiveDirectory !== null || publication.artifactUrl !== null) {
      fail('withdrawn publication must not select an archive or artifact URL')
    }
    if (fs.readFileSync(output, 'utf8') !== withdrawnReport) {
      fail('withdrawn benchmark report drifted from the exact no-claims notice')
    }
    return publication
  }

  if (typeof publication.artifactUrl !== 'string') fail('published state requires an artifact URL')
  const directory = confinedPublicationDirectory(root, publication.archiveDirectory)
  const rendered = renderBenchmarkPublication(directory, publication.artifactUrl, root)
  const manifest = readJson(
    path.join(directory, 'benchmark-archive.json'),
    'benchmark archive manifest',
    maximumManifestBytes,
  )
  if (path.basename(directory) !== manifest.run.artifactName) {
    fail('published archive directory does not match the verified artifact name')
  }
  if (fs.readFileSync(output, 'utf8') !== rendered) {
    fail('generated report bytes drifted from the selected verified archive')
  }
  return publication
}

export function validateBenchmarkPublicationWorkflowSource(build, scheduled) {
  const archive = build.indexOf('- name: Validate benchmark archive policy')
  const publication = build.indexOf('- name: Validate benchmark publication', archive)
  const command = build.indexOf(
    'npm run test:benchmark-publication && npm run check:benchmark-publication',
    publication,
  )
  if (archive === -1 || publication <= archive || command <= publication) {
    fail('build workflow must validate benchmark publication after archive policy')
  }
  const scheduledArchive = scheduled.indexOf('npm run test:benchmark-archive && npm run check:benchmark-archive')
  const scheduledPublication = scheduled.indexOf(
    'npm run test:benchmark-publication && npm run check:benchmark-publication',
    scheduledArchive,
  )
  const prepare = scheduled.indexOf('- name: Prepare benchmark archive directory')
  if (scheduledArchive === -1 || scheduledPublication <= scheduledArchive || prepare <= scheduledPublication) {
    fail('scheduled workflow must validate publication policy after archive policy and before collection')
  }
  return true
}

export function validateBenchmarkPublicationWorkflow(root = repositoryRoot) {
  return validateBenchmarkPublicationWorkflowSource(
    fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8'),
    fs.readFileSync(path.join(root, '.github', 'workflows', 'benchmarks.yml'), 'utf8'),
  )
}

export function writeBenchmarkPublication(directory, artifactUrl, output, root = repositoryRoot) {
  if (!path.isAbsolute(output)) fail('publication output path must be absolute')
  requireRealDirectory(path.dirname(output), 'publication output directory')
  const rendered = renderBenchmarkPublication(directory, artifactUrl, root)
  try {
    fs.writeFileSync(output, rendered, { encoding: 'utf8', flag: 'wx', mode: 0o644 })
  } catch (error) {
    fail(`publication output must be create-only: ${error.message}`)
  }
  return rendered
}

function parseCommand(argumentsList) {
  if (argumentsList.length === 1 && argumentsList[0] === '--check') return { mode: 'check' }
  if (argumentsList.length !== 7 || argumentsList[0] !== '--write') {
    fail('usage: node scripts/publish-benchmark-report.mjs --check|--write --directory absolute-path --artifact-url url --output absolute-path')
  }
  const result = { mode: 'write' }
  const seen = new Set()
  for (let index = 1; index < argumentsList.length; index += 2) {
    const name = argumentsList[index]
    const value = argumentsList[index + 1]
    if (!['--directory', '--artifact-url', '--output'].includes(name) || seen.has(name)) {
      fail('publication command arguments are invalid or duplicated')
    }
    seen.add(name)
    result[name.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value
  }
  if (!same([...seen].sort(), ['--artifact-url', '--directory', '--output'])) {
    fail('publication command is missing a required argument')
  }
  if (!path.isAbsolute(result.directory) || !path.isAbsolute(result.output)) {
    fail('publication directory and output arguments must be absolute')
  }
  return result
}

function main() {
  const command = parseCommand(process.argv.slice(2))
  validateBenchmarkPublicationWorkflow(repositoryRoot)
  if (command.mode === 'check') {
    const publication = validateBenchmarkPublication(repositoryRoot)
    process.stdout.write(
      publication.status === 'withdrawn'
        ? 'Benchmark publication verified: no controlled archive is selected, so the exact withdrawal notice contains no timing claims.\n'
        : `Benchmark publication verified: ${publication.archiveDirectory} deterministically generates BENCHMARK_REPORT.md.\n`,
    )
    return
  }
  writeBenchmarkPublication(command.directory, command.artifactUrl, command.output)
  process.stdout.write(`Benchmark publication written to ${command.output}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
