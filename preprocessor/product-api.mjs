import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  CORE_PROTOCOL_VERSION,
  runZigCssCore,
  validateCoreResponse,
} from './core-runner.mjs'
import {
  DEFAULT_PROCESS_TIMEOUT_MS,
  MAX_PROCESS_TIMEOUT_MS,
  MAX_SOURCE_BYTES,
  PROTOCOL_VERSION,
  validateRequest,
  validateResponse,
} from './protocol.mjs'
import { runPreprocessorHost } from './runner.mjs'
import { createConfinedResolver } from './resolver.mjs'
import { composeSourceMaps } from './source-map.mjs'

export const SUPPORTED_SYNTAXES = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus'])

const syntaxConfiguration = Object.freeze({
  scss: Object.freeze({
    provider: 'dart-sass',
    extension: 'scss',
    providerOptions: Object.freeze({ charset: true, quietDeps: false, verbose: false }),
  }),
  sass: Object.freeze({
    provider: 'dart-sass',
    extension: 'sass',
    providerOptions: Object.freeze({ charset: true, quietDeps: false, verbose: false }),
  }),
  less: Object.freeze({
    provider: 'less',
    extension: 'less',
    providerOptions: Object.freeze({
      math: 'parens-division',
      quietDeprecations: false,
      rewriteUrls: 'off',
      strictUnits: false,
    }),
  }),
  stylus: Object.freeze({
    provider: 'stylus',
    extension: 'styl',
    providerOptions: Object.freeze({ hoistAtrules: false, includeCss: false }),
  }),
})

const productionBinaryPath = fileURLToPath(new URL(
  `../bin/${process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'}`,
  import.meta.url,
))

export class ZigCssCompileError extends Error {
  constructor(code, message, diagnostics = []) {
    super(message)
    this.name = 'ZigCssCompileError'
    this.code = code
    this.diagnostics = Object.freeze(diagnostics.map(diagnostic => Object.freeze({ ...diagnostic })))
  }
}

