import * as sass from 'sass'
import { fileURLToPath } from 'node:url'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { createConfinedResolver } from '../resolver.mjs'
import { parseSourceMap } from '../source-map.mjs'
import { createSassImportAuthority } from './sass-importer.mjs'

export const DART_SASS_VERSION = '1.101.0'
export const SASS_MAX_IMPORT_DEPTH = 32

const IMPORT_SENTINEL = 'ZIGCSS_SASS_IMPORT_ROOT_REQUIRED'
const MAX_CAPTURED_DIAGNOSTICS = 1000
const syntaxes = Object.freeze(['scss', 'sass'])
const entryFilenames = Object.freeze({
  scss: 'input.scss',
  sass: 'input.sass',
})

function entryUrlForRequest(request) {
  const pathname = request.sourceUrl === null
    ? `/${entryFilenames[request.syntax]}`
    : new URL(request.sourceUrl).pathname
  return new URL(`zigcss-entry://entry${pathname}`)
}

function createRejectingImporter(state) {
  return Object.freeze({
    nonCanonicalScheme: Object.freeze(['file', 'http', 'https', 'zigcss-entry']),
    canonicalize() {
      state.rejected = true
      throw new Error(IMPORT_SENTINEL)
    },
    load() {
      state.rejected = true
      throw new Error(IMPORT_SENTINEL)
    },
  })
}

function failure(code, message) {
  return new ProviderFailure(code, message, [])
}

