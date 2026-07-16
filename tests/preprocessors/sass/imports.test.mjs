import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import {
  SASS_MAX_IMPORT_DEPTH,
  createDartSassProvider,
} from '../../../preprocessor/providers/dart-sass.mjs'
import {
  composeSourceMaps,
  parseSourceMap,
} from '../../../preprocessor/source-map.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

function canonicalUrl(filename) {
  return pathToFileURL(fs.realpathSync(filename)).href
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-sass-imports-'))
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
    sourceUrl: pathToFileURL(path.join(root, 'input.scss')).href,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [root],
      providerOptions: { charset: true, quietDeps: false, verbose: false },
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(root, overrides = {}) {
  return await createDartSassProvider().compile(request(root, overrides), {
    signal: new AbortController().signal,
  })
}

test('matches Dart Sass load-path, partial, index, forward, and import-only precedence', async () => {
  await withFixture(async ({ first, second }) => {
    const components = path.join(first, 'components')
    fs.mkdirSync(components)
    const index = path.join(components, '_index.scss')
    const tokens = path.join(first, '_tokens.scss')
    const secondTokens = path.join(second, '_tokens.scss')
    const legacyImport = path.join(first, '_legacy.import.scss')
    fs.writeFileSync(index, '@forward "../tokens";\n')
    fs.writeFileSync(tokens, '$accent: #c0ffee;\n')
    fs.writeFileSync(secondTokens, '$accent: red;\n')
    fs.writeFileSync(legacyImport, '.legacy { border-color: #c0ffee; }\n')
    fs.writeFileSync(path.join(first, '_legacy.scss'), '.legacy { border-color: red; }\n')

    const result = await compile(first, {
      source: [
        '@use "components";',
        '@import "legacy";',
        '.card { color: components.$accent; }',
      ].join('\n'),
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first, second],
        providerOptions: { charset: true, quietDeps: false, verbose: false },
      },
    })

    assert.equal(result.css, [
      '.legacy {',
      '  border-color: #c0ffee;',
      '}',
      '',
      '.card {',
      '  color: #c0ffee;',
      '}',
    ].join('\n'))
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(index), kind: 'reference' },
      { url: canonicalUrl(tokens), kind: 'reference' },
      { url: canonicalUrl(legacyImport), kind: 'import' },
    ])
  })
})

test('maps imported indented Sass syntax without translating its source bytes', async () => {
  await withFixture(async ({ first }) => {
    const palette = path.join(first, '_palette.sass')
    fs.writeFileSync(palette, '$accent: rebeccapurple\n')
    const result = await compile(first, {
      syntax: 'sass',
      sourceUrl: pathToFileURL(path.join(first, 'input.sass')).href,
      source: '@use "palette"\n.card\n  color: palette.$accent\n',
    })
    assert.equal(result.css, '.card {\n  color: rebeccapurple;\n}')
    assert.deepEqual(result.dependencies, [
      { url: canonicalUrl(palette), kind: 'reference' },
    ])
  })
})

test('preserves caller load-path order independently of resolver root normalization', async () => {
  await withFixture(async ({ first, second }) => {
    const firstChoice = path.join(first, '_choice.scss')
    const secondChoice = path.join(second, '_choice.scss')
    fs.writeFileSync(firstChoice, '$color: red;\n')
    fs.writeFileSync(secondChoice, '$color: blue;\n')
    const source = '@use "choice";\n.card { color: choice.$color; }'

    const secondFirst = await compile(first, {
      source,
      sourceUrl: null,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [second, first],
        providerOptions: { charset: true, quietDeps: false, verbose: false },
      },
    })
    const firstFirst = await compile(first, {
      source,
      sourceUrl: null,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first, second],
        providerOptions: { charset: true, quietDeps: false, verbose: false },
      },
    })

    assert.equal(secondFirst.css, '.card {\n  color: blue;\n}')
    assert.deepEqual(secondFirst.dependencies, [{
      url: canonicalUrl(secondChoice),
      kind: 'reference',
    }])
    assert.equal(firstFirst.css, '.card {\n  color: red;\n}')
    assert.deepEqual(firstFirst.dependencies, [{
      url: canonicalUrl(firstChoice),
      kind: 'reference',
    }])
  })
})

