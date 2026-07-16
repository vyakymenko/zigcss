const MAX_DIAGNOSTICS = 1000
const MAX_DEPENDENCIES = 4096
const MAX_DIAGNOSTIC_MESSAGE_BYTES = 4096
const MAX_FAILURE_MESSAGE_BYTES = 1024
const MAX_URL_BYTES = 4096

const providers = new Set(['dart-sass', 'less', 'stylus'])
const dependencyKinds = new Set(['import', 'use', 'forward', 'reference'])
const diagnosticKeys = ['severity', 'code', 'message', 'sourceUrl', 'line', 'column']
const dependencyKeys = ['url', 'kind']

export class MetadataError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'MetadataError'
    this.code = code
  }
}

function fail(code, message) {
  throw new MetadataError(code, message)
}

function byteLength(value) {
  return Buffer.byteLength(value, 'utf8')
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function hasExactKeys(value, expected) {
  if (!isPlainObject(value)) return false
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  return JSON.stringify(actual) === JSON.stringify(wanted)
}

function sanitizeText(value) {
  return value
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, '')
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, '')
}

function requireLocalFileUrl(value, code, label) {
  if (typeof value !== 'string' || value.length === 0 || byteLength(value) > MAX_URL_BYTES) {
    fail(code, `${label} must be a bounded local file URL`)
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail(code, `${label} must be a bounded local file URL`)
  }
  if (
    parsed.protocol !== 'file:' ||
    parsed.username !== '' ||
    parsed.password !== '' ||
    parsed.hostname !== '' ||
    parsed.search !== '' ||
    parsed.hash !== '' ||
    !parsed.pathname.startsWith('/') ||
    /%2f|%5c/i.test(parsed.pathname) ||
    parsed.href !== value
  ) {
    fail(code, `${label} must be a canonical local file URL`)
  }
  return value
}

function requireLocation(value, label) {
  if (value === null) return
  if (!Number.isSafeInteger(value) || value < 1 || value > 0x7fffffff) {
    fail('METADATA_DIAGNOSTIC_SHAPE', `${label} must be null or a positive integer`)
  }
}

function normalizeDiagnostic(value, defaultSourceUrl) {
  if (!hasExactKeys(value, diagnosticKeys)) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic has unexpected or missing fields')
  }
  if (!['error', 'warning', 'deprecation'].includes(value.severity)) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic severity is invalid')
  }
  if (
    value.code !== null &&
    (typeof value.code !== 'string' || !/^[A-Za-z0-9_.-]+$/.test(value.code) || value.code.length > 128)
  ) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic code is invalid')
  }
  if (typeof value.message !== 'string') {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic message must be a string')
  }
  const message = sanitizeText(value.message)
  if (message.length === 0) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic message must not be empty')
  }
  if (byteLength(message) > MAX_DIAGNOSTIC_MESSAGE_BYTES) {
    fail('METADATA_DIAGNOSTIC_LIMIT', 'diagnostic message exceeds its byte limit')
  }
  const sourceUrl = value.sourceUrl === null ? defaultSourceUrl : value.sourceUrl
  if (sourceUrl !== null) requireLocalFileUrl(sourceUrl, 'METADATA_SOURCE_URL', 'diagnostic sourceUrl')
  requireLocation(value.line, 'diagnostic line')
  requireLocation(value.column, 'diagnostic column')
  if (value.line === null && value.column !== null) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostic column requires a line')
  }
  return Object.freeze({
    severity: value.severity === 'deprecation' ? 'warning' : value.severity,
    code: value.code,
    message,
    sourceUrl,
    line: value.line,
    column: value.column,
  })
}

