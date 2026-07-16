import assert from 'node:assert/strict'
import test from 'node:test'
import {
  MAX_REQUEST_FRAME_BYTES,
  PROTOCOL_VERSION,
  decodeSingleFrame,
  encodeFrame,
  validateResponse,
} from '../../../preprocessor/protocol.mjs'
import { processHostInput } from '../../../preprocessor/host-core.mjs'
import { makeRequest } from './helpers.mjs'

function registryWith(compile) {
  return new Map([
    [
      'dart-sass',
      {
        syntaxes: ['scss', 'sass'],
        compile,
      },
    ],
  ])
}

async function exchange(request, options = {}) {
  const input = encodeFrame(request, { maxBytes: MAX_REQUEST_FRAME_BYTES })
  const output = await processHostInput(input, options)
  return validateResponse(decodeSingleFrame(output))
}

test('host returns one complete fake-provider result without interpreting source bytes', async () => {
  const request = makeRequest({ source: '$(touch should-never-run); .card { color: red; }' })
  const response = await exchange(request, {
    registry: registryWith(async received => ({
      css: received.source,
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    })),
    providerTimeoutMs: 100,
  })
  assert.deepEqual(response, {
    protocol: PROTOCOL_VERSION,
    requestId: request.requestId,
    ok: true,
    result: {
      css: request.source,
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    },
  })
})

test('provider throws, timeouts, invalid results, and output overflow fail without css', async () => {
  const secret = 'internal stack and filesystem secret'
  const thrown = await exchange(makeRequest(), {
    registry: registryWith(async () => {
      throw new Error(secret)
    }),
    providerTimeoutMs: 100,
  })
  assert.equal(thrown.ok, false)
  assert.equal(thrown.error.code, 'HOST_PROVIDER_FAILURE')
  assert.doesNotMatch(thrown.error.message, /secret|stack|filesystem/i)
  assert.equal('result' in thrown, false)

  let providerWasAborted = false
  const timedOut = await exchange(makeRequest(), {
    registry: registryWith((_request, { signal }) => {
      signal.addEventListener('abort', () => {
        providerWasAborted = true
      }, { once: true })
      return new Promise(() => {})
    }),
    providerTimeoutMs: 20,
  })
  assert.equal(timedOut.ok, false)
  assert.equal(timedOut.error.code, 'HOST_PROVIDER_TIMEOUT')
  assert.equal('result' in timedOut, false)
  assert.equal(providerWasAborted, true)

  const invalid = await exchange(makeRequest(), {
    registry: registryWith(async () => ({ css: 42 })),
    providerTimeoutMs: 100,
  })
  assert.equal(invalid.ok, false)
  assert.equal(invalid.error.code, 'HOST_INVALID_PROVIDER_RESULT')
  assert.equal('result' in invalid, false)

  const overflow = await exchange(makeRequest(), {
    registry: registryWith(async () => ({
      css: 'x'.repeat(2048),
      sourceMap: null,
      diagnostics: [],
      dependencies: [],
    })),
    providerTimeoutMs: 100,
    maxResponseBytes: 512,
  })
  assert.equal(overflow.ok, false)
  assert.equal(overflow.error.code, 'HOST_OUTPUT_LIMIT')
  assert.equal('result' in overflow, false)
})

test('missing providers and malformed or extra input produce one framed failure', async () => {
  const unavailable = await exchange(makeRequest(), {
    registry: new Map(),
    providerTimeoutMs: 100,
  })
  assert.equal(unavailable.ok, false)
  assert.equal(unavailable.error.code, 'HOST_PROVIDER_UNAVAILABLE')
  assert.equal(unavailable.requestId, 'request-001')

  const frame = encodeFrame(makeRequest(), { maxBytes: MAX_REQUEST_FRAME_BYTES })
  const malformedOutput = await processHostInput(Buffer.concat([frame, frame]), {
    registry: new Map(),
  })
  const malformed = validateResponse(decodeSingleFrame(malformedOutput))
  assert.equal(malformed.ok, false)
  assert.equal(malformed.error.code, 'HOST_PROTOCOL_EXTRA_BYTES')
  assert.equal(malformed.requestId, null)
  assert.equal('result' in malformed, false)
})
