import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  DART_SASS_VERSION,
  createDartSassProvider,
} from '../../../preprocessor/providers/dart-sass.mjs'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'
import { createProductionRegistry } from '../../../preprocessor/provider-registry.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const fixtureDirectory = path.join(repositoryRoot, 'tests/preprocessors/sass/fixtures')
const entryUrl = pathToFileURL(path.join(fixtureDirectory, 'input.scss')).href

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

function request(overrides = {}) {
  return makeRequest({
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(overrides = {}, signal = new AbortController().signal) {
  return await createDartSassProvider().compile(request(overrides), { signal })
}

test('binds the internal adapter and lockfile to exact Dart Sass 1.101.0 with no public admission', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const installed = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'node_modules/sass/package.json'), 'utf8'),
  )
  const matrix = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'tests/formats/matrix.json'), 'utf8'),
  )
  const provider = createProductionRegistry().get('dart-sass')
  const adapterSource = fs.readFileSync(
    path.join(repositoryRoot, 'preprocessor/providers/dart-sass.mjs'),
    'utf8',
  )

  assert.equal(DART_SASS_VERSION, '1.101.0')
  assert.equal(manifest.devDependencies.sass, DART_SASS_VERSION)
  assert.equal(manifest.dependencies?.sass, undefined)
  assert.equal(manifest.files.includes('preprocessor'), false)
  assert.equal(lock.packages[''].devDependencies.sass, DART_SASS_VERSION)
  assert.equal(lock.packages['node_modules/sass'].version, DART_SASS_VERSION)
  assert.equal(installed.version, DART_SASS_VERSION)
  assert.equal(installed.license, 'MIT')
  assert.deepEqual(installed.engines, { node: '>=20.19.0' })
  assert.equal(matrix.canonicalProviders['dart-sass'].version, DART_SASS_VERSION)
  assert.deepEqual(provider.syntaxes, ['scss', 'sass'])
  assert.equal(typeof provider.compile, 'function')
  assert.match(adapterSource, /sass\.compileStringAsync\(/)
  assert.doesNotMatch(adapterSource, /sass\.(?:render|renderSync)\(/)
  for (const adapterId of ['scss', 'sass']) {
    const adapter = matrix.adapters.find(candidate => candidate.id === adapterId)
    assert.equal(adapter.availability, 'Unavailable')
    assert.equal(adapter.compatibility, 'Unverified')
  }
})

test('locks and license-reviews the complete Dart Sass dependency closure', () => {
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const pending = ['sass']
  const seen = new Set()
  while (pending.length !== 0) {
    const name = pending.shift()
    if (seen.has(name)) continue
    const entry = lock.packages[`node_modules/${name}`]
    assert.notEqual(entry, undefined, name)
    seen.add(name)
    pending.push(...Object.keys({
      ...(entry.dependencies ?? {}),
      ...(entry.optionalDependencies ?? {}),
    }))
  }

  assert.deepEqual([...seen].sort().map(name => {
    const entry = lock.packages[`node_modules/${name}`]
    return `${name}@${entry.version} ${entry.license}`
  }), [
    '@parcel/watcher@2.5.6 MIT',
    '@parcel/watcher-android-arm64@2.5.6 MIT',
    '@parcel/watcher-darwin-arm64@2.5.6 MIT',
    '@parcel/watcher-darwin-x64@2.5.6 MIT',
    '@parcel/watcher-freebsd-x64@2.5.6 MIT',
    '@parcel/watcher-linux-arm-glibc@2.5.6 MIT',
    '@parcel/watcher-linux-arm-musl@2.5.6 MIT',
    '@parcel/watcher-linux-arm64-glibc@2.5.6 MIT',
    '@parcel/watcher-linux-arm64-musl@2.5.6 MIT',
    '@parcel/watcher-linux-x64-glibc@2.5.6 MIT',
    '@parcel/watcher-linux-x64-musl@2.5.6 MIT',
    '@parcel/watcher-win32-arm64@2.5.6 MIT',
    '@parcel/watcher-win32-ia32@2.5.6 MIT',
    '@parcel/watcher-win32-x64@2.5.6 MIT',
    'chokidar@5.0.0 MIT',
    'detect-libc@2.1.2 Apache-2.0',
    'immutable@5.1.9 MIT',
    'is-extglob@2.1.1 MIT',
    'is-glob@4.0.3 MIT',
    'node-addon-api@7.1.1 MIT',
    'picomatch@4.0.5 MIT',
    'readdirp@5.0.0 MIT',
    'sass@1.101.0 MIT',
    'source-map-js@1.2.1 BSD-3-Clause',
  ])
})