function fail(message, diagnostics = []) {
  throw new ZigCssCompileError('API_OPTIONS', message, diagnostics)
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function canonicalSourceUrl(value, syntax) {
  if (value === undefined || value === null) {
    const extension = syntaxConfiguration[syntax]?.extension ?? 'css'
    return pathToFileURL(path.resolve(process.cwd(), `.zigcss-input.${extension}`)).href
  }
  if (typeof value !== 'string' || Buffer.byteLength(value) > 4096) {
    fail('sourceUrl must be a bounded canonical local file URL')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    fail('sourceUrl must be a bounded canonical local file URL')
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
    fail('sourceUrl must be a bounded canonical local file URL')
  }
  try {
    fileURLToPath(parsed)
  } catch {
    fail('sourceUrl must be a bounded canonical local file URL')
  }
  return value
}

function normalizeLoadPaths(value, syntax) {
  const paths = value === undefined ? [] : value
  if (!Array.isArray(paths) || paths.length > 64) fail('loadPaths must be a bounded array')
  if (syntax === 'css' && paths.length !== 0) fail('CSS compilation does not accept preprocessor load paths')
  const normalized = paths.map(loadPath => {
    if (
      typeof loadPath !== 'string' ||
      !path.isAbsolute(loadPath) ||
      Buffer.byteLength(loadPath) > 4096 ||
      /[\u0000\r\n]/.test(loadPath)
    ) {
      fail('loadPaths must contain bounded absolute local paths')
    }
    return path.resolve(loadPath)
  })
  if (new Set(normalized).size !== normalized.length) fail('loadPaths must be unique')
  return Object.freeze(normalized)
}

function normalizeProviderOptions(syntax, value) {
  if (syntax === 'css') {
    if (value !== undefined && value !== null && (!isPlainObject(value) || Object.keys(value).length !== 0)) {
      fail('CSS compilation does not accept providerOptions')
    }
    return null
  }
  if (value !== undefined && value !== null && !isPlainObject(value)) {
    fail('providerOptions must be an object')
  }
  const defaults = syntaxConfiguration[syntax].providerOptions
  const overrides = value ?? {}
  for (const key of Object.keys(overrides)) {
    if (!Object.hasOwn(defaults, key)) fail(`unsupported ${syntax} provider option: ${key}`)
  }
  const options = { ...defaults, ...overrides }
  if (syntax === 'scss' || syntax === 'sass') {
    for (const name of ['charset', 'quietDeps', 'verbose']) {
      if (typeof options[name] !== 'boolean') fail(`${syntax} provider option ${name} must be boolean`)
    }
  } else if (syntax === 'less') {
    if (!['always', 'parens-division', 'parens'].includes(options.math)) {
      fail('Less provider option math is invalid')
    }
    if (!['off', 'local', 'all'].includes(options.rewriteUrls)) {
      fail('Less provider option rewriteUrls is invalid')
    }
    for (const name of ['quietDeprecations', 'strictUnits']) {
      if (typeof options[name] !== 'boolean') fail(`Less provider option ${name} must be boolean`)
    }
  } else {
    for (const name of ['hoistAtrules', 'includeCss']) {
      if (typeof options[name] !== 'boolean') fail(`Stylus provider option ${name} must be boolean`)
    }
  }
  return Object.freeze(options)
}

function normalizeOptions(value) {
  const options = value === undefined ? {} : value
  if (!isPlainObject(options)) fail('compile options must be an object')
  const allowed = new Set([
    'syntax',
    'sourceUrl',
    'loadPaths',
    'format',
    'sourceMap',
    'optimize',
    'providerOptions',
    'timeoutMs',
    'signal',
  ])
  for (const key of Object.keys(options)) {
    if (!allowed.has(key)) fail(`unknown compile option: ${key}`)
  }
  const syntax = options.syntax ?? 'css'
  if (!SUPPORTED_SYNTAXES.includes(syntax)) fail(`unsupported syntax: ${syntax}`)
  const format = options.format ?? 'pretty'
  if (format !== 'pretty' && format !== 'minified') fail('format must be pretty or minified')
  const sourceMap = options.sourceMap ?? false
  const optimize = options.optimize ?? false
  if (typeof sourceMap !== 'boolean' || typeof optimize !== 'boolean') {
    fail('sourceMap and optimize must be boolean')
  }
  if (sourceMap && optimize) fail('source maps are unavailable with fixed-point optimization')
  const timeoutMs = options.timeoutMs ?? DEFAULT_PROCESS_TIMEOUT_MS
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > MAX_PROCESS_TIMEOUT_MS) {
    fail('timeoutMs is outside its allowed range')
  }
  if (options.signal !== undefined && !(options.signal instanceof AbortSignal)) {
    fail('signal must be an AbortSignal')
  }
  return Object.freeze({
    syntax,
    sourceUrl: canonicalSourceUrl(options.sourceUrl, syntax),
    loadPaths: normalizeLoadPaths(options.loadPaths, syntax),
    format,
    sourceMap,
    optimize,
    providerOptions: normalizeProviderOptions(syntax, options.providerOptions),
    timeoutMs,
    signal: options.signal,
  })
}

function normalizeRuntime(value) {
  if (!isPlainObject(value)) fail('runtime must be an object')
  const keys = Object.keys(value).sort()
  if (JSON.stringify(keys) !== JSON.stringify(['binaryPath', 'runCore', 'runHost'])) {
    fail('runtime has unexpected or missing fields')
  }
  if (
    typeof value.binaryPath !== 'string' ||
    typeof value.runCore !== 'function' ||
    typeof value.runHost !== 'function'
  ) {
    fail('runtime fields are invalid')
  }
  return value
}

function intermediateSourceUrl(sourceUrl) {
  const sourcePath = fileURLToPath(sourceUrl)
  return pathToFileURL(path.join(path.dirname(sourcePath), '.zigcss-intermediate.css')).href
}

function wrapFailure(error) {
  if (error instanceof ZigCssCompileError) return error
  const code = typeof error?.code === 'string' && /^[A-Z][A-Z0-9_]{1,63}$/.test(error.code)
    ? error.code
    : 'API_INTERNAL'
  const message = typeof error?.message === 'string' && error.message.length > 0
    ? error.message
    : 'compilation failed'
  const diagnostics = Array.isArray(error?.diagnostics) ? error.diagnostics : []
  return new ZigCssCompileError(code, message, diagnostics)
}

