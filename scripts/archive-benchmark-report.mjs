import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateBenchmarkReport } from './report-benchmark-statistics.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const contract = {
  schemaVersion: 1,
  benchmarkId: 'zigcss-benchmark-v1',
  repository: 'vyakymenko/zigcss',
  branch: 'main',
  schedule: '17 4 * * 1',
  runner: {
    type: 'self-hosted',
    labels: ['self-hosted', 'linux', 'x64', 'zigcss-benchmark-v1'],
    platform: 'linux',
    architecture: 'x64',
    fingerprintFields: [
      'platform',
      'architecture',
      'cpuModel',
      'logicalCpuCount',
      'totalMemoryBytes',
    ],
  },
  concurrencyGroup: 'zigcss-benchmark-v1',
  artifact: {
    report: 'benchmark-report.json',
    manifest: 'benchmark-archive.json',
    retentionDays: 90,
  },
}

const packageScripts = {
  'check:benchmark-archive': 'node scripts/archive-benchmark-report.mjs --check-policy',
  'test:benchmark-archive': 'node --test scripts/archive-benchmark-report.test.mjs',
}

function fail(message) {
  throw new Error(`benchmark archive: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function requireRegularFile(file, label) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  return stat
}

function requireArchiveDirectory(directory) {
  if (!path.isAbsolute(directory)) fail('archive directory must be absolute')
  let stat
  try {
    stat = fs.lstatSync(directory)
  } catch (error) {
    fail(`archive directory is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('archive directory must be a real non-symlink directory')
  }
  return directory
}

