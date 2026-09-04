import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { contentTypeFor, createDocsServer, PAGES_BASE_PATH } from '../server.js'

const docsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const distDir = path.join(docsRoot, 'dist')
const expectedMetaContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"

function filesBelow(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name)
    return entry.isDirectory() ? filesBelow(file) : [file]
  })
}

function portableRelative(file) {
  return path.relative(distDir, file).split(path.sep).join('/')
}

if (!fs.existsSync(path.join(distDir, 'index.html')))
  throw new Error('served bundle check requires a completed documentation build')

const server = createDocsServer({ distDir })
await new Promise((resolve, reject) => {
  server.once('error', reject)
  server.listen(0, '127.0.0.1', resolve)
})

try {
  const address = server.address()
  assert(address && typeof address === 'object', 'documentation server did not expose an address')
  const origin = `http://127.0.0.1:${address.port}`
  const artifacts = filesBelow(distDir)

  for (const file of artifacts) {
    const relative = portableRelative(file)
    const response = await fetch(`${origin}${PAGES_BASE_PATH}/${relative}`)
    assert.equal(response.status, 200, `${relative} was not served successfully`)
    assert.equal(
      response.headers.get('content-type'),
      contentTypeFor(file),
      `${relative} was served with the wrong content type`,
    )
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff', `${relative} lost nosniff`)
    const policy = response.headers.get('content-security-policy') ?? ''
    assert(!policy.includes("'unsafe-inline'"), `${relative} permits arbitrary inline content`)
    assert.match(policy, /script-src-attr 'none'/, `${relative} permits script attributes`)
    assert.match(policy, /style-src-attr 'none'/, `${relative} permits style attributes`)
    const served = Buffer.from(await response.arrayBuffer())
    assert.deepEqual(
      served,
      fs.readFileSync(file),
      `${relative} did not round-trip byte-for-byte through the production server`,
    )
    if (path.extname(file) === '.html') {
      const html = served.toString('utf8')
      const metaPolicies = [...html.matchAll(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"\s*\/?\s*>/gi)]
      assert.equal(metaPolicies.length, 1, `${relative} must contain one exact meta CSP`)
      assert.equal(metaPolicies[0][1], expectedMetaContentSecurityPolicy, `${relative} changed its deployable meta CSP`)
      assert(!metaPolicies[0][1].includes('frame-ancestors'), `${relative} claims a response-only CSP directive in meta`)
      assert(!/\sstyle\s*=/i.test(html), `${relative} contains an inline style attribute`)
      assert(!/<style(?:\s|>)/i.test(html), `${relative} contains an inline style element`)
      for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
        if (/\bsrc\s*=/i.test(match[0])) continue
        const hash = `sha256-${crypto.createHash('sha256').update(match[1]).digest('base64')}`
        assert(policy.includes(`'${hash}'`), `${relative} contains an unhashed inline script`)
        assert(metaPolicies[0][1].includes(`'${hash}'`), `${relative} contains an inline script absent from its meta CSP`)
      }
    }
  }

  const entry = await fetch(`${origin}/`)
  assert.equal(entry.status, 200, 'container root did not serve the application entry point')
  assert.match(await entry.text(), /\/zigcss\/assets\//, 'container entry point lost its deploy-time asset base')

  console.log(`Served bundle verified: ${artifacts.length} files round-trip at ${PAGES_BASE_PATH}/ with exact bytes and content types.`)
} finally {
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
}
