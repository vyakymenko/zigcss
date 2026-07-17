import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import stylus from 'stylus'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import {
  STYLUS_VERSION,
  createStylusProvider,
} from '../../../preprocessor/providers/stylus.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/stylus/corpus')
const filesRoot = path.join(corpusRoot, 'files')
const casesRoot = path.join(filesRoot, 'upstream/cases')
const imagesRoot = path.join(filesRoot, 'upstream/images')
const importBasicRoot = path.join(casesRoot, 'import.basic')
const manifest = JSON.parse(fs.readFileSync(path.join(corpusRoot, 'manifest.json'), 'utf8'))
const selection = JSON.parse(fs.readFileSync(path.join(corpusRoot, 'selection.json'), 'utf8'))
const compiler = path.join(
  repositoryRoot,
  'zig-out/bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const utf8 = new TextDecoder('utf-8', { fatal: true })
const provider = createStylusProvider()

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function trackedCorpusFiles() {
  const prefix = 'tests/preprocessors/stylus/corpus/files/'
  const result = spawnSync('git', [
    'ls-files',
    '-z',
    '--',
    'tests/preprocessors/stylus/corpus/files',
  ], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
    windowsHide: true,
  })
  assert.equal(result.error, undefined, 'tracked corpus inventory: git launch')
  assert.equal(result.signal, null, 'tracked corpus inventory: git signal')
  assert.equal(result.status, 0, `tracked corpus inventory: ${result.stderr}`)
  return sorted(result.stdout.split('\0').filter(Boolean).map(filename => {
    assert.equal(filename.startsWith(prefix), true, filename)
    return filename.slice(prefix.length)
  }))
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

function relativeFile(filename, specCase) {
  const canonical = fs.realpathSync(filename)
  const relative = path.relative(fs.realpathSync(filesRoot), canonical)
  assert.equal(
    relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative),
    false,
    `${specCase.id}: dependency escapes the corpus root`,
  )
  return relative.split(path.sep).join('/')
}

function caseData(item) {
  const entry = path.join(filesRoot, ...item.entry.split('/'))
  const entryBytes = fs.readFileSync(entry)
  const rawSource = utf8.decode(entryBytes)
  const source = item.source === 'official'
    ? rawSource.replaceAll('\r', '').trim()
    : rawSource
  return {
    ...item,
    entry,
    entryRelative: item.entry,
    entryUrl: pathToFileURL(entry).href,
    source,
    expectation: item.outcome === 'success'
      ? utf8.decode(fs.readFileSync(path.join(filesRoot, ...item.expected.split('/'))))
        .replaceAll('\r', '')
        .trim()
      : item.expected,
  }
}

function directErrorMetadata(error, specCase) {
  const formatted = String(error?.message ?? '').replaceAll('\r\n', '\n')
  const header = /^(.*):([0-9]+):([0-9]+)\n/.exec(formatted)
  assert.notEqual(header, null, `${specCase.id}: canonical error location`)
  assert.equal(
    relativeFile(header[1], specCase),
    specCase.entryRelative,
    `${specCase.id}: error source`,
  )
  const separator = formatted.indexOf('\n\n')
  assert.notEqual(separator, -1, `${specCase.id}: canonical formatted error`)
  let message = formatted.slice(separator + 2)
  const stack = typeof error.stylusStack === 'string' && error.stylusStack.length !== 0
    ? `${error.stylusStack}\n`
    : ''
  if (stack.length !== 0 && message.endsWith(stack)) message = message.slice(0, -stack.length)
  message = message.replace(/\n$/, '')
  return {
    message,
    line: Number(header[2]),
    column: Number(header[3]),
  }
}

async function compileDirect(specCase) {
  const renderer = stylus(specCase.source, {
    cache: false,
    filename: specCase.entry,
  })
    .include(imagesRoot)
    .include(importBasicRoot)
    .set('compress', specCase.style === 'compressed')
    .set('include css', specCase.providerOptions.includeCss)
    .set('hoist atrules', specCase.providerOptions.hoistAtrules)
  let css
  try {
    css = await new Promise((resolve, reject) => {
      renderer.render((error, output) => {
        if (error) reject(error)
        else resolve(output)
      })
    })
  } catch (error) {
    return { outcome: 'error', expected: directErrorMetadata(error, specCase) }
  }
  let dependencies = null
  if (/@(?:import|require)\b/.test(specCase.source)) {
    try {
      dependencies = renderer.deps().map(filename => relativeFile(filename, specCase))
    } catch {
      // The official integration harness does not require its separate dependency
      // visitor to accept every renderable AST. Compare it whenever it succeeds.
    }
  }
  return { outcome: 'success', css, dependencies }
}

