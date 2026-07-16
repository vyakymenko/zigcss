import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  runPreprocessorHost,
  sanitizedHostEnvironment,
} from '../../../preprocessor/runner.mjs'
import { makeRequest } from './helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const fixtureHost = path.join(repositoryRoot, 'tests/preprocessors/fixtures/child-behavior.mjs')

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

test('production host recognizes canonical ids but keeps providers unavailable before adapters land', async () => {
  const response = await runPreprocessorHost(makeRequest(), { timeoutMs: 1000 })
  assert.equal(response.ok, false)
  assert.equal(response.error.code, 'HOST_PROVIDER_UNAVAILABLE')
  assert.equal('result' in response, false)
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
