import { createHash } from 'node:crypto'
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
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const exactDriver = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32'
    ? 'zigcss-css-modules-test-driver.exe'
    : 'zigcss-css-modules-test-driver',
)

function fail(message) {
  throw new Error(message)
}

function lengthBytes(length) {
  const bytes = Buffer.alloc(8)
  bytes.writeBigUInt64LE(BigInt(length))
  return bytes
}

function expectedName(sourceName, className) {
  const normalizedSource = Buffer.from(sourceName.replace(/\\/g, '/'))
  const classBytes = Buffer.from(className)
  const hash = createHash('sha256')
  hash.update(Buffer.from('zigcss.css-modules.v1\0'))
  hash.update(lengthBytes(normalizedSource.length))
  hash.update(normalizedSource)
  hash.update(lengthBytes(classBytes.length))
  hash.update(classBytes)

  const readable = Buffer.from(
    Uint8Array.from(classBytes.subarray(0, 32), byte =>
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5a) ||
      (byte >= 0x61 && byte <= 0x7a) ||
      byte === 0x2d ||
      byte === 0x5f
        ? byte
        : 0x5f,
    ),
  ).toString('ascii')
  return `_zigcss_${readable}_${hash.digest('hex')}`
}

function runDriver(driver, input, sourceName, minified) {
  if (driver !== exactDriver) fail('CSS Modules driver escaped the exact repository test binary')
  const args = [input, sourceName]
  if (minified) args.push('--minify')
  const result = spawnSync(exactDriver, args, {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  })
  if (result.error) fail(`CSS Modules driver launch failed: ${result.error.message}`)
  if (result.signal) fail(`CSS Modules driver terminated by ${result.signal}`)
  return result
}

function canonicalize(css, label) {
  let result
  try {
    result = transform({
      filename: `${label}.css`,
      code: Buffer.from(css),
      minify: true,
      errorRecovery: false,
      drafts: { nesting: true },
    })
  } catch (error) {
    fail(`${label}: Lightning CSS rejected CSS Modules output: ${error.message}`)
  }
  if (result.warnings.length !== 0) {
    fail(`${label}: unexpected Lightning CSS warnings: ${JSON.stringify(result.warnings)}`)
  }
  return result.code.toString('utf8')
}

function validateCompositionOracle(css, sourceName) {
  let result
  try {
    result = transform({
      filename: sourceName,
      code: Buffer.from(css),
      minify: true,
      errorRecovery: false,
      drafts: { nesting: true },
      cssModules: { pattern: 'oracle_[local]_[hash]' },
    })
  } catch (error) {
    fail(`Lightning CSS rejected the composition oracle input: ${error.message}`)
  }
  if (result.warnings.length !== 0) {
    fail(`composition oracle emitted warnings: ${JSON.stringify(result.warnings)}`)
  }
  const base = result.exports?.base
  const item = result.exports?.item
  if (!base || !item) fail('composition oracle omitted base or item exports')
  const expected = [
    { type: 'local', name: base.name },
    { type: 'global', name: 'global-reset' },
    { type: 'dependency', name: 'external', specifier: './external.module.css' },
  ]
  if (JSON.stringify(item.composes) !== JSON.stringify(expected)) {
    fail(`Lightning CSS composition projection differs: ${JSON.stringify(item.composes)}`)
  }
}

