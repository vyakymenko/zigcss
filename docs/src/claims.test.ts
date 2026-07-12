// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')

function read(relativePath: string): string {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

function markdownFiles(directory: string): string[] {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const entryPath = path.join(directory, entry.name)
    return entry.isDirectory() ? markdownFiles(entryPath) : entryPath.endsWith('.md') ? [entryPath] : []
  })
}

describe('public recovery claims', () => {
  const activeSurfaces = [
    'README.md',
    'package.json',
    'Formula/zigcss.rb',
    'vscode-extension/package.json',
    '.github/workflows/release.yml',
    'docs/src/app/components/Home.tsx',
    'docs/src/app/components/Features.tsx',
    'docs/src/app/components/GettingStarted.tsx',
    'docs/src/app/components/Playground.tsx',
    ...markdownFiles(path.join(repoRoot, 'docs/src/content/docs')).map(file => path.relative(repoRoot, file)),
  ]

  test.each(activeSurfaces)('%s avoids withdrawn performance and completeness claims', relativePath => {
    const content = read(relativePath)

    expect(content).not.toMatch(/world.?s fastest/i)
    expect(content).not.toMatch(/81\s*[–-]\s*127x/i)
    expect(content).not.toMatch(/uncompromising performance/i)
    expect(content).not.toMatch(/full CSS3/i)
    expect(content).not.toMatch(/fully supported/i)
    expect(content).not.toMatch(/production-ready CSS/i)
  })

  test('marks package, compiler documentation, and editor integration experimental', () => {
    expect(JSON.parse(read('package.json')).description).toMatch(/experimental/i)
    expect(read('README.md')).toMatch(/experimental recovery status/i)
    expect(JSON.parse(read('vscode-extension/package.json')).description).toMatch(/experimental/i)
    expect(read('Formula/zigcss.rb')).toMatch(/experimental/i)
  })

  test('publishes only the current recovery and tested compatibility guides', () => {
    const contentRoot = path.join(repoRoot, 'docs/src/content/docs')
    const published = markdownFiles(contentRoot)
      .map(file => path.relative(contentRoot, file))
      .sort()

    expect(published).toEqual([
      'guide/build-from-source.md',
      'guide/css-compatibility.md',
      'guide/format-compatibility.md',
      'guide/recovery-cli.md',
      'guide/status.md',
    ])
  })

  test('withdraws legacy benchmarks and marks generated releases as prereleases', () => {
    expect(read('BENCHMARK_REPORT.md')).toMatch(/performance claims are withdrawn/i)
    expect(read('BENCHMARK_REPORT.md')).toMatch(/not semantically equivalent/i)
    expect(read('.github/workflows/release.yml')).toContain('prerelease: true')
  })
})
