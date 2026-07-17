import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { sanitizedHostEnvironment } from './environment.mjs'
import {
  DEFAULT_PROCESS_TIMEOUT_MS,
  MAX_PROCESS_TIMEOUT_MS,
  MAX_STDERR_BYTES,
  decodeSingleFrame,
  encodeFrame,
} from './protocol.mjs'
import { parseSourceMap } from './source-map.mjs'

export const CORE_PROTOCOL_VERSION = 'zigcss-core-v1'
export const MAX_CORE_SOURCE_BYTES = 20 * 1024 * 1024
export const MAX_CORE_REQUEST_FRAME_BYTES = MAX_CORE_SOURCE_BYTES + 64 * 1024
export const MAX_CORE_RESPONSE_FRAME_BYTES = 40 * 1024 * 1024

const MAX_REQUEST_ID_BYTES = 64
const MAX_SOURCE_URL_BYTES = 4096
const MAX_DIAGNOSTICS = 1000
const MAX_DEPENDENCIES = 100_000
const MAX_MESSAGE_BYTES = 4096

export class CoreProcessError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CoreProcessError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CoreProcessError(code, message)
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

function requirePositiveInteger(value, maximum, code, label) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    fail(code, `${label} is outside its allowed range`)
  }
}

function validateSourceUrl(value, code = 'CORE_SOURCE_URL') {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > MAX_SOURCE_URL_BYTES) {
    fail(code, 'sourceUrl must be a bounded canonical local file URL')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail(code, 'sourceUrl must be a bounded canonical local file URL')
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
    fail(code, 'sourceUrl must be a bounded canonical local file URL')
  }
  try {
    fileURLToPath(parsed)
  } catch {
    fail(code, 'sourceUrl must be a bounded canonical local file URL')
  }
  return value
}

export function validateCoreRequest(value) {
  requireExactKeys(
    value,
    ['protocol', 'requestId', 'operation', 'source', 'sourceUrl', 'options'],
    'CORE_REQUEST_SHAPE',
    'request',
  )
  if (value.protocol !== CORE_PROTOCOL_VERSION) fail('CORE_PROTOCOL_VERSION', 'unsupported core protocol')
  if (
    typeof value.requestId !== 'string' ||
    Buffer.byteLength(value.requestId) > MAX_REQUEST_ID_BYTES ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value.requestId)
  ) {
    fail('CORE_REQUEST_ID', 'requestId must be a bounded opaque identifier')
  }
  if (value.operation !== 'compile') fail('CORE_REQUEST_SHAPE', 'operation must be compile')
  if (typeof value.source !== 'string' || Buffer.byteLength(value.source) > MAX_CORE_SOURCE_BYTES) {
    fail('CORE_SOURCE_LIMIT', 'source must be a bounded string')
  }
  validateSourceUrl(value.sourceUrl)
  requireExactKeys(
    value.options,
    ['format', 'sourceMap', 'optimize'],
    'CORE_OPTIONS',
    'options',
  )
  if (value.options.format !== 'pretty' && value.options.format !== 'minified') {
    fail('CORE_OPTIONS', 'options.format must be pretty or minified')
  }
  if (typeof value.options.sourceMap !== 'boolean' || typeof value.options.optimize !== 'boolean') {
    fail('CORE_OPTIONS', 'options booleans are invalid')
  }
  if (value.options.sourceMap && value.options.optimize) {
    fail('CORE_OPTIONS', 'source maps are unavailable with fixed-point optimization')
  }
  return Object.freeze({
    protocol: CORE_PROTOCOL_VERSION,
    requestId: value.requestId,
    operation: 'compile',
    source: value.source,
    sourceUrl: value.sourceUrl,
    options: Object.freeze({ ...value.options }),
  })
}

