// @vitest-environment node

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import type { AddressInfo } from 'node:net'
import type { Server } from 'node:http'
import {
  CONTAINER_CONTENT_SECURITY_POLICY,
  CONTAINER_PERMISSIONS_POLICY,
  createDocsServer,
  MAX_STATIC_FILE_BYTES,
  META_CONTENT_SECURITY_POLICY,
  SECURITY_HEADERS,
} from '../server.js'

const exactMetaContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"

type Response = {
  body: string
  headers: http.IncomingHttpHeaders
  contentType: string
  status: number
}

type RequestOptions = {
  body?: string
  method?: string
}

describe('docs static server containment', () => {
  let fixtureRoot: string
  let distDir: string
  let server: Server

  beforeEach(async () => {
    fixtureRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-server-test-')))
    distDir = path.join(fixtureRoot, 'dist')
    fs.mkdirSync(distDir)
    fs.writeFileSync(path.join(distDir, 'index.html'), '<h1>zigcss docs</h1>')
    fs.writeFileSync(path.join(distDir, 'app.css'), 'body { color: green; }')
    fs.writeFileSync(path.join(fixtureRoot, 'secret.json'), '{"secret":true}')

    server = createDocsServer({ distDir })
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })
  })

  afterEach(async () => {
    vi.restoreAllMocks()
    if (server?.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve())
        server.closeAllConnections()
      })
    }
    fs.rmSync(fixtureRoot, { force: true, recursive: true })
  })

  function request(urlPath: string, options: RequestOptions = {}): Promise<Response> {
    const address = server.address() as AddressInfo
    return new Promise((resolve, reject) => {
      const req = http.request({
        headers: options.body ? { 'Content-Length': Buffer.byteLength(options.body) } : undefined,
        host: '127.0.0.1',
        method: options.method ?? 'GET',
        path: urlPath,
        port: address.port,
      }, res => {
        const chunks: Buffer[] = []
        res.on('data', chunk => chunks.push(Buffer.from(chunk)))
        res.on('end', () => resolve({
          body: Buffer.concat(chunks).toString('utf8'),
          headers: res.headers,
          contentType: String(res.headers['content-type'] ?? ''),
          status: res.statusCode ?? 0,
        }))
      })
      req.on('error', reject)
      if (options.body)
        req.write(options.body)
      req.end()
    })
  }

  test('separates the exact deployable meta CSP from container-only response controls', () => {
    expect(META_CONTENT_SECURITY_POLICY).toBe(exactMetaContentSecurityPolicy)
    expect(META_CONTENT_SECURITY_POLICY).not.toContain('frame-ancestors')
    expect(CONTAINER_CONTENT_SECURITY_POLICY).toBe(
      `${exactMetaContentSecurityPolicy}; frame-ancestors 'none'`,
    )
    expect(CONTAINER_PERMISSIONS_POLICY).toBe(
      'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
    )
    expect(SECURITY_HEADERS).toEqual({
      'Content-Security-Policy': `${exactMetaContentSecurityPolicy}; frame-ancestors 'none'`,
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Resource-Policy': 'same-origin',
      'Permissions-Policy': 'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
    })
  })

  test.each([
    '/..%2fsecret.json',
    '/%2e%2e%2fsecret.json',
    '/%2e%2e%5csecret.json',
    '/safe%2f..%2fsecret.json',
    '/safe%5c..%5csecret.json',
    '/%2e%2e%2f%2e%2e%2fpackage.json',
    '/zigcss/%2e%2e%2fsecret.json',
  ])('rejects encoded traversal %s', async urlPath => {
    const response = await request(urlPath)

    expect(response.status).toBe(403)
    expect(response.body).not.toContain('"secret":true')
  })

  test('rejects a symlink that resolves outside the static root', async () => {
    fs.symlinkSync(path.join(fixtureRoot, 'secret.json'), path.join(distDir, 'linked.json'))

    const response = await request('/linked.json')

    expect(response.status).toBe(403)
    expect(response.body).not.toContain('"secret":true')
  })

  test('rejects every request below a symlinked directory', async () => {
    const outside = path.join(fixtureRoot, 'outside')
    fs.mkdirSync(outside)
    fs.writeFileSync(path.join(outside, 'nested.json'), '{"nestedSecret":true}')
    fs.symlinkSync(outside, path.join(distDir, 'linked-directory'), process.platform === 'win32' ? 'junction' : 'dir')

    const response = await request('/linked-directory/nested.json')

    expect(response.status).toBe(403)
    expect(response.body).not.toContain('nestedSecret')
  })

  test.each([
    ['file', 'before'],
    ['file', 'after'],
    ['directory', 'before'],
    ['directory', 'after'],
  ] as const)('rejects a %s replacement %s the descriptor is opened', async (replacement, timing) => {
    const directory = path.join(distDir, 'assets')
    const outside = path.join(fixtureRoot, 'outside')
    fs.mkdirSync(directory)
    fs.mkdirSync(outside)
    const asset = path.join(directory, 'race.json')
    fs.writeFileSync(asset, '{"public":true}')
    fs.writeFileSync(path.join(outside, 'race.json'), '{"externalSecret":true}')

    const originalOpen = fs.openSync.bind(fs)
    let replaced = false
    let opened: number | undefined
    const replace = () => {
      if (replacement === 'file') {
        fs.renameSync(asset, path.join(directory, 'original.json'))
        fs.symlinkSync(path.join(outside, 'race.json'), asset)
      } else {
        fs.renameSync(directory, path.join(distDir, 'original-assets'))
        fs.symlinkSync(outside, directory, process.platform === 'win32' ? 'junction' : 'dir')
      }
    }
    vi.spyOn(fs, 'openSync').mockImplementation((file, flags, mode) => {
      if (file !== asset || replaced) return originalOpen(file, flags, mode)
      replaced = true
      if (timing === 'before') replace()
      opened = originalOpen(file, flags, mode)
      if (timing === 'after') replace()
      return opened
    })

    const response = await request('/assets/race.json')

    expect(replaced).toBe(true)
    expect(response.status).toBe(403)
    expect(response.body).not.toContain('externalSecret')
    expect(response.headers['cache-control']).toBe('no-store')
    if (opened !== undefined)
      expect(() => fs.fstatSync(opened!)).toThrow(expect.objectContaining({ code: 'EBADF' }))
  })

  test('rejects a parent directory replaced during inventory construction', async () => {
    const directory = path.join(distDir, 'assets')
    const outside = path.join(fixtureRoot, 'outside')
    fs.mkdirSync(directory)
    fs.mkdirSync(outside)
    const asset = path.join(directory, 'race.json')
    fs.writeFileSync(asset, '{"public":true}')
    fs.writeFileSync(path.join(outside, 'race.json'), '{"externalSecret":true}')
    const originalRealpath = fs.realpathSync.bind(fs)
    let replaced = false
    vi.spyOn(fs, 'realpathSync').mockImplementation((file, options) => {
      const canonical = originalRealpath(file, options)
      if (file === asset && !replaced) {
        replaced = true
        fs.renameSync(directory, path.join(distDir, 'original-assets'))
        fs.symlinkSync(outside, directory, process.platform === 'win32' ? 'junction' : 'dir')
      }
      return canonical
    })

    const response = await request('/assets/race.json')

    expect(replaced).toBe(true)
    expect(response.status).toBe(403)
    expect(response.body).not.toContain('externalSecret')
  })

  test.each(['truncate', 'grow', 'rewrite'] as const)('rejects a file that changes during its bounded read: %s', async mutation => {
    const asset = path.join(distDir, 'app.css')
    const originalRead = fs.readSync.bind(fs)
    let changed = false
    let opened: number | undefined
    vi.spyOn(fs, 'readSync').mockImplementation((...args: Parameters<typeof fs.readSync>) => {
      const count = originalRead(...args)
      if (!changed) {
        changed = true
        opened = args[0]
        if (mutation === 'truncate') fs.truncateSync(asset, 0)
        else if (mutation === 'grow') fs.appendFileSync(asset, '/* changed */')
        else fs.writeFileSync(asset, 'x'.repeat(fs.statSync(asset).size))
      }
      return count
    })

    const response = await request('/app.css')

    expect(changed).toBe(true)
    expect(response.status).toBe(403)
    expect(response.body).toBe('Static file changed')
    expect(() => fs.fstatSync(opened!)).toThrow(expect.objectContaining({ code: 'EBADF' }))
  })

  test('accepts empty assets and rejects oversized sparse files before allocating their contents', async () => {
    fs.writeFileSync(path.join(distDir, 'empty.css'), '')
    const asset = path.join(distDir, 'oversized.css')
    fs.writeFileSync(asset, '')
    fs.truncateSync(asset, MAX_STATIC_FILE_BYTES + 1)

    const empty = await request('/empty.css')
    const oversized = await request('/oversized.css')

    expect(empty).toMatchObject({ status: 200, body: '', headers: { 'content-length': '0' } })
    expect(oversized).toMatchObject({ status: 413, body: 'Static file too large' })
  })

  test('returns 400 for malformed URL encoding and keeps serving requests', async () => {
    const malformed = await request('/%E0%A4%A')
    const healthy = await request('/app.css')

    expect(malformed.status).toBe(400)
    expect(healthy).toEqual({
      body: 'body { color: green; }',
      headers: expect.objectContaining({
        'cache-control': 'public, max-age=300',
        'content-security-policy': expect.stringContaining("default-src 'self'"),
        'permissions-policy': 'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
        'x-content-type-options': 'nosniff',
        'x-frame-options': 'DENY',
      }),
      contentType: 'text/css',
      status: 200,
    })
    expect(healthy.headers['content-security-policy']).not.toContain("'unsafe-inline'")
  })

  test('serves GitHub Pages-prefixed bundle assets with their real content types', async () => {
    fs.mkdirSync(path.join(distDir, 'assets'))
    fs.writeFileSync(path.join(distDir, 'assets', 'app.js'), 'globalThis.__zigcssLoaded = true')

    const html = await request('/zigcss/')
    const css = await request('/zigcss/app.css')
    const javascript = await request('/zigcss/assets/app.js')

    expect(html).toMatchObject({
      body: '<h1>zigcss docs</h1>',
      headers: expect.objectContaining({ 'cache-control': 'no-cache' }),
      contentType: 'text/html; charset=utf-8',
      status: 200,
    })
    expect(css).toMatchObject({
      body: 'body { color: green; }',
      contentType: 'text/css',
      status: 200,
    })
    expect(javascript).toMatchObject({
      body: 'globalThis.__zigcssLoaded = true',
      headers: expect.objectContaining({
        'cache-control': 'public, max-age=31536000, immutable',
      }),
      contentType: 'application/javascript',
      status: 200,
    })
  })

  test('preserves the SPA fallback for safe missing paths', async () => {
    const response = await request('/guide/getting-started')

    expect(response).toEqual({
      body: '<h1>zigcss docs</h1>',
      headers: expect.objectContaining({
        'cache-control': 'no-cache',
        'content-length': String(Buffer.byteLength('<h1>zigcss docs</h1>')),
      }),
      contentType: 'text/html; charset=utf-8',
      status: 200,
    })
  })

  test('serves HEAD without a body and rejects state-changing static methods', async () => {
    const head = await request('/zigcss/app.css', { method: 'HEAD' })
    const post = await request('/zigcss/app.css', { body: 'ignored', method: 'POST' })

    expect(head).toMatchObject({
      body: '',
      headers: expect.objectContaining({
        'content-length': String(Buffer.byteLength('body { color: green; }')),
      }),
      contentType: 'text/css',
      status: 200,
    })
    expect(post).toMatchObject({
      body: 'Method not allowed',
      headers: expect.objectContaining({
        allow: 'GET, HEAD',
        'cache-control': 'no-store',
      }),
      status: 405,
    })
  })

  test('returns 404 instead of HTML for a missing typed asset', async () => {
    const response = await request('/zigcss/assets/missing.js')

    expect(response).toMatchObject({
      body: 'Not found',
      contentType: 'text/plain; charset=utf-8',
      status: 404,
    })
  })

  test.each(['/api/compile', '/zigcss/api/compile'])(
    'keeps the public compile endpoint disabled at %s',
    async urlPath => {
      const response = await request(urlPath, {
        body: JSON.stringify({ input: '.a { color: red; }' }),
        method: 'POST',
      })

      expect(response.status).toBe(503)
      expect(JSON.parse(response.body)).toEqual({
        error: 'Compile API disabled pending security hardening',
      })
    },
  )
})
