import path from 'node:path'
import { fileURLToPath } from 'node:url'
import less from 'less'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { parseSourceMap } from '../source-map.mjs'

export const LESS_VERSION = '4.6.7'

const IMPORT_SENTINEL = 'ZIGCSS_LESS_IMPORTS_UNAVAILABLE'
const PLUGIN_DISABLED_MESSAGE = '@plugin statements are not allowed when disablePluginRule is set to true'
const JAVASCRIPT_DISABLED_MESSAGE = 'Inline JavaScript is not enabled. Is it set in your options?'
const VIRTUAL_DIRECTORY = '/__zigcss_less__'
const VIRTUAL_FILENAME = `${VIRTUAL_DIRECTORY}/input.less`
const VIRTUAL_MAP_SOURCE = 'input.less'
const VIRTUAL_SOURCE_URL = 'zigcss-entry://entry/input.less'
const syntaxes = Object.freeze(['less'])

function failure(code, message) {
  return new ProviderFailure(code, message, [])
}

function detectedVersion() {
  if (!Array.isArray(less.version) || less.version.length !== 3) return null
  if (less.version.some(value => !Number.isSafeInteger(value) || value < 0)) return null
  return less.version.join('.')
}

function hasExactKeys(value, expected) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  if (prototype !== Object.prototype && prototype !== null) return false
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  return JSON.stringify(actual) === JSON.stringify(wanted)
}

function validSourceUrl(value) {
  if (value === null) return true
  if (typeof value !== 'string') return false
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    return false
  }
  const valid = (
    parsed.protocol === 'file:' &&
    parsed.hostname === '' &&
    parsed.username === '' &&
    parsed.password === '' &&
    parsed.search === '' &&
    parsed.hash === '' &&
    parsed.pathname.startsWith('/') &&
    !/%2f|%5c/i.test(parsed.pathname) &&
    parsed.href === value
  )
  if (!valid) return false
  try {
    fileURLToPath(parsed)
  } catch {
    return false
  }
  return true
}

function validLoadPaths(values) {
  if (!Array.isArray(values) || values.length > 64) return false
  if (new Set(values).size !== values.length) return false
  return values.every(value => (
    typeof value === 'string' &&
    value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= 4096 &&
    path.isAbsolute(value) &&
    !/[\u0000\r\n]/.test(value)
  ))
}

function validateRequest(request) {
  if (
    request === null ||
    typeof request !== 'object' ||
    request.provider !== 'less' ||
    request.syntax !== 'less' ||
    typeof request.source !== 'string' ||
    !validSourceUrl(request.sourceUrl) ||
    request.options === null ||
    typeof request.options !== 'object' ||
    !hasExactKeys(request.options, ['style', 'sourceMap', 'loadPaths', 'providerOptions']) ||
    !['expanded', 'compressed'].includes(request.options.style) ||
    typeof request.options.sourceMap !== 'boolean' ||
    !validLoadPaths(request.options.loadPaths) ||
    !hasExactKeys(request.options.providerOptions, [])
  ) {
    throw failure('LESS_REQUEST_INVALID', 'Less received an invalid host request')
  }
  if (request.options.loadPaths.length !== 0) {
    throw failure(
      'LESS_IMPORTS_UNAVAILABLE',
      'Less imports require the confined resolver integration',
    )
  }
}

function cancellation() {
  return failure('LESS_CANCELLED', 'Less compilation was cancelled')
}

function createRejectingFilePlugin(state) {
  class RejectingFileManager extends less.FileManager {
    supports() {
      return true
    }

    supportsSync() {
      return true
    }

    loadFile() {
      state.rejected = true
      return Promise.reject({ type: 'File', message: IMPORT_SENTINEL })
    }

    loadFileSync() {
      state.rejected = true
      throw { type: 'File', message: IMPORT_SENTINEL }
    }
  }

  return Object.freeze({
    install(_lessApi, pluginManager) {
      pluginManager.addFileManager(new RejectingFileManager())
    },
  })
}

function locationFromError(error) {
  const line = Number.isSafeInteger(error?.line) && error.line >= 1
    ? error.line
    : null
  const column = line !== null && Number.isSafeInteger(error?.column) && error.column >= 0
    ? error.column + 1
    : null
  return { line, column }
}

function ownDiagnostic(error, request, code) {
  const location = locationFromError(error)
  const message = typeof error?.message === 'string' && error.message.length !== 0
    ? error.message
    : 'Less compilation failed'
  try {
    return normalizeDiagnostics([{
      severity: 'error',
      code,
      message,
      sourceUrl: request.sourceUrl,
      line: location.line,
      column: location.column,
    }], {
      provider: 'less',
      defaultSourceUrl: request.sourceUrl,
    })
  } catch {
    throw failure('LESS_DIAGNOSTIC_INVALID', 'Less returned invalid diagnostic metadata')
  }
}

