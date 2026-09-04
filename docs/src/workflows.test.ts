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

  test('live-smokes the public development container in the unfiltered Build gate', () => {
    const buildWorkflow = fs.readFileSync(path.join(workflowsDir, 'build.yml'), 'utf8')
    const docsTest = buildWorkflow.indexOf('npm --prefix docs run test:run')
    const containerSmoke = buildWorkflow.indexOf('npm run test:dev-container')
    const nextStep = buildWorkflow.indexOf('Install VS Code extension dependencies')

    expect(containerSmoke).toBeGreaterThan(docsTest)
    expect(nextStep).toBeGreaterThan(containerSmoke)
    expect(buildWorkflow.match(/npm run test:dev-container/g)).toHaveLength(1)
    expect(buildWorkflow).not.toMatch(/npm run test:dev-container\n\s+continue-on-error: true/)
  })

  test('deploys only the exact successful green main commit', () => {
    expect(workflow).toMatch(/^name: Documentation$/m)
    expect(workflow).toContain('workflow_run:')
    expect(workflow).toContain('workflows: [Build]')
    expect(workflow).toContain('types: [completed]')
    expect(workflow).not.toContain('workflow_dispatch:')
    expect(workflow).toContain("github.event_name == 'workflow_run'")
    expect(workflow).toContain("github.event.workflow_run.name == 'Build'")
    expect(workflow).toContain("github.event.workflow_run.path == '.github/workflows/build.yml'")
    expect(workflow).toContain("github.event.workflow_run.conclusion == 'success'")
    expect(workflow).toContain("github.event.workflow_run.event == 'push'")
    expect(workflow).toContain("github.event.workflow_run.head_branch == 'main'")
    expect(workflow).toContain('github.event.workflow_run.repository.full_name == github.repository')
    expect(workflow).toContain('github.event.workflow_run.head_repository.full_name == github.repository')
    expect(workflow).toContain("ref: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || github.sha }}")
    expect(workflow).toContain('test "$actual_source_sha" = "$EXPECTED_SOURCE_SHA"')
    expect(workflow).toContain('needs.build.outputs.source-sha == github.event.workflow_run.head_sha')
    expect(workflow).toContain('needs: build')
  })

  test('bounds validation and deployment without letting a failed Build cancel a green deployment', () => {
    expect(workflow).toContain('    timeout-minutes: 45')
    expect(workflow).toContain('    timeout-minutes: 15')
    expect(workflow).toContain("github.event.workflow_run.conclusion == 'success' && 'deploy'")
  })

  test('audits the complete documentation build graph before tests and build', () => {
    const install = workflow.indexOf('npm ci --ignore-scripts')
    const audit = workflow.indexOf('npm audit --include=prod --include=dev --include=optional --include=peer --package-lock-only --audit-level=high')
    const tests = workflow.indexOf('npm run test:run')
    const build = workflow.indexOf('npm run build')

    expect(install).toBeGreaterThan(-1)
    expect(audit).toBeGreaterThan(install)
    expect(tests).toBeGreaterThan(audit)
    expect(build).toBeGreaterThan(tests)
  })

  test('builds and live-smokes the pinned documentation container before upload', () => {
    const build = workflow.indexOf('npm run build')
    const container = workflow.indexOf('node docs/scripts/smoke-docs-container.mjs')
    const upload = workflow.indexOf('uses: actions/upload-pages-artifact@')

    expect(container).toBeGreaterThan(build)
    expect(upload).toBeGreaterThan(container)
    for (const input of [
      'docs/**',
      'Dockerfile.docs',
      'Dockerfile.docs.dockerignore',
      'index.js',
      'install.js',
      'README.md',
      'LICENSE',
      'package.json',
      'package-lock.json',
      '.github/workflows/docs.yml',
    ]) {
      expect(workflow.match(new RegExp(`^      - '${input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}'$`, 'gm'))).toHaveLength(2)
    }
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
    expect(buildWorkflow).toMatch(/^name: Build$/m)
    expect(releaseWorkflow).toMatch(/^name: Release$/m)
    expect(workflows.match(/\n\s+uses:/g)).toHaveLength(46)
    expect(workflows).not.toMatch(/\n\s+uses: [^\n]+@(?![0-9a-f]{40} # v)/)
    expect(buildWorkflow).toContain(
      'uses: cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31',
    )
    expect(buildWorkflow).toContain('install_url: https://releases.nixos.org/nix/nix-2.35.2/install')
    expect(statusGuide).toContain('Their twelve jobs declare only the access they use')
    expect(statusGuide).toContain('All 46 action references are pinned')
    expect(statusGuide).toContain('release build job receives attestation and OIDC write access')
  })

  test('bounds every release job with an explicit hard timeout', () => {
    expect(releaseWorkflow.match(/^    timeout-minutes: (?:15|30|45|120)$/gm)).toEqual([
      '    timeout-minutes: 45',
      '    timeout-minutes: 120',
      '    timeout-minutes: 30',
      '    timeout-minutes: 30',
      '    timeout-minutes: 15',
    ])
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

  test('runs the complete documentation suite for every Build change', () => {
    const trigger = buildWorkflow.slice(0, buildWorkflow.indexOf('\njobs:'))
    const rootInstall = buildWorkflow.indexOf('- name: Install independent validator')
    const docsInstall = buildWorkflow.indexOf('- name: Install documentation dependencies')
    const docsTests = buildWorkflow.indexOf('npm --prefix docs run test:run')

    expect(trigger).toContain('  push:\n    branches: [main, development]')
    expect(trigger).toContain('  pull_request:\n    branches: [main, development]')
    expect(trigger).not.toMatch(/^\s+paths(?:-ignore)?:/m)
    expect(buildWorkflow.match(/npm --prefix docs run test:run/g)).toHaveLength(1)
    expect(docsInstall).toBeGreaterThan(rootInstall)
    expect(docsTests).toBeGreaterThan(docsInstall)
    expect(statusGuide).toContain('The unfiltered common `Build` workflow installs the locked documentation graph')
  })

  test('audits every production graph, the full root development graph, and pinned host locks before native integration', () => {
    const exactNode = buildWorkflow.indexOf("node-version: '22.22.0'")
    const extensionInstall = buildWorkflow.indexOf('Install VS Code extension dependencies')
    const policy = buildWorkflow.indexOf('npm run test:dependencies', extensionInstall)
    const audit = buildWorkflow.indexOf('npm run audit:production', policy)
    const developmentAudit = buildWorkflow.indexOf('npm run audit:development', audit)
    const documentationAudit = buildWorkflow.indexOf('npm run audit:documentation', developmentAudit)
    const vscodeAudit = buildWorkflow.indexOf('npm run audit:vscode', documentationAudit)
    const turbopackAudit = buildWorkflow.indexOf('npm run audit:turbopack-example', vscodeAudit)
    const sveltekitAudit = buildWorkflow.indexOf('npm run audit:sveltekit-example', turbopackAudit)
    const astroAudit = buildWorkflow.indexOf('npm run audit:astro-example', sveltekitAudit)
    const nuxtAudit = buildWorkflow.indexOf('npm run audit:nuxt-example', astroAudit)
    const packageManagers = buildWorkflow.indexOf('npm run test:package-managers', nuxtAudit)
    const types = buildWorkflow.indexOf('npm run test:types', packageManagers)
    const extensionPackage = buildWorkflow.indexOf('Test and package VS Code extension', types)
    const nativeTests = buildWorkflow.indexOf('node scripts/run-zig-test-suite.mjs --mode Debug', extensionPackage)
    const adapterStep = buildWorkflow.indexOf('Verify build-tool adapters', nativeTests)
    const adapterBinary = buildWorkflow.indexOf('ZIGCSS_ADAPTER_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', adapterStep)
    const adapters = buildWorkflow.indexOf('run: npm run test:bundler-adapters', adapterBinary)
    const turbopackStep = buildWorkflow.indexOf('Verify Next.js Turbopack global SCSS integration', adapters)
    const turbopackBinary = buildWorkflow.indexOf('ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', turbopackStep)
    const turbopack = buildWorkflow.indexOf('run: npm run test:turbopack-example', turbopackBinary)
    const nextWebpackStep = buildWorkflow.indexOf('Verify Next.js Webpack global SCSS integration', turbopack)
    const nextWebpackBinary = buildWorkflow.indexOf('ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', nextWebpackStep)
    const nextWebpack = buildWorkflow.indexOf('run: npm run test:next-webpack-example', nextWebpackBinary)
    const sveltekitStep = buildWorkflow.indexOf('Verify SvelteKit external CSS Module integration', nextWebpack)
    const sveltekitBinary = buildWorkflow.indexOf('ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', sveltekitStep)
    const sveltekit = buildWorkflow.indexOf('run: npm run test:sveltekit-example', sveltekitBinary)
    const astroStep = buildWorkflow.indexOf('Verify Astro external CSS Module integration', sveltekit)
    const astroBinary = buildWorkflow.indexOf('ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', astroStep)
    const astro = buildWorkflow.indexOf('run: npm run test:astro-example', astroBinary)
    const nuxtStep = buildWorkflow.indexOf('Verify Nuxt external CSS Module integration', astro)
    const nuxtBinary = buildWorkflow.indexOf('ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', nuxtStep)
    const nuxt = buildWorkflow.indexOf('run: npm run test:nuxt-example', nuxtBinary)
    const parcelStep = buildWorkflow.indexOf('Verify Parcel local transformer integration', nuxt)
    const parcelBinary = buildWorkflow.indexOf('ZIGCSS_PARCEL_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', parcelStep)
    const parcel = buildWorkflow.indexOf('run: npm run test:parcel-example', parcelBinary)
    const buildSystemsStep = buildWorkflow.indexOf('Verify dependency-file build-system integrations', parcel)
    const realBinary = buildWorkflow.indexOf('ZIGCSS_REAL_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', buildSystemsStep)
    const requiredBuildSystems = buildWorkflow.indexOf("ZIGCSS_REQUIRE_BUILD_SYSTEMS: '1'", realBinary)
    const buildSystems = buildWorkflow.indexOf('run: npm run test:build-systems', requiredBuildSystems)

    expect(exactNode).toBeGreaterThan(-1)
    expect(extensionInstall).toBeGreaterThan(exactNode)
    expect(policy).toBeGreaterThan(extensionInstall)
    expect(audit).toBeGreaterThan(policy)
    expect(developmentAudit).toBeGreaterThan(audit)
    expect(documentationAudit).toBeGreaterThan(developmentAudit)
    expect(vscodeAudit).toBeGreaterThan(documentationAudit)
    expect(turbopackAudit).toBeGreaterThan(vscodeAudit)
    expect(sveltekitAudit).toBeGreaterThan(turbopackAudit)
    expect(astroAudit).toBeGreaterThan(sveltekitAudit)
    expect(nuxtAudit).toBeGreaterThan(astroAudit)
    expect(packageManagers).toBeGreaterThan(nuxtAudit)
    expect(types).toBeGreaterThan(packageManagers)
    expect(extensionPackage).toBeGreaterThan(types)
    expect(nativeTests).toBeGreaterThan(extensionPackage)
    expect(adapterStep).toBeGreaterThan(nativeTests)
    expect(adapterBinary).toBeGreaterThan(adapterStep)
    expect(adapters).toBeGreaterThan(adapterBinary)
    expect(turbopackStep).toBeGreaterThan(adapters)
    expect(turbopackBinary).toBeGreaterThan(turbopackStep)
    expect(turbopack).toBeGreaterThan(turbopackBinary)
    expect(nextWebpackStep).toBeGreaterThan(turbopack)
    expect(nextWebpackBinary).toBeGreaterThan(nextWebpackStep)
    expect(nextWebpack).toBeGreaterThan(nextWebpackBinary)
    expect(sveltekitStep).toBeGreaterThan(nextWebpack)
    expect(sveltekitBinary).toBeGreaterThan(sveltekitStep)
    expect(sveltekit).toBeGreaterThan(sveltekitBinary)
    expect(astroStep).toBeGreaterThan(sveltekit)
    expect(astroBinary).toBeGreaterThan(astroStep)
    expect(astro).toBeGreaterThan(astroBinary)
    expect(nuxtStep).toBeGreaterThan(astro)
    expect(nuxtBinary).toBeGreaterThan(nuxtStep)
    expect(nuxt).toBeGreaterThan(nuxtBinary)
    expect(parcelStep).toBeGreaterThan(nuxt)
    expect(parcelBinary).toBeGreaterThan(parcelStep)
    expect(parcel).toBeGreaterThan(parcelBinary)
    expect(buildSystemsStep).toBeGreaterThan(parcel)
    expect(realBinary).toBeGreaterThan(buildSystemsStep)
    expect(requiredBuildSystems).toBeGreaterThan(realBinary)
    expect(buildSystems).toBeGreaterThan(requiredBuildSystems)
    expect(statusGuide).toContain("The ordinary build workflow's Test job uses exact Node 22.22.0")
    expect(statusGuide).toContain('the seven owned production dependency audits, one complete root development audit, the complete documentation and VS Code build-graph audits, and the four full pinned Next.js, SvelteKit, Astro, and Nuxt host-lock audits')
    expect(statusGuide).toContain('The audit order is production graphs, root development graph, documentation and VS Code build graphs, then the four host locks')
    expect(statusGuide).toContain('the four full pinned Next.js, SvelteKit, Astro, and Nuxt host-lock audits')
    expect(statusGuide).toContain('After the native Debug suite builds and tests `zig-out/bin/zigcss`, the adapter, Next.js Turbopack, Next.js Webpack, SvelteKit, Astro, Nuxt, Parcel, and dependency-file build-system suites receive that exact binary in that order')
    expect(dependabot.match(/package-ecosystem:/g)).toHaveLength(3)
    expect(dependabot).toContain('- "/examples/next-turbopack"')
    expect(dependabot).toContain('- "/examples/sveltekit"')
    expect(dependabot).toContain('- "/examples/astro"')
    expect(dependabot).toContain('- "/examples/nuxt"')
    expect(dependabot).toContain('- "/vscode-extension"')
    expect(dependabot).toContain('open-pull-requests-limit: 3')
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

  test('keeps native migration and future tag publication fail closed', () => {
    const releaseMetadata = buildWorkflow.indexOf('npm run test:release-metadata')
    const nativeContract = buildWorkflow.indexOf(
      'npm run test:native-contract && npm run test:native-package-evidence && npm run check:native-contract',
      releaseMetadata,
    )
    const releaseConsumers = buildWorkflow.indexOf(
      'npm run test:release-smoke',
      nativeContract,
    )
    const stableContract = buildWorkflow.indexOf(
      'npm run test:stable-release && npm run check:stable-release',
      nativeContract,
    )
    const tagInterlock = releaseWorkflow.indexOf('- name: Verify release candidate admission')
    const npmAuthority = releaseWorkflow.indexOf('npm whoami')
    const npmPublish = releaseWorkflow.indexOf(
      'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --provenance',
    )

    expect(nativeContract).toBeGreaterThan(releaseMetadata)
    expect(stableContract).toBeGreaterThan(nativeContract)
    expect(releaseConsumers).toBeGreaterThan(stableContract)
    expect(tagInterlock).toBeGreaterThan(-1)
    expect(releaseWorkflow).toContain('node scripts/validate-release-admission.mjs --check')
    expect(releaseWorkflow).toContain('--release-tag "$GITHUB_REF_NAME"')
    expect(releaseWorkflow).toContain('--candidate-commit "$candidate_commit"')
    expect(releaseWorkflow).toContain('--origin-main-commit "$origin_main_commit"')
    expect(statusGuide).toContain(
      'Active source candidate 0.7.0-rc.1 is selected in `release/next-release.json` but is not published.',
    )
    expect(statusGuide).toContain(
      'Its `candidateReady` interlock remains `false` until all seven pre-tag gates pass',
    )
    expect(statusGuide).toContain('5 of 8 admission gates now carry recorded evidence')
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
