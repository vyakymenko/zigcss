/**
 * Production server for the zigcss docs website.
 * Serves the Vite-built static files. The public compile API is deliberately
 * unavailable until its resource limits and process isolation are verified.
 */
import { createServer } from 'http'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIST_DIR  = path.join(__dirname, 'dist')
const PORT      = Number(process.env.PORT ?? 8080)

export const MIME = {
  '.html' : 'text/html; charset=utf-8',
  '.js'   : 'application/javascript',
  '.mjs'  : 'application/javascript',
  '.css'  : 'text/css',
  '.json' : 'application/json',
  '.png'  : 'image/png',
  '.jpg'  : 'image/jpeg',
  '.svg'  : 'image/svg+xml',
  '.ico'  : 'image/x-icon',
  '.woff' : 'font/woff',
  '.woff2': 'font/woff2',
  '.txt'  : 'text/plain',
  '.xml'  : 'application/xml; charset=utf-8',
  '.map'  : 'application/json',
  '.webmanifest': 'application/manifest+json',
}

export const PAGES_BASE_PATH = '/zigcss'

// GitHub Pages receives the supported subset through an HTML meta policy.
// frame-ancestors and the remaining response-only headers below are enforced
// only when this static server is the HTTP origin; Pages owns its own headers.
export const META_CONTENT_SECURITY_POLICY = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"
export const CONTAINER_CONTENT_SECURITY_POLICY = `${META_CONTENT_SECURITY_POLICY}; frame-ancestors 'none'`
export const CONTAINER_PERMISSIONS_POLICY = 'camera=(), geolocation=(), microphone=(), payment=(), usb=()'

export const SECURITY_HEADERS = Object.freeze({
  'Content-Security-Policy': CONTAINER_CONTENT_SECURITY_POLICY,
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Permissions-Policy': CONTAINER_PERMISSIONS_POLICY,
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
})

class StaticRequestError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

export const MAX_STATIC_FILE_BYTES = 16 * 1024 * 1024
const MAX_STATIC_ENTRIES = 4096
const MAX_STATIC_DEPTH = 32

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino &&
    left.size === right.size && left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs
}

function requireStableDirectories(parents) {
  for (const parent of parents) {
    const current = fs.lstatSync(parent.file, { bigint: true })
    if (!current.isDirectory() || current.isSymbolicLink() ||
        !sameIdentity(parent.metadata, current)) {
      throw new StaticRequestError(403, 'Static directory changed')
    }
  }
}

function staticInventory(root) {
  const directories = new Set([''])
  const files = new Map()
  const forbidden = new Set()
  let entryCount = 0

  const visit = (directory, segments, parents) => {
    if (segments.length > MAX_STATIC_DEPTH)
      throw new StaticRequestError(500, 'Static inventory limit exceeded')
    requireStableDirectories(parents)
    const handle = fs.opendirSync(directory)
    try {
      for (let entry = handle.readSync(); entry !== null; entry = handle.readSync()) {
        if (++entryCount > MAX_STATIC_ENTRIES)
          throw new StaticRequestError(500, 'Static inventory limit exceeded')
        const entrySegments = [...segments, entry.name]
        const route = entrySegments.join('/')
        const entryPath = path.join(directory, entry.name)
        const metadata = fs.lstatSync(entryPath, { bigint: true })
        if (metadata.isSymbolicLink()) {
          forbidden.add(route)
        } else if (metadata.isDirectory()) {
          directories.add(route)
          visit(entryPath, entrySegments, [...parents, { file: entryPath, metadata }])
        } else if (metadata.isFile()) {
          const canonical = fs.realpathSync(entryPath)
          const relative = path.relative(root, canonical)
          if (
            relative === '..' ||
            relative.startsWith(`..${path.sep}`) ||
            path.isAbsolute(relative)
          ) {
            throw new StaticRequestError(403, 'Forbidden')
          }
          files.set(route, { file: canonical, metadata, parents })
        }
      }
    } finally {
      handle.closeSync()
    }
    requireStableDirectories(parents)
  }

  visit(root, [], [{ file: root, metadata: fs.lstatSync(root, { bigint: true }) }])
  return { directories, files, forbidden }
}

function requestedStaticRoute(urlPath) {
  let decodedPath
  try {
    decodedPath = decodeURIComponent(urlPath)
  } catch {
    throw new StaticRequestError(400, 'Malformed URL encoding')
  }

  if (decodedPath.includes('\0'))
    throw new StaticRequestError(400, 'Malformed URL path')

  const mountedPath = decodedPath === PAGES_BASE_PATH
    ? '/'
    : decodedPath.startsWith(`${PAGES_BASE_PATH}/`)
      ? decodedPath.slice(PAGES_BASE_PATH.length)
      : decodedPath
  const segments = mountedPath.replaceAll('\\', '/').split('/')
  if (segments.includes('..')) throw new StaticRequestError(403, 'Forbidden')
  return segments.filter(segment => segment !== '' && segment !== '.').join('/')
}

