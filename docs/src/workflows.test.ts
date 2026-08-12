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
    const workflows = [
      buildWorkflow,
      releaseWorkflow,
      fs.readFileSync(path.join(workflowsDir, 'docs.yml'), 'utf8'),
      fs.readFileSync(path.join(workflowsDir, 'benchmarks.yml'), 'utf8'),
    ].join('\n')

    expect(workflows.match(/^permissions: \{\}$/gm)).toHaveLength(4)
    expect(workflows.match(/\n\s+uses:/g)).toHaveLength(32)
    expect(workflows).not.toMatch(/\n\s+uses: [^\n]+@(?![0-9a-f]{40} # v)/)
    expect(statusGuide).toContain('Their ten jobs declare only the access they use')
    expect(statusGuide).toContain('All 32 action invocations are pinned')
    expect(statusGuide).toContain('release build job receives attestation and OIDC write access')
  })

  test('passes every build matrix target to Zig after the ReleaseSafe suite', () => {
    const nativeTests = buildWorkflow.indexOf(
      'node scripts/run-zig-test-suite.mjs --mode ReleaseSafe',
    )
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
    const tests = buildWorkflow.indexOf(
      'node scripts/run-zig-test-suite.mjs --mode Debug',
      prefixData,
    )
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
    const nativeTests = buildWorkflow.indexOf(
      'node scripts/run-zig-test-suite.mjs --mode Debug',
      mainTestStep,
    )
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
    const nativeTests = buildWorkflow.indexOf(
      'node scripts/run-zig-test-suite.mjs --mode Debug',
    )
    const compatibility = buildWorkflow.lastIndexOf('npm run test:compat')
    const transforms = buildWorkflow.lastIndexOf('npm run test:transforms')

    expect(install).toBeGreaterThan(-1)
    expect(nativeTests).toBeGreaterThan(install)
    expect(compatibility).toBeGreaterThan(nativeTests)
    expect(transforms).toBeGreaterThan(compatibility)
  })

  test('validates package metadata, bounded preprocessing, and result ownership before CSS oracles', () => {
    const metadata = buildWorkflow.indexOf('npm run test:zig-package')
    const nativeTests = buildWorkflow.lastIndexOf(
      'node scripts/run-zig-test-suite.mjs --mode Debug',
      metadata,
    )
    const wrapper = buildWorkflow.indexOf('npm run test:node-wrapper', metadata)
    const preprocessorHost = buildWorkflow.indexOf('npm run test:preprocessor-host', wrapper)
    const preprocessorResolver = buildWorkflow.indexOf(
      'npm run test:preprocessor-resolver',
      preprocessorHost,
    )
    const preprocessorMetadata = buildWorkflow.indexOf(
      'npm run test:preprocessor-metadata',
      preprocessorResolver,
    )
    const preprocessorSass = buildWorkflow.indexOf(
      'npm run test:preprocessor-sass',
      preprocessorMetadata,
    )
    const preprocessorLess = buildWorkflow.indexOf(
      'npm run test:preprocessor-less',
      preprocessorSass,
    )
    const formats = buildWorkflow.indexOf('npm run test:formats', preprocessorLess)
    const packageConsumer = buildWorkflow.indexOf('working-directory: tests/package-consumer', formats)
    const consumerTests = buildWorkflow.indexOf('zig build test --summary all', packageConsumer)
    const compatibility = buildWorkflow.indexOf('npm run test:compat', consumerTests)

    expect(metadata).toBeGreaterThan(nativeTests)
    expect(wrapper).toBeGreaterThan(metadata)
    expect(preprocessorHost).toBeGreaterThan(wrapper)
    expect(preprocessorResolver).toBeGreaterThan(preprocessorHost)
    expect(preprocessorMetadata).toBeGreaterThan(preprocessorResolver)
    expect(preprocessorSass).toBeGreaterThan(preprocessorMetadata)
    expect(preprocessorLess).toBeGreaterThan(preprocessorSass)
    expect(formats).toBeGreaterThan(preprocessorLess)
    expect(packageConsumer).toBeGreaterThan(formats)
    expect(consumerTests).toBeGreaterThan(packageConsumer)
    expect(compatibility).toBeGreaterThan(consumerTests)
  })

  test('keeps native migration and tag publication fail closed', () => {
    const releaseMetadata = buildWorkflow.indexOf('npm run test:release-metadata')
    const nativeContract = buildWorkflow.indexOf(
      'npm run test:native-contract && npm run test:native-package-evidence && npm run check:native-contract',
      releaseMetadata,
    )
    const releaseConsumers = buildWorkflow.indexOf(
      'npm run test:release-smoke',
      nativeContract,
    )
    const tagInterlock = releaseWorkflow.indexOf(
      'npm run check:native-contract -- --release-tag "$GITHUB_REF_NAME"',
    )
    const npmAuthority = releaseWorkflow.indexOf('npm whoami')
    const npmPublish = releaseWorkflow.indexOf('npm publish --tag next --provenance')

    expect(nativeContract).toBeGreaterThan(releaseMetadata)
    expect(releaseConsumers).toBeGreaterThan(nativeContract)
    expect(tagInterlock).toBeGreaterThan(-1)
    expect(npmAuthority).toBeGreaterThan(tagInterlock)
    expect(npmPublish).toBeGreaterThan(npmAuthority)
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
