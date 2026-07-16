import path from 'node:path'

export const PROTOCOL_VERSION = 'zigcss-preprocessor-v1'
export const MAX_SOURCE_BYTES = 10 * 1024 * 1024
export const MAX_OUTPUT_BYTES = 20 * 1024 * 1024
export const MAX_REQUEST_FRAME_BYTES = MAX_SOURCE_BYTES + 64 * 1024
export const MAX_RESPONSE_FRAME_BYTES = MAX_OUTPUT_BYTES + 256 * 1024
export const MAX_STDERR_BYTES = 64 * 1024
export const DEFAULT_PROVIDER_TIMEOUT_MS = 8_000
export const DEFAULT_PROCESS_TIMEOUT_MS = 10_000
export const MAX_PROCESS_TIMEOUT_MS = 30_000

const MAX_REQUEST_ID_BYTES = 64
const MAX_URL_BYTES = 4096
const MAX_LOAD_PATHS = 64
const MAX_DIAGNOSTICS = 1000
const MAX_DEPENDENCIES = 4096
const MAX_MESSAGE_BYTES = 4096

const providerSyntaxes = {
  'dart-sass': new Set(['scss', 'sass']),
  less: new Set(['less']),
  stylus: new Set(['stylus']),
}

export class ProtocolError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'ProtocolError'
    this.code = code
  }
}

function fail(code, message) {
  throw new ProtocolError(code, message)
}

function byteLength(value) {
  return Buffer.byteLength(value, 'utf8')
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function requireExactKeys(value, expected, code, label) {
  if (!isPlainObject(value)) fail(code, `${label} must be an object`)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(code, `${label} has unexpected or missing fields`)
  }
}

function requireBoundedString(value, maximum, code, label, allowEmpty = false) {
  if (typeof value !== 'string' || (!allowEmpty && value.length === 0) || byteLength(value) > maximum) {
    fail(code, `${label} must be a bounded string`)
  }
}

function requireInteger(value, minimum, maximum, code, label) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(code, `${label} must be a bounded integer`)
  }
}

function validateFrameLimit(maxBytes) {
  requireInteger(maxBytes, 1, 0xffffffff, 'HOST_PROTOCOL_FRAME_LIMIT', 'frame limit')
}

export function encodeFrame(value, { maxBytes = MAX_RESPONSE_FRAME_BYTES } = {}) {
  validateFrameLimit(maxBytes)
  let body
  try {
    body = Buffer.from(JSON.stringify(value), 'utf8')
  } catch {
    fail('HOST_PROTOCOL_JSON', 'frame value is not JSON serializable')
  }
  if (body.length === 0 || body.length > maxBytes) {
    fail('HOST_PROTOCOL_FRAME_LIMIT', 'encoded frame exceeds its byte limit')
  }
  const header = Buffer.allocUnsafe(4)
  header.writeUInt32BE(body.length)
  return Buffer.concat([header, body], body.length + 4)
}

export function decodeSingleFrame(input, { maxBytes = MAX_RESPONSE_FRAME_BYTES } = {}) {
  validateFrameLimit(maxBytes)
  if (!Buffer.isBuffer(input)) fail('HOST_PROTOCOL_SHAPE', 'framed input must be a Buffer')
  if (input.length < 4) fail('HOST_PROTOCOL_TRUNCATED', 'frame header is truncated')
  const declared = input.readUInt32BE(0)
  if (declared === 0 || declared > maxBytes) {
    fail('HOST_PROTOCOL_FRAME_LIMIT', 'declared frame exceeds its byte limit')
  }
  const total = declared + 4
  if (input.length < total) fail('HOST_PROTOCOL_TRUNCATED', 'frame body is truncated')
  if (input.length > total) fail('HOST_PROTOCOL_EXTRA_BYTES', 'exactly one frame is required')
  try {
    return JSON.parse(input.toString('utf8', 4, total))
  } catch {
    fail('HOST_PROTOCOL_JSON', 'frame body is not valid JSON')
  }
}

