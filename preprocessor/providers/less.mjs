import { AsyncLocalStorage } from 'node:async_hooks'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import sizeOf from 'image-size'
import less from 'less'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { createConfinedResolver } from '../resolver.mjs'
import { parseSourceMap } from '../source-map.mjs'
import { createLessImportAuthority } from './less-importer.mjs'

export const LESS_VERSION = '4.6.7'

const IMPORT_SENTINEL = 'ZIGCSS_LESS_IMPORTS_UNAVAILABLE'
const PLUGIN_DISABLED_MESSAGE = '@plugin statements are not allowed when disablePluginRule is set to true'
const JAVASCRIPT_DISABLED_MESSAGE = 'Inline JavaScript is not enabled. Is it set in your options?'
const VIRTUAL_DIRECTORY = '/__zigcss_less__'
const VIRTUAL_FILENAME = `${VIRTUAL_DIRECTORY}/input.less`
const VIRTUAL_MAP_SOURCE = 'input.less'
const VIRTUAL_SOURCE_URL = 'zigcss-entry://entry/input.less'
const MAX_CAPTURED_DIAGNOSTICS = 1000
const COMPRESS_DEPRECATION = 'The compress option has been deprecated. We recommend you use a dedicated css minifier, for instance see less-plugin-clean-css.'
const syntaxes = Object.freeze(['less'])
const warningContext = new AsyncLocalStorage()

less.logger.addListener(Object.freeze({
  warn(message) {
    const capture = warningContext.getStore()
    if (capture === undefined) return
    if (capture.values.length >= MAX_CAPTURED_DIAGNOSTICS) {
      capture.overflow = true
      return
    }
    capture.values.push(message)
  },
}))

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
    !hasExactKeys(
      request.options.providerOptions,
      ['math', 'quietDeprecations', 'rewriteUrls', 'strictUnits'],
    ) ||
    !['always', 'parens-division', 'parens'].includes(request.options.providerOptions.math) ||
    !['off', 'local', 'all'].includes(request.options.providerOptions.rewriteUrls) ||
    typeof request.options.providerOptions.quietDeprecations !== 'boolean' ||
    typeof request.options.providerOptions.strictUnits !== 'boolean'
  ) {
    throw failure('LESS_REQUEST_INVALID', 'Less received an invalid host request')
  }
}

function cancellation() {
  return failure('LESS_CANCELLED', 'Less compilation was cancelled')
}

function createRejectingFileManager(state) {
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
  return new RejectingFileManager()
}

function ownedImageDimensions(functionContext, filePathNode, fileManager) {
  let filePath = filePathNode?.value
  if (typeof filePath !== 'string' || filePath.length === 0) {
    throw { type: 'File', message: 'Image path must be a nonempty string' }
  }
  const fragmentStart = filePath.indexOf('#')
  if (fragmentStart !== -1) filePath = filePath.slice(0, fragmentStart)
  const currentFileInfo = functionContext.currentFileInfo
  const currentDirectory = currentFileInfo.rewriteUrls
    ? currentFileInfo.currentDirectory
    : currentFileInfo.entryPath
  const loaded = fileManager.loadFileSync(filePath, currentDirectory, {
    ...functionContext.context,
    rawBuffer: true,
  })
  if (!Buffer.isBuffer(loaded?.contents)) {
    throw { type: 'File', message: `Image file '${filePath}' was not found` }
  }
  try {
    return sizeOf(loaded.contents)
  } catch {
    throw { type: 'File', message: `Image file '${filePath}' is invalid` }
  }
}

const originalImageFunctions = Object.fromEntries(
  ['image-size', 'image-width', 'image-height'].map(name => [
    name,
    less.functions.functionRegistry.get(name),
  ]),
)
less.functions.functionRegistry.addMultiple({
  'image-size': function confinedImageSize(filePathNode) {
    const fileManager = warningContext.getStore()?.fileManager ?? null
    if (fileManager !== null) {
      const size = ownedImageDimensions(this, filePathNode, fileManager)
      return new less.tree.Expression([
        new less.tree.Dimension(size.width, 'px'),
        new less.tree.Dimension(size.height, 'px'),
      ])
    }
    return originalImageFunctions['image-size'].call(this, filePathNode)
  },
  'image-width': function confinedImageWidth(filePathNode) {
    const fileManager = warningContext.getStore()?.fileManager ?? null
    return fileManager === null
      ? originalImageFunctions['image-width'].call(this, filePathNode)
      : new less.tree.Dimension(
          ownedImageDimensions(this, filePathNode, fileManager).width,
          'px',
        )
  },
  'image-height': function confinedImageHeight(filePathNode) {
    const fileManager = warningContext.getStore()?.fileManager ?? null
    return fileManager === null
      ? originalImageFunctions['image-height'].call(this, filePathNode)
      : new less.tree.Dimension(
          ownedImageDimensions(this, filePathNode, fileManager).height,
          'px',
        )
  },
})