function validateSuccess(result, sourceName, mode) {
  if (result.status !== 0) {
    fail(`CSS Modules ${mode} driver exited ${result.status}\n${result.stderr}`)
  }
  if (result.stderr.length !== 0) fail(`CSS Modules ${mode} emitted stderr: ${result.stderr}`)
  let payload
  try {
    payload = JSON.parse(result.stdout)
  } catch (error) {
    fail(`CSS Modules ${mode} emitted invalid JSON: ${error.message}\n${result.stdout}`)
  }
  if (
    typeof payload.css !== 'string' ||
    !Array.isArray(payload.exports) ||
    !Array.isArray(payload.dependencies)
  ) {
    fail(`CSS Modules ${mode} payload has the wrong shape`)
  }
  const expectedClasses = ['card', 'icon', 'badge', '🔥', 'base', 'item']
  if (JSON.stringify(payload.exports.map(entry => entry.name)) !== JSON.stringify(expectedClasses)) {
    fail(`CSS Modules ${mode} exports are not unique first-seen classes`)
  }
  const names = Object.fromEntries(
    expectedClasses.map(className => [className, expectedName(sourceName, className)]),
  )
  for (const entry of payload.exports) {
    if (entry.value !== names[entry.name]) {
      fail(`CSS Modules ${mode} name mismatch for ${entry.name}`)
    }
  }
  const item = payload.exports.find(entry => entry.name === 'item')
  const base = payload.exports.find(entry => entry.name === 'base')
  const expectedComposes = [
    { local: base.value },
    { global: 'global-reset' },
    { dependency: { name: 'external', specifier: './external.module.css' } },
  ]
  if (JSON.stringify(item.composes) !== JSON.stringify(expectedComposes)) {
    fail(`CSS Modules ${mode} composition references differ: ${JSON.stringify(item.composes)}`)
  }
  const dependencies = payload.dependencies.map(dependency => ({
    kind: dependency.kind,
    specifier: dependency.specifier,
    source_name: dependency.source_name,
  }))
  const expectedDependencies = [
    { kind: 'import', specifier: 'theme.css', source_name: sourceName },
    {
      kind: 'css_module',
      specifier: './external.module.css',
      source_name: sourceName,
    },
  ]
  if (JSON.stringify(dependencies) !== JSON.stringify(expectedDependencies)) {
    fail(`CSS Modules ${mode} dependency facts differ: ${JSON.stringify(dependencies)}`)
  }
  const expectedCss =
    `@import "theme.css";.card,.${names.card}:hover{color:red}` +
    `@media all{.${names.icon}:is(.${names.card},.${names.badge}){display:block}}` +
    `.${names['🔥']}{opacity:1}` +
    `.${names.base}{color:black}.${names.item}{display:grid}`
  const actualCanonical = canonicalize(payload.css, `css-modules-${mode}-actual`)
  const expectedCanonical = canonicalize(expectedCss, `css-modules-${mode}-expected`)
  if (actualCanonical !== expectedCanonical) {
    fail(
      `CSS Modules ${mode} semantic projection differs\nexpected ${expectedCanonical}\nactual   ${actualCanonical}`,
    )
  }
  return payload
}

function validateValueSuccess(result, sourceName, mode) {
  if (result.status !== 0) fail(`CSS Modules values ${mode} exited ${result.status}\n${result.stderr}`)
  if (result.stderr.length !== 0) fail(`CSS Modules values ${mode} emitted stderr`)
  const payload = JSON.parse(result.stdout)
  const expected = [
    { name: 'primary', value: '#bf4040' },
    { name: 'alias', value: '#bf4040' },
    { name: 'selector', value: 'card' },
    { name: 'bp', value: '(min-width: 30em)' },
    { name: 'card', value: expectedName(sourceName, 'card') },
  ]
  const actual = payload.exports.map(entry => ({ name: entry.name, value: entry.value }))
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`CSS Modules values ${mode} exports differ: ${JSON.stringify(actual)}`)
  }
  if (payload.exports.some(entry => entry.composes.length !== 0)) {
    fail(`CSS Modules values ${mode} unexpectedly composed an export`)
  }
  if (payload.dependencies.length !== 0) fail(`CSS Modules values ${mode} added a dependency`)
  if (payload.css.includes('@value') || payload.css.includes('.selector')) {
    fail(`CSS Modules values ${mode} leaked adapter syntax`)
  }
  const generated = expected[4].value
  const expectedCss =
    `.${generated}{color:#bf4040}` +
    `@media (min-width:30em){.${generated}{border-color:#bf4040}}`
  const actualCanonical = canonicalize(payload.css, `css-modules-values-${mode}-actual`)
  const expectedCanonical = canonicalize(expectedCss, `css-modules-values-${mode}-expected`)
  if (actualCanonical !== expectedCanonical) {
    fail(`CSS Modules values ${mode} semantic projection differs`)
  }
  return payload
}

