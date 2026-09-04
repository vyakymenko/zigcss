// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')

function read(relativePath: string): string {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

describe('published native CSS Modules subset', () => {
  const matrix = JSON.parse(read('tests/formats/matrix.json'))
  const adapter = matrix.adapters.find((value: { id: string }) => value.id === 'css-modules')
  const guide = read('docs/src/content/docs/guide/css-modules.md')

  test('matches the executable adapter classification', () => {
    expect(adapter).toMatchObject({
      availability: 'ExperimentalLibrary',
      compatibility: 'NativeSubset',
      implementation: 'LimitedNative',
      publicSyntax: 'css_modules',
      formatTag: null,
    })
    expect(read('src/api.zig')).toMatch(/pub const Syntax = enum \{[\s\S]*css_modules,/)
    expect(read('src/formats.zig')).not.toMatch(/^\s*css_modules,\s*$/m)
    expect(fs.existsSync(path.join(repoRoot, 'src/formats/css_modules.zig'))).toBe(false)
  })

  test('publishes naming ownership limits and strict deferred behavior', () => {
    expect(guide).toContain('zigcss.css-modules.v1')
    expect(guide).toContain('full SHA-256')
    expect(guide).toContain('first authored occurrence order')
    expect(guide).toContain('CompileResult.deinit()')
    expect(guide).toContain('CssModuleLimits')
    expect(guide).toContain('occurrence-sensitive')
    expect(guide).toContain(':local(...)')
    expect(guide).toContain(':global(...)')
    expect(guide).toContain('1,000,000')
    expect(guide).toContain('DependencyKind.css_module')
    expect(guide).toContain('local composition cycles')
    expect(guide).toContain('does not read the filesystem')
    expect(guide).toContain('Local values')
    expect(guide).toContain('intentionally sequential')
    expect(guide).toContain('comments act as safe token separators')
    expect(guide).toContain('Imported `@value')
    expect(guide).toContain('CSS0008')
    expect(guide).toContain('CSS0009')
    expect(guide).toContain('MODULE-002')
    expect(guide).toMatch(/CLI and LSP do not expose CSS Modules semantics/i)
    expect(guide).toMatch(/\.module\.css.*rejected on the default CSS route/i)
  })

  test('keeps the library-only guide discoverable', () => {
    const sidebar = read('docs/src/app/components/docs/DocsLayout.tsx')
    expect(sidebar).toContain('CSS Modules subset')
    expect(sidebar).toContain('/docs/guide/css-modules')
    expect(read('docs/src/content/docs/guide/format-compatibility.md')).toContain(
      '[native CSS Modules subset](/guide/css-modules)',
    )
  })

  test('binds the public driver to independent naming and CSS oracles', () => {
    const build = read('build.zig')
    const oracle = read('tests/formats/css_modules_validate.mjs')
    expect(build).toContain('zigcss-css-modules-test-driver')
    expect(oracle).toContain("createHash('sha256')")
    expect(oracle).toContain('errorRecovery: false')
    expect(oracle).toContain("require('lightningcss')")
    expect(guide).toContain('Lightning CSS 1.30.1')
  })

  test('publishes the exact compiled and executed CSS Modules example', () => {
    const match = guide.match(/## Library use\s+```zig\n([\s\S]*?)\n```/)
    expect(match?.[1]).toBe(read('examples/css_modules.zig').trim())
    expect(read('build.zig')).toContain('test-documentation-examples')
  })
})