test('routes dynamic meta.load-css through the same confined dependency authority', async () => {
  await withFixture(async ({ first }) => {
    const fragment = path.join(first, '_fragment.scss')
    fs.writeFileSync(fragment, '.fragment { color: red; }\n')
    const result = await compile(first, {
      source: [
        '@use "sass:meta";',
        '.scope { @include meta.load-css("fragment"); }',
      ].join('\n'),
    })
    assert.equal(result.css, '.scope .fragment {\n  color: red;\n}')
    assert.deepEqual(result.dependencies, [{
      url: canonicalUrl(fragment),
      kind: 'reference',
    }])
  })
})

test('fails closed on canonical Sass ambiguity without returning CSS', async () => {
  await withFixture(async ({ first }) => {
    fs.writeFileSync(path.join(first, '_theme.scss'), '$color: red;\n')
    fs.writeFileSync(path.join(first, 'theme.scss'), '$color: blue;\n')
    await assert.rejects(
      compile(first, { source: '@use "theme";\n.card { color: theme.$color; }' }),
      error => {
        assert.equal(rejectsWithCode('SASS_IMPORT_AMBIGUOUS')(error), true)
        assert.equal('css' in error, false)
        assert.equal(error.diagnostics[0].sourceUrl, pathToFileURL(path.join(first, 'input.scss')).href)
        return true
      },
    )
  })
})

test('matches extension ambiguity, explicit-extension, and CSS fallback groups', async () => {
  await withFixture(async ({ first }) => {
    fs.writeFileSync(path.join(first, '_ambiguous.sass'), '$value: red\n')
    fs.writeFileSync(path.join(first, 'ambiguous.scss'), '$value: blue;\n')
    await assert.rejects(
      compile(first, { source: '@use "ambiguous";' }),
      rejectsWithCode('SASS_IMPORT_AMBIGUOUS'),
    )

    const fallbackScss = path.join(first, '_fallback.scss')
    fs.writeFileSync(fallbackScss, '.scss-wins { color: red; }\n')
    fs.writeFileSync(path.join(first, '_fallback.css'), '.css-loses { color: blue; }\n')
    const fallback = await compile(first, { source: '@use "fallback";' })
    assert.equal(fallback.css, '.scss-wins {\n  color: red;\n}')
    assert.deepEqual(fallback.dependencies, [{
      url: canonicalUrl(fallbackScss),
      kind: 'reference',
    }])

    const onlyCss = path.join(first, '_only.css')
    fs.writeFileSync(onlyCss, '.only-css { color: green; }\n')
    const css = await compile(first, { source: '@use "only";' })
    assert.equal(css.css, '.only-css {\n  color: green;\n}')
    assert.deepEqual(css.dependencies, [{
      url: canonicalUrl(onlyCss),
      kind: 'reference',
    }])

    fs.writeFileSync(path.join(first, '_explicit.sass'), '$value: red\n')
    const explicitScss = path.join(first, '_explicit.scss')
    fs.writeFileSync(explicitScss, '$value: blue;\n')
    const explicit = await compile(first, {
      source: '@use "explicit.scss";\n.card { color: explicit.$value; }',
    })
    assert.equal(explicit.css, '.card {\n  color: blue;\n}')
    assert.deepEqual(explicit.dependencies, [{
      url: canonicalUrl(explicitScss),
      kind: 'reference',
    }])
  })
})

