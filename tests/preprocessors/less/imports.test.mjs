import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { pathToFileURL } from 'node:url'
import less from 'less'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import { createLessProvider } from '../../../preprocessor/providers/less.mjs'
import {
  composeSourceMaps,
  parseSourceMap,
} from '../../../preprocessor/source-map.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

function providerOptions(overrides = {}) {
  return {
    math: 'parens-division',
    quietDeprecations: false,
    rewriteUrls: 'off',
    strictUnits: false,
    ...overrides,
  }
}

function canonicalUrl(filename) {
  return pathToFileURL(fs.realpathSync(filename)).href
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-less-imports-'))
  const first = path.join(temporary, 'first')
  const second = path.join(temporary, 'second')
  const outside = path.join(temporary, 'outside')
  fs.mkdirSync(first)
  fs.mkdirSync(second)
  fs.mkdirSync(outside)
  try {
    await run({ temporary, first, second, outside })
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function request(root, overrides = {}) {
  return makeRequest({
    provider: 'less',
    syntax: 'less',
    source: '.entry { color: red; }',
    sourceUrl: pathToFileURL(path.join(root, 'input.less')).href,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [root],
      providerOptions: providerOptions(),
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(root, overrides = {}) {
  return await createLessProvider().compile(request(root, overrides), {
    signal: new AbortController().signal,
  })
}

async function renderDirect(source, filename, paths, overrides = {}) {
  return await less.render(source, {
    compress: false,
    disablePluginRule: true,
    filename,
    insecure: false,
    javascriptEnabled: false,
    paths,
    ...overrides,
  })
}

test('matches canonical entry-relative, load-path, extension, and nested resolution order', async () => {
  await withFixture(async ({ first, second }) => {
    const firstTokens = path.join(first, 'tokens.less')
    const secondTokens = path.join(second, 'tokens.less')
    const parent = path.join(first, 'nested', 'parent.less')
    const child = path.join(first, 'nested', 'child.less')
    fs.mkdirSync(path.dirname(parent))
    fs.writeFileSync(firstTokens, '@accent: #c0ffee;\n')
    fs.writeFileSync(secondTokens, '@accent: red;\n')
    fs.writeFileSync(parent, '@import "child";\n.parent { border-color: @nested; }\n')
    fs.writeFileSync(child, '@nested: rebeccapurple;\n.child { color: @nested; }\n')
    const source = [
      '@import "tokens";',
      '@import "nested/parent";',
      '.entry { color: @accent; }',
    ].join('\n')
    const filename = path.join(first, 'input.less')
    const direct = await renderDirect(source, filename, [second, first])
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [second, first],
        providerOptions: providerOptions(),
      },
    })

    assert.equal(result.css, direct.css)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(firstTokens), kind: 'import' },
      { url: canonicalUrl(parent), kind: 'import' },
      { url: canonicalUrl(child), kind: 'import' },
    ])

    const loadPathOnly = await compile(first, {
      source: '@import "tokens";\n.entry { color: @accent; }',
      sourceUrl: null,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [second, first],
        providerOptions: providerOptions(),
      },
    })
    assert.equal(loadPathOnly.css, '.entry {\n  color: red;\n}\n')
    assert.deepEqual(loadPathOnly.dependencies, [
      { url: canonicalUrl(secondTokens), kind: 'import' },
    ])
  })
})

