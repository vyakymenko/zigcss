import crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { expectedCorpus, validateRepository as validateCorpora } from './generate-benchmark-corpora.mjs'
import { verifyInstalledToolchain } from './validate-benchmark-toolchain.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const oraclePackage = JSON.parse(
  fs.readFileSync(path.join(path.dirname(require.resolve('lightningcss')), '..', 'package.json'), 'utf8'),
)
const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const manifest = {
  schemaVersion: 1,
  oracle: {
    package: 'lightningcss',
    version: '1.30.1',
    errorRecovery: false,
    minify: true,
  },
  limits: {
    timeoutMilliseconds: 120_000,
    stdioBytes: 1024 * 1024,
    maxOutputFactor: 4,
    maxOutputExtraBytes: 4096,
  },
  corpora: ['small-flat', 'medium-flat', 'large-flat'],
  tools: [
    {
      id: 'zigcss',
      arguments: ['{input}', '--minify', '-o', '{output}'],
      stderr: 'version-notice-and-compile-message',
    },
    {
      id: 'esbuild',
      arguments: [
        '{input}',
        '--minify',
        '--legal-comments=none',
        '--log-level=error',
        '--outfile={output}',
      ],
      stderr: 'empty',
    },
    {
      id: 'lightningcss',
      arguments: ['{input}', '--minify', '--output-file', '{output}'],
      stderr: 'empty',
    },
  ],
}

const packageScripts = {
  'check:benchmark-output': 'node scripts/validate-benchmark-output.mjs --check',
  'test:benchmark-output': 'node --test scripts/validate-benchmark-output.test.mjs',
}

