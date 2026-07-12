import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const bcd = require('@mdn/browser-compat-data')
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '..')
const manifestPath = path.join(repositoryRoot, 'data', 'prefixing', 'compatibility-source.json')
const outputPath = path.join(repositoryRoot, 'src', 'prefixing', 'generated_compat.zig')
const packagePath = path.join(repositoryRoot, 'package.json')
const lockPath = path.join(repositoryRoot, 'package-lock.json')
const expectedBrowsers = [
  { id: 'chrome', bcd: 'chrome' },
  { id: 'edge', bcd: 'edge' },
  { id: 'firefox', bcd: 'firefox' },
  { id: 'safari', bcd: 'safari' },
  { id: 'ios_safari', bcd: 'safari_ios' },
  { id: 'ie', bcd: 'ie' },
]

function fail(message) {
  throw new Error(message)
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

export function validateInputs(manifest) {
  if (manifest.schemaVersion !== 1) fail(`unsupported manifest schema ${manifest.schemaVersion}`)
  if (manifest.upstream.package !== '@mdn/browser-compat-data') fail('unexpected upstream package')
  if (manifest.upstream.version !== bcd.__meta?.version) {
    fail(`manifest pins BCD ${manifest.upstream.version}, installed ${bcd.__meta?.version}`)
  }
  if (manifest.upstream.releasedAt !== bcd.__meta?.timestamp) {
    fail(`manifest timestamp ${manifest.upstream.releasedAt} does not match installed BCD ${bcd.__meta?.timestamp}`)
  }
  if (!/^[0-9a-f]{40}$/.test(manifest.upstream.gitCommit)) fail('invalid upstream Git commit')
  if (!/^[0-9a-f]{40}$/.test(manifest.upstream.tarballSha1)) fail('invalid upstream tarball SHA-1')
  if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(manifest.upstream.tarballIntegrity)) {
    fail('invalid upstream tarball integrity')
  }
  if (manifest.upstream.license !== 'CC0-1.0') fail('unexpected upstream license')
  if (manifest.upstream.repository !== 'https://github.com/mdn/browser-compat-data') {
    fail('unexpected upstream repository')
  }

  const packageMetadata = readJson(packagePath)
  if (packageMetadata.devDependencies?.[manifest.upstream.package] !== manifest.upstream.version) {
    fail('BCD must be an exact devDependency')
  }
  const lock = readJson(lockPath)
  const locked = lock.packages?.[`node_modules/${manifest.upstream.package}`]
  if (locked?.version !== manifest.upstream.version) fail('package lock has a different BCD version')
  if (locked?.integrity !== manifest.upstream.tarballIntegrity) fail('package lock BCD integrity does not match manifest')
  if (locked?.license !== manifest.upstream.license) fail('package lock BCD license does not match manifest')

  if (JSON.stringify(manifest.browsers) !== JSON.stringify(expectedBrowsers)) {
    fail('manifest browsers must exactly match the target-query browser order')
  }

  const browserIds = new Set()
  const bcdBrowsers = new Set()
  for (const browser of manifest.browsers ?? []) {
    if (!/^[a-z][a-z_]*$/.test(browser.id)) fail(`invalid browser id ${browser.id}`)
    if (!/^[a-z][a-z_]*$/.test(browser.bcd)) fail(`invalid BCD browser id ${browser.bcd}`)
    if (browserIds.has(browser.id)) fail(`duplicate browser id ${browser.id}`)
    if (bcdBrowsers.has(browser.bcd)) fail(`duplicate BCD browser id ${browser.bcd}`)
    browserIds.add(browser.id)
    bcdBrowsers.add(browser.bcd)
  }
  if (browserIds.size === 0) fail('manifest must select browsers')

  const featureIds = new Set()
  const kinds = new Set(['property', 'value', 'selector', 'at_rule'])
  for (const feature of manifest.features ?? []) {
    if (!/^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+$/.test(feature.id)) fail(`invalid feature id ${feature.id}`)
    if (featureIds.has(feature.id)) fail(`duplicate feature id ${feature.id}`)
    if (!kinds.has(feature.kind)) fail(`invalid feature kind ${feature.kind}`)
    if (!Array.isArray(feature.bcdPath) || feature.bcdPath.length < 2 ||
        feature.bcdPath[0] !== 'css' ||
        feature.bcdPath.some(part => typeof part !== 'string' || !/^[a-z0-9_-]+$/.test(part))) {
      fail(`invalid BCD path for ${feature.id}`)
    }
    featureIds.add(feature.id)
  }
  if (featureIds.size === 0) fail('manifest must select features')
}

