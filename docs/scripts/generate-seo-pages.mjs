import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { routeAliases, routeMetadata, siteOrigin } from '../src/data/seo-routes.mjs'

export { routeAliases, routeMetadata } from '../src/data/seo-routes.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const defaultDocsRoot = path.resolve(path.dirname(scriptPath), '..')

function fail(message) {
  throw new Error(`SEO page generation: ${message}`)
}

function replaceOnce(source, expression, replacement, label) {
  const match = expression.exec(source)
  if (match === null) fail(`${label} is missing`)
  if (expression.test(source.slice(match.index + match[0].length))) fail(`${label} is duplicated`)
  return `${source.slice(0, match.index)}${replacement}${source.slice(match.index + match[0].length)}`
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
}

function readBoundedIndex(distRoot) {
  const filename = path.join(distRoot, 'index.html')
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`dist/index.html is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) {
    fail('dist/index.html must be a bounded regular non-symlink file')
  }
  const source = fs.readFileSync(filename, 'utf8').replaceAll('\r\n', '\n')
  if (source.includes('\r')) fail('dist/index.html contains a bare carriage return')
  return source
}

function renderRoute(baseHtml, route, robots = 'index,follow,max-image-preview:large') {
  const canonical = `${siteOrigin}${route.canonicalPath}`
  const title = escapeHtml(route.title)
  const description = escapeHtml(route.description)
  let html = baseHtml
  html = replaceOnce(html, /<title>[\s\S]*?<\/title>/, `<title>${title}</title>`, 'title')
  html = replaceOnce(
    html,
    /<meta\s+name="description"\s+content="[^"]*"\s*\/?>/,
    `<meta name="description" content="${description}" />`,
    'description',
  )
  html = replaceOnce(
    html,
    /<link\s+rel="canonical"\s+href="[^"]*"\s*\/?>/,
    `<link rel="canonical" href="${canonical}" />`,
    'canonical URL',
  )
  html = replaceOnce(html, /<meta property="og:title" content="[^"]*"\s*\/?>/, `<meta property="og:title" content="${title}" />`, 'Open Graph title')
  html = replaceOnce(html, /<meta\s+property="og:description"\s+content="[^"]*"\s*\/?>/, `<meta property="og:description" content="${description}" />`, 'Open Graph description')
  html = replaceOnce(html, /<meta property="og:url" content="[^"]*"\s*\/?>/, `<meta property="og:url" content="${canonical}" />`, 'Open Graph URL')
  html = replaceOnce(html, /<meta name="twitter:title" content="[^"]*"\s*\/?>/, `<meta name="twitter:title" content="${title}" />`, 'Twitter title')
  html = replaceOnce(html, /<meta name="twitter:description" content="[^"]*"\s*\/?>/, `<meta name="twitter:description" content="${description}" />`, 'Twitter description')
  html = replaceOnce(html, /<meta\s+name="robots"\s+content="[^"]*"\s*\/?>/, `<meta name="robots" content="${robots}" />`, 'robots policy')
  if (route.sourceOnly === true) {
    html = replaceOnce(
      html,
      /\s*<script id="zigcss-software-metadata" type="application\/ld\+json">[\s\S]*?<\/script>/,
      '',
      'published software structured metadata on a source-only route',
    )
    html = replaceOnce(
      html,
      /<noscript>[\s\S]*?<\/noscript>/,
      `<noscript>
    <main>
      <p>ZIGCSS · 0.7.0-RC.1 · CURRENT UNPUBLISHED SOURCE</p>
      <h1>JavaScript is required for this source-only documentation route.</h1>
      <p>This page documents the 0.7.0-rc.1 source candidate, not published stable 0.6.0. Build the repository source before using these capabilities.</p>
      <p><a href="https://github.com/vyakymenko/zigcss">Open the ZigCSS source repository</a></p>
    </main>
  </noscript>`,
      'source-only no-script fallback',
    )
  }
  return html
}

function writeAtomically(filename, source) {
  fs.mkdirSync(path.dirname(filename), { recursive: true })
  const temporary = `${filename}.tmp`
  fs.writeFileSync(temporary, source, { encoding: 'utf8', mode: 0o644 })
  fs.renameSync(temporary, filename)
}

export function generateSeoPages(docsRoot = defaultDocsRoot) {
  const canonicalDocsRoot = fs.realpathSync(docsRoot)
  const distRoot = path.join(canonicalDocsRoot, 'dist')
  const baseHtml = readBoundedIndex(distRoot)

  for (const route of routeMetadata) {
    const output = route.canonicalPath === '/'
      ? path.join(distRoot, 'index.html')
      : path.join(distRoot, route.canonicalPath.slice(1), 'index.html')
    writeAtomically(output, renderRoute(baseHtml, route))
  }

  for (const alias of routeAliases) {
    const output = path.join(distRoot, alias.outputPath.slice(1), 'index.html')
    writeAtomically(output, renderRoute(baseHtml, alias, 'noindex,follow'))
  }

  const sitemap = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...routeMetadata.flatMap(route => [
      '  <url>',
      `    <loc>${siteOrigin}${route.canonicalPath}</loc>`,
      '  </url>',
    ]),
    '</urlset>',
    '',
  ].join('\n')
  writeAtomically(path.join(distRoot, 'sitemap.xml'), sitemap)
  return { pages: routeMetadata.length + routeAliases.length, sitemapUrls: routeMetadata.length }
}

function main() {
  if (process.argv.length !== 2) fail('usage: node scripts/generate-seo-pages.mjs')
  const result = generateSeoPages()
  process.stdout.write(`SEO routes generated: ${result.pages} pages, ${result.sitemapUrls} sitemap URLs.\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
