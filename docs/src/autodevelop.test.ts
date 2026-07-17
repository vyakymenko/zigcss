// @vitest-environment node

import { describe, expect, test } from 'vitest'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const orientScript = path.join(repoRoot, 'scripts/autodevelop/orient.sh')
const controlScript = path.join(repoRoot, 'scripts/autodevelop/ctl.sh')
const launchScript = path.join(repoRoot, 'scripts/autodevelop/launch-loop.sh')
const loopScript = path.join(repoRoot, 'scripts/autodevelop/loop.sh')
const passScript = path.join(repoRoot, 'scripts/autodevelop/run-pass.sh')
const pushScript = path.join(repoRoot, 'scripts/autodevelop/push-checkpoint.sh')
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
    expect(protocol).toContain('automatically pushes')
    expect(protocol).toContain('finish SCSS and indented Sass through `SASS-012`')
    expect(protocol).toContain('Less through `LESS-012`')
    expect(protocol).toContain('Stylus through `STYLUS-012`')
    expect(protocol).toContain('must not block dependency-eligible preprocessor correctness work')
    expect(protocol).toContain('Do not publish, deploy, or open a pull request')
    expect(protocol).toContain('scripts/autodevelop/orient.sh')
    expect(protocol).toContain('scripts/autodevelop/ctl.sh')
    expect(protocol).toContain('atomic directory lock')
    expect(protocol).toContain('BLOCKED <stable-code>: <reason>')
  })

  test('single-lane supervisor pins the model and passes hermetic control tests', () => {
    const before = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })
    const selftest = execFileSync('bash', [selftestScript], { cwd: repoRoot, encoding: 'utf8' })
    const prompt = execFileSync('bash', [passScript, '--print-prompt'], { cwd: repoRoot, encoding: 'utf8' })
    const after = execFileSync('git', ['status', '--porcelain=v1'], { cwd: repoRoot, encoding: 'utf8' })
    const control = fs.readFileSync(controlScript, 'utf8')
    const loop = fs.readFileSync(loopScript, 'utf8')
    const push = fs.readFileSync(pushScript, 'utf8')

    for (const script of [controlScript, launchScript, loopScript, passScript, pushScript, selftestScript]) {
      expect(fs.statSync(script).mode & 0o111).not.toBe(0)
    }
    expect(after).toBe(before)
    expect(selftest).toContain('PASS=47 FAIL=0')
    expect(prompt).toContain('Use only gpt-5.6-sol with ultra reasoning')
    expect(prompt).toContain('Never delegate, spawn subagents, create child tasks, or fall back')
    expect(prompt).toContain('SCSS/Sass through SASS-012')
    expect(prompt).toContain('Less through LESS-012')
    expect(prompt).toContain('Stylus through STYLUS-012')
    expect(prompt).toContain('earliest dependency-eligible package not marked VERIFIED')
    expect(prompt).toContain('After PRE-008 is verified, PRE-009 is next')
    expect(prompt).toContain('pending external BENCH-007 runner must not block')
    expect(prompt).toContain('Do not push from this model pass')
    expect(prompt).toContain('ZIGCSS-AUTODEVELOP-STATUS: PROGRESS <short summary>')
    expect(control).toContain('doctor|test|run|start|stop|pause|resume|status|logs|orient')
    expect(control).toContain('screen -dmS')
    expect(control).not.toMatch(/Library\/LaunchAgents|launchctl|git\s+push|npm\s+publish/)
    expect(loop).toContain('blocked attempt $BLOCKED_COUNT/3')
    expect(loop).toContain('autodevelop_record_blocker "$BLOCKER_CODE"')
    expect(loop).toContain('consecutive-errors')
    expect(loop).toContain('push_green_checkpoint || break')
    expect(push).toContain('push --porcelain')
    expect(push).toContain('ls-remote --exit-code')
    expect(push).not.toMatch(/--force(?:-with-lease)?/)
  })
})
