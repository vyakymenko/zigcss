// @vitest-environment node

import { describe, expect, test } from 'vitest'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const orientScript = path.join(repoRoot, 'scripts/autodevelop/orient.sh')
const protocolPath = path.join(repoRoot, 'docs/operations/codex-loop-protocol.md')

describe('autonomous development operations', () => {
  test('orientation is executable, read-only, and reconstructs durable state', () => {
    const before = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })
    const output = execFileSync('bash', [orientScript], { cwd: path.join(repoRoot, 'docs'), encoding: 'utf8' })
    const after = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })

    expect(fs.statSync(orientScript).mode & 0o111).not.toBe(0)
    expect(after).toBe(before)
    expect(output).toContain('ZigCSS autonomous development orientation')
    expect(output).toContain('## branch and working tree')
    expect(output).toContain('## current ledger work')
    expect(output).toContain('## active blockers')
    expect(output).toContain('## last full validation')
    expect(output).toContain('DEVELOPMENT_PLAN.md')
  })

  test('protocol preserves the approved authority and package loop', () => {
    const protocol = fs.readFileSync(protocolPath, 'utf8')

    expect(protocol).toContain('one implementation agent')
    expect(protocol).toContain('DEVELOPMENT_PLAN.md')
    expect(protocol).toContain('DEVELOPMENT_STATUS.md')
    expect(protocol).toMatch(/reproduce or measure/i)
    expect(protocol).toMatch(/add or strengthen tests/i)
    expect(protocol).toMatch(/smallest correct change/i)
    expect(protocol).toContain('Do not push, publish, deploy, or open a pull request')
    expect(protocol).toContain('scripts/autodevelop/orient.sh')
  })
})
