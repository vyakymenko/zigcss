import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import { expectedCorpus } from './generate-benchmark-corpora.mjs'
import {
  collectBenchmarkHostAttestation,
  notRequestedHostAttestation,
  validateBenchmarkHostAttestation,
  validateBenchmarkHostContract,
} from './attest-benchmark-host.mjs'
import { collectBenchmarkCliSeries } from './validate-benchmark-modes.mjs'
import { resolveBenchmarkExecutables } from './validate-benchmark-output.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const sampleCount = 20
const maximumU64 = (1n << 64n) - 1n
const tools = ['zigcss', 'esbuild', 'lightningcss']
const corpora = ['small-flat', 'medium-flat', 'large-flat']
const memoryFields = {
  totalAllocatedBytes: 'bytes',
  totalFreedBytes: 'bytes',
  peakLiveBytes: 'bytes',
  retainedResultBytes: 'bytes',
  allocationCount: 'count',
  deallocationCount: 'count',
  resizeCount: 'count',
}
const contract = {
  schemaVersion: 2,
  sampleCount,
  rawSamples: 'required',
  sampleEncoding: 'unsigned-decimal-string',
  statistics: {
    median: 'sorted-middle-average',
    p95: 'nearest-rank',
    variance: 'population',
  },
  environment: [
    'platform',
    'release',
    'architecture',
    'cpuModel',
    'logicalCpuCount',
    'totalMemoryBytes',
    'nodeVersion',
    'zigVersion',
    'optimizationMode',
    'hostAttestation',
    'clock',
    'runnerExecutableSha256',
    'tools',
  ],
  memoryFields,
}
const packageScripts = {
  'check:benchmark-statistics': 'node scripts/report-benchmark-statistics.mjs --check',
  'test:benchmark-statistics': 'node --test scripts/report-benchmark-statistics.test.mjs',
}
const maximumBenchmarkExecutableBytes = 512 * 1024 * 1024

function fail(message) {
  throw new Error(`benchmark statistics: ${message}`)
}

function requireRegularFile(file, label) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
}

