// @vitest-environment node

import { describe, expect, test, vi } from 'vitest'
import {
  canonicalRoute,
  canonicalUrl,
  expectedContainerContentSecurityPolicy,
  expectedContainerPermissionsPolicy,
  extractReferencedAssets,
  runDocsContainerSmoke,
  verifyDocsHttp,
} from '../scripts/smoke-docs-container.mjs'

function response(body: BodyInit, init: ResponseInit = {}) {
  return new Response(body, init)
}

function staticHeaders(contentType: string) {
  return {
    'Cache-Control': contentType.startsWith('text/html')
      ? 'no-cache'
      : 'public, max-age=31536000, immutable',
    'Content-Security-Policy': expectedContainerContentSecurityPolicy,
    'Content-Type': contentType,
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Permissions-Policy': expectedContainerPermissionsPolicy,
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  }
}

describe('documentation container HTTP smoke', () => {
  test('owns the complete exact container header policy independently of the server', () => {
    expect(expectedContainerContentSecurityPolicy).toBe(
      "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'; frame-ancestors 'none'",
    )
    expect(expectedContainerPermissionsPolicy).toBe(
      'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
    )
  })

  test('extracts every unique referenced JavaScript and stylesheet asset', () => {
    expect(extractReferencedAssets(`
      <script type="module" src="/zigcss/assets/app.js"></script>
      <link rel="modulepreload" href="/zigcss/assets/vendor.js">
      <link rel="stylesheet" href="/zigcss/assets/app.css">
      <link rel="stylesheet" href="/zigcss/assets/app.css">
      <link rel="icon" href="/zigcss/favicon.svg">
    `)).toEqual([
      '/zigcss/assets/app.css',
      '/zigcss/assets/app.js',
      '/zigcss/assets/vendor.js',
    ])
  })

  test('retries readiness within a finite budget and verifies the complete live contract', async () => {
    const origin = 'http://127.0.0.1:49152'
    const rootHtml = [
      '<div id="root"></div>',
      '<script src="/zigcss/assets/app.js"></script>',
      '<link rel="modulepreload" href="/zigcss/assets/vendor.js">',
      '<link rel="stylesheet" href="/zigcss/assets/app.css">',
    ].join('')
    let rootAttempts = 0
    const requested: Array<{ method: string; pathname: string }> = []
    const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input))
      requested.push({ method: init?.method ?? 'GET', pathname: url.pathname })
      if (init?.method === 'POST') {
        return response('Method not allowed', {
          headers: {
            ...staticHeaders('text/plain; charset=utf-8'),
            Allow: 'GET, HEAD',
            'Cache-Control': 'no-store',
          },
          status: 405,
        })
      }
      if (url.pathname === '/') {
        rootAttempts += 1
        if (rootAttempts < 3) throw new Error('connection refused')
        return response(rootHtml, { headers: staticHeaders('text/html; charset=utf-8') })
      }
      if (url.pathname.endsWith('.css'))
        return response('body{}', { headers: staticHeaders('text/css') })
      if (url.pathname.endsWith('.js'))
        return response('export{}', { headers: staticHeaders('application/javascript') })
      if (url.pathname === canonicalRoute) {
        return response(
          `<link rel="canonical" href="${canonicalUrl}" /><div id="root"></div>`,
          { headers: staticHeaders('text/html; charset=utf-8') },
        )
      }
      if (url.pathname === '/api/compile' || url.pathname === '/zigcss/api/compile') {
        return response(JSON.stringify({ error: 'Compile API disabled pending security hardening' }), {
          headers: {
            ...staticHeaders('application/json'),
            'Cache-Control': 'no-store',
          },
          status: 503,
        })
      }
      return response('not found', { status: 404 })
    })
    const sleepImpl = vi.fn(async () => {})

    await expect(verifyDocsHttp({
      fetchImpl,
      origin,
      requestTimeoutMilliseconds: 100,
      retryDelayMilliseconds: 1,
      sleepImpl,
      startupAttempts: 3,
    })).resolves.toEqual({ assets: 3, canonicalRoute, compileEndpoints: 2 })

    expect(rootAttempts).toBe(3)
    expect(sleepImpl).toHaveBeenCalledTimes(2)
    expect(requested).toEqual([
      { method: 'GET', pathname: '/' },
      { method: 'GET', pathname: '/' },
      { method: 'GET', pathname: '/' },
      { method: 'GET', pathname: '/zigcss/assets/app.css' },
      { method: 'GET', pathname: '/zigcss/assets/app.js' },
      { method: 'GET', pathname: '/zigcss/assets/vendor.js' },
      { method: 'HEAD', pathname: '/zigcss/assets/app.css' },
      { method: 'POST', pathname: '/zigcss/assets/app.css' },
      { method: 'GET', pathname: canonicalRoute },
      { method: 'GET', pathname: '/api/compile' },
      { method: 'GET', pathname: '/zigcss/api/compile' },
    ])
  })

  test('fails closed when an asset is not deploy-prefixed', async () => {
    const fetchImpl = vi.fn(async () => response(
      '<div id="root"></div><script src="/assets/app.js"></script><link rel="stylesheet" href="/zigcss/app.css">',
      { headers: staticHeaders('text/html; charset=utf-8') },
    ))

    await expect(verifyDocsHttp({
      fetchImpl,
      origin: 'http://127.0.0.1:49152',
      startupAttempts: 1,
    })).rejects.toThrow(/not deploy-prefixed/)
  })

  test('stops readiness polling at the configured attempt bound', async () => {
    const fetchImpl = vi.fn(async () => { throw new Error('connection refused') })
    const sleepImpl = vi.fn(async () => {})

    await expect(verifyDocsHttp({
      fetchImpl,
      origin: 'http://127.0.0.1:49152',
      retryDelayMilliseconds: 1,
      sleepImpl,
      startupAttempts: 2,
    })).rejects.toThrow(/not ready after 2 attempts/)

    expect(fetchImpl).toHaveBeenCalledTimes(2)
    expect(sleepImpl).toHaveBeenCalledTimes(1)
  })

  test('always removes a started container after a smoke failure', async () => {
    const commands: string[][] = []
    const runCommand = vi.fn((command: string, args: string[]) => {
      commands.push([command, ...args])
      if (args[0] === 'run') return '0123456789abcdef\n'
      if (args[0] === 'port') return '127.0.0.1:49152\n'
      if (args[0] === 'logs') return 'server stopped\n'
      return ''
    })

    await expect(runDocsContainerSmoke({
      runCommand,
      tag: 'zigcss-docs-smoke:test',
      verifyHttp: async () => { throw new Error('HTTP contract failed') },
    })).rejects.toThrow(/HTTP contract failed[\s\S]*server stopped/)

    expect(commands[0]).toEqual([
      'docker',
      'build',
      '--pull',
      '--file',
      'Dockerfile.docs',
      '--tag',
      'zigcss-docs-smoke:test',
      '.',
    ])
    expect(commands[1]).toEqual([
      'docker',
      'run',
      '--detach',
      '--read-only',
      '--cap-drop=ALL',
      '--security-opt=no-new-privileges:true',
      '--publish',
      '127.0.0.1::8080',
      'zigcss-docs-smoke:test',
    ])
    expect(commands.at(-2)).toEqual([
      'docker',
      'rm',
      '--force',
      '0123456789abcdef',
    ])
    expect(commands.at(-1)).toEqual([
      'docker',
      'image',
      'rm',
      '--force',
      'zigcss-docs-smoke:test',
    ])
  })

  test('reports a cleanup failure together with the primary smoke failure', async () => {
    const runCommand = vi.fn((_command: string, args: string[]) => {
      if (args[0] === 'run') return '0123456789abcdef\n'
      if (args[0] === 'port') return '127.0.0.1:49152\n'
      if (args[0] === 'logs') return 'server stopped\n'
      if (args[0] === 'rm') throw new Error('cleanup denied')
      return ''
    })

    await expect(runDocsContainerSmoke({
      runCommand,
      tag: 'zigcss-docs-smoke:test',
      verifyHttp: async () => { throw new Error('HTTP contract failed') },
    })).rejects.toThrow(/HTTP contract failed[\s\S]*cleanup failed: cleanup denied/)
  })

  test('rejects ambiguous temporary image tags before invoking Docker', async () => {
    const runCommand = vi.fn()
    await expect(runDocsContainerSmoke({
      runCommand,
      tag: '--all',
    })).rejects.toThrow(/bounded explicit local image tag/)
    expect(runCommand).not.toHaveBeenCalled()
  })
})
