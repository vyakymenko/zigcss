import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import stylus from 'stylus'
import {
  ProviderFailure,
  normalizeDiagnostics,
} from '../metadata.mjs'
import { parseSourceMap } from '../source-map.mjs'
import { imageDimensions } from '../image-dimensions.mjs'
import { createStylusImportAuthority } from './stylus-importer.mjs'

export const STYLUS_VERSION = '0.64.0'

const require = createRequire(import.meta.url)
const INTERNAL_FUNCTIONS_PATH = require.resolve('stylus/lib/functions/index.styl')
const VIRTUAL_DIRECTORY = path.join(
  path.parse(INTERNAL_FUNCTIONS_PATH).root,
  '__zigcss_stylus__',
)
const VIRTUAL_FILENAME = path.join(VIRTUAL_DIRECTORY, 'input.styl')
const VIRTUAL_SOURCE_URL = 'zigcss-entry://entry/input.styl'
const FILESYSTEM_SENTINEL = 'ZIGCSS_STYLUS_FILESYSTEM_DISABLED'
const PLUGIN_SENTINEL = 'ZIGCSS_STYLUS_PLUGIN_DISABLED'
const MAX_CAPTURED_DIAGNOSTICS = 1000
const MAX_JSON_DEPTH = 64
const MAX_JSON_VALUES = 4096
const assetUtf8 = new TextDecoder('utf-8', { fatal: true })
const embeddedMimes = Object.freeze({
  '.eot': 'application/vnd.ms-fontobject',
  '.gif': 'image/gif',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ttf': 'application/x-font-ttf',
  '.webp': 'image/webp',
  '.woff': 'application/font-woff',
  '.woff2': 'application/font-woff2',
})
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
    !hasExactKeys(request.options.providerOptions, ['hoistAtrules', 'includeCss']) ||
    typeof request.options.providerOptions.hoistAtrules !== 'boolean' ||
    typeof request.options.providerOptions.includeCss !== 'boolean'
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
    sourceUrl: state.currentSourceUrl,
    line: null,
    column: null,
  })
}

function parseAuthoredUrl(value) {
  const hashIndex = value.indexOf('#')
  const queryIndex = value.indexOf('?')
  const pathEnd = Math.min(
    hashIndex === -1 ? value.length : hashIndex,
    queryIndex === -1 ? value.length : queryIndex,
  )
  const scheme = /^[A-Za-z][A-Za-z0-9+.-]*:/.exec(value)
  return {
    hash: hashIndex === -1 ? '' : value.slice(hashIndex),
    href: value,
    pathname: value.slice(0, pathEnd),
    protocol: scheme?.[0] ?? (value.startsWith('//') ? '//' : null),
  }
}

