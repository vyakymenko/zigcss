// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const workflowsDir = path.resolve(import.meta.dirname, '..', '..', '.github', 'workflows')
const statusGuide = fs.readFileSync(path.resolve(import.meta.dirname, 'content', 'docs', 'guide', 'status.md'), 'utf8')

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
  const dependabot = fs.readFileSync(path.resolve(workflowsDir, '..', 'dependabot.yml'), 'utf8')

  test('publishes the enforced least-privilege and immutable-action boundary', () => {
    const workflows = [buildWorkflow, releaseWorkflow, fs.readFileSync(path.join(workflowsDir, 'docs.yml'), 'utf8')].join('\n')

    expect(workflows.match(/^permissions: \{\}$/gm)).toHaveLength(3)
    expect(workflows.match(/\n\s+uses:/g)).toHaveLength(19)
    expect(workflows).not.toMatch(/\n\s+uses: [^\n]+@(?![0-9a-f]{40} # v)/)
    expect(statusGuide).toContain('Their seven jobs declare only the access they use')
    expect(statusGuide).toContain('All 19 action invocations are pinned')
  })

  test('passes every build matrix target to Zig after native tests', () => {
    const nativeTests = buildWorkflow.indexOf('zig build test --summary all')
    const targetBuild = buildWorkflow.indexOf('zig build -Doptimize=ReleaseSafe -Dtarget=${{ matrix.target }}')
    const inspection = buildWorkflow.indexOf('node scripts/verify-artifact-target.mjs')
    const upload = buildWorkflow.indexOf('uses: actions/upload-artifact@')

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

  test('audits every locked production graph under bounded update-only automation', () => {
    const extensionInstall = buildWorkflow.indexOf('Install VS Code extension dependencies')
    const policy = buildWorkflow.indexOf('npm run test:dependencies', extensionInstall)
    const audit = buildWorkflow.indexOf('npm run audit:production', policy)
    const extensionPackage = buildWorkflow.indexOf('Test and package VS Code extension', audit)

    expect(policy).toBeGreaterThan(extensionInstall)
    expect(audit).toBeGreaterThan(policy)
    expect(extensionPackage).toBeGreaterThan(audit)
    expect(dependabot.match(/package-ecosystem:/g)).toHaveLength(3)
    expect(dependabot).toContain('- "/vscode-extension"')
    expect(dependabot).toContain('open-pull-requests-limit: 1')
    expect(dependabot).not.toMatch(/automerge|registries|target-branch|reviewers|assignees/i)
  })

  test('validates every documentation link and example after compiler and editor setup', () => {
    const mainTestStep = buildWorkflow.indexOf('- name: Run Tests')
    const nativeTests = buildWorkflow.indexOf('zig build test --summary all', mainTestStep)
    const neovim = buildWorkflow.indexOf('npm run test:neovim', nativeTests)
    const documentation = buildWorkflow.indexOf('npm run test:documentation', neovim)
    const drift = buildWorkflow.indexOf('npm run check:documentation', documentation)
    const metadata = buildWorkflow.indexOf('npm run test:zig-package', drift)

    expect(mainTestStep).toBeGreaterThan(-1)
    expect(nativeTests).toBeGreaterThan(mainTestStep)
    expect(neovim).toBeGreaterThan(nativeTests)
    expect(documentation).toBeGreaterThan(neovim)
    expect(drift).toBeGreaterThan(documentation)
    expect(metadata).toBeGreaterThan(drift)
    expect(buildWorkflow).toContain('NVIM: ${{ runner.temp }}/nvim-0.11.7/bin/nvim')
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

  test('validates package metadata wrapper behavior and a real path dependency before CSS oracles', () => {
    const metadata = buildWorkflow.indexOf('npm run test:zig-package')
    const nativeTests = buildWorkflow.lastIndexOf('zig build test --summary all', metadata)
    const wrapper = buildWorkflow.indexOf('npm run test:node-wrapper', metadata)
    const formats = buildWorkflow.indexOf('npm run test:formats', wrapper)
    const packageConsumer = buildWorkflow.indexOf('working-directory: tests/package-consumer', formats)
    const consumerTests = buildWorkflow.indexOf('zig build test --summary all', packageConsumer)
    const compatibility = buildWorkflow.indexOf('npm run test:compat', consumerTests)

    expect(metadata).toBeGreaterThan(nativeTests)
    expect(wrapper).toBeGreaterThan(metadata)
    expect(formats).toBeGreaterThan(wrapper)
    expect(packageConsumer).toBeGreaterThan(formats)
    expect(consumerTests).toBeGreaterThan(packageConsumer)
    expect(compatibility).toBeGreaterThan(consumerTests)
  })

  test('compiles the complete build integration example in both safe modes', () => {
    const exampleDirectory = 'working-directory: examples/build-integration'
    const firstDirectory = buildWorkflow.indexOf(exampleDirectory)
    const debug = buildWorkflow.indexOf('zig build test --summary all', firstDirectory)
    const secondDirectory = buildWorkflow.indexOf(exampleDirectory, debug)
    const releaseSafe = buildWorkflow.indexOf(
      'zig build test -Doptimize=ReleaseSafe --summary all',
      secondDirectory,
    )
    const compatibility = buildWorkflow.indexOf('npm run test:compat', releaseSafe)

    expect(firstDirectory).toBeGreaterThan(-1)
    expect(debug).toBeGreaterThan(firstDirectory)
    expect(secondDirectory).toBeGreaterThan(debug)
    expect(releaseSafe).toBeGreaterThan(secondDirectory)
    expect(compatibility).toBeGreaterThan(releaseSafe)
  })
})
