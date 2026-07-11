import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const validatorPackage = JSON.parse(
  fs.readFileSync(path.join(path.dirname(require.resolve('lightningcss')), '..', 'package.json'), 'utf8'),
)
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '../..')
const fixturesRoot = path.join(scriptDirectory, 'fixtures')
const matrixPath = path.join(scriptDirectory, 'matrix.json')

function fail(message) {
  throw new Error(message)
}

function compilerFromArguments(argumentsList) {
  let compiler = path.join(repositoryRoot, 'zig-out', 'bin', process.platform === 'win32' ? 'zigcss.exe' : 'zigcss')
  for (let index = 0; index < argumentsList.length; index += 1) {
    if (argumentsList[index] !== '--compiler') fail(`unknown argument: ${argumentsList[index]}`)
    if (index + 1 >= argumentsList.length) fail('--compiler requires a path')
    compiler = path.resolve(argumentsList[index + 1])
    index += 1
  }
  return compiler
}

function loadMatrix() {
  const matrix = JSON.parse(fs.readFileSync(matrixPath, 'utf8'))
  if (matrix.schemaVersion !== 1) fail(`unsupported matrix schema: ${matrix.schemaVersion}`)
  if (matrix.validator.package !== 'lightningcss') fail('matrix validator package must be lightningcss')
  if (matrix.validator.version !== validatorPackage.version) {
    fail(`matrix pins lightningcss ${matrix.validator.version}, installed ${validatorPackage.version}`)
  }
  if (matrix.validator.errorRecovery !== false) fail('independent validation must disable error recovery')
  if (matrix.validator.drafts?.nesting !== true) fail('independent validation must enable the nesting draft')

  const statuses = new Set(Object.keys(matrix.statuses))
  const cases = new Map()
  for (const testCase of matrix.cases) {
    if (cases.has(testCase.id)) fail(`duplicate case id: ${testCase.id}`)
    if (!['emit', 'reject'].includes(testCase.expectation)) fail(`invalid expectation for ${testCase.id}`)
    if (JSON.stringify(testCase.modes) !== JSON.stringify(['pretty', 'minified'])) {
      fail(`${testCase.id} must validate pretty and minified modes`)
    }
    const fixturePath = path.resolve(scriptDirectory, testCase.fixture)
    const fixturePrefix = `${path.resolve(fixturesRoot)}${path.sep}`
    if (!fixturePath.startsWith(fixturePrefix)) fail(`fixture escapes compatibility root: ${testCase.fixture}`)
    if (!fs.statSync(fixturePath).isFile()) fail(`fixture is not a file: ${testCase.fixture}`)
    if (fs.readFileSync(fixturePath).length === 0) fail(`fixture is empty: ${testCase.fixture}`)
    testCase.fixturePath = fixturePath
    cases.set(testCase.id, testCase)
  }

  const featureIds = new Set()
  const referencedCases = new Set()
  for (const feature of matrix.features) {
    if (featureIds.has(feature.id)) fail(`duplicate feature id: ${feature.id}`)
    featureIds.add(feature.id)
    if (!statuses.has(feature.status)) fail(`unknown status for ${feature.id}: ${feature.status}`)
    const testCase = cases.get(feature.case)
    if (!testCase) fail(`unknown case for ${feature.id}: ${feature.case}`)
    if ((feature.status === 'Rejected') !== (testCase.expectation === 'reject')) {
      fail(`status and expectation disagree for ${feature.id}`)
    }
    referencedCases.add(feature.case)
  }
  for (const caseId of cases.keys()) {
    if (!referencedCases.has(caseId)) fail(`case has no matrix feature: ${caseId}`)
  }
  return { matrix, cases }
}

function runCompiler(compiler, testCase, mode) {
  const argumentsList = [testCase.fixturePath]
  if (mode === 'minified') argumentsList.push('--minify')
  const result = spawnSync(compiler, argumentsList, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  })
  if (result.error) fail(`${testCase.id}/${mode}: compiler launch failed: ${result.error.message}`)
  if (result.signal) fail(`${testCase.id}/${mode}: compiler terminated by ${result.signal}`)
  return result
}

function validateEmission(testCase, mode, result, validatorOptions) {
  if (result.status !== 0) {
    fail(`${testCase.id}/${mode}: compiler exited ${result.status}\n${result.stderr}`)
  }
  if (result.stdout.length === 0) fail(`${testCase.id}/${mode}: compiler emitted empty CSS`)
  if (!result.stderr.includes('experimental recovery build')) {
    fail(`${testCase.id}/${mode}: recovery boundary warning is missing`)
  }

  let independent
  try {
    independent = transform({
      filename: `${testCase.id}-${mode}.css`,
      code: Buffer.from(result.stdout),
      minify: false,
      errorRecovery: validatorOptions.errorRecovery,
      drafts: validatorOptions.drafts,
    })
  } catch (error) {
    fail(`${testCase.id}/${mode}: Lightning CSS rejected ZigCSS output: ${error.message}`)
  }
  const expectedWarnings = testCase.validatorWarnings ?? []
  if (independent.warnings.length !== expectedWarnings.length) {
    fail(`${testCase.id}/${mode}: Lightning CSS warnings: ${JSON.stringify(independent.warnings)}`)
  }
  for (let index = 0; index < expectedWarnings.length; index += 1) {
    if (!independent.warnings[index].message.includes(expectedWarnings[index])) {
      fail(`${testCase.id}/${mode}: unexpected Lightning CSS warning: ${independent.warnings[index].message}`)
    }
  }
}

function validateRejection(testCase, mode, result) {
  if (result.status === 0) fail(`${testCase.id}/${mode}: unsupported syntax compiled successfully`)
  if (result.stdout.length !== 0) fail(`${testCase.id}/${mode}: rejected syntax emitted partial CSS`)
  if (!result.stderr.includes(testCase.diagnostic)) {
    fail(`${testCase.id}/${mode}: missing diagnostic ${JSON.stringify(testCase.diagnostic)}\n${result.stderr}`)
  }
}

const compiler = compilerFromArguments(process.argv.slice(2))
fs.accessSync(compiler, fs.constants.F_OK)
const { matrix, cases } = loadMatrix()
let emitted = 0
let rejected = 0

for (const testCase of cases.values()) {
  for (const mode of testCase.modes) {
    const result = runCompiler(compiler, testCase, mode)
    if (testCase.expectation === 'emit') {
      validateEmission(testCase, mode, result, matrix.validator)
      emitted += 1
    } else {
      validateRejection(testCase, mode, result)
      rejected += 1
    }
  }
}

console.log(
  `Compatibility matrix verified: ${matrix.features.length} features, ${emitted} independently parsed outputs, ${rejected} deterministic rejections (Lightning CSS ${validatorPackage.version}).`,
)
