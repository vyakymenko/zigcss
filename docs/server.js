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

function serveStatic(res, urlPath) {
  let fp = path.join(DIST_DIR, decodeURIComponent(urlPath))

  // directory → index.html
  if (fs.existsSync(fp) && fs.statSync(fp).isDirectory())
    fp = path.join(fp, 'index.html')

  // SPA fallback
  if (!fs.existsSync(fp))
    fp = path.join(DIST_DIR, 'index.html')

  const mime = MIME[path.extname(fp)] ?? 'application/octet-stream'
  res.writeHead(200, { 'Content-Type': mime })
  fs.createReadStream(fp).pipe(res)
}

async function handleCompile(req, res) {
  try {
    const { input, minify } = JSON.parse(await rawBody(req) || '{}')
    if (typeof input !== 'string') {
      res.writeHead(400, { 'Content-Type': 'application/json' })
      return res.end(JSON.stringify({ error: 'Missing or invalid input' }))
    }

    const id  = `zigcss-${Date.now()}-${Math.random().toString(36).slice(2)}`
    const ext = (input.trimStart().startsWith('$') || input.includes('@mixin')) ? 'scss' : 'css'
    const inp = path.join(os.tmpdir(), `${id}.${ext}`)
    const out = path.join(os.tmpdir(), `${id}.out.css`)
    fs.writeFileSync(inp, input, 'utf8')

    const args = [inp, '-o', out]
    if (minify) args.push('--minify')

    const result = await new Promise(resolve => {
      const child = spawn(ZIGCSS_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
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

createServer(async (req, res) => {
  const url = req.url?.split('?')[0] ?? '/'

  if (url === '/api/compile' || url === '/zigcss/api/compile') {
    if (req.method !== 'POST') {
      res.writeHead(405, { 'Content-Type': 'application/json' })
      return res.end(JSON.stringify({ error: 'Method not allowed' }))
    }
    return handleCompile(req, res)
  }

  serveStatic(res, url)
}).listen(PORT, '0.0.0.0', () =>
  console.log(`zigcss docs listening on :${PORT}`)
)
