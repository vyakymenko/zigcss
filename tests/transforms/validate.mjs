import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
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
const fixture = path.join(scriptDirectory, 'fixtures', 'empty-cleanup.css')
const expectedPaths = {
  pretty: path.join(scriptDirectory, 'fixtures', 'empty-cleanup.expected.css'),
  minified: path.join(scriptDirectory, 'fixtures', 'empty-cleanup.expected.min.css'),
}
const validatorOptions = {
  errorRecovery: false,
  drafts: { nesting: true },
}

function fail(message) {
  throw new Error(message)
}

function driverFromArguments(argumentsList) {
  let driver = path.join(
    repositoryRoot,
    'zig-out',
    'bin',
    process.platform === 'win32' ? 'zigcss-transform-test-driver.exe' : 'zigcss-transform-test-driver',
  )
  for (let index = 0; index < argumentsList.length; index += 1) {
    if (argumentsList[index] !== '--driver') fail(`unknown argument: ${argumentsList[index]}`)
    if (index + 1 >= argumentsList.length) fail('--driver requires a path')
    driver = path.resolve(argumentsList[index + 1])
    index += 1
  }
  return driver
}

function runDriver(driver, input, mode) {
  const argumentsList = [input]
  if (mode === 'minified') argumentsList.push('--minify')
  const result = spawnSync(driver, argumentsList, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  })
  if (result.error) fail(`${mode}: transform driver launch failed: ${result.error.message}`)
  if (result.signal) fail(`${mode}: transform driver terminated by ${result.signal}`)
  if (result.status !== 0) fail(`${mode}: transform driver exited ${result.status}\n${result.stderr}`)
  if (result.stderr.length !== 0) fail(`${mode}: transform driver wrote stderr:\n${result.stderr}`)
  if (result.stdout.length === 0) fail(`${mode}: transform driver emitted empty CSS`)
  return result.stdout
}

function expectedOutput(mode) {
  const expected = fs.readFileSync(expectedPaths[mode], 'utf8')
  return mode === 'minified' && expected.endsWith('\n') ? expected.slice(0, -1) : expected
}

function canonicalize(code, label) {
  let result
  try {
    result = transform({
      filename: `${label}.css`,
      code: Buffer.from(code),
      minify: true,
      errorRecovery: validatorOptions.errorRecovery,
      drafts: validatorOptions.drafts,
    })
  } catch (error) {
    fail(`${label}: Lightning CSS rejected the stylesheet: ${error.message}`)
  }
  if (
    result.warnings.length !== 1 ||
    result.warnings[0].type !== 'AtRuleInvalid' ||
    result.warnings[0].value !== 'unknown'
  ) {
    fail(`${label}: unexpected Lightning CSS warnings: ${JSON.stringify(result.warnings)}`)
  }
  return result.code.toString('utf8')
}

if (validatorPackage.version !== '1.30.1') {
  fail(`transform validation pins Lightning CSS 1.30.1, installed ${validatorPackage.version}`)
}
const packageMetadata = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
if (packageMetadata.devDependencies?.lightningcss !== validatorPackage.version) {
  fail('package metadata and installed Lightning CSS versions differ')
}

const driver = driverFromArguments(process.argv.slice(2))
fs.accessSync(driver, fs.constants.X_OK)
const input = fs.readFileSync(fixture, 'utf8')
const canonicalInput = canonicalize(input, 'input')
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-transform-'))

try {
  for (const mode of ['pretty', 'minified']) {
    const output = runDriver(driver, fixture, mode)
    const expected = expectedOutput(mode)
    if (output !== expected) fail(`${mode}: output differs from the reviewed golden fixture`)
    if (canonicalize(output, `zigcss-${mode}`) !== canonicalInput) {
      fail(`${mode}: independent canonical output differs from the original stylesheet`)
    }

    const repeatedInput = path.join(temporaryDirectory, `${mode}.css`)
    fs.writeFileSync(repeatedInput, output)
    if (runDriver(driver, repeatedInput, mode) !== output) {
      fail(`${mode}: parse-transform-emit is not byte-idempotent`)
    }
  }
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true })
}

const minified = runDriver(driver, fixture, 'minified')
if (Buffer.byteLength(minified) >= Buffer.byteLength(input)) {
  fail('minified cleanup fixture did not become smaller')
}

console.log(
  `Transform differential verified: empty-rule-cleanup pretty/minified outputs, golden order, byte idempotence, and size reduction (Lightning CSS ${validatorPackage.version}).`,
)