function validateDiagnostic(value, request) {
  requireExactKeys(
    value,
    ['severity', 'code', 'message', 'sourceUrl', 'line', 'column'],
    'CORE_RESPONSE_SHAPE',
    'diagnostic',
  )
  if (!['error', 'warning', 'note'].includes(value.severity)) {
    fail('CORE_RESPONSE_SHAPE', 'diagnostic severity is invalid')
  }
  if (typeof value.code !== 'string' || !/^(?:CSS|API)[0-9]{4}$/.test(value.code)) {
    fail('CORE_RESPONSE_SHAPE', 'diagnostic code is invalid')
  }
  if (
    typeof value.message !== 'string' ||
    value.message.length === 0 ||
    Buffer.byteLength(value.message) > MAX_MESSAGE_BYTES ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/.test(value.message)
  ) {
    fail('CORE_RESPONSE_SHAPE', 'diagnostic message is invalid')
  }
  validateSourceUrl(value.sourceUrl, 'CORE_RESPONSE_SHAPE')
  if (value.sourceUrl !== request.sourceUrl) {
    fail('CORE_RESPONSE_SHAPE', 'diagnostic source does not match the generated CSS source')
  }
  for (const name of ['line', 'column']) {
    if (!Number.isSafeInteger(value[name]) || value[name] < 1 || value[name] > 0x7fffffff) {
      fail('CORE_RESPONSE_SHAPE', `diagnostic ${name} is invalid`)
    }
  }
  return Object.freeze({ ...value })
}

function validateDiagnostics(values, request) {
  if (!Array.isArray(values) || values.length > MAX_DIAGNOSTICS) {
    fail('CORE_RESPONSE_SHAPE', 'diagnostics must be a bounded array')
  }
  return Object.freeze(values.map(value => validateDiagnostic(value, request)))
}

function validateDependencies(values, request) {
  if (!Array.isArray(values) || values.length > MAX_DEPENDENCIES) {
    fail('CORE_RESPONSE_SHAPE', 'dependencies must be a bounded array')
  }
  return Object.freeze(values.map(value => {
    requireExactKeys(
      value,
      ['kind', 'specifier', 'sourceUrl', 'start', 'end'],
      'CORE_RESPONSE_SHAPE',
      'dependency',
    )
    if (value.kind !== 'css-import' && value.kind !== 'css-module') {
      fail('CORE_RESPONSE_SHAPE', 'dependency kind is invalid')
    }
    if (
      typeof value.specifier !== 'string' ||
      value.specifier.length === 0 ||
      Buffer.byteLength(value.specifier) > MAX_MESSAGE_BYTES
    ) {
      fail('CORE_RESPONSE_SHAPE', 'dependency specifier is invalid')
    }
    validateSourceUrl(value.sourceUrl, 'CORE_RESPONSE_SHAPE')
    if (value.sourceUrl !== request.sourceUrl) {
      fail('CORE_RESPONSE_SHAPE', 'dependency source does not match the generated CSS source')
    }
    if (
      !Number.isSafeInteger(value.start) ||
      !Number.isSafeInteger(value.end) ||
      value.start < 0 ||
      value.end < value.start ||
      value.end > Buffer.byteLength(request.source)
    ) {
      fail('CORE_RESPONSE_SHAPE', 'dependency span is invalid')
    }
    return Object.freeze({ ...value })
  }))
}

