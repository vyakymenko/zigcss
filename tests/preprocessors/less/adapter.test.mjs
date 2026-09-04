import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import {
  LESS_VERSION,
  createLessProvider,
} from '../../../preprocessor/providers/less.mjs'
import { createProductionRegistry } from '../../../preprocessor/provider-registry.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'
import { resolveLockedDependency } from '../../../scripts/validate-preprocessor-package.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function providerOptions(overrides = {}) {
  return {
    math: 'parens-division',
    quietDeprecations: false,
    rewriteUrls: 'off',
    strictUnits: false,
    ...overrides,
  }
}

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

function request(overrides = {}) {
  return makeRequest({
    provider: 'less',
    syntax: 'less',
    source: '@color: red;\n.card { color: @color; }\n',
    sourceUrl: 'file:///workspace/input.less',
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: providerOptions(),
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(overrides = {}, signal = new AbortController().signal) {
  return await createLessProvider().compile(request(overrides), { signal })
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-less-renderer-'))
  try {
    await run(temporary)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

test('binds the development oracle row and lockfile to exact Less 4.9.0', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const installed = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'node_modules/less/package.json'), 'utf8'),
  )
  const matrix = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'tests/formats/matrix.json'), 'utf8'),
  )
  const provider = createProductionRegistry().get('less')
  const adapterSource = fs.readFileSync(
    path.join(repositoryRoot, 'preprocessor/providers/less.mjs'),
    'utf8',
  )

  assert.equal(LESS_VERSION, '4.9.0')
  assert.equal(manifest.dependencies?.less, undefined)
  assert.equal(manifest.dependencies?.['image-size'], undefined)
  assert.equal(manifest.devDependencies.less, LESS_VERSION)
  assert.equal(manifest.devDependencies['image-size'], undefined)
  assert.equal(manifest.files.includes('preprocessor/providers/less.mjs'), false)
  assert.equal(lock.packages[''].dependencies?.less, undefined)
  assert.equal(lock.packages[''].dependencies?.['image-size'], undefined)
  assert.equal(lock.packages[''].devDependencies.less, LESS_VERSION)
  assert.equal(lock.packages[''].devDependencies['image-size'], undefined)
  assert.equal(lock.packages['node_modules/less'].version, LESS_VERSION)
  assert.equal(
    lock.packages['node_modules/less'].integrity,
    'sha512-umRhrCH7fCi8Uj2RcwKjJdvUORTjeWqkdKx0LbcZvjIwsAVsnIAGcxHaqowPeBFBjQuWOeC/bve0AlpFzF/+SQ==',
  )
  assert.equal(lock.packages['node_modules/image-size'], undefined)
  assert.equal(installed.version, LESS_VERSION)
  assert.equal(installed.license, 'Apache-2.0')
  assert.deepEqual(installed.engines, { node: '>=18' })
  for (const lifecycle of ['preinstall', 'install', 'postinstall']) {
    assert.equal(installed.scripts?.[lifecycle], undefined)
  }
  assert.equal(matrix.canonicalProviders.less.version, LESS_VERSION)
  assert.deepEqual(provider.syntaxes, ['less'])
  assert.equal(typeof provider.compile, 'function')
  assert.match(adapterSource, /less\.render\(/)
  assert.doesNotMatch(adapterSource, /less\.renderSync\(/)
  assert.match(adapterSource, /imageDimensions\(loaded\.contents\)/)
  assert.doesNotMatch(adapterSource, /from ['"]image-size['"]|require\(['"]image-size/)
  const adapter = matrix.adapters.find(candidate => candidate.id === 'less')
  assert.equal(adapter.availability, 'NativeCliZigApi')
  assert.equal(adapter.compatibility, 'NativeGraduated')
  assert.equal(adapter.ownerPackages.at(-1), 'NATIVE-009')
  assert.equal(adapter.implementation, 'NativeFrontend')
  assert.equal(adapter.referenceOracleId, 'less')
})

