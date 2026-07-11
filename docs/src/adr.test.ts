// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const adrRoot = path.join(repoRoot, 'docs/adr')

function read(name: string): string {
  return fs.readFileSync(path.join(adrRoot, name), 'utf8')
}

describe('foundational architecture decisions', () => {
  const decisions = [
    'ADR-001-core-product-scope.md',
    'ADR-002-tokenizer-and-syntax-tree.md',
    'ADR-003-memory-and-result-ownership.md',
    'ADR-004-transform-safety-classes.md',
    'ADR-010-autonomous-model-requirement.md',
  ]

  test.each(decisions)('%s is accepted and records consequences', name => {
    const adr = read(name)

    expect(adr).toMatch(/^# ADR-\d{3}:/)
    expect(adr).toMatch(/- Status: Accepted/)
    expect(adr).toMatch(/- Date: \d{4}-\d{2}-\d{2}/)
    expect(adr).toContain('## Context')
    expect(adr).toContain('## Decision')
    expect(adr).toContain('## Consequences')
  })

  test('limits stable product scope to standards-oriented CSS', () => {
    const adr = read('ADR-001-core-product-scope.md')

    expect(adr).toContain('standards-oriented CSS')
    expect(adr).toContain('Explicit non-goals')
    expect(adr).toMatch(/SCSS.*experimental/s)
    expect(adr).toMatch(/performance claims.*withdrawn/i)
  })

  test('defines a spec-oriented tokenizer and lossless syntax boundary', () => {
    const adr = read('ADR-002-tokenizer-and-syntax-tree.md')

    expect(adr).toContain('https://drafts.csswg.org/css-syntax/')
    expect(adr).toContain('byte offsets')
    expect(adr).toContain('lossless component values')
    expect(adr).toContain('must not perform transforms')
  })

  test('defines compilation and result ownership without hidden allocator coupling', () => {
    const adr = read('ADR-003-memory-and-result-ownership.md')

    expect(adr).toContain('compilation-scoped arena')
    expect(adr).toContain('caller-owned allocator')
    expect(adr).toContain('CompileResult.deinit')
    expect(adr).toContain('allocator-failure')
  })

  test('makes transform authority explicit and deny-by-default', () => {
    const adr = read('ADR-004-transform-safety-classes.md')

    expect(adr).toContain('Immutable pass handoff')
    expect(adr).toContain('lossless_cleanup')
    expect(adr).toContain('Safety classes are not an ordered permission ladder')
    expect(adr).toContain('defaults to verified analysis only')
    expect(adr).toContain('does not enable `--optimize`')
  })

  test('makes the approved model and single-agent rule a hard autonomous gate', () => {
    const adr = read('ADR-010-autonomous-model-requirement.md')

    expect(adr).toContain('gpt-5.6-sol')
    expect(adr).toContain('ultra reasoning')
    expect(adr).toContain('one implementation agent')
    expect(adr).toContain('No fallback model')
  })
})