export function validateCoreResponse(value, request) {
  if (!isPlainObject(value) || value.protocol !== CORE_PROTOCOL_VERSION || value.requestId !== request.requestId) {
    fail('CORE_RESPONSE_SHAPE', 'core response envelope is invalid')
  }
  if (value.ok === true) {
    requireExactKeys(value, ['protocol', 'requestId', 'ok', 'result'], 'CORE_RESPONSE_SHAPE', 'response')
    requireExactKeys(
      value.result,
      ['css', 'sourceMap', 'diagnostics', 'dependencies'],
      'CORE_RESPONSE_SHAPE',
      'result',
    )
    if (typeof value.result.css !== 'string' || Buffer.byteLength(value.result.css) > MAX_CORE_RESPONSE_FRAME_BYTES) {
      fail('CORE_RESPONSE_SHAPE', 'core CSS is invalid')
    }
    const diagnostics = validateDiagnostics(value.result.diagnostics, request)
    const dependencies = validateDependencies(value.result.dependencies, request)
    if (diagnostics.some(diagnostic => diagnostic.severity === 'error')) {
      fail('CORE_RESPONSE_SHAPE', 'successful core response contains an error')
    }
    if (request.options.sourceMap) {
      if (typeof value.result.sourceMap !== 'string') {
        fail('CORE_RESPONSE_SHAPE', 'core source map is missing')
      }
      const parsed = parseSourceMap(value.result.sourceMap)
      if (parsed.sources.length !== 1 || parsed.sources[0] !== request.sourceUrl) {
        fail('CORE_RESPONSE_SHAPE', 'core source map does not own the generated CSS source')
      }
    } else if (value.result.sourceMap !== null) {
      fail('CORE_RESPONSE_SHAPE', 'core returned an unrequested source map')
    }
    return Object.freeze({
      protocol: CORE_PROTOCOL_VERSION,
      requestId: request.requestId,
      ok: true,
      result: Object.freeze({
        css: value.result.css,
        sourceMap: value.result.sourceMap,
        diagnostics,
        dependencies,
      }),
    })
  }
  if (value.ok !== false) fail('CORE_RESPONSE_SHAPE', 'core response status is invalid')
  requireExactKeys(value, ['protocol', 'requestId', 'ok', 'error'], 'CORE_RESPONSE_SHAPE', 'response')
  requireExactKeys(
    value.error,
    ['code', 'message', 'diagnostics'],
    'CORE_RESPONSE_SHAPE',
    'error',
  )
  if (
    value.error.code !== 'CORE_COMPILE_ERROR' ||
    value.error.message !== 'generated CSS was rejected'
  ) {
    fail('CORE_RESPONSE_SHAPE', 'core failure is invalid')
  }
  const diagnostics = validateDiagnostics(value.error.diagnostics, request)
  if (!diagnostics.some(diagnostic => diagnostic.severity === 'error')) {
    fail('CORE_RESPONSE_SHAPE', 'core failure requires an error diagnostic')
  }
  return Object.freeze({
    protocol: CORE_PROTOCOL_VERSION,
    requestId: request.requestId,
    ok: false,
    error: Object.freeze({
      code: value.error.code,
      message: value.error.message,
      diagnostics,
    }),
  })
}

function validateBinary(binaryPath, binaryArguments) {
  if (typeof binaryPath !== 'string' || !path.isAbsolute(binaryPath)) {
    fail('CORE_BINARY_INVALID', 'core binary path must be absolute')
  }
  let stat
  try {
    stat = fs.lstatSync(binaryPath)
    fs.accessSync(binaryPath, process.platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK)
  } catch {
    fail('CORE_BINARY_INVALID', 'core binary is unavailable or not executable')
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail('CORE_BINARY_INVALID', 'core binary must be a regular non-symlink file')
  }
  if (!Array.isArray(binaryArguments) || binaryArguments.length > 8) {
    fail('CORE_ARGUMENTS_INVALID', 'core binary arguments must be bounded')
  }
  for (const argument of binaryArguments) {
    if (typeof argument !== 'string' || Buffer.byteLength(argument) > 256 || /[\u0000\r\n]/.test(argument)) {
      fail('CORE_ARGUMENTS_INVALID', 'core binary arguments must be bounded strings')
    }
  }
}

function validateSignal(signal) {
  if (signal !== undefined && !(signal instanceof AbortSignal)) {
    fail('CORE_SIGNAL_INVALID', 'signal must be an AbortSignal')
  }
  if (signal?.aborted) fail('CORE_PROCESS_ABORTED', 'core compilation was cancelled')
}

