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
const fixtures = [
  {
    label: 'empty-rule-cleanup',
    passId: 'empty-rule-cleanup',
    input: path.join(scriptDirectory, 'fixtures', 'empty-cleanup.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'empty-cleanup.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'empty-cleanup.expected.min.css'),
    },
    warningExpectation: 'unknown-at-rule',
  },
  {
    label: 'numeric-math-folding',
    passId: 'numeric-math-folding',
    input: path.join(scriptDirectory, 'fixtures', 'math-folding.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'math-folding.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'math-folding.expected.min.css'),
    },
    warningExpectation: 'none',
  },
  {
    label: 'typed-color-zero-shortening',
    passId: 'typed-color-zero-shortening',
    input: path.join(scriptDirectory, 'fixtures', 'color-zero-shortening.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'color-zero-shortening.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'color-zero-shortening.expected.min.css'),
    },
    warningExpectation: 'none',
  },
]
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

function runDriver(driver, fixture, input, mode, passId = fixture.passId) {
  const argumentsList = [input, '--pass', passId]
  if (mode === 'minified') argumentsList.push('--minify')
  const result = spawnSync(driver, argumentsList, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  })
  const label = `${fixture.label}/${mode}/${passId}`
  if (result.error) fail(`${label}: transform driver launch failed: ${result.error.message}`)
  if (result.signal) fail(`${label}: transform driver terminated by ${result.signal}`)
  if (result.status !== 0) fail(`${label}: transform driver exited ${result.status}\n${result.stderr}`)
  if (result.stderr.length !== 0) fail(`${label}: transform driver wrote stderr:\n${result.stderr}`)
  if (result.stdout.length === 0) fail(`${label}: transform driver emitted empty CSS`)
  return result.stdout
}

function expectedOutput(fixture, mode) {
  const expected = fs.readFileSync(fixture.expected[mode], 'utf8')
  return mode === 'minified' && expected.endsWith('\n') ? expected.slice(0, -1) : expected
}

function validateWarnings(warnings, expectation, label) {
  if (expectation === 'none') {
    if (warnings.length !== 0) fail(`${label}: unexpected Lightning CSS warnings: ${JSON.stringify(warnings)}`)
    return
  }
  if (expectation === 'unknown-at-rule') {
    if (warnings.length === 1 && warnings[0].type === 'AtRuleInvalid' && warnings[0].value === 'unknown') {
      return
    }
    fail(`${label}: unexpected Lightning CSS warnings: ${JSON.stringify(warnings)}`)
  }
  fail(`${label}: unknown warning expectation ${expectation}`)
}

function canonicalize(code, label, warningExpectation) {
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
  validateWarnings(result.warnings, warningExpectation, label)
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
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-transform-'))

try {
  for (const fixture of fixtures) {
    const input = fs.readFileSync(fixture.input, 'utf8')
    const canonicalInput = canonicalize(
      input,
      `${fixture.label}/input`,
      fixture.warningExpectation,
    )
    const outputs = {}
    for (const mode of ['pretty', 'minified']) {
      const output = runDriver(driver, fixture, fixture.input, mode)
      outputs[mode] = output
      const expected = expectedOutput(fixture, mode)
      if (output !== expected) fail(`${fixture.label}/${mode}: output differs from the reviewed golden fixture`)
      if (
        canonicalize(output, `${fixture.label}/zigcss-${mode}`, fixture.warningExpectation) !==
        canonicalInput
      ) {
        fail(`${fixture.label}/${mode}: independent canonical output differs from the original stylesheet`)
      }

      const repeatedInput = path.join(temporaryDirectory, `${fixture.label}-${mode}.css`)
      fs.writeFileSync(repeatedInput, output)
      if (runDriver(driver, fixture, repeatedInput, mode) !== output) {
        fail(`${fixture.label}/${mode}: parse-transform-emit is not byte-idempotent`)
      }
    }

    const baseline = runDriver(driver, fixture, fixture.input, 'minified', 'none')
    if (Buffer.byteLength(outputs.minified) >= Buffer.byteLength(baseline)) {
      fail(`${fixture.label}: verified pass did not reduce its transform-free minified baseline`)
    }
  }
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true })
}

console.log(
  `Transform differential verified: ${fixtures.map((fixture) => fixture.label).join(', ')} pretty/minified outputs, golden order, byte idempotence, independent canonical semantics, and transform-attributable size reduction (Lightning CSS ${validatorPackage.version}).`,
)
