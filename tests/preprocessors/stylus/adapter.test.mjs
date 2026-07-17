import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ProviderFailure } from '../../../preprocessor/metadata.mjs'
import {
  STYLUS_VERSION,
  createStylusProvider,
} from '../../../preprocessor/providers/stylus.mjs'
import { createProductionRegistry } from '../../../preprocessor/provider-registry.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'
import { makeRequest } from '../protocol/helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function rejectsWithCode(code) {
  return error => error instanceof ProviderFailure && error.code === code
}

function request(overrides = {}) {
  return makeRequest({
    provider: 'stylus',
    syntax: 'stylus',
    source: '.card\n  color red\n',
    sourceUrl: 'file:///workspace/input.styl',
    options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: { hoistAtrules: false, includeCss: false },
      ...(overrides.options ?? {}),
    },
    ...overrides,
  })
}

async function compile(overrides = {}, signal = new AbortController().signal) {
  return await createStylusProvider().compile(request(overrides), { signal })
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-stylus-renderer-'))
  try {
    await run(temporary)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function resolveLockedDependency(lock, parent, name) {
  let cursor = parent
  while (true) {
    const nested = `${cursor}/node_modules/${name}`
    if (Object.hasOwn(lock.packages, nested)) return nested
    const boundary = cursor.lastIndexOf('/node_modules/')
    if (boundary === -1) break
    cursor = cursor.slice(0, boundary)
  }
  const topLevel = `node_modules/${name}`
  assert.equal(Object.hasOwn(lock.packages, topLevel), true, `${parent} -> ${name}`)
  return topLevel
}

function stylusClosure(lock) {
  const pending = ['node_modules/stylus']
  const seen = new Set()
  while (pending.length !== 0) {
    const packagePath = pending.shift()
    if (seen.has(packagePath)) continue
    const entry = lock.packages[packagePath]
    assert.notEqual(entry, undefined, packagePath)
    seen.add(packagePath)
    for (const name of Object.keys({
      ...(entry.dependencies ?? {}),
      ...(entry.optionalDependencies ?? {}),
    })) {
      pending.push(resolveLockedDependency(lock, packagePath, name))
    }
  }
  return [...seen].sort()
}

test('binds the graduated package row and lockfile to exact Stylus 0.64.0', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const installed = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'node_modules/stylus/package.json'), 'utf8'),
  )
  const matrix = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'tests/formats/matrix.json'), 'utf8'),
  )
  const provider = createProductionRegistry().get('stylus')
  const adapterSource = fs.readFileSync(
    path.join(repositoryRoot, 'preprocessor/providers/stylus.mjs'),
    'utf8',
  )
  const importerSource = fs.readFileSync(
    path.join(repositoryRoot, 'preprocessor/providers/stylus-importer.mjs'),
    'utf8',
  )

  assert.equal(STYLUS_VERSION, '0.64.0')
  assert.equal(manifest.dependencies.stylus, STYLUS_VERSION)
  assert.equal(manifest.devDependencies?.stylus, undefined)
  assert.equal(manifest.files.includes('preprocessor/providers/stylus.mjs'), true)
  assert.equal(lock.packages[''].dependencies.stylus, STYLUS_VERSION)
  assert.equal(lock.packages['node_modules/stylus'].version, STYLUS_VERSION)
  assert.equal(
    lock.packages['node_modules/stylus'].integrity,
    'sha512-ZIdT8eUv8tegmqy1tTIdJv9We2DumkNZFdCF5mz/Kpq3OcTaxSuCAYZge6HKK2CmNC02G1eJig2RV7XTw5hQrA==',
  )
  assert.equal(installed.version, STYLUS_VERSION)
  assert.equal(installed.license, 'MIT')
  assert.deepEqual(installed.engines, { node: '>=16' })
  for (const lifecycle of ['preinstall', 'install', 'postinstall']) {
    assert.equal(installed.scripts?.[lifecycle], undefined)
  }
  assert.equal(matrix.canonicalProviders.stylus.version, STYLUS_VERSION)
  assert.deepEqual(provider.syntaxes, ['stylus'])
  assert.equal(typeof provider.compile, 'function')
  assert.match(adapterSource, /stylus\(request\.source/)
  assert.match(adapterSource, /renderer\.render\(/)
  assert.match(adapterSource, /cache: false/)
  assert.equal(lock.packages['node_modules/glob'].version, '10.5.0')
  assert.equal(
    lock.packages['node_modules/glob'].integrity,
    'sha512-DfXN8DfhJ7NH3Oe7cFmu3NCu1wKbkReJ8TorzSAFbSKrlNaQSKfIzqYqVY8zlbs2NLBbWpRiU52GX2PbaBVNkg==',
  )
  assert.match(importerSource, /stylusRequire\('glob'\)/)
  assert.match(importerSource, /globIterateSync\(/)
  assert.doesNotMatch(importerSource, /node:child_process|\b(?:exec|spawn)(?:File|Sync)?\s*\(/)
  const adapter = matrix.adapters.find(candidate => candidate.id === 'stylus')
  assert.equal(adapter.availability, 'CanonicalCliApi')
  assert.equal(adapter.compatibility, 'CanonicalVersion')
  assert.equal(adapter.implementation, 'CanonicalProvider')
})

test('renders canonical Stylus semantics in exact expanded and compressed styles', async () => {
  const source = [
    'space = 4px',
    'rounded(radius)',
    '  border-radius radius',
    '.card',
    '  rounded(space)',
    '  width space * 2',
    '  background lighten(#000, 50%)',
    '  &:hover',
    '    color red',
  ].join('\n')
  const expanded = await compile({ source })
  const compressed = await compile({
    source,
    options: {
      style: 'compressed',
      sourceMap: false,
      loadPaths: [],
      providerOptions: { hoistAtrules: false, includeCss: false },
    },
  })

  assert.deepEqual(expanded, {
    css: [
      '.card {',
      '  border-radius: 4px;',
      '  width: 8px;',
      '  background: #808080;',
      '}',
      '.card:hover {',
      '  color: #f00;',
      '}',
      '',
    ].join('\n'),
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
  assert.deepEqual(compressed, {
    css: '.card{border-radius:4px;width:8px;background:#808080}.card:hover{color:#f00}',
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  })
  assert.deepEqual(await compile({ source }), expanded)
})

test('locks and license-reviews the complete Stylus dependency closure', () => {
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  const closure = stylusClosure(lock)
  const rows = closure.map(packagePath => {
    const entry = lock.packages[packagePath]
    assert.match(entry.resolved, /^https:\/\/registry\.npmjs\.org\//)
    assert.match(entry.integrity, /^sha512-[A-Za-z0-9+/]+=*$/)
    assert.equal(['BSD-3-Clause', 'BlueOak-1.0.0', 'ISC', 'MIT'].includes(entry.license), true)
    const installed = JSON.parse(
      fs.readFileSync(path.join(repositoryRoot, packagePath, 'package.json'), 'utf8'),
    )
    for (const lifecycle of ['preinstall', 'install', 'postinstall']) {
      assert.equal(installed.scripts?.[lifecycle], undefined, `${packagePath}:${lifecycle}`)
    }
    return `${packagePath}\t${entry.version}\t${entry.license}\t${entry.integrity}`
  })
  const inventory = `${rows.join('\n')}\n`

  assert.equal(closure.length, 47)
  assert.equal(Buffer.byteLength(inventory), 6514)
  assert.equal(
    createHash('sha256').update(inventory).digest('hex'),
    '31d676c0cb1356e60ddae73e9f99df8bd9abb9a779b25a42f238069531f464e9',
  )
})

test('owns deterministic Source Map v3 bytes for only the virtual entry', async () => {
  const source = '.card\n  color red\n'
  const options = {
    style: 'expanded',
    sourceMap: true,
    loadPaths: [],
    providerOptions: { hoistAtrules: false, includeCss: false },
  }
  const result = await compile({ source, options })
  const repeated = await compile({ source, options })

  assert.equal(result.sourceMap, repeated.sourceMap)
  const map = parseSourceMap(result.sourceMap)
  assert.equal(map.version, 3)
  assert.equal(map.file, 'input.css')
  assert.deepEqual(map.sources, ['file:///workspace/input.styl'])
  assert.deepEqual(map.sourcesContent, [source])
  assert.deepEqual(map.names, [])
  assert.equal(map.mappings, 'AAAA;EACE,OAAM,KAAN')
  assert.deepEqual(result.dependencies, [])
  assert.doesNotMatch(result.css, /sourceMappingURL/)
})

test('denies unauthorized project reads, file helpers, and executable plugins', async () => {
  await withFixture(async temporary => {
    const entry = path.join(temporary, 'input.styl')
    const dependency = path.join(temporary, 'secret.styl')
    const json = path.join(temporary, 'secret.json')
    const image = path.join(temporary, 'secret.png')
    const marker = path.join(temporary, 'executed')
    const plugin = path.join(temporary, 'plugin.cjs')
    fs.writeFileSync(entry, 'entry bytes are supplied by the request only\n')
    fs.writeFileSync(dependency, '.secret\n  color fuchsia\n')
    fs.writeFileSync(json, '{"secret":"fuchsia"}\n')
    fs.writeFileSync(image, Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nGQAAAAASUVORK5CYII=',
      'base64',
    ))
    fs.writeFileSync(
      plugin,
      `module.exports = () => require('node:fs').writeFileSync(${JSON.stringify(marker)}, 'x')\n`,
    )
    const sourceUrl = pathToFileURL(entry).href

    for (const source of [
      '@import "secret"\n.entry\n  color red',
      `@import ${JSON.stringify(dependency)}\n.entry\n  color red`,
    ]) {
      await assert.rejects(compile({ source, sourceUrl }), error => {
        assert.equal(rejectsWithCode('STYLUS_IMPORT_POLICY')(error), true)
        assert.equal('css' in error, false)
        assert.doesNotMatch(error.message, /fuchsia|secret bytes/i)
        return true
      })
    }
    const remote = await compile({
      source: '@import "https://example.invalid/theme.css"\n.entry\n  color red',
      sourceUrl,
    })
    assert.equal(
      remote.css,
      '@import "https://example.invalid/theme.css";\n.entry {\n  color: #f00;\n}\n',
    )
    assert.deepEqual(remote.dependencies, [])

    for (const source of [
      `.entry\n  value json(${JSON.stringify(json)})`,
      `.entry\n  value image-size(${JSON.stringify(image)})`,
      `reader = json\n.entry\n  value reader(${JSON.stringify(json)})`,
    ]) {
      await assert.rejects(
        compile({ source, sourceUrl }),
        rejectsWithCode('STYLUS_IMPORT_POLICY'),
      )
    }
    for (const source of [
      `.entry\n  value embedurl(${JSON.stringify(dependency)})`,
      `reader = embedurl\n.entry\n  value reader(${JSON.stringify(dependency)})`,
    ]) {
      const literal = await compile({ source, sourceUrl })
      assert.match(literal.css, /url\(".*secret\.styl"\)/)
      assert.deepEqual(literal.dependencies, [])
    }
    await assert.rejects(
      compile({ source: `.entry\n  value use(${JSON.stringify(plugin)})`, sourceUrl }),
      rejectsWithCode('STYLUS_PLUGIN_DISABLED'),
    )
    await assert.rejects(
      compile({
        source: `loader = use\n.entry\n  value loader(${JSON.stringify(plugin)})`,
        sourceUrl,
      }),
      rejectsWithCode('STYLUS_PLUGIN_DISABLED'),
    )
    assert.equal(fs.existsSync(marker), false)
    const rooted = await compile({
      sourceUrl,
      options: {
        style: 'expanded',
        sourceMap: false,
        loadPaths: [temporary],
        providerOptions: { hoistAtrules: false, includeCss: false },
      },
    })
    assert.equal(rooted.css, '.card {\n  color: #f00;\n}\n')
    assert.deepEqual(rooted.dependencies, [])
  })
})

test('captures output-oriented language helpers as owned diagnostics', async () => {
  const hostRequest = request({
    requestId: 'stylus-diagnostics-001',
    source: [
      '.entry',
      '  first warn("careful")',
      '  second p(1 + 2)',
      '  third trace()',
    ].join('\n'),
  })
  const response = await runPreprocessorHost(hostRequest)

  assert.equal(response.ok, true)
  assert.equal(response.result.css, '.entry {\n  first: ;\n  second: ;\n  third: ;\n}\n')
  assert.deepEqual(response.result.diagnostics, [
    {
      severity: 'warning',
      code: 'stylus.warning',
      message: 'careful',
      sourceUrl: 'file:///workspace/input.styl',
      line: null,
      column: null,
    },
    {
      severity: 'warning',
      code: 'stylus.inspect',
      message: 'inspect: 3',
      sourceUrl: 'file:///workspace/input.styl',
      line: null,
      column: null,
    },
    {
      severity: 'warning',
      code: 'stylus.trace',
      message: 'Stylus trace requested',
      sourceUrl: 'file:///workspace/input.styl',
      line: null,
      column: null,
    },
  ])
})

test('normalizes parse failures and enforces the diagnostic ceiling without CSS', async () => {
  await assert.rejects(
    compile({ source: '.entry\n  color: (' }),
    error => {
      assert.equal(rejectsWithCode('STYLUS_COMPILE_ERROR')(error), true)
      assert.equal(error.message, 'Stylus rejected the input')
      assert.equal('css' in error, false)
      assert.deepEqual(error.diagnostics, [{
        severity: 'error',
        code: 'stylus.compile',
        message: 'expected ")", got "outdent"',
        sourceUrl: 'file:///workspace/input.styl',
        line: 2,
        column: 11,
      }])
      assert.doesNotMatch(JSON.stringify(error), /__zigcss_stylus__|node_modules|stack/i)
      return true
    },
  )

  const source = Array.from({ length: 1001 }, (_, index) => `warn("warning ${index}")`).join('\n')
  await assert.rejects(compile({ source }), error => {
    assert.equal(rejectsWithCode('STYLUS_DIAGNOSTIC_LIMIT')(error), true)
    assert.equal(error.diagnostics.length, 0)
    assert.equal('css' in error, false)
    return true
  })
})

test('rejects invalid requests and pre/post-render cancellation without provider output', async () => {
  await assert.rejects(compile({ syntax: 'less' }), rejectsWithCode('STYLUS_REQUEST_INVALID'))
  await assert.rejects(
    compile({ sourceUrl: 'https://example.com/input.styl' }),
    rejectsWithCode('STYLUS_REQUEST_INVALID'),
  )
  await assert.rejects(
    compile({ options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: { functions: {} },
    } }),
    rejectsWithCode('STYLUS_REQUEST_INVALID'),
  )
  await assert.rejects(
    compile({ options: {
      style: 'expanded',
      sourceMap: false,
      loadPaths: [],
      providerOptions: { hoistAtrules: false, includeCss: false },
      plugins: [],
    } }),
    rejectsWithCode('STYLUS_REQUEST_INVALID'),
  )

  const before = new AbortController()
  before.abort()
  await assert.rejects(compile({}, before.signal), rejectsWithCode('STYLUS_CANCELLED'))

  let reads = 0
  const after = {
    get aborted() {
      reads += 1
      return reads >= 2
    },
  }
  await assert.rejects(compile({}, after), rejectsWithCode('STYLUS_CANCELLED'))
})

test('keeps repeated, parallel, and real framed-host rendering deterministic', async () => {
  const jobs = Array.from({ length: 12 }, (_, index) => compile({
    source: `.item-${index}\n  z-index ${index}`,
  }))
  const results = await Promise.all(jobs)
  for (let index = 0; index < results.length; index += 1) {
    assert.equal(results[index].css, `.item-${index} {\n  z-index: ${index};\n}\n`)
    assert.deepEqual(results[index].diagnostics, [])
    assert.deepEqual(results[index].dependencies, [])
  }

  const hostRequest = request({
    requestId: 'stylus-host-001',
    source: 'tone = rebeccapurple\n.host\n  color tone',
  })
  const response = await runPreprocessorHost(hostRequest)
  assert.deepEqual(response, {
    protocol: 'zigcss-preprocessor-v1',
    requestId: 'stylus-host-001',
    ok: true,
    result: {
      css: '.host {\n  color: #639;\n}\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    },
  })
})

test('documents the virtual Stylus boundary and canonical product admission', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'callback-based `renderer.render` API through an owned Promise boundary',
    'stable non-file virtual filename',
    '`json()`, `image-size()`, and `embedurl()`',
    '`warn()`, `p()`, and `trace()`',
    '`STYLUS-012`',
    'graduate `.styl` through the 0.5 npm CLI/API',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