test('matches canonical reference, inline, optional, multiple, forced-Less, and CSS imports', async () => {
  await withFixture(async ({ first }) => {
    const library = path.join(first, 'library.less')
    const raw = path.join(first, 'raw.txt')
    const repeat = path.join(first, 'repeat.less')
    const forced = path.join(first, 'forced.css')
    fs.writeFileSync(library, '.library { color: red; }\n.mixin() { border: 1px solid; }\n')
    fs.writeFileSync(raw, 'raw-inline { value: untouched; }\n')
    fs.writeFileSync(repeat, '.repeat { display: block; }\n')
    fs.writeFileSync(forced, '@forced: blue;\n.forced { color: @forced; }\n')
    const source = [
      '@import (reference) "library";',
      '@import (inline) "raw.txt";',
      '@import (optional) "missing";',
      '@import (multiple) "repeat";',
      '@import (multiple) "repeat";',
      '@import (less) "forced.css";',
      '@import (css) "https://example.invalid/theme.css";',
      '.use { .mixin(); }',
    ].join('\n')
    const direct = await renderDirect(source, path.join(first, 'input.less'), [first])
    const result = await compile(first, { source })

    assert.equal(result.css, direct.css)
    assert.equal((result.css.match(/\.repeat \{/g) ?? []).length, 2)
    assert.doesNotMatch(result.css, /\.library \{/)
    assert.match(result.css, /raw-inline \{ value: untouched; \}/)
    assert.match(result.css, /@import "https:\/\/example\.invalid\/theme\.css";/)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(library), kind: 'import' },
      { url: canonicalUrl(raw), kind: 'import' },
      { url: canonicalUrl(repeat), kind: 'import' },
      { url: canonicalUrl(forced), kind: 'import' },
    ])
  })
})

test('owns imported diagnostics, dependencies, and every source-map identity', async () => {
  await withFixture(async ({ first }) => {
    const tokens = path.join(first, 'tokens.less')
    const component = path.join(first, 'component.less')
    fs.writeFileSync(tokens, '@accent: rebeccapurple;\n')
    fs.writeFileSync(component, '@import "tokens";\n.component { color: @accent; }\n')
    const source = '@import "component";\n.entry::before { content: "🙂"; }\n'
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: providerOptions(),
      },
    })
    const map = parseSourceMap(result.sourceMap)
    assert.deepEqual(new Set(map.sources), new Set([
      pathToFileURL(path.join(first, 'input.less')).href,
      canonicalUrl(component),
    ]))
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

    fs.writeFileSync(component, '.component { color: @missing; }\n')
    await assert.rejects(
      compile(first, { source: '@import "component";' }),
      error => {
        assert.equal(error.code, 'LESS_COMPILE_ERROR')
        assert.equal(error.diagnostics[0].sourceUrl, canonicalUrl(component))
        assert.equal(error.diagnostics[0].line, 1)
        assert.equal('css' in error, false)
        return true
      },
    )
  })
})

test('matches canonical URL rewriting without exposing provider filesystem reads', async () => {
  await withFixture(async ({ first }) => {
    const styles = path.join(first, 'styles')
    fs.mkdirSync(styles)
    const component = path.join(styles, 'component.less')
    fs.writeFileSync(component, '.asset { background: url("../images/card.png"); }\n')
    const source = '@import "styles/component";'
    for (const rewriteUrls of ['off', 'local', 'all']) {
      const direct = await renderDirect(source, path.join(first, 'input.less'), [first], {
        rewriteUrls,
      })
      const result = await compile(first, {
        source,
        options: {
          style: 'expanded',
          sourceMap: false,
          loadPaths: [first],
          providerOptions: providerOptions({ rewriteUrls }),
        },
      })
      assert.equal(result.css, direct.css, rewriteUrls)
      assert.deepEqual(result.dependencies, [{ url: canonicalUrl(component), kind: 'import' }])
    }
  })
})