function providerMap(serialized, request) {
  let parsed
  try {
    parsed = parseSourceMap(serialized)
  } catch {
    throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an invalid source map')
  }
  if (
    parsed.sources.length !== 1 ||
    parsed.sources[0] !== VIRTUAL_MAP_SOURCE ||
    !Object.hasOwn(parsed, 'sourcesContent') ||
    parsed.sourcesContent.length !== 1 ||
    parsed.sourcesContent[0] !== request.source ||
    (Object.hasOwn(parsed, 'sourceRoot') && parsed.sourceRoot !== '')
  ) {
    throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an unexpected source identity')
  }

  const output = { version: 3 }
  if (Object.hasOwn(parsed, 'file')) output.file = parsed.file
  output.sources = [request.sourceUrl ?? VIRTUAL_SOURCE_URL]
  output.sourcesContent = [request.source]
  output.names = [...parsed.names]
  output.mappings = parsed.mappings
  const owned = JSON.stringify(output)
  try {
    parseSourceMap(owned)
  } catch {
    throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an invalid source map')
  }
  return owned
}

function validateResult(result, request) {
  if (
    result === null ||
    typeof result !== 'object' ||
    typeof result.css !== 'string' ||
    !Array.isArray(result.imports) ||
    result.imports.length !== 0
  ) {
    throw failure('LESS_RESULT_INVALID', 'Less returned an invalid result')
  }
  if (request.options.sourceMap) {
    if (result.css.length !== 0 && typeof result.map !== 'string') {
      throw failure('LESS_SOURCE_MAP_INVALID', 'Less did not return a requested source map')
    }
  } else if (result.map !== undefined) {
    throw failure('LESS_RESULT_INVALID', 'Less returned an unexpected source map')
  }
}

async function compileLess(request, { signal } = {}) {
  validateRequest(request)
  if (detectedVersion() !== LESS_VERSION) {
    throw failure('LESS_VERSION_MISMATCH', 'The installed Less version is not supported')
  }
  if (signal?.aborted === true) throw cancellation()

  const importState = { rejected: false }
  const options = {
    compress: request.options.style === 'compressed',
    disablePluginRule: true,
    filename: VIRTUAL_FILENAME,
    insecure: false,
    javascriptEnabled: false,
    paths: [],
    plugins: [createRejectingFilePlugin(importState)],
    reUsePluginManager: false,
    syncImport: false,
  }
  if (request.options.sourceMap) {
    options.sourceMap = {
      disableSourcemapAnnotation: true,
      outputSourceFiles: true,
      sourceMapBasepath: VIRTUAL_DIRECTORY,
      sourceMapFilename: 'input.css.map',
      sourceMapInputFilename: VIRTUAL_FILENAME,
      sourceMapOutputFilename: 'input.css',
    }
  }

  let result
  try {
    result = await less.render(request.source, options)
  } catch (error) {
    if (signal?.aborted === true) throw cancellation()
    if (importState.rejected) {
      throw failure(
        'LESS_IMPORTS_UNAVAILABLE',
        'Less imports require the confined resolver integration',
      )
    }
    if (error?.message === PLUGIN_DISABLED_MESSAGE) {
      throw new ProviderFailure(
        'LESS_PLUGIN_DISABLED',
        'Less plugins are disabled',
        ownDiagnostic(error, request, 'less.plugin'),
      )
    }
    if (error?.message === JAVASCRIPT_DISABLED_MESSAGE) {
      throw new ProviderFailure(
        'LESS_JAVASCRIPT_DISABLED',
        'Less inline JavaScript is disabled',
        ownDiagnostic(error, request, 'less.javascript'),
      )
    }
    throw new ProviderFailure(
      'LESS_COMPILE_ERROR',
      'Less rejected the input',
      ownDiagnostic(error, request, 'less.compile'),
    )
  }

  if (signal?.aborted === true) throw cancellation()
  if (importState.rejected) {
    throw failure(
      'LESS_IMPORTS_UNAVAILABLE',
      'Less imports require the confined resolver integration',
    )
  }
  validateResult(result, request)
  return {
    css: result.css,
    sourceMap: request.options.sourceMap && typeof result.map === 'string'
      ? providerMap(result.map, request)
      : null,
    diagnostics: [],
    dependencies: [],
  }
}

export function createLessProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileLess,
  })
}