function createFilePlugin(fileManager) {
  return Object.freeze({
    install(_lessApi, pluginManager) {
      pluginManager.addFileManager(fileManager)
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

function diagnosticSourceUrl(error, request, authority) {
  const filename = error?.filename
  if (filename === undefined || filename === null || filename === VIRTUAL_FILENAME) {
    return request.sourceUrl
  }
  const actual = authority?.actualUrlForProviderFilename(filename) ?? null
  if (actual === null) {
    throw failure('LESS_IMPORT_BOUNDARY', 'Less returned an unknown dependency identity')
  }
  return actual
}

function rawErrorDiagnostic(error, request, code, authority, messageOverride) {
  const location = locationFromError(error)
  const message = messageOverride ?? (
    typeof error?.message === 'string' && error.message.length !== 0
      ? error.message
      : 'Less compilation failed'
  )
  const sourceUrl = diagnosticSourceUrl(error, request, authority)
  return {
    severity: 'error',
    code,
    message,
    sourceUrl,
    line: location.line,
    column: location.column,
  }
}

function rawWarningDiagnostic(value, request, authority) {
  if (typeof value !== 'string' || value.length === 0) {
    throw failure('LESS_DIAGNOSTIC_INVALID', 'Less returned invalid diagnostic metadata')
  }
  let message = value
  let filename = null
  let line = null
  let column = null
  const located = /^(.*) in ([^\r\n]+) on line ([0-9]+), column ([0-9]+):(?:\r?\n[\s\S]*)?$/.exec(message)
  if (located !== null) {
    message = located[1]
    filename = located[2]
    line = Number(located[3])
    column = Number(located[4])
    if (
      !Number.isSafeInteger(line) ||
      line < 1 ||
      line > 0x7fffffff ||
      !Number.isSafeInteger(column) ||
      column < 1 ||
      column > 0x7fffffff
    ) {
      throw failure('LESS_DIAGNOSTIC_INVALID', 'Less returned invalid diagnostic metadata')
    }
  }

  let severity = 'warning'
  let code = 'less.warning'
  if (message === COMPRESS_DEPRECATION) {
    severity = 'deprecation'
    code = 'less.deprecation.compress'
  } else if (message.startsWith('DEPRECATED WARNING: ')) {
    message = message.slice('DEPRECATED WARNING: '.length)
    severity = 'deprecation'
    code = 'less.deprecation'
  } else if (message.startsWith('WARNING: ')) {
    message = message.slice('WARNING: '.length)
  }

  return {
    severity,
    code,
    message,
    sourceUrl: diagnosticSourceUrl({ filename }, request, authority),
    line,
    column,
  }
}

function ownDiagnostics(
  capture,
  request,
  authority,
  error = null,
  errorCode = null,
  errorMessage = null,
) {
  if (capture.overflow) {
    throw failure('LESS_DIAGNOSTIC_LIMIT', 'Less exceeded the diagnostic limit')
  }
  const raw = capture.values.map(value => rawWarningDiagnostic(value, request, authority))
  if (error !== null) {
    raw.push(rawErrorDiagnostic(error, request, errorCode, authority, errorMessage))
  }
  if (raw.length > MAX_CAPTURED_DIAGNOSTICS) {
    throw failure('LESS_DIAGNOSTIC_LIMIT', 'Less exceeded the diagnostic limit')
  }
  try {
    return normalizeDiagnostics(raw, {
      provider: 'less',
      defaultSourceUrl: request.sourceUrl,
    })
  } catch {
    throw failure('LESS_DIAGNOSTIC_INVALID', 'Less returned invalid diagnostic metadata')
  }
}

function providerMap(serialized, request, authority) {
  let parsed
  try {
    parsed = parseSourceMap(serialized)
  } catch {
    throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an invalid source map')
  }
  if (
    parsed.sources.length === 0 ||
    !Object.hasOwn(parsed, 'sourcesContent') ||
    parsed.sourcesContent.length !== parsed.sources.length ||
    (Object.hasOwn(parsed, 'sourceRoot') && parsed.sourceRoot !== '')
  ) {
    throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an unexpected source identity')
  }

  const sources = []
  for (let index = 0; index < parsed.sources.length; index += 1) {
    const providerSource = parsed.sources[index]
    const actual = authority === null
      ? providerSource === VIRTUAL_MAP_SOURCE
        ? request.sourceUrl ?? VIRTUAL_SOURCE_URL
        : null
      : authority.actualUrlForMapSource(providerSource)
    const expectedContent = providerSource === VIRTUAL_MAP_SOURCE
      ? request.source
      : authority?.sourceContentForMapSource(providerSource)
    if (actual === null || expectedContent === undefined || parsed.sourcesContent[index] !== expectedContent) {
      throw failure('LESS_SOURCE_MAP_INVALID', 'Less returned an unexpected source identity')
    }
    sources.push(actual)
  }

  const output = { version: 3 }
  if (Object.hasOwn(parsed, 'file')) output.file = parsed.file
  output.sources = sources
  output.sourcesContent = [...parsed.sourcesContent]
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

function validateResult(result, request, authority) {
  if (
    result === null ||
    typeof result !== 'object' ||
    typeof result.css !== 'string' ||
    !Array.isArray(result.imports)
  ) {
    throw failure('LESS_RESULT_INVALID', 'Less returned an invalid result')
  }
  if (authority === null && result.imports.length !== 0) {
    throw failure('LESS_IMPORT_BOUNDARY', 'Less crossed the filesystem import boundary')
  }
  if (authority !== null && result.imports.some(filename => (
    authority.actualUrlForProviderFilename(filename) === null
  ))) {
    throw failure('LESS_IMPORT_BOUNDARY', 'Less returned an unknown dependency identity')
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
  let authority = null
  if (request.options.loadPaths.length !== 0) {
    try {
      const resolver = createConfinedResolver({ roots: request.options.loadPaths })
      authority = createLessImportAuthority({
        lessApi: less,
        session: resolver.createSession(),
        loadPaths: request.options.loadPaths,
        sourceUrl: request.sourceUrl,
        entryFilename: VIRTUAL_FILENAME,
        signal,
      })
    } catch {
      throw failure('LESS_IMPORT_ROOT_INVALID', 'Less received an invalid confined load path')
    }
  }
  const fileManager = authority?.fileManager ?? createRejectingFileManager(importState)
  const options = {
    color: false,
    compress: request.options.style === 'compressed',
    disablePluginRule: true,
    filename: VIRTUAL_FILENAME,
    insecure: false,
    javascriptEnabled: false,
    math: request.options.providerOptions.math,
    paths: [],
    plugins: [createFilePlugin(fileManager)],
    reUsePluginManager: false,
    quietDeprecations: request.options.providerOptions.quietDeprecations,
    rewriteUrls: request.options.providerOptions.rewriteUrls,
    strictUnits: request.options.providerOptions.strictUnits,
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

  try {
    const warningCapture = {
      values: [],
      overflow: false,
      fileManager: authority === null ? null : fileManager,
    }
    let result
    try {
      result = await warningContext.run(
        warningCapture,
        () => less.render(request.source, options),
      )
    } catch (error) {
      if (signal?.aborted === true) throw cancellation()
      if (warningCapture.overflow) {
        throw failure('LESS_DIAGNOSTIC_LIMIT', 'Less exceeded the diagnostic limit')
      }
      const importFailure = authority?.failure()
      if (importFailure?.code === 'LESS_CANCELLED') throw cancellation()
      if (importFailure !== null && importFailure !== undefined) {
        throw new ProviderFailure(
          importFailure.code,
          importFailure.message,
          ownDiagnostics(
            warningCapture,
            request,
            authority,
            error,
            'less.import',
            importFailure.message,
          ),
        )
      }
      if (authority?.isMissingError(error) === true) {
        throw new ProviderFailure(
          'LESS_IMPORT_NOT_FOUND',
          'A confined Less dependency was not found',
          ownDiagnostics(
            warningCapture,
            request,
            authority,
            error,
            'less.import',
            'A confined Less dependency was not found',
          ),
        )
      }
      if (importState.rejected) {
        throw new ProviderFailure(
          'LESS_IMPORTS_UNAVAILABLE',
          'Less imports require at least one explicit confined load path',
          ownDiagnostics(
            warningCapture,
            request,
            authority,
            error,
            'less.import',
            'Less imports require at least one explicit confined load path',
          ),
        )
      }
      if (error?.message === PLUGIN_DISABLED_MESSAGE) {
        throw new ProviderFailure(
          'LESS_PLUGIN_DISABLED',
          'Less plugins are disabled',
          ownDiagnostics(warningCapture, request, authority, error, 'less.plugin'),
        )
      }
      if (error?.message === JAVASCRIPT_DISABLED_MESSAGE) {
        throw new ProviderFailure(
          'LESS_JAVASCRIPT_DISABLED',
          'Less inline JavaScript is disabled',
          ownDiagnostics(warningCapture, request, authority, error, 'less.javascript'),
        )
      }
      throw new ProviderFailure(
        'LESS_COMPILE_ERROR',
        'Less rejected the input',
        ownDiagnostics(warningCapture, request, authority, error, 'less.compile'),
      )
    }

    if (signal?.aborted === true) throw cancellation()
    if (warningCapture.overflow) {
      throw failure('LESS_DIAGNOSTIC_LIMIT', 'Less exceeded the diagnostic limit')
    }
    const importFailure = authority?.failure()
    if (importFailure !== null && importFailure !== undefined) {
      throw failure(importFailure.code, importFailure.message)
    }
    if (importState.rejected) {
      throw failure(
        'LESS_IMPORTS_UNAVAILABLE',
        'Less imports require at least one explicit confined load path',
      )
    }
    validateResult(result, request, authority)
    return {
      css: result.css,
      sourceMap: request.options.sourceMap && typeof result.map === 'string'
        ? providerMap(result.map, request, authority)
        : null,
      diagnostics: ownDiagnostics(warningCapture, request, authority),
      dependencies: authority?.dependencies() ?? [],
    }
  } finally {
    authority?.close()
  }
}

export function createLessProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileLess,
  })
}
