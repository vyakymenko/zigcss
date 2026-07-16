import {
  DEFAULT_PROVIDER_TIMEOUT_MS,
  MAX_REQUEST_FRAME_BYTES,
  MAX_RESPONSE_FRAME_BYTES,
  PROTOCOL_VERSION,
  ProtocolError,
  decodeSingleFrame,
  encodeFrame,
  validateRequest,
  validateResponse,
} from './protocol.mjs'
import { ProviderFailure } from './metadata.mjs'

const messages = {
  HOST_INVALID_PROVIDER_RESULT: 'Canonical provider returned an invalid result',
  HOST_OUTPUT_LIMIT: 'Canonical provider output exceeded its byte limit',
  HOST_PROVIDER_FAILURE: 'Canonical provider compilation failed',
  HOST_PROVIDER_TIMEOUT: 'Canonical provider exceeded its execution limit',
  HOST_PROVIDER_UNAVAILABLE: 'Canonical provider is not installed in this host',
}

function failure(requestId, code, message = 'Preprocessor request was rejected', diagnostics = []) {
  return {
    protocol: PROTOCOL_VERSION,
    requestId,
    ok: false,
    error: { code, message, diagnostics },
  }
}

function failureFrame(requestId, code, maxResponseBytes, message, diagnostics = []) {
  const response = failure(requestId, code, message ?? messages[code], diagnostics)
  validateResponse(response)
  return encodeFrame(response, { maxBytes: maxResponseBytes })
}

function validateOptions(registry, providerTimeoutMs, maxResponseBytes) {
  if (!(registry instanceof Map)) throw new TypeError('registry must be a Map')
  if (!Number.isSafeInteger(providerTimeoutMs) || providerTimeoutMs < 1 || providerTimeoutMs > 30_000) {
    throw new TypeError('providerTimeoutMs must be between 1 and 30000')
  }
  if (!Number.isSafeInteger(maxResponseBytes) || maxResponseBytes < 256) {
    throw new TypeError('maxResponseBytes must be at least 256')
  }
}

async function compileWithTimeout(compile, request, timeoutMs) {
  const controller = new AbortController()
  let timer
  const timeout = new Promise(resolve => {
    timer = setTimeout(() => {
      controller.abort()
      resolve({ timedOut: true })
    }, timeoutMs)
  })
  const compilation = Promise.resolve()
    .then(() => compile(request, { signal: controller.signal }))
    .then(result => ({ timedOut: false, result }))
  try {
    return await Promise.race([compilation, timeout])
  } finally {
    clearTimeout(timer)
  }
}

export async function processHostInput(
  input,
  {
    registry,
    providerTimeoutMs = DEFAULT_PROVIDER_TIMEOUT_MS,
    maxResponseBytes = MAX_RESPONSE_FRAME_BYTES,
  } = {},
) {
  validateOptions(registry, providerTimeoutMs, maxResponseBytes)
  let request
  try {
    request = validateRequest(
      decodeSingleFrame(input, { maxBytes: MAX_REQUEST_FRAME_BYTES }),
    )
  } catch (error) {
    const code = error instanceof ProtocolError ? error.code : 'HOST_REQUEST_SHAPE'
    return failureFrame(null, code, maxResponseBytes, 'Preprocessor request was rejected')
  }

  const provider = registry.get(request.provider)
  if (provider === undefined || typeof provider.compile !== 'function') {
    return failureFrame(request.requestId, 'HOST_PROVIDER_UNAVAILABLE', maxResponseBytes)
  }
  if (!Array.isArray(provider.syntaxes) || !provider.syntaxes.includes(request.syntax)) {
    return failureFrame(request.requestId, 'HOST_PROVIDER_UNAVAILABLE', maxResponseBytes)
  }

  let outcome
  try {
    outcome = await compileWithTimeout(provider.compile, request, providerTimeoutMs)
  } catch (error) {
    if (error instanceof ProviderFailure) {
      try {
        return failureFrame(
          request.requestId,
          error.code,
          maxResponseBytes,
          error.message,
          error.diagnostics,
        )
      } catch (frameError) {
        const code = frameError instanceof ProtocolError && frameError.code === 'HOST_PROTOCOL_FRAME_LIMIT'
          ? 'HOST_OUTPUT_LIMIT'
          : 'HOST_PROVIDER_FAILURE'
        return failureFrame(request.requestId, code, maxResponseBytes)
      }
    }
    return failureFrame(request.requestId, 'HOST_PROVIDER_FAILURE', maxResponseBytes)
  }
  if (outcome.timedOut) {
    return failureFrame(request.requestId, 'HOST_PROVIDER_TIMEOUT', maxResponseBytes)
  }

  const response = {
    protocol: PROTOCOL_VERSION,
    requestId: request.requestId,
    ok: true,
    result: outcome.result,
  }
  try {
    validateResponse(response)
  } catch (error) {
    const code = error instanceof ProtocolError && error.code === 'HOST_OUTPUT_LIMIT'
      ? 'HOST_OUTPUT_LIMIT'
      : 'HOST_INVALID_PROVIDER_RESULT'
    return failureFrame(request.requestId, code, maxResponseBytes)
  }
  try {
    return encodeFrame(response, { maxBytes: maxResponseBytes })
  } catch (error) {
    if (error instanceof ProtocolError && error.code === 'HOST_PROTOCOL_FRAME_LIMIT') {
      return failureFrame(request.requestId, 'HOST_OUTPUT_LIMIT', maxResponseBytes)
    }
    return failureFrame(request.requestId, 'HOST_INVALID_PROVIDER_RESULT', maxResponseBytes)
  }
}
