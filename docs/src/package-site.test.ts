// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const read = (relativePath: string) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

describe('consumer package website', () => {
  test('publishes package metadata at the canonical Pages URL', () => {
    const manifest = JSON.parse(read('package.json'))
    const html = read('docs/index.html')

    expect(manifest.homepage).toBe('https://vyakymenko.github.io/zigcss/')
    expect(manifest.description).toMatch(/experimental.*CSS compiler/i)
    expect(html).toContain('<title>ZigCSS — native CSS compiler in Zig</title>')
    expect(html).toContain('https://vyakymenko.github.io/zigcss/')
    expect(html).toContain('og:image')

    const socialCard = fs.readFileSync(path.join(repoRoot, 'docs/public/og.png'))
    expect(socialCard.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
    expect(socialCard.readUInt32BE(16)).toBe(1200)
    expect(socialCard.readUInt32BE(20)).toBe(630)
    expect(socialCard.byteLength).toBeGreaterThan(50_000)
    expect(socialCard.byteLength).toBeLessThan(1_000_000)
  })

  test('builds for the project path and recovers direct SPA routes', () => {
    expect(read('docs/vite.config.ts')).toMatch(/base:\s*['"]\/zigcss\/['"]/)
    expect(read('docs/public/404.html')).toContain("pathSegmentsToKeep = 1")
    expect(read('docs/index.html')).toContain("window.history.replaceState")
  })

  test('states the CSS-only input boundary on package surfaces', () => {
    for (const relativePath of [
      'README.md',
      'docs/src/app/components/Home.tsx',
      'docs/src/app/components/GettingStarted.tsx',
    ]) {
      const content = read(relativePath)
      expect(content).toMatch(/SCSS/i)
      expect(content).toMatch(/Sass/i)
      expect(content).toMatch(/Less/i)
      expect(content).not.toMatch(/\b(?:supports?|accepts?)\s+(?:full\s+)?(?:SCSS|Sass|Less)\b/i)
    }
  })
})
