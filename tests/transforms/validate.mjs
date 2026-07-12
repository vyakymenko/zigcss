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
  {
    label: 'margin-shorthand-synthesis',
    passId: 'margin-shorthand-synthesis',
    input: path.join(scriptDirectory, 'fixtures', 'margin-shorthand-synthesis.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'margin-shorthand-synthesis.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'margin-shorthand-synthesis.expected.min.css'),
    },
    warningExpectation: 'none',
  },
  {
    label: 'adjacent-selector-rule-merge',
    passId: 'adjacent-selector-rule-merge',
    input: path.join(scriptDirectory, 'fixtures', 'selector-rule-merge.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'selector-rule-merge.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'selector-rule-merge.expected.min.css'),
    },
    warningExpectation: 'none',
  },
  {
    label: 'adjacent-at-rule-merge',
    passId: 'adjacent-at-rule-merge',
    input: path.join(scriptDirectory, 'fixtures', 'at-rule-merge.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'at-rule-merge.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'at-rule-merge.expected.min.css'),
    },
    warningExpectation: 'none',
  },
  {
    label: 'target-prefix-rewrite',
    passId: 'target-prefix-rewrite',
    input: path.join(scriptDirectory, 'fixtures', 'target-prefix-rewrite.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'target-prefix-rewrite.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'target-prefix-rewrite.expected.min.css'),
    },
    warningExpectation: 'none',
    semanticMode: 'compatibility-projection',
    sizeExpectation: 'increase',
    driverArgs: [
      '--targets',
      'chrome >= 22, edge >= 17, firefox >= 10, safari >= 7, ie >= 11',
    ],
    noOpDriverArgs: [
      '--targets',
      'chrome >= 120, edge >= 120, firefox >= 120',
    ],
  },
  {
    label: 'conservative-dead-code-extraction',
    passId: 'conservative-dead-code-extraction',
    input: path.join(scriptDirectory, 'fixtures', 'selector-extraction.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'selector-extraction.dead.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'selector-extraction.dead.expected.min.css'),
    },
    warningExpectation: 'none',
    semanticMode: 'selector-extraction',
    inventory: {
      classes: ['shell', 'critical', 'later', 'parent'],
      ids: ['hero'],
    },
    driverArgs: [
      '--complete-classes',
      '--known-class', 'shell',
      '--known-class', 'critical',
      '--known-class', 'later',
      '--known-class', 'parent',
      '--complete-ids',
      '--known-id', 'hero',
    ],
  },
  {
    label: 'conservative-critical-css-extraction',
    passId: 'conservative-critical-css-extraction',
    input: path.join(scriptDirectory, 'fixtures', 'selector-extraction.css'),
    expected: {
      pretty: path.join(scriptDirectory, 'fixtures', 'selector-extraction.critical.expected.css'),
      minified: path.join(scriptDirectory, 'fixtures', 'selector-extraction.critical.expected.min.css'),
    },
    warningExpectation: 'none',
    semanticMode: 'selector-extraction',
    inventory: {
      classes: ['critical', 'parent'],
      ids: ['hero'],
    },
    driverArgs: [
      '--complete-classes',
      '--known-class', 'critical',
      '--known-class', 'parent',
      '--complete-ids',
      '--known-id', 'hero',
    ],
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

function runDriver(
  driver,
  fixture,
  input,
  mode,
  passId = fixture.passId,
  driverArgs = passId === fixture.passId ? fixture.driverArgs : undefined,
) {
  const argumentsList = [input, '--pass', passId]
  if (driverArgs) argumentsList.push(...driverArgs)
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

function validateInvalidTargetQuery(driver, input) {
  const result = spawnSync(
    driver,
    [input, '--pass', 'target-prefix-rewrite', '--targets', 'defaults'],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
    },
  )
  if (result.error) fail(`target-prefix-rewrite/invalid-query: driver launch failed: ${result.error.message}`)
  if (result.signal) fail(`target-prefix-rewrite/invalid-query: driver terminated by ${result.signal}`)
  if (result.status === 0) fail('target-prefix-rewrite/invalid-query: dynamic target query was accepted')
  if (result.stdout.length !== 0) fail('target-prefix-rewrite/invalid-query: rejected query emitted CSS')
  if (!result.stderr.startsWith('invalid target query at byte 0: unknown_browser\n')) {
    fail(`target-prefix-rewrite/invalid-query: missing structured byte diagnostic\n${result.stderr}`)
  }
}

function validateInvalidExtractionInventories(driver, input) {
  const cases = [
    {
      label: 'incomplete-category',
      args: ['--known-class', 'critical'],
      diagnostic: '--known-class requires --complete-classes\n',
    },
    {
      label: 'duplicate-entry',
      args: ['--complete-classes', '--known-class', 'Critical', '--known-class', 'critical'],
      diagnostic: 'invalid extraction inventory: DuplicateEntry\n',
    },
  ]
  for (const testCase of cases) {
    const result = spawnSync(
      driver,
      [input, '--pass', 'conservative-critical-css-extraction', ...testCase.args],
      {
        cwd: repositoryRoot,
        encoding: 'utf8',
        maxBuffer: 8 * 1024 * 1024,
      },
    )
    const label = `selector-extraction/${testCase.label}`
    if (result.error) fail(`${label}: driver launch failed: ${result.error.message}`)
    if (result.signal) fail(`${label}: driver terminated by ${result.signal}`)
    if (result.status === 0) fail(`${label}: invalid inventory was accepted`)
    if (result.stdout.length !== 0) fail(`${label}: rejected inventory emitted CSS`)
    if (!result.stderr.startsWith(testCase.diagnostic)) {
      fail(`${label}: missing structured inventory diagnostic\n${result.stderr}`)
    }
  }
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

function hasVendorPrefix(value) {
  const prefixes = value?.vendorPrefix ?? value?.vendor_prefix
  return Array.isArray(prefixes) && prefixes.length > 0
}

function selectorHasVendorPrefix(selector) {
  return selector.some(component => hasVendorPrefix(component))
}

function projectCompatibility(code, label, warningExpectation) {
  let removed = 0
  let result
  try {
    result = transform({
      filename: `${label}.css`,
      code: Buffer.from(code),
      minify: true,
      errorRecovery: validatorOptions.errorRecovery,
      drafts: validatorOptions.drafts,
      visitor: {
        Rule(rule) {
          if (rule.type === 'keyframes' && hasVendorPrefix(rule.value)) {
            removed += 1
            return []
          }
          if (
            rule.type === 'style' &&
            rule.value.selectors.some(selectorHasVendorPrefix)
          ) {
            removed += 1
            return []
          }
        },
        Declaration(declaration) {
          if (hasVendorPrefix(declaration) || hasVendorPrefix(declaration.value?.propertyId)) {
            removed += 1
            return []
          }
          if (
            declaration.property === 'position' &&
            declaration.value?.type === 'sticky' &&
            declaration.value.value.length > 0
          ) {
            removed += 1
            return []
          }
          if (
            declaration.property === 'display' &&
            declaration.value?.type === 'pair' &&
            hasVendorPrefix(declaration.value.inside)
          ) {
            removed += 1
            return []
          }
        },
      },
    })
  } catch (error) {
    fail(`${label}: Lightning CSS rejected compatibility projection: ${error.message}`)
  }
  validateWarnings(result.warnings, warningExpectation, label)
  return { canonical: result.code.toString('utf8'), removed }
}

function asciiLower(value) {
  let result = ''
  for (const character of value) {
    const code = character.codePointAt(0)
    result += code >= 65 && code <= 90 ? String.fromCodePoint(code + 32) : character
  }
  return result
}

function inventoryContains(entries, value) {
  if (entries === null || entries === undefined) return true
  const expected = asciiLower(value)
  return entries.some(entry => asciiLower(entry) === expected)
}

function selectorImpossible(selector, inventory) {
  for (const component of selector) {
    if (component.type === 'class' && !inventoryContains(inventory.classes, component.name)) {
      return true
    }
    if (component.type === 'id' && !inventoryContains(inventory.ids, component.name)) {
      return true
    }
  }
  return false
}

function projectSelectorExtraction(code, fixture, label) {
  let removed = 0
  let result
  try {
    result = transform({
      filename: `${label}.css`,
      code: Buffer.from(code),
      minify: true,
      errorRecovery: validatorOptions.errorRecovery,
      drafts: validatorOptions.drafts,
      visitor: {
        Rule(rule) {
          if (
            rule.type === 'style' &&
            rule.value.selectors.every(selector => selectorImpossible(selector, fixture.inventory))
          ) {
            removed += 1
            return []
          }
        },
      },
    })
  } catch (error) {
    fail(`${label}: Lightning CSS rejected selector extraction projection: ${error.message}`)
  }
  validateWarnings(result.warnings, fixture.warningExpectation, label)
  return { canonical: result.code.toString('utf8'), removed }
}

function semanticCanonical(code, fixture, label) {
  if (fixture.semanticMode === 'compatibility-projection') {
    return projectCompatibility(code, label, fixture.warningExpectation)
  }
  if (fixture.semanticMode === 'selector-extraction') {
    return projectSelectorExtraction(code, fixture, label)
  }
  return {
    canonical: canonicalize(code, label, fixture.warningExpectation),
    removed: 0,
  }
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
validateInvalidTargetQuery(
  driver,
  path.join(scriptDirectory, 'fixtures', 'target-prefix-rewrite.css'),
)
validateInvalidExtractionInventories(
  driver,
  path.join(scriptDirectory, 'fixtures', 'selector-extraction.css'),
)
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-transform-'))

try {
  for (const fixture of fixtures) {
    const input = fs.readFileSync(fixture.input, 'utf8')
    const semanticInput = semanticCanonical(
      input,
      fixture,
      `${fixture.label}/input`,
    )
    const outputs = {}
    for (const mode of ['pretty', 'minified']) {
      const output = runDriver(driver, fixture, fixture.input, mode)
      outputs[mode] = output
      const expected = expectedOutput(fixture, mode)
      if (output !== expected) fail(`${fixture.label}/${mode}: output differs from the reviewed golden fixture`)
      const semanticOutput = semanticCanonical(output, fixture, `${fixture.label}/zigcss-${mode}`)
      if (semanticOutput.canonical !== semanticInput.canonical) {
        fail(
          `${fixture.label}/${mode}: independent canonical output differs from the original stylesheet` +
            `\ninput:  ${semanticInput.canonical}` +
            `\noutput: ${semanticOutput.canonical}`,
        )
      }
      if (
        fixture.semanticMode === 'compatibility-projection' &&
        semanticOutput.removed <= semanticInput.removed
      ) {
        fail(`${fixture.label}/${mode}: compatibility projection did not observe generated vendor forms`)
      }
      if (
        fixture.semanticMode === 'selector-extraction' &&
        (semanticInput.removed === 0 || semanticOutput.removed !== 0)
      ) {
        fail(`${fixture.label}/${mode}: independent selector inventory did not prove the exact extraction subset`)
      }

      const repeatedInput = path.join(temporaryDirectory, `${fixture.label}-${mode}.css`)
      fs.writeFileSync(repeatedInput, output)
      const repeatedOutput = runDriver(driver, fixture, repeatedInput, mode)
      if (repeatedOutput !== output) {
        fail(
          `${fixture.label}/${mode}: parse-transform-emit is not byte-idempotent` +
            `\nfirst:  ${output}` +
            `\nsecond: ${repeatedOutput}`,
        )
      }
    }

    const baseline = runDriver(driver, fixture, fixture.input, 'minified', 'none')
    if (fixture.sizeExpectation === 'increase') {
      if (Buffer.byteLength(outputs.minified) <= Buffer.byteLength(baseline)) {
        fail(`${fixture.label}: compatibility pass did not add target-required output`)
      }
    } else if (Buffer.byteLength(outputs.minified) >= Buffer.byteLength(baseline)) {
      fail(`${fixture.label}: verified pass did not reduce its transform-free minified baseline`)
    }

    if (fixture.noOpDriverArgs) {
      for (const mode of ['pretty', 'minified']) {
        const noOpOutput = runDriver(
          driver,
          fixture,
          fixture.input,
          mode,
          fixture.passId,
          fixture.noOpDriverArgs,
        )
        const noPassOutput = runDriver(driver, fixture, fixture.input, mode, 'none')
        if (noOpOutput !== noPassOutput) {
          fail(`${fixture.label}/${mode}: modern target query did not preserve exact transform-free output`)
        }
        if (noOpOutput === outputs[mode]) {
          fail(`${fixture.label}/${mode}: legacy and modern target queries produced identical output`)
        }
      }
    }
  }
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true })
}

console.log(
  `Transform differential verified: ${fixtures.map((fixture) => fixture.label).join(', ')} pretty/minified outputs, golden order, byte idempotence, independent canonical semantics, target-dependent compatibility output, independently proven selector subsets, structured query/inventory rejection, and pass-specific size contracts (Lightning CSS ${validatorPackage.version}).`,
)
