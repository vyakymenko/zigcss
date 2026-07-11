/**
 * Production server for the zigcss docs website.
 * Serves the Vite-built static files AND handles POST /api/compile
 * by spawning the zigcss binary — same contract as the Vite dev plugin.
 */
import { createServer } from 'http'
import { spawn } from 'child_process'
import fs from 'fs'
import path from 'path'
import os from 'os'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIST_DIR  = path.join(__dirname, 'dist')
const PORT      = Number(process.env.PORT ?? 80)

const ZIGCSS_BIN = (() => {
  if (process.env.ZIGCSS_BIN) return process.env.ZIGCSS_BIN
  const local = path.join(__dirname, 'node_modules', '.bin', 'zigcss')
  if (fs.existsSync(local)) return local
  return '/usr/local/bin/zigcss'
})()

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

function rawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', c => chunks.push(c))
    req.on('end',  () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
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

function detectExt(input, format) {
  // Explicit format from the client takes priority
  if (format === 'scss') return 'scss'
  if (format === 'css')  return 'css'
  // Heuristic fallback: $ variables or @mixin → SCSS
  if (input.trimStart().startsWith('$') || input.includes('@mixin')) return 'scss'
  return 'css'
}

async function handleCompile(req, res, zigcssBin) {
  try {
    const { input, minify, format } = JSON.parse(await rawBody(req) || '{}')
    if (typeof input !== 'string') {
      res.writeHead(400, { 'Content-Type': 'application/json' })
      return res.end(JSON.stringify({ error: 'Missing or invalid input' }))
    }

    const id  = `zigcss-${Date.now()}-${Math.random().toString(36).slice(2)}`
    const ext = detectExt(input, format)
    const inp = path.join(os.tmpdir(), `${id}.${ext}`)
    const out = path.join(os.tmpdir(), `${id}.out.css`)
    fs.writeFileSync(inp, input, 'utf8')

    const args = [inp, '-o', out]
    if (minify) args.push('--minify')

    const result = await new Promise(resolve => {
      const child = spawn(zigcssBin, args, { stdio: ['ignore', 'pipe', 'pipe'] })
      let stderr = ''
      child.stderr?.on('data', d => { stderr += d.toString() })
      child.on('close', code => {
        try { fs.unlinkSync(inp) } catch (_) {}
        if (code === 0 && fs.existsSync(out)) {
          const css = fs.readFileSync(out, 'utf8')
          try { fs.unlinkSync(out) } catch (_) {}
          resolve({ css })
        } else {
          resolve({ error: stderr || `zigcss exited with code ${code}` })
        }
      })
      child.on('error', err => {
        resolve({ error: err.code === 'ENOENT' ? 'zigcss binary not found' : err.message })
      })
    })

    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(result))
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ error: err.message ?? 'Compilation failed' }))
  }
}

export function createDocsServer({ distDir = DIST_DIR, zigcssBin = ZIGCSS_BIN } = {}) {
  return createServer(async (req, res) => {
    const url = req.url?.split('?')[0] ?? '/'

    if (url === '/api/compile' || url === '/zigcss/api/compile') {
      if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'application/json' })
        return res.end(JSON.stringify({ error: 'Method not allowed' }))
      }
      return handleCompile(req, res, zigcssBin)
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
