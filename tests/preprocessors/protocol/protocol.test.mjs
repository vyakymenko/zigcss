import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  MAX_REQUEST_FRAME_BYTES,
  MAX_SOURCE_BYTES,
  PROTOCOL_VERSION,
  decodeSingleFrame,
  encodeFrame,
  validateRequest,
  validateResponse,
} from '../../../preprocessor/protocol.mjs'
import {
  CANONICAL_PROVIDERS,
  PROVIDER_SYNTAXES,
} from '../../../preprocessor/provider-registry.mjs'
import { makeRequest } from './helpers.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function hasCode(code) {
  return error => error?.code === code
}

test('protocol and production provider metadata are exact and matrix-bound', () => {
  const matrix = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'tests/formats/matrix.json'), 'utf8'),
  )
  assert.equal(PROTOCOL_VERSION, 'zigcss-preprocessor-v1')
  assert.deepEqual(CANONICAL_PROVIDERS, matrix.canonicalProviders)
  assert.deepEqual(PROVIDER_SYNTAXES, {
    'dart-sass': ['scss', 'sass'],
    less: ['less'],
    stylus: ['stylus'],
  })
})

test('host core has no network, shell, eval, or ambient module-loading authority', () => {
  const hostSources = [
    'preprocessor/protocol.mjs',
    'preprocessor/environment.mjs',
    'preprocessor/resolver.mjs',
    'preprocessor/metadata.mjs',
    'preprocessor/source-map.mjs',
    'preprocessor/providers/dart-sass.mjs',
    'preprocessor/provider-registry.mjs',
    'preprocessor/host-core.mjs',
    'preprocessor/host.mjs',
  ].map(relative => fs.readFileSync(path.join(repositoryRoot, relative), 'utf8')).join('\n')
  const runner = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/runner.mjs'), 'utf8')

  assert.doesNotMatch(hostSources, /node:(?:child_process|http|https|net|tls|dgram)/)
  assert.doesNotMatch(hostSources, /\beval\s*\(|new\s+Function\s*\(|import\s*\(/)
  assert.match(runner, /spawn\(process\.execPath/)
  assert.match(runner, /shell: false/)
  assert.match(runner, /env: sanitizedHostEnvironment\(\)/)
  assert.doesNotMatch(runner, /exec(?:File|Sync)?\s*\(|spawnSync\s*\(/)
})

test('protocol documentation publishes the wire, limit, lifecycle, and current availability boundaries', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'one-request-per-process protocol',
    'four-byte unsigned big-endian payload length',
    'Any stderr byte is an operational failure',
    '10 MiB UTF-8',
    '20 MiB UTF-8',
    '`shell: false`',
    'strips `PATH`, `HOME`, `NODE_OPTIONS`, and `NODE_PATH`',
    'still publicly unavailable',
    'never command arguments or shell text',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})

test('one length-prefixed frame round-trips and rejects truncation, overflow, and extras', () => {
  const request = makeRequest()
  const frame = encodeFrame(request, { maxBytes: MAX_REQUEST_FRAME_BYTES })
  assert.deepEqual(decodeSingleFrame(frame, { maxBytes: MAX_REQUEST_FRAME_BYTES }), request)

  assert.throws(
    () => decodeSingleFrame(frame.subarray(0, frame.length - 1), { maxBytes: MAX_REQUEST_FRAME_BYTES }),
    hasCode('HOST_PROTOCOL_TRUNCATED'),
  )
  assert.throws(
    () => decodeSingleFrame(Buffer.concat([frame, frame]), { maxBytes: MAX_REQUEST_FRAME_BYTES }),
    hasCode('HOST_PROTOCOL_EXTRA_BYTES'),
  )

  const oversized = Buffer.alloc(4)
  oversized.writeUInt32BE(MAX_REQUEST_FRAME_BYTES + 1)
  assert.throws(
    () => decodeSingleFrame(oversized, { maxBytes: MAX_REQUEST_FRAME_BYTES }),
    hasCode('HOST_PROTOCOL_FRAME_LIMIT'),
  )
})

test('request validation is closed, provider-aware, and byte bounded', () => {
  assert.deepEqual(validateRequest(makeRequest()), makeRequest())
  assert.deepEqual(
    validateRequest(
      makeRequest({
        provider: 'dart-sass',
        syntax: 'sass',
        sourceUrl: null,
        options: { style: 'compressed', sourceMap: false, loadPaths: [] },
      }),
    ),
    makeRequest({
      provider: 'dart-sass',
      syntax: 'sass',
      sourceUrl: null,
      options: { style: 'compressed', sourceMap: false, loadPaths: [] },
    }),
  )

  const invalid = [
    [makeRequest({ protocol: 'zigcss-preprocessor-v2' }), 'HOST_PROTOCOL_VERSION'],
    [makeRequest({ requestId: '../escape' }), 'HOST_REQUEST_ID'],
    [makeRequest({ operation: 'evaluate' }), 'HOST_REQUEST_SHAPE'],
    [makeRequest({ provider: 'unknown' }), 'HOST_PROVIDER_UNKNOWN'],
    [makeRequest({ provider: 'less', syntax: 'scss' }), 'HOST_SYNTAX_PROVIDER_MISMATCH'],
    [makeRequest({ sourceUrl: 'https://example.com/input.scss' }), 'HOST_SOURCE_URL'],
    [makeRequest({ sourceUrl: 'file://server/share/input.scss' }), 'HOST_SOURCE_URL'],
    [makeRequest({ sourceUrl: 'file:///workspace/input.scss?raw=1' }), 'HOST_SOURCE_URL'],
    [makeRequest({ options: { style: 'tiny', sourceMap: true, loadPaths: [] } }), 'HOST_OPTIONS'],
    [makeRequest({ options: { style: 'expanded', sourceMap: 'yes', loadPaths: [] } }), 'HOST_OPTIONS'],
    [makeRequest({ options: { style: 'expanded', sourceMap: true, loadPaths: ['relative'] } }), 'HOST_OPTIONS'],
    [makeRequest({ options: { style: 'expanded', sourceMap: true, loadPaths: ['/one', '/one'] } }), 'HOST_OPTIONS'],
    [makeRequest({ options: { style: 'expanded', sourceMap: true, loadPaths: [], plugin: 'x' } }), 'HOST_OPTIONS'],
    [{ ...makeRequest(), unexpected: true }, 'HOST_REQUEST_SHAPE'],
  ]
  for (const [request, code] of invalid) {
    assert.throws(() => validateRequest(request), hasCode(code), code)
  }

  assert.throws(
    () => validateRequest(makeRequest({ source: 'a'.repeat(MAX_SOURCE_BYTES + 1) })),
    hasCode('HOST_SOURCE_LIMIT'),
  )
})

test('response validation admits one complete result or one css-free failure', () => {
  const success = {
    protocol: PROTOCOL_VERSION,
    requestId: 'request-001',
    ok: true,
    result: {
      css: '.card { color: red; }\n',
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    },
  }
  const failure = {
    protocol: PROTOCOL_VERSION,
    requestId: 'request-001',
    ok: false,
    error: {
      code: 'HOST_PROVIDER_FAILURE',
      message: 'Canonical provider compilation failed',
      diagnostics: [],
    },
  }
  assert.deepEqual(validateResponse(success), success)
  assert.deepEqual(validateResponse(failure), failure)
  assert.throws(
    () => validateResponse({ ...failure, result: success.result }),
    hasCode('HOST_RESPONSE_SHAPE'),
  )
  assert.throws(
    () => validateResponse({ ...success, error: failure.error }),
    hasCode('HOST_RESPONSE_SHAPE'),
  )
  assert.throws(
    () => validateResponse({ ...success, requestId: null }),
    hasCode('HOST_RESPONSE_SHAPE'),
  )
  assert.throws(
    () => validateResponse({ ...failure, css: '.partial{}' }),
    hasCode('HOST_RESPONSE_SHAPE'),
  )
  assert.throws(
    () => validateResponse({
      ...success,
      result: {
        ...success.result,
        dependencies: [{ url: null, kind: 'import' }],
      },
    }),
    hasCode('HOST_RESPONSE_SHAPE'),
  )
})
