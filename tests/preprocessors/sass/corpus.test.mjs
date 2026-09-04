import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import * as sass from 'sass'
import {
  DART_SASS_VERSION,
  createDartSassProvider,
} from '../../../preprocessor/providers/dart-sass.mjs'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import { makeRequest } from '../protocol/helpers.mjs'
import { readStableRegularFile } from '../../../scripts/bounded-filesystem.mjs'

const require = createRequire(import.meta.url)
const { transform } = require('lightningcss')
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/sass/corpus')
const casesRoot = path.join(corpusRoot, 'cases')
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
const provider = createDartSassProvider()

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
      assert.equal(entry.isSymbolicLink(), false, `${relative}/${entry.name}`)
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = path.join(directory, entry.name)
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
  const directory = path.join(casesRoot, specCase.id)
  const entry = path.join(directory, ...specCase.entry.split('/'))
  const expected = path.join(directory, ...specCase.expected.split('/'))
  return {
    ...specCase,
    directory,
    entry,
    entryUrl: pathToFileURL(entry).href,
    source: utf8.decode(fs.readFileSync(entry)),
    expectation: utf8.decode(fs.readFileSync(expected)),
  }
}

function normalizeSpecOutput(value) {
  return value.replace(/(\r?\n)+/g, '\n')
}

function relativeUrl(value, specCase) {
  if (value === null || value === undefined) return specCase.entry
  const parsed = value instanceof URL ? value : new URL(value)
  assert.equal(parsed.protocol, 'file:', `${specCase.id}: non-file diagnostic or dependency URL`)
  const filename = fileURLToPath(parsed)
  const relative = path.relative(specCase.directory, filename)
  assert.equal(
    relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative),
    false,
    `${specCase.id}: URL escapes its case directory`,
  )
  return relative.split(path.sep).join('/')
}

function location(span) {
  const line = Number.isSafeInteger(span?.start?.line) ? span.start.line + 1 : null
  const column = line !== null && Number.isSafeInteger(span?.start?.column)
    ? span.start.column + 1
    : null
  return { line, column }
}

function directWarning(message, options, specCase) {
  const position = location(options?.span)
  const id = options?.deprecationType?.id
  const code = options?.deprecation === true
    ? (typeof id === 'string' ? `sass.deprecation.${id}` : 'sass.deprecation')
    : 'sass.warning'
  return {
    severity: 'warning',
    code,
    message,
    source: relativeUrl(options?.span?.url, specCase),
    line: position.line,
    column: position.column,
  }
}

function adapterDiagnostics(diagnostics, specCase) {
  return diagnostics.map(diagnostic => ({
    severity: diagnostic.severity,
    code: diagnostic.code,
    message: diagnostic.message,
    source: relativeUrl(diagnostic.sourceUrl, specCase),
    line: diagnostic.line,
    column: diagnostic.column,
  }))
}

function directDependencies(loadedUrls, specCase) {
  return loadedUrls
    .filter(url => url.protocol === 'file:' && url.href !== specCase.entryUrl)
    .map(url => relativeUrl(url, specCase))
}

async function compileDirect(specCase) {
  const diagnostics = []
  const options = {
    alertColor: false,
    charset: true,
    loadPaths: [specCase.directory],
    logger: {
      warn(message, warningOptions) {
        diagnostics.push(directWarning(message, warningOptions, specCase))
      },
      debug() {},
    },
    quietDeps: false,
    style: 'expanded',
    syntax: specCase.syntax === 'sass' ? 'indented' : 'scss',
    url: new URL(specCase.entryUrl),
    verbose: false,
  }
  try {
    const result = await sass.compileStringAsync(specCase.source, options)
    return {
      outcome: 'success',
      css: result.css,
      diagnostics,
      dependencies: directDependencies(result.loadedUrls, specCase),
    }
  } catch (error) {
    assert.equal(typeof error?.sassMessage, 'string', `${specCase.id}: canonical error shape`)
    const position = location(error.span)
    diagnostics.push({
      severity: 'error',
      code: 'sass.compile',
      message: error.sassMessage,
      source: relativeUrl(error.span?.url, specCase),
      line: position.line,
      column: position.column,
    })
    return {
      outcome: 'error',
      diagnostics,
      message: error.sassMessage,
    }
  }
}