test('owns imported-file diagnostics and every provider source-map identity', async () => {
  await withFixture(async ({ first }) => {
    const dependency = path.join(first, '_dependency.scss')
    fs.writeFileSync(dependency, '.dependency { color: darken(red, 10%); }\n')
    const source = '@use "dependency";\n.entry::before { content: "🙂"; }\n'
    const result = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: { charset: true, quietDeps: false, verbose: false },
      },
    })
    const dependencyUrl = canonicalUrl(dependency)
    const entryUrl = pathToFileURL(path.join(first, 'input.scss')).href
    assert.deepEqual(result.diagnostics.map(diagnostic => diagnostic.sourceUrl), [
      dependencyUrl,
      dependencyUrl,
    ])
    assert.deepEqual(result.dependencies, [{ url: dependencyUrl, kind: 'reference' }])
    const map = parseSourceMap(result.sourceMap)
    assert.deepEqual(new Set(map.sources), new Set([entryUrl, dependencyUrl]))
    assert.equal(map.sourcesContent[map.sources.indexOf(entryUrl)], source)
    assert.equal(map.sourcesContent[map.sources.indexOf(dependencyUrl)], fs.readFileSync(dependency, 'utf8'))

    const intermediateSourceUrl = 'zigcss-intermediate:provider.css'
    const identityMappings = result.css.split('\n').map((_, index) => (
      index === 0 ? 'AAAA' : 'AACA'
    )).join(';')
    const composed = parseSourceMap(composeSourceMaps({
      providerMap: result.sourceMap,
      zigMap: JSON.stringify({
        version: 3,
        sources: [intermediateSourceUrl],
        names: [],
        mappings: identityMappings,
      }),
      intermediateSourceUrl,
    }))
    assert.deepEqual(composed.sources, map.sources)
    assert.deepEqual(composed.sourcesContent, map.sourcesContent)

    const broken = path.join(first, '_broken.scss')
    fs.writeFileSync(broken, '$value: ;\n')
    await assert.rejects(
      compile(first, { source: '@use "broken";' }),
      error => {
        assert.equal(rejectsWithCode('SASS_COMPILE_ERROR')(error), true)
        assert.equal(error.diagnostics[0].sourceUrl, canonicalUrl(broken))
        assert.equal(error.diagnostics[0].line, 1)
        assert.equal('css' in error, false)
        return true
      },
    )
  })
})

test('applies quietDeps only to ordered load-path dependencies, not entry-relative files', async () => {
  await withFixture(async ({ first }) => {
    const dependency = path.join(first, '_dependency.scss')
    fs.writeFileSync(dependency, '.dependency { color: darken(red, 10%); }\n')
    const source = '@use "dependency";\n'
    const providerOptions = { charset: true, quietDeps: true, verbose: false }

    const loadPathDependency = await compile(first, {
      source,
      sourceUrl: null,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first],
        providerOptions,
      },
    })
    const entryRelative = await compile(first, {
      source,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [first],
        providerOptions,
      },
    })

    assert.equal(loadPathDependency.css, entryRelative.css)
    assert.deepEqual(loadPathDependency.diagnostics, [])
    assert.equal(entryRelative.diagnostics.length, 2)
    assert.deepEqual(loadPathDependency.dependencies, entryRelative.dependencies)
  })
})

