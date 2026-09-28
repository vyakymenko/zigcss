// @vitest-environment node

import { afterEach, describe, expect, test } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { generateSeoPages, routeAliases, routeMetadata } from '../scripts/generate-seo-pages.mjs'
import { publishedSoftwareMetadata } from './data/seo-routes.mjs'

const docsRoot = path.resolve(import.meta.dirname, '..')
const nextRelease = JSON.parse(fs.readFileSync(path.join(docsRoot, '..', 'release', 'next-release.json'), 'utf8'))
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
  test('owns route-level crawl policy without publishing a misleading project-path robots file', () => {
    expect(fs.existsSync(path.join(docsRoot, 'public', 'robots.txt'))).toBe(false)
    expect(routeMetadata.map(route => route.canonicalPath)).toEqual([
      '/',
      '/getting-started/',
      '/features/',
      '/docs/guide/status/',
      '/docs/guide/css-compatibility/',
      '/docs/guide/format-compatibility/',
      '/docs/guide/css-modules/',
      '/docs/guide/build-from-source/',
      '/docs/guide/builder-integrations/',
      '/docs/guide/recovery-cli/',
    ])
    expect(new Set(routeMetadata.map(route => route.canonicalPath)).size).toBe(routeMetadata.length)
    expect(nextRelease.candidateVersion).toBe('0.7.0-rc.3')
    expect(nextRelease.state).toBe('planned')
    expect(nextRelease.candidateReady).toBe(false)
    expect(routeMetadata.find(route => route.canonicalPath === '/docs/guide/status/')).toEqual({
      canonicalPath: '/docs/guide/status/',
      title: 'ZigCSS 0.7.0-rc.3 release status',
      description: 'ZigCSS 0.7.0-rc.3 is a selected unpublished candidate. Stable 0.6.0 remains published; failed rc.1 and rc.2 are closed.',
      sourceOnly: true,
    })
    expect(routeMetadata.find(route => route.canonicalPath === '/docs/guide/builder-integrations/')).toEqual({
      canonicalPath: '/docs/guide/builder-integrations/',
      title: 'ZigCSS source-only builder and framework proofs',
      description: 'Current-source ZigCSS builder and package-manager proofs for unpublished 0.7.0-rc.3; stable 0.6.0 is separate.',
      sourceOnly: true,
    })
    expect(routeMetadata.find(route => route.canonicalPath === '/docs/guide/css-compatibility/')).toEqual({
      canonicalPath: '/docs/guide/css-compatibility/',
      title: 'ZigCSS source-only CSS compatibility',
      description: 'Source-only CSS compatibility for unpublished ZigCSS 0.7.0-rc.3. Stable 0.6.0 has a separate contract.',
      sourceOnly: true,
    })
    expect(routeMetadata.find(route => route.canonicalPath === '/docs/guide/recovery-cli/')).toEqual({
      canonicalPath: '/docs/guide/recovery-cli/',
      title: 'ZigCSS source-only CLI and recovery contract',
      description: 'Source-only ZigCSS CLI and recovery contract for unpublished 0.7.0-rc.3. Stable 0.6.0 remains available.',
      sourceOnly: true,
    })
    for (const route of routeMetadata) expect(route.description.length).toBeLessThanOrEqual(160)
    expect(routeAliases).toEqual([
      {
        outputPath: '/docs/',
        canonicalPath: '/docs/guide/status/',
        title: 'ZigCSS documentation',
        description: 'Open the evidence-backed ZigCSS documentation and current capability status.',
      },
    ])
  })

  test('base HTML exposes stable software metadata without an invented rating or speed claim', () => {
    const html = fs.readFileSync(path.join(docsRoot, 'index.html'), 'utf8')
    const jsonLdMatch = html.match(/<script id="zigcss-software-metadata" type="application\/ld\+json">([\s\S]*?)<\/script>/)

    expect(html).toContain('<meta name="robots" content="index,follow,max-image-preview:large" />')
    expect(jsonLdMatch).not.toBeNull()
    const metadata = JSON.parse(jsonLdMatch?.[1] ?? '{}')
    expect(metadata).toEqual(publishedSoftwareMetadata)
    expect(metadata.aggregateRating).toBeUndefined()
    expect(html).not.toMatch(/world.?s fastest|\b\d+(?:\.\d+)?x faster\b/i)
  })

  test('generates unique static route metadata and a canonical XML sitemap', () => {
    const root = temporaryBuildRoot()
    const result = generateSeoPages(root)

    expect(result).toEqual({ pages: 11, sitemapUrls: 10 })
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
      if (route.sourceOnly === true) {
        const noScript = html.match(/<noscript>([\s\S]*?)<\/noscript>/)?.[1] ?? ''
        expect(noScript).toContain('ZIGCSS · 0.7.0-RC.3 · UNPUBLISHED SOURCE CANDIDATE')
        expect(noScript).toContain('Candidate 0.7.0-rc.3 is selected but not published on GitHub or npm.')
        expect(noScript).toContain('Failed 0.7.0-rc.1 and 0.7.0-rc.2 identities remain closed.')
        expect(noScript).toContain('Stable 0.6.0 remains on npm latest; historical 0.6.0-rc.2 remains on next.')
        expect(noScript).not.toContain('candidateReady=true')
        expect(noScript).not.toContain('ZIGCSS · 0.7.0-RC.1 · FAILED RELEASE IDENTITY')
        expect(noScript).not.toContain('ZIGCSS 0.6.0 · STABLE RELEASE')
        expect(noScript).not.toContain('npm install')
        expect(html).not.toContain('SoftwareSourceCode')
        expect(html).not.toContain('"version": "0.6.0"')
      }
    }

    const sitemap = fs.readFileSync(path.join(root, 'dist', 'sitemap.xml'), 'utf8')
    expect(sitemap.match(/<url>/g)).toHaveLength(routeMetadata.length)
    for (const route of routeMetadata) {
      expect(sitemap).toContain(`<loc>https://vyakymenko.github.io/zigcss${route.canonicalPath}</loc>`)
    }
    expect(sitemap).not.toMatch(/<priority>|<changefreq>/)

    const builderPage = fs.readFileSync(
      path.join(root, 'dist', 'docs', 'guide', 'builder-integrations', 'index.html'),
      'utf8',
    )
    expect(builderPage).toContain('Current-source ZigCSS builder and package-manager proofs for unpublished 0.7.0-rc.3')
    expect(builderPage).not.toContain('SoftwareSourceCode')
    expect(builderPage).not.toContain('"version": "0.6.0"')

    const recoveryPage = fs.readFileSync(
      path.join(root, 'dist', 'docs', 'guide', 'recovery-cli', 'index.html'),
      'utf8',
    )
    expect(recoveryPage).toContain('Source-only ZigCSS CLI and recovery contract for unpublished 0.7.0-rc.3')
    expect(recoveryPage).not.toContain('SoftwareSourceCode')
    expect(recoveryPage).not.toContain('"version": "0.6.0"')

    const cssCompatibilityPage = fs.readFileSync(
      path.join(root, 'dist', 'docs', 'guide', 'css-compatibility', 'index.html'),
      'utf8',
    )
    expect(cssCompatibilityPage).toContain('Source-only CSS compatibility for unpublished ZigCSS 0.7.0-rc.3')
    expect(cssCompatibilityPage).not.toContain('SoftwareSourceCode')
    expect(cssCompatibilityPage).not.toContain('"version": "0.6.0"')

    const docsAlias = fs.readFileSync(path.join(root, 'dist', 'docs', 'index.html'), 'utf8')
    expect(docsAlias).toContain('<title>ZigCSS documentation</title>')
    expect(docsAlias).toContain('<link rel="canonical" href="https://vyakymenko.github.io/zigcss/docs/guide/status/" />')
    expect(docsAlias).toContain('<meta name="robots" content="noindex,follow" />')
    expect(docsAlias).toContain('UNPUBLISHED SOURCE CANDIDATE')
    expect(docsAlias).not.toContain('SoftwareSourceCode')
    expect(docsAlias).not.toContain('"version": "0.6.0"')
    expect(sitemap).not.toContain('<loc>https://vyakymenko.github.io/zigcss/docs/</loc>')
  })

  test('fails closed on duplicate metadata instead of emitting conflicting canonicals', () => {
    const root = temporaryBuildRoot()
    const index = path.join(root, 'dist', 'index.html')
    fs.appendFileSync(index, '\n<link rel="canonical" href="https://example.invalid/" />\n')

    expect(() => generateSeoPages(root)).toThrow(/canonical URL is duplicated/)
  })

  test('runs SEO generation before the production bundle gate', () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(docsRoot, 'package.json'), 'utf8'))
    expect(manifest.scripts.build).toBe(
      'vite build && node scripts/generate-seo-pages.mjs && npm run check:bundle && npm run check:served-bundle',
    )
  })
})
