// @vitest-environment node

import { describe, expect, test } from 'vitest'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const orientScript = path.join(repoRoot, 'scripts/autodevelop/orient.sh')
const controlScript = path.join(repoRoot, 'scripts/autodevelop/ctl.sh')
const loopScript = path.join(repoRoot, 'scripts/autodevelop/loop.sh')
const passScript = path.join(repoRoot, 'scripts/autodevelop/run-pass.sh')
const selftestScript = path.join(repoRoot, 'scripts/autodevelop/selftest.sh')
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
    expect(protocol).toContain('scripts/autodevelop/ctl.sh')
    expect(protocol).toContain('atomic directory lock')
  })

  test('single-lane supervisor pins the model and passes hermetic control tests', () => {
    const before = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })
    const selftest = execFileSync('bash', [selftestScript], { cwd: repoRoot, encoding: 'utf8' })
    const prompt = execFileSync('bash', [passScript, '--print-prompt'], { cwd: repoRoot, encoding: 'utf8' })
    const after = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })
    const control = fs.readFileSync(controlScript, 'utf8')
    const loop = fs.readFileSync(loopScript, 'utf8')

    for (const script of [controlScript, loopScript, passScript, selftestScript]) {
      expect(fs.statSync(script).mode & 0o111).not.toBe(0)
    }
    expect(after).toBe(before)
    expect(selftest).toContain('PASS=24 FAIL=0')
    expect(prompt).toContain('Use only gpt-5.6-sol with ultra reasoning')
    expect(prompt).toContain('Never delegate, spawn subagents, create child tasks, or fall back')
    expect(prompt).toContain('Do not push, publish, deploy')
    expect(prompt).toContain('ZIGCSS-AUTODEVELOP-STATUS: PROGRESS <short summary>')
    expect(control).toContain('doctor|test|run|start|stop|pause|resume|status|logs|orient')
    expect(control).not.toMatch(/launchctl|git\s+push|npm\s+publish/)
    expect(loop).toContain('blocked attempt $BLOCKED_COUNT/3')
    expect(loop).toContain('consecutive-errors')
  })
})
