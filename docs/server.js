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

const MIME = {
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
}

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
  const portablePath = decodedPath.replace(/\\/g, '/').replace(/^\/+/, '')
  let candidate = path.resolve(root, portablePath)

  if (!isWithinRoot(root, candidate))
    throw new StaticRequestError(403, 'Forbidden')

  if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory())
    candidate = path.join(candidate, 'index.html')

  // Preserve the existing SPA fallback, but only for paths contained by root.
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

function serveStatic(res, urlPath, distDir) {
  let fp
  try {
    fp = resolveStaticFile(distDir, urlPath)
  } catch (error) {
    const status = error instanceof StaticRequestError ? error.status : 500
    const message = error instanceof StaticRequestError ? error.message : 'Static file error'
    res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' })
    return res.end(message)
  }

  const mime = MIME[path.extname(fp)] ?? 'application/octet-stream'
  const stream = fs.createReadStream(fp)
  stream.on('error', () => {
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('Static file error')
    } else {
      res.destroy()
    }
  })
  res.writeHead(200, { 'Content-Type': mime })
  stream.pipe(res)
}

export function createDocsServer({ distDir = DIST_DIR } = {}) {
  return createServer((req, res) => {
    const url = req.url?.split('?')[0] ?? '/'

    if (url === '/api/compile' || url === '/zigcss/api/compile') {
      res.writeHead(503, {
        'Cache-Control': 'no-store',
        'Content-Type': 'application/json',
      })
      return res.end(JSON.stringify({
        error: 'Compile API disabled pending security hardening',
      }))
    }

    serveStatic(res, url, distDir)
  })
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  createDocsServer().listen(PORT, '0.0.0.0', () =>
    console.log(`zigcss docs listening on :${PORT}`)
  )
}
