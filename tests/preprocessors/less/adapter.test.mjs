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

test('binds the packaged adapter and lockfile to exact Less 4.6.7 before public graduation', () => {
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

  assert.equal(LESS_VERSION, '4.6.7')
  assert.equal(manifest.dependencies.less, LESS_VERSION)
  assert.equal(manifest.dependencies['image-size'], '0.5.5')
  assert.equal(manifest.devDependencies?.less, undefined)
  assert.equal(manifest.files.includes('preprocessor/providers/less.mjs'), true)
  assert.equal(lock.packages[''].dependencies.less, LESS_VERSION)
  assert.equal(lock.packages[''].dependencies['image-size'], '0.5.5')
  assert.equal(lock.packages['node_modules/less'].version, LESS_VERSION)
  assert.equal(
    lock.packages['node_modules/less'].integrity,
    'sha512-o3UxHBPPVY1HtCXx15/z1NlknQiWyafRNbtLEv+6xFaDRI2g2xPKIH43do9dSwt8bGLTsjNSaifa48N3d6odsQ==',
  )
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
  const adapter = matrix.adapters.find(candidate => candidate.id === 'less')
  assert.equal(adapter.availability, 'Unavailable')
  assert.equal(adapter.compatibility, 'Unverified')
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
  const pending = ['less']
  const seen = new Set()
  while (pending.length !== 0) {
    const name = pending.shift()
    if (seen.has(name)) continue
    const entry = lock.packages[`node_modules/${name}`]
    assert.notEqual(entry, undefined, name)
    assert.match(entry.resolved, /^https:\/\/registry\.npmjs\.org\//)
    assert.match(entry.integrity, /^sha512-[A-Za-z0-9+/]+=*$/)
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
    'copy-anything@3.0.5 MIT',
    'errno@0.1.8 MIT',
    'graceful-fs@4.2.11 ISC',
    'iconv-lite@0.6.3 MIT',
    'image-size@0.5.5 MIT',
    'is-what@4.1.16 MIT',
    'less@4.6.7 Apache-2.0',
    'make-dir@5.1.0 MIT',
    'mime@1.6.0 MIT',
    'needle@3.5.0 MIT',
    'parse-node-version@1.0.1 MIT',
    'prr@1.0.1 MIT',
    'safer-buffer@2.1.2 MIT',
    'sax@1.6.0 BlueOak-1.0.0',
    'source-map@0.6.1 BSD-3-Clause',
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

test('documents the virtual Less boundary and preserves unavailable public admission', () => {
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
    '`.less` remains rejected by the public CLI',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