test('keeps missing imports distinct from policy failures and optional misses', async () => {
  await withFixture(async ({ first, outside }) => {
    const inside = path.join(first, 'inside.less')
    fs.writeFileSync(inside, '.inside { color: green; }\n')
    fs.writeFileSync(path.join(outside, 'escape.less'), '.escape { color: red; }\n')
    const absoluteInside = await compile(first, {
      source: `@import (less) ${JSON.stringify(inside)};`,
    })
    assert.equal(absoluteInside.css, '.inside {\n  color: green;\n}\n')
    assert.deepEqual(absoluteInside.dependencies, [{
      url: canonicalUrl(inside),
      kind: 'import',
    }])
    await assert.rejects(
      compile(first, { source: '@import "missing";' }),
      error => {
        assert.equal(rejectsWithCode('LESS_IMPORT_NOT_FOUND')(error), true)
        assert.equal(error.diagnostics[0].message, 'A confined Less dependency was not found')
        assert.doesNotMatch(error.diagnostics[0].message, /ZIGCSS_/)
        return true
      },
    )
    await assert.rejects(
      compile(first, { source: '@import "../outside/escape";' }),
      rejectsWithCode('LESS_IMPORT_POLICY'),
    )
    await assert.rejects(
      compile(first, { source: '@import (less) "https://example.invalid/remote.less";' }),
      rejectsWithCode('LESS_IMPORT_POLICY'),
    )
    assert.deepEqual(await compile(first, {
      source: '@import (optional) "missing";\n.entry { color: red; }',
    }), {
      css: '.entry {\n  color: red;\n}\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    })
  })
})

test('normalizes entry and imported warnings and applies quietDeprecations exactly', async () => {
  await withFixture(async ({ first, second }) => {
    const firstWarning = path.join(first, 'warning.less')
    const secondWarning = path.join(second, 'warning.less')
    const warningSource = '.mixin() { color: red; }\n.use { .mixin; }\n'
    fs.writeFileSync(firstWarning, warningSource)
    fs.writeFileSync(secondWarning, warningSource.replace('red', 'blue'))

    const entryWarning = await compile(first, {
      source: '.mixin() { color: red; }\n.entry { .mixin; }',
    })
    assert.deepEqual(entryWarning.diagnostics.map(diagnostic => ({
      severity: diagnostic.severity,
      code: diagnostic.code,
      sourceUrl: diagnostic.sourceUrl,
      line: diagnostic.line,
      column: diagnostic.column,
    })), [{
      severity: 'warning',
      code: 'less.deprecation',
      sourceUrl: pathToFileURL(path.join(first, 'input.less')).href,
      line: 2,
      column: 16,
    }])

    const imported = await compile(first, { source: '@import "warning";' })
    assert.equal(imported.diagnostics.length, 1)
    assert.equal(imported.diagnostics[0].code, 'less.deprecation')
    assert.equal(imported.diagnostics[0].sourceUrl, canonicalUrl(firstWarning))
    assert.equal(imported.diagnostics[0].line, 2)
    assert.equal(imported.diagnostics[0].column, 14)
    assert.doesNotMatch(imported.diagnostics[0].message, /__zigcss_less_imports__|warning\.less/)

    const quiet = await compile(first, {
      source: '@import "warning";',
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first],
        providerOptions: providerOptions({ quietDeprecations: true }),
      },
    })
    assert.deepEqual(quiet.diagnostics, [])

    const [firstParallel, secondParallel] = await Promise.all([
      compile(first, { source: '@import "warning";' }),
      compile(second, { source: '@import "warning";' }),
    ])
    assert.equal(firstParallel.diagnostics[0].sourceUrl, canonicalUrl(firstWarning))
    assert.equal(secondParallel.diagnostics[0].sourceUrl, canonicalUrl(secondWarning))
  })
})