test('rejects missing, escaping, linked, and invalid-encoding imports with stable ownership', async () => {
  await withFixture(async ({ first, outside }) => {
    const secret = path.join(outside, '_secret.scss')
    fs.writeFileSync(secret, '$secret: red;\n')

    await assert.rejects(
      compile(first, { source: '@use "missing";' }),
      error => {
        assert.equal(rejectsWithCode('SASS_COMPILE_ERROR')(error), true)
        assert.equal(error.diagnostics[0].sourceUrl, pathToFileURL(path.join(first, 'input.scss')).href)
        return true
      },
    )
    await assert.rejects(
      compile(first, { source: '@use "../outside/secret";' }),
      rejectsWithCode('SASS_IMPORT_POLICY'),
    )
    await assert.rejects(
      compile(first, { source: `@use "${pathToFileURL(secret).href}";` }),
      rejectsWithCode('SASS_IMPORT_POLICY'),
    )
    await assert.rejects(
      compile(first, { source: '@use "https://example.com/theme";' }),
      rejectsWithCode('SASS_IMPORT_POLICY'),
    )
    await assert.rejects(
      compile(first, { source: '@use "pkg:untrusted";' }),
      rejectsWithCode('SASS_IMPORT_POLICY'),
    )

    const invalid = path.join(first, '_invalid.scss')
    fs.writeFileSync(invalid, Buffer.from([0xff, 0xfe]))
    await assert.rejects(
      compile(first, { source: '@use "invalid";' }),
      rejectsWithCode('SASS_IMPORT_ENCODING'),
    )

    const oversized = path.join(first, '_oversized.scss')
    fs.writeFileSync(oversized, '')
    fs.truncateSync(oversized, 10 * 1024 * 1024 + 1)
    await assert.rejects(
      compile(first, { source: '@use "oversized";' }),
      rejectsWithCode('SASS_IMPORT_LIMIT'),
    )

    if (process.platform !== 'win32' && process.getuid?.() !== 0) {
      const unreadable = path.join(first, '_unreadable.scss')
      fs.writeFileSync(unreadable, '$value: red;\n', { mode: 0o600 })
      fs.chmodSync(unreadable, 0o000)
      try {
        await assert.rejects(
          compile(first, { source: '@use "unreadable";' }),
          rejectsWithCode('SASS_IMPORT_IO'),
        )
      } finally {
        fs.chmodSync(unreadable, 0o600)
      }
    }

    if (process.platform !== 'win32') {
      fs.symlinkSync(secret, path.join(first, '_linked.scss'))
      await assert.rejects(
        compile(first, { source: '@use "linked";' }),
        rejectsWithCode('SASS_IMPORT_POLICY'),
      )
    }
  })
})

test('keeps imported SCSS results deterministic across repetition and parallel workers', async () => {
  await withFixture(async ({ first }) => {
    fs.writeFileSync(path.join(first, '_tokens.scss'), '$accent: rebeccapurple;\n')
    const overrides = {
      source: '@use "tokens";\n.card::before { color: tokens.$accent; content: "🙂"; }',
      options: {
        style: 'compressed',
        sourceMap: true,
        loadPaths: [first],
        providerOptions: { charset: true, quietDeps: false, verbose: false },
      },
    }
    const baseline = await compile(first, overrides)
    assert.deepEqual(await compile(first, overrides), baseline)
    const parallel = await Promise.all(Array.from({ length: 8 }, () => compile(first, overrides)))
    for (const result of parallel) assert.deepEqual(result, baseline)

    const controller = new AbortController()
    const pending = createDartSassProvider().compile(request(first, overrides), {
      signal: controller.signal,
    })
    controller.abort()
    await assert.rejects(pending, rejectsWithCode('SASS_CANCELLED'))
    assert.deepEqual(await compile(first, overrides), baseline)
  })
})

test('enforces canonical import cycles and the provider-safe ancestry limit', async () => {
  await withFixture(async ({ first }) => {
    fs.writeFileSync(path.join(first, '_a.scss'), '@use "b";\n')
    fs.writeFileSync(path.join(first, '_b.scss'), '@use "a";\n')
    await assert.rejects(
      compile(first, { source: '@use "a";' }),
      rejectsWithCode('SASS_IMPORT_CYCLE'),
    )

    assert.equal(SASS_MAX_IMPORT_DEPTH, 32)
    for (let index = 0; index <= SASS_MAX_IMPORT_DEPTH; index += 1) {
      const next = index === SASS_MAX_IMPORT_DEPTH ? '' : `@use "depth-${index + 1}";\n`
      fs.writeFileSync(path.join(first, `_depth-${index}.scss`), next)
    }
    await assert.rejects(
      compile(first, { source: '@use "depth-0";' }),
      rejectsWithCode('SASS_IMPORT_DEPTH_LIMIT'),
    )
  })
})

test('documents confined Sass resolution and preserves pre-admission status', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'Dart Sass never receives native entry-file or native load-path authority',
    'partial/full ambiguity groups',
    'legacy `.import` precedence',
    'recorded as `reference`',
    'lowers its ancestry ceiling to 32',
    '`quietDeps` follows Dart Sass ownership',
    'remain rejected by the public CLI',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
