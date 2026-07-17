import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import stylus from 'stylus'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { parseSourceMap } from '../source-map.mjs'

export const STYLUS_VERSION = '0.64.0'

const require = createRequire(import.meta.url)
const INTERNAL_FUNCTIONS_PATH = require.resolve('stylus/lib/functions/index.styl')
const VIRTUAL_DIRECTORY = path.join(
  path.parse(INTERNAL_FUNCTIONS_PATH).root,
  '__zigcss_stylus__',
)
const VIRTUAL_FILENAME = path.join(VIRTUAL_DIRECTORY, 'input.styl')
const VIRTUAL_MAP_SOURCE = 'input.styl'
const VIRTUAL_SOURCE_URL = 'zigcss-entry://entry/input.styl'
const IMPORT_SENTINEL = 'ZIGCSS_STYLUS_IMPORTS_UNAVAILABLE'
const FILESYSTEM_SENTINEL = 'ZIGCSS_STYLUS_FILESYSTEM_DISABLED'
const PLUGIN_SENTINEL = 'ZIGCSS_STYLUS_PLUGIN_DISABLED'
const MAX_CAPTURED_DIAGNOSTICS = 1000
const syntaxes = Object.freeze(['stylus'])

function failure(code, message) {
  return new ProviderFailure(code, message, [])
}

function cancellation() {
  return failure('STYLUS_CANCELLED', 'Stylus compilation was cancelled')
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
    request.provider !== 'stylus' ||
    request.syntax !== 'stylus' ||
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
    throw failure('STYLUS_REQUEST_INVALID', 'Stylus received an invalid host request')
  }
}

function detectedVersion() {
  return typeof stylus.version === 'string' ? stylus.version : null
}

function captureDiagnostic(state, code, message) {
  if (state.values.length >= MAX_CAPTURED_DIAGNOSTICS) {
    state.overflow = true
    return
  }
  state.values.push({
    severity: 'warning',
    code,
    message,
    sourceUrl: state.sourceUrl,
    line: null,
    column: null,
  })
}

function createLanguageFunctions(state) {
  function disabledFilesystem() {
    state.filesystemRejected = true
    throw new Error(FILESYSTEM_SENTINEL)
  }
  disabledFilesystem.raw = true

  function disabledPlugin() {
    state.pluginRejected = true
    throw new Error(PLUGIN_SENTINEL)
  }
  disabledPlugin.raw = true

  function capturedWarning(message) {
    stylus.utils.assertType(message, 'string', 'msg')
    captureDiagnostic(state, 'stylus.warning', message.val)
    return stylus.nodes.null
  }
  capturedWarning.params = ['message']

  function capturedInspect(...expressions) {
    for (const expression of expressions) {
      const unwrapped = stylus.utils.unwrap(expression)
      if (!Array.isArray(unwrapped?.nodes) || unwrapped.nodes.length === 0) continue
      const message = unwrapped.toString().replace(/^\(|\)$/g, '')
      captureDiagnostic(state, 'stylus.inspect', `inspect: ${message}`)
    }
    return stylus.nodes.null
  }
  capturedInspect.raw = true

  function capturedTrace() {
    captureDiagnostic(state, 'stylus.trace', 'Stylus trace requested')
    return stylus.nodes.null
  }

  return {
    disabledFilesystem,
    disabledPlugin,
    capturedWarning,
    capturedInspect,
    capturedTrace,
  }
}

function rawImportPath(imported) {
  const expression = imported?.path
  if (expression?.nodeName !== 'expression' || expression.nodes?.length !== 1) return null
  const value = expression.nodes[0]
  return typeof value?.string === 'string' ? value.string : null
}

function createConfinedEvaluator(state, functions) {
  return class ConfinedStylusEvaluator extends stylus.Evaluator {
    populateGlobalScope() {
      super.populateGlobalScope()
      this.global.scope.add(new stylus.nodes.Ident(
        'embedurl',
        new stylus.nodes.Function('embedurl', functions.disabledFilesystem),
      ))
    }

    visitImport(imported) {
      const candidate = rawImportPath(imported)
      if (
        state.internalImports === 0 &&
        candidate === INTERNAL_FUNCTIONS_PATH &&
        imported?.filename === VIRTUAL_FILENAME
      ) {
        state.internalImports += 1
        return super.visitImport(imported)
      }
      state.importRejected = true
      throw new Error(IMPORT_SENTINEL)
    }
  }
}