function validateSourceUrl(value) {
  if (value === null) return
  requireBoundedString(value, MAX_URL_BYTES, 'HOST_SOURCE_URL', 'sourceUrl')
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail('HOST_SOURCE_URL', 'sourceUrl must be null or an absolute file URL')
  }
  if (parsed.protocol !== 'file:' || parsed.username !== '' || parsed.password !== '') {
    fail('HOST_SOURCE_URL', 'sourceUrl must be null or an absolute file URL')
  }
}

function validateOptions(options) {
  requireExactKeys(options, ['style', 'sourceMap', 'loadPaths'], 'HOST_OPTIONS', 'options')
  if (options.style !== 'expanded' && options.style !== 'compressed') {
    fail('HOST_OPTIONS', 'options.style must be expanded or compressed')
  }
  if (typeof options.sourceMap !== 'boolean') {
    fail('HOST_OPTIONS', 'options.sourceMap must be boolean')
  }
  if (!Array.isArray(options.loadPaths) || options.loadPaths.length > MAX_LOAD_PATHS) {
    fail('HOST_OPTIONS', 'options.loadPaths must be a bounded array')
  }
  for (const loadPath of options.loadPaths) {
    requireBoundedString(loadPath, MAX_URL_BYTES, 'HOST_OPTIONS', 'load path')
    if (!path.isAbsolute(loadPath) || /[\u0000\r\n]/.test(loadPath)) {
      fail('HOST_OPTIONS', 'load paths must be absolute local paths')
    }
  }
  if (new Set(options.loadPaths).size !== options.loadPaths.length) {
    fail('HOST_OPTIONS', 'load paths must be unique')
  }
}

export function validateRequest(value) {
  requireExactKeys(
    value,
    ['protocol', 'requestId', 'operation', 'provider', 'syntax', 'source', 'sourceUrl', 'options'],
    'HOST_REQUEST_SHAPE',
    'request',
  )
  if (value.protocol !== PROTOCOL_VERSION) {
    fail('HOST_PROTOCOL_VERSION', 'unsupported preprocessor protocol version')
  }
  if (
    typeof value.requestId !== 'string' ||
    byteLength(value.requestId) > MAX_REQUEST_ID_BYTES ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value.requestId)
  ) {
    fail('HOST_REQUEST_ID', 'requestId must be a bounded opaque identifier')
  }
  if (value.operation !== 'compile') fail('HOST_REQUEST_SHAPE', 'operation must be compile')
  if (!Object.hasOwn(providerSyntaxes, value.provider)) {
    fail('HOST_PROVIDER_UNKNOWN', 'provider id is not registered')
  }
  if (!providerSyntaxes[value.provider].has(value.syntax)) {
    fail('HOST_SYNTAX_PROVIDER_MISMATCH', 'syntax does not belong to provider')
  }
  if (typeof value.source !== 'string') fail('HOST_REQUEST_SHAPE', 'source must be a string')
  if (byteLength(value.source) > MAX_SOURCE_BYTES) {
    fail('HOST_SOURCE_LIMIT', 'source exceeds the byte limit')
  }
  validateSourceUrl(value.sourceUrl)
  validateOptions(value.options)
  return value
}

function validateDiagnostic(value) {
  requireExactKeys(
    value,
    ['severity', 'code', 'message', 'sourceUrl', 'line', 'column'],
    'HOST_RESPONSE_SHAPE',
    'diagnostic',
  )
  if (value.severity !== 'warning' && value.severity !== 'error') {
    fail('HOST_RESPONSE_SHAPE', 'diagnostic severity is invalid')
  }
  if (value.code !== null) {
    requireBoundedString(value.code, 128, 'HOST_RESPONSE_SHAPE', 'diagnostic code')
  }
  requireBoundedString(value.message, MAX_MESSAGE_BYTES, 'HOST_RESPONSE_SHAPE', 'diagnostic message')
  validateSourceUrl(value.sourceUrl)
  if (value.line !== null) requireInteger(value.line, 1, 0x7fffffff, 'HOST_RESPONSE_SHAPE', 'line')
  if (value.column !== null) {
    requireInteger(value.column, 1, 0x7fffffff, 'HOST_RESPONSE_SHAPE', 'column')
  }
}

