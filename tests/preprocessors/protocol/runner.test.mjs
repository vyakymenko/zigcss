import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  runPreprocessorHost,
  sanitizedHostEnvironment,
} from '../../../preprocessor/runner.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'
import { makeRequest } from './helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const fixtureHost = path.join(repositoryRoot, 'tests/preprocessors/fixtures/child-behavior.mjs')
const sassFixtureDirectory = path.join(repositoryRoot, 'tests/preprocessors/sass/fixtures')

function rejectsWithCode(code) {
  return error => error?.code === code
}

test('process supervisor uses framed stdin without shell interpretation', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-host-injection-'))
  try {
    const marker = path.join(temporary, 'should-not-exist')
    const source = `$(touch ${marker}); .card { color: red; }`
    const response = await runPreprocessorHost(makeRequest({ source }), {
      hostPath: fixtureHost,
      hostArguments: ['success'],
      timeoutMs: 1000,
    })
    assert.equal(response.ok, true)
    assert.equal(response.result.css, source)
    assert.equal(fs.existsSync(marker), false)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('production host reaches only the admitted internal Dart Sass and Less adapters', async () => {
  const response = await runPreprocessorHost(makeRequest({
    options: {
      style: 'compressed',
      sourceMap: true,
      loadPaths: [],
      providerOptions: { charset: true, quietDeps: false, verbose: false },
    },
  }), { timeoutMs: 5000 })
  assert.equal(response.result.css, '.card{color:red}')
  assert.equal(parseSourceMap(response.result.sourceMap).sources[0], 'file:///workspace/input.scss')
  assert.deepEqual(response.result.diagnostics, [])
  assert.deepEqual(response.result.dependencies, [])

  const imported = await runPreprocessorHost(makeRequest({
    source: '@use "tokens";\n.card { color: tokens.$accent; }',
    sourceUrl: pathToFileURL(path.join(sassFixtureDirectory, 'input.scss')).href,
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [sassFixtureDirectory],
      providerOptions: { charset: true, quietDeps: false, verbose: false },
    },
  }), { timeoutMs: 5000 })
  assert.equal(imported.ok, true)
  assert.equal(imported.result.css, '.card {\n  color: rebeccapurple;\n}')
  assert.deepEqual(imported.result.dependencies, [{
    url: pathToFileURL(path.join(sassFixtureDirectory, '_tokens.scss')).href,
    kind: 'reference',
  }])
  assert.deepEqual(new Set(parseSourceMap(imported.result.sourceMap).sources), new Set([
    pathToFileURL(path.join(sassFixtureDirectory, 'input.scss')).href,
    pathToFileURL(path.join(sassFixtureDirectory, '_tokens.scss')).href,
  ]))

  const rejected = await runPreprocessorHost(makeRequest({
    source: '$color: ;\n.card { color: $color; }',
  }), { timeoutMs: 5000 })
  assert.equal(rejected.ok, false)
  assert.equal(rejected.error.code, 'SASS_COMPILE_ERROR')
  assert.equal(rejected.error.diagnostics[0].message, 'Expected expression.')
  assert.equal('result' in rejected, false)

  const less = await runPreprocessorHost(makeRequest({
    provider: 'less',
    syntax: 'less',
    source: '@color: red; .card { color: @color; }',
    sourceUrl: 'file:///workspace/input.less',
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [],
      providerOptions: {
        math: 'parens-division',
        quietDeprecations: false,
        rewriteUrls: 'off',
        strictUnits: false,
      },
    },
  }), { timeoutMs: 5000 })
  assert.equal(less.ok, true)
  assert.equal(less.result.css, '.card {\n  color: red;\n}\n')
  assert.equal(parseSourceMap(less.result.sourceMap).sources[0], 'file:///workspace/input.less')
  assert.deepEqual(less.result.diagnostics, [])
  assert.deepEqual(less.result.dependencies, [])

  const unavailable = await runPreprocessorHost(makeRequest({
    provider: 'stylus',
    syntax: 'stylus',
    source: 'color = red\n.card\n  color color\n',
    sourceUrl: 'file:///workspace/input.styl',
    options: {
      style: 'expanded',
      sourceMap: true,
      loadPaths: [],
      providerOptions: {},
    },
  }), { timeoutMs: 5000 })
  assert.equal(unavailable.ok, false)
  assert.equal(unavailable.error.code, 'HOST_PROVIDER_UNAVAILABLE')
  assert.equal('result' in unavailable, false)
})

