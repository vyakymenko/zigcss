import * as sass from 'sass'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { parseSourceMap } from '../source-map.mjs'

export const DART_SASS_VERSION = '1.101.0'

const IMPORT_SENTINEL = 'ZIGCSS_SASS_IMPORTS_UNAVAILABLE'
const MAX_CAPTURED_DIAGNOSTICS = 1000
const syntaxes = Object.freeze(['scss', 'sass'])
const entryUrlStrings = Object.freeze({
  scss: 'zigcss-entry:input.scss',
  sass: 'zigcss-entry:input.sass',
})

function createRejectingImporter(state) {
  return Object.freeze({
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

function validateRequest(request) {
  if (
    request === null ||
    typeof request !== 'object' ||
    request.provider !== 'dart-sass' ||
    !syntaxes.includes(request.syntax) ||
    typeof request.source !== 'string' ||
    request.options === null ||
    typeof request.options !== 'object' ||
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
  if (request.options.loadPaths.length !== 0) {
    throw failure(
      'SASS_IMPORTS_UNAVAILABLE',
      'Dart Sass filesystem imports are not enabled in this adapter stage',
    )
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

function providerMap(sourceMap, entryUrl, requestSourceUrl) {
  let parsed
  try {
    parsed = parseSourceMap(JSON.stringify(sourceMap))
  } catch {
    throw failure('SASS_SOURCE_MAP_INVALID', 'Dart Sass returned an invalid source map')
  }
  if (parsed.sources.some(source => source !== entryUrl.href)) {
    throw failure('SASS_IMPORT_BOUNDARY', 'Dart Sass crossed the filesystem import boundary')
  }

  const output = { version: 3 }
  if (Object.hasOwn(parsed, 'file')) output.file = parsed.file
  if (Object.hasOwn(parsed, 'sourceRoot')) output.sourceRoot = parsed.sourceRoot
  output.sources = parsed.sources.map(source => (
    source === entryUrl.href && requestSourceUrl !== null ? requestSourceUrl : source
  ))
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

function validateResult(result, entryUrl) {
  if (
    result === null ||
    typeof result !== 'object' ||
    typeof result.css !== 'string' ||
    !Array.isArray(result.loadedUrls)
  ) {
    throw failure('SASS_RESULT_INVALID', 'Dart Sass returned an invalid result')
  }
  if (result.loadedUrls.some(url => String(url) !== entryUrl.href)) {
    throw failure('SASS_IMPORT_BOUNDARY', 'Dart Sass crossed the filesystem import boundary')
  }
}

async function compileDartSass(request, { signal } = {}) {
  validateRequest(request)
  if (detectedVersion() !== DART_SASS_VERSION) {
    throw failure('SASS_VERSION_MISMATCH', 'The installed Dart Sass version is not supported')
  }
  if (signal?.aborted === true) throw cancellation()

  const entryUrl = new URL(entryUrlStrings[request.syntax])
  const importState = { rejected: false }
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
        request.sourceUrl,
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
    importers: [createRejectingImporter(importState)],
    logger,
    verbose: request.options.providerOptions.verbose,
  }
  if (request.options.sourceMap) options.sourceMapIncludeSources = true

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
        'SASS_IMPORTS_UNAVAILABLE',
        'Dart Sass filesystem imports are not enabled in this adapter stage',
      )
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
        request.sourceUrl,
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
  validateResult(result, entryUrl)
  const diagnostics = ownDiagnostics(rawDiagnostics, request)
  let sourceMap = null
  if (request.options.sourceMap) {
    if (result.sourceMap === undefined) {
      throw failure('SASS_SOURCE_MAP_INVALID', 'Dart Sass did not return a requested source map')
    }
    sourceMap = providerMap(result.sourceMap, entryUrl, request.sourceUrl)
  }
  return {
    css: result.css,
    sourceMap,
    diagnostics,
    dependencies: [],
  }
}

export function createDartSassProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileDartSass,
  })
}