export async function runZigCssCore(
  requestValue,
  {
    binaryPath,
    binaryArguments = [],
    timeoutMs = DEFAULT_PROCESS_TIMEOUT_MS,
    maxStdoutBytes = MAX_CORE_RESPONSE_FRAME_BYTES + 4,
    maxStderrBytes = MAX_STDERR_BYTES,
    signal,
  } = {},
) {
  const request = validateCoreRequest(requestValue)
  validateBinary(binaryPath, binaryArguments)
  validateSignal(signal)
  requirePositiveInteger(timeoutMs, MAX_PROCESS_TIMEOUT_MS, 'CORE_LIMIT_INVALID', 'timeout')
  requirePositiveInteger(
    maxStdoutBytes,
    MAX_CORE_RESPONSE_FRAME_BYTES + 4,
    'CORE_LIMIT_INVALID',
    'stdout limit',
  )
  requirePositiveInteger(maxStderrBytes, MAX_STDERR_BYTES, 'CORE_LIMIT_INVALID', 'stderr limit')
  const input = encodeFrame(request, { maxBytes: MAX_CORE_REQUEST_FRAME_BYTES })

  return await new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(binaryPath, [...binaryArguments, '--internal-core-v1'], {
        cwd: path.dirname(binaryPath),
        env: sanitizedHostEnvironment(),
        shell: false,
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      })
    } catch {
      reject(new CoreProcessError('CORE_PROCESS_START', 'core process could not start'))
      return
    }

    const stdout = []
    let stdoutBytes = 0
    let stderrBytes = 0
    let failure = null

    const terminate = error => {
      if (failure !== null) return
      failure = error
      child.kill('SIGKILL')
    }
    const onAbort = () => {
      terminate(new CoreProcessError('CORE_PROCESS_ABORTED', 'core compilation was cancelled'))
    }
    if (signal !== undefined) signal.addEventListener('abort', onAbort, { once: true })
    const timer = setTimeout(() => {
      terminate(new CoreProcessError('CORE_PROCESS_TIMEOUT', 'core process exceeded its time limit'))
    }, timeoutMs)
    const cleanup = () => {
      clearTimeout(timer)
      if (signal !== undefined) signal.removeEventListener('abort', onAbort)
    }

    child.on('error', () => {
      terminate(new CoreProcessError('CORE_PROCESS_START', 'core process could not start'))
    })
    child.stdout.on('data', chunk => {
      stdoutBytes += chunk.length
      if (stdoutBytes > maxStdoutBytes) {
        terminate(new CoreProcessError('CORE_STDOUT_LIMIT', 'core process exceeded its stdout limit'))
        return
      }
      stdout.push(chunk)
    })
    child.stderr.on('data', chunk => {
      stderrBytes += chunk.length
      if (stderrBytes > maxStderrBytes) {
        terminate(new CoreProcessError('CORE_STDERR_LIMIT', 'core process exceeded its stderr limit'))
        return
      }
      terminate(new CoreProcessError('CORE_STDERR_OUTPUT', 'core process emitted unexpected stderr'))
    })
    child.stdin.on('error', () => {
      // Early close is resolved by the terminal process checks below.
    })
    child.once('close', (code, processSignal) => {
      cleanup()
      if (failure !== null) {
        reject(failure)
        return
      }
      if (code !== 0 || processSignal !== null) {
        reject(new CoreProcessError('CORE_PROCESS_EXIT', 'core process exited unsuccessfully'))
        return
      }
      if (stderrBytes !== 0) {
        reject(new CoreProcessError('CORE_STDERR_OUTPUT', 'core process emitted unexpected stderr'))
        return
      }
      let response
      try {
        response = validateCoreResponse(
          decodeSingleFrame(Buffer.concat(stdout, stdoutBytes), {
            maxBytes: MAX_CORE_RESPONSE_FRAME_BYTES,
          }),
          request,
        )
      } catch {
        reject(new CoreProcessError('CORE_RESPONSE_INVALID', 'core process returned an invalid response'))
        return
      }
      resolve(response)
    })
    child.stdin.end(input)
  })
}
