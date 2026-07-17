import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
import stylus from 'stylus'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import { createStylusProvider } from '../../../preprocessor/providers/stylus.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'
import {
  composeSourceMaps,
  parseSourceMap,
} from '../../../preprocessor/source-map.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

function canonicalUrl(filename) {
  return pathToFileURL(fs.realpathSync(filename)).href
}

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-stylus-imports-'))
  const first = path.join(temporary, 'first')
  const second = path.join(temporary, 'second')
  const outside = path.join(temporary, 'outside')
  fs.mkdirSync(first)
  fs.mkdirSync(second)
  fs.mkdirSync(outside)
  try {
    await run({ first, outside, second, temporary })
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function request(root, overrides = {}) {
  return makeRequest({
    provider: 'stylus',
    syntax: 'stylus',
    source: '.entry\n  color red\n',
    sourceUrl: pathToFileURL(path.join(root, 'input.styl')).href,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [root],
      providerOptions: { hoistAtrules: false, includeCss: false },
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(root, overrides = {}, signal = new AbortController().signal) {
  return await createStylusProvider().compile(request(root, overrides), { signal })
}

function renderDirect(source, filename, paths, overrides = {}) {
  const renderer = stylus(source, {
    cache: false,
    filename,
    paths: [...paths],
    ...overrides,
  })
  return new Promise((resolve, reject) => {
    renderer.render((error, css) => {
      if (error) reject(error)
      else resolve({ css, map: renderer.sourcemap ?? null })
    })
  })
}

test('matches canonical entry, load-path, extension, and nested import precedence', async () => {
  await withFixture(async ({ first, second }) => {
    const firstTokens = path.join(first, 'tokens.styl')
    const secondTokens = path.join(second, 'tokens.styl')
    const parent = path.join(first, 'nested', 'parent.styl')
    const child = path.join(first, 'nested', 'child.styl')
    fs.mkdirSync(path.dirname(parent))
    fs.writeFileSync(firstTokens, '$tone = green\n.first-token\n  color $tone\n')
    fs.writeFileSync(secondTokens, '$tone = blue\n.second-token\n  color $tone\n')
    fs.writeFileSync(parent, '@import "child"\n.parent\n  color $child\n')
    fs.writeFileSync(child, '$child = purple\n.child\n  color $child\n')
    const source = [
      '@import "tokens"',
      '@import "nested/parent.styl"',
      '.use',
      '  color $tone',
    ].join('\n')
    const filename = path.join(first, 'input.styl')
    const direct = await renderDirect(source, filename, [second, first])
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [second, first],
        providerOptions: { hoistAtrules: false, includeCss: false },
      },
    })

    assert.equal(result.css, direct.css)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(firstTokens), kind: 'import' },
      { url: canonicalUrl(parent), kind: 'import' },
      { url: canonicalUrl(child), kind: 'import' },
    ])

    const loadPathOnly = await compile(first, {
      source: '@import "tokens"\n.use\n  color $tone\n',
      sourceUrl: null,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [second, first],
        providerOptions: { hoistAtrules: false, includeCss: false },
      },
    })
    assert.match(loadPathOnly.css, /\.first-token/)
    assert.doesNotMatch(loadPathOnly.css, /\.second-token/)
    assert.deepEqual(loadPathOnly.dependencies, [
      { url: canonicalUrl(firstTokens), kind: 'import' },
    ])
  })
})