function ownedResult(css, sourceMap, diagnostics, dependencies) {
  return Object.freeze({
    css,
    sourceMap,
    diagnostics: Object.freeze(diagnostics.map(diagnostic => Object.freeze({ ...diagnostic }))),
    dependencies: Object.freeze(dependencies.map(dependency => Object.freeze({ ...dependency }))),
  })
}

export async function compileStringWithRuntime(source, optionValue, runtimeValue) {
  try {
    if (typeof source !== 'string' || Buffer.byteLength(source) > MAX_SOURCE_BYTES) {
      fail('source must be a string within the 10 MiB limit')
    }
    const options = normalizeOptions(optionValue)
    const runtime = normalizeRuntime(runtimeValue)
    let generatedCss = source
    let providerMap = null
    let diagnostics = []
    let dependencies = []

    if (options.syntax !== 'css') {
      const configuration = syntaxConfiguration[options.syntax]
      const hostRequest = validateRequest({
        protocol: PROTOCOL_VERSION,
        requestId: 'product-provider',
        operation: 'compile',
        provider: configuration.provider,
        syntax: options.syntax,
        source,
        sourceUrl: options.sourceUrl,
        options: {
          style: 'expanded',
          sourceMap: options.sourceMap,
          loadPaths: [...options.loadPaths],
          providerOptions: { ...options.providerOptions },
        },
      })
      const hostResponse = validateResponse(await runtime.runHost(hostRequest, {
        timeoutMs: options.timeoutMs,
        signal: options.signal,
      }))
      if (hostResponse.requestId !== hostRequest.requestId) {
        throw new ZigCssCompileError('HOST_RESPONSE_INVALID', 'preprocessor response id does not match')
      }
      if (!hostResponse.ok) {
        throw new ZigCssCompileError(
          hostResponse.error.code,
          hostResponse.error.message,
          hostResponse.error.diagnostics,
        )
      }
      generatedCss = hostResponse.result.css
      providerMap = hostResponse.result.sourceMap
      diagnostics = hostResponse.result.diagnostics
      dependencies = hostResponse.result.dependencies
      if (options.sourceMap && typeof providerMap !== 'string') {
        throw new ZigCssCompileError('SOURCE_MAP_INVALID', 'preprocessor source map is missing')
      }
      if (!options.sourceMap && providerMap !== null) {
        throw new ZigCssCompileError('SOURCE_MAP_INVALID', 'preprocessor returned an unrequested source map')
      }
    }

    const generatedSourceUrl = options.syntax === 'css'
      ? options.sourceUrl
      : intermediateSourceUrl(options.sourceUrl)
    const coreRequest = {
      protocol: CORE_PROTOCOL_VERSION,
      requestId: 'product-core',
      operation: 'compile',
      source: generatedCss,
      sourceUrl: generatedSourceUrl,
      options: {
        format: options.format,
        sourceMap: options.sourceMap,
        optimize: options.optimize,
      },
    }
    const coreResponse = validateCoreResponse(await runtime.runCore(coreRequest, {
      binaryPath: runtime.binaryPath,
      timeoutMs: options.timeoutMs,
      signal: options.signal,
    }), coreRequest)
    if (!coreResponse.ok) {
      throw new ZigCssCompileError(
        coreResponse.error.code,
        coreResponse.error.message,
        coreResponse.error.diagnostics,
      )
    }
    const finalMap = !options.sourceMap
      ? null
      : options.syntax === 'css'
        ? coreResponse.result.sourceMap
        : composeSourceMaps({
          providerMap,
          zigMap: coreResponse.result.sourceMap,
          intermediateSourceUrl: generatedSourceUrl,
        })
    return ownedResult(
      coreResponse.result.css,
      finalMap,
      [...diagnostics, ...coreResponse.result.diagnostics],
      [...dependencies, ...coreResponse.result.dependencies],
    )
  } catch (error) {
    throw wrapFailure(error)
  }
}

