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

function isWithinRoot(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

export function resolveStaticFile(distDir, urlPath) {
  let decodedPath
  try {
    decodedPath = decodeURIComponent(urlPath)
  } catch {
    throw new StaticRequestError(400, 'Malformed URL encoding')
  }

  if (decodedPath.includes('\0'))
    throw new StaticRequestError(400, 'Malformed URL path')

  const root = fs.realpathSync(distDir)
  const mountedPath = decodedPath === PAGES_BASE_PATH
    ? '/'
    : decodedPath.startsWith(`${PAGES_BASE_PATH}/`)
      ? decodedPath.slice(PAGES_BASE_PATH.length)
      : decodedPath
  const portablePath = mountedPath.replace(/\\/g, '/').replace(/^\/+/, '')
  let candidate = path.resolve(root, portablePath)

  if (!isWithinRoot(root, candidate))
    throw new StaticRequestError(403, 'Forbidden')

  if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory())
    candidate = path.join(candidate, 'index.html')

  // Preserve the SPA fallback only for extensionless application routes.
  // A missing script, stylesheet, font, or image must never receive HTML.
  if (!fs.existsSync(candidate) && path.extname(candidate) !== '')
    throw new StaticRequestError(404, 'Not found')
  if (!fs.existsSync(candidate))
    candidate = path.join(root, 'index.html')

  if (!fs.existsSync(candidate))
    throw new StaticRequestError(404, 'Not found')

  const realCandidate = fs.realpathSync(candidate)
  if (!isWithinRoot(root, realCandidate))
    throw new StaticRequestError(403, 'Forbidden')

  if (!fs.statSync(realCandidate).isFile())
    throw new StaticRequestError(404, 'Not found')

  return realCandidate
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
  try {
    fp = resolveStaticFile(distDir, urlPath)
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
  let stat
  let root
  try {
    stat = fs.statSync(fp)
    root = fs.realpathSync(distDir)
  } catch {
    res.writeHead(500, {
      ...SECURITY_HEADERS,
      'Cache-Control': 'no-store',
      'Content-Type': 'text/plain; charset=utf-8',
    })
    return res.end('Static file error')
  }
  const headers = {
    ...SECURITY_HEADERS,
    'Cache-Control': cacheControlFor(root, fp),
    'Content-Length': stat.size,
    'Content-Type': mime,
  }
  if (req.method === 'HEAD') {
    res.writeHead(200, headers)
    return res.end()
  }

  const stream = fs.createReadStream(fp)
  stream.on('error', () => {
    if (!res.headersSent) {
      res.writeHead(500, {
        ...SECURITY_HEADERS,
        'Cache-Control': 'no-store',
        'Content-Type': 'text/plain; charset=utf-8',
      })
      res.end('Static file error')
    } else {
      res.destroy()
    }
  })
  res.writeHead(200, headers)
  stream.pipe(res)
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