test('matches canonical sorted globs, directory/package lookup, and require-once semantics', async () => {
  await withFixture(async ({ first }) => {
    const globDirectory = path.join(first, 'glob')
    const globNestedDirectory = path.join(globDirectory, 'nested')
    const indexed = path.join(first, 'indexed', 'index.styl')
    const named = path.join(first, 'named', 'named.styl')
    const packageDirectory = path.join(first, 'node_modules', 'theme')
    const packageJson = path.join(packageDirectory, 'package.json')
    const packageMain = path.join(packageDirectory, 'main.styl')
    const packageFallbackDirectory = path.join(first, 'node_modules', 'fallback.styl')
    const packageFallback = path.join(packageFallbackDirectory, 'index.styl')
    fs.mkdirSync(globNestedDirectory, { recursive: true })
    fs.mkdirSync(path.dirname(indexed))
    fs.mkdirSync(path.dirname(named))
    fs.mkdirSync(packageDirectory, { recursive: true })
    fs.mkdirSync(packageFallbackDirectory, { recursive: true })
    const globA = path.join(globDirectory, 'a.styl')
    const globB = path.join(globDirectory, 'b.styl')
    const globC = path.join(globNestedDirectory, 'c.styl')
    fs.writeFileSync(globB, '.glob-b\n  order 2\n')
    fs.writeFileSync(globA, '.glob-a\n  order 1\n')
    fs.writeFileSync(globC, '.glob-c\n  order 3\n')
    fs.writeFileSync(indexed, '.indexed\n  color orange\n')
    fs.writeFileSync(named, '.named\n  color teal\n')
    fs.writeFileSync(packageJson, '{"main":"main.styl"}\n')
    fs.writeFileSync(packageMain, '.package-main\n  color gold\n')
    fs.writeFileSync(packageFallback, '.package-fallback\n  color coral\n')
    const source = [
      '@import "glob/**/*"',
      '@import "indexed"',
      '@import "indexed"',
      '@require "named"',
      '@require "named"',
      '@import "theme"',
      '@import "fallback"',
    ].join('\n')
    const direct = await renderDirect(source, path.join(first, 'input.styl'), [first])
    const result = await compile(first, { source })

    assert.equal(result.css, direct.css)
    assert.equal((result.css.match(/\.indexed \{/g) ?? []).length, 2)
    assert.equal((result.css.match(/\.named \{/g) ?? []).length, 1)
    assert.ok(result.css.indexOf('.glob-a') < result.css.indexOf('.glob-b'))
    assert.ok(result.css.indexOf('.glob-b') < result.css.indexOf('.glob-c'))
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(globA), kind: 'import' },
      { url: canonicalUrl(globB), kind: 'import' },
      { url: canonicalUrl(globC), kind: 'import' },
      { url: canonicalUrl(indexed), kind: 'import' },
      { url: canonicalUrl(named), kind: 'import' },
      { url: canonicalUrl(packageJson), kind: 'import' },
      { url: canonicalUrl(packageMain), kind: 'import' },
      { url: canonicalUrl(packageFallback), kind: 'import' },
    ])
  })
})

test('preserves literal CSS and URL imports without granting network authority', async () => {
  await withFixture(async ({ first }) => {
    const literal = path.join(first, 'literal.css')
    fs.writeFileSync(literal, '.literal { color: maroon; }\n')
    const source = [
      '@import "literal.css"',
      '@require "literal.css"',
      '@import url("https://example.invalid/theme.css")',
      '@import "//example.invalid/print.css"',
      '@import "#fragment"',
    ].join('\n')
    const direct = await renderDirect(source, path.join(first, 'input.styl'), [first])
    const result = await compile(first, { source })

    assert.equal(result.css, direct.css)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(literal), kind: 'import' },
    ])
    await assert.rejects(
      compile(first, { source: '@require url("https://example.invalid/theme.css")' }),
      rejectsWithCode('STYLUS_COMPILE_ERROR'),
    )
  })
})

