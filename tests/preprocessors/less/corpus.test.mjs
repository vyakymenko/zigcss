import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import less from 'less'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import {
  LESS_VERSION,
  createLessProvider,
} from '../../../preprocessor/providers/less.mjs'
import { makeRequest } from '../protocol/helpers.mjs'
import { readStableRegularFile } from '../../../scripts/bounded-filesystem.mjs'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/less/corpus')
const filesRoot = path.join(corpusRoot, 'files')
const manifest = JSON.parse(fs.readFileSync(path.join(corpusRoot, 'manifest.json'), 'utf8'))
const selection = JSON.parse(fs.readFileSync(path.join(corpusRoot, 'selection.json'), 'utf8'))
const compiler = path.join(
  repositoryRoot,
  'zig-out/bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const activeVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
const prereleaseNotice = `Warning: ZigCSS ${activeVersion} is an experimental release candidate; do not use it for production CSS.\n`
const utf8 = new TextDecoder('utf-8', { fatal: true })
const provider = createLessProvider()
let directWarningCapture = null
const exactForwardOracleImportDrift = new Map([
  ['less-import-import-interpolation', [
    'import/import/interpolation-vars.less',
    'import/import/import-test-e.less',
    'import/import/import-interpolation.less',
    'import/import/import-interpolation2.less',
  ]],
])

less.logger.addListener(Object.freeze({
  warn(message) {
    if (directWarningCapture !== null) directWarningCapture.push(message)
  },
}))

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function sorted(values) {
  return [...values].sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
}

function listFiles(root) {
  const output = []
  function visit(directory, relative) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = path.join(directory, entry.name)
      assert.equal(entry.isSymbolicLink(), false, childRelative)
      if (entry.isDirectory()) visit(child, childRelative)
      else {
        assert.equal(entry.isFile(), true, childRelative)
        output.push(childRelative)
      }
    }
  }
  visit(root, '')
  return sorted(output)
}

function caseData(specCase) {
  const root = path.join(filesRoot, ...specCase.suite.split('/'))
  const entry = path.join(filesRoot, ...specCase.entry.split('/'))
  const expected = path.join(filesRoot, ...specCase.expected.split('/'))
  return {
    ...specCase,
    root,
    entry,
    entryUrl: pathToFileURL(entry).href,
    source: utf8.decode(fs.readFileSync(entry)),
    expectation: utf8.decode(fs.readFileSync(expected)),
    providerOptions: { ...manifest.options[specCase.outcome] },
  }
}

function relativeSource(value, specCase) {
  let filename
  if (value === null || value === undefined) {
    filename = specCase.entry
  } else if (value instanceof URL) {
    assert.equal(value.protocol, 'file:', `${specCase.id}: non-file source URL`)
    filename = fileURLToPath(value)
  } else if (typeof value === 'string' && value.startsWith('file:')) {
    const parsed = new URL(value)
    assert.equal(parsed.protocol, 'file:', `${specCase.id}: non-file source URL`)
    filename = fileURLToPath(parsed)
  } else {
    assert.equal(typeof value, 'string', `${specCase.id}: invalid source identity`)
    filename = value
  }
  const relative = path.relative(specCase.root, filename)
  assert.equal(
    relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative),
    false,
    `${specCase.id}: source identity escapes its suite root`,
  )
  return relative.split(path.sep).join('/')
}

function location(error) {
  const line = Number.isSafeInteger(error?.line) && error.line >= 1 ? error.line : null
  const column = line !== null && Number.isSafeInteger(error?.column) && error.column >= 0
    ? error.column + 1
    : null
  return { line, column }
}

function directWarning(value, specCase) {
  assert.equal(typeof value, 'string', `${specCase.id}: canonical warning shape`)
  let message = value
  let filename = null
  let line = null
  let column = null
  const located = /^(.*) in ([^\r\n]+) on line ([0-9]+), column ([0-9]+):(?:\r?\n[\s\S]*)?$/.exec(message)
  if (located !== null) {
    message = located[1]
    filename = located[2]
    line = Number(located[3])
    column = Number(located[4])
  }
  let severity = 'warning'
  let code = 'less.warning'
  if (message.startsWith('DEPRECATED WARNING: ')) {
    message = message.slice('DEPRECATED WARNING: '.length)
    severity = 'warning'
    code = 'less.deprecation'
  } else if (message.startsWith('WARNING: ')) {
    message = message.slice('WARNING: '.length)
  }
  return {
    severity,
    code,
    message,
    source: relativeSource(filename, specCase),
    line,
    column,
  }
}