test('process supervisor kills timeout and stdout overflow and rejects stderr, malformed, extra, and nonzero exits', async () => {
  await assert.rejects(
    runPreprocessorHost(makeRequest(), {
      hostPath: fixtureHost,
      hostArguments: ['hang'],
      timeoutMs: 50,
    }),
    rejectsWithCode('HOST_PROCESS_TIMEOUT'),
  )
  await assert.rejects(
    runPreprocessorHost(makeRequest(), {
      hostPath: fixtureHost,
      hostArguments: ['flood'],
      maxStdoutBytes: 1024,
      timeoutMs: 1000,
    }),
    rejectsWithCode('HOST_STDOUT_LIMIT'),
  )
  for (const [mode, code] of [
    ['stderr', 'HOST_STDERR_OUTPUT'],
    ['malformed', 'HOST_RESPONSE_INVALID'],
    ['extra', 'HOST_RESPONSE_INVALID'],
    ['wrong-id', 'HOST_RESPONSE_INVALID'],
    ['exit', 'HOST_PROCESS_EXIT'],
  ]) {
    await assert.rejects(
      runPreprocessorHost(makeRequest(), {
        hostPath: fixtureHost,
        hostArguments: [mode],
        timeoutMs: 1000,
      }),
      rejectsWithCode(code),
      mode,
    )
  }
})

test('host environment is deterministic and strips Node injection surfaces', async () => {
  assert.deepEqual(
    sanitizedHostEnvironment({
      HOME: '/secret/home',
      NODE_OPTIONS: '--require=/tmp/inject.cjs',
      NODE_PATH: '/tmp/modules',
      PATH: '/untrusted/bin',
      SystemRoot: 'C:\\Windows',
      TMPDIR: '/private/tmp',
    }),
    {
      LANG: 'C',
      LC_ALL: 'C',
      TZ: 'UTC',
      SystemRoot: 'C:\\Windows',
      TMPDIR: '/private/tmp',
    },
  )

  const response = await runPreprocessorHost(makeRequest(), {
    hostPath: fixtureHost,
    hostArguments: ['environment'],
    timeoutMs: 1000,
  })
  const environment = JSON.parse(response.result.css)
  const keys = Object.keys(environment)
  for (const forbidden of ['HOME', 'NODE_OPTIONS', 'NODE_PATH', 'PATH']) {
    assert.equal(keys.includes(forbidden), false, forbidden)
  }
  for (const key of keys) {
    assert.equal(
      [
        'LANG',
        'LC_ALL',
        'TZ',
        'SystemRoot',
        'WINDIR',
        'TMP',
        'TEMP',
        'TMPDIR',
      ].includes(key),
      true,
      key,
    )
  }
  assert.equal(environment.LANG, 'C')
  assert.equal(environment.LC_ALL, 'C')
  assert.equal(environment.TZ, 'UTC')
  assert.equal('__CF_USER_TEXT_ENCODING' in environment, false)
})

test('host executable must be an absolute regular non-symlink file', { skip: process.platform === 'win32' }, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-host-path-'))
  try {
    const link = path.join(temporary, 'host.mjs')
    fs.symlinkSync(fixtureHost, link)
    await assert.rejects(
      runPreprocessorHost(makeRequest(), {
        hostPath: link,
        hostArguments: ['success'],
        timeoutMs: 1000,
      }),
      rejectsWithCode('HOST_PATH_INVALID'),
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