function adapterDiagnostics(values, specCase) {
  return values.map(item => ({
    severity: item.severity,
    code: item.code,
    message: item.message,
    source: item.sourceUrl === null ? null : relativeFile(fileURLToPath(item.sourceUrl), specCase),
    line: item.line,
    column: item.column,
  }))
}

async function compileAdapter(specCase) {
  const request = makeRequest({
    provider: 'stylus',
    syntax: 'stylus',
    source: specCase.source,
    sourceUrl: specCase.entryUrl,
    options: {
      style: specCase.style,
      sourceMap: false,
      loadPaths: [casesRoot, imagesRoot, importBasicRoot],
      providerOptions: specCase.providerOptions,
    },
  })
  try {
    const result = await provider.compile(request, { signal: new AbortController().signal })
    return {
      outcome: 'success',
      css: result.css,
      diagnostics: adapterDiagnostics(result.diagnostics, specCase),
      dependencies: result.dependencies.map(item => ({
        path: relativeFile(fileURLToPath(item.url), specCase),
        kind: item.kind,
      })),
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

function assertSubsequence(expected, actual, label) {
  let cursor = 0
  for (const value of actual) {
    if (value === expected[cursor]) cursor += 1
  }
  assert.equal(cursor, expected.length, label)
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
  assert.match(result.stderr, /experimental release candidate/, `${id}: ZigCSS safety notice`)
  return result.stdout
}

test('pins, license-reviews, and checksum-verifies the Stylus 0.64.0 corpus', () => {
  assert.equal(STYLUS_VERSION, '0.64.0')
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.officialCandidateCount, 355)
  assert.equal(manifest.excludedCount, 29)
  assert.equal(manifest.officialSuccessCount, 326)
  assert.equal(manifest.integrationErrorCount, 20)
  assert.equal(manifest.caseCount, 346)
  assert.equal(manifest.files.length, 816)
  assert.deepEqual(manifest.upstream, selection.upstream)
  assert.deepEqual(manifest.exclusions, selection.exclusions)
  assert.deepEqual(manifest.upstream, {
    repository: 'https://github.com/stylus/stylus',
    tag: '0.64.0',
    revision: '1086c6c1fbd7a7fd0ce9ad94f6cf4a62fc79a6e9',
    tree: '295654c66ed48ff47a4aeca95b1935edf7a612ba',
    archiveSha256: '140a722893f0f05b501a01ce1ff27042b6d7c0769ad746f4b5d04429ec8d429e',
    packageSha256: '9eb16d271c690abd29fc62c3e96896b1f7a3b54e77cc36f04e8c0d04a73c06c6',
    testRunSha256: '8ca21b113ede44c0f74353e292d3a3f88b8026b15696b595a1fd2d5daae82ae4',
    packageVersion: STYLUS_VERSION,
    license: 'MIT',
    licenseSha256: 'a5889179818e8e7252246f50df3f9754691affe1a5e3848d032e0bc1da5c7020',
  })

  const installedPackage = fs.readFileSync(path.join(repositoryRoot, 'node_modules/stylus/package.json'))
  assert.equal(sha256(installedPackage), manifest.upstream.packageSha256)
  const license = fs.readFileSync(path.join(corpusRoot, manifest.licenseFile.path))
  assert.equal(sha256(license), manifest.licenseFile.sha256)
  assert.match(license.toString('utf8'), /Copyright \(c\) Automattic/)
  assert.match(license.toString('utf8'), /Permission is hereby granted, free of charge/)

  const expectedInventory = []
  const inventory = new Set()
  for (const file of manifest.files) {
    assert.equal(inventory.has(file.path), false, `duplicate corpus file ${file.path}`)
    inventory.add(file.path)
    assert.doesNotMatch(file.path, /(?:^|\/)\.\.(?:\/|$)|\\|[\u0000\r\n]/)
    assert.doesNotMatch(file.path, /\.(?:c?js|mjs)$/i)
    if (file.path.startsWith('upstream/')) assert.match(file.source, /^test\/(?:cases|images)\//)
    else assert.match(file.source, /^selection\.json#negativeCases\//)
    const filename = path.join(filesRoot, ...file.path.split('/'))
    const stat = fs.lstatSync(filename)
    assert.equal(stat.isFile(), true, file.path)
    assert.equal(stat.isSymbolicLink(), false, file.path)
    const bytes = fs.readFileSync(filename)
    assert.equal(bytes.length, file.bytes, `${file.path}: size`)
    assert.equal(sha256(bytes), file.sha256, `${file.path}: checksum`)
    expectedInventory.push(file.path)
  }
  assert.deepEqual(listFiles(filesRoot), sorted(expectedInventory))
  assert.deepEqual(trackedCorpusFiles(), sorted(expectedInventory))

  const caseIds = new Set()
  const upstreamNames = new Set()
  const features = new Set()
  for (const specCase of manifest.cases) {
    assert.equal(caseIds.has(specCase.id), false, specCase.id)
    caseIds.add(specCase.id)
    features.add(specCase.feature)
    assert.equal(inventory.has(specCase.entry), true, `${specCase.id}: entry inventory`)
    if (specCase.outcome === 'success') {
      assert.equal(specCase.source, 'official')
      assert.equal(inventory.has(specCase.expected), true, `${specCase.id}: expectation inventory`)
      upstreamNames.add(specCase.upstreamName)
    } else {
      assert.equal(specCase.source, 'integration')
      assert.equal(specCase.upstreamName, null)
      assert.deepEqual(specCase.expected, selection.negativeCases.find(
        item => specCase.id === `stylus-integration-${item.id}`,
      )?.expected)
    }
  }
  assert.equal(manifest.exclusions.some(item => upstreamNames.has(item.name)), false)
  const exclusionCounts = {}
  for (const item of manifest.exclusions) {
    exclusionCounts[item.category] = (exclusionCounts[item.category] ?? 0) + 1
  }
  assert.deepEqual(exclusionCounts, {
    'executable-extension': 5,
    'unsupported-option': 5,
    'generated-css-invalid': 19,
  })
  for (const feature of [
    'arithmetic',
    'at-rules',
    'built-ins',
    'control',
    'extend',
    'functions',
    'imports',
    'keyframes',
    'media',
    'mixins',
    'object',
    'operators',
    'regression',
    'selectors',
    'negative-parser',
    'negative-evaluator',
    'negative-import',
  ]) {
    assert.equal(features.has(feature), true, feature)
  }
})

test('matches exact Stylus across all 326 official successes and 20 integration errors', {
  timeout: 120_000,
}, async () => {
  const cases = manifest.cases.map(caseData)
  const baseline = new Map()
  let canonicalDependencyCases = 0
  for (const specCase of cases) {
    const direct = await compileDirect(specCase)
    const adapter = await compileAdapter(specCase)
    assert.equal(direct.outcome, specCase.outcome, `${specCase.id}: canonical outcome`)
    assert.equal(adapter.outcome, direct.outcome, `${specCase.id}: adapter outcome`)
    if (specCase.outcome === 'success') {
      assert.equal(direct.css.trim(), specCase.expectation, `${specCase.id}: official CSS`)
      assert.equal(adapter.css, direct.css, `${specCase.id}: canonical CSS`)
      assert.deepEqual(adapter.diagnostics, [], `${specCase.id}: diagnostics`)
      if (direct.dependencies !== null) {
        canonicalDependencyCases += 1
        const adapterImports = adapter.dependencies
          .filter(item => item.kind === 'import')
          .map(item => item.path)
        assertSubsequence(
          direct.dependencies,
          adapterImports,
          `${specCase.id}: canonical dependency order`,
        )
      }
      assert.equal(
        adapter.dependencies.every(item => inventoryPath(item.path) && ['import', 'reference'].includes(item.kind)),
        true,
        `${specCase.id}: dependency ownership`,
      )
    } else {
      assert.deepEqual(direct.expected, specCase.expectation, `${specCase.id}: canonical error`)
      assert.equal(adapter.code, 'STYLUS_COMPILE_ERROR', `${specCase.id}: adapter failure code`)
      assert.equal(adapter.message, 'Stylus rejected the input', `${specCase.id}: adapter failure`)
      assert.deepEqual(adapter.diagnostics, [{
        severity: 'error',
        code: 'stylus.compile',
        message: specCase.expectation.message,
        source: specCase.entryRelative,
        line: specCase.expectation.line,
        column: specCase.expectation.column,
      }], `${specCase.id}: adapter diagnostic`)
    }
    baseline.set(specCase.id, adapter)
  }
  assert.ok(canonicalDependencyCases >= 15, 'canonical dependency differential coverage')

  const parallel = await boundedParallel(cases, 8, compileAdapter)
  for (let index = 0; index < cases.length; index += 1) {
    assert.deepEqual(parallel[index], baseline.get(cases[index].id), `${cases[index].id}: parallel`)
  }
})

function inventoryPath(value) {
  return manifest.files.some(file => file.path === value)
}

test('reparses every official Stylus success through stable ZigCSS and an independent CSS parser', {
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