test('rejects import aliases, links, unsafe bytes, cycles, and exhausted limits without CSS', {
  skip: process.platform === 'win32',
}, async () => {
  await withFixture(async ({ first, outside }) => {
    const valid = path.join(first, 'valid.less')
    const invalidUtf8 = path.join(first, 'invalid.less')
    const outsideFile = path.join(outside, 'outside.less')
    const fileLink = path.join(first, 'file-link.less')
    const directoryLink = path.join(first, 'directory-link')
    fs.writeFileSync(valid, '.valid { color: green; }\n')
    fs.writeFileSync(invalidUtf8, Buffer.from([0xc3, 0x28]))
    fs.writeFileSync(outsideFile, '.outside { color: red; }\n')
    fs.symlinkSync(valid, fileLink)
    fs.symlinkSync(outside, directoryLink)

    for (const [source, code] of [
      ['@import (less) "valid.less?raw=1";', 'LESS_IMPORT_POLICY'],
      ['@import (less) "valid.less#fragment";', 'LESS_IMPORT_POLICY'],
      ['@import "nested%2fvalid";', 'LESS_IMPORT_POLICY'],
      ['@import "~untrusted/theme";', 'LESS_IMPORT_POLICY'],
      ['@import "file-link";', 'LESS_IMPORT_POLICY'],
      ['@import "directory-link/outside";', 'LESS_IMPORT_POLICY'],
      ['@import "invalid";', 'LESS_IMPORT_ENCODING'],
      [`@import (less) ${JSON.stringify(outsideFile)};`, 'LESS_IMPORT_POLICY'],
    ]) {
      await assert.rejects(
        compile(first, { source }),
        error => {
          assert.equal(error.code, code, source)
          assert.equal('css' in error, false)
          assert.doesNotMatch(
            error.diagnostics.map(diagnostic => diagnostic.message).join('\n'),
            /ZIGCSS_/,
          )
          return true
        },
      )
    }

    const cycleA = path.join(first, 'cycle-a.less')
    const cycleB = path.join(first, 'cycle-b.less')
    fs.writeFileSync(cycleA, '@import "cycle-b";\n')
    fs.writeFileSync(cycleB, '@import "cycle-a";\n')
    await assert.rejects(
      compile(first, { source: '@import "cycle-a";' }),
      rejectsWithCode('LESS_IMPORT_CYCLE'),
    )

    const deepFiles = Array.from({ length: 65 }, (_, index) => (
      path.join(first, `deep-${index}.less`)
    ))
    for (let index = 0; index < deepFiles.length; index += 1) {
      fs.writeFileSync(
        deepFiles[index],
        index + 1 === deepFiles.length
          ? '.deep { color: green; }\n'
          : `@import "deep-${index + 1}";\n`,
      )
    }
    await assert.rejects(
      compile(first, { source: '@import "deep-0";' }),
      rejectsWithCode('LESS_IMPORT_DEPTH_LIMIT'),
    )

    const oversized = path.join(first, 'oversized.less')
    fs.writeFileSync(oversized, '')
    fs.truncateSync(oversized, (10 * 1024 * 1024) + 1)
    await assert.rejects(
      compile(first, { source: '@import "oversized";' }),
      rejectsWithCode('LESS_IMPORT_LIMIT'),
    )
  })
})

test('rejects unreadable dependencies without CSS or dependency metadata', {
  skip: process.platform === 'win32' || process.getuid?.() === 0,
}, async () => {
  await withFixture(async ({ first }) => {
    const unreadable = path.join(first, 'unreadable.less')
    fs.writeFileSync(unreadable, '.unreadable { color: red; }\n', { mode: 0o600 })
    fs.chmodSync(unreadable, 0o000)
    try {
      await assert.rejects(
        compile(first, { source: '@import "unreadable";' }),
        error => {
          assert.equal(error.code, 'LESS_IMPORT_IO')
          assert.equal('css' in error, false)
          return true
        },
      )
    } finally {
      fs.chmodSync(unreadable, 0o600)
    }
  })
})

test('keeps imported cancellation and parallel dependency order deterministic', async () => {
  await withFixture(async ({ first }) => {
    const firstFile = path.join(first, 'first.less')
    const secondFile = path.join(first, 'second.less')
    fs.writeFileSync(firstFile, '.first { color: red; }\n')
    fs.writeFileSync(secondFile, '.second { color: blue; }\n')
    const source = '@import "first";\n@import "second";\n.entry { color: green; }'
    const expected = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: providerOptions(),
      },
    })
    const repeated = await Promise.all(Array.from({ length: 8 }, () => compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: providerOptions(),
      },
    })))
    for (const result of repeated) assert.deepEqual(result, expected)

    const controller = new AbortController()
    const pending = createLessProvider().compile(request(first, { source }), {
      signal: controller.signal,
    })
    queueMicrotask(() => controller.abort())
    await assert.rejects(pending, rejectsWithCode('LESS_CANCELLED'))
    assert.deepEqual(await compile(first, { source }), {
      ...expected,
      sourceMap: null,
    })
  })
})

