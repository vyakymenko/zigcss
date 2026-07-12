// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const workflowsDir = path.resolve(import.meta.dirname, '..', '..', '.github', 'workflows')

describe('documentation workflow', () => {
  const workflow = fs.readFileSync(path.join(workflowsDir, 'docs.yml'), 'utf8')

  test('validates documentation on pull requests', () => {
    expect(workflow).toContain('pull_request:')
    expect(workflow).toContain('npm run test:run')
    expect(workflow).toContain('npm run build')
  })

  test('uploads the verified Vite output', () => {
    expect(workflow).toContain('path: docs/dist')
    expect(workflow).not.toContain('docs/.vitepress/dist')
  })

  test('keeps deployment out of pull-request validation', () => {
    expect(workflow).toContain("if: github.event_name != 'pull_request'")
    expect(workflow).toContain('needs: build')
  })
})

describe('native artifact workflows', () => {
  const buildWorkflow = fs.readFileSync(path.join(workflowsDir, 'build.yml'), 'utf8')
  const releaseWorkflow = fs.readFileSync(path.join(workflowsDir, 'release.yml'), 'utf8')

  test('passes every build matrix target to Zig after native tests', () => {
    const nativeTests = buildWorkflow.indexOf('zig build test --summary all')
    const targetBuild = buildWorkflow.indexOf('zig build -Doptimize=ReleaseSafe -Dtarget=${{ matrix.target }}')
    const inspection = buildWorkflow.indexOf('node scripts/verify-artifact-target.mjs')
    const upload = buildWorkflow.indexOf('uses: actions/upload-artifact@v4')

    expect(nativeTests).toBeGreaterThan(-1)
    expect(targetBuild).toBeGreaterThan(nativeTests)
    expect(inspection).toBeGreaterThan(targetBuild)
    expect(upload).toBeGreaterThan(inspection)
  })

  test('verifies pinned generated prefix data before the main test suite', () => {
    const install = buildWorkflow.indexOf('npm ci --ignore-scripts')
    const generatorTests = buildWorkflow.indexOf('npm run test:prefix-data')
    const prefixData = buildWorkflow.indexOf('npm run check:prefix-data')
    const tests = buildWorkflow.indexOf('zig build test --summary all', prefixData)
    expect(install).toBeGreaterThan(-1)
    expect(generatorTests).toBeGreaterThan(install)
    expect(prefixData).toBeGreaterThan(generatorTests)
    expect(tests).toBeGreaterThan(prefixData)
  })

  test('passes every release matrix target to Zig and verifies the result', () => {
    expect(releaseWorkflow).toContain('zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.target }}')
    expect(releaseWorkflow).toContain('node scripts/verify-artifact-target.mjs')
    expect(releaseWorkflow).not.toContain('if [ "${{ matrix.target }}"')
  })

  test('runs the locked independent CSS validator after native tests', () => {
    const install = buildWorkflow.lastIndexOf('npm ci --ignore-scripts')
    const nativeTests = buildWorkflow.lastIndexOf('zig build test --summary all')
    const compatibility = buildWorkflow.lastIndexOf('npm run test:compat')
    const transforms = buildWorkflow.lastIndexOf('npm run test:transforms')

    expect(install).toBeGreaterThan(-1)
    expect(nativeTests).toBeGreaterThan(install)
    expect(compatibility).toBeGreaterThan(nativeTests)
    expect(transforms).toBeGreaterThan(compatibility)
  })
})