function validateRejection(result, label) {
  if (result.status === 0) fail(`${label} compiled successfully`)
  if (result.stdout.length !== 0) fail(`${label} emitted partial output`)
  if (!result.stderr.includes('CSS0009')) fail(`${label} omitted CSS0009\n${result.stderr}`)
}

export function validateCssModules(driver) {
  try {
    fs.accessSync(driver, fs.constants.F_OK)
  } catch {
    fail(`CSS Modules test driver is missing; run 'zig build test' first: ${driver}`)
  }
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-css-modules-'))
  const sourceName = 'src/components/card.module.css'
  const input = path.join(temporary, 'fixture.css')
  const values = path.join(temporary, 'values.css')
  const invalid = path.join(temporary, 'invalid.css')
  const invalidValue = path.join(temporary, 'invalid-value.css')
  fs.writeFileSync(
    input,
    '@import "theme.css";:global(.card),:local(.card):hover{color:red}' +
      '@media all{.icon:is(.card,.badge){display:block}}.🔥{opacity:1}' +
      '.base{color:black}.item{composes:base;composes:global-reset from global;' +
      'composes:external from "./external.module.css";display:grid}',
  )
  fs.writeFileSync(
    values,
    '@value primary: #bf4040;@value alias: primary;@value selector: card;' +
      '@value bp: (min-width: 30em);.selector{color:alias}' +
      '@media bp{.selector{border-color:primary}}',
  )
  fs.writeFileSync(invalid, ':local .card{color:red}')
  fs.writeFileSync(invalidValue, '@value primary from "./tokens.css";.card{color:primary}')

  try {
    validateCompositionOracle(fs.readFileSync(input), sourceName)
    const prettyResult = runDriver(driver, input, sourceName, false)
    const minifiedResult = runDriver(driver, input, sourceName, true)
    const pretty = validateSuccess(prettyResult, sourceName, 'pretty')
    const minified = validateSuccess(minifiedResult, sourceName, 'minified')
    if (JSON.stringify(pretty.exports) !== JSON.stringify(minified.exports)) {
      fail('CSS Modules names vary by output format')
    }

    const repeated = runDriver(driver, input, sourceName, true)
    if (repeated.status !== 0 || repeated.stdout !== minifiedResult.stdout) {
      fail('CSS Modules minified result is not byte-deterministic')
    }

    const otherSource = 'src/components/other.module.css'
    const other = validateSuccess(
      runDriver(driver, input, otherSource, true),
      otherSource,
      'other-source',
    )
    if (other.exports[0].value === minified.exports[0].value) {
      fail('CSS Modules names are not source-specific')
    }

    const valueSource = 'src/components/values.module.css'
    const valuePretty = validateValueSuccess(
      runDriver(driver, values, valueSource, false),
      valueSource,
      'pretty',
    )
    const valueMinified = validateValueSuccess(
      runDriver(driver, values, valueSource, true),
      valueSource,
      'minified',
    )
    if (JSON.stringify(valuePretty.exports) !== JSON.stringify(valueMinified.exports)) {
      fail('CSS Modules value exports vary by output format')
    }

    validateRejection(runDriver(driver, invalid, sourceName, true), 'ambiguous scope')
    validateRejection(runDriver(driver, invalidValue, sourceName, true), 'imported @value')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }

  return {
    outputs: 5,
    rejections: 2,
    compositionDifferentials: 1,
    valueFixtures: 2,
    validatorVersion: validatorPackage.version,
  }
}