function createLanguageFunctions(state, authority) {
  function abortAsset(code, message) {
    if (state.filesystemFailure === null) {
      state.filesystemFailure = Object.freeze({ code, message })
    }
    throw new Error(FILESYSTEM_SENTINEL)
  }

  function loadAsset(specifier, optional = false) {
    return authority.loadAsset(specifier, state.currentVirtualFilename, {
      ancestry: state.currentAncestry,
      optional,
    })
  }

  function confinedJson(filename, local, namePrefix) {
    stylus.utils.assertString(filename, 'path')
    const options = local?.nodeName === 'object' ? local : null
    const optional = options?.get('optional').toBoolean().isTrue === true
    const loaded = loadAsset(filename.string, optional)
    if (loaded === null) return stylus.nodes.null
    let value
    try {
      value = JSON.parse(assetUtf8.decode(loaded.contents))
    } catch {
      abortAsset('STYLUS_ASSET_INVALID', 'A confined Stylus JSON asset is invalid')
    }

    let values = 0
    function count(depth) {
      values += 1
      if (depth > MAX_JSON_DEPTH || values > MAX_JSON_VALUES) {
        abortAsset('STYLUS_ASSET_LIMIT', 'A confined Stylus JSON asset exceeded its structure limit')
      }
    }
    function convertedObject(object, conversionOptions, depth = 0) {
      count(depth)
      const output = new stylus.nodes.Object()
      const leaveStrings = conversionOptions.get('leave-strings').toBoolean()
      for (const key of Object.keys(object ?? {})) {
        const current = object[key]
        let converted
        if (current !== null && typeof current === 'object') {
          converted = convertedObject(current, conversionOptions, depth + 1)
        } else {
          count(depth + 1)
          converted = stylus.utils.coerce(current)
          if (converted.nodeName === 'string' && leaveStrings.isFalse) {
            converted = stylus.utils.parseString(converted.string)
          }
        }
        output.set(key, converted)
      }
      return output
    }
    if (options !== null) return convertedObject(value, options)

    if (namePrefix !== undefined) {
      stylus.utils.assertString(namePrefix, 'namePrefix')
      namePrefix = namePrefix.val
    } else {
      namePrefix = ''
    }
    local = local ? local.toBoolean() : new stylus.nodes.Boolean(local)
    const scope = local.isTrue ? this.currentScope : this.global.scope
    function defineVariables(object, prefix = '', depth = 0) {
      count(depth)
      const nestedPrefix = prefix ? `${prefix}-` : ''
      for (const key of Object.keys(object ?? {})) {
        const current = object[key]
        const name = `${nestedPrefix}${key}`
        if (current !== null && typeof current === 'object') {
          defineVariables(current, name, depth + 1)
        } else {
          count(depth + 1)
          let converted = stylus.utils.coerce(current)
          if (converted.nodeName === 'string') converted = stylus.utils.parseString(converted.string)
          scope.add({ name: `${namePrefix}${name}`, val: converted })
        }
      }
    }
    defineVariables(value)
    return undefined
  }
  confinedJson.params = ['path', 'local', 'namePrefix']

  function confinedImageSize(image, ignoreError) {
    stylus.utils.assertType(image, 'string', 'img')
    const loaded = loadAsset(image.string, ignoreError !== undefined)
    if (loaded === null) return [new stylus.nodes.Unit(0), new stylus.nodes.Unit(0)]
    let dimensions
    try {
      dimensions = imageDimensions(loaded.contents)
    } catch {
      abortAsset('STYLUS_ASSET_INVALID', 'A confined Stylus image asset is invalid')
    }
    return [
      new stylus.nodes.Unit(dimensions.width, 'px'),
      new stylus.nodes.Unit(dimensions.height, 'px'),
    ]
  }
  confinedImageSize.params = ['img', 'ignoreErr']

  function confinedEmbedUrl(url, encoding) {
    const compiler = new stylus.Compiler(url)
    compiler.isURL = true
    const authored = url.nodes.map(node => compiler.visit(node)).join('')
    const parsed = parseAuthoredUrl(authored)
    const extension = path.extname(parsed.pathname ?? '')
    const mime = embeddedMimes[extension]
    const literal = new stylus.nodes.Literal(`url("${parsed.href}")`)
    if (mime === undefined || parsed.protocol) return literal
    const loaded = loadAsset(parsed.pathname, true)
    if (loaded === null) return literal
    let type = 'base64'
    let result
    if (encoding && encoding.first?.val?.toLowerCase() === 'utf8') {
      type = 'charset=utf-8'
      result = loaded.contents.toString()
        .replace(/\s+/g, ' ')
        .replace(/[{}|\\^~[\]`"<>#%]/g, character => (
          `%${character.charCodeAt(0).toString(16).toUpperCase()}`
        ))
        .trim()
    } else {
      result = `${loaded.contents.toString('base64')}${parsed.hash ?? ''}`
    }
    return new stylus.nodes.Literal(`url("data:${mime};${type},${result}")`)
  }
  confinedEmbedUrl.raw = true

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
    confinedEmbedUrl,
    confinedImageSize,
    confinedJson,
    disabledPlugin,
    capturedWarning,
    capturedInspect,
    capturedTrace,
  }
}

function createConfinedEvaluator(state, functions, authority) {
  return class ConfinedStylusEvaluator extends stylus.Evaluator {
    visit(node) {
      const previousAncestry = state.currentAncestry
      const previousSourceUrl = state.currentSourceUrl
      const previousVirtualFilename = state.currentVirtualFilename
      const sourceUrl = authority.sourceUrlForVirtual(node?.filename)
      if (sourceUrl !== undefined) {
        state.currentAncestry = [...this.importStack]
        state.currentSourceUrl = sourceUrl
        state.currentVirtualFilename = node.filename
      }
      try {
        return stylus.Visitor.prototype.visit.call(this, node)
      } catch (error) {
        if (error.filename) throw error
        error.lineno = node.lineno
        error.column = node.column
        error.filename = node.filename
        error.stylusStack = this.stack.toString()
        throw error
      } finally {
        state.currentAncestry = previousAncestry
        state.currentSourceUrl = previousSourceUrl
        state.currentVirtualFilename = previousVirtualFilename
      }
    }

    populateGlobalScope() {
      super.populateGlobalScope()
      this.global.scope.add(new stylus.nodes.Ident(
        'embedurl',
        new stylus.nodes.Function('embedurl', functions.confinedEmbedUrl),
      ))
    }

    visitImport(imported) {
      if (
        state.internalImports === 0 &&
        imported?.path?.first?.string === INTERNAL_FUNCTIONS_PATH &&
        imported?.filename === VIRTUAL_FILENAME
      ) {
        state.internalImports += 1
        return super.visitImport(imported)
      }

      this.return += 1
      const evaluated = this.visit(imported.path).first
      this.return -= 1
      const nodeName = imported.once ? 'require' : 'import'
      if (evaluated?.name === 'url') {
        if (imported.once) throw new Error('You cannot @require a url')
        return imported
      }
      if (typeof evaluated?.string !== 'string') {
        throw new Error(`@${nodeName} string expected`)
      }
      const specifier = evaluated.string
      if (/(?:url\s*\(\s*)?['"]?(?:#|(?:https?:)?\/\/)/i.test(specifier)) {
        if (imported.once) throw new Error('You cannot @require a url')
        return imported
      }
      const literal = /\.css$/i.test(specifier)
      if (literal && !imported.once && !this.includeCSS) return imported

      const loaded = authority.resolve(specifier, imported.filename, {
        ancestry: [...this.importStack],
        kind: 'import',
        literal,
      })
      const block = new stylus.nodes.Block()
      for (const dependency of loaded) {
        block.push(this.importDependency(imported, dependency, literal))
      }
      return block
    }

    importDependency(imported, dependency, literal) {
      if (imported.once) {
        if (this.requireHistory[dependency.actualUrl]) return stylus.nodes.null
        this.requireHistory[dependency.actualUrl] = true
        if (literal && !this.includeCSS) return imported
      }
      if (this.importStack.includes(dependency.actualUrl)) {
        throw new Error('import loop has been found')
      }
      if (!dependency.source.trim()) return stylus.nodes.null

      imported.path = dependency.virtualFilename
      imported.dirname = path.dirname(dependency.virtualFilename)
      stylus.nodes.filename = dependency.virtualFilename
      if (literal) {
        const value = new stylus.nodes.Literal(dependency.source.replace(/\r\n?/g, '\n'))
        value.lineno = 1
        value.column = 1
        return value
      }

      let block = new stylus.nodes.Block()
      const parser = new stylus.Parser(dependency.source, {
        ...this.options,
        cache: false,
        filename: dependency.virtualFilename,
        root: block,
      })
      try {
        block = parser.parse()
      } catch (error) {
        error.filename = dependency.virtualFilename
        error.lineno = parser.lexer.lineno
        error.column = parser.lexer.column
        error.input = dependency.source
        throw error
      }

      block = block.clone(this.currentBlock)
      block.parent = this.currentBlock
      block.scope = false
      this.importStack.push(dependency.actualUrl)
      try {
        return this.visit(block)
      } finally {
        this.importStack.pop()
      }
    }
  }
}

function errorMetadata(error, authority) {
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
  const sourceUrl = source === null ? undefined : authority.sourceUrlForVirtual(source)
  if (source !== null && sourceUrl === undefined) {
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
  return { message, line, column, sourceUrl }
}

function ownDiagnostics(
  state,
  request,
  authority,
  error = null,
  errorCode = null,
  messageOverride = null,
) {
  if (state.overflow) {
    throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
  }
  const raw = [...state.values]
  if (error !== null) {
    const metadata = errorMetadata(error, authority)
    raw.push({
      severity: 'error',
      code: errorCode,
      message: messageOverride ?? metadata.message,
      sourceUrl: metadata.sourceUrl ?? request.sourceUrl,
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

function providerMap(value, request, authority) {
  let parsed
  try {
    parsed = parseSourceMap(JSON.stringify(value))
  } catch {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an invalid source map')
  }
  if (
    parsed.file !== 'input.css' ||
    parsed.sources.length === 0 ||
    Object.hasOwn(parsed, 'sourcesContent') ||
    Object.hasOwn(parsed, 'sourceRoot')
  ) {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an unexpected source identity')
  }

  const records = parsed.sources.map(source => authority.sourceMapRecord(source))
  if (records.some(record => record === null)) {
    throw failure('STYLUS_SOURCE_MAP_INVALID', 'Stylus returned an unexpected source identity')
  }
  const owned = JSON.stringify({
    version: 3,
    file: parsed.file,
    sources: records.map(record => record.sourceUrl),
    sourcesContent: records.map(record => record.source),
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

  const state = {
    currentAncestry: [],
    currentSourceUrl: request.sourceUrl,
    currentVirtualFilename: VIRTUAL_FILENAME,
    filesystemFailure: null,
    internalImports: 0,
    overflow: false,
    pluginRejected: false,
    sourceUrl: request.sourceUrl,
    values: [],
  }
  let authority
  try {
    authority = createStylusImportAuthority({
      roots: request.options.loadPaths,
      source: request.source,
      sourceUrl: request.sourceUrl,
      entryFilename: VIRTUAL_FILENAME,
      virtualDirectory: VIRTUAL_DIRECTORY,
      virtualSourceUrl: VIRTUAL_SOURCE_URL,
      signal,
    })
  } catch {
    throw failure('STYLUS_IMPORT_POLICY', 'Stylus received an invalid confined load root')
  }
  const functions = createLanguageFunctions(state, authority)
  const renderer = stylus(request.source, {
    Evaluator: createConfinedEvaluator(state, functions, authority),
    cache: false,
    compress: request.options.style === 'compressed',
    filename: VIRTUAL_FILENAME,
    functions: {},
    globals: {},
    'hoist atrules': request.options.providerOptions.hoistAtrules,
    imports: [],
    'include css': request.options.providerOptions.includeCss,
    paths: [],
    use: [],
    warn: false,
  })
  renderer.define('json', functions.confinedJson)
  renderer.define('image-size', functions.confinedImageSize)
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
  let renderError = null
  try {
    css = await render(renderer)
  } catch (error) {
    renderError = error
  } finally {
    authority.close()
  }
  if (renderError !== null) {
    const error = renderError
    if (signal?.aborted === true) throw cancellation()
    if (state.overflow) {
      throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
    }
    if (authority.failure !== null) {
      throw new ProviderFailure(
        authority.failure.code,
        authority.failure.message,
        ownDiagnostics(
          state,
          request,
          authority,
          error,
          'stylus.import',
          authority.failure.message,
        ),
      )
    }
    if (state.filesystemFailure !== null) {
      throw new ProviderFailure(
        state.filesystemFailure.code,
        state.filesystemFailure.message,
        ownDiagnostics(
          state,
          request,
          authority,
          error,
          'stylus.filesystem',
          state.filesystemFailure.message,
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
          authority,
          error,
          'stylus.plugin',
          'Stylus plugins are disabled',
        ),
      )
    }
    throw new ProviderFailure(
      'STYLUS_COMPILE_ERROR',
      'Stylus rejected the input',
      ownDiagnostics(state, request, authority, error, 'stylus.compile'),
    )
  }

  if (signal?.aborted === true) throw cancellation()
  if (state.overflow) {
    throw failure('STYLUS_DIAGNOSTIC_LIMIT', 'Stylus exceeded the diagnostic limit')
  }
  if (
    typeof css !== 'string' ||
    state.internalImports !== 1 ||
    authority.failure !== null ||
    state.filesystemFailure !== null ||
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
    sourceMap: request.options.sourceMap
      ? providerMap(renderer.sourcemap, request, authority)
      : null,
    diagnostics: ownDiagnostics(state, request, authority),
    dependencies: authority.dependencies(),
  }
}

export function createStylusProvider() {
  return Object.freeze({
    syntaxes,
    compile: compileStylus,
  })
}