export function normalizeDiagnostics(values, { provider, defaultSourceUrl = null } = {}) {
  if (!providers.has(provider)) fail('METADATA_PROVIDER', 'provider id is not registered')
  if (defaultSourceUrl !== null) {
    requireLocalFileUrl(defaultSourceUrl, 'METADATA_SOURCE_URL', 'default sourceUrl')
  }
  if (!Array.isArray(values)) {
    fail('METADATA_DIAGNOSTIC_SHAPE', 'diagnostics must be an array')
  }
  if (values.length > MAX_DIAGNOSTICS) {
    fail('METADATA_DIAGNOSTIC_LIMIT', 'diagnostics exceed the count limit')
  }
  return Object.freeze(values.map(value => normalizeDiagnostic(value, defaultSourceUrl)))
}

export function normalizeDependencies(values) {
  if (!Array.isArray(values) || values.length > MAX_DEPENDENCIES) {
    fail('METADATA_DEPENDENCY', 'dependencies must be a bounded array')
  }
  const seen = new Set()
  const output = []
  for (const value of values) {
    if (!hasExactKeys(value, dependencyKeys) || !dependencyKinds.has(value.kind)) {
      fail('METADATA_DEPENDENCY', 'dependency has an invalid shape or kind')
    }
    requireLocalFileUrl(value.url, 'METADATA_DEPENDENCY', 'dependency URL')
    if (seen.has(value.url)) continue
    seen.add(value.url)
    output.push(Object.freeze({ url: value.url, kind: value.kind }))
  }
  return Object.freeze(output)
}

function validateNormalizedDiagnostics(values) {
  if (!Array.isArray(values) || values.length > MAX_DIAGNOSTICS) {
    fail('METADATA_FAILURE', 'failure diagnostics must be a bounded array')
  }
  return values.map(value => {
    if (
      !hasExactKeys(value, diagnosticKeys) ||
      !['error', 'warning'].includes(value.severity) ||
      (value.code !== null && (
        typeof value.code !== 'string' ||
        !/^[A-Za-z0-9_.-]+$/.test(value.code) ||
        value.code.length > 128
      )) ||
      typeof value.message !== 'string' ||
      value.message.length === 0 ||
      byteLength(value.message) > MAX_DIAGNOSTIC_MESSAGE_BYTES ||
      sanitizeText(value.message) !== value.message
    ) {
      fail('METADATA_FAILURE', 'failure diagnostic is not normalized')
    }
    if (value.sourceUrl !== null) {
      try {
        requireLocalFileUrl(value.sourceUrl, 'METADATA_FAILURE', 'failure diagnostic sourceUrl')
      } catch (error) {
        if (error instanceof MetadataError) fail('METADATA_FAILURE', 'failure diagnostic sourceUrl is invalid')
        throw error
      }
    }
    if (
      (value.line !== null && (!Number.isSafeInteger(value.line) || value.line < 1 || value.line > 0x7fffffff)) ||
      (value.column !== null && (!Number.isSafeInteger(value.column) || value.column < 1 || value.column > 0x7fffffff)) ||
      (value.line === null && value.column !== null)
    ) {
      fail('METADATA_FAILURE', 'failure diagnostic location is invalid')
    }
    return Object.freeze({ ...value })
  })
}

function normalizeFailureMessage(value) {
  if (typeof value !== 'string') fail('METADATA_FAILURE', 'failure message must be a string')
  const message = sanitizeText(value)
  if (message.length === 0 || byteLength(message) > MAX_FAILURE_MESSAGE_BYTES || /[\n\t]/.test(message)) {
    fail('METADATA_FAILURE', 'failure message must be a bounded single-line string')
  }
  return message
}

export class ProviderFailure extends Error {
  constructor(code, message, diagnostics = []) {
    if (typeof code !== 'string' || !/^[A-Z][A-Z0-9_]{1,63}$/.test(code)) {
      fail('METADATA_FAILURE', 'failure code is invalid')
    }
    const publicMessage = normalizeFailureMessage(message)
    const ownedDiagnostics = Object.freeze(validateNormalizedDiagnostics(diagnostics))
    super(publicMessage)
    this.name = 'ProviderFailure'
    this.code = code
    this.diagnostics = ownedDiagnostics
  }
}