function readJson(file, label) {
  requireRegularFile(file, label)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function validateProvenance(provenance) {
  if (provenance === null || typeof provenance !== 'object' || Array.isArray(provenance)) {
    fail('run provenance is invalid')
  }
  const keys = Object.keys(provenance).sort()
  if (!same(keys, ['commit', 'runAttempt', 'runId'])) fail('run provenance fields drifted')
  if (typeof provenance.commit !== 'string' || !/^[0-9a-f]{40}$/.test(provenance.commit)) {
    fail('source commit must be a full lowercase Git object ID')
  }
  for (const field of ['runId', 'runAttempt']) {
    if (typeof provenance[field] !== 'string' || !/^[1-9][0-9]{0,31}$/.test(provenance[field])) {
      fail(`${field} must be a bounded positive decimal string`)
    }
  }
  return provenance
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function hardwareFingerprint(environment) {
  const values = contract.runner.fingerprintFields.map(field => String(environment[field]))
  return sha256(Buffer.from(values.join('\0'), 'utf8'))
}

function validateControlledReport(report) {
  validateBenchmarkReport(report)
  if (report.environment.platform !== contract.runner.platform) {
    fail(`controlled hardware platform must be ${contract.runner.platform}`)
  }
  if (report.environment.architecture !== contract.runner.architecture) {
    fail(`controlled hardware architecture must be ${contract.runner.architecture}`)
  }
}

function readReport(directory) {
  const reportPath = path.join(directory, contract.artifact.report)
  const stat = requireRegularFile(reportPath, 'benchmark report')
  const bytes = fs.readFileSync(reportPath)
  let report
  try {
    report = JSON.parse(bytes.toString('utf8'))
  } catch (error) {
    fail(`benchmark report is not valid JSON: ${error.message}`)
  }
  validateControlledReport(report)
  return { bytes, report, stat }
}

function expectedManifest(reportValue, reportBytes, reportStat, provenance) {
  const artifactName = [
    contract.benchmarkId,
    provenance.commit,
    provenance.runId,
    provenance.runAttempt,
  ].join('-')
  return {
    schemaVersion: contract.schemaVersion,
    benchmarkId: contract.benchmarkId,
    source: {
      repository: contract.repository,
      ref: `refs/heads/${contract.branch}`,
      commit: provenance.commit,
    },
    run: {
      event: 'schedule',
      schedule: contract.schedule,
      id: provenance.runId,
      attempt: provenance.runAttempt,
      artifactName,
    },
    controlledHardware: {
      id: contract.benchmarkId,
      platform: reportValue.environment.platform,
      architecture: reportValue.environment.architecture,
      cpuModel: reportValue.environment.cpuModel,
      logicalCpuCount: reportValue.environment.logicalCpuCount,
      totalMemoryBytes: reportValue.environment.totalMemoryBytes,
      fingerprint: hardwareFingerprint(reportValue.environment),
    },
    report: {
      path: contract.artifact.report,
      sha256: sha256(reportBytes),
      sizeBytes: String(reportStat.size),
      generatedAt: reportValue.generatedAt,
    },
  }
}

function requireInventory(directory, expected) {
  const actual = fs.readdirSync(directory, { withFileTypes: true })
  for (const entry of actual) {
    if (!entry.isFile() || entry.isSymbolicLink()) {
      fail(`archive inventory entry ${entry.name} must be a regular non-symlink file`)
    }
  }
  const names = actual.map(entry => entry.name).sort()
  if (!same(names, [...expected].sort())) {
    fail(`archive inventory must contain exactly ${expected.join(', ')}`)
  }
}

export function validateBenchmarkArchiveContract(root = repositoryRoot) {
  const file = path.join(root, 'benchmarks', 'archive.json')
  const actual = readJson(file, 'benchmarks/archive.json')
  if (fs.readFileSync(file, 'utf8') !== `${JSON.stringify(contract, null, 2)}\n`) {
    fail('archive contract does not match the closed scheduling and retention policy')
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  return actual
}

function requireContains(source, value, message) {
  if (!source.includes(value)) fail(message)
}

function requireOrder(source, values, message) {
  let previous = -1
  for (const value of values) {
    const current = source.indexOf(value, previous + 1)
    if (current <= previous) fail(message)
    previous = current
  }
}

export function validateBenchmarkArchiveWorkflowSource(benchmarkWorkflow, buildWorkflow) {
  const prefix = `name: Benchmarks\n\non:\n  schedule:\n    - cron: '${contract.schedule}'\n\npermissions: {}`
  if (!benchmarkWorkflow.startsWith(prefix)) fail('scheduled workflow schedule or default permissions drifted')
  if (/^\s{2}(?:push|pull_request|workflow_dispatch):/m.test(benchmarkWorkflow)) {
    fail('scheduled workflow must not admit push, pull-request, or manual execution')
  }
  requireContains(
    benchmarkWorkflow,
    `concurrency:\n  group: ${contract.concurrencyGroup}\n  cancel-in-progress: false`,
    'scheduled workflow concurrency policy drifted',
  )
  requireContains(
    benchmarkWorkflow,
    `if: github.repository == '${contract.repository}' && github.ref == 'refs/heads/${contract.branch}'`,
    'scheduled workflow source boundary drifted',
  )
  requireContains(
    benchmarkWorkflow,
    `runs-on: [${contract.runner.labels.join(', ')}]`,
    'scheduled workflow must use the exact controlled runner labels',
  )
  requireContains(
    benchmarkWorkflow,
    'permissions:\n      contents: read',
    'scheduled workflow must use read-only repository contents',
  )
  requireContains(benchmarkWorkflow, 'timeout-minutes: 45', 'scheduled workflow timeout drifted')
  requireContains(
    benchmarkWorkflow,
    `name: ${contract.benchmarkId}-\${{ github.sha }}-\${{ github.run_id }}-\${{ github.run_attempt }}`,
    'scheduled workflow artifact identity drifted',
  )
  requireContains(
    benchmarkWorkflow,
    `retention-days: ${contract.artifact.retentionDays}`,
    'scheduled workflow artifact retention drifted',
  )
  requireContains(
    benchmarkWorkflow,
    `path: |\n            \${{ runner.temp }}/zigcss-benchmark-archive/${contract.artifact.report}\n            \${{ runner.temp }}/zigcss-benchmark-archive/${contract.artifact.manifest}`,
    'scheduled workflow artifact inventory drifted',
  )
  requireOrder(
    benchmarkWorkflow,
    [
      '- name: Install pinned benchmark dependencies',
      '- name: Build ReleaseFast benchmark executables',
      '- name: Validate benchmark prerequisites',
      '- name: Prepare benchmark archive directory',
      '- name: Collect complete benchmark report',
      '- name: Seal and verify benchmark archive',
      '- name: Upload benchmark archive',
      '- name: Clean benchmark archive directory',
    ],
    'scheduled workflow collection, archival, or cleanup order drifted',
  )
  requireContains(
    benchmarkWorkflow,
    'node scripts/report-benchmark-statistics.mjs --output "$BENCHMARK_ARCHIVE_DIR/benchmark-report.json"',
    'scheduled workflow must collect the complete validated report',
  )
  requireContains(
    benchmarkWorkflow,
    'npm run test:workflows && npm run check:workflows',
    'scheduled workflow must recheck its immutable action and permission policy',
  )
  for (const mode of ['--write', '--check']) {
    requireContains(
      benchmarkWorkflow,
      `node scripts/archive-benchmark-report.mjs ${mode}`,
      `scheduled workflow is missing archive ${mode}`,
    )
  }
  requireContains(benchmarkWorkflow, 'if: always()', 'scheduled workflow cleanup must run unconditionally')
  requireContains(
    benchmarkWorkflow,
    'rm -rf -- "$BENCHMARK_ARCHIVE_DIR"',
    'scheduled workflow cleanup command drifted',
  )

  const statistics = buildWorkflow.indexOf('- name: Validate benchmark statistics')
  const archive = buildWorkflow.indexOf('- name: Validate benchmark archive policy')
  const command = buildWorkflow.indexOf(
    'npm run test:benchmark-archive && npm run check:benchmark-archive',
    archive,
  )
  if (statistics === -1 || archive <= statistics || command <= archive) {
    fail('build workflow must validate the benchmark archive policy after statistics')
  }
  return true
}

export function validateBenchmarkArchiveWorkflow(root = repositoryRoot) {
  validateBenchmarkArchiveContract(root)
  const benchmarkPath = path.join(root, '.github', 'workflows', 'benchmarks.yml')
  const buildPath = path.join(root, '.github', 'workflows', 'build.yml')
  requireRegularFile(benchmarkPath, 'benchmark workflow')
  requireRegularFile(buildPath, 'build workflow')
  return validateBenchmarkArchiveWorkflowSource(
    fs.readFileSync(benchmarkPath, 'utf8'),
    fs.readFileSync(buildPath, 'utf8'),
  )
}

export function writeBenchmarkArchive(directory, provenance, root = repositoryRoot) {
  validateBenchmarkArchiveContract(root)
  validateProvenance(provenance)
  requireArchiveDirectory(directory)
  requireInventory(directory, [contract.artifact.report])
  const report = readReport(directory)
  const manifest = expectedManifest(report.report, report.bytes, report.stat, provenance)
  const manifestPath = path.join(directory, contract.artifact.manifest)
  try {
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    })
    return validateBenchmarkArchive(directory, provenance, root)
  } catch (error) {
    fs.rmSync(manifestPath, { force: true })
    throw error
  }
}

export function validateBenchmarkArchive(directory, provenance, root = repositoryRoot) {
  validateBenchmarkArchiveContract(root)
  validateProvenance(provenance)
  requireArchiveDirectory(directory)
  requireInventory(directory, [contract.artifact.report, contract.artifact.manifest])
  const report = readReport(directory)
  const manifestPath = path.join(directory, contract.artifact.manifest)
  const manifest = readJson(manifestPath, 'benchmark archive manifest')

  if (manifest?.source?.commit !== provenance.commit) fail('archive source provenance does not match the run')
  if (manifest?.run?.id !== provenance.runId || manifest?.run?.attempt !== provenance.runAttempt) {
    fail('archive run provenance does not match the run')
  }
  const expected = expectedManifest(report.report, report.bytes, report.stat, provenance)
  if (manifest?.report?.sha256 !== expected.report.sha256 || manifest?.report?.sizeBytes !== expected.report.sizeBytes) {
    fail('archive report digest or size does not match the retained report')
  }
  if (fs.readFileSync(manifestPath, 'utf8') !== `${JSON.stringify(expected, null, 2)}\n`) {
    fail('archive manifest drifted from its report, source, run, or controlled hardware')
  }
  return manifest
}

function parseCommand(argumentsList) {
  if (argumentsList.length === 1 && argumentsList[0] === '--check-policy') return { mode: 'policy' }
  if (!['--write', '--check'].includes(argumentsList[0]) || argumentsList.length !== 9) {
    fail('usage: node scripts/archive-benchmark-report.mjs --check-policy|--write|--check --directory absolute-path --commit sha --run-id id --run-attempt attempt')
  }
  const result = { mode: argumentsList[0].slice(2) }
  const seen = new Set()
  for (let index = 1; index < argumentsList.length; index += 2) {
    const name = argumentsList[index]
    const value = argumentsList[index + 1]
    if (!['--directory', '--commit', '--run-id', '--run-attempt'].includes(name) || seen.has(name)) {
      fail('archive command arguments are invalid or duplicated')
    }
    seen.add(name)
    result[name.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value
  }
  if (!same([...seen].sort(), ['--commit', '--directory', '--run-attempt', '--run-id'])) {
    fail('archive command is missing a required argument')
  }
  if (!path.isAbsolute(result.directory)) fail('archive directory argument must be absolute')
  return result
}

function main() {
  const command = parseCommand(process.argv.slice(2))
  validateBenchmarkArchiveWorkflow(repositoryRoot)
  if (command.mode === 'policy') {
    process.stdout.write('Benchmark archive policy verified: weekly schedule, dedicated controlled runner, complete provenance, exact two-file inventory, and 90-day artifact retention.\n')
    return
  }
  const provenance = {
    commit: command.commit,
    runId: command.runId,
    runAttempt: command.runAttempt,
  }
  const manifest = command.mode === 'write'
    ? writeBenchmarkArchive(command.directory, provenance)
    : validateBenchmarkArchive(command.directory, provenance)
  process.stdout.write(`Benchmark archive ${command.mode === 'write' ? 'written' : 'verified'}: ${manifest.run.artifactName}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