function adapterDiagnostics(values, specCase) {
  return values.map(diagnostic => ({
    severity: diagnostic.severity,
    code: diagnostic.code,
    message: diagnostic.message,
    source: relativeSource(diagnostic.sourceUrl, specCase),
    line: diagnostic.line,
    column: diagnostic.column,
  }))
}

function directDependencies(values, specCase) {
  return values.map(value => relativeSource(value, specCase))
}

function formattedDirectError(error, specCase) {
  const directory = `${path.dirname(specCase.entry)}${path.sep}`
  const rendered = error.toString().replaceAll('\r\n', '\n')
  if (!specCase.expectation.includes('{path}')) {
    assert.equal(rendered.includes(directory), false, `${specCase.id}: unexpected error source path`)
    return rendered
  }
  assert.equal(rendered.includes(directory), true, `${specCase.id}: canonical error source path`)
  return rendered.split(directory).join('{path}')
}

async function compileDirect(specCase) {
  const warnings = []
  directWarningCapture = warnings
  try {
    const result = await less.render(specCase.source, {
      color: false,
      compress: false,
      disablePluginRule: true,
      filename: specCase.entry,
      insecure: false,
      javascriptEnabled: false,
      math: specCase.providerOptions.math,
      paths: [],
      quietDeprecations: specCase.providerOptions.quietDeprecations,
      rewriteUrls: specCase.providerOptions.rewriteUrls,
      strictUnits: specCase.providerOptions.strictUnits,
      syncImport: false,
    })
    return {
      outcome: 'success',
      css: result.css,
      diagnostics: warnings.map(value => directWarning(value, specCase)),
      dependencies: directDependencies(result.imports, specCase),
    }
  } catch (error) {
    const position = location(error)
    return {
      outcome: 'error',
      formatted: formattedDirectError(error, specCase),
      diagnostics: [
        ...warnings.map(value => directWarning(value, specCase)),
        {
          severity: 'error',
          code: 'less.compile',
          message: error.message,
          source: relativeSource(error.filename, specCase),
          line: position.line,
          column: position.column,
        },
      ],
    }
  } finally {
    directWarningCapture = null
  }
}

async function compileAdapter(specCase) {
  const request = makeRequest({
    provider: 'less',
    syntax: 'less',
    source: specCase.source,
    sourceUrl: specCase.entryUrl,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [specCase.root],
      providerOptions: specCase.providerOptions,
    },
  })
  try {
    const result = await provider.compile(request, { signal: new AbortController().signal })
    return {
      outcome: 'success',
      css: result.css,
      diagnostics: adapterDiagnostics(result.diagnostics, specCase),
      dependencies: result.dependencies.map(item => relativeSource(item.url, specCase)),
      dependencyKinds: result.dependencies.map(item => item.kind),
    }
  } catch (error) {
    assert.equal(error instanceof ProviderFailure, true, `${specCase.id}: adapter error ownership`)
    assert.equal('css' in error, false, `${specCase.id}: failure must not own CSS`)
    return {
      outcome: 'error',
      code: error.code,
      message: error.message,
      diagnostics: adapterDiagnostics(error.diagnostics, specCase),
    }
  }
}

async function boundedParallel(values, workerCount, callback) {
  const output = new Array(values.length)
  let next = 0
  const workers = Array.from({ length: Math.min(workerCount, values.length) }, async () => {
    while (true) {
      const index = next
      next += 1
      if (index >= values.length) return
      output[index] = await callback(values[index], index)
    }
  })
  await Promise.all(workers)
  return output
}

function runZigCss(input, id, pass) {
  const result = spawnSync(compiler, ['-', '--syntax', 'css'], {
    cwd: repositoryRoot,
    input,
    encoding: 'utf8',
    maxBuffer: 24 * 1024 * 1024,
  })
  assert.equal(result.error, undefined, `${id}: ZigCSS ${pass} launch`)
  assert.equal(result.signal, null, `${id}: ZigCSS ${pass} signal`)
  assert.equal(result.status, 0, `${id}: ZigCSS ${pass}\n${result.stderr}`)
  assert.equal(result.stderr, prereleaseNotice, `${id}: ZigCSS prerelease warning boundary`)
  return result.stdout
}

