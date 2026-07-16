// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const matrix = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tests/formats/matrix.json'), 'utf8'))
const guide = fs.readFileSync(
  path.join(repoRoot, 'docs/src/content/docs/guide/format-compatibility.md'),
  'utf8',
)
const strategy = fs.readFileSync(
  path.join(repoRoot, 'docs/adr/ADR-005-preprocessor-strategy.md'),
  'utf8',
)
const canonicalStrategy = fs.readFileSync(
  path.join(repoRoot, 'docs/adr/ADR-012-canonical-preprocessor-host.md'),
  'utf8',
)
const packageMetadata = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const workflow = fs.readFileSync(path.join(repoRoot, '.github/workflows/build.yml'), 'utf8')
const sidebar = fs.readFileSync(
  path.join(repoRoot, 'docs/src/app/components/docs/DocsLayout.tsx'),
  'utf8',
)

describe('published experimental format matrix', () => {
  test('publishes every machine-readable adapter boundary and owner', () => {
    expect(matrix.adapters).toHaveLength(8)
    for (const adapter of matrix.adapters) {
      const row = guide.split('\n').find(line => line.startsWith(`| \`${adapter.id}\` |`))
      expect(row).toBeDefined()
      expect(row).toContain(`| ${adapter.availability} |`)
      expect(row).toContain(`| ${adapter.compatibility} |`)
      expect(row).toContain(`| ${adapter.implementation} |`)
      expect(row).toContain(`| \`${adapter.strategy}\` |`)
      for (const extension of adapter.extensions) expect(row).toContain(`\`${extension}\``)
      for (const owner of adapter.ownerPackages) expect(row).toContain(`\`${owner}\``)
    }
  })

  test('binds every adapter to the accepted ADR strategy', () => {
    expect(strategy).toContain('- Status: Accepted')
    expect(canonicalStrategy).toContain('- Status: Accepted')
    expect(strategy).toContain('structured diagnostic and no partial CSS')
    for (const adapter of matrix.adapters) {
      expect(`${strategy}\n${canonicalStrategy}`).toContain(
        `| \`${adapter.id}\` | \`${adapter.strategy}\` |`,
      )
    }
  })

  test('records funded canonical providers without prematurely exposing formats', () => {
    expect(matrix.canonicalProviders).toEqual({
      'dart-sass': {
        package: 'sass',
        version: '1.101.0',
        license: 'MIT',
        adapters: ['scss', 'sass'],
      },
      less: {
        package: 'less',
        version: '4.6.7',
        license: 'Apache-2.0',
        adapters: ['less'],
      },
      stylus: {
        package: 'stylus',
        version: '0.64.0',
        license: 'MIT',
        adapters: ['stylus'],
      },
    })

    for (const id of ['scss', 'sass', 'less', 'stylus']) {
      const adapter = matrix.adapters.find(candidate => candidate.id === id)
      expect(adapter.strategy).toBe('canonical-integration')
      expect(adapter.availability).toBe('Unavailable')
      expect(adapter.compatibility).toBe('Unverified')
      expect(adapter.implementation).toBe('Removed')
      expect(adapter.providerId).toBeTypeOf('string')
    }
  })

  test('keeps the executable matrix in package scripts and CI', () => {
    expect(packageMetadata.scripts['test:formats']).toBe(
      'node --test tests/formats/validate.test.mjs && node tests/formats/validate.mjs',
    )
    expect(workflow).toContain('npm run test:formats')
    expect(sidebar).toContain('Format compatibility')
    expect(sidebar).toContain('/docs/guide/format-compatibility')
  })
})