function fail(message) {
  throw new Error(`benchmark output: ${message}`)
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

function readJson(file, label) {
  requireRegularFile(file, label)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function confinedExecutable(root, file, label) {
  if (!path.isAbsolute(file)) fail(`${label} must be absolute`)
  const stat = requireRegularFile(file, label)
  if (process.platform !== 'win32' && (stat.mode & 0o111) === 0) fail(`${label} is not executable`)
  const canonicalRoot = fs.realpathSync(root)
  const canonicalFile = fs.realpathSync(file)
  const relative = path.relative(canonicalRoot, canonicalFile)
  if (relative.startsWith('..') || path.isAbsolute(relative)) fail(`${label} escapes the repository`)
  return canonicalFile
}

export function validateBenchmarkOutputContract(root = repositoryRoot) {
  const manifestPath = path.join(root, 'benchmarks', 'output-validation.json')
  const actual = readJson(manifestPath, 'benchmarks/output-validation.json')
  if (fs.readFileSync(manifestPath, 'utf8') !== `${JSON.stringify(manifest, null, 2)}\n`) {
    fail('output-validation manifest does not match the closed acceptance contract')
  }
  if (oraclePackage.version !== manifest.oracle.version) {
    fail(`oracle version drifted: expected ${manifest.oracle.version}, installed ${oraclePackage.version}`)
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }
  if (packageJson.devDependencies?.[manifest.oracle.package] !== manifest.oracle.version) {
    fail(`package.json must pin ${manifest.oracle.package} to ${manifest.oracle.version}`)
  }

  const corpusIds = expectedCorpus().manifest.corpora.map(corpus => corpus.id)
  if (JSON.stringify(corpusIds) !== JSON.stringify(manifest.corpora)) {
    fail('output-validation manifest does not cover the complete ordered corpus inventory')
  }
  return actual
}

function bytes(value, label) {
  if (typeof value === 'string') return Buffer.from(value)
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return Buffer.from(value)
  fail(`${label} must be bytes or a string`)
}

function canonicalize(content, label) {
  let result
  try {
    result = transform({
      filename: `${label}.css`,
      code: content,
      minify: manifest.oracle.minify,
      errorRecovery: manifest.oracle.errorRecovery,
      drafts: { nesting: true },
    })
  } catch (error) {
    fail(`${label} is not recovery-free CSS: ${error.message}`)
  }
  if (result.warnings.length !== 0) fail(`${label} produced oracle warnings: ${JSON.stringify(result.warnings)}`)
  if (result.code.length === 0) fail(`${label} canonicalized to empty CSS`)
  return Buffer.from(result.code)
}

export function validateOutput(inputValue, outputValue, label = 'benchmark sample') {
  const input = bytes(inputValue, `${label} input`)
  const output = bytes(outputValue, `${label} output`)
  if (input.length === 0) fail(`${label} input is empty`)
  if (output.length === 0) fail(`${label} output is empty`)
  const maximum = input.length * manifest.limits.maxOutputFactor + manifest.limits.maxOutputExtraBytes
  if (output.length > maximum) fail(`${label} output exceeds ${maximum} bytes`)

  const expected = canonicalize(input, `${label} input`)
  const actual = canonicalize(output, `${label} output`)
  if (!actual.equals(expected)) fail(`${label} is not semantically equivalent to its corpus input`)
  return {
    inputBytes: input.length,
    outputBytes: output.length,
    canonicalSha256: crypto.createHash('sha256').update(actual).digest('hex'),
  }
}

export function admitTimingSample(samples, durationNanoseconds, input, output, label) {
  if (!Array.isArray(samples)) fail('timing sample destination must be an array')
  if (typeof durationNanoseconds !== 'bigint' || durationNanoseconds <= 0n) {
    fail('timing sample duration must be a positive bigint')
  }
  validateOutput(input, output, label)
  samples.push(durationNanoseconds)
}

function commandEnvironment() {
  const environment = {
    NO_COLOR: '1',
    FORCE_COLOR: '0',
    LANG: 'C',
    LC_ALL: 'C',
  }
  if (process.platform === 'win32') {
    for (const name of ['ComSpec', 'SystemRoot', 'SYSTEMROOT']) {
      if (process.env[name] !== undefined) environment[name] = process.env[name]
    }
  }
  return environment
}

function renderArguments(argumentsList, input, output) {
  return argumentsList.map(argument => argument.replaceAll('{input}', input).replaceAll('{output}', output))
}

export function renderZigCssStderr(version, input, output) {
  const parsed = parseReleaseVersion(version, 'benchmark compiler version')
  const notice = parsed.prerelease === null
    ? ''
    : `Warning: ZigCSS ${parsed.value} is an experimental release candidate; do not use it for production CSS.\n`
  return `${notice}Compiled: ${input} -> ${output}\n`
}

function validateStderr(root, tool, stderr, input, output) {
  if (tool.stderr === 'empty') {
    if (stderr !== '') fail(`${tool.id} emitted unexpected stderr: ${JSON.stringify(stderr)}`)
    return
  }
  const versionPath = path.join(root, 'VERSION')
  requireRegularFile(versionPath, 'VERSION')
  const version = fs.readFileSync(versionPath, 'utf8').trim()
  const expected = renderZigCssStderr(version, input, output)
  if (tool.stderr !== 'version-notice-and-compile-message' || stderr !== expected) {
    fail(`${tool.id} stderr drifted: ${JSON.stringify(stderr)}`)
  }
}

export function runBenchmarkCli(root, tool, executable, input, output, clock) {
  fs.rmSync(output, { force: true })
  const started = clock?.()
  const result = spawnSync(executable, renderArguments(tool.arguments, input, output), {
    cwd: root,
    encoding: 'utf8',
    env: commandEnvironment(),
    maxBuffer: manifest.limits.stdioBytes,
    timeout: manifest.limits.timeoutMilliseconds,
  })
  const finished = clock?.()
  if (result.error) fail(`${tool.id} failed to run: ${result.error.message}`)
  if (result.signal !== null) fail(`${tool.id} terminated by ${result.signal}`)
  if (result.status !== 0) fail(`${tool.id} exited ${result.status}: ${JSON.stringify(result.stderr)}`)
  if (result.stdout !== '') fail(`${tool.id} emitted unexpected stdout: ${JSON.stringify(result.stdout)}`)
  validateStderr(root, tool, result.stderr, input, output)
  requireRegularFile(output, `${tool.id} output`)
  const outputBytes = fs.readFileSync(output)
  return {
    output: outputBytes,
    durationNanoseconds:
      started === undefined || finished === undefined ? undefined : finished - started,
  }
}

export function resolveBenchmarkExecutables(root = repositoryRoot, compilerArgument) {
  if (compilerArgument !== undefined && !path.isAbsolute(compilerArgument)) {
    fail('zigcss benchmark executable argument must be absolute')
  }
  const compiler = confinedExecutable(
    root,
    compilerArgument ?? path.join(root, 'zig-out', 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'),
    'zigcss benchmark executable',
  )
  const installed = verifyInstalledToolchain(root)
  const executables = new Map(installed.map(tool => [tool.id, tool.executable]))
  executables.set('zigcss', compiler)
  return executables
}

export function validateBenchmarkOutputs(root = repositoryRoot, compilerArgument) {
  validateBenchmarkOutputContract(root)
  validateCorpora(root)
  const executables = resolveBenchmarkExecutables(root, compilerArgument)

  const expected = expectedCorpus()
  const files = new Map(expected.files.map(file => [file.name, file.content]))
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-benchmark-output-'))
  let outputs = 0
  try {
    for (const corpus of expected.manifest.corpora) {
      const input = path.join(root, corpus.path)
      requireRegularFile(input, `${corpus.id} corpus`)
      const inputBytes = Buffer.from(files.get(path.basename(corpus.path)))
      for (const tool of manifest.tools) {
        const executable = executables.get(tool.id)
        if (executable === undefined) fail(`missing executable for ${tool.id}`)
        const output = path.join(temporary, `${corpus.id}-${tool.id}.css`)
        const result = runBenchmarkCli(root, tool, executable, input, output)
        validateOutput(inputBytes, result.output, `${corpus.id}/${tool.id}`)
        outputs += 1
      }
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  return { tools: manifest.tools.length, corpora: manifest.corpora.length, outputs }
}

export function validateBenchmarkOutputWorkflow(root = repositoryRoot) {
  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const toolchain = workflow.indexOf('- name: Validate benchmark toolchain')
  const output = workflow.indexOf('- name: Validate benchmark outputs')
  const command = workflow.indexOf(
    'npm run test:benchmark-output && npm run check:benchmark-output',
    output,
  )
  const smoke = workflow.indexOf('- name: Run validated benchmark smoke')
  const smokeCommand = workflow.indexOf('run: zig build bench', smoke)
  if (
    toolchain === -1 ||
    output <= toolchain ||
    command <= output ||
    smoke <= command ||
    smokeCommand <= smoke
  ) {
    fail('build workflow must validate every benchmark output before the benchmark smoke')
  }
  return true
}

function compilerFromArguments(argumentsList) {
  if (argumentsList.length === 0) return undefined
  if (argumentsList.length !== 2 || argumentsList[0] !== '--compiler') {
    fail('usage: node scripts/validate-benchmark-output.mjs --check [--compiler path]')
  }
  return argumentsList[1]
}

function main() {
  if (process.argv[2] !== '--check') {
    fail('usage: node scripts/validate-benchmark-output.mjs --check [--compiler path]')
  }
  const compiler = compilerFromArguments(process.argv.slice(3))
  validateBenchmarkOutputWorkflow(repositoryRoot)
  const report = validateBenchmarkOutputs(repositoryRoot, compiler)
  process.stdout.write(
    `Benchmark outputs verified: ${report.tools} tools x ${report.corpora} corpora = ${report.outputs} recovery-free semantically equivalent outputs; no timing sample accepted.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
