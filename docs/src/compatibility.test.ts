// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const matrix = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tests/compatibility/matrix.json'), 'utf8'))
const guide = fs.readFileSync(path.join(repoRoot, 'docs/src/content/docs/guide/css-compatibility.md'), 'utf8')
const packageMetadata = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))

describe('published CSS compatibility matrix', () => {
  test('publishes every machine-readable feature with its tested status', () => {
    expect(matrix.features.length).toBeGreaterThan(0)
    for (const feature of matrix.features) {
      expect(guide).toContain(`\`${feature.id}\``)
      const row = guide.split('\n').find(line => line.startsWith(`| \`${feature.id}\` |`))
      expect(row).toBeDefined()
      expect(row).toContain(`| ${feature.status} |`)
    }
  })

  test('pins the documented independent parser version in package metadata', () => {
    expect(matrix.validator.package).toBe('lightningcss')
    expect(matrix.validator.errorRecovery).toBe(false)
    expect(matrix.validator.drafts.nesting).toBe(true)
    expect(packageMetadata.devDependencies.lightningcss).toBe(matrix.validator.version)
    expect(guide).toContain(`Lightning CSS ${matrix.validator.version}`)
  })

  test('keeps every matrix case backed by a non-empty fixture', () => {
    for (const testCase of matrix.cases) {
      const fixture = path.resolve(repoRoot, 'tests/compatibility', testCase.fixture)
      expect(fixture.startsWith(path.resolve(repoRoot, 'tests/compatibility/fixtures') + path.sep)).toBe(true)
      expect(fs.statSync(fixture).isFile()).toBe(true)
      expect(fs.readFileSync(fixture).length).toBeGreaterThan(0)
      expect(testCase.modes).toEqual(['pretty', 'minified'])
    }
  })
})
