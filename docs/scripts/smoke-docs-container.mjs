import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const containerPort = 8080
export const defaultStartupAttempts = 24
export const defaultRetryDelayMilliseconds = 250
export const defaultRequestTimeoutMilliseconds = 5_000
export const canonicalRoute = '/zigcss/docs/guide/status/'
export const canonicalUrl = 'https://vyakymenko.github.io/zigcss/docs/guide/status/'
export const expectedContainerContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'; frame-ancestors 'none'"
export const expectedContainerPermissionsPolicy = 'camera=(), geolocation=(), microphone=(), payment=(), usb=()'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..', '..')

function defaultRunCommand(command, args, { capture = true } = {}) {
  if (!capture) {
    execFileSync(command, args, {
      cwd: repositoryRoot,
      stdio: 'inherit',
    })
    return ''
  }
  return execFileSync(command, args, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  })
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds))
}

function requestUrl(origin, pathname) {
  return new URL(pathname, `${origin.replace(/\/$/, '')}/`).href
}

async function fetchWithTimeout(fetchImpl, url, options, timeoutMilliseconds) {
  return fetchImpl(url, {
    ...options,
    signal: AbortSignal.timeout(timeoutMilliseconds),
  })
}

function assertHtmlResponse(response, label) {
  assert.equal(response.status, 200, `${label} returned HTTP ${response.status}`)
  assert.match(
    response.headers.get('content-type') ?? '',
    /^text\/html(?:;|$)/i,
    `${label} did not return HTML`,
  )
  assert.equal(response.headers.get('cache-control'), 'no-cache', `${label} must be revalidated`)
  assertSecurityHeaders(response, label)
}

function assertSecurityHeaders(response, label) {
  const policy = response.headers.get('content-security-policy') ?? ''
  assert.equal(policy, expectedContainerContentSecurityPolicy, `${label} changed its exact CSP`)
  assert.equal(
    response.headers.get('permissions-policy'),
    expectedContainerPermissionsPolicy,
    `${label} changed its exact Permissions-Policy`,
  )
  assert.equal(response.headers.get('cross-origin-opener-policy'), 'same-origin', `${label} lost opener isolation`)
  assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin', `${label} lost resource isolation`)
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer', `${label} leaks referrers`)
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff', `${label} lost nosniff`)
  assert.equal(response.headers.get('x-frame-options'), 'DENY', `${label} lost frame denial`)
}