test('compiles SCSS through the modern API in exact expanded and compressed styles', async () => {
  const source = '$color: red;\n.card { color: $color; }\n'
  const expanded = await compile({ source })
  const compressed = await compile({
    source,
    options: { style: 'compressed', sourceMap: false, loadPaths: [] },
  })

  assert.deepEqual(expanded, {
    css: '.card {\n  color: red;\n}',
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
  assert.deepEqual(compressed, {
    css: '.card{color:red}',
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
  assert.deepEqual(await compile({ source }), expanded)
})

test('maps the protocol sass syntax to Dart Sass indented syntax without rewriting bytes', async () => {
  const source = '$color: red\n.card\n  color: $color\n'
  assert.deepEqual(await compile({
    syntax: 'sass',
    source,
    sourceUrl: 'file:///workspace/input.sass',
  }), {
    css: '.card {\n  color: red;\n}',
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
})

test('owns deterministic provider Source Map v3 bytes and rewrites only the virtual entry identity', async () => {
  const source = '$color: red;\n.card { color: $color; }\n'
  const result = await compile({
    source,
    options: { style: 'expanded', sourceMap: true, loadPaths: [] },
  })
  const repeated = await compile({
    source,
    options: { style: 'expanded', sourceMap: true, loadPaths: [] },
  })

  assert.equal(result.sourceMap, repeated.sourceMap)
  assert.deepEqual(JSON.parse(result.sourceMap), {
    version: 3,
    sourceRoot: '',
    sources: ['file:///workspace/input.scss'],
    sourcesContent: [source],
    names: [],
    mappings: 'AACA;EAAQ,OADA',
  })
  assert.equal(parseSourceMap(result.sourceMap).version, 3)
  assert.deepEqual(result.dependencies, [])
})

test('allows built-in Sass modules but fails closed before any filesystem import or load path', async () => {
  const builtIn = await compile({
    source: '@use "sass:math";\n.card { width: math.div(2, 2) * 1px; }',
    sourceUrl: entryUrl,
  })
  assert.equal(builtIn.css, '.card {\n  width: 1px;\n}')
  assert.deepEqual(builtIn.dependencies, [])

  for (const overrides of [
    {
      source: '@use "tokens";\n.card { color: tokens.$accent; }',
      sourceUrl: entryUrl,
    },
    {
      source: '@use "file:///etc/passwd";',
      sourceUrl: entryUrl,
    },
    {
      source: '@use "sass:meta";\n.card { @include meta.load-css("tokens"); }',
      sourceUrl: entryUrl,
    },
    {
      options: { style: 'expanded', sourceMap: false, loadPaths: [fixtureDirectory] },
    },
  ]) {
    await assert.rejects(compile(overrides), rejectsWithCode('SASS_IMPORTS_UNAVAILABLE'))
  }
})

test('normalizes warnings and parse failures without returning partial CSS', async () => {
  const warning = await compile({ source: '.card { color: darken(red, 10%); }' })
  assert.equal(warning.diagnostics.length, 2)
  assert.deepEqual(
    warning.diagnostics.map(diagnostic => ({
      severity: diagnostic.severity,
      code: diagnostic.code,
      sourceUrl: diagnostic.sourceUrl,
      line: diagnostic.line,
      column: diagnostic.column,
    })),
    [
      {
        severity: 'warning',
        code: 'sass.deprecation.global-builtin',
        sourceUrl: 'file:///workspace/input.scss',
        line: 1,
        column: 16,
      },
      {
        severity: 'warning',
        code: 'sass.deprecation.color-functions',
        sourceUrl: 'file:///workspace/input.scss',
        line: 1,
        column: 16,
      },
    ],
  )

  await assert.rejects(
    compile({ source: '$color: ;\n.card { color: $color; }' }),
    error => {
      assert.equal(error.code, 'SASS_COMPILE_ERROR')
      assert.equal(error.message, 'Dart Sass rejected the input')
      assert.deepEqual(error.diagnostics, [{
        severity: 'error',
        code: 'sass.compile',
        message: 'Expected expression.',
        sourceUrl: 'file:///workspace/input.scss',
        line: 1,
        column: 9,
      }])
      assert.equal('css' in error, false)
      return true
    },
  )

  await assert.rejects(
    compile({ source: '@error "ZIGCSS_SASS_IMPORTS_UNAVAILABLE";' }),
    rejectsWithCode('SASS_COMPILE_ERROR'),
  )
})

test('rejects cancellation before canonical evaluation begins', async () => {
  const controller = new AbortController()
  controller.abort()
  await assert.rejects(
    compile({}, controller.signal),
    rejectsWithCode('SASS_CANCELLED'),
  )

  const during = new AbortController()
  const pending = compile({}, during.signal)
  during.abort()
  await assert.rejects(pending, rejectsWithCode('SASS_CANCELLED'))
})

test('keeps mixed SCSS and indented Sass compilation deterministic in parallel', async () => {
  const jobs = Array.from({ length: 12 }, (_, index) => (
    index % 2 === 0
      ? compile({ source: `$value: ${index}; .item-${index} { z-index: $value; }` })
      : compile({
          syntax: 'sass',
          sourceUrl: 'file:///workspace/input.sass',
          source: `$value: ${index}\n.item-${index}\n  z-index: $value\n`,
        })
  ))
  const results = await Promise.all(jobs)
  for (let index = 0; index < results.length; index += 1) {
    assert.equal(results[index].css, `.item-${index} {\n  z-index: ${index};\n}`)
    assert.deepEqual(results[index].diagnostics, [])
    assert.deepEqual(results[index].dependencies, [])
  }
})

test('documents the virtual import boundary and preserves unavailable public rows', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'modern asynchronous `compileStringAsync` API',
    'stable non-file virtual URL',
    'Built-in `sass:` modules remain available',
    'This work does not make any preprocessor syntax available publicly',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
