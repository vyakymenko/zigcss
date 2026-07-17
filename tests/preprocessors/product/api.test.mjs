import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  ZigCssCompileError,
  compileFileWithRuntime,
  compileStringWithRuntime,
} from '../../../preprocessor/product-api.mjs'
import { runZigCssCore } from '../../../preprocessor/core-runner.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const binaryPath = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const runtime = Object.freeze({ binaryPath, runCore: runZigCssCore, runHost: runPreprocessorHost })

test('root npm API entrypoint exposes only the supported compile contract', async () => {
  const api = await import('../../../api.mjs')
  assert.deepEqual(Object.keys(api).sort(), [
    'SUPPORTED_SYNTAXES',
    'ZigCssCompileError',
    'compileFile',
    'compileString',
    'detectSyntax',
  ])
})

test('npm API routes CSS directly through the native core', async () => {
  const result = await compileStringWithRuntime(
    '.card { color: red; }',
    { syntax: 'css', format: 'minified', sourceMap: true },
    {
      ...runtime,
      runHost: async () => {
        throw new Error('CSS must not enter the preprocessor host')
      },
    },
  )
  assert.equal(result.css, '.card{color:red}')
  assert.deepEqual(result.diagnostics, [])
  assert.deepEqual(result.dependencies, [])
  assert.equal(parseSourceMap(result.sourceMap).sources.length, 1)
})

test('npm API validates all four canonical preprocessor syntaxes through ZigCSS', async () => {
  const cases = [
    ['scss', '$color: red; .card { color: $color; }', '.card{color:red}'],
    ['sass', '$color: red\n.card\n  color: $color\n', '.card{color:red}'],
    ['less', '@color: red; .card { color: @color; }', '.card{color:red}'],
    ['stylus', 'color = red\n.card\n  color color\n', '.card{color:#f00}'],
  ]
  for (const [syntax, source, expected] of cases) {
    const sourceUrl = `file:///workspace/input.${syntax === 'stylus' ? 'styl' : syntax}`
    const result = await compileStringWithRuntime(source, {
      syntax,
      sourceUrl,
      format: 'minified',
      sourceMap: true,
    }, runtime)
    assert.equal(result.css, expected, syntax)
    assert.deepEqual(result.diagnostics, [], syntax)
    assert.deepEqual(result.dependencies, [], syntax)
    assert.deepEqual(parseSourceMap(result.sourceMap).sources, [sourceUrl], syntax)
  }
})

test('npm API provider and generated-CSS failures expose diagnostics but never CSS', async () => {
  await assert.rejects(
    compileStringWithRuntime('$color: ; .card { color: $color; }', {
      syntax: 'scss',
      sourceUrl: 'file:///workspace/input.scss',
    }, runtime),
    error => {
      assert.equal(error instanceof ZigCssCompileError, true)
      assert.equal(error.code, 'SASS_COMPILE_ERROR')
      assert.equal(error.diagnostics[0].message, 'Expected expression.')
      assert.equal('css' in error, false)
      return true
    },
  )

  const invalidHost = async request => ({
    protocol: request.protocol,
    requestId: request.requestId,
    ok: true,
    result: {
      css: '.card { broken; color: red; }',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    },
  })
  await assert.rejects(
    compileStringWithRuntime('.card {}', {
      syntax: 'scss',
      sourceUrl: 'file:///workspace/input.scss',
    }, { ...runtime, runHost: invalidHost }),
    error => {
      assert.equal(error instanceof ZigCssCompileError, true)
      assert.equal(error.code, 'CORE_COMPILE_ERROR')
      assert.equal(error.diagnostics[0].code, 'CSS0007')
      assert.equal('css' in error, false)
      return true
    },
  )
})

test('npm API schema and provider options are closed before process launch', async () => {
  const invalid = [
    [{ syntax: 'unknown' }, 'API_OPTIONS'],
    [{ syntax: 'scss', sourceMap: true, optimize: true }, 'API_OPTIONS'],
    [{ syntax: 'css', loadPaths: ['/tmp'] }, 'API_OPTIONS'],
    [{ syntax: 'less', providerOptions: { javascriptEnabled: true } }, 'API_OPTIONS'],
    [{ syntax: 'stylus', providerOptions: { use: './plugin.js' } }, 'API_OPTIONS'],
    [{ syntax: 'scss', unexpected: true }, 'API_OPTIONS'],
  ]
  for (const [options, code] of invalid) {
    await assert.rejects(
      compileStringWithRuntime('.a{}', options, runtime),
      error => error instanceof ZigCssCompileError && error.code === code,
    )
  }
})

