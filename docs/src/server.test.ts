// @vitest-environment node

import { afterEach, beforeEach, describe, expect, test } from 'vitest'
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
    fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-server-test-'))
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
