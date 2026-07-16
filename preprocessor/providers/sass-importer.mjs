import { createHash } from 'node:crypto'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const SASS_IMPORT_SENTINEL = 'ZIGCSS_SASS_IMPORT_FAILURE'

const canonicalScheme = 'zigcss-sass:'
const entryScheme = 'zigcss-entry:'
const absentCodes = new Set([
  'RESOLVER_MISSING',
  'RESOLVER_DIRECTORY',
  'RESOLVER_PARENT_NOT_DIRECTORY',
])
const extensionSet = new Set(['.sass', '.scss', '.css'])
const utf8 = new TextDecoder('utf-8', { fatal: true })

function containsPath(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

function partial(filename) {
  return path.join(path.dirname(filename), `_${path.basename(filename)}`)
}

function syntaxForUrl(url) {
  const extension = path.extname(fileURLToPath(url))
  if (extension === '.sass') return 'indented'
  if (extension === '.css') return 'css'
  return 'scss'
}

function canonicalKey(actualUrl) {
  return `f-${createHash('sha256').update(actualUrl).digest('hex')}`
}

function failureForResolver(error) {
  if (error?.code === 'RESOLVER_CYCLE') {
    return ['SASS_IMPORT_CYCLE', 'Sass dependency resolution detected an import cycle']
  }
  if (error?.code === 'RESOLVER_DEPTH_LIMIT') {
    return ['SASS_IMPORT_DEPTH_LIMIT', 'Sass dependency resolution exceeded its depth limit']
  }
  if (
    error?.code === 'RESOLVER_FILE_LIMIT' ||
    error?.code === 'RESOLVER_TOTAL_LIMIT' ||
    error?.code === 'RESOLVER_FILE_COUNT_LIMIT' ||
    error?.code === 'RESOLVER_READ_COUNT_LIMIT'
  ) {
    return ['SASS_IMPORT_LIMIT', 'Sass dependency resolution exceeded a resource limit']
  }
  if (
    error?.code === 'RESOLVER_PATH_ESCAPE' ||
    error?.code === 'RESOLVER_SYMLINK' ||
    error?.code === 'RESOLVER_SCHEME' ||
    error?.code === 'RESOLVER_URL_INVALID' ||
    error?.code === 'RESOLVER_ANCESTRY_INVALID'
  ) {
    return ['SASS_IMPORT_POLICY', 'Sass dependency resolution crossed the allowed file boundary']
  }
  if (
    error?.code === 'RESOLVER_UNREADABLE' ||
    error?.code === 'RESOLVER_NOT_REGULAR' ||
    error?.code === 'RESOLVER_FILE_CHANGED'
  ) {
    return ['SASS_IMPORT_IO', 'A confined Sass dependency could not be read safely']
  }
  return ['SASS_IMPORT_FAILURE', 'Sass dependency resolution failed']
}

function fileUrlFromVirtualPath(pathname) {
  if (/%2f|%5c|%00/i.test(pathname)) {
    throw new Error('encoded separator')
  }
  return new URL(pathname, 'file://')
}

function providerCanonicalUrl(key, actualUrl) {
  const actual = new URL(actualUrl)
  return new URL(`${canonicalScheme}//${key}${actual.pathname}`)
}

export function createSassImportAuthority({
  resolver,
  session,
  loadPaths,
  sourceUrl,
  entryUrl,
  signal,
}) {
  const state = { failure: null }
  const byActualUrl = new Map()
  const byKey = new Map()
  const orderedRoots = loadPaths.map(root => path.resolve(root))
  const admittedRoots = [...new Set([...orderedRoots, ...resolver.roots])]
  const entryVirtualFilename = fileURLToPath(fileUrlFromVirtualPath(entryUrl.pathname))
  let entryDirectory = null

  if (sourceUrl !== null) {
    const filename = fileURLToPath(sourceUrl)
    if (admittedRoots.some(root => containsPath(root, filename))) {
      entryDirectory = path.dirname(filename)
    }
  }

  function abort(code, message) {
    if (state.failure === null) state.failure = Object.freeze({ code, message })
    throw new Error(SASS_IMPORT_SENTINEL)
  }

  function abortResolver(error) {
    const [code, message] = failureForResolver(error)
    abort(code, message)
  }

  function checkCancellation() {
    if (signal?.aborted === true) abort('SASS_CANCELLED', 'Dart Sass compilation was cancelled')
  }

  function lineageForContainingUrl(value) {
    if (value === null || value === undefined) return []
    const parsed = value instanceof URL ? value : new URL(value)
    if (parsed.protocol === entryScheme) return []
    if (parsed.protocol !== canonicalScheme) {
      abort('SASS_IMPORT_POLICY', 'Sass dependency resolution crossed the allowed file boundary')
    }
    const parent = byKey.get(parsed.hostname)
    if (parent === undefined || parsed.pathname !== parent.virtualPath) {
      abort('SASS_IMPORT_IDENTITY', 'Sass returned an unknown dependency identity')
    }
    return [...parent.ancestry, parent.actualUrl]
  }

  function remember(loaded, ancestry) {
    const existing = byActualUrl.get(loaded.url)
    if (existing !== undefined) {
      if (!existing.bytes.equals(loaded.contents)) {
        abort('SASS_IMPORT_CHANGED', 'A Sass dependency changed during compilation')
      }
      return existing
    }

    const key = canonicalKey(loaded.url)
    const collision = byKey.get(key)
    if (collision !== undefined && collision.actualUrl !== loaded.url) {
      abort('SASS_IMPORT_IDENTITY', 'Sass dependency identity could not be made unique')
    }
    const canonicalUrl = providerCanonicalUrl(key, loaded.url)
    const entry = Object.freeze({
      actualUrl: loaded.url,
      ancestry: Object.freeze([...ancestry]),
      bytes: Buffer.from(loaded.contents),
      canonicalUrl,
      key,
      syntax: syntaxForUrl(loaded.url),
      virtualPath: canonicalUrl.pathname,
    })
    byActualUrl.set(loaded.url, entry)
    byKey.set(key, entry)
    return entry
  }

  async function probeGroup(candidates, kind, ancestry) {
    const matches = []
    const candidateSet = new Set()
    for (const filename of candidates) {
      const normalized = path.resolve(filename)
      if (candidateSet.has(normalized)) continue
      candidateSet.add(normalized)
      checkCancellation()
      try {
        const loaded = await session.load(pathToFileURL(normalized).href, { kind, ancestry })
        checkCancellation()
        matches.push(remember(loaded, ancestry))
      } catch (error) {
        if (state.failure !== null) throw error
        if (absentCodes.has(error?.code)) continue
        abortResolver(error)
      }
    }
    if (matches.length > 1) {
      abort('SASS_IMPORT_AMBIGUOUS', 'A Sass import matches more than one allowed stylesheet')
    }
    return matches[0] ?? null
  }

  async function tryWithExtensions(filename, kind, ancestry) {
    const sassOrScss = await probeGroup([
      partial(`${filename}.sass`),
      `${filename}.sass`,
      partial(`${filename}.scss`),
      `${filename}.scss`,
    ], kind, ancestry)
    if (sassOrScss !== null) return sassOrScss
    return await probeGroup([
      partial(`${filename}.css`),
      `${filename}.css`,
    ], kind, ancestry)
  }

  async function resolveImportPath(filename, fromImport, ancestry) {
    const kind = fromImport ? 'import' : 'reference'
    const extension = path.extname(filename)
    if (extensionSet.has(extension)) {
      if (fromImport) {
        const importOnly = `${filename.slice(0, -extension.length)}.import${extension}`
        const imported = await probeGroup([partial(importOnly), importOnly], kind, ancestry)
        if (imported !== null) return imported
      }
      return await probeGroup([partial(filename), filename], kind, ancestry)
    }

    if (fromImport) {
      const imported = await tryWithExtensions(`${filename}.import`, kind, ancestry)
      if (imported !== null) return imported
    }
    const direct = await tryWithExtensions(filename, kind, ancestry)
    if (direct !== null) return direct
    if (fromImport) {
      const importedIndex = await tryWithExtensions(
        path.join(filename, 'index.import'),
        kind,
        ancestry,
      )
      if (importedIndex !== null) return importedIndex
    }
    return await tryWithExtensions(path.join(filename, 'index'), kind, ancestry)
  }

  function decodeRelativeSpecifier(url) {
    if (
      typeof url !== 'string' ||
      url.length === 0 ||
      /%2f|%5c|%00/i.test(url) ||
      /[\u0000\r\n?#]/.test(url)
    ) {
      abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an invalid path')
    }
    try {
      return decodeURIComponent(url)
    } catch {
      abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an aliased URL')
    }
  }

  async function canonicalizeLocal(url, context) {
    checkCancellation()
    let parsed
    try {
      parsed = new URL(url)
    } catch {
      return null
    }
    if (
      parsed.username !== '' ||
      parsed.password !== '' ||
      parsed.port !== '' ||
      parsed.search !== '' ||
      parsed.hash !== ''
    ) {
      abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an aliased URL')
    }

    const fromImport = context?.fromImport === true
    if (parsed.protocol === canonicalScheme) {
      const parent = byKey.get(parsed.hostname)
      if (parent === undefined) {
        abort('SASS_IMPORT_IDENTITY', 'Sass returned an unknown dependency identity')
      }
      if (parsed.pathname === parent.virtualPath) return parent.canonicalUrl

      let directUrl
      try {
        directUrl = fileUrlFromVirtualPath(parsed.pathname)
      } catch {
        abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an aliased URL')
      }
      const filename = fileURLToPath(directUrl)
      const ancestry = [...parent.ancestry, parent.actualUrl]
      const local = await resolveImportPath(filename, fromImport, ancestry)
      return local?.canonicalUrl ?? null
    }

    if (parsed.protocol === entryScheme) {
      if (parsed.hostname !== 'entry') {
        abort('SASS_IMPORT_IDENTITY', 'Sass returned an unknown entry identity')
      }
      if (/%2f|%5c|%00/i.test(parsed.pathname)) {
        abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an aliased URL')
      }
      let filename
      try {
        filename = fileURLToPath(fileUrlFromVirtualPath(parsed.pathname))
      } catch {
        abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an aliased URL')
      }
      if (/\u0000|\r|\n/.test(filename)) {
        abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an invalid path')
      }
      if (entryDirectory !== null) {
        const local = await resolveImportPath(filename, fromImport, [])
        if (local !== null) return local.canonicalUrl
      }
      return null
    }

    if (parsed.protocol === 'file:') {
      const ancestry = lineageForContainingUrl(context?.containingUrl)
      let filename
      try {
        filename = fileURLToPath(parsed)
      } catch {
        abort('SASS_IMPORT_POLICY', 'Sass dependency resolution received an invalid file URL')
      }
      const result = await resolveImportPath(filename, fromImport, ancestry)
      return result?.canonicalUrl ?? null
    }

    abort('SASS_IMPORT_POLICY', 'Sass dependency resolution permits only confined local files')
  }

  async function canonicalizeFromRoot(root, url, context) {
    const local = await canonicalizeLocal(url, context)
    if (local !== null) return local
    let parsed = true
    try {
      new URL(url)
    } catch {
      parsed = false
    }
    if (parsed) return null
    const specifier = decodeRelativeSpecifier(url)
    const ancestry = lineageForContainingUrl(context?.containingUrl)
    const result = await resolveImportPath(
      path.resolve(root, specifier),
      context?.fromImport === true,
      ancestry,
    )
    return result?.canonicalUrl ?? null
  }

  async function load(canonicalUrl) {
    checkCancellation()
    const parsed = canonicalUrl instanceof URL ? canonicalUrl : new URL(canonicalUrl)
    if (parsed.protocol !== canonicalScheme) {
      abort('SASS_IMPORT_IDENTITY', 'Sass returned an unknown dependency identity')
    }
    const entry = byKey.get(parsed.hostname)
    if (entry === undefined || parsed.href !== entry.canonicalUrl.href) {
      abort('SASS_IMPORT_IDENTITY', 'Sass returned an unknown dependency identity')
    }
    let contents
    try {
      contents = utf8.decode(entry.bytes)
    } catch {
      abort('SASS_IMPORT_ENCODING', 'A Sass dependency is not valid UTF-8')
    }
    return {
      contents,
      syntax: entry.syntax,
      sourceMapUrl: new URL(entry.actualUrl),
    }
  }

  function actualUrlForProviderUrl(value) {
    let parsed
    try {
      parsed = value instanceof URL ? value : new URL(value)
    } catch {
      return null
    }
    if (parsed.protocol === canonicalScheme) {
      const entry = byKey.get(parsed.hostname)
      return entry !== undefined && parsed.href === entry.canonicalUrl.href
        ? entry.actualUrl
        : null
    }
    return byActualUrl.has(parsed.href) ? parsed.href : null
  }

  const nonCanonicalScheme = Object.freeze(['file', 'http', 'https', 'zigcss-entry'])
  const entryImporter = Object.freeze({
    nonCanonicalScheme,
    canonicalize: canonicalizeLocal,
    load,
  })
  const loadPathImporters = Object.freeze(orderedRoots.map(root => Object.freeze({
    nonCanonicalScheme,
    canonicalize(url, context) {
      return canonicalizeFromRoot(root, url, context)
    },
    load,
  })))

  return Object.freeze({
    importer: entryImporter,
    entryImporter,
    loadPathImporters,
    actualUrlForProviderUrl,
    dependencies() {
      return session.dependencies()
    },
    failure() {
      return state.failure === null ? null : { ...state.failure }
    },
    close() {
      session.close()
    },
  })
}