async function compileAdapter(specCase) {
  const request = makeRequest({
    syntax: specCase.syntax,
    source: specCase.source,
    sourceUrl: specCase.entryUrl,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [specCase.directory],
      providerOptions: { charset: true, quietDeps: false, verbose: false },
    },
  })
  try {
    const result = await provider.compile(request, { signal: new AbortController().signal })
    return {
      outcome: 'success',
      css: result.css,
      diagnostics: adapterDiagnostics(result.diagnostics, specCase),
      dependencies: result.dependencies.map(dependency => relativeUrl(dependency.url, specCase)),
      dependencyKinds: result.dependencies.map(dependency => dependency.kind),
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

test('pins, license-reviews, and checksum-verifies the official Sass-spec corpus', () => {
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.caseCount, 80)
  assert.deepEqual(manifest.upstream, selection.upstream)
  assert.deepEqual(manifest.upstream, {
    repository: 'https://github.com/sass/sass-spec',
    revision: '1b03109a6205c8cff146defeae8488094b147c88',
    tree: '2e2c5127e220ccc6fc1cbeef7b74f79fbadcb32c',
    archiveSha256: 'a7918374582d19cb4e403411a888c91499a7286f021b6f91278219f471b76790',
    packageVersion: '3.5.4',
    packageSha256: '5253c05b5c2e838bea12d1ab72f354e19b56b270a3c01daacfe0a800df85fe21',
    license: 'MIT',
    licenseSha256: 'd51e586775405c2734ca4c0b39cd70c5184a9011f880339a15f84690f479a106',
    dartSassVersion: DART_SASS_VERSION,
    dartSassTagCommit: '63b9922f5ddbf34bc742b50949e0ee5c47f4686d',
  })
  const license = fs.readFileSync(path.join(corpusRoot, manifest.licenseFile.path))
  assert.equal(sha256(license), manifest.licenseFile.sha256)
  assert.match(license.toString('utf8'), /The MIT License \(MIT\)/)
  assert.match(license.toString('utf8'), /Copyright \(c\) 2007-2014 The Sass Authors/)

  const groups = {
    'scss-success': 0,
    'sass-success': 0,
    'scss-error': 0,
    'sass-error': 0,
  }
  const features = new Set()
  const expectedInventory = []
  assert.deepEqual(manifest.cases.map(specCase => specCase.id), selection.cases.map(specCase => specCase.id))
  for (const specCase of manifest.cases) {
    const group = `${specCase.syntax}-${specCase.outcome}`
    switch (group) {
      case 'scss-success':
        groups['scss-success'] += 1
        break
      case 'sass-success':
        groups['sass-success'] += 1
        break
      case 'scss-error':
        groups['scss-error'] += 1
        break
      case 'sass-error':
        groups['sass-error'] += 1
        break
      default: assert.fail(`unknown Sass corpus group ${JSON.stringify(group)}`)
    }
    features.add(specCase.feature)
    const names = new Set()
    for (const file of specCase.files) {
      assert.equal(names.has(file.path), false, `${specCase.id}: duplicate file ${file.path}`)
      names.add(file.path)
      const filename = path.join(casesRoot, specCase.id, ...file.path.split('/'))
      const bytes = readStableRegularFile(filename, {
        allowEmpty: true,
        label: `${specCase.id}: ${file.path}`,
        maximumBytes: Math.max(file.bytes, 1),
        reject: assert.fail,
      })
      assert.equal(bytes.length, file.bytes, `${specCase.id}: ${file.path} size`)
      assert.equal(sha256(bytes), file.sha256, `${specCase.id}: ${file.path} checksum`)
      expectedInventory.push(`${specCase.id}/${file.path}`)
    }
    assert.equal(names.has(specCase.entry), true, `${specCase.id}: entry inventory`)
    assert.equal(names.has(specCase.expected), true, `${specCase.id}: expectation inventory`)
    if (specCase.warning !== null) assert.equal(names.has(specCase.warning), true)
  }
  assert.deepEqual(groups, {
    'scss-success': 41,
    'sass-success': 19,
    'scss-error': 13,
    'sass-error': 7,
  })
  for (const feature of [
    'variables',
    'operators',
    'control-flow',
    'functions',
    'mixins',
    'extend',
    'modules',
    'legacy-imports',
    'calculations',
    'colors',
    'custom-properties',
    'keyframes',
    'selectors',
  ]) {
    assert.equal(features.has(feature), true, feature)
  }
  assert.deepEqual(listFiles(casesRoot), sorted(expectedInventory))
})

test('matches exact Dart Sass across all 80 success and negative corpus cases', {
  timeout: 120_000,
}, async () => {
  const cases = manifest.cases.map(caseData)
  const baseline = new Map()

  for (const specCase of cases) {
    const direct = await compileDirect(specCase)
    const adapter = await compileAdapter(specCase)
    assert.equal(direct.outcome, specCase.outcome, `${specCase.id}: upstream outcome`)
    assert.equal(adapter.outcome, direct.outcome, `${specCase.id}: adapter outcome`)
    assert.deepEqual(adapter.diagnostics, direct.diagnostics, `${specCase.id}: diagnostics`)

    if (specCase.outcome === 'success') {
      const canonicalCliCss = direct.css === '' ? '' : `${direct.css}\n`
      assert.equal(
        normalizeSpecOutput(canonicalCliCss),
        normalizeSpecOutput(specCase.expectation),
        `${specCase.id}: Sass-spec CSS`,
      )
      assert.equal(adapter.css, direct.css, `${specCase.id}: canonical CSS`)
      assert.deepEqual(adapter.dependencies, direct.dependencies, `${specCase.id}: dependencies`)
      const expectedKind = specCase.feature === 'legacy-imports' ? 'import' : 'reference'
      assert.equal(
        adapter.dependencyKinds.every(kind => kind === expectedKind),
        true,
        `${specCase.id}: dependency kinds`,
      )
      if (specCase.warning === null) {
        assert.deepEqual(adapter.diagnostics, [], `${specCase.id}: unexpected warning`)
      } else {
        const warning = fs.readFileSync(path.join(specCase.directory, specCase.warning), 'utf8')
        for (const diagnostic of adapter.diagnostics) {
          assert.equal(warning.includes(diagnostic.message.split('\n')[0]), true, specCase.id)
        }
      }
    } else {
      assert.equal(adapter.code, 'SASS_COMPILE_ERROR', `${specCase.id}: failure code`)
      assert.equal(adapter.message, 'Dart Sass rejected the input', `${specCase.id}: failure message`)
      assert.equal(adapter.diagnostics.at(-1).severity, 'error', `${specCase.id}: terminal error`)
      const headline = `Error: ${direct.message.split('\n')[0]}`
      assert.equal(specCase.expectation.includes(headline), true, `${specCase.id}: Sass-spec error`)
    }
    baseline.set(specCase.id, adapter)
  }

  const parallel = await boundedParallel(cases, 8, compileAdapter)
  for (let index = 0; index < cases.length; index += 1) {
    assert.deepEqual(parallel[index], baseline.get(cases[index].id), `${cases[index].id}: parallel`)
  }
})

test('reparses every canonical success through stable ZigCSS and an independent CSS parser', {
  timeout: 120_000,
}, async () => {
  const stat = fs.lstatSync(compiler)
  assert.equal(stat.isFile(), true)
  assert.equal(stat.isSymbolicLink(), false)
  for (const specCase of manifest.cases.filter(candidate => candidate.outcome === 'success').map(caseData)) {
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

test('fails closed when canonical Sass exceeds the normalized diagnostic ceiling', async () => {
  const source = [
    '@for $index from 1 through 1001 {',
    '  @warn "bounded warning #{$index}";',
    '}',
  ].join('\n')
  const request = makeRequest({
    source,
    sourceUrl: null,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: { charset: true, quietDeps: false, verbose: false },
    },
  })
  await assert.rejects(
    provider.compile(request, { signal: new AbortController().signal }),
    error => {
      assert.equal(error instanceof ProviderFailure, true)
      assert.equal(error.code, 'SASS_DIAGNOSTIC_LIMIT')
      assert.equal(error.diagnostics.length, 0)
      assert.equal('css' in error, false)
      return true
    },
  )
})
