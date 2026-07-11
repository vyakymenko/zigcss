// @vitest-environment node

import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import type { AddressInfo } from 'node:net'
import type { Server } from 'node:http'
import { createDocsServer } from '../server.js'

type Response = {
  body: string
  status: number
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
      await new Promise<void>((resolve, reject) =>
        server.close(error => error ? reject(error) : resolve()),
      )
    }
    fs.rmSync(fixtureRoot, { force: true, recursive: true })
  })

  function request(urlPath: string): Promise<Response> {
    const address = server.address() as AddressInfo
    return new Promise((resolve, reject) => {
      const req = http.request({
        host: '127.0.0.1',
        method: 'GET',
        path: urlPath,
        port: address.port,
      }, res => {
        const chunks: Buffer[] = []
        res.on('data', chunk => chunks.push(Buffer.from(chunk)))
        res.on('end', () => resolve({
          body: Buffer.concat(chunks).toString('utf8'),
          status: res.statusCode ?? 0,
        }))
      })
      req.on('error', reject)
      req.end()
    })
  }

  test.each([
    '/..%2fsecret.json',
    '/%2e%2e%2fsecret.json',
    '/%2e%2e%5csecret.json',
    '/%2e%2e%2f%2e%2e%2fpackage.json',
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
      status: 200,
    })
  })

  test('preserves the SPA fallback for safe missing paths', async () => {
    const response = await request('/guide/getting-started')

    expect(response).toEqual({
      body: '<h1>zigcss docs</h1>',
      status: 200,
    })
  })
})