const productionRuntime = Object.freeze({
  binaryPath: productionBinaryPath,
  runCore: runZigCssCore,
  runHost: runPreprocessorHost,
})

export async function compileString(source, options) {
  return compileStringWithRuntime(source, options, productionRuntime)
}

const detectedSyntaxes = Object.freeze([
  Object.freeze({ suffix: '.scss', syntax: 'scss' }),
  Object.freeze({ suffix: '.sass', syntax: 'sass' }),
  Object.freeze({ suffix: '.less', syntax: 'less' }),
  Object.freeze({ suffix: '.styl', syntax: 'stylus' }),
  Object.freeze({ suffix: '.css', syntax: 'css' }),
])

export function detectSyntax(filename) {
  if (
    typeof filename !== 'string' ||
    filename.length === 0 ||
    Buffer.byteLength(filename) > 4096 ||
    /[\u0000\r\n]/.test(filename)
  ) {
    fail('filename must be a bounded local path')
  }
  const basename = path.basename(filename)
  if (basename.endsWith('.module.css')) {
    fail('CSS Modules remain unavailable through the npm preprocessor API')
  }
  return detectedSyntaxes.find(candidate => basename.endsWith(candidate.suffix))?.syntax ?? null
}

function deduplicateLoadPaths(values) {
  const output = []
  const seen = new Set()
  for (const value of values) {
    const identity = process.platform === 'win32' ? value.toLowerCase() : value
    if (seen.has(identity)) continue
    seen.add(identity)
    output.push(value)
  }
  return output
}

export async function loadFileForCompilation(filename, optionValue) {
  try {
    if (
      typeof filename !== 'string' ||
      filename.length === 0 ||
      Buffer.byteLength(filename) > 4096 ||
      /[\u0000\r\n]/.test(filename)
    ) {
      fail('filename must be a bounded local path')
    }
    const rawOptions = optionValue === undefined ? {} : optionValue
    if (!isPlainObject(rawOptions)) fail('compile options must be an object')
    if (Object.hasOwn(rawOptions, 'sourceUrl')) {
      fail('compileFile owns sourceUrl from the confined entry path')
    }
    const detected = detectSyntax(filename)
    const explicit = rawOptions.syntax
    if (explicit !== undefined && !SUPPORTED_SYNTAXES.includes(explicit)) {
      fail(`unsupported syntax: ${explicit}`)
    }
    if (detected === null && explicit === undefined) {
      fail('cannot detect syntax from the input extension; set syntax explicitly')
    }
    if (detected !== null && explicit !== undefined && detected !== explicit) {
      fail(`explicit syntax ${explicit} does not match detected ${detected}`)
    }
    const syntax = explicit ?? detected
    const absolute = path.resolve(filename)
    const parent = path.dirname(absolute)
    const resolver = createConfinedResolver({ roots: [parent] })
    const session = resolver.createSession()
    let loaded
    try {
      loaded = await session.load(pathToFileURL(absolute).href, {
        kind: 'import',
        ancestry: [],
      })
    } finally {
      session.close()
    }
    let source
    try {
      source = new TextDecoder('utf-8', { fatal: true }).decode(loaded.contents)
    } catch {
      throw new ZigCssCompileError('API_INPUT_ENCODING', 'input file is not valid UTF-8')
    }
    const callerLoadPaths = normalizeLoadPaths(rawOptions.loadPaths, syntax)
    const loadPaths = syntax === 'css'
      ? []
      : deduplicateLoadPaths([resolver.roots[0], ...callerLoadPaths])
    return Object.freeze({
      source,
      options: Object.freeze({
        ...rawOptions,
        syntax,
        sourceUrl: loaded.url,
        loadPaths: Object.freeze(loadPaths),
      }),
    })
  } catch (error) {
    throw wrapFailure(error)
  }
}

export async function compileFileWithRuntime(filename, optionValue, runtimeValue) {
  const loaded = await loadFileForCompilation(filename, optionValue)
  return compileStringWithRuntime(loaded.source, loaded.options, runtimeValue)
}

export async function compileFile(filename, options) {
  return compileFileWithRuntime(filename, options, productionRuntime)
}