test('renders canonical Less semantics in exact expanded and compressed styles', async () => {
  const source = [
    '@space: 4px;',
    '.rounded(@radius) { border-radius: @radius; }',
    '.card {',
    '  .rounded(@space);',
    '  width: (@space * 2);',
    '  &:hover { color: red; }',
    '}',
  ].join('\n')
  const expanded = await compile({ source })
  const compressed = await compile({
    source,
    options: {
      style: 'compressed',
      sourceMap: false,
      loadPaths: [],
      providerOptions: providerOptions(),
    },
  })

  assert.deepEqual(expanded, {
    css: [
      '.card {',
      '  border-radius: 4px;',
      '  width: 8px;',
      '}',
      '.card:hover {',
      '  color: red;',
      '}',
      '',
    ].join('\n'),
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
  assert.deepEqual(compressed, {
    css: '.card{border-radius:4px;width:8px}.card:hover{color:red}',
    sourceMap: null,
    diagnostics: [{
      severity: 'warning',
      code: 'less.deprecation.compress',
      message: 'The compress option has been deprecated. We recommend you use a dedicated css minifier, for instance see less-plugin-clean-css.',
      sourceUrl: 'file:///workspace/input.less',
      line: null,
      column: null,
    }],
    dependencies: [],
  })
  assert.deepEqual(await compile({ source }), expanded)
})

test('maps only the closed non-executable Less provider options', async () => {
  const source = '.value { division: 6 / 3; parens: (6 / 3); }'
  const defaultMath = await compile({ source })
  const alwaysMath = await compile({
    source,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: providerOptions({ math: 'always' }),
    },
  })
  const strictMath = await compile({
    source,
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: providerOptions({ math: 'parens' }),
    },
  })

  assert.equal(defaultMath.css, '.value {\n  division: 6 / 3;\n  parens: 2;\n}\n')
  assert.equal(alwaysMath.css, '.value {\n  division: 2;\n  parens: 2;\n}\n')
  assert.equal(strictMath.css, defaultMath.css)
  await assert.rejects(
    compile({
      source: '.value { width: 1px + 1s; }',
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [],
        providerOptions: providerOptions({ strictUnits: true }),
      },
    }),
    rejectsWithCode('LESS_COMPILE_ERROR'),
  )
  await assert.rejects(
    compile({
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [],
        providerOptions: { math: 'parens-division' },
      },
    }),
    rejectsWithCode('LESS_REQUEST_INVALID'),
  )
})

test('locks and license-reviews the complete Less dependency closure', () => {
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const pending = ['node_modules/less']
  const seen = new Set()
  while (pending.length !== 0) {
    const packagePath = pending.shift()
    if (seen.has(packagePath)) continue
    const entry = lock.packages[packagePath]
    assert.notEqual(entry, undefined, packagePath)
    assert.match(entry.resolved, /^https:\/\/registry\.npmjs\.org\//)
    assert.match(entry.integrity, /^sha512-[A-Za-z0-9+/]+=*$/)
    assert.equal(entry.dev, true, `${packagePath}:dev`)
    seen.add(packagePath)
    pending.push(...Object.keys({
      ...(entry.dependencies ?? {}),
      ...(entry.optionalDependencies ?? {}),
    }).sort().map(name => resolveLockedDependency(lock, packagePath, name)))
  }

  assert.deepEqual([...seen].sort().map(packagePath => {
    const entry = lock.packages[packagePath]
    return `${packagePath} ${entry.version} ${entry.license}`
  }), [
    'node_modules/copy-anything 3.0.5 MIT',
    'node_modules/errno 0.1.8 MIT',
    'node_modules/graceful-fs 4.2.11 ISC',
    'node_modules/iconv-lite 0.6.3 MIT',
    'node_modules/is-what 4.1.16 MIT',
    'node_modules/less 4.9.0 Apache-2.0',
    'node_modules/lodash.merge 4.6.2 MIT',
    'node_modules/make-dir 5.1.0 MIT',
    'node_modules/mime 1.6.0 MIT',
    'node_modules/ms 2.1.3 MIT',
    'node_modules/needle 3.5.0 MIT',
    'node_modules/parse-node-version 1.0.1 MIT',
    'node_modules/probe-image-size 7.4.0 MIT',
    'node_modules/probe-image-size/node_modules/debug 3.2.7 MIT',
    'node_modules/probe-image-size/node_modules/iconv-lite 0.4.24 MIT',
    'node_modules/probe-image-size/node_modules/needle 2.9.1 MIT',
    'node_modules/prr 1.0.1 MIT',
    'node_modules/safer-buffer 2.1.2 MIT',
    'node_modules/sax 1.6.0 BlueOak-1.0.0',
    'node_modules/source-map 0.6.1 BSD-3-Clause',
    'node_modules/stream-parser 0.3.1 MIT',
    'node_modules/stream-parser/node_modules/debug 2.6.9 MIT',
    'node_modules/stream-parser/node_modules/ms 2.0.0 MIT',
  ])
})

test('owns deterministic Source Map v3 bytes for only the virtual entry', async () => {
  const source = '@color: red;\n.card { color: @color; }\n'
  const result = await compile({
    source,
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [],
      providerOptions: providerOptions(),
    },
  })
  const repeated = await compile({
    source,
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [],
      providerOptions: providerOptions(),
    },
  })

  assert.equal(result.sourceMap, repeated.sourceMap)
  const map = parseSourceMap(result.sourceMap)
  assert.equal(map.version, 3)
  assert.deepEqual(map.sources, ['file:///workspace/input.less'])
  assert.deepEqual(map.sourcesContent, [source])
  assert.deepEqual(result.dependencies, [])
})

