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
    expect(manifest.description).toMatch(/self-contained native CSS, SCSS, Sass, Less, and Stylus compiler/i)
    expect(manifest.description).not.toMatch(/experimental/i)
    expect(html).toContain('<title>ZigCSS — Native CSS, SCSS, Sass, Less &amp; Stylus compiler</title>')
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
    expect(read('docs/public/404.html')).toContain('error: route not found — exit 2')
  })

  test('ships a readable no-script fallback and self-hosted terminal typography', () => {
    const html = read('docs/index.html')
    const theme = read('docs/src/styles/theme.css')

    expect(html).toContain('<noscript>')
    expect(html).toContain('Exact in. Deterministic out. Denied by default.')
    expect(theme).toMatch(/font-display:\s*swap/)
    for (const file of [
      'docs/src/assets/fonts/archivo-latin-variable.woff2',
      'docs/src/assets/fonts/jetbrains-mono-latin-variable.woff2',
    ]) {
      expect(fs.readFileSync(path.join(repoRoot, file)).subarray(0, 4).toString()).toBe('wOF2')
    }
    expect(read('docs/public/favicon.svg')).toMatch(/caret.*animation|animation.*caret/s)
  })

  test('keeps the landing JavaScript budget executable and fail-closed', () => {
    const manifest = JSON.parse(read('docs/package.json'))
    const gate = read('docs/scripts/check-bundle-budget.mjs')

    expect(manifest.scripts.build).toContain('check:bundle')
    expect(read('docs/vite.config.ts')).toMatch(/manifest:\s*true/)
    expect(gate).toMatch(/160 \* 1024/)
    expect(gate).toMatch(/src\/app\/components\/Home\.tsx/)
    expect(gate).toMatch(/gzipSync/)
  })

  test('makes the README a visual front door to the package website', () => {
    const readme = read('README.md')
    const installHeading = readme.indexOf('## Install')

    expect(readme).toContain(
      '[![ZigCSS — Native by design. Correct by contract.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)',
    )
    expect(readme).toContain('**Compile CSS. Keep the meaning.**')
    expect(readme).toContain('**Five languages in. One deterministic compiler out.**')
    expect(readme).toContain('**Native by design. Fast on purpose. Correct by contract.**')
    expect(readme).toContain('[Website](https://vyakymenko.github.io/zigcss/)')
    expect(readme).toContain('[npm](https://www.npmjs.com/package/zigcss)')
    expect(readme.indexOf('[Website]')).toBeLessThan(installHeading)
  })

  test('presents the benchmark program without inventing speed results', () => {
    const readme = read('README.md')

    expect(readme).toContain('## Benchmarks')
    expect(readme).toMatch(/43 ordered series/i)
    expect(readme).toMatch(/860 raw observations/i)
    expect(readme).toMatch(/controlled.*Linux x64/i)
    expect(readme).toMatch(/numbers remain unpublished/i)
    expect(readme).not.toMatch(/world.?s fastest|\d+x faster/i)
  })

  test('states the exact five-language boundary on package surfaces', () => {
    for (const relativePath of [
      'README.md',
      'docs/src/app/components/GettingStarted.tsx',
    ]) {
      const content = read(relativePath)
      expect(content).toMatch(/CSS/i)
      expect(content).toMatch(/SCSS/i)
      expect(content).toMatch(/Sass/i)
      expect(content).toMatch(/Less/i)
      expect(content).toMatch(/Stylus/i)
      expect(content).toMatch(/1\.101\.0/)
      expect(content).toMatch(/4\.6\.7/)
      expect(content).toMatch(/0\.64\.0/)
      expect(content).toMatch(/plugin|project code/i)
    }

    expect(read('docs/src/app/components/Home.tsx')).toMatch(/<FormatShowcase\s*\/>/)
    const showcase = read('docs/src/app/components/FormatShowcase.tsx')
    const examples = JSON.parse(read('docs/src/data/format-examples.json'))
    expect(examples.map((example: { label: string }) => example.label)).toEqual(['CSS', 'SCSS', 'Sass', 'Less', 'Stylus'])
    expect(examples.slice(1).map((example: { frontend: string }) => example.frontend)).toEqual([
      'Native Sass frontend',
      'Native Sass frontend',
      'Native Less frontend',
      'Native Stylus frontend',
    ])
    expect(showcase).toMatch(/selected\.frontend/)
    expect(showcase).not.toMatch(/selected\.provider/)
    expect(showcase).toMatch(/recorded compiler output/i)
    expect(showcase).toMatch(/format-examples\.json/)
  })
})
