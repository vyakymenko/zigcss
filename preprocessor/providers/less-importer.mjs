import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const LESS_IMPORT_SENTINEL = 'ZIGCSS_LESS_IMPORT_FAILURE'
export const LESS_IMPORT_MISSING_SENTINEL = 'ZIGCSS_LESS_IMPORT_MISSING'

const absentCodes = new Set([
  'RESOLVER_MISSING',
  'RESOLVER_DIRECTORY',
  'RESOLVER_PARENT_NOT_DIRECTORY',
])
const utf8 = new TextDecoder('utf-8', { fatal: true })

function containsPath(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

function failureForResolver(error) {
  if (error?.code === 'RESOLVER_CYCLE') {
    return ['LESS_IMPORT_CYCLE', 'Less dependency resolution detected an import cycle']
  }
  if (error?.code === 'RESOLVER_DEPTH_LIMIT') {
    return ['LESS_IMPORT_DEPTH_LIMIT', 'Less dependency resolution exceeded its depth limit']
  }
  if (
    error?.code === 'RESOLVER_FILE_LIMIT' ||
    error?.code === 'RESOLVER_TOTAL_LIMIT' ||
    error?.code === 'RESOLVER_FILE_COUNT_LIMIT' ||
    error?.code === 'RESOLVER_READ_COUNT_LIMIT'
  ) {
    return ['LESS_IMPORT_LIMIT', 'Less dependency resolution exceeded a resource limit']
  }
  if (
    error?.code === 'RESOLVER_PATH_ESCAPE' ||
    error?.code === 'RESOLVER_SYMLINK' ||
    error?.code === 'RESOLVER_SCHEME' ||
    error?.code === 'RESOLVER_URL_INVALID' ||
    error?.code === 'RESOLVER_ANCESTRY_INVALID'
  ) {
    return ['LESS_IMPORT_POLICY', 'Less dependency resolution crossed the allowed file boundary']
  }
  if (
    error?.code === 'RESOLVER_UNREADABLE' ||
    error?.code === 'RESOLVER_NOT_REGULAR' ||
    error?.code === 'RESOLVER_FILE_CHANGED'
  ) {
    return ['LESS_IMPORT_IO', 'A confined Less dependency could not be read safely']
  }
  if (error?.code === 'RESOLVER_SESSION_BUSY') {
    return [
      'LESS_IMPORT_SYNC_UNAVAILABLE',
      'A synchronous Less dependency read overlapped asynchronous import work',
    ]
  }
  return ['LESS_IMPORT_FAILURE', 'Less dependency resolution failed']
}

function providerError(message) {
  return { type: 'File', message }
}

function canonicalKey(actualUrl, ancestry) {
  return `f-${createHash('sha256')
    .update(JSON.stringify([actualUrl, ...ancestry]))
    .digest('hex')}`
}

function identity(value) {
  return process.platform === 'win32' ? value.toLowerCase() : value
}

function uniquePaths(values) {
  const seen = new Set()
  const output = []
  for (const value of values) {
    if (value === null) continue
    const normalized = path.resolve(value)
    const key = identity(normalized)
    if (seen.has(key)) continue
    seen.add(key)
    output.push(normalized)
  }
  return output
}

export function createLessImportAuthority({
  lessApi,
  session,
  loadPaths,
  sourceUrl,
  entryFilename,
  signal,
}) {
  const state = { failure: null }
  const inputRoots = loadPaths.map(root => path.resolve(root))
  const orderedRoots = inputRoots.map(root => fs.realpathSync(root))
  const bytesByActualUrl = new Map()
  const byContext = new Map()
  const byVirtualFilename = new Map()
  const byVirtualDirectory = new Map()
  const entryDirectoryName = `${path.posix.dirname(entryFilename)}/`
  let entryDirectory = null

  if (sourceUrl !== null) {
    const filename = fileURLToPath(sourceUrl)
    for (let index = 0; index < inputRoots.length; index += 1) {
      const inputRoot = inputRoots[index]
      const canonicalRoot = orderedRoots[index]
      if (containsPath(inputRoot, filename)) {
        entryDirectory = path.resolve(
          canonicalRoot,
          path.relative(inputRoot, path.dirname(filename)),
        )
        break
      }
      if (containsPath(canonicalRoot, filename)) {
        entryDirectory = path.dirname(filename)
        break
      }
    }
  }

  function setFailure(code, message) {
    if (state.failure === null) state.failure = Object.freeze({ code, message })
  }

  function abort(code, message) {
    setFailure(code, message)
    throw providerError(LESS_IMPORT_SENTINEL)
  }

  function checkCancellation() {
    if (signal?.aborted === true) {
      abort('LESS_CANCELLED', 'Less compilation was cancelled')
    }
  }

  function abortResolver(error) {
    const [code, message] = failureForResolver(error)
    abort(code, message)
  }

  function ancestryAndBases(currentDirectory) {
    if (currentDirectory === entryDirectoryName) {
      return {
        ancestry: [],
        bases: uniquePaths([entryDirectory, ...orderedRoots]),
      }
    }
    const parent = byVirtualDirectory.get(currentDirectory)
    if (parent === undefined) {
      abort('LESS_IMPORT_IDENTITY', 'Less returned an unknown dependency identity')
    }
    return {
      ancestry: [...parent.ancestry, parent.actualUrl],
      bases: uniquePaths([path.dirname(fileURLToPath(parent.actualUrl)), ...orderedRoots]),
    }
  }

  function normalizedSpecifier(manager, filename, options) {
    if (
      typeof filename !== 'string' ||
      filename.length === 0 ||
      Buffer.byteLength(filename, 'utf8') > 8192 ||
      /[\u0000\r\n]/.test(filename) ||
      /[?#]/.test(filename) ||
      /%2f|%5c|%00/i.test(filename) ||
      filename.startsWith('~')
    ) {
      abort('LESS_IMPORT_POLICY', 'Less dependency resolution received an invalid path')
    }
    if (/^[\\/]{2}/.test(filename) || filename.startsWith('#')) {
      abort('LESS_IMPORT_POLICY', 'Less dependency resolution crossed the allowed file boundary')
    }
    if (!path.isAbsolute(filename) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(filename)) {
      abort('LESS_IMPORT_POLICY', 'Less dependency resolution permits only confined local files')
    }
    if (options?.prefixes !== undefined && (
      !Array.isArray(options.prefixes) ||
      options.prefixes.length !== 1 ||
      options.prefixes[0] !== ''
    )) {
      abort('LESS_IMPORT_POLICY', 'Less package and plugin resolution are disabled')
    }
    if (options?.ext !== undefined && options.ext !== '.less') {
      abort('LESS_IMPORT_POLICY', 'Less requested an unsupported import extension')
    }

    let parts
    try {
      parts = manager.extractUrlParts(filename)
    } catch {
      abort('LESS_IMPORT_POLICY', 'Less dependency resolution received an invalid path')
    }
    if (parts.hostPart && !path.isAbsolute(filename)) {
      abort('LESS_IMPORT_POLICY', 'Less dependency resolution permits only confined local files')
    }
    const withoutParameters = `${parts.rawPath}${parts.filename}`
    return options?.ext === '.less'
      ? manager.tryAppendExtension(withoutParameters, '.less')
      : withoutParameters
  }

  function remember(loaded, ancestry) {
    const existingBytes = bytesByActualUrl.get(loaded.url)
    if (existingBytes !== undefined) {
      if (!existingBytes.equals(loaded.contents)) {
        abort('LESS_IMPORT_CHANGED', 'A Less dependency changed during compilation')
      }
    } else {
      bytesByActualUrl.set(loaded.url, Buffer.from(loaded.contents))
    }

    const contextIdentity = JSON.stringify([loaded.url, ...ancestry])
    const existing = byContext.get(contextIdentity)
    if (existing !== undefined) return existing

    const key = canonicalKey(loaded.url, ancestry)
    const filename = fileURLToPath(loaded.url)
    const virtualDirectory = `/__zigcss_less_imports__/${key}/`
    const virtualFilename = `${virtualDirectory}${path.basename(filename)}`
    if (byVirtualFilename.has(virtualFilename) || byVirtualDirectory.has(virtualDirectory)) {
      abort('LESS_IMPORT_IDENTITY', 'Less dependency identity could not be made unique')
    }
    const entry = Object.freeze({
      actualUrl: loaded.url,
      ancestry: Object.freeze([...ancestry]),
      bytes: Buffer.from(loaded.contents),
      virtualDirectory,
      virtualFilename,
    })
    byContext.set(contextIdentity, entry)
    byVirtualFilename.set(virtualFilename, entry)
    byVirtualDirectory.set(virtualDirectory, entry)
    return entry
  }

  async function resolve(manager, filename, currentDirectory, options) {
    checkCancellation()
    const { ancestry, bases } = ancestryAndBases(currentDirectory)
    const specifier = normalizedSpecifier(manager, filename, options)
    const candidates = path.isAbsolute(specifier)
      ? [path.resolve(specifier)]
      : bases.map(base => path.resolve(base, specifier))
    for (const candidate of uniquePaths(candidates)) {
      checkCancellation()
      try {
        const loaded = await session.load(pathToFileURL(candidate).href, {
          kind: 'import',
          ancestry,
        })
        checkCancellation()
        return remember(loaded, ancestry)
      } catch (error) {
        if (state.failure !== null) throw error
        if (absentCodes.has(error?.code)) continue
        abortResolver(error)
      }
    }
    throw providerError(LESS_IMPORT_MISSING_SENTINEL)
  }

  function resolveSync(manager, filename, currentDirectory, options) {
    checkCancellation()
    const { bases } = ancestryAndBases(currentDirectory)
    const specifier = normalizedSpecifier(manager, filename, options)
    const candidates = path.isAbsolute(specifier)
      ? [path.resolve(specifier)]
      : bases.map(base => path.resolve(base, specifier))
    for (const candidate of uniquePaths(candidates)) {
      checkCancellation()
      try {
        const loaded = session.loadSync(pathToFileURL(candidate).href, {
          kind: 'reference',
          ancestry: [],
        })
        checkCancellation()
        return remember(loaded, [])
      } catch (error) {
        if (state.failure !== null) throw error
        if (absentCodes.has(error?.code)) continue
        abortResolver(error)
      }
    }
    throw providerError(LESS_IMPORT_MISSING_SENTINEL)
  }

  function actualDirectoryForProviderDirectory(value) {
    if (value === entryDirectoryName) return entryDirectory
    const entry = byVirtualDirectory.get(value)
    return entry === undefined ? null : path.dirname(fileURLToPath(entry.actualUrl))
  }

  class ConfinedFileManager extends lessApi.FileManager {
    supports() {
      return true
    }

    supportsSync() {
      return true
    }

    pathDiff(url, baseUrl) {
      const actualUrl = actualDirectoryForProviderDirectory(url)
      const actualBase = actualDirectoryForProviderDirectory(baseUrl)
      return actualUrl !== null && actualBase !== null
        ? super.pathDiff(`${actualUrl}${path.sep}`, `${actualBase}${path.sep}`)
        : super.pathDiff(url, baseUrl)
    }

    async loadFile(filename, currentDirectory, options) {
      const entry = await resolve(this, filename, currentDirectory, options)
      let contents
      try {
        contents = utf8.decode(entry.bytes)
      } catch {
        abort('LESS_IMPORT_ENCODING', 'A Less dependency is not valid UTF-8')
      }
      return { contents, filename: entry.virtualFilename }
    }

    loadFileSync(filename, currentDirectory, options) {
      if (options?.rawBuffer !== true) {
        abort(
          'LESS_IMPORT_SYNC_UNAVAILABLE',
          'Unowned synchronous Less file access is unavailable in the confined host',
        )
      }
      let entry
      try {
        entry = resolveSync(this, filename, currentDirectory, options)
      } catch (error) {
        if (error?.message === LESS_IMPORT_MISSING_SENTINEL && state.failure === null) {
          return { contents: null, filename: '' }
        }
        throw error
      }
      return { contents: Buffer.from(entry.bytes), filename: entry.virtualFilename }
    }
  }

  function actualUrlForProviderFilename(value) {
    if (value === entryFilename) return sourceUrl
    return byVirtualFilename.get(value)?.actualUrl ?? null
  }

  function actualUrlForMapSource(value) {
    if (value === 'input.less') return sourceUrl ?? 'zigcss-entry://entry/input.less'
    if (typeof value !== 'string' || /[\u0000\r\n]/.test(value)) return null
    const virtualFilename = path.posix.resolve(path.posix.dirname(entryFilename), value)
    return actualUrlForProviderFilename(virtualFilename)
  }

  function sourceContentForMapSource(value) {
    if (value === 'input.less') return null
    if (typeof value !== 'string' || /[\u0000\r\n]/.test(value)) return undefined
    const virtualFilename = path.posix.resolve(path.posix.dirname(entryFilename), value)
    const entry = byVirtualFilename.get(virtualFilename)
    if (entry === undefined) return undefined
    try {
      return utf8.decode(entry.bytes)
    } catch {
      return undefined
    }
  }

  return Object.freeze({
    fileManager: new ConfinedFileManager(),
    actualUrlForMapSource,
    actualUrlForProviderFilename,
    sourceContentForMapSource,
    dependencies() {
      return session.dependencies()
    },
    failure() {
      return state.failure === null ? null : { ...state.failure }
    },
    isMissingError(error) {
      return error?.message === LESS_IMPORT_MISSING_SENTINEL
    },
    close() {
      session.close()
    },
  })
}