function errorMetadata(error) {
  const formatted = typeof error?.message === 'string' && error.message.length !== 0
    ? error.message.replaceAll('\r\n', '\n')
    : 'Stylus compilation failed'
  const header = /^(.*):([0-9]+):([0-9]+)\n/.exec(formatted)
  let line = null
  let column = null
  let source = null
  if (header !== null) {
    source = header[1]
    line = Number(header[2])
    column = Number(header[3])
    if (
      !Number.isSafeInteger(line) ||
      line < 1 ||
      line > 0x7fffffff ||
      !Number.isSafeInteger(column) ||
      column < 1 ||
      column > 0x7fffffff
    ) {
      throw failure('STYLUS_DIAGNOSTIC_INVALID', 'Stylus returned invalid diagnostic metadata')
    }
  }
  if (source !== null && source !== VIRTUAL_FILENAME) {
    throw failure('STYLUS_DIAGNOSTIC_INVALID', 'Stylus returned an unknown source identity')
  }

  const separator = formatted.indexOf('\n\n')
  let message = separator === -1 ? formatted : formatted.slice(separator + 2)
  const stack = typeof error?.stylusStack === 'string' && error.stylusStack.length !== 0
    ? `${error.stylusStack}\n`
    : ''
  if (stack.length !== 0 && message.endsWith(stack)) message = message.slice(0, -stack.length)
  message = message.replace(/\n$/, '')
  if (message.length === 0) message = 'Stylus compilation failed'
  return { message, line, column }
}

function ownDiagnostics(state, request, error = null, errorCode = null, messageOverride = null) {
  if (state.overflow) {
    throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
  }
  const raw = [...state.values]
  if (error !== null) {
    const metadata = errorMetadata(error)
    raw.push({
      severity: 'error',
      code: errorCode,
      message: messageOverride ?? metadata.message,
      sourceUrl: request.sourceUrl,
      line: metadata.line,
      column: metadata.column,
    })
  }
  if (raw.length > MAX_CAPTURED_DIAGNOSTICS) {
    throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
  }
  try {
    return normalizeDiagnostics(raw, {
      provider: 'stylus',
      defaultSourceUrl: request.sourceUrl,
    })
  } catch {
    throw failure('STYLUS_DIAGNOSTIC_INVALID', 'Stylus returned invalid diagnostic metadata')
  }
}

function providerMap(value, request) {
  let parsed
  try {
    parsed = parseSourceMap(JSON.stringify(value))
  } catch {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an invalid source map')
  }
  if (
    parsed.file !== 'input.css' ||
    parsed.sources.length !== 1 ||
    parsed.sources[0] !== VIRTUAL_MAP_SOURCE ||
    Object.hasOwn(parsed, 'sourcesContent') ||
    Object.hasOwn(parsed, 'sourceRoot')
  ) {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an unexpected source identity')
  }

  const owned = JSON.stringify({
    version: 3,
    file: parsed.file,
    sources: [request.sourceUrl ?? VIRTUAL_SOURCE_URL],
    sourcesContent: [request.source],
    names: [...parsed.names],
    mappings: parsed.mappings,
  })
  try {
    parseSourceMap(owned)
  } catch {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an invalid source map')
  }
  return owned
}

function render(renderer) {
  return new Promise((resolve, reject) => {
    renderer.render((error, css) => {
      if (error !== null && error !== undefined) reject(error)
      else resolve(css)
    })
  })
}