test('matches canonical includeCss and hoistAtrules options through a closed boolean surface', async () => {
  await withFixture(async ({ first }) => {
    const literal = path.join(first, 'literal.css')
    fs.writeFileSync(literal, '.literal { color: maroon; }\n')
    const includedSource = '@import "literal.css"\n.entry\n  color red\n'
    const includedDirect = await renderDirect(
      includedSource,
      path.join(first, 'input.styl'),
      [first],
      { 'include css': true },
    )
    const included = await compile(first, {
      source: includedSource,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first],
        providerOptions: { hoistAtrules: false, includeCss: true },
      },
    })
    assert.equal(included.css, includedDirect.css)
    assert.match(included.css, /\.literal \{ color: maroon; \}/)
    assert.deepEqual(included.dependencies, [{ url: canonicalUrl(literal), kind: 'import' }])

    const hoistSource = [
      '.before',
      '  color blue',
      '@import "https://example.invalid/theme.css"',
      '.after',
      '  color green',
    ].join('\n')
    const hoistedDirect = await renderDirect(
      hoistSource,
      path.join(first, 'input.styl'),
      [first],
      { 'hoist atrules': true },
    )
    const hoisted = await compile(first, {
      source: hoistSource,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first],
        providerOptions: { hoistAtrules: true, includeCss: false },
      },
    })
    assert.equal(hoisted.css, hoistedDirect.css)
    assert.equal(hoisted.css.startsWith('@import '), true)
    assert.deepEqual(hoisted.dependencies, [])
  })
})

test('matches canonical JSON, image-size, and embedurl helpers over resolver-owned bytes', async () => {
  await withFixture(async ({ first }) => {
    const components = path.join(first, 'components')
    const component = path.join(components, 'card.styl')
    const variables = path.join(components, 'variables.json')
    const image = path.join(components, 'pixel.png')
    fs.mkdirSync(components)
    fs.writeFileSync(variables, '{"spacing":4,"tone":"rebeccapurple"}\n')
    fs.writeFileSync(image, Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nGQAAAAASUVORK5CYII=',
      'base64',
    ))
    fs.writeFileSync(component, [
      'json("variables.json")',
      '.component',
      '  color tone',
      '  padding spacing * 1px',
      '  width image-size("pixel.png")[0]',
      '  height image-size("missing.png", true)[1]',
      '  background embedurl("pixel.png")',
    ].join('\n'))
    const source = '@import "components/card"\n'
    const direct = await renderDirect(source, path.join(first, 'input.styl'), [first])
    const result = await compile(first, { source })

    assert.equal(result.css, direct.css)
    assert.match(result.css, /color: #639/)
    assert.match(result.css, /padding: 4px/)
    assert.match(result.css, /width: 1px/)
    assert.match(result.css, /height: 0/)
    assert.match(result.css, /data:image\/png;base64,/)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(component), kind: 'import' },
      { url: canonicalUrl(variables), kind: 'reference' },
      { url: canonicalUrl(image), kind: 'reference' },
    ])
  })
})

test('owns imported diagnostics, dependencies, and source-map identities', async () => {
  await withFixture(async ({ first }) => {
    const tokens = path.join(first, 'tokens.styl')
    const component = path.join(first, 'component.styl')
    fs.writeFileSync(tokens, '$tone = rebeccapurple\n')
    fs.writeFileSync(component, '@import "tokens"\n.component\n  color $tone\n')
    const source = '@import "component"\n.entry::before\n  content "🙂"\n'
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: { hoistAtrules: false, includeCss: false },
      },
    })
    const map = parseSourceMap(result.sourceMap)
    assert.deepEqual(new Set(map.sources), new Set([
      pathToFileURL(path.join(first, 'input.styl')).href,
      canonicalUrl(component),
    ]))
    assert.deepEqual(new Set(map.sourcesContent), new Set([source, fs.readFileSync(component, 'utf8')]))
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(component), kind: 'import' },
      { url: canonicalUrl(tokens), kind: 'import' },
    ])

    const intermediateSourceUrl = 'zigcss-intermediate:provider.css'
    const composed = parseSourceMap(composeSourceMaps({
      providerMap: result.sourceMap,
      zigMap: JSON.stringify({
        version: 3,
        sources: [intermediateSourceUrl],
        names: [],
        mappings: result.css.split('\n').map((_, index) => (
          index === 0 ? 'AAAA' : 'AACA'
        )).join(';'),
      }),
      intermediateSourceUrl,
    }))
    assert.deepEqual(composed.sources, map.sources)
    assert.deepEqual(composed.sourcesContent, map.sourcesContent)

    fs.writeFileSync(component, 'warn("nested warning")\n.component\n  color red\n')
    const warned = await compile(first, { source: '@import "component"' })
    assert.deepEqual(warned.diagnostics, [{
      severity: 'warning',
      code: 'stylus.warning',
      message: 'nested warning',
      sourceUrl: canonicalUrl(component),
      line: null,
      column: null,
    }])

    fs.writeFileSync(component, '.component\n  color (\n')
    await assert.rejects(
      compile(first, { source: '@import "component"' }),
      error => {
        assert.equal(error.code, 'STYLUS_COMPILE_ERROR')
        assert.equal(error.diagnostics[0].sourceUrl, canonicalUrl(component))
        assert.equal(error.diagnostics[0].line, 3)
        assert.equal('css' in error, false)
        assert.doesNotMatch(JSON.stringify(error), /__zigcss_stylus__|node_modules\/stylus|stack/i)
        return true
      },
    )
  })
})