function valueAtPath(root, parts, featureId) {
  let value = root
  for (const part of parts) {
    value = value?.[part]
    if (value === undefined) fail(`missing BCD path for ${featureId}: ${parts.join('.')}`)
  }
  return value
}

export function parseVersion(value, context) {
  if (typeof value !== 'string' || !/^\d+(?:\.\d+){0,2}$/.test(value)) {
    fail(`${context} has unsupported version ${JSON.stringify(value)}`)
  }
  const rawParts = value.split('.')
  if (rawParts.some(part => part.length > 1 && part.startsWith('0'))) {
    fail(`${context} has a noncanonical version ${value}`)
  }
  const parts = rawParts.map(part => Number.parseInt(part, 10))
  if (parts.some(part => !Number.isSafeInteger(part) || part < 0 || part > 65535)) {
    fail(`${context} has out-of-range version ${value}`)
  }
  if (parts[0] === 0) fail(`${context} has a zero major version`)
  return { major: parts[0], minor: parts[1] ?? 0, patch: parts[2] ?? 0 }
}

export function compareVersions(left, right) {
  return left.major - right.major || left.minor - right.minor || left.patch - right.patch
}

export function hasNotes(value, context) {
  if (value === undefined) return false
  if (typeof value === 'string') {
    if (value.length === 0) fail(`${context} has an empty note`)
    return true
  }
  if (!Array.isArray(value) || value.some(note => typeof note !== 'string' || note.length === 0)) {
    fail(`${context} has invalid notes`)
  }
  return value.length > 0
}

function formFor(statement, context) {
  if (statement.prefix !== undefined && statement.alternative_name !== undefined) {
    fail(`${context} combines prefix and alternative_name`)
  }
  if (statement.prefix !== undefined) {
    if (typeof statement.prefix !== 'string' || !/^[\x20-\x7e]+$/.test(statement.prefix)) {
      fail(`${context} has invalid prefix`)
    }
    return { kind: 'prefix', value: statement.prefix }
  }
  if (statement.alternative_name !== undefined) {
    if (typeof statement.alternative_name !== 'string' ||
        !/^[\x20-\x7e]+$/.test(statement.alternative_name)) {
      fail(`${context} has invalid alternative_name`)
    }
    return { kind: 'alternative_name', value: statement.alternative_name }
  }
  return { kind: 'standard', value: '' }
}

export function normalizeSupport(feature, browser, raw) {
  if (raw === 'mirror') fail(`${feature.id}/${browser.id} uses unresolved mirror support`)
  const statements = Array.isArray(raw) ? raw : [raw]
  const normalized = []
  for (const [index, statement] of statements.entries()) {
    const context = `${feature.id}/${browser.id}[${index}]`
    if (statement === undefined || statement === null || typeof statement !== 'object') {
      fail(`${context} is missing or invalid`)
    }
    if (statement.version_added === false) continue
    if (statement.version_added === true || statement.version_added === null) {
      fail(`${context} lacks an exact version_added`)
    }
    if (statement.flags !== undefined) fail(`${context} requires runtime flags`)
    if (statement.partial_implementation !== undefined &&
        typeof statement.partial_implementation !== 'boolean') {
      fail(`${context} has invalid partial_implementation`)
    }
    const added = parseVersion(statement.version_added, `${context}.version_added`)
    const removed = statement.version_removed === undefined || statement.version_removed === null
      ? null
      : parseVersion(statement.version_removed, `${context}.version_removed`)
    if (removed !== null && compareVersions(removed, added) <= 0) {
      fail(`${context} has a non-increasing removal interval`)
    }
    if (statement.version_last !== undefined) {
      if (removed === null) fail(`${context} has version_last without an exact version_removed`)
      const last = parseVersion(statement.version_last, `${context}.version_last`)
      if (compareVersions(last, added) < 0 || compareVersions(last, removed) >= 0) {
        fail(`${context} has an inconsistent version_last interval`)
      }
    }
    normalized.push({
      browser: browser.id,
      added,
      removed,
      form: formFor(statement, context),
      partial: statement.partial_implementation === true,
      annotated: hasNotes(statement.notes, context),
    })
  }
  return normalized
}

