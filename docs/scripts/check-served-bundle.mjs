import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { JSDOM } from 'jsdom'
import { contentTypeFor, createDocsServer, PAGES_BASE_PATH } from '../server.js'

const scriptPath = fileURLToPath(import.meta.url)
const docsRoot = path.resolve(path.dirname(scriptPath), '..')
const distDir = path.join(docsRoot, 'dist')
const expectedMetaContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"

function filesBelow(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(directory, entry.name)
    return entry.isDirectory() ? filesBelow(file) : [file]
  })
}

function portableRelative(root, file) {
  return path.relative(root, file).split(path.sep).join('/')
}

export function inspectServedHtml(
  html,
  {
    expectedMetaPolicy = expectedMetaContentSecurityPolicy,
    relative = '<memory>',
    responsePolicy,
  },
) {
  const dom = new JSDOM(html)
  try {
    const document = dom.window.document
    const metaPolicies = [...document.querySelectorAll('meta[http-equiv]')]
      .filter(meta => meta.getAttribute('http-equiv')?.trim().toLowerCase() === 'content-security-policy')
      .map(meta => meta.getAttribute('content') ?? '')
    assert.equal(metaPolicies.length, 1, `${relative} must contain one exact meta CSP`)
    assert.equal(metaPolicies[0], expectedMetaPolicy, `${relative} changed its deployable meta CSP`)
    assert(!metaPolicies[0].includes('frame-ancestors'), `${relative} claims a response-only CSP directive in meta`)
    assert.equal(document.querySelector('[style]'), null, `${relative} contains an inline style attribute`)
    assert.equal(document.querySelector('style'), null, `${relative} contains an inline style element`)
    for (const script of document.querySelectorAll('script')) {
      if (script.hasAttribute('src')) continue
      const source = script.textContent ?? ''
      const hash = `sha256-${crypto.createHash('sha256').update(source).digest('base64')}`
      assert(responsePolicy.includes(`'${hash}'`), `${relative} contains an unhashed inline script`)
      assert(metaPolicies[0].includes(`'${hash}'`), `${relative} contains an inline script absent from its meta CSP`)
    }
  } finally {
    dom.window.close()
  }
}

export async function verifyServedBundle(bundleDirectory = distDir) {
  if (!fs.existsSync(path.join(bundleDirectory, 'index.html')))
    throw new Error('served bundle check requires a completed documentation build')

  const server = createDocsServer({ distDir: bundleDirectory })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })

  try {
    const address = server.address()
    assert(address && typeof address === 'object', 'documentation server did not expose an address')
    const origin = `http://127.0.0.1:${address.port}`
    const artifacts = filesBelow(bundleDirectory)

    for (const file of artifacts) {
      const relative = portableRelative(bundleDirectory, file)
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
        inspectServedHtml(served.toString('utf8'), { relative, responsePolicy: policy })
      }
    }

    const entry = await fetch(`${origin}/`)
    assert.equal(entry.status, 200, 'container root did not serve the application entry point')
    assert.match(await entry.text(), /\/zigcss\/assets\//, 'container entry point lost its deploy-time asset base')

    console.log(`Served bundle verified: ${artifacts.length} files round-trip at ${PAGES_BASE_PATH}/ with exact bytes and content types.`)
  } finally {
    await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  await verifyServedBundle()
}