test('runs exact Less 4.9.0 against the frozen official Less 4.6.7 corpus', () => {
  assert.equal(LESS_VERSION, '4.9.0')
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.caseCount, 88)
  assert.equal(manifest.successCount, 68)
  assert.equal(manifest.errorCount, 20)
  assert.equal(manifest.files.length, 217)
  assert.deepEqual(manifest.upstream, selection.upstream)
  assert.deepEqual(manifest.upstream, {
    repository: 'https://github.com/less/less.js',
    tag: 'v4.6.7',
    tagObject: '1c14e30ca4a857ebf220c9223a5e71fc2fc1764e',
    revision: '8ae2cc3bfa79f0718ad6fe5f263a1d6819fe9d5c',
    tree: '77299b2e4390d6e2b8592d6ca2dbb495189149b1',
    archiveSha256: '9c53e2e65ce1b73fb192e735d3b267c590139212bc76b88151ec546793260577',
    rootPackageSha256: '48a2f0e35ec14107beed6d0279e996fd99754e9ca8b258a5adc0b61841eb17fb',
    providerPackageSha256: 'cc8336c3a08e2be27701c819c066eec04b6c8813d398459049c979c6bc967a46',
    packageVersion: '4.6.7',
    license: 'Apache-2.0',
    licenseSha256: '39445b459f86621683f9731fb6a7d070819dc379840e8ef52f62bb1c68942291',
  })
  assert.deepEqual(manifest.options, selection.options)
  assert.deepEqual(manifest.cases.map(item => item.id), selection.cases.map(item => item.id))

  const license = fs.readFileSync(path.join(corpusRoot, manifest.licenseFile.path))
  assert.equal(sha256(license), manifest.licenseFile.sha256)
  assert.match(license.toString('utf8'), /Apache License/)
  assert.match(license.toString('utf8'), /Version 2\.0, January 2004/)

  const expectedInventory = []
  const names = new Set()
  for (const file of manifest.files) {
    assert.equal(names.has(file.path), false, `duplicate corpus file ${file.path}`)
    names.add(file.path)
    assert.equal(file.source, `packages/test-data/${file.path}`)
    assert.doesNotMatch(file.path, /(?:^|\/)\.\.(?:\/|$)|\\|[\u0000\r\n]/)
    const filename = path.join(filesRoot, ...file.path.split('/'))
    const bytes = readStableRegularFile(filename, {
      allowEmpty: true,
      label: file.path,
      maximumBytes: Math.max(file.bytes, 1),
      reject: assert.fail,
    })
    assert.equal(bytes.length, file.bytes, `${file.path}: size`)
    assert.equal(sha256(bytes), file.sha256, `${file.path}: checksum`)
    expectedInventory.push(file.path)
  }
  assert.deepEqual(listFiles(filesRoot), sorted(expectedInventory))
  assert.equal(manifest.files.some(file => /\.(?:c?js|mjs)$/.test(file.path)), false)

  const features = new Set()
  const groups = { success: 0, error: 0 }
  for (const specCase of manifest.cases) {
    features.add(specCase.feature)
    if (specCase.outcome === 'success') groups.success += 1
    else if (specCase.outcome === 'error') groups.error += 1
    else assert.fail(`unknown Less corpus outcome ${JSON.stringify(specCase.outcome)}`)
    assert.equal(names.has(specCase.entry), true, `${specCase.id}: entry inventory`)
    assert.equal(names.has(specCase.expected), true, `${specCase.id}: expectation inventory`)
    assert.equal(Array.isArray(specCase.dependencies), true, `${specCase.id}: dependencies`)
    assert.equal(new Set(specCase.dependencies).size, specCase.dependencies.length)
    for (const dependency of specCase.dependencies) {
      assert.equal(
        names.has(`${specCase.suite}/${dependency}`),
        true,
        `${specCase.id}: dependency inventory`,
      )
    }
    if (specCase.outcome === 'error') assert.deepEqual(specCase.dependencies, [])
  }
  assert.deepEqual(groups, { success: 68, error: 20 })
  for (const feature of [
    'at-rules-targeted',
    'calc',
    'color-functions',
    'detached-rulesets',
    'extend',
    'import',
    'mixins',
    'operations',
    'selectors',
    'strings',
    'variables',
    'negative-parser',
    'negative-units',
  ]) {
    assert.equal(features.has(feature), true, feature)
  }
})

