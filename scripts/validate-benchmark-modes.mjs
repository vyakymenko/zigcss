import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { expectedCorpus, validateRepository as validateCorpora } from './generate-benchmark-corpora.mjs'
import {
  admitTimingSample,
  resolveBenchmarkExecutables,
  runBenchmarkCli,
  validateBenchmarkOutputContract,
  validateOutput,
} from './validate-benchmark-output.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const allTools = ['zigcss', 'esbuild', 'lightningcss']
const manifest = {
  schemaVersion: 1,
  clock: 'monotonic-nanoseconds',
  outputValidation: 'after-timing-before-admission',
  modes: [
    {
      id: 'cold-cli',
      metric: 'latency-nanoseconds',
      tools: allTools,
      processLifecycle: 'new-process-per-iteration',
      cachePreparation: 'no-mode-local-warmup',
      includesProcessStartup: true,
      timed: true,
      warmupIterations: 0,
      measuredIterations: 1,
    },
    {
      id: 'warm-cli',
      metric: 'latency-nanoseconds',
      tools: allTools,
      processLifecycle: 'new-process-per-iteration',
      cachePreparation: 'one-validated-mode-local-warmup',
      includesProcessStartup: true,
      timed: true,
      warmupIterations: 1,
      measuredIterations: 1,
    },
    {
      id: 'in-process-api',
      metric: 'latency-nanoseconds',
      tools: ['zigcss'],
      processLifecycle: 'in-process-zig-api',
      includesProcessStartup: false,
      timed: true,
      warmupIterations: 1,
      measuredIterations: 1,
    },
    {
      id: 'memory',
      metric: 'allocator-requested-bytes',
      tools: ['zigcss'],
      processLifecycle: 'in-process-zig-api',
      includesProcessStartup: false,
      timed: false,
      warmupIterations: 0,
      measuredIterations: 1,
      fields: [
        'totalAllocatedBytes',
        'totalFreedBytes',
        'peakLiveBytes',
        'retainedResultBytes',
        'allocationCount',
        'deallocationCount',
        'resizeCount',
      ],
    },
    {
      id: 'throughput',
      metric: 'input-bytes-per-second',
      tools: ['zigcss'],
      processLifecycle: 'in-process-zig-api',
      includesProcessStartup: false,
      timed: true,
      warmupIterations: 1,
      measuredIterations: 2,
    },
  ],
}

const packageScripts = {
  'check:benchmark-modes': 'node scripts/validate-benchmark-modes.mjs --check',
  'test:benchmark-modes': 'node --test scripts/validate-benchmark-modes.test.mjs',
}

function fail(message) {
  throw new Error(`benchmark modes: ${message}`)
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

export function validateBenchmarkModeContract(root = repositoryRoot) {
  const manifestPath = path.join(root, 'benchmarks', 'modes.json')
  const actual = readJson(manifestPath, 'benchmarks/modes.json')
  if (fs.readFileSync(manifestPath, 'utf8') !== `${JSON.stringify(manifest, null, 2)}\n`) {
    fail('mode manifest does not match the closed execution contract')
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  return actual
}

function positiveDuration(durationNanoseconds) {
  if (typeof durationNanoseconds !== 'bigint' || durationNanoseconds <= 0n) {
    fail('timed duration must be a positive bigint')
  }
}

export function admitThroughputSample(samples, durationNanoseconds, operations) {
  if (!Array.isArray(samples)) fail('throughput sample destination must be an array')
  positiveDuration(durationNanoseconds)
  if (!Array.isArray(operations) || operations.length === 0) {
    fail('throughput sample must contain at least one operation')
  }
  for (const operation of operations) {
    if (operation === null || typeof operation !== 'object') fail('throughput operation must be an object')
    validateOutput(operation.input, operation.output, operation.label)
  }
  samples.push(durationNanoseconds)
}

function runCliModes(root, compiler, corpora, files, temporary) {
  const outputManifest = validateBenchmarkOutputContract(root)
  const tools = new Map(outputManifest.tools.map(tool => [tool.id, tool]))
  const executables = resolveBenchmarkExecutables(root, compiler)
  const accepted = { cold: 0, warm: 0 }

  for (const mode of manifest.modes.slice(0, 2)) {
    const destination = []
    for (const corpus of corpora) {
      const inputPath = path.join(root, corpus.path)
      const input = Buffer.from(files.get(path.basename(corpus.path)))
      for (const toolId of mode.tools) {
        const tool = tools.get(toolId)
        const executable = executables.get(toolId)
        if (tool === undefined || executable === undefined) fail(`missing CLI contract for ${toolId}`)
        const outputPath = path.join(temporary, `${mode.id}-${corpus.id}-${toolId}.css`)
        for (let warmup = 0; warmup < mode.warmupIterations; warmup += 1) {
          const warm = runBenchmarkCli(root, tool, executable, inputPath, outputPath)
          validateOutput(input, warm.output, `${mode.id}/${corpus.id}/${toolId}/warmup`)
        }
        const measured = runBenchmarkCli(
          root,
          tool,
          executable,
          inputPath,
          outputPath,
          process.hrtime.bigint,
        )
        admitTimingSample(
          destination,
          measured.durationNanoseconds,
          input,
          measured.output,
          `${mode.id}/${corpus.id}/${toolId}`,
        )
      }
    }
    if (mode.id === 'cold-cli') accepted.cold = destination.length
    else accepted.warm = destination.length
  }
  return accepted
}

export function runBenchmarkModeSmoke(root = repositoryRoot, compiler) {
  validateBenchmarkModeContract(root)
  validateCorpora(root)
  const expected = expectedCorpus()
  const files = new Map(expected.files.map(file => [file.name, file.content]))
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-modes-'))
  try {
    return runCliModes(root, compiler, expected.manifest.corpora, files, temporary)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

export function validateBenchmarkModeWorkflow(root = repositoryRoot) {
  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const output = workflow.indexOf('- name: Validate benchmark outputs')
  const modes = workflow.indexOf('- name: Validate benchmark modes')
  const command = workflow.indexOf(
    'npm run test:benchmark-modes && npm run check:benchmark-modes',
    modes,
  )
  const smoke = workflow.indexOf('- name: Run validated benchmark smoke')
  const smokeCommand = workflow.indexOf('run: zig build bench', smoke)
  if (
    output === -1 ||
    modes <= output ||
    command <= modes ||
    smoke <= command ||
    smokeCommand <= smoke
  ) {
    fail('workflow must separate benchmark modes after output acceptance and before their smoke')
  }
  return true
}

function compilerFromArguments(argumentsList) {
  if (argumentsList.length === 0) return undefined
  if (argumentsList.length !== 2 || argumentsList[0] !== '--compiler') {
    fail('usage: node scripts/validate-benchmark-modes.mjs --check [--compiler path]')
  }
  return argumentsList[1]
}

function main() {
  if (process.argv[2] !== '--check') {
    fail('usage: node scripts/validate-benchmark-modes.mjs --check [--compiler path]')
  }
  const compiler = compilerFromArguments(process.argv.slice(3))
  validateBenchmarkModeWorkflow(repositoryRoot)
  const report = runBenchmarkModeSmoke(repositoryRoot, compiler)
  process.stdout.write(
    `Benchmark modes verified: ${report.cold} cold CLI and ${report.warm} warm CLI cross-tool samples accepted only after validation; Zig in-process API, allocator-memory, and throughput modes are enforced separately by zig build bench; no result archived.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