test('rejects missing authority, traversal, links, invalid bytes, and package metadata without CSS', async () => {
  await withFixture(async ({ first, outside }) => {
    const outsideFile = path.join(outside, 'escape.styl')
    const linked = path.join(first, 'linked.styl')
    const invalid = path.join(first, 'invalid.styl')
    const packageDirectory = path.join(first, 'node_modules', 'broken')
    fs.writeFileSync(outsideFile, '.escape\n  color red\n')
    fs.symlinkSync(outsideFile, linked)
    fs.writeFileSync(invalid, Buffer.from([0xff, 0xfe, 0xfd]))
    fs.mkdirSync(packageDirectory, { recursive: true })
    fs.writeFileSync(path.join(packageDirectory, 'package.json'), '{not-json}\n')

    await assert.rejects(
      compile(first, {
        source: '@import "missing"',
        options: {
          style: 'expanded',
          sourceMap: false,
          loadPaths: [],
          providerOptions: { hoistAtrules: false, includeCss: false },
        },
      }),
      rejectsWithCode('STYLUS_IMPORT_POLICY'),
    )
    for (const [source, code] of [
      ['@import "../outside/escape"', 'STYLUS_IMPORT_POLICY'],
      ['@import "linked"', 'STYLUS_IMPORT_POLICY'],
      ['@import "invalid"', 'STYLUS_IMPORT_ENCODING'],
      ['@import "broken"', 'STYLUS_IMPORT_PACKAGE'],
      ['@import "missing"', 'STYLUS_IMPORT_MISSING'],
      ['@import "../outside/*"', 'STYLUS_IMPORT_POLICY'],
    ]) {
      await assert.rejects(compile(first, { source }), error => {
        assert.equal(rejectsWithCode(code)(error), true, source)
        assert.equal('css' in error, false)
        assert.doesNotMatch(JSON.stringify(error), /escape\.styl|invalid\.styl|package\.json/)
        return true
      })
    }
  })
})

test('fails cycles, excessive ancestry, and mid-import cancellation deterministically', async () => {
  await withFixture(async ({ first }) => {
    const a = path.join(first, 'a.styl')
    const b = path.join(first, 'b.styl')
    fs.writeFileSync(a, '@import "b"\n.a\n  color red\n')
    fs.writeFileSync(b, '@import "a"\n.b\n  color blue\n')
    await assert.rejects(
      compile(first, { source: '@import "a"' }),
      rejectsWithCode('STYLUS_IMPORT_CYCLE'),
    )

    const depth = 34
    for (let index = 0; index < depth; index += 1) {
      const next = index + 1 < depth ? `@import "level-${index + 1}"\n` : ''
      fs.writeFileSync(path.join(first, `level-${index}.styl`), `${next}.level-${index}\n  order ${index}\n`)
    }
    await assert.rejects(
      compile(first, { source: '@import "level-0"' }),
      rejectsWithCode('STYLUS_IMPORT_DEPTH_LIMIT'),
    )

    let reads = 0
    const signal = {
      get aborted() {
        reads += 1
        return reads >= 2
      },
    }
    await assert.rejects(
      compile(first, { source: '@import "a"' }, signal),
      rejectsWithCode('STYLUS_CANCELLED'),
    )
  })
})