test('requires confined roots before adjacent filesystem bytes can compile', async () => {
  await withFixture(async temporary => {
    const entry = path.join(temporary, 'input.less')
    const secret = path.join(temporary, 'secret.less')
    fs.writeFileSync(entry, 'entry bytes are supplied by the request only\n')
    fs.writeFileSync(secret, '.secret { color: fuchsia; }\n')

    await assert.rejects(
      compile({
        source: '@import "secret";\n.entry { color: red; }',
        sourceUrl: pathToFileURL(entry).href,
      }),
      error => {
        assert.equal(rejectsWithCode('LESS_IMPORTS_UNAVAILABLE')(error), true)
        assert.equal('css' in error, false)
        assert.doesNotMatch(error.message, /fuchsia|secret bytes/i)
        return true
      },
    )
    for (const source of [
      '@import (optional) "missing";\n.entry { color: red; }',
      '@import (inline) "secret.txt";\n.entry { color: red; }',
      '@import "https://example.invalid/remote.less";\n.entry { color: red; }',
      '.entry { value: data-uri("secret.txt"); }',
      '.entry { width: image-width("secret.png"); }',
    ]) {
      await assert.rejects(
        compile({ source, sourceUrl: pathToFileURL(entry).href }),
        rejectsWithCode('LESS_IMPORTS_UNAVAILABLE'),
      )
    }
    assert.deepEqual(await compile({
      source: '@import (css) "https://example.invalid/theme.css";\n.entry { color: red; }',
      sourceUrl: pathToFileURL(entry).href,
    }), {
      css: '@import "https://example.invalid/theme.css";\n.entry {\n  color: red;\n}\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    })
    assert.deepEqual(await compile({
      source: '.entry { color: red; }',
      sourceUrl: pathToFileURL(entry).href,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [temporary],
        providerOptions: providerOptions(),
      },
    }), {
      css: '.entry {\n  color: red;\n}\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    })
  })
})

test('keeps Less JavaScript and plugin execution disabled', async () => {
  await withFixture(async temporary => {
    const marker = path.join(temporary, 'executed')
    const plugin = path.join(temporary, 'evil.js')
    fs.writeFileSync(plugin, `require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'plugin')\n`)
    const entryUrl = pathToFileURL(path.join(temporary, 'input.less')).href

    await assert.rejects(
      compile({ source: '@plugin "evil.js";\n.card { color: red; }', sourceUrl: entryUrl }),
      rejectsWithCode('LESS_PLUGIN_DISABLED'),
    )
    assert.equal(fs.existsSync(marker), false)

    const javascript = `@value: \`require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'js')\`;\n.card { value: @value; }`
    await assert.rejects(
      compile({ source: javascript, sourceUrl: entryUrl }),
      rejectsWithCode('LESS_JAVASCRIPT_DISABLED'),
    )
    assert.equal(fs.existsSync(marker), false)
  })
})

test('normalizes parse failures without returning partial CSS', async () => {
  await assert.rejects(
    compile({ source: '.valid { color: red; }\n.broken { color: @missing; }' }),
    error => {
      assert.equal(error.code, 'LESS_COMPILE_ERROR')
      assert.equal(error.message, 'Less rejected the input')
      assert.equal(error.diagnostics.length, 1)
      assert.equal(error.diagnostics[0].severity, 'error')
      assert.equal(error.diagnostics[0].code, 'less.compile')
      assert.equal(error.diagnostics[0].sourceUrl, 'file:///workspace/input.less')
      assert.equal(error.diagnostics[0].line, 2)
      assert.equal('css' in error, false)
      return true
    },
  )
})

test('fails closed when Less exceeds the diagnostic ceiling', async () => {
  const source = Array.from({ length: 1001 }, (_, index) => (
    `.item-${index}:extend(.missing-${index}) {}`
  )).join('\n')
  await assert.rejects(
    compile({ source }),
    error => {
      assert.equal(error.code, 'LESS_DIAGNOSTIC_LIMIT')
      assert.equal(error.diagnostics.length, 0)
      assert.equal('css' in error, false)
      return true
    },
  )
})

test('rejects invalid requests and cancellation without provider output', async () => {
  await assert.rejects(
    compile({ syntax: 'scss' }),
    rejectsWithCode('LESS_REQUEST_INVALID'),
  )
  await assert.rejects(
    compile({ sourceUrl: 'https://example.com/input.less' }),
    rejectsWithCode('LESS_REQUEST_INVALID'),
  )
  await assert.rejects(
    compile({
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [],
        providerOptions: providerOptions(),
        plugins: [],
      },
    }),
    rejectsWithCode('LESS_REQUEST_INVALID'),
  )

  const before = new AbortController()
  before.abort()
  await assert.rejects(compile({}, before.signal), rejectsWithCode('LESS_CANCELLED'))

  const during = new AbortController()
  const pending = compile({}, during.signal)
  during.abort()
  await assert.rejects(pending, rejectsWithCode('LESS_CANCELLED'))
})

test('keeps repeated, parallel, and real framed-host rendering deterministic', async () => {
  const jobs = Array.from({ length: 12 }, (_, index) => compile({
    source: `@value: ${index}; .item-${index} { z-index: @value; }`,
  }))
  const results = await Promise.all(jobs)
  for (let index = 0; index < results.length; index += 1) {
    assert.equal(results[index].css, `.item-${index} {\n  z-index: ${index};\n}\n`)
    assert.deepEqual(results[index].diagnostics, [])
    assert.deepEqual(results[index].dependencies, [])
  }

  const hostRequest = request({
    requestId: 'less-host-001',
    source: '@color: rebeccapurple; .host { color: @color; }',
  })
  const response = await runPreprocessorHost(hostRequest)
  assert.deepEqual(response, {
    protocol: 'zigcss-preprocessor-v1',
    requestId: 'less-host-001',
    ok: true,
    result: {
      css: '.host {\n  color: rebeccapurple;\n}\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    },
  })
})

test('documents the virtual Less boundary and canonical product admission', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'asynchronous programmatic `less.render` API',
    'stable virtual filename',
    '`javascriptEnabled: false`',
    '`math`, `quietDeprecations`, `rewriteUrls`, and `strictUnits`',
    '`data-uri()` and the three image metadata functions',
    'first-success dependency order',
    '`LESS-012`',
    'official Less tag `v4.6.7`',
    'graduated `.less` through the unpublished 0.5 npm CLI/API',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