async function compileStylus(request, { signal } = {}) {
  validateRequest(request)
  if (detectedVersion() !== STYLUS_VERSION) {
    throw failure('STYLUS_VERSION_MISMATCH', 'The installed Stylus version is not supported')
  }
  if (signal?.aborted === true) throw cancellation()
  if (request.options.loadPaths.length !== 0) {
    throw failure(
      'STYLUS_IMPORTS_UNAVAILABLE',
      'Stylus imports require the confined STYLUS-011 integration',
    )
  }

  const state = {
    filesystemRejected: false,
    importRejected: false,
    internalImports: 0,
    overflow: false,
    pluginRejected: false,
    sourceUrl: request.sourceUrl,
    values: [],
  }
  const functions = createLanguageFunctions(state)
  const renderer = stylus(request.source, {
    Evaluator: createConfinedEvaluator(state, functions),
    compress: request.options.style === 'compressed',
    filename: VIRTUAL_FILENAME,
    functions: {},
    globals: {},
    imports: [],
    paths: [],
    use: [],
    warn: false,
  })
  renderer.define('json', functions.disabledFilesystem, true)
  renderer.define('image-size', functions.disabledFilesystem, true)
  renderer.define('use', functions.disabledPlugin, true)
  renderer.define('warn', functions.capturedWarning)
  renderer.define('p', functions.capturedInspect, true)
  renderer.define('trace', functions.capturedTrace)
  if (request.options.sourceMap) {
    renderer.set('sourcemap', {
      basePath: VIRTUAL_DIRECTORY,
      comment: false,
      inline: false,
    })
  }
  if (
    renderer.options.imports.length !== 1 ||
    renderer.options.imports[0] !== INTERNAL_FUNCTIONS_PATH ||
    renderer.options.paths.length !== 0 ||
    renderer.options.use.length !== 0
  ) {
    throw failure('STYLUS_RESULT_INVALID', 'Stylus initialized an unexpected provider boundary')
  }

  let css
  try {
    css = await render(renderer)
  } catch (error) {
    if (signal?.aborted === true) throw cancellation()
    if (state.overflow) {
      throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
    }
    if (state.importRejected) {
      throw new ProviderFailure(
        'STYLUS_IMPORTS_UNAVAILABLE',
        'Stylus imports require the confined STYLUS-011 integration',
        ownDiagnostics(
          state,
          request,
          error,
          'stylus.import',
          'Stylus imports require the confined STYLUS-011 integration',
        ),
      )
    }
    if (state.filesystemRejected) {
      throw new ProviderFailure(
        'STYLUS_FILESYSTEM_DISABLED',
        'Stylus filesystem helpers are disabled',
        ownDiagnostics(
          state,
          request,
          error,
          'stylus.filesystem',
          'Stylus filesystem helpers are disabled',
        ),
      )
    }
    if (state.pluginRejected) {
      throw new ProviderFailure(
        'STYLUS_PLUGIN_DISABLED',
        'Stylus plugins are disabled',
        ownDiagnostics(
          state,
          request,
          error,
          'stylus.plugin',
          'Stylus plugins are disabled',
        ),
      )
    }
    throw new ProviderFailure(
      'STYLUS_COMPILE_ERROR',
      'Stylus rejected the input',
      ownDiagnostics(state, request, error, 'stylus.compile'),
    )
  }

  if (signal?.aborted === true) throw cancellation()
  if (state.overflow) {
    throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
  }
  if (
    typeof css !== 'string' ||
    state.internalImports !== 1 ||
    state.importRejected ||
    state.filesystemRejected ||
    state.pluginRejected
  ) {
    throw failure('STYLUS_RESULT_INVALID', 'Stylus returned an invalid result')
  }
  if (request.options.sourceMap) {
    if (renderer.sourcemap === null || typeof renderer.sourcemap !== 'object') {
      throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus did not return a requested source map')
    }
  } else if (renderer.sourcemap !== undefined) {
    throw failure('STYLUS_RESULT_INVALID', 'Stylus returned an unexpected source map')
  }

  return {
    css,
    sourceMap: request.options.sourceMap ? providerMap(renderer.sourcemap, request) : null,
    diagnostics: ownDiagnostics(state, request),
    dependencies: [],
  }
}

export function createStylusProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileStylus,
  })
}