function validateDependency(value) {
  requireExactKeys(value, ['url', 'kind'], 'HOST_RESPONSE_SHAPE', 'dependency')
  validateSourceUrl(value.url)
  if (!['import', 'use', 'forward', 'reference'].includes(value.kind)) {
    fail('HOST_RESPONSE_SHAPE', 'dependency kind is invalid')
  }
}

function validateSuccess(value) {
  requireExactKeys(value, ['protocol', 'requestId', 'ok', 'result'], 'HOST_RESPONSE_SHAPE', 'response')
  if (value.requestId === null) fail('HOST_RESPONSE_SHAPE', 'successful response requires requestId')
  requireExactKeys(
    value.result,
    ['css', 'sourceMap', 'diagnostics', 'dependencies'],
    'HOST_RESPONSE_SHAPE',
    'result',
  )
  if (typeof value.result.css !== 'string') fail('HOST_RESPONSE_SHAPE', 'result.css must be a string')
  if (byteLength(value.result.css) > MAX_OUTPUT_BYTES) {
    fail('HOST_OUTPUT_LIMIT', 'CSS output exceeds the byte limit')
  }
  if (value.result.sourceMap !== null) {
    requireBoundedString(
      value.result.sourceMap,
      MAX_OUTPUT_BYTES,
      'HOST_OUTPUT_LIMIT',
      'source map',
      true,
    )
  }
  if (!Array.isArray(value.result.diagnostics) || value.result.diagnostics.length > MAX_DIAGNOSTICS) {
    fail('HOST_RESPONSE_SHAPE', 'diagnostics must be a bounded array')
  }
  for (const diagnostic of value.result.diagnostics) validateDiagnostic(diagnostic)
  if (!Array.isArray(value.result.dependencies) || value.result.dependencies.length > MAX_DEPENDENCIES) {
    fail('HOST_RESPONSE_SHAPE', 'dependencies must be a bounded array')
  }
  for (const dependency of value.result.dependencies) validateDependency(dependency)
}

function validateFailure(value) {
  requireExactKeys(value, ['protocol', 'requestId', 'ok', 'error'], 'HOST_RESPONSE_SHAPE', 'response')
  requireExactKeys(value.error, ['code', 'message'], 'HOST_RESPONSE_SHAPE', 'error')
  if (!/^[A-Z][A-Z0-9_]{1,63}$/.test(value.error.code)) {
    fail('HOST_RESPONSE_SHAPE', 'error code is invalid')
  }
  requireBoundedString(value.error.message, 1024, 'HOST_RESPONSE_SHAPE', 'error message')
  if (/[\u0000-\u001f\u007f]/.test(value.error.message)) {
    fail('HOST_RESPONSE_SHAPE', 'error message contains control bytes')
  }
}

function validateResponseRequestId(value) {
  if (value.requestId === null) return
  if (
    typeof value.requestId !== 'string' ||
    byteLength(value.requestId) > MAX_REQUEST_ID_BYTES ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value.requestId)
  ) {
    fail('HOST_RESPONSE_SHAPE', 'response requestId is invalid')
  }
}

export function validateResponse(value) {
  if (!isPlainObject(value)) fail('HOST_RESPONSE_SHAPE', 'response must be an object')
  if (value.protocol !== PROTOCOL_VERSION) {
    fail('HOST_PROTOCOL_VERSION', 'response protocol version does not match')
  }
  validateResponseRequestId(value)
  if (value.ok === true) validateSuccess(value)
  else if (value.ok === false) validateFailure(value)
  else fail('HOST_RESPONSE_SHAPE', 'response ok must be boolean')
  return value
}