test('keeps canonical ancestry distinct for convergent multiple-import branches', async () => {
  await withFixture(async ({ first }) => {
    const left = path.join(first, 'left.less')
    const right = path.join(first, 'right.less')
    const shared = path.join(first, 'shared.less')
    const leaf = path.join(first, 'leaf.less')
    fs.writeFileSync(left, '@import (multiple) "shared";\n.left { order: 1; }\n')
    fs.writeFileSync(right, '@import (multiple) "shared";\n.right { order: 2; }\n')
    fs.writeFileSync(shared, '@import (multiple) "leaf";\n.shared { display: block; }\n')
    fs.writeFileSync(leaf, '.leaf { display: inline; }\n')
    const source = '@import "left";\n@import "right";'
    const direct = await renderDirect(source, path.join(first, 'input.less'), [first])
    const result = await compile(first, { source })

    assert.equal(result.css, direct.css)
    assert.equal((result.css.match(/\.shared \{/g) ?? []).length, 2)
    assert.equal((result.css.match(/\.leaf \{/g) ?? []).length, 2)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(left), kind: 'import' },
      { url: canonicalUrl(right), kind: 'import' },
      { url: canonicalUrl(shared), kind: 'import' },
      { url: canonicalUrl(leaf), kind: 'import' },
    ])
  })
})

test('confines canonical data-uri and image metadata functions with complete dependency facts', async () => {
  await withFixture(async ({ first, second, outside }) => {
    const textAsset = path.join(first, 'asset.txt')
    const imageAsset = path.join(first, 'pixel.png')
    const outsideAsset = path.join(outside, 'secret.txt')
    fs.writeFileSync(textAsset, 'hello less\n')
    fs.writeFileSync(imageAsset, Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      'base64',
    ))
    fs.writeFileSync(outsideAsset, 'secret\n')
    const secondTextAsset = path.join(second, 'asset.txt')
    fs.writeFileSync(secondTextAsset, 'second root\n')
    const source = [
      '.asset {',
      '  embedded: data-uri("asset.txt");',
      '  dimensions: image-size("pixel.png");',
      '  width: image-width("pixel.png");',
      '  height: image-height("pixel.png");',
      '}',
    ].join('\n')
    const direct = await renderDirect(source, path.join(first, 'input.less'), [first])
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: providerOptions(),
      },
    })
    assert.equal(result.css, direct.css)
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(textAsset), kind: 'reference' },
      { url: canonicalUrl(imageAsset), kind: 'reference' },
    ])
    assert.deepEqual(parseSourceMap(result.sourceMap).sources, [
      pathToFileURL(path.join(first, 'input.less')).href,
    ])

    const [firstParallel, secondParallel] = await Promise.all([
      compile(first, { source: '.asset { value: data-uri("asset.txt"); }' }),
      compile(second, { source: '.asset { value: data-uri("asset.txt"); }' }),
    ])
    assert.match(firstParallel.css, /hello%20less/)
    assert.match(secondParallel.css, /second%20root/)
    assert.deepEqual(firstParallel.dependencies, [{
      url: canonicalUrl(textAsset),
      kind: 'reference',
    }])
    assert.deepEqual(secondParallel.dependencies, [{
      url: canonicalUrl(secondTextAsset),
      kind: 'reference',
    }])

    const missing = await compile(first, {
      source: '.asset { value: data-uri("missing.txt"); }',
    })
    assert.match(missing.css, /url\("missing\.txt"\)/)
    assert.deepEqual(missing.dependencies, [])
    assert.equal(missing.diagnostics.length, 1)
    assert.equal(missing.diagnostics[0].code, 'less.warning')
    assert.match(missing.diagnostics[0].message, /file not found/)

    for (const source of [
      '.asset { value: data-uri("asset.txt?raw=1"); }',
      '.asset { value: data-uri("../outside/secret.txt"); }',
      `.asset { value: data-uri(${JSON.stringify(outsideAsset)}); }`,
    ]) {
      await assert.rejects(compile(first, { source }), error => {
        assert.equal(error.code, 'LESS_IMPORT_POLICY')
        assert.equal('css' in error, false)
        return true
      })
    }

    if (process.platform !== 'win32') {
      const assetLink = path.join(first, 'asset-link.txt')
      fs.symlinkSync(textAsset, assetLink)
      await assert.rejects(
        compile(first, { source: '.asset { value: data-uri("asset-link.txt"); }' }),
        rejectsWithCode('LESS_IMPORT_POLICY'),
      )
    }
  })
})
