import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const validatorPackage = JSON.parse(
  fs.readFileSync(path.join(path.dirname(require.resolve('lightningcss')), '..', 'package.json'), 'utf8'),
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
  const args = [input, sourceName]
  if (minified) args.push('--minify')
  const result = spawnSync(driver, args, {
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
  if (typeof payload.css !== 'string' || !Array.isArray(payload.exports)) {
    fail(`CSS Modules ${mode} payload has the wrong shape`)
  }
  const expectedClasses = ['card', 'icon', 'badge', '🔥']
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
  const expectedCss =
    `@import "theme.css";.card,.${names.card}:hover{color:red}` +
    `@media all{.${names.icon}:is(.${names.card},.${names.badge}){display:block}}` +
    `.${names['🔥']}{opacity:1}`
  const actualCanonical = canonicalize(payload.css, `css-modules-${mode}-actual`)
  const expectedCanonical = canonicalize(expectedCss, `css-modules-${mode}-expected`)
  if (actualCanonical !== expectedCanonical) {
    fail(
      `CSS Modules ${mode} semantic projection differs\nexpected ${expectedCanonical}\nactual   ${actualCanonical}`,
    )
  }
  return payload
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
  const invalid = path.join(temporary, 'invalid.css')
  fs.writeFileSync(
    input,
    '@import "theme.css";:global(.card),:local(.card):hover{color:red}' +
      '@media all{.icon:is(.card,.badge){display:block}}.🔥{opacity:1}',
  )
  fs.writeFileSync(invalid, ':local .card{color:red}')

  try {
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

    const rejected = runDriver(driver, invalid, sourceName, true)
    if (rejected.status === 0) fail('CSS Modules deferred syntax compiled successfully')
    if (rejected.stdout.length !== 0) fail('CSS Modules deferred syntax emitted partial output')
    if (!rejected.stderr.includes('CSS0009')) {
      fail(`CSS Modules deferred syntax omitted CSS0009\n${rejected.stderr}`)
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }

  return {
    outputs: 3,
    rejections: 1,
    validatorVersion: validatorPackage.version,
  }
}