test('matches exact Less across all 88 official success and negative cases', {
  timeout: 120_000,
}, async () => {
  const cases = manifest.cases.map(caseData)
  const baseline = new Map()
  const observedForwardImportDrift = new Set()
  for (const specCase of cases) {
    const direct = await compileDirect(specCase)
    const adapter = await compileAdapter(specCase)
    assert.equal(direct.outcome, specCase.outcome, `${specCase.id}: upstream outcome`)
    assert.equal(adapter.outcome, direct.outcome, `${specCase.id}: adapter outcome`)
    assert.deepEqual(adapter.diagnostics, direct.diagnostics, `${specCase.id}: diagnostics`)
    if (specCase.outcome === 'success') {
      assert.equal(direct.css, specCase.expectation, `${specCase.id}: official CSS`)
      assert.equal(adapter.css, direct.css, `${specCase.id}: canonical CSS`)
      assert.deepEqual(adapter.dependencies, specCase.dependencies, `${specCase.id}: dependencies`)
      const expectedDirectDependencies = exactForwardOracleImportDrift.get(specCase.id)
        ?? specCase.dependencies
      assert.deepEqual(
        sorted(direct.dependencies),
        sorted(expectedDirectDependencies),
        `${specCase.id}: exact Less 4.9.0 provider dependency set`,
      )
      if (exactForwardOracleImportDrift.has(specCase.id)) {
        observedForwardImportDrift.add(specCase.id)
      }
      assert.equal(new Set(direct.dependencies).size, direct.dependencies.length)
      for (const dependency of direct.dependencies) {
        assert.equal(
          adapter.dependencies.includes(dependency),
          true,
          `${specCase.id}: canonical dependency subset`,
        )
      }
      assert.equal(
        adapter.dependencyKinds.every(kind => kind === 'import'),
        true,
        `${specCase.id}: dependency kinds`,
      )
    } else {
      assert.equal(direct.formatted, specCase.expectation, `${specCase.id}: official error`)
      assert.equal(adapter.code, 'LESS_COMPILE_ERROR', `${specCase.id}: adapter failure code`)
      assert.equal(adapter.message, 'Less rejected the input', `${specCase.id}: adapter failure`)
      assert.equal(adapter.diagnostics.at(-1).severity, 'error', `${specCase.id}: terminal error`)
    }
    baseline.set(specCase.id, adapter)
  }
  assert.deepEqual(observedForwardImportDrift, new Set(exactForwardOracleImportDrift.keys()))

  const parallel = await boundedParallel(cases, 8, compileAdapter)
  for (let index = 0; index < cases.length; index += 1) {
    assert.deepEqual(parallel[index], baseline.get(cases[index].id), `${cases[index].id}: parallel`)
  }
})

test('reparses every official Less success through stable ZigCSS and an independent CSS parser', {
  timeout: 120_000,
}, async () => {
  const stat = fs.lstatSync(compiler)
  assert.equal(stat.isFile(), true)
  assert.equal(stat.isSymbolicLink(), false)
  const cases = manifest.cases.filter(item => item.outcome === 'success').map(caseData)
  for (const specCase of cases) {
    const result = await compileAdapter(specCase)
    assert.equal(result.outcome, 'success', specCase.id)
    assert.doesNotThrow(() => transform({
      filename: `${specCase.id}.css`,
      code: Buffer.from(result.css),
      minify: false,
      errorRecovery: false,
      drafts: { nesting: true },
    }), `${specCase.id}: independent provider-CSS parse`)
    const first = runZigCss(result.css, specCase.id, 'first parse')
    const second = runZigCss(first, specCase.id, 'second parse')
    assert.equal(second, first, `${specCase.id}: ZigCSS parser/emitter stability`)
    assert.doesNotThrow(() => transform({
      filename: `${specCase.id}-zigcss.css`,
      code: Buffer.from(first),
      minify: false,
      errorRecovery: false,
      drafts: { nesting: true },
    }), `${specCase.id}: independent ZigCSS-output parse`)
  }
})