test('enforces stylesheet, asset, JSON-structure, and glob-count limits without partial CSS', {
  timeout: 30_000,
}, async () => {
  await withFixture(async ({ first }) => {
    const oversized = path.join(first, 'oversized.styl')
    const invalidImage = path.join(first, 'invalid.png')
    const deepJson = path.join(first, 'deep.json')
    fs.writeFileSync(oversized, Buffer.alloc((10 * 1024 * 1024) + 1, 0x20))
    fs.writeFileSync(invalidImage, 'not-an-image')
    let nested = 'value'
    for (let depth = 0; depth < 66; depth += 1) nested = { nested }
    fs.writeFileSync(deepJson, JSON.stringify(nested))

    for (const [source, code] of [
      ['@import "oversized"', 'STYLUS_IMPORT_LIMIT'],
      ['.asset\n  width image-size("invalid.png")[0]', 'STYLUS_ASSET_INVALID'],
      ['values = json("deep.json", { hash: true })', 'STYLUS_ASSET_LIMIT'],
    ]) {
      await assert.rejects(compile(first, { source }), error => {
        assert.equal(rejectsWithCode(code)(error), true, source)
        assert.equal('css' in error, false)
        return true
      })
    }

    const many = path.join(first, 'many')
    fs.mkdirSync(many)
    for (let index = 0; index < 4097; index += 1) {
      fs.writeFileSync(path.join(many, `${index.toString().padStart(4, '0')}.styl`), '')
    }
    await assert.rejects(
      compile(first, { source: '@import "many/*"' }),
      rejectsWithCode('STYLUS_IMPORT_LIMIT'),
    )
  })
})

test('routes project bytes only through the confined resolver and stays parallel deterministic', async () => {
  await withFixture(async ({ first }) => {
    const dependency = path.join(first, 'dependency.styl')
    fs.writeFileSync(dependency, '$tone = teal\n.dependency\n  color $tone\n')
    const source = '@import "dependency"\n.entry\n  color $tone\n'
    const directReadFileSync = fs.readFileSync
    const directStatSync = fs.statSync
    fs.readFileSync = function guardedRead(filename, ...args) {
      if (typeof filename === 'string' && filename.startsWith(first)) {
        throw new Error('native Stylus project read')
      }
      return directReadFileSync.call(this, filename, ...args)
    }
    fs.statSync = function guardedStat(filename, ...args) {
      if (typeof filename === 'string' && filename.startsWith(first)) {
        throw new Error('native Stylus project stat')
      }
      return directStatSync.call(this, filename, ...args)
    }
    let result
    try {
      result = await compile(first, { source })
    } finally {
      fs.readFileSync = directReadFileSync
      fs.statSync = directStatSync
    }
    assert.deepEqual(result.dependencies, [{ url: canonicalUrl(dependency), kind: 'import' }])

    const jobs = Array.from({ length: 8 }, () => compile(first, { source }))
    const results = await Promise.all(jobs)
    for (const current of results) assert.deepEqual(current, result)

    const framed = await runPreprocessorHost(request(first, {
      requestId: 'stylus-imports-framed-001',
      source,
    }), { timeoutMs: 5000 })
    assert.equal(framed.ok, true)
    assert.equal(framed.result.css, result.css)
    assert.deepEqual(framed.result.dependencies, result.dependencies)
  })
})