export function extractReferencedAssets(html) {
  const assets = new Set()
  const attributePattern = /\b(?:src|href)=["']([^"']+)["']/gi
  for (const match of html.matchAll(attributePattern)) {
    const pathname = match[1].split(/[?#]/, 1)[0]
    if (/\.(?:css|js)$/i.test(pathname)) assets.add(match[1])
  }
  return [...assets].sort()
}

async function waitForRoot({
  fetchImpl,
  origin,
  requestTimeoutMilliseconds,
  retryDelayMilliseconds,
  sleepImpl,
  startupAttempts,
}) {
  let lastError = new Error('documentation container did not answer')
  for (let attempt = 1; attempt <= startupAttempts; attempt += 1) {
    try {
      const response = await fetchWithTimeout(
        fetchImpl,
        requestUrl(origin, '/'),
        {},
        requestTimeoutMilliseconds,
      )
      assertHtmlResponse(response, 'documentation root')
      return response
    } catch (error) {
      lastError = error
      if (attempt < startupAttempts) await sleepImpl(retryDelayMilliseconds)
    }
  }
  throw new Error(
    `documentation container was not ready after ${startupAttempts} attempts: ${lastError.message}`,
    { cause: lastError },
  )
}

export async function verifyDocsHttp({
  fetchImpl = fetch,
  origin,
  requestTimeoutMilliseconds = defaultRequestTimeoutMilliseconds,
  retryDelayMilliseconds = defaultRetryDelayMilliseconds,
  sleepImpl = delay,
  startupAttempts = defaultStartupAttempts,
} = {}) {
  assert.equal(typeof origin, 'string', 'documentation container origin is required')
  assert(Number.isInteger(startupAttempts) && startupAttempts > 0, 'startup attempts must be a positive integer')
  assert(Number.isInteger(retryDelayMilliseconds) && retryDelayMilliseconds >= 0, 'retry delay must be a non-negative integer')
  assert(Number.isInteger(requestTimeoutMilliseconds) && requestTimeoutMilliseconds > 0, 'request timeout must be a positive integer')

  const rootResponse = await waitForRoot({
    fetchImpl,
    origin,
    requestTimeoutMilliseconds,
    retryDelayMilliseconds,
    sleepImpl,
    startupAttempts,
  })
  const rootHtml = await rootResponse.text()
  assert.match(rootHtml, /<div id=["']root["']><\/div>/, 'documentation root lost the application mount')

  const assets = extractReferencedAssets(rootHtml)
  assert(assets.some(asset => new URL(asset, origin).pathname.endsWith('.js')), 'documentation root references no JavaScript')
  assert(assets.some(asset => new URL(asset, origin).pathname.endsWith('.css')), 'documentation root references no stylesheet')

  const expectedOrigin = new URL(origin).origin
  for (const asset of assets) {
    const assetUrl = new URL(asset, origin)
    assert.equal(assetUrl.origin, expectedOrigin, `documentation asset must remain same-origin: ${asset}`)
    assert(assetUrl.pathname.startsWith('/zigcss/'), `documentation asset is not deploy-prefixed: ${asset}`)

    const response = await fetchWithTimeout(
      fetchImpl,
      assetUrl.href,
      {},
      requestTimeoutMilliseconds,
    )
    assert.equal(response.status, 200, `${assetUrl.pathname} returned HTTP ${response.status}`)
    const expectedType = assetUrl.pathname.endsWith('.css') ? 'text/css' : 'application/javascript'
    assert.equal(
      response.headers.get('content-type'),
      expectedType,
      `${assetUrl.pathname} has the wrong content type`,
    )
    assert.equal(
      response.headers.get('x-content-type-options'),
      'nosniff',
      `${assetUrl.pathname} lost X-Content-Type-Options: nosniff`,
    )
    assert.equal(
      response.headers.get('cache-control'),
      'public, max-age=31536000, immutable',
      `${assetUrl.pathname} lost immutable asset caching`,
    )
    assertSecurityHeaders(response, assetUrl.pathname)
    assert((await response.arrayBuffer()).byteLength > 0, `${assetUrl.pathname} is empty`)
  }

  const methodProbe = new URL(assets[0], origin)
  const headResponse = await fetchWithTimeout(
    fetchImpl,
    methodProbe.href,
    { method: 'HEAD' },
    requestTimeoutMilliseconds,
  )
  assert.equal(headResponse.status, 200, `${methodProbe.pathname} rejected HEAD`)
  assertSecurityHeaders(headResponse, `${methodProbe.pathname} HEAD`)
  const postResponse = await fetchWithTimeout(
    fetchImpl,
    methodProbe.href,
    { method: 'POST' },
    requestTimeoutMilliseconds,
  )
  assert.equal(postResponse.status, 405, `${methodProbe.pathname} accepted POST`)
  assert.equal(postResponse.headers.get('allow'), 'GET, HEAD')
  assert.equal(postResponse.headers.get('cache-control'), 'no-store')
  assertSecurityHeaders(postResponse, `${methodProbe.pathname} POST`)

  const routeResponse = await fetchWithTimeout(
    fetchImpl,
    requestUrl(origin, canonicalRoute),
    {},
    requestTimeoutMilliseconds,
  )
  assertHtmlResponse(routeResponse, 'canonical documentation route')
  const routeHtml = await routeResponse.text()
  assert(
    routeHtml.includes(`<link rel="canonical" href="${canonicalUrl}"`),
    'canonical documentation route lost its exact canonical URL',
  )
  assert.match(routeHtml, /<div id=["']root["']><\/div>/, 'canonical documentation route lost the application mount')

  for (const pathname of ['/api/compile', '/zigcss/api/compile']) {
    const response = await fetchWithTimeout(
      fetchImpl,
      requestUrl(origin, pathname),
      {},
      requestTimeoutMilliseconds,
    )
    assert.equal(response.status, 503, `${pathname} must remain disabled`)
    assert.match(response.headers.get('content-type') ?? '', /^application\/json(?:;|$)/i)
    assert.equal(response.headers.get('cache-control'), 'no-store')
    assertSecurityHeaders(response, pathname)
    assert.deepEqual(await response.json(), {
      error: 'Compile API disabled pending security hardening',
    })
  }

  return { assets: assets.length, canonicalRoute, compileEndpoints: 2 }
}

function publishedPort(output) {
  const matches = [...String(output).matchAll(/(?:^|\n)127\.0\.0\.1:([0-9]+)\s*(?=\n|$)/g)]
  assert.equal(matches.length, 1, `Docker exposed an unexpected port mapping: ${String(output).trim()}`)
  const port = Number(matches[0][1])
  assert(Number.isInteger(port) && port >= 1 && port <= 65_535, 'Docker exposed an invalid host port')
  return port
}

function validateTemporaryTag(tag) {
  assert(
    typeof tag === 'string'
      && tag.length <= 258
      && /^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(tag)
      && !tag.includes('..')
      && !tag.includes('//'),
    'documentation container tag must be one bounded explicit local image tag',
  )
  return tag
}

function appendCleanupFailure(primary, cleanupError, label) {
  const cleanupFailure = new Error(
    `Documentation container ${label} failed: ${cleanupError.message}`,
    { cause: cleanupError },
  )
  if (!primary) return cleanupFailure
  return new AggregateError(
    [primary, cleanupFailure],
    `${primary.message}\n${cleanupFailure.message}`,
  )
}

export async function runDocsContainerSmoke({
  runCommand = defaultRunCommand,
  tag = `zigcss-docs-smoke:${process.pid}`,
  verifyHttp = verifyDocsHttp,
} = {}) {
  validateTemporaryTag(tag)
  runCommand('docker', [
    'build',
    '--pull',
    '--file',
    'Dockerfile.docs',
    '--tag',
    tag,
    '.',
  ], { capture: false })

  let containerId = ''
  let failure
  let result
  try {
    containerId = String(runCommand('docker', [
      'run',
      '--detach',
      '--read-only',
      '--cap-drop=ALL',
      '--security-opt=no-new-privileges:true',
      '--publish',
      `127.0.0.1::${containerPort}`,
      tag,
    ])).trim()
    assert.match(containerId, /^[0-9a-f]{12,64}$/i, 'Docker did not return one container ID')

    const port = publishedPort(runCommand('docker', ['port', containerId, `${containerPort}/tcp`]))
    const verified = await verifyHttp({ origin: `http://127.0.0.1:${port}` })
    result = { ...verified, containerPort, hostPort: port }
  } catch (error) {
    let logs = ''
    if (containerId) {
      try {
        logs = String(runCommand('docker', ['logs', containerId])).trim()
      } catch {
        logs = '<unavailable>'
      }
    }
    failure = new Error(
      `${error.message}${logs ? `\nDocumentation container logs:\n${logs}` : ''}`,
      { cause: error },
    )
  } finally {
    if (containerId) {
      try {
        runCommand('docker', ['rm', '--force', containerId])
      } catch (cleanupError) {
        failure = appendCleanupFailure(failure, cleanupError, 'cleanup')
      }
    }
    try {
      runCommand('docker', ['image', 'rm', '--force', tag])
    } catch (cleanupError) {
      failure = appendCleanupFailure(failure, cleanupError, 'image cleanup')
    }
  }
  if (failure) throw failure
  return result
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === scriptPath
if (isMain) {
  const result = await runDocsContainerSmoke()
  console.log(
    `Documentation container verified on an ephemeral loopback port: ${result.assets} prefixed JS/CSS assets, one canonical route, and ${result.compileEndpoints} disabled compile endpoints.`,
  )
}