function readJson(file, label) {
  requireRegularFile(file, label)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} fields drifted: expected ${wanted.join(', ')}, received ${actual.join(', ')}`)
  }
}

function parseSample(value, label) {
  if (typeof value !== 'string' || !/^(?:0|[1-9][0-9]*)$/.test(value)) {
    fail(`${label} must use unsigned decimal string encoding`)
  }
  const parsed = BigInt(value)
  if (parsed > maximumU64) fail(`${label} exceeds the unsigned 64-bit range`)
  return parsed
}

function renderFraction(numerator, denominator) {
  if (denominator <= 0n || numerator < 0n) fail('invalid internal statistic fraction')
  const whole = numerator / denominator
  let remainder = numerator % denominator
  if (remainder === 0n) return whole.toString()
  let fraction = ''
  for (let digits = 0; remainder !== 0n && digits < 32; digits += 1) {
    remainder *= 10n
    fraction += (remainder / denominator).toString()
    remainder %= denominator
  }
  if (remainder !== 0n) fail('statistic fraction is not finitely representable')
  return `${whole}.${fraction.replace(/0+$/, '')}`
}

export function summarizeSamples(rawSamples) {
  if (!Array.isArray(rawSamples) || rawSamples.length !== sampleCount) {
    fail(`every series must retain exactly ${sampleCount} raw samples`)
  }
  const values = rawSamples.map((value, index) => parseSample(value, `sample ${index}`))
  values.sort((left, right) => (left < right ? -1 : left > right ? 1 : 0))

  const count = BigInt(values.length)
  const median = renderFraction(values[9] + values[10], 2n)
  const p95 = values[Math.ceil(values.length * 0.95) - 1].toString()
  let sum = 0n
  let sumSquares = 0n
  for (const value of values) {
    sum += value
    sumSquares += value * value
  }
  const variance = renderFraction(count * sumSquares - sum * sum, count * count)
  return { count: values.length, median, p95, variance }
}

export function validateBenchmarkStatisticsContract(root = repositoryRoot) {
  validateBenchmarkHostContract(root)
  const manifestPath = path.join(root, 'benchmarks', 'statistics.json')
  const actual = readJson(manifestPath, 'benchmarks/statistics.json')
  if (fs.readFileSync(manifestPath, 'utf8') !== `${JSON.stringify(contract, null, 2)}\n`) {
    fail('statistics manifest does not match the closed reporting contract')
  }

  const modes = readJson(path.join(root, 'benchmarks', 'modes.json'), 'benchmarks/modes.json')
  if (
    !Array.isArray(modes.modes) ||
    modes.modes.length !== 5 ||
    modes.modes.some(mode => mode.measuredIterations !== sampleCount)
  ) {
    fail(`every benchmark mode must declare exactly ${sampleCount} measured iterations`)
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  return actual
}

function expectedSeries() {
  const expected = []
  for (const mode of ['cold-cli', 'warm-cli']) {
    for (const corpus of corpora) {
      for (const tool of tools) {
        expected.push({ mode, metric: 'latency-nanoseconds', tool, corpus, unit: 'nanoseconds' })
      }
    }
  }
  for (const corpus of corpora) {
    expected.push({
      mode: 'in-process-api',
      metric: 'latency-nanoseconds',
      tool: 'zigcss',
      corpus,
      unit: 'nanoseconds',
    })
  }
  for (const corpus of corpora) {
    for (const [field, unit] of Object.entries(memoryFields)) {
      expected.push({
        mode: 'memory',
        metric: 'allocator-requested-bytes',
        tool: 'zigcss',
        corpus,
        field,
        unit,
      })
    }
  }
  expected.push({
    mode: 'throughput',
    metric: 'input-bytes-per-second',
    tool: 'zigcss',
    corpus: 'all-v1',
    unit: 'input-bytes-per-second',
  })
  return expected
}

function seriesIdentity(series) {
  return [series.mode, series.metric, series.tool, series.corpus, series.field ?? '', series.unit].join('/')
}

function validateEnvironment(environment) {
  exactKeys(environment, contract.environment, 'report environment')
  for (const field of ['platform', 'release', 'architecture', 'cpuModel', 'nodeVersion', 'zigVersion']) {
    if (typeof environment[field] !== 'string' || environment[field].length === 0) {
      fail(`report environment ${field} must be a nonempty string`)
    }
  }
  if (!Number.isSafeInteger(environment.logicalCpuCount) || environment.logicalCpuCount < 1) {
    fail('report environment logicalCpuCount must be positive')
  }
  if (parseSample(environment.totalMemoryBytes, 'report environment totalMemoryBytes') === 0n) {
    fail('report environment totalMemoryBytes must be positive')
  }
  if (environment.optimizationMode !== 'ReleaseFast') {
    fail('report environment must identify ReleaseFast benchmark executables')
  }
  validateBenchmarkHostAttestation(environment.hostAttestation)
  if (environment.clock !== 'monotonic-nanoseconds') fail('report environment clock drifted')
  if (!/^[0-9a-f]{64}$/.test(environment.runnerExecutableSha256)) {
    fail('report environment runner executable digest is invalid')
  }
  if (!Array.isArray(environment.tools) || environment.tools.length !== tools.length) {
    fail('report environment must identify exactly three tools')
  }
  for (let index = 0; index < tools.length; index += 1) {
    const tool = environment.tools[index]
    exactKeys(tool, ['id', 'version', 'executableSha256'], `report environment tool ${index}`)
    if (tool.id !== tools[index] || typeof tool.version !== 'string' || tool.version.length === 0) {
      fail(`report environment tool ${index} identity drifted`)
    }
    if (typeof tool.executableSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(tool.executableSha256)) {
      fail(`report environment tool ${tool.id} has an invalid executable digest`)
    }
  }
}

function validateSeries(series, label) {
  const hasField = Object.hasOwn(series, 'field')
  exactKeys(
    series,
    hasField
      ? ['mode', 'metric', 'tool', 'corpus', 'field', 'unit', 'samples', 'statistics']
      : ['mode', 'metric', 'tool', 'corpus', 'unit', 'samples', 'statistics'],
    label,
  )
  for (const field of ['mode', 'metric', 'tool', 'corpus', 'unit']) {
    if (typeof series[field] !== 'string' || series[field].length === 0) fail(`${label} ${field} is invalid`)
  }
  if (hasField && (typeof series.field !== 'string' || series.field.length === 0)) {
    fail(`${label} field is invalid`)
  }
  const statistics = summarizeSamples(series.samples)
  if (series.mode !== 'memory' && series.samples.some(value => parseSample(value, label) === 0n)) {
    fail(`${label} timed samples must be positive`)
  }
  exactKeys(series.statistics, ['count', 'median', 'p95', 'variance'], `${label} statistics`)
  if (JSON.stringify(series.statistics) !== JSON.stringify(statistics)) {
    fail(`${label} statistics drifted from retained raw samples`)
  }
}

export function validateBenchmarkReport(report, options = {}) {
  exactKeys(report, ['schemaVersion', 'generatedAt', 'environment', 'corpus', 'series'], 'report')
  if (report.schemaVersion !== contract.schemaVersion) fail('report schema version drifted')
  if (
    typeof report.generatedAt !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(report.generatedAt) ||
    Number.isNaN(Date.parse(report.generatedAt))
  ) {
    fail('report generatedAt must be an RFC 3339 UTC instant')
  }
  validateEnvironment(report.environment)
  exactKeys(report.corpus, ['version', 'manifestSha256'], 'report corpus')
  if (report.corpus.version !== 'v1' || !/^[0-9a-f]{64}$/.test(report.corpus.manifestSha256)) {
    fail('report corpus identity drifted')
  }
  if (!Array.isArray(report.series) || report.series.length === 0) fail('report series must be nonempty')

  const seen = new Set()
  for (let index = 0; index < report.series.length; index += 1) {
    const series = report.series[index]
    validateSeries(series, `report series ${index}`)
    const identity = seriesIdentity(series)
    if (seen.has(identity)) fail(`duplicate report series ${identity}`)
    seen.add(identity)
  }

  if (options.requireCompleteSeries !== false) {
    const expected = expectedSeries()
    if (report.series.length !== expected.length) fail(`report must contain exactly ${expected.length} series`)
    for (let index = 0; index < expected.length; index += 1) {
      if (seriesIdentity(report.series[index]) !== seriesIdentity(expected[index])) {
        fail(`report series ${index} does not match the closed mode/tool/corpus order`)
      }
    }
  }
  return true
}

function confinedExecutable(root, file, label) {
  if (!path.isAbsolute(file) || file.includes('\0')) fail(`${label} path must be absolute`)
  const realRoot = fs.realpathSync(root)
  const realFile = fs.realpathSync(file)
  const relative = path.relative(realRoot, realFile)
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) {
    fail(`${label} must remain inside the repository`)
  }
  let descriptor
  try {
    descriptor = fs.openSync(
      realFile,
      fs.constants.O_RDONLY |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
    )
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const pathStat = fs.lstatSync(realFile, { bigint: true })
    if (
      !opened.isFile() || !pathStat.isFile() || pathStat.isSymbolicLink() ||
      opened.dev !== pathStat.dev || opened.ino !== pathStat.ino ||
      opened.size !== pathStat.size || opened.mtimeNs !== pathStat.mtimeNs ||
      opened.ctimeNs !== pathStat.ctimeNs || opened.size <= 0n ||
      opened.size > BigInt(maximumBenchmarkExecutableBytes)
    ) fail(`${label} must be a bounded stable regular file`)
    if (process.platform !== 'win32' && (opened.mode & 0o111n) === 0n) {
      fail(`${label} must be executable`)
    }
    return realFile
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

function rawRunnerEnvironment() {
  const environment = { NO_COLOR: '1', FORCE_COLOR: '0', LANG: 'C', LC_ALL: 'C' }
  if (process.platform === 'win32') {
    for (const name of ['ComSpec', 'SystemRoot', 'SYSTEMROOT']) {
      if (process.env[name] !== undefined) environment[name] = process.env[name]
    }
  }
  return environment
}

export function benchmarkRunnerPath(root = repositoryRoot, runnerArgument) {
  const defaultName = process.platform === 'win32' ? 'zigcss-bench.exe' : 'zigcss-bench'
  const expected = path.join(root, 'zig-out', 'bin', defaultName)
  if (runnerArgument === undefined || runnerArgument === expected) return expected
  fail('in-process benchmark runner must be the repository ReleaseFast binary')
}

function runRawBenchmarkRunner(root, runnerArgument) {
  const runner = confinedExecutable(
    root,
    benchmarkRunnerPath(root, runnerArgument),
    'in-process benchmark runner',
  )
  const result = spawnSync(runner, ['--raw-report'], {
    cwd: root,
    encoding: 'utf8',
    env: rawRunnerEnvironment(),
    maxBuffer: 4 * 1024 * 1024,
    timeout: 120_000,
  })
  if (result.error) fail(`in-process benchmark runner failed: ${result.error.message}`)
  if (result.signal !== null) fail(`in-process benchmark runner terminated by ${result.signal}`)
  if (result.status !== 0) fail(`in-process benchmark runner exited ${result.status}: ${JSON.stringify(result.stderr)}`)
  if (result.stderr !== '') fail(`in-process benchmark runner emitted stderr: ${JSON.stringify(result.stderr)}`)
  let fragment
  try {
    fragment = JSON.parse(result.stdout)
  } catch (error) {
    fail(`in-process benchmark runner emitted invalid JSON: ${error.message}`)
  }
  return { runner, fragment }
}

function normalizePlatform(platform) {
  if (platform === 'macos') return 'darwin'
  if (platform === 'windows') return 'win32'
  return platform
}

function normalizeArchitecture(architecture) {
  if (architecture === 'x86_64') return 'x64'
  if (architecture === 'aarch64') return 'arm64'
  return architecture
}

function validateRawFragment(fragment) {
  exactKeys(fragment, ['schemaVersion', 'zigVersion', 'optimizationMode', 'platform', 'architecture', 'series'], 'raw runner report')
  if (fragment.schemaVersion !== 1) fail('raw runner schema version drifted')
  if (fragment.zigVersion !== '0.15.2') fail('raw runner Zig version drifted')
  if (fragment.optimizationMode !== 'ReleaseFast') fail('raw runner must be built in ReleaseFast mode')
  if (normalizePlatform(fragment.platform) !== process.platform) fail('raw runner platform does not match Node')
  if (normalizeArchitecture(fragment.architecture) !== process.arch) fail('raw runner architecture does not match Node')
  if (!Array.isArray(fragment.series) || fragment.series.length !== 25) {
    fail('raw runner must report exactly 25 in-process and memory series')
  }
  for (let index = 0; index < fragment.series.length; index += 1) {
    const series = fragment.series[index]
    const hasField = Object.hasOwn(series, 'field')
    exactKeys(
      series,
      hasField
        ? ['mode', 'metric', 'tool', 'corpus', 'field', 'unit', 'samples']
        : ['mode', 'metric', 'tool', 'corpus', 'unit', 'samples'],
      `raw runner series ${index}`,
    )
    if (!Array.isArray(series.samples) || series.samples.length !== sampleCount) {
      fail(`raw runner series ${index} must contain ${sampleCount} samples`)
    }
  }
  const expected = expectedSeries().slice(18)
  for (let index = 0; index < expected.length; index += 1) {
    if (seriesIdentity(fragment.series[index]) !== seriesIdentity(expected[index])) {
      fail(`raw runner series ${index} identity drifted`)
    }
  }
}

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function reportSeries(series) {
  const samples = series.samples.map(value => (typeof value === 'bigint' ? value.toString() : value))
  const reported = {
    mode: series.mode,
    metric: series.metric,
    tool: series.tool,
    corpus: series.corpus,
    ...(series.field === undefined ? {} : { field: series.field }),
    unit: series.unit,
    samples,
    statistics: summarizeSamples(samples),
  }
  return reported
}

export function createBenchmarkReport(root = repositoryRoot, options = {}) {
  validateBenchmarkStatisticsContract(root)
  const hostAttestation = options.requireControlledHost === true
    ? collectBenchmarkHostAttestation()
    : notRequestedHostAttestation()
  const compiler = options.compiler ?? path.join(
    root,
    'zig-out',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  )
  const cliSeries = collectBenchmarkCliSeries(root, compiler, sampleCount)
  const { runner, fragment } = runRawBenchmarkRunner(root, options.runner)
  validateRawFragment(fragment)

  const executables = resolveBenchmarkExecutables(root, compiler)
  const cpu = os.cpus()[0]
  if (cpu === undefined || typeof cpu.model !== 'string' || cpu.model.trim().length === 0) {
    fail('host CPU model is unavailable')
  }
  const corpusManifest = path.join(root, 'benchmarks', 'corpora', 'v1', 'manifest.json')
  const versions = new Map([
    ['zigcss', fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim()],
    ['esbuild', '0.28.1'],
    ['lightningcss', '1.30.1'],
  ])
  const report = {
    schemaVersion: contract.schemaVersion,
    generatedAt: new Date().toISOString(),
    environment: {
      platform: process.platform,
      release: os.release(),
      architecture: process.arch,
      cpuModel: cpu.model.trim(),
      logicalCpuCount: os.cpus().length,
      totalMemoryBytes: String(os.totalmem()),
      nodeVersion: process.version,
      zigVersion: fragment.zigVersion,
      optimizationMode: fragment.optimizationMode,
      hostAttestation,
      clock: 'monotonic-nanoseconds',
      runnerExecutableSha256: digest(runner),
      tools: tools.map(id => ({
        id,
        version: versions.get(id),
        executableSha256: digest(executables.get(id)),
      })),
    },
    corpus: {
      version: expectedCorpus().manifest.corpusVersion,
      manifestSha256: digest(corpusManifest),
    },
    series: [...cliSeries, ...fragment.series].map(reportSeries),
  }
  validateBenchmarkReport(report)
  return report
}

export function validateBenchmarkStatisticsWorkflow(root = repositoryRoot) {
  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const modes = workflow.indexOf('- name: Validate benchmark modes')
  const host = workflow.indexOf('- name: Validate benchmark host policy', modes)
  const hostCommand = workflow.indexOf(
    'npm run test:benchmark-host && npm run check:benchmark-host',
    host,
  )
  const smoke = workflow.indexOf('- name: Run validated benchmark smoke')
  const build = workflow.indexOf('- name: Build optimized benchmark executables')
  const buildCompiler = workflow.indexOf('zig build -Doptimize=ReleaseFast', build)
  const buildRunner = workflow.indexOf(
    'zig build install-benchmark-runner -Doptimize=ReleaseFast',
    build,
  )
  const statistics = workflow.indexOf('- name: Validate benchmark statistics')
  const command = workflow.indexOf(
    'npm run test:benchmark-statistics && npm run check:benchmark-statistics',
    statistics,
  )
  if (
    modes === -1 ||
    host <= modes ||
    hostCommand <= host ||
    smoke <= hostCommand ||
    build <= smoke ||
    buildCompiler <= build ||
    buildRunner <= buildCompiler ||
    statistics <= buildRunner ||
    command <= statistics
  ) {
    fail('workflow must build ReleaseFast executables and report statistics after mode validation')
  }
  return true
}

function parseArguments(argumentsList) {
  if (argumentsList.length === 1 && argumentsList[0] === '--check') return { check: true }
  if (argumentsList.length < 2 || argumentsList[0] !== '--output') {
    fail('usage: node scripts/report-benchmark-statistics.mjs --check|--output absolute-path [--compiler absolute-path] [--runner absolute-path] [--require-controlled-host]')
  }
  const options = { check: false, output: argumentsList[1] }
  if (!path.isAbsolute(options.output)) fail('report output path must be absolute')
  const seen = new Set()
  for (let index = 2; index < argumentsList.length;) {
    const name = argumentsList[index]
    if (seen.has(name)) fail('duplicate report argument')
    seen.add(name)
    if (name === '--require-controlled-host') {
      options.requireControlledHost = true
      index += 1
      continue
    }
    const value = argumentsList[index + 1]
    if (value === undefined || !['--compiler', '--runner'].includes(name)) fail('invalid report argument')
    if (!path.isAbsolute(value)) fail(`${name} path must be absolute`)
    if (name === '--compiler') options.compiler = value
    else options.runner = value
    index += 2
  }
  return options
}

export function benchmarkReportOutputPath(root = repositoryRoot, requested) {
  if (typeof requested !== 'string' || !path.isAbsolute(requested) || requested.includes('\0')) {
    fail('report output path must be absolute')
  }
  const workflowOutput = path.resolve(
    root,
    '..',
    '..',
    '_temp',
    'zigcss-benchmark-archive',
    'benchmark-report.json',
  )
  const localOutput = path.join(
    os.tmpdir(),
    'zigcss-benchmark-archive',
    'benchmark-report.json',
  )
  if (requested === workflowOutput) return workflowOutput
  if (requested === localOutput) return localOutput
  fail('report output must be the dedicated benchmark archive path')
}

function writeNewReport(file, report) {
  const bytes = Buffer.from(`${JSON.stringify(report, null, 2)}\n`)
  let descriptor
  try {
    descriptor = fs.openSync(
      file,
      fs.constants.O_WRONLY |
        fs.constants.O_CREAT |
        fs.constants.O_EXCL |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
      0o600,
    )
    let offset = 0
    while (offset < bytes.length) {
      const written = fs.writeSync(descriptor, bytes, offset, bytes.length - offset, null)
      if (written === 0) fail('report write made no progress')
      offset += written
    }
    fs.fsyncSync(descriptor)
    const stat = fs.fstatSync(descriptor, { bigint: true })
    if (!stat.isFile() || stat.size !== BigInt(bytes.length)) fail('report write was incomplete')
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2))
  validateBenchmarkStatisticsWorkflow(repositoryRoot)
  if (options.check) {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-statistics-'))
    try {
      const file = path.join(temporary, 'report.json')
      const report = createBenchmarkReport(repositoryRoot)
      writeNewReport(file, report)
      validateBenchmarkReport(readJson(file, 'temporary benchmark report'))
      process.stdout.write(
        `Benchmark statistics verified: ${report.series.length} complete series retain ${sampleCount} raw samples with exact median, nearest-rank p95, population variance, and environment metadata; temporary report removed without archival.\n`,
      )
    } finally {
      fs.rmSync(temporary, { recursive: true, force: true })
    }
    return
  }
  const report = createBenchmarkReport(repositoryRoot, options)
  const output = benchmarkReportOutputPath(repositoryRoot, options.output)
  writeNewReport(output, report)
  process.stdout.write(`Benchmark report written to ${output}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
