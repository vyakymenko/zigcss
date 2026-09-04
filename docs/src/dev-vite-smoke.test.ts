// @vitest-environment node

import { describe, expect, test } from 'vitest'
import path from 'node:path'
import { createServer } from 'vite'

const docsRoot = path.resolve(import.meta.dirname, '..')
const developmentContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'self' ws://127.0.0.1:* ws://localhost:*; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; style-src-attr 'none'; worker-src 'none'"

describe('live Vite development surface', () => {
  test('serves a single-base favicon and a narrowly development-capable CSP', async () => {
    const server = await createServer({
      configFile: path.join(docsRoot, 'vite.config.ts'),
      logLevel: 'silent',
      root: docsRoot,
      server: { host: '127.0.0.1', port: 0, strictPort: true },
    })
    try {
      await server.listen()
      const address = server.httpServer?.address()
      expect(address).not.toBeNull()
      expect(typeof address).toBe('object')
      if (address === null || typeof address !== 'object') throw new Error('Vite did not publish a TCP address')
      const origin = `http://127.0.0.1:${address.port}`

      const pageResponse = await fetch(`${origin}/zigcss/`, { signal: AbortSignal.timeout(5_000) })
      expect(pageResponse.status).toBe(200)
      expect(pageResponse.headers.get('content-type')).toMatch(/^text\/html(?:;|$)/i)
      const html = await pageResponse.text()
      expect(html).toContain(`content="${developmentContentSecurityPolicy}"`)
      expect(html).toContain('href="/zigcss/favicon.svg"')
      expect(html).not.toContain('/zigcss/zigcss/favicon.svg')
      expect(html).toContain('/@vite/client')

      const faviconResponse = await fetch(`${origin}/zigcss/favicon.svg`, { signal: AbortSignal.timeout(5_000) })
      expect(faviconResponse.status).toBe(200)
      expect(faviconResponse.headers.get('content-type')).toMatch(/^image\/svg\+xml(?:;|$)/i)
      expect(await faviconResponse.text()).toMatch(/^<svg\b/)
    } finally {
      await server.close()
    }
  }, 15_000)
})
