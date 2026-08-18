// @vitest-environment node

import { afterEach, describe, expect, test } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { generateSeoPages, routeMetadata } from '../scripts/generate-seo-pages.mjs'

const docsRoot = path.resolve(import.meta.dirname, '..')
const temporaryRoots: string[] = []

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) fs.rmSync(root, { recursive: true, force: true })
})

function temporaryBuildRoot(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-seo-'))
  temporaryRoots.push(root)
  fs.mkdirSync(path.join(root, 'dist'), { recursive: true })
  fs.copyFileSync(path.join(docsRoot, 'index.html'), path.join(root, 'dist', 'index.html'))
  return root
}

describe('search discovery contract', () => {
  test('owns canonical crawl policy and an exact finite public route inventory', () => {
    expect(fs.readFileSync(path.join(docsRoot, 'public', 'robots.txt'), 'utf8')).toBe(
      'User-agent: *\nAllow: /zigcss/\nSitemap: https://vyakymenko.github.io/zigcss/sitemap.xml\n',
    )
    expect(routeMetadata.map(route => route.canonicalPath)).toEqual([
      '/',
      '/getting-started/',
      '/features/',
      '/docs/guide/status/',
      '/docs/guide/css-compatibility/',
      '/docs/guide/format-compatibility/',
      '/docs/guide/css-modules/',
      '/docs/guide/build-from-source/',
      '/docs/guide/recovery-cli/',
    ])
    expect(new Set(routeMetadata.map(route => route.canonicalPath)).size).toBe(routeMetadata.length)
  })

  test('base HTML exposes stable software metadata without an invented rating or speed claim', () => {
    const html = fs.readFileSync(path.join(docsRoot, 'index.html'), 'utf8')
    const jsonLdMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)

    expect(html).toContain('<meta name="robots" content="index,follow,max-image-preview:large" />')
    expect(jsonLdMatch).not.toBeNull()
    const metadata = JSON.parse(jsonLdMatch?.[1] ?? '{}')
    expect(metadata).toMatchObject({
      '@context': 'https://schema.org',
      '@type': 'SoftwareSourceCode',
      name: 'ZigCSS',
      version: '0.6.0',
      codeRepository: 'https://github.com/vyakymenko/zigcss',
      programmingLanguage: 'Zig',
      url: 'https://vyakymenko.github.io/zigcss/',
    })
    expect(metadata.aggregateRating).toBeUndefined()
    expect(html).not.toMatch(/world.?s fastest|\b\d+(?:\.\d+)?x faster\b/i)
  })

  test('generates unique static route metadata and a canonical XML sitemap', () => {
    const root = temporaryBuildRoot()
    const result = generateSeoPages(root)

    expect(result).toEqual({ pages: 9, sitemapUrls: 9 })
    for (const route of routeMetadata) {
      const output = route.canonicalPath === '/'
        ? path.join(root, 'dist', 'index.html')
        : path.join(root, 'dist', route.canonicalPath.slice(1), 'index.html')
      const html = fs.readFileSync(output, 'utf8')
      const canonical = `https://vyakymenko.github.io/zigcss${route.canonicalPath}`
      expect(html).toContain(`<title>${route.title.replaceAll('&', '&amp;')}</title>`)
      expect(html).toContain(`<link rel="canonical" href="${canonical}" />`)
      expect(html).toContain(`<meta name="robots" content="index,follow,max-image-preview:large" />`)
      expect(html).toContain(route.description)
    }

    const sitemap = fs.readFileSync(path.join(root, 'dist', 'sitemap.xml'), 'utf8')
    expect(sitemap.match(/<url>/g)).toHaveLength(routeMetadata.length)
    for (const route of routeMetadata) {
      expect(sitemap).toContain(`<loc>https://vyakymenko.github.io/zigcss${route.canonicalPath}</loc>`)
    }
    expect(sitemap).not.toMatch(/<priority>|<changefreq>/)
  })

  test('fails closed on duplicate metadata instead of emitting conflicting canonicals', () => {
    const root = temporaryBuildRoot()
    const index = path.join(root, 'dist', 'index.html')
    fs.appendFileSync(index, '\n<link rel="canonical" href="https://example.invalid/" />\n')

    expect(() => generateSeoPages(root)).toThrow(/canonical URL is duplicated/)
  })

  test('runs SEO generation before the production bundle gate', () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(docsRoot, 'package.json'), 'utf8'))
    expect(manifest.scripts.build).toBe('vite build && node scripts/generate-seo-pages.mjs && npm run check:bundle')
  })
})