function selectedData(manifest) {
  return [...manifest.features]
    .sort((left, right) => compareAscii(left.id, right.id))
    .map(feature => {
      const compat = valueAtPath(bcd, feature.bcdPath, feature.id)?.__compat
      if (compat === undefined || compat.support === undefined) fail(`${feature.id} has no __compat.support data`)
      const support = manifest.browsers.flatMap(browser =>
        normalizeSupport(feature, browser, compat.support[browser.bcd]),
      )
      if (support.length === 0) fail(`${feature.id} has no selected support statements`)
      return { id: feature.id, kind: feature.kind, support }
    })
}

export function compareAscii(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function zigString(value) {
  return JSON.stringify(value)
}

function zigVersion(version) {
  return `.{ .major = ${version.major}, .minor = ${version.minor}, .patch = ${version.patch} }`
}

function generate(manifestBytes, manifest, data) {
  const lines = [
    '// Generated by scripts/generate-prefix-data.mjs. Do not edit by hand.',
    'const types = @import("compatibility_types.zig");',
    '',
    'pub const source = types.SourceMetadata{',
    `    .package = ${zigString(manifest.upstream.package)},`,
    `    .version = ${zigString(manifest.upstream.version)},`,
    `    .git_commit = ${zigString(manifest.upstream.gitCommit)},`,
    `    .released_at = ${zigString(manifest.upstream.releasedAt)},`,
    `    .tarball_sha1 = ${zigString(manifest.upstream.tarballSha1)},`,
    `    .tarball_integrity = ${zigString(manifest.upstream.tarballIntegrity)},`,
    `    .license = ${zigString(manifest.upstream.license)},`,
    `    .repository = ${zigString(manifest.upstream.repository)},`,
    `    .manifest_sha256 = ${zigString(sha256(manifestBytes))},`,
    `    .selected_data_sha256 = ${zigString(sha256(JSON.stringify(data)))},`,
    '};',
    '',
  ]

  data.forEach((feature, featureIndex) => {
    lines.push(`const support_${featureIndex} = [_]types.SupportStatement{`)
    for (const statement of feature.support) {
      const removed = statement.removed === null ? 'null' : zigVersion(statement.removed)
      lines.push(
        `    .{ .browser = .${statement.browser}, .added = ${zigVersion(statement.added)}, ` +
        `.removed = ${removed}, .form = .{ .kind = .${statement.form.kind}, ` +
        `.value = ${zigString(statement.form.value)} }, .partial = ${statement.partial}, ` +
        `.annotated = ${statement.annotated} },`,
      )
    }
    lines.push('};', '')
  })

  lines.push('pub const features = [_]types.Feature{')
  data.forEach((feature, featureIndex) => {
    lines.push(
      `    .{ .id = ${zigString(feature.id)}, .kind = .${feature.kind}, ` +
      `.support = &support_${featureIndex} },`,
    )
  })
  lines.push('};', '')
  return formatZig(lines.join('\n'))
}

function formatZig(input) {
  const executable = process.env.ZIG ?? 'zig'
  const result = spawnSync(executable, ['fmt', '--stdin'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    input,
    maxBuffer: 8 * 1024 * 1024,
  })
  if (result.error) fail(`could not run Zig formatter ${JSON.stringify(executable)}: ${result.error.message}`)
  if (result.signal) fail(`Zig formatter terminated by ${result.signal}`)
  if (result.status !== 0) fail(`Zig formatter exited ${result.status}: ${result.stderr}`)
  return result.stdout
}

function main() {
  const argumentsList = process.argv.slice(2)
  const mode = argumentsList.length === 0 ? '--check' : argumentsList[0]
  if (argumentsList.length > 1 || !['--check', '--stdout', '--write'].includes(mode)) {
    fail('usage: node scripts/generate-prefix-data.mjs [--check|--stdout|--write]')
  }

  const manifestBytes = fs.readFileSync(manifestPath)
  const manifest = JSON.parse(manifestBytes.toString('utf8'))
  validateInputs(manifest)
  const data = selectedData(manifest)
  const output = generate(manifestBytes, manifest, data)

  if (mode === '--stdout') {
    process.stdout.write(output)
  } else if (mode === '--write') {
    fs.writeFileSync(outputPath, output)
    console.log(`Generated ${path.relative(repositoryRoot, outputPath)} from BCD ${manifest.upstream.version}.`)
  } else {
    const current = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, 'utf8') : ''
    if (current !== output) fail(`${path.relative(repositoryRoot, outputPath)} is stale; run npm run generate:prefix-data`)
    console.log(`Prefix compatibility data verified against BCD ${manifest.upstream.version}.`)
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main()