test('npm API mixed parallel compilation is deterministic', async () => {
  const jobs = Array.from({ length: 8 }, (_, index) => {
    const syntax = ['scss', 'sass', 'less', 'stylus'][index % 4]
    const sources = {
      scss: '$n: 1; .item { z-index: $n; }',
      sass: '$n: 1\n.item\n  z-index: $n\n',
      less: '@n: 1; .item { z-index: @n; }',
      stylus: 'n = 1\n.item\n  z-index n\n',
    }
    return compileStringWithRuntime(sources[syntax], {
      syntax,
      sourceUrl: `file:///workspace/input-${index}.${syntax === 'stylus' ? 'styl' : syntax}`,
      format: 'minified',
    }, runtime)
  })
  const results = await Promise.all(jobs)
  assert.deepEqual(new Set(results.map(result => result.css)), new Set(['.item{z-index:1}']))
})

test('npm file API detects each syntax and confines entry-relative imports', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-files-'))
  try {
    const cases = [
      {
        entry: 'input.scss',
        dependency: '_tokens.scss',
        dependencySource: '$color: red;',
        source: '@use "tokens"; .card { color: tokens.$color; }',
      },
      {
        entry: 'input.sass',
        dependency: '_tokens.sass',
        dependencySource: '$color: red',
        source: '@use "tokens"\n.card\n  color: tokens.$color\n',
      },
      {
        entry: 'input.less',
        dependency: 'tokens.less',
        dependencySource: '@color: red;',
        source: '@import "tokens"; .card { color: @color; }',
      },
      {
        entry: 'input.styl',
        dependency: 'tokens.styl',
        dependencySource: 'color = red\n',
        source: '@import "tokens"\n.card\n  color color\n',
      },
    ]
    for (const [index, fixture] of cases.entries()) {
      const caseDirectory = path.join(temporary, String(index))
      fs.mkdirSync(caseDirectory)
      const entry = path.join(caseDirectory, fixture.entry)
      const dependency = path.join(caseDirectory, fixture.dependency)
      fs.writeFileSync(entry, fixture.source)
      fs.writeFileSync(dependency, fixture.dependencySource)
      const result = await compileFileWithRuntime(entry, {
        format: 'minified',
        sourceMap: true,
      }, runtime)
      assert.match(result.css, /^\.card\{color:(?:red|#f00)\}$/)
      assert.deepEqual(result.dependencies, [{
        url: pathToFileURL(fs.realpathSync(dependency)).href,
        kind: fixture.entry.endsWith('.less') || fixture.entry.endsWith('.styl')
          ? 'import'
          : 'reference',
      }])
      assert.equal(
        parseSourceMap(result.sourceMap).sources.includes(pathToFileURL(fs.realpathSync(entry)).href),
        true,
      )
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm file API rejects ambiguous extensions, mismatches, links, and invalid UTF-8', {
  skip: process.platform === 'win32',
}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-files-negative-'))
  try {
    const scss = path.join(temporary, 'input.scss')
    fs.writeFileSync(scss, '.a{}')
    await assert.rejects(
      compileFileWithRuntime(scss, { syntax: 'less' }, runtime),
      error => error instanceof ZigCssCompileError && error.code === 'API_OPTIONS',
    )

    const unknown = path.join(temporary, 'input.txt')
    fs.writeFileSync(unknown, '.a{}')
    await assert.rejects(
      compileFileWithRuntime(unknown, {}, runtime),
      error => error instanceof ZigCssCompileError && error.code === 'API_OPTIONS',
    )

    const link = path.join(temporary, 'linked.scss')
    fs.symlinkSync(scss, link)
    await assert.rejects(
      compileFileWithRuntime(link, {}, runtime),
      error => error instanceof ZigCssCompileError && error.code === 'RESOLVER_SYMLINK',
    )

    const invalid = path.join(temporary, 'invalid.less')
    fs.writeFileSync(invalid, Buffer.from([0xff, 0xfe]))
    await assert.rejects(
      compileFileWithRuntime(invalid, {}, runtime),
      error => error instanceof ZigCssCompileError && error.code === 'API_INPUT_ENCODING',
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