function detectedVersion() {
  if (typeof sass.info !== 'string') return null
  const match = /^dart-sass\t([^\t\r\n]+)\t/.exec(sass.info)
  return match?.[1] ?? null
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

function validateRequest(request) {
  if (
    request === null ||
    typeof request !== 'object' ||
    request.provider !== 'dart-sass' ||
    !syntaxes.includes(request.syntax) ||
    typeof request.source !== 'string' ||
    !validSourceUrl(request.sourceUrl) ||
    request.options === null ||
    typeof request.options !== 'object' ||
    !hasExactKeys(request.options, ['style', 'sourceMap', 'loadPaths', 'providerOptions']) ||
    !['expanded', 'compressed'].includes(request.options.style) ||
    typeof request.options.sourceMap !== 'boolean' ||
    !Array.isArray(request.options.loadPaths) ||
    !hasExactKeys(request.options.providerOptions, ['charset', 'quietDeps', 'verbose']) ||
    typeof request.options.providerOptions.charset !== 'boolean' ||
    typeof request.options.providerOptions.quietDeps !== 'boolean' ||
    typeof request.options.providerOptions.verbose !== 'boolean'
  ) {
    throw failure('SASS_REQUEST_INVALID', 'Dart Sass received an invalid host request')
  }
}

function cancellation() {
  return failure('SASS_CANCELLED', 'Dart Sass compilation was cancelled')
}

function diagnosticLocation(span) {
  const line = Number.isSafeInteger(span?.start?.line) && span.start.line >= 0
    ? span.start.line + 1
    : null
  const column = line !== null && Number.isSafeInteger(span?.start?.column) && span.start.column >= 0
    ? span.start.column + 1
    : null
  return { line, column }
}

function warningCode(options) {
  const id = options?.deprecationType?.id
  if (
    options?.deprecation === true &&
    typeof id === 'string' &&
    /^[A-Za-z0-9_.-]+$/.test(id) &&
    id.length <= 96
  ) {
    return `sass.deprecation.${id}`
  }
  return options?.deprecation === true ? 'sass.deprecation' : 'sass.warning'
}

function rawDiagnostic(severity, code, message, span, sourceUrl) {
  const location = diagnosticLocation(span)
  return {
    severity,
    code,
    message,
    sourceUrl,
    line: location.line,
    column: location.column,
  }
}

function ownDiagnostics(raw, request) {
  if (raw.length > MAX_CAPTURED_DIAGNOSTICS) {
    throw failure('SASS_DIAGNOSTIC_LIMIT', 'Dart Sass exceeded the diagnostic limit')
  }
  try {
    return normalizeDiagnostics(raw, {
      provider: 'dart-sass',
      defaultSourceUrl: request.sourceUrl,
    })
  } catch {
    throw failure('SASS_DIAGNOSTIC_INVALID', 'Dart Sass returned invalid diagnostic metadata')
  }
}

function providerSourceUrl(source, entryUrl, requestSourceUrl, authority) {
  if (source === entryUrl.href) return requestSourceUrl ?? source
  return authority?.actualUrlForProviderUrl(source) ?? null
}

function diagnosticSourceUrl(span, entryUrl, requestSourceUrl, authority) {
  const value = span?.url
  if (value === undefined || value === null) return requestSourceUrl
  const source = String(value)
  if (source === entryUrl.href) return requestSourceUrl
  return authority?.actualUrlForProviderUrl(source) ?? requestSourceUrl
}

function providerMap(sourceMap, entryUrl, requestSourceUrl, authority) {
  let parsed
  try {
    parsed = parseSourceMap(JSON.stringify(sourceMap))
  } catch {
    throw failure('SASS_SOURCE_MAP_INVALID', 'Dart Sass returned an invalid source map')
  }
  const sources = parsed.sources.map(source => (
    providerSourceUrl(source, entryUrl, requestSourceUrl, authority)
  ))
  if (sources.some(source => source === null)) {
    throw failure('SASS_IMPORT_BOUNDARY', 'Dart Sass crossed the filesystem import boundary')
  }

  const output = { version: 3 }
  if (Object.hasOwn(parsed, 'file')) output.file = parsed.file
  if (Object.hasOwn(parsed, 'sourceRoot')) output.sourceRoot = parsed.sourceRoot
  output.sources = sources
  if (Object.hasOwn(parsed, 'sourcesContent')) {
    output.sourcesContent = [...parsed.sourcesContent]
  }
  output.names = [...parsed.names]
  output.mappings = parsed.mappings

  const serialized = JSON.stringify(output)
  try {
    parseSourceMap(serialized)
  } catch {
    throw failure('SASS_SOURCE_MAP_INVALID', 'Dart Sass returned an invalid source map')
  }
  return serialized
}

function validateResult(result, entryUrl, authority) {
  if (
    result === null ||
    typeof result !== 'object' ||
    typeof result.css !== 'string' ||
    !Array.isArray(result.loadedUrls)
  ) {
    throw failure('SASS_RESULT_INVALID', 'Dart Sass returned an invalid result')
  }
  if (result.loadedUrls.some(url => (
    String(url) !== entryUrl.href && (authority?.actualUrlForProviderUrl(url) ?? null) === null
  ))) {
    throw failure('SASS_IMPORT_BOUNDARY', 'Dart Sass crossed the filesystem import boundary')
  }
}

async function compileDartSass(request, { signal } = {}) {
  validateRequest(request)
  if (detectedVersion() !== DART_SASS_VERSION) {
    throw failure('SASS_VERSION_MISMATCH', 'The installed Dart Sass version is not supported')
  }
  if (signal?.aborted === true) throw cancellation()

  const entryUrl = entryUrlForRequest(request)
  const importState = { rejected: false }
  let authority = null
  if (request.options.loadPaths.length !== 0) {
    try {
      const resolver = createConfinedResolver({
        roots: request.options.loadPaths,
        limits: { maxDepth: SASS_MAX_IMPORT_DEPTH },
      })
      authority = createSassImportAuthority({
        resolver,
        session: resolver.createSession(),
        loadPaths: request.options.loadPaths,
        sourceUrl: request.sourceUrl,
        entryUrl,
        signal,
      })
    } catch {
      throw failure('SASS_IMPORT_ROOT_INVALID', 'Dart Sass received an invalid confined load path')
    }
  }
  const rawDiagnostics = []
  let diagnosticOverflow = false
  const logger = {
    warn(message, options) {
      if (rawDiagnostics.length >= MAX_CAPTURED_DIAGNOSTICS) {
        diagnosticOverflow = true
        return
      }
      rawDiagnostics.push(rawDiagnostic(
        options?.deprecation === true ? 'deprecation' : 'warning',
        warningCode(options),
        message,
        options?.span,
        diagnosticSourceUrl(options?.span, entryUrl, request.sourceUrl, authority),
      ))
    },
    debug() {},
  }

  const options = {
    alertColor: false,
    charset: request.options.providerOptions.charset,
    quietDeps: request.options.providerOptions.quietDeps,
    syntax: request.syntax === 'sass' ? 'indented' : 'scss',
    style: request.options.style,
    sourceMap: request.options.sourceMap,
    url: entryUrl,
    importer: authority?.importer ?? createRejectingImporter(importState),
    logger,
    verbose: request.options.providerOptions.verbose,
  }
  if (authority !== null) options.importers = authority.loadPathImporters
  if (request.options.sourceMap) options.sourceMapIncludeSources = true

  try {
    let result
    try {
      result = await sass.compileStringAsync(request.source, options)
    } catch (error) {
      if (signal?.aborted === true) throw cancellation()
      if (
        importState.rejected &&
        typeof error?.sassMessage === 'string' &&
        error.sassMessage.startsWith(IMPORT_SENTINEL)
      ) {
        throw failure(
          'SASS_IMPORT_ROOT_REQUIRED',
          'Dart Sass imports require at least one explicit confined load path',
        )
      }
      const importFailure = authority?.failure()
      if (importFailure?.code === 'SASS_CANCELLED') throw cancellation()
      if (importFailure !== null && importFailure !== undefined) {
        const diagnostics = ownDiagnostics([
          ...rawDiagnostics,
          rawDiagnostic(
            'error',
            'sass.import',
            importFailure.message,
            error?.span,
            diagnosticSourceUrl(error?.span, entryUrl, request.sourceUrl, authority),
          ),
        ], request)
        throw new ProviderFailure(importFailure.code, importFailure.message, diagnostics)
      }
      const message = typeof error?.sassMessage === 'string'
        ? error.sassMessage
        : 'Dart Sass compilation failed'
      const diagnostics = ownDiagnostics([
        ...rawDiagnostics,
        rawDiagnostic(
          'error',
          'sass.compile',
          message,
          error?.span,
          diagnosticSourceUrl(error?.span, entryUrl, request.sourceUrl, authority),
        ),
      ], request)
      throw new ProviderFailure(
        'SASS_COMPILE_ERROR',
        'Dart Sass rejected the input',
        diagnostics,
      )
    }

    if (signal?.aborted === true) throw cancellation()
    if (diagnosticOverflow) {
      throw failure('SASS_DIAGNOSTIC_LIMIT', 'Dart Sass exceeded the diagnostic limit')
    }
    validateResult(result, entryUrl, authority)
    const diagnostics = ownDiagnostics(rawDiagnostics, request)
    let sourceMap = null
    if (request.options.sourceMap) {
      if (result.sourceMap === undefined) {
        throw failure('SASS_SOURCE_MAP_INVALID', 'Dart Sass did not return a requested source map')
      }
      sourceMap = providerMap(result.sourceMap, entryUrl, request.sourceUrl, authority)
    }
    return {
      css: result.css,
      sourceMap,
      diagnostics,
      dependencies: authority?.dependencies() ?? [],
    }
  } finally {
    authority?.close()
  }
}

export function createDartSassProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileDartSass,
  })
}