function resolveStaticEntry(distDir, urlPath) {
  const root = fs.realpathSync(distDir)
  const route = requestedStaticRoute(urlPath)
  const inventory = staticInventory(root)
  if ([...inventory.forbidden].some(prefix => route === prefix || route.startsWith(`${prefix}/`))) {
    throw new StaticRequestError(403, 'Forbidden')
  }

  let candidate = inventory.files.get(route)
  if (candidate === undefined && inventory.directories.has(route)) {
    candidate = inventory.files.get(route === '' ? 'index.html' : `${route}/index.html`)
  }

  // Preserve the SPA fallback only for extensionless application routes.
  // A missing script, stylesheet, font, or image must never receive HTML.
  if (candidate === undefined && path.posix.extname(route) !== '')
    throw new StaticRequestError(404, 'Not found')
  if (candidate === undefined)
    candidate = inventory.files.get('index.html')

  if (candidate === undefined)
    throw new StaticRequestError(404, 'Not found')
  return { root, candidate }
}

export function resolveStaticFile(distDir, urlPath) {
  return resolveStaticEntry(distDir, urlPath).candidate.file
}

function readStaticFile(candidate) {
  requireStableDirectories(candidate.parents)
  let descriptor
  try {
    descriptor = fs.openSync(candidate.file, fs.constants.O_RDONLY |
      (fs.constants.O_NOFOLLOW ?? 0) | (fs.constants.O_NONBLOCK ?? 0))
  } catch (error) {
    if (error.code === 'ELOOP') throw new StaticRequestError(403, 'Forbidden')
    throw error
  }

  try {
    // The inventory is only a pathname allowlist. Bind its identity to one
    // descriptor before reading, and never reopen that pathname for delivery.
    const opened = fs.fstatSync(descriptor, { bigint: true })
    if (!opened.isFile() || !sameIdentity(candidate.metadata, opened))
      throw new StaticRequestError(403, 'Static file changed')
    if (opened.size > BigInt(MAX_STATIC_FILE_BYTES))
      throw new StaticRequestError(413, 'Static file too large')
    requireStableDirectories(candidate.parents)
    const bytes = Buffer.alloc(Number(opened.size))
    let offset = 0
    while (offset < bytes.length) {
      const count = fs.readSync(descriptor, bytes, offset, bytes.length - offset, offset)
      if (count === 0) throw new StaticRequestError(403, 'Static file changed')
      offset += count
    }
    const after = fs.fstatSync(descriptor, { bigint: true })
    if (!sameIdentity(opened, after))
      throw new StaticRequestError(403, 'Static file changed')
    requireStableDirectories(candidate.parents)
    return bytes
  } finally {
    fs.closeSync(descriptor)
  }
}

export function contentTypeFor(file) {
  return MIME[path.extname(file)] ?? 'application/octet-stream'
}

function cacheControlFor(root, file) {
  const relative = path.relative(root, file)
  if (relative.split(path.sep)[0] === 'assets')
    return 'public, max-age=31536000, immutable'
  if (path.extname(file) === '.html')
    return 'no-cache'
  return 'public, max-age=300'
}

function serveStatic(req, res, urlPath, distDir) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, {
      ...SECURITY_HEADERS,
      'Allow': 'GET, HEAD',
      'Cache-Control': 'no-store',
      'Content-Type': 'text/plain; charset=utf-8',
    })
    return res.end('Method not allowed')
  }

  let fp
  let root
  let bytes
  try {
    const resolved = resolveStaticEntry(distDir, urlPath)
    fp = resolved.candidate.file
    root = resolved.root
    bytes = readStaticFile(resolved.candidate)
  } catch (error) {
    const status = error instanceof StaticRequestError ? error.status : 500
    const message = error instanceof StaticRequestError ? error.message : 'Static file error'
    res.writeHead(status, {
      ...SECURITY_HEADERS,
      'Cache-Control': 'no-store',
      'Content-Type': 'text/plain; charset=utf-8',
    })
    return res.end(message)
  }

  const mime = contentTypeFor(fp)
  const headers = {
    ...SECURITY_HEADERS,
    'Cache-Control': cacheControlFor(root, fp),
    'Content-Length': bytes.length,
    'Content-Type': mime,
  }
  if (req.method === 'HEAD') {
    res.writeHead(200, headers)
    return res.end()
  }

  res.writeHead(200, headers)
  res.end(bytes)
}

export function createDocsServer({ distDir = DIST_DIR } = {}) {
  return createServer((req, res) => {
    const url = req.url?.split('?')[0] ?? '/'

    if (url === '/api/compile' || url === '/zigcss/api/compile') {
      res.writeHead(503, {
        ...SECURITY_HEADERS,
        'Cache-Control': 'no-store',
        'Content-Type': 'application/json',
      })
      return res.end(JSON.stringify({
        error: 'Compile API disabled pending security hardening',
      }))
    }

    serveStatic(req, res, url, distDir)
  })
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  createDocsServer().listen(PORT, '0.0.0.0', () =>
    console.log(`zigcss docs listening on :${PORT}`)
  )
}
