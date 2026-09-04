import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  artifactRecords as setupZigArtifactRecords,
  maximumArchiveEntries as setupZigMaximumArchiveEntries,
  maximumCacheBytes as setupZigMaximumCacheBytes,
  resolveArchiveCommand as setupZigResolveArchiveCommand,
  zigVersion as setupZigVersion,
} from '../.github/actions/setup-zig/setup-zig.mjs'
import { nativeTargetContract } from './native-target-contract.mjs'
import { failureHeadBytes, suiteArguments } from './run-zig-test-suite.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const setupZigAction = './.github/actions/setup-zig'

// Each commit was resolved from the named tag in the action's official repository.
// Dependabot owns reviewed updates to these immutable references.
export const actionPins = Object.freeze({
  'actions/checkout': Object.freeze({
    sha: '3d3c42e5aac5ba805825da76410c181273ba90b1',
    version: 'v7.0.1',
    runtime: 'node24',
  }),
  'actions/cache': Object.freeze({
    sha: '27d5ce7f107fe9357f9df03efb73ab90386fccae',
    version: 'v5.0.5',
    runtime: 'node24',
  }),
  'actions/upload-artifact': Object.freeze({
    sha: '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
    version: 'v7.0.1',
    runtime: 'node24',
  }),
  'actions/setup-node': Object.freeze({
    sha: '820762786026740c76f36085b0efc47a31fe5020',
    version: 'v7.0.0',
    runtime: 'node24',
  }),
  'actions/upload-pages-artifact': Object.freeze({
    sha: 'fc324d3547104276b827a68afc52ff2a11cc49c9',
    version: 'v5.0.0',
    runtime: 'node24',
  }),
  'actions/deploy-pages': Object.freeze({
    sha: 'cd2ce8fcbc39b97be8ca5fce6e763baed58fa128',
    version: 'v5.0.0',
    runtime: 'node24',
  }),
  'actions/download-artifact': Object.freeze({
    sha: '3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
    version: 'v8.0.1',
    runtime: 'node24',
  }),
  'actions/attest': Object.freeze({
    sha: 'a1948c3f048ba23858d222213b7c278aabede763',
    version: 'v4.1.1',
  }),
  'cachix/install-nix-action': Object.freeze({
    sha: '13d8dd58da0234aa297dedd986986ccb8e7f3e24',
    version: 'v31',
  }),
  'oven-sh/setup-bun': Object.freeze({
    sha: '0c5077e51419868618aeaa5fe8019c62421857d6',
    version: 'v2.2.0',
    runtime: 'node24',
  }),
  'softprops/action-gh-release': Object.freeze({
    sha: 'de2c0eb89ae2a093876385947365aca7b0e5f844',
    version: 'v1',
  }),
})

// Public Build and Documentation annotations define this exact finite
// migration inventory. Every retained official JavaScript/composite action
// below has a reviewed tagged Node 24 terminal. The sole tagged setup-zig
// remainder is retired in favor of the repository-owned composite.
export const actionRuntimeMigration = Object.freeze({
  requiredRuntime: 'node24',
  terminalActions: Object.freeze([
    'actions/checkout',
    'actions/setup-node',
    'actions/upload-artifact',
    'actions/download-artifact',
    'actions/upload-pages-artifact',
    'actions/deploy-pages',
    'oven-sh/setup-bun',
    'mlugg/setup-zig',
  ]),
  replacedActions: Object.freeze(['mlugg/setup-zig']),
  pendingActions: Object.freeze([]),
})

export const workflowPolicy = Object.freeze({
  'benchmarks.yml': Object.freeze({
    benchmark: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        setupZigAction,
        'actions/upload-artifact',
      ]),
    }),
  }),
  'build.yml': Object.freeze({
    build: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        'cachix/install-nix-action',
        setupZigAction,
        'actions/upload-artifact',
        'actions/upload-artifact',
      ]),
    }),
    'native-provenance-evidence': Object.freeze({
      permissions: Object.freeze({ attestations: 'write', contents: 'read', 'id-token': 'write' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        'actions/download-artifact',
        'actions/attest',
        'actions/attest',
        'actions/upload-artifact',
      ]),
    }),
    'native-package-evidence': Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        'actions/download-artifact',
        'actions/upload-artifact',
      ]),
    }),
    test: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        setupZigAction,
        'oven-sh/setup-bun',
      ]),
    }),
  }),
  'docs.yml': Object.freeze({
    build: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'actions/setup-node', 'actions/upload-pages-artifact']),
    }),
    deploy: Object.freeze({
      permissions: Object.freeze({ pages: 'write', 'id-token': 'write' }),
      actions: Object.freeze(['actions/deploy-pages']),
    }),
  }),
  'release.yml': Object.freeze({
    'npm-preflight': Object.freeze({
      permissions: Object.freeze({ actions: 'read', contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'actions/setup-node', 'actions/upload-artifact']),
    }),
    release: Object.freeze({
      permissions: Object.freeze({ attestations: 'write', contents: 'read', 'id-token': 'write' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
        'actions/download-artifact',
        setupZigAction,
        'actions/attest',
        'actions/attest',
        'actions/upload-artifact',
      ]),
    }),
    'create-release': Object.freeze({
      permissions: Object.freeze({ contents: 'write' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/download-artifact',
        'softprops/action-gh-release',
      ]),
    }),
    'publish-npm': Object.freeze({
      permissions: Object.freeze({ contents: 'read', 'id-token': 'write' }),
      actions: Object.freeze(['actions/checkout', 'actions/setup-node', 'actions/download-artifact']),
    }),
    'anonymous-public-delivery': Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'actions/setup-node']),
    }),
  }),
})

export const workflowDisplayNames = Object.freeze({
  'benchmarks.yml': 'Benchmarks',
  'build.yml': 'Build',
  'docs.yml': 'Documentation',
  'release.yml': 'Release',
})

export const terminalWorkflowTimeoutPolicy = Object.freeze({
  'docs.yml': Object.freeze({
    build: 45,
    deploy: 15,
  }),
  'release.yml': Object.freeze({
    'npm-preflight': 45,
    release: 120,
    'create-release': 30,
    'publish-npm': 30,
    'anonymous-public-delivery': 15,
  }),
})

export const nativeTestRunners = Object.freeze([
  'run_native_preprocessor_tests',
  'run_native_foundation_tests',
  'run_native_resolver_tests',
  'run_native_evaluator_tests',
  'run_native_sass_parser_tests',
  'run_native_less_parser_tests',
  'run_native_stylus_parser_tests',
  'run_native_stylus_evaluator_tests',
  'run_native_stylus_conformance_tests',
  'run_native_less_evaluator_tests',
  'run_native_less_conformance_tests',
  'run_native_sass_arguments_tests',
  'run_native_sass_numeric_tests',
  'run_native_sass_color_tests',
  'run_native_sass_string_tests',
  'run_native_sass_selector_tests',
  'run_native_sass_evaluator_tests',
  'run_native_sass_conformance_tests',
  'run_native_cli_tests',
])

export const packageManagerCiPolicy = Object.freeze({
  action: 'oven-sh/setup-bun',
  bunVersion: '1.4.0',
  gate: 'npm run test:package-managers',
})

export const publicDeliveryCiPolicy = Object.freeze({
  command: 'node scripts/smoke-public-delivery.mjs --version "${GITHUB_REF_NAME#v}"',
  job: 'anonymous-public-delivery',
  needs: 'publish-npm',
  nodeVersion: '20.19.0',
  registry: 'https://registry.npmjs.org/',
  runner: 'ubuntu-latest',
  timeoutMinutes: 15,
})

export const nixFlakeCiPolicy = Object.freeze({
  action: 'cachix/install-nix-action',
  checkScript: 'npm run check:nix-flake',
  installUrl: 'https://releases.nixos.org/nix/nix-2.35.2/install',
  nixVersion: '2.35.2',
  testScript: 'npm run test:nix-flake',
})

export const turbopackCiPolicy = Object.freeze({
  gate: 'npm run test:turbopack-example',
  host: 'Next.js 16.3.4',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
})

export const nextWebpackCiPolicy = Object.freeze({
  gate: 'npm run test:next-webpack-example',
  host: 'Next.js 16.3.4 with Webpack 5.110.2',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  nodeVersion: '22.22.0',
})

export const sveltekitCiPolicy = Object.freeze({
  gate: 'npm run test:sveltekit-example',
  host: 'SvelteKit 2.70.3 with Vite 8.2.2',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
})

export const astroCiPolicy = Object.freeze({
  gate: 'npm run test:astro-example',
  host: 'Astro 7.2.10',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  nodeVersion: '22.22.0',
})

export const nuxtCiPolicy = Object.freeze({
  gate: 'npm run test:nuxt-example',
  host: 'Nuxt 4.5.2',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  nodeVersion: '22.22.0',
})

export const buildThroughputPolicy = Object.freeze({
  interventionPercent: 75,
  artifactMatrix: Object.freeze(nativeTargetContract.map(target => Object.freeze({
    os: target.runner,
    arch: target.zigArch,
    target: target.target,
    archiveExtension: target.archiveExtension,
    zigVersion: target.zigVersion,
    binaryName: target.binaryName,
  }))),
  jobs: Object.freeze({
    build: Object.freeze({ timeoutMinutes: 240 }),
    'native-provenance-evidence': Object.freeze({ timeoutMinutes: 30 }),
    'native-package-evidence': Object.freeze({ timeoutMinutes: 60 }),
    test: Object.freeze({ timeoutMinutes: 240 }),
  }),
})

export const releaseConsumerSteps = Object.freeze([
  Object.freeze({ name: 'Test release smoke', command: 'npm run test:release-smoke' }),
  Object.freeze({ name: 'Test release consumers', command: 'npm run test:release-consumers' }),
  Object.freeze({ name: 'Test release container', command: 'npm run test:release-container' }),
  Object.freeze({ name: 'Test release Homebrew', command: 'npm run test:release-homebrew' }),
])

export const documentationContainerCiPolicy = Object.freeze({
  command: 'node docs/scripts/smoke-docs-container.mjs',
  contextPaths: Object.freeze([
    'docs/**',
    'Dockerfile.docs',
    'Dockerfile.docs.dockerignore',
    'PREPROCESSOR-SBOM.spdx.json',
    'THIRD_PARTY_NOTICES.md',
    'adapters/**',
    'api.cjs',
    'api.mjs',
    'api.d.cts',
    'api.d.mts',
    'api.d.ts',
    'index.js',
    'install.js',
    'native-integrity.json',
    'README.md',
    'LICENSE',
    'package.json',
    'package-lock.json',
    'scripts/audit-production-dependencies.mjs',
    '.github/workflows/docs.yml',
  ]),
  dockerfile: 'Dockerfile.docs',
})

export const documentationBuildCiPolicy = Object.freeze({
  installCommand: 'npm ci --ignore-scripts',
  testCommand: 'npm --prefix docs run test:run',
})

export const developmentContainerCiPolicy = Object.freeze({
  command: 'npm run test:dev-container',
  timeoutMinutes: 240,
})

export const buildSystemCiPolicy = Object.freeze({
  command: 'npm run test:build-systems',
  nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  requireAll: '1',
})

export const zigTestSuitePolicy = Object.freeze({
  failureHeadBytes: 3 * 1024,
  modes: Object.freeze({
    Debug: Object.freeze(['build', 'test', '--summary', 'all']),
    ReleaseSafe: Object.freeze(['build', 'test', '-Doptimize=ReleaseSafe', '--summary', 'all']),
  }),
  workflowCommands: Object.freeze({
    Debug: 'node scripts/run-zig-test-suite.mjs --mode Debug',
    ReleaseSafe: 'node scripts/run-zig-test-suite.mjs --mode ReleaseSafe',
  }),
})

export const nativeCorpusCheckoutAttributes = Object.freeze([
  'tests/preprocessors/sass/corpus/cases/**/*.css text eol=lf',
  'tests/preprocessors/sass/corpus/cases/**/*.sass text eol=lf',
  'tests/preprocessors/sass/corpus/cases/**/*.scss text eol=lf',
  'tests/preprocessors/sass/corpus/cases/**/error text eol=lf',
  'tests/preprocessors/sass/corpus/cases/**/warning text eol=lf',
  'tests/preprocessors/less/corpus/files/**/*.css text eol=lf',
  'tests/preprocessors/less/corpus/files/**/*.json text eol=lf',
  'tests/preprocessors/less/corpus/files/**/*.less text eol=lf',
  'tests/preprocessors/less/corpus/files/**/*.txt text eol=lf',
  'tests/preprocessors/stylus/corpus/files/**/*.css text eol=lf',
  'tests/preprocessors/stylus/corpus/files/**/*.json text eol=lf',
  'tests/preprocessors/stylus/corpus/files/**/*.styl text eol=lf',
  'tests/preprocessors/stylus/corpus/files/**/*.svg text eol=lf',
])

function fail(message) {
  throw new Error(`workflow integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function sortedRecord(record) {
  return Object.fromEntries(Object.entries(record).sort(([left], [right]) => left.localeCompare(right)))
}

export function validateActionRuntimeMigration() {
  const node24Actions = []
  const replacedActions = []
  const pendingActions = []
  for (const name of actionRuntimeMigration.terminalActions) {
    const pin = actionPins[name]
    if (pin?.runtime === actionRuntimeMigration.requiredRuntime) {
      node24Actions.push(name)
      continue
    }
    if (actionRuntimeMigration.replacedActions.includes(name) && pin === undefined) {
      replacedActions.push(name)
      continue
    }
    if (actionRuntimeMigration.pendingActions.includes(name) && pin?.runtime === 'node20') {
      pendingActions.push(name)
      continue
    }
    fail(`${name} has unreviewed action runtime ${pin?.runtime ?? 'missing'}`)
  }
  if (!same(replacedActions, actionRuntimeMigration.replacedActions)) {
    fail(`action runtime migration replacement inventory changed: expected ${actionRuntimeMigration.replacedActions.join(', ')}, received ${replacedActions.join(', ')}`)
  }
  if (!same(pendingActions, actionRuntimeMigration.pendingActions)) {
    fail(`action runtime migration pending inventory changed: expected ${actionRuntimeMigration.pendingActions.join(', ')}, received ${pendingActions.join(', ')}`)
  }
  return {
    actions: actionRuntimeMigration.terminalActions.length,
    node24Actions,
    replacedActions,
    pendingActions,
  }
}

export function validateZigTestSuiteRunner() {
  if (failureHeadBytes !== zigTestSuitePolicy.failureHeadBytes) {
    fail(`Zig test suite failure head must remain ${zigTestSuitePolicy.failureHeadBytes} bytes`)
  }
  for (const [mode, expected] of Object.entries(zigTestSuitePolicy.modes)) {
    let actual
    try {
      actual = suiteArguments(mode)
    } catch (error) {
      fail(`Zig test suite mode ${mode} is unavailable: ${error.message}`)
    }
    if (!same(actual, expected)) {
      fail(`Zig test suite mode ${mode} changed: expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
    }
  }
  return {
    failureHeadBytes,
    modes: Object.keys(zigTestSuitePolicy.modes),
  }
}

export function validateNativeCorpusCheckoutAttributes(source) {
  if (source.includes('\r')) fail('.gitattributes must use LF line endings')
  const actual = source
    .split('\n')
    .filter(line => /^tests\/preprocessors\/(?:sass|less|stylus)\/corpus\/.* text eol=lf$/.test(line))
  if (!same(actual, nativeCorpusCheckoutAttributes)) {
    fail(`native corpus checkout attributes changed: expected ${JSON.stringify(nativeCorpusCheckoutAttributes)}, received ${JSON.stringify(actual)}`)
  }
  return {
    patterns: nativeCorpusCheckoutAttributes.length,
    patternsByLanguage: Object.fromEntries(['sass', 'less', 'stylus'].map(language => [
      language,
      nativeCorpusCheckoutAttributes.filter(line => line.startsWith(`tests/preprocessors/${language}/`)).length,
    ])),
  }
}

function splitJobs(source, filename) {
  if (source.includes('\t')) fail(`${filename} contains a tab; security parsing requires spaces`)
  if (/(?:^|\s)(?:&|\*)[A-Za-z0-9_-]+|^\s*<<\s*:/m.test(source)) {
    fail(`${filename} must not use YAML anchors, aliases, or merge keys`)
  }
  const lines = source.split('\n')
  const jobsIndexes = lines.flatMap((line, index) => line === 'jobs:' ? [index] : [])
  if (!same(jobsIndexes, [jobsIndexes[0]]) || jobsIndexes.length !== 1) {
    fail(`${filename} must contain exactly one top-level jobs mapping`)
  }

  const jobsIndex = jobsIndexes[0]
  const permissionLines = lines
    .slice(0, jobsIndex)
    .filter(line => /^permissions\s*:/.test(line))
  if (!same(permissionLines, ['permissions: {}'])) {
    fail(`${filename} must deny all workflow-level token permissions with permissions: {}`)
  }

  const headers = []
  for (let index = jobsIndex + 1; index < lines.length; index += 1) {
    const match = lines[index].match(/^  ([A-Za-z][A-Za-z0-9_-]*):\s*$/)
    if (match !== null) headers.push({ name: match[1], index })
  }
  if (headers.length === 0) fail(`${filename} has no jobs`)

  return new Map(headers.map((header, index) => {
    const end = headers[index + 1]?.index ?? lines.length
    return [header.name, lines.slice(header.index + 1, end)]
  }))
}

function parsePermissions(lines, filename, job) {
  const candidates = lines.flatMap((line, index) => /^\s*permissions\s*:/.test(line) ? [{ line, index }] : [])
  if (candidates.length !== 1 || candidates[0].line !== '    permissions:') {
    fail(`${filename} job ${job} must contain exactly one explicit permission mapping`)
  }

  const permissions = {}
  for (let index = candidates[0].index + 1; index < lines.length; index += 1) {
    const line = lines[index]
    if (line.trim() === '') continue
    const indentation = line.length - line.trimStart().length
    if (indentation <= 4) break
    const match = line.match(/^      ([a-z][a-z-]*): (read|write|none)$/)
    if (match === null) fail(`${filename} job ${job} has a malformed permission entry: ${line.trim()}`)
    if (Object.hasOwn(permissions, match[1])) fail(`${filename} job ${job} repeats permission ${match[1]}`)
    permissions[match[1]] = match[2]
  }
  if (Object.keys(permissions).length === 0) fail(`${filename} job ${job} has an empty permission mapping`)
  return sortedRecord(permissions)
}

function parseActions(lines, filename, job) {
  const actions = []
  for (const line of lines) {
    if (!/^\s+(?:-\s+)?(?:["']?uses["']?)\s*:/.test(line)) continue
    const local = line.match(/^\s+(?:-\s+)?uses: (\.\/\.github\/actions\/[A-Za-z0-9_.-]+)$/)
    if (local !== null) {
      if (local[1] !== setupZigAction) fail(`${filename} job ${job} uses unreviewed local action ${local[1]}`)
      actions.push(local[1])
      continue
    }
    const match = line.match(/^\s+(?:-\s+)?uses: ([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)@([0-9a-f]{40}) # (v[0-9]+(?:\.[0-9]+){0,2})$/)
    if (match === null) {
      fail(`${filename} job ${job} must pin every action to a full lowercase commit SHA with an exact version comment`)
    }
    const [, name, sha, version] = match
    const pin = actionPins[name]
    if (pin === undefined) fail(`${filename} job ${job} uses unreviewed action ${name}`)
    if (sha !== pin.sha || version !== pin.version) {
      fail(`${filename} job ${job} action ${name} must use ${pin.sha} # ${pin.version}`)
    }
    actions.push(name)
  }
  return actions
}

export function validateWorkflowSource(filename, source) {
  const expected = workflowPolicy[filename]
  if (expected === undefined) fail(`unowned workflow ${filename}`)
  const expectedDisplayName = workflowDisplayNames[filename]
  const displayNameLines = source.split('\n').filter(line => /^name:/.test(line))
  if (!same(displayNameLines, [`name: ${expectedDisplayName}`])) {
    fail(`${filename} top-level workflow name must remain exactly ${expectedDisplayName}`)
  }
  const jobs = splitJobs(source, filename)
  const actualNames = [...jobs.keys()].sort()
  const expectedNames = Object.keys(expected).sort()
  if (!same(actualNames, expectedNames)) {
    fail(`${filename} job inventory changed: expected ${expectedNames.join(', ')}, received ${actualNames.join(', ')}`)
  }

  let actionCount = 0
  for (const [job, policy] of Object.entries(expected)) {
    const lines = jobs.get(job)
    const permissions = parsePermissions(lines, filename, job)
    const expectedPermissions = sortedRecord(policy.permissions)
    if (!same(permissions, expectedPermissions)) {
      fail(`${filename} job ${job} permissions changed: expected ${JSON.stringify(expectedPermissions)}, received ${JSON.stringify(permissions)}`)
    }
    const actions = parseActions(lines, filename, job)
    if (!same(actions, policy.actions)) {
      fail(`${filename} job ${job} action inventory changed: expected ${JSON.stringify(policy.actions)}, received ${JSON.stringify(actions)}`)
    }
    actionCount += actions.length
  }
  const lexicalUses = source.split('\n').filter(line => /\buses\s*:/.test(line)).length
  if (lexicalUses !== actionCount) {
    fail(`${filename} contains an indirect or malformed action reference`)
  }
  return { jobs: jobs.size, actions: actionCount }
}

function validateSelfGate(buildWorkflow) {
  const setup = buildWorkflow.indexOf('- name: Setup Node.js')
  const gate = buildWorkflow.indexOf('- name: Verify workflow security policy')
  const command = buildWorkflow.indexOf('npm run test:workflows && npm run check:workflows', gate)
  const install = buildWorkflow.indexOf('- name: Install independent validator')
  if (setup === -1 || gate <= setup || command <= gate || install <= command) {
    fail('build.yml must test and check workflow policy after Node setup and before npm installation')
  }
}

export function validateDocumentationBuildCoverage(buildWorkflow) {
  if (typeof buildWorkflow !== 'string') fail('build.yml source is unavailable')
  const triggerContract = [
    'on:',
    '  push:',
    '    branches: [main, development]',
    '  pull_request:',
    '    branches: [main, development]',
    '  workflow_dispatch:',
  ].join('\n')
  if (buildWorkflow.split(triggerContract).length !== 2) {
    fail('build.yml must run for every main/development push and pull request without path filters')
  }

  const testJob = splitJobs(buildWorkflow, 'build.yml').get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const rootInstallStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  const docsInstallStep = [
    '      - name: Install documentation dependencies',
    '        working-directory: docs',
    `        run: ${documentationBuildCiPolicy.installCommand}`,
  ].join('\n')
  const docsTestStep = [
    '      - name: Test documentation site',
    `        run: ${documentationBuildCiPolicy.testCommand}`,
  ].join('\n')
  const developmentContainerStep = [
    '      - name: Build and smoke-test development container',
    `        run: ${developmentContainerCiPolicy.command}`,
  ].join('\n')
  const exactSequence = [
    docsInstallStep,
    docsTestStep,
    developmentContainerStep,
    '      - name: Install VS Code extension dependencies',
  ].join('\n\n')
  if (
    testJob.split(exactSequence).length !== 2
    || testJob.split(documentationBuildCiPolicy.testCommand).length !== 2
    || testJob.split(developmentContainerCiPolicy.command).length !== 2
    || testJob.indexOf(rootInstallStep) === -1
    || testJob.indexOf(docsInstallStep) <= testJob.indexOf(rootInstallStep)
    || testJob.indexOf(docsTestStep) <= testJob.indexOf(docsInstallStep)
  ) {
    fail('build.yml must install locked documentation dependencies, run the complete docs suite, and live-smoke the development container exactly once')
  }
  return {
    install: documentationBuildCiPolicy.installCommand,
    test: documentationBuildCiPolicy.testCommand,
    triggers: ['push', 'pull_request', 'workflow_dispatch'],
  }
}

export function validateDocumentationWorkflowContract(docsWorkflow, buildWorkflow) {
  if (typeof docsWorkflow !== 'string' || typeof buildWorkflow !== 'string') {
    fail('documentation workflow sources are unavailable')
  }
  const completionTrigger = [
    '  workflow_run:',
    '    workflows: [Build]',
    '    types: [completed]',
    '    branches: [main]',
  ].join('\n')
  if (
    docsWorkflow.split(completionTrigger).length !== 2 ||
    docsWorkflow.split('  workflow_run:').length !== 2 ||
    docsWorkflow.includes('workflow_dispatch:')
  ) {
    fail('docs.yml must receive only the completed main Build workflow as its deployment trigger')
  }
  const exactCheckout = "          ref: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || github.sha }}"
  if (docsWorkflow.split(exactCheckout).length !== 2) {
    fail('docs.yml must check out the exact successful Build commit')
  }
  const sourceIdentity = [
    '    outputs:',
    '      source-sha: ${{ steps.source-identity.outputs.sha }}',
    '    steps:',
    '      - name: Checkout',
  ].join('\n')
  const sourceIdentityStep = [
    '      - name: Verify checked-out source identity',
    '        id: source-identity',
    '        shell: bash',
    '        env:',
    "          EXPECTED_SOURCE_SHA: ${{ github.event_name == 'workflow_run' && github.event.workflow_run.head_sha || github.sha }}",
    '        run: |',
    '          actual_source_sha="$(git rev-parse HEAD)"',
    '          test "$actual_source_sha" = "$EXPECTED_SOURCE_SHA"',
    '          echo "sha=$actual_source_sha" >> "$GITHUB_OUTPUT"',
  ].join('\n')
  if (
    docsWorkflow.split(sourceIdentity).length !== 2
    || docsWorkflow.split(sourceIdentityStep).length !== 2
  ) {
    fail('docs.yml must verify and export the exact checked-out source SHA')
  }
  const deploymentCondition = [
    '    if: >-',
    "      github.event_name == 'workflow_run' &&",
    "      github.event.workflow_run.name == 'Build' &&",
    "      github.event.workflow_run.path == '.github/workflows/build.yml' &&",
    "      github.event.workflow_run.conclusion == 'success' &&",
    "      github.event.workflow_run.event == 'push' &&",
    "      github.event.workflow_run.head_branch == 'main' &&",
    '      github.event.workflow_run.repository.full_name == github.repository &&',
    '      github.event.workflow_run.head_repository.full_name == github.repository &&',
    '      needs.build.outputs.source-sha == github.event.workflow_run.head_sha',
  ].join('\n')
  if (docsWorkflow.split(deploymentCondition).length !== 2) {
    fail('docs.yml deployment must be confined to the exact successful same-repository main Build file and SHA')
  }

  const concurrency = "concurrency:\n  group: pages-${{ github.event_name == 'workflow_run' && github.event.workflow_run.conclusion == 'success' && 'deploy' || format('{0}-{1}', github.event_name, github.ref) }}\n  cancel-in-progress: true\n"
  if (docsWorkflow.split(concurrency).length !== 2) {
    fail('docs.yml must prevent failed Build completions from cancelling a green deployment')
  }

  const auditCommand = 'npm run audit:documentation'
  const auditStep = [
    '      - name: Audit complete documentation build graph',
    `        run: ${auditCommand}`,
    '',
    '      - name: Test documentation',
  ].join('\n')
  const install = docsWorkflow.indexOf('        run: npm ci --ignore-scripts')
  const audit = docsWorkflow.indexOf(`        run: ${auditCommand}`)
  const tests = docsWorkflow.indexOf('        run: npm run test:run')
  const build = docsWorkflow.indexOf('        run: npm run build')
  if (
    docsWorkflow.split(auditStep).length !== 2 ||
    docsWorkflow.split(`        run: ${auditCommand}`).length !== 2 ||
    install === -1 || audit <= install || tests <= audit || build <= tests
  ) {
    fail('docs.yml must audit the complete documentation build graph before testing and building')
  }
  const containerSmokeStep = [
    '      - name: Build and smoke-test documentation container',
    `        run: ${documentationContainerCiPolicy.command}`,
    '',
    '      - name: Upload GitHub Pages artifact',
  ].join('\n')
  const containerSmoke = docsWorkflow.indexOf(`        run: ${documentationContainerCiPolicy.command}`)
  const upload = docsWorkflow.indexOf('      - name: Upload GitHub Pages artifact')
  if (
    docsWorkflow.split(containerSmokeStep).length !== 2 ||
    docsWorkflow.split(documentationContainerCiPolicy.command).length !== 2 ||
    containerSmoke <= build || upload <= containerSmoke
  ) {
    fail('docs.yml must build and live-smoke Dockerfile.docs exactly once after the verified docs build and before Pages upload')
  }
  const documentationPaths = [
    '    paths:',
    ...documentationContainerCiPolicy.contextPaths.map(input => `      - '${input}'`),
  ].join('\n')
  if (docsWorkflow.split(documentationPaths).length !== 3) {
    fail('docs.yml push and pull-request filters must cover the exact documentation container context inputs')
  }
  const aggregateAudit = 'npm run audit:production && npm run audit:development && npm run audit:documentation && npm run audit:vscode && npm run audit:turbopack-example && npm run audit:sveltekit-example && npm run audit:astro-example && npm run audit:nuxt-example'
  if (buildWorkflow.split(aggregateAudit).length !== 2) {
    fail('build.yml must audit root, documentation, VS Code, and framework build graphs in exact order')
  }
  return {
    buildGraphAudits: 2,
    containerSmoke: documentationContainerCiPolicy.command,
    deploymentBranch: 'main',
    trigger: 'workflow_run',
  }
}

export function validateReleaseBuildEvidenceWorkflowContract(releaseWorkflow) {
  if (typeof releaseWorkflow !== 'string') fail('release workflow source is unavailable')
  const npmPreflight = splitJobs(releaseWorkflow, 'release.yml').get('npm-preflight')?.join('\n')
  if (typeof npmPreflight !== 'string') fail('release.yml npm-preflight job is unavailable')
  const evidenceStep = [
    '      - name: Verify successful Build evidence for release commit',
    '        shell: bash',
    '        env:',
    '          GITHUB_TOKEN: ${{ github.token }}',
    '        run: |',
    '          candidate_commit="$(git rev-parse "${GITHUB_SHA}^{commit}")"',
    '          node scripts/verify-build-workflow-run.mjs \\',
    '            --repository "$GITHUB_REPOSITORY" \\',
    '            --commit "$candidate_commit"',
  ].join('\n')
  if (
    npmPreflight.split(evidenceStep).length !== 2
    || npmPreflight.split('node scripts/verify-build-workflow-run.mjs').length !== 2
    || npmPreflight.split('GITHUB_TOKEN: ${{ github.token }}').length !== 2
  ) {
    fail('release.yml npm preflight must verify one exact-SHA successful Build run through the bounded helper')
  }

  const admissionStep = [
    '      - name: Verify release candidate admission',
    '        shell: bash',
    '        run: |',
    '          candidate_commit="$(git rev-parse "${GITHUB_SHA}^{commit}")"',
    '          origin_main_commit="$(',
    '            git ls-remote --exit-code --refs origin refs/heads/main |',
    '              cut -f1',
    '          )"',
    '          node scripts/validate-release-admission.mjs --check \\',
    '            --release-tag "$GITHUB_REF_NAME" \\',
    '            --candidate-commit "$candidate_commit" \\',
    '            --origin-main-commit "$origin_main_commit"',
  ].join('\n')
  if (
    npmPreflight.split(admissionStep).length !== 2
    || npmPreflight.split('node scripts/validate-release-admission.mjs').length !== 2
  ) {
    fail('release.yml npm preflight must run one exact fail-closed candidate admission gate')
  }

  const versionGate = npmPreflight.indexOf('- name: Verify synchronized release version for publication')
  const evidenceGate = npmPreflight.indexOf(evidenceStep)
  const admissionGate = npmPreflight.indexOf(admissionStep)
  const npmAuthority = npmPreflight.indexOf('- name: Verify npm publication authority')
  const npmPack = npmPreflight.indexOf('- name: Pack exact npm package')
  if (
    versionGate < 0
    || evidenceGate <= versionGate
    || admissionGate <= evidenceGate
    || npmAuthority <= admissionGate
    || npmPack <= npmAuthority
  ) {
    fail('release.yml exact-SHA Build evidence must run before every publication authority and packaging check')
  }
  return {
    branch: 'main',
    event: 'push',
    permission: 'actions: read',
    workflow: 'Build',
  }
}

export function validatePublicDeliveryWorkflowContract(releaseWorkflow) {
  if (typeof releaseWorkflow !== 'string') fail('release workflow source is unavailable')
  const jobs = splitJobs(releaseWorkflow, 'release.yml')
  const jobLines = jobs.get(publicDeliveryCiPolicy.job)
  if (jobLines === undefined) fail('release.yml anonymous public delivery job is unavailable')
  if ([...jobs.keys()].at(-1) !== publicDeliveryCiPolicy.job) {
    fail('release.yml anonymous public delivery must remain the final job')
  }
  const job = jobLines.join('\n')
  if (
    /^\s+env:/m.test(job)
    || /\b(?:NODE_AUTH_TOKEN|NPM_AUTH_TOKEN|NPM_TOKEN|YARN_NPM_AUTH_TOKEN)\b/.test(job)
    || /\$\{\{\s*(?:secrets\.|github\.token)/.test(job)
    || /^\s+(?:id-token|packages):/m.test(job)
    || /^\s+registry-url:/m.test(job)
  ) {
    fail('release.yml anonymous public delivery must not receive npm, GitHub, OIDC, or registry credentials')
  }

  const checkoutPin = actionPins['actions/checkout']
  const setupNodePin = actionPins['actions/setup-node']
  const expectedJob = [
    '    name: Verify Anonymous Public Delivery',
    `    needs: ${publicDeliveryCiPolicy.needs}`,
    `    runs-on: ${publicDeliveryCiPolicy.runner}`,
    `    timeout-minutes: ${publicDeliveryCiPolicy.timeoutMinutes}`,
    '    permissions:',
    '      contents: read',
    '    steps:',
    '      - name: Checkout verification source without credentials',
    `        uses: actions/checkout@${checkoutPin.sha} # ${checkoutPin.version}`,
    '        with:',
    '          persist-credentials: false',
    '',
    '      - name: Setup exact Node.js',
    `        uses: actions/setup-node@${setupNodePin.sha} # ${setupNodePin.version}`,
    '        with:',
    `          node-version: '${publicDeliveryCiPolicy.nodeVersion}'`,
    '',
    '      - name: Smoke anonymous canonical npm delivery',
    `        run: ${publicDeliveryCiPolicy.command}`,
  ].join('\n')
  if (
    job.trimEnd() !== expectedJob
    || releaseWorkflow.split(publicDeliveryCiPolicy.command).length !== 2
    || releaseWorkflow.split('node scripts/smoke-public-delivery.mjs').length !== 2
  ) {
    fail('release.yml anonymous public delivery must use the exact bounded credential-free terminal')
  }
  return {
    job: publicDeliveryCiPolicy.job,
    needs: publicDeliveryCiPolicy.needs,
    nodeVersion: publicDeliveryCiPolicy.nodeVersion,
    registry: publicDeliveryCiPolicy.registry,
    runner: publicDeliveryCiPolicy.runner,
    timeoutMinutes: publicDeliveryCiPolicy.timeoutMinutes,
  }
}

export function validatePackageManagerWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const pin = actionPins[packageManagerCiPolicy.action]
  const setupStep = [
    '      - name: Setup Bun for package-manager matrix',
    `        uses: ${packageManagerCiPolicy.action}@${pin.sha} # ${pin.version}`,
    '        with:',
    `          bun-version: '${packageManagerCiPolicy.bunVersion}'`,
  ].join('\n')
  const gateStep = [
    '      - name: Verify package-manager lifecycle recovery',
    `        run: ${packageManagerCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(setupStep).length !== 2) {
    fail('build.yml package-manager matrix must install one exact reviewed Bun release')
  }
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml package-manager recovery gate changed')
  }
  const bunVersionLines = testJob.split('\n').filter(line => /^\s+bun-version:/.test(line))
  if (!same(bunVersionLines, [`          bun-version: '${packageManagerCiPolicy.bunVersion}'`])) {
    fail(`build.yml package-manager matrix must use exact Bun ${packageManagerCiPolicy.bunVersion}`)
  }
  if (testJob.indexOf(setupStep) >= testJob.indexOf(gateStep)) {
    fail('build.yml must setup exact Bun before the package-manager recovery gate')
  }
  return {
    action: `${packageManagerCiPolicy.action}@${pin.sha}`,
    bunVersion: packageManagerCiPolicy.bunVersion,
    gate: packageManagerCiPolicy.gate,
  }
}

export function validateBuildSystemWorkflowContract(buildWorkflow) {
  const testJob = splitJobs(buildWorkflow, 'build.yml').get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify dependency-file build-system integrations',
    '        env:',
    `          ZIGCSS_REAL_BINARY: ${buildSystemCiPolicy.nativeBinary}`,
    `          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '${buildSystemCiPolicy.requireAll}'`,
    `        run: ${buildSystemCiPolicy.command}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml build-system gate must require all four toolchains and the exact current-checkout native binary')
  }
  const requirementLines = testJob.split('\n').filter(line => /ZIGCSS_REQUIRE_BUILD_SYSTEMS:/.test(line))
  if (!same(requirementLines, [`          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '${buildSystemCiPolicy.requireAll}'`])) {
    fail('build.yml build-system mandatory-toolchain environment changed')
  }
  const debug = testJob.indexOf('run: node scripts/run-zig-test-suite.mjs --mode Debug')
  const gate = testJob.indexOf(gateStep)
  if (debug === -1 || gate <= debug) {
    fail('build.yml build-system gate must run after the complete native Debug suite')
  }
  return { ...buildSystemCiPolicy }
}

export function validateNixFlakeWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const buildJob = jobs.get('build')?.join('\n')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof buildJob !== 'string' || typeof testJob !== 'string') {
    fail('build.yml Nix flake jobs are unavailable')
  }

  const pin = actionPins[nixFlakeCiPolicy.action]
  const preflightStep = [
    '      - name: Validate Nix flake contract',
    "        if: runner.os != 'Windows'",
    '        run: node scripts/validate-nix-flake.mjs --check',
  ].join('\n')
  const installStep = [
    '      - name: Install exact Nix',
    "        if: runner.os != 'Windows'",
    `        uses: ${nixFlakeCiPolicy.action}@${pin.sha} # ${pin.version}`,
    '        with:',
    `          install_url: ${nixFlakeCiPolicy.installUrl}`,
    '          enable_kvm: false',
    '          set_as_trusted_user: false',
    '          extra_nix_config: |',
    '            sandbox = true',
  ].join('\n')
  const verificationStep = [
    '      - name: Verify native Nix flake',
    "        if: runner.os != 'Windows'",
    '        shell: bash',
    '        run: |',
    `          test "$(nix --version)" = "nix (Nix) ${nixFlakeCiPolicy.nixVersion}"`,
    '          nix flake check \\',
    '            --no-update-lock-file \\',
    '            --no-write-lock-file \\',
    '            --no-use-registries \\',
    '            .',
    '          nix build \\',
    '            --no-link \\',
    '            --no-update-lock-file \\',
    '            --no-write-lock-file \\',
    '            --no-use-registries \\',
    '            .#default',
    '          actual="$(nix run \\',
    '            --no-update-lock-file \\',
    '            --no-write-lock-file \\',
    '            --no-use-registries \\',
    '            .#default -- --version)"',
    '          test "$actual" = "zigcss $(tr -d \'\\r\\n\' < VERSION)"',
    '          git diff --exit-code -- flake.nix flake.lock',
  ].join('\n')
  const staticGateStep = [
    '      - name: Verify repository-local Nix flake',
    `        run: ${nixFlakeCiPolicy.testScript} && ${nixFlakeCiPolicy.checkScript}`,
  ].join('\n')

  if (buildJob.split(preflightStep).length !== 2) {
    fail('build.yml Nix flake static contract must fail closed before the installer action')
  }
  if (buildJob.split(installStep).length !== 2) {
    fail('build.yml Nix flake install must use one exact immutable action and Nix 2.35.2 policy')
  }
  if (buildJob.split(verificationStep).length !== 2) {
    fail('build.yml Nix flake native verification contract changed')
  }
  if (testJob.split(staticGateStep).length !== 2) {
    fail('build.yml Test Suite must run both exact Nix flake static gates')
  }
  const nativeSequence = [
    preflightStep,
    installStep,
    verificationStep,
    '      - name: Setup Zig',
  ].join('\n\n')
  if (buildJob.split(nativeSequence).length !== 2) {
    fail('build.yml Nix flake steps must be adjacent, closed, and ordered before Zig setup')
  }
  const staticSequence = [
    staticGateStep,
    '      - name: Verify release version policy',
  ].join('\n\n')
  if (testJob.split(staticSequence).length !== 2) {
    fail('build.yml Nix flake static gate must be closed and ordered before release policy')
  }

  const setupNode = buildJob.indexOf('- name: Setup Node.js')
  const preflight = buildJob.indexOf(preflightStep)
  const install = buildJob.indexOf(installStep)
  const verification = buildJob.indexOf(verificationStep)
  const setupZig = buildJob.indexOf('- name: Setup Zig')
  if (
    setupNode < 0
    || preflight <= setupNode
    || install <= preflight
    || verification <= install
    || setupZig <= verification
  ) {
    fail('build.yml must statically validate, install, and verify Nix after Node setup and before Zig setup')
  }
  const testSetupNode = testJob.indexOf('- name: Setup Node.js')
  const staticGate = testJob.indexOf(staticGateStep)
  const dependencyInstall = testJob.indexOf('- name: Install independent validator')
  if (testSetupNode < 0 || staticGate <= testSetupNode || dependencyInstall <= staticGate) {
    fail('build.yml must run both Nix flake static gates after Node setup and before dependency installation')
  }

  return {
    action: `${nixFlakeCiPolicy.action}@${pin.sha}`,
    installUrl: nixFlakeCiPolicy.installUrl,
    nixVersion: nixFlakeCiPolicy.nixVersion,
    staticGate: `${nixFlakeCiPolicy.testScript} && ${nixFlakeCiPolicy.checkScript}`,
  }
}

export function validateTurbopackWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify Next.js Turbopack global SCSS integration',
    '        env:',
    `          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${turbopackCiPolicy.nativeBinary}`,
    `        run: ${turbopackCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml Next.js Turbopack gate must use the exact absolute current-checkout native binary')
  }
  const binaryLines = testJob.split('\n').filter(line => /ZIGCSS_TURBOPACK_NATIVE_BINARY:/.test(line))
  if (!same(binaryLines, [`          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${turbopackCiPolicy.nativeBinary}`])) {
    fail('build.yml Next.js Turbopack native binary environment changed')
  }
  const debugStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const installStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  if (
    testJob.indexOf(debugStep) === -1 ||
    testJob.indexOf(installStep) === -1 ||
    testJob.indexOf(gateStep) <= testJob.indexOf(debugStep) ||
    testJob.indexOf(debugStep) <= testJob.indexOf(installStep)
  ) {
    fail('build.yml Next.js Turbopack gate must run after the native Debug suite and locked host install')
  }
  return {
    gate: turbopackCiPolicy.gate,
    host: turbopackCiPolicy.host,
    nativeBinary: turbopackCiPolicy.nativeBinary,
  }
}

export function validateNextWebpackWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify Next.js Webpack global SCSS integration',
    '        env:',
    `          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${nextWebpackCiPolicy.nativeBinary}`,
    `        run: ${nextWebpackCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml Next.js Webpack gate must use the exact absolute current-checkout native binary')
  }
  const binaryLines = testJob.split('\n').filter(line => /ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY:/.test(line))
  if (!same(binaryLines, [`          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${nextWebpackCiPolicy.nativeBinary}`])) {
    fail('build.yml Next.js Webpack native binary environment changed')
  }
  const nodeVersionLines = testJob.split('\n').filter(line => /^\s+node-version:/.test(line))
  if (!same(nodeVersionLines, [`          node-version: '${nextWebpackCiPolicy.nodeVersion}'`])) {
    fail(`build.yml Next.js Webpack gate must run on exact Node ${nextWebpackCiPolicy.nodeVersion}`)
  }
  const installStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  const debugStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const turbopackStep = [
    '      - name: Verify Next.js Turbopack global SCSS integration',
    '        env:',
    `          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${turbopackCiPolicy.nativeBinary}`,
    `        run: ${turbopackCiPolicy.gate}`,
  ].join('\n')
  const sveltekitStep = [
    '      - name: Verify SvelteKit external CSS Module integration',
    '        env:',
    `          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${sveltekitCiPolicy.nativeBinary}`,
    `        run: ${sveltekitCiPolicy.gate}`,
  ].join('\n')
  const installIndex = testJob.indexOf(installStep)
  const debugIndex = testJob.indexOf(debugStep)
  const turbopackIndex = testJob.indexOf(turbopackStep)
  const gateIndex = testJob.indexOf(gateStep)
  const sveltekitIndex = testJob.indexOf(sveltekitStep)
  if (
    installIndex === -1 ||
    debugIndex <= installIndex ||
    turbopackIndex <= debugIndex ||
    gateIndex <= turbopackIndex ||
    sveltekitIndex <= gateIndex
  ) {
    fail('build.yml Next.js Webpack gate must run after the locked install, native Debug suite, and Turbopack gate, and before SvelteKit')
  }
  return {
    gate: nextWebpackCiPolicy.gate,
    host: nextWebpackCiPolicy.host,
    nativeBinary: nextWebpackCiPolicy.nativeBinary,
    nodeVersion: nextWebpackCiPolicy.nodeVersion,
  }
}

export function validateSveltekitWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify SvelteKit external CSS Module integration',
    '        env:',
    `          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${sveltekitCiPolicy.nativeBinary}`,
    `        run: ${sveltekitCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml SvelteKit gate must use the exact absolute current-checkout native binary')
  }
  const binaryLines = testJob.split('\n').filter(line => /ZIGCSS_SVELTEKIT_NATIVE_BINARY:/.test(line))
  if (!same(binaryLines, [`          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${sveltekitCiPolicy.nativeBinary}`])) {
    fail('build.yml SvelteKit native binary environment changed')
  }
  const debugStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const installStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  if (
    testJob.indexOf(debugStep) === -1 ||
    testJob.indexOf(installStep) === -1 ||
    testJob.indexOf(gateStep) <= testJob.indexOf(debugStep) ||
    testJob.indexOf(debugStep) <= testJob.indexOf(installStep)
  ) {
    fail('build.yml SvelteKit gate must run after the native Debug suite and locked host install')
  }
  return {
    gate: sveltekitCiPolicy.gate,
    host: sveltekitCiPolicy.host,
    nativeBinary: sveltekitCiPolicy.nativeBinary,
  }
}

export function validateAstroWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify Astro external CSS Module integration',
    '        env:',
    `          ZIGCSS_ASTRO_NATIVE_BINARY: ${astroCiPolicy.nativeBinary}`,
    `        run: ${astroCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml Astro gate must use the exact absolute current-checkout native binary')
  }
  const binaryLines = testJob.split('\n').filter(line => /ZIGCSS_ASTRO_NATIVE_BINARY:/.test(line))
  if (!same(binaryLines, [`          ZIGCSS_ASTRO_NATIVE_BINARY: ${astroCiPolicy.nativeBinary}`])) {
    fail('build.yml Astro native binary environment changed')
  }
  const nodeVersionLines = testJob.split('\n').filter(line => /^\s+node-version:/.test(line))
  if (!same(nodeVersionLines, [`          node-version: '${astroCiPolicy.nodeVersion}'`])) {
    fail(`build.yml Astro gate must run on exact Node ${astroCiPolicy.nodeVersion}`)
  }
  const debugStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const installStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  if (
    testJob.indexOf(debugStep) === -1 ||
    testJob.indexOf(installStep) === -1 ||
    testJob.indexOf(gateStep) <= testJob.indexOf(debugStep) ||
    testJob.indexOf(debugStep) <= testJob.indexOf(installStep)
  ) {
    fail('build.yml Astro gate must run after the native Debug suite and locked host install')
  }
  return {
    gate: astroCiPolicy.gate,
    host: astroCiPolicy.host,
    nativeBinary: astroCiPolicy.nativeBinary,
  }
}

export function validateNuxtWorkflowContract(buildWorkflow) {
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const testJob = jobs.get('test')?.join('\n')
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const gateStep = [
    '      - name: Verify Nuxt external CSS Module integration',
    '        env:',
    `          ZIGCSS_NUXT_NATIVE_BINARY: ${nuxtCiPolicy.nativeBinary}`,
    `        run: ${nuxtCiPolicy.gate}`,
  ].join('\n')
  if (testJob.split(gateStep).length !== 2) {
    fail('build.yml Nuxt gate must use the exact absolute current-checkout native binary')
  }
  const binaryLines = testJob.split('\n').filter(line => /ZIGCSS_NUXT_NATIVE_BINARY:/.test(line))
  if (!same(binaryLines, [`          ZIGCSS_NUXT_NATIVE_BINARY: ${nuxtCiPolicy.nativeBinary}`])) {
    fail('build.yml Nuxt native binary environment changed')
  }
  const nodeVersionLines = testJob.split('\n').filter(line => /^\s+node-version:/.test(line))
  if (!same(nodeVersionLines, [`          node-version: '${nuxtCiPolicy.nodeVersion}'`])) {
    fail(`build.yml Nuxt gate must run on exact Node ${nuxtCiPolicy.nodeVersion}`)
  }
  const debugStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const installStep = [
    '      - name: Install independent validator',
    '        run: npm ci --ignore-scripts',
  ].join('\n')
  if (
    testJob.indexOf(debugStep) === -1 ||
    testJob.indexOf(installStep) === -1 ||
    testJob.indexOf(gateStep) <= testJob.indexOf(debugStep) ||
    testJob.indexOf(debugStep) <= testJob.indexOf(installStep)
  ) {
    fail('build.yml Nuxt gate must run after the native Debug suite and locked host install')
  }
  return {
    gate: nuxtCiPolicy.gate,
    host: nuxtCiPolicy.host,
    nativeBinary: nuxtCiPolicy.nativeBinary,
  }
}

const setupZigArtifacts = Object.freeze({
  'aarch64-macos': '50635984:3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b',
  'x86_64-macos': '55800460:375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f',
  'aarch64-linux': '49471996:958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f',
  'x86_64-linux': '53733924:02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239',
  'x86_64-windows': '92614574:3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c',
})

export function validateSetupZigAction(root = repositoryRoot) {
  const directory = path.join(root, '.github', 'actions', 'setup-zig')
  let directoryStat
  try {
    directoryStat = fs.lstatSync(directory)
  } catch (error) {
    fail(`repository-owned Zig setup action is unavailable: ${error.message}`)
  }
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    fail('repository-owned Zig setup action must be a regular non-symlink directory')
  }
  const entries = fs.readdirSync(directory).sort()
  if (!same(entries, ['action.yml', 'setup-zig.mjs'])) {
    fail(`repository-owned Zig setup inventory changed: received ${entries.join(', ')}`)
  }
  for (const entry of entries) {
    const stat = fs.lstatSync(path.join(directory, entry))
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`repository-owned Zig setup ${entry} must be a regular file`)
    if (stat.size > 64 * 1024) fail(`repository-owned Zig setup ${entry} exceeds 64 KiB`)
  }

  const manifest = fs.readFileSync(path.join(directory, 'action.yml'), 'utf8')
  if (manifest.includes('\t') || /(?:^|\s)(?:&|\*)[A-Za-z0-9_-]+|^\s*<<\s*:/m.test(manifest)) {
    fail('repository-owned Zig setup manifest must not use tabs, anchors, aliases, or merge keys')
  }
  const cachePin = actionPins['actions/cache']
  if (cachePin.runtime !== actionRuntimeMigration.requiredRuntime) {
    fail(`actions/cache must use the ${actionRuntimeMigration.requiredRuntime} runtime`)
  }
  const expectedCacheUse = `      uses: actions/cache@${cachePin.sha} # ${cachePin.version}`
  if (manifest.split(expectedCacheUse).length !== 3) {
    fail('repository-owned Zig setup must use exactly two immutable reviewed cache actions')
  }
  const lexicalUses = manifest.split('\n').filter(line => /\buses\s*:/.test(line))
  if (!same(lexicalUses, [expectedCacheUse, expectedCacheUse])) {
    fail('repository-owned Zig setup contains an indirect or unreviewed action reference')
  }
  for (const required of [
    'name: Setup Zig 0.15.2',
    '  using: composite',
    '    required: true',
    'path: ${{ runner.temp }}/zigcss-zig-tool-archive',
    'key: zigcss-zig-archive-v1-${{ runner.os }}-${{ runner.arch }}-${{ inputs.version }}',
    'path: ${{ github.workspace }}/.zig-cache',
    'key: zigcss-zig-build-v1-${{ github.job }}-${{ runner.os }}-${{ runner.arch }}-${{ inputs.version }}-${{ github.run_id }}-${{ github.run_attempt }}',
    '          zigcss-zig-build-v1-${{ github.job }}-${{ runner.os }}-${{ runner.arch }}-${{ inputs.version }}-\n',
    'ZIGCSS_SETUP_VERSION: ${{ inputs.version }}',
    'run: node "${{ github.action_path }}/setup-zig.mjs" --install',
  ]) {
    if (manifest.split(required).length !== 2) fail(`repository-owned Zig setup manifest is missing exact contract ${JSON.stringify(required)}`)
  }
  if (/mlugg\/setup-zig|node20/.test(manifest)) fail('repository-owned Zig setup retains the retired Node 20 action')

  const implementation = fs.readFileSync(path.join(directory, 'setup-zig.mjs'), 'utf8')
  for (const required of [
    'https://ziglang.org/download/${zigVersion}/${filename}',
    "redirect: 'error'",
    'signal: AbortSignal.timeout(downloadTimeoutMilliseconds)',
    'await verifyArchive(destination, artifact)',
    'validateArchiveEntries(entries, artifact.root)',
    'const archiveCommand = resolveArchiveCommand(process.platform)',
    "await requireCommandFile(archiveCommand, 'Windows archive tool')",
    "await runBounded(archiveCommand, ['-tf', archive], maximumArchiveListingBytes)",
    "await runBounded(archiveCommand, ['-xf', archive, '-C', extractionParent], 256 * 1024)",
    'await inspectExtractedTree(toolDirectory)',
    "version.stdout.trim() !== zigVersion || version.stderr.trim() !== ''",
    'const cache = await prepareCache(workspace)',
    'await appendCommand(githubPath, toolDirectory)',
    'await appendCommand(githubEnvironment, `ZIG_GLOBAL_CACHE_DIR=${cache.globalDirectory}`)',
    'await appendCommand(githubEnvironment, `ZIG_LOCAL_CACHE_DIR=${cache.localDirectory}`)',
    "if (process.argv[2] === '--install') await install()",
    'else await pruneCache()',
  ]) {
    if (!implementation.includes(required)) {
      fail(`repository-owned Zig setup implementation is missing integrity contract ${JSON.stringify(required)}`)
    }
  }
  if (/http:\/\/|shell\s*:\s*true|\beval\s*\(|\bexecSync\s*\(/.test(implementation)) {
    fail('repository-owned Zig setup implementation contains an unsafe execution or transport primitive')
  }
  if (/runBounded\('tar'/.test(implementation)) {
    fail('repository-owned Zig setup must not resolve the Windows archive tool through Git Bash PATH')
  }
  if (
    setupZigResolveArchiveCommand('win32', {
      PATH: 'C:\\Program Files\\Git\\usr\\bin;C:\\Windows\\System32',
      SystemRoot: 'C:\\Windows',
    }) !== 'C:\\Windows\\System32\\tar.exe'
  ) {
    fail('repository-owned Zig setup must select the local Windows archive tool independently of PATH')
  }

  const artifacts = Object.fromEntries(setupZigArtifactRecords.map(record => [
    record.target,
    `${record.size}:${record.sha256}`,
  ]))
  if (
    setupZigVersion !== '0.15.2'
    || !same(artifacts, setupZigArtifacts)
    || setupZigMaximumArchiveEntries !== 25_000
    || setupZigMaximumCacheBytes !== 2 * 1024 * 1024 * 1024
  ) {
    fail('repository-owned Zig setup version, host archive, or resource terminal changed')
  }
  return {
    cacheActions: 2,
    cacheRuntime: cachePin.runtime,
    files: entries.length,
    hosts: setupZigArtifactRecords.length,
    maximumArchiveEntries: setupZigMaximumArchiveEntries,
    maximumCacheBytes: setupZigMaximumCacheBytes,
    version: setupZigVersion,
  }
}

export function validateSetupZigWorkflowContract(sources) {
  const placements = [
    { filename: 'benchmarks.yml', job: 'benchmark', version: '0.15.2' },
    { filename: 'build.yml', job: 'build', version: '${{ matrix.zig-version }}' },
    { filename: 'build.yml', job: 'test', version: '0.15.2' },
    { filename: 'release.yml', job: 'release', version: '${{ matrix.zig-version }}' },
  ]
  for (const placement of placements) {
    const job = splitJobs(sources.get(placement.filename), placement.filename).get(placement.job).join('\n')
    const setupBlock = [
      '      - name: Setup Zig',
      `        uses: ${setupZigAction}`,
      '        with:',
      `          version: ${placement.version}`,
    ].join('\n')
    if (job.split(setupBlock).length !== 2) {
      fail(`${placement.filename} job ${placement.job} must use the exact repository-owned Zig ${setupZigVersion} setup`)
    }
    const node = job.indexOf('      - name: Setup Node.js')
    const zig = job.indexOf(setupBlock)
    if (node === -1 || zig <= node) {
      fail(`${placement.filename} job ${placement.job} must provide its pinned Node runtime before repository-owned Zig setup`)
    }
    const pruneBlock = [
      '      - name: Bound Zig cache',
      '        if: always()',
      '        run: node .github/actions/setup-zig/setup-zig.mjs --prune-cache',
    ].join('\n')
    if (job.split(pruneBlock).length !== 2 || !job.trimEnd().endsWith(pruneBlock)) {
      fail(`${placement.filename} job ${placement.job} must bound the Zig cache in its terminal always step`)
    }
  }
  const source = [...sources.values()].join('\n')
  if (source.includes('mlugg/setup-zig')) fail('workflow inventory retains the retired mlugg/setup-zig action')
  if (source.split(`uses: ${setupZigAction}`).length !== placements.length + 1) {
    fail(`workflow inventory must contain exactly ${placements.length} repository-owned Zig setup placements`)
  }
  return { placements: placements.length, pruners: placements.length, version: setupZigVersion }
}

export function validateNativeIntegrityWorkflowContract(sources) {
  const build = sources.get('build.yml')
  const release = sources.get('release.yml')
  if (typeof build !== 'string' || typeof release !== 'string') {
    fail('native integrity workflow sources are unavailable')
  }
  const epochCommand = '          epoch="$(node scripts/validate-native-integrity.mjs --print-source-date-epoch --version "$version")"'
  const epochExport = '          echo "SOURCE_DATE_EPOCH=$epoch" >> "$GITHUB_ENV"'
  if (build.split(epochCommand).length !== 3 || build.split(epochExport).length !== 3) {
    fail('build.yml must validate and reuse exactly two manifest-owned source date epochs')
  }
  if (release.split(epochCommand).length !== 2 || release.split(epochExport).length !== 2) {
    fail('release.yml must validate and reuse exactly one manifest-owned source date epoch')
  }
  if (`${build}\n${release}`.includes('git show -s --format=%ct')) {
    fail('native archives must not derive SOURCE_DATE_EPOCH from a mutable commit timestamp')
  }

  const integrityGate = [
    '      - name: Verify Committed Native Integrity',
    '        shell: bash',
    '        run: |',
    '          node scripts/validate-native-integrity.mjs \\',
    '            --archive "release-assets/$RELEASE_ARCHIVE" \\',
    '            --target "${{ matrix.target }}" \\',
    '            --version "$RELEASE_VERSION"',
  ].join('\n')
  if (release.split(integrityGate).length !== 2) {
    fail('release.yml must verify every tag archive against the committed native integrity manifest')
  }
  if (build.includes('node scripts/validate-native-integrity.mjs \\\n            --archive')) {
    fail('build.yml must not compare unreleased development archives with published release digests')
  }
  if (release.split('node scripts/validate-native-integrity.mjs').length !== 4) {
    fail('release.yml native integrity command inventory changed')
  }
  if (release.split('node scripts/validate-native-integrity.mjs --check').length !== 2) {
    fail('release.yml must validate committed native integrity before packing npm')
  }
  const prepackCheck = release.indexOf('node scripts/validate-native-integrity.mjs --check')
  const npmPack = release.indexOf('npm pack --ignore-scripts --json')
  if (prepackCheck === -1 || npmPack <= prepackCheck) {
    fail('release.yml must validate committed native integrity before packing npm')
  }
  if (build.split('node scripts/validate-native-integrity.mjs').length !== 4) {
    fail('build.yml native integrity command inventory changed')
  }
  if (`${build}\n${release}`.includes('validate-native-integrity.mjs --write')) {
    fail('workflows must never derive committed native integrity trust data from freshly built archives')
  }
  const create = release.indexOf('      - name: Create Archive\n')
  const verify = release.indexOf(integrityGate)
  const metadata = release.indexOf('      - name: Generate SHA-256 Manifest and SPDX SBOM\n')
  if (create === -1 || verify <= create || metadata <= verify) {
    fail('release.yml must verify committed native integrity before generating release metadata')
  }
  const ciGate = 'npm run test:release-metadata && node --test scripts/validate-native-integrity.test.mjs && npm run check:release-metadata && node scripts/validate-native-integrity.mjs --check && npm run test:npm-publication'
  if (build.split(ciGate).length !== 2) {
    fail('build.yml must test and check the native integrity policy exactly once')
  }
  return {
    buildEpochReads: 2,
    releaseArchiveGates: 1,
    releaseEpochReads: 1,
  }
}

function parseJobTimeout(lines, job, filename = 'build.yml') {
  const candidates = lines.filter(line => /^\s*timeout-minutes\s*:/.test(line))
  if (candidates.length !== 1) {
    fail(`${filename} job ${job} must declare exactly one hard timeout`)
  }
  const match = candidates[0].match(/^    timeout-minutes: ([1-9][0-9]*)$/)
  if (match === null) fail(`${filename} job ${job} has a malformed hard timeout`)
  return Number.parseInt(match[1], 10)
}

export function validateTerminalWorkflowTimeouts(sources) {
  const hardTimeoutMinutes = {}
  for (const [filename, jobsPolicy] of Object.entries(terminalWorkflowTimeoutPolicy)) {
    const source = sources.get(filename)
    if (typeof source !== 'string') fail(`${filename} timeout source is unavailable`)
    const jobs = splitJobs(source, filename)
    hardTimeoutMinutes[filename] = {}
    for (const [job, expectedMinutes] of Object.entries(jobsPolicy)) {
      const timeoutMinutes = parseJobTimeout(jobs.get(job), job, filename)
      if (timeoutMinutes !== expectedMinutes) {
        fail(`${filename} job ${job} hard timeout must remain ${expectedMinutes} minutes`)
      }
      hardTimeoutMinutes[filename][job] = timeoutMinutes
    }
  }
  return hardTimeoutMinutes
}

export function validateReleaseConsumerSteps(testJob) {
  if (typeof testJob !== 'string') fail('build.yml Test Suite is unavailable')
  const lines = testJob.split('\n')
  let priorPosition = -1
  for (const step of releaseConsumerSteps) {
    const nameLine = `      - name: ${step.name}`
    const commandLine = `        run: ${step.command}`
    const nameCount = lines.filter(line => line === nameLine).length
    const commandCount = lines.filter(line => line === commandLine).length
    const position = testJob.indexOf(`${nameLine}\n${commandLine}\n\n`)
    if (nameCount !== 1 || commandCount !== 1 || position <= priorPosition) {
      fail('build.yml release consumer gates must remain individually attributable and run exactly once')
    }
    priorPosition = position
  }
  if (testJob.includes('- name: Test release consumer paths')) {
    fail('build.yml release consumer gates must remain individually attributable and run exactly once')
  }
  return releaseConsumerSteps.map(step => step.command)
}

export function validateBuildThroughput(buildWorkflow) {
  const concurrency = 'concurrency:\n  group: build-${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: false\n'
  if (buildWorkflow.split(concurrency).length !== 2) {
    fail('build.yml must use one bounded non-cancelling concurrency group per workflow ref')
  }
  const jobs = splitJobs(buildWorkflow, 'build.yml')
  const hardTimeoutMinutes = {}
  const interventionMinutes = {}
  for (const [job, policy] of Object.entries(buildThroughputPolicy.jobs)) {
    const timeoutMinutes = parseJobTimeout(jobs.get(job), job)
    if (timeoutMinutes !== policy.timeoutMinutes) {
      fail(`build.yml job ${job} hard timeout must remain ${policy.timeoutMinutes} minutes`)
    }
    hardTimeoutMinutes[job] = timeoutMinutes
    interventionMinutes[job] = timeoutMinutes * buildThroughputPolicy.interventionPercent / 100
  }
  const artifactJob = jobs.get('build').join('\n')
  const testJob = jobs.get('test').join('\n')
  const artifactTargets = artifactJob.split('\n').flatMap(line => {
    const match = line.match(/^            target: ([a-z0-9_-]+)$/)
    return match === null ? [] : [match[1]]
  })
  if (
    artifactTargets.length !== buildThroughputPolicy.artifactMatrix.length
    || new Set(artifactTargets).size !== artifactTargets.length
  ) {
    fail(`build.yml artifact matrix must contain exactly ${buildThroughputPolicy.artifactMatrix.length} unique targets`)
  }
  const artifactMatrixExpression = /          - os: ([^\n]+)\n            arch: ([^\n]+)\n            target: ([^\n]+)\n            archive-extension: ([^\n]+)\n            zig-version: ([^\n]+)\n            binary-name: ([^\n]+)/g
  const artifactMatrix = [...artifactJob.matchAll(artifactMatrixExpression)].map(match => ({
    os: match[1],
    arch: match[2],
    target: match[3],
    archiveExtension: match[4],
    zigVersion: match[5],
    binaryName: match[6],
  }))
  if (!same(artifactMatrix, buildThroughputPolicy.artifactMatrix)) {
    fail('build.yml must retain the exact five-target artifact matrix')
  }
  const debugAggregate = `      - name: Run Native Tests\n        run: ${zigTestSuitePolicy.workflowCommands.Debug}`
  const releaseSafeAggregate = `      - name: Run Native Tests\n        run: ${zigTestSuitePolicy.workflowCommands.ReleaseSafe}`
  if (artifactJob.includes(debugAggregate)) {
    fail('build.yml artifact matrix must not run the complete Zig graph in Debug')
  }
  if (artifactJob.split(releaseSafeAggregate).length !== 2) {
    fail('build.yml artifact matrix must run exactly one complete ReleaseSafe Zig graph')
  }
  const optimizedAggregate = `      - name: Run Tests\n        run: ${zigTestSuitePolicy.workflowCommands.ReleaseSafe}`
  if (testJob.includes(optimizedAggregate)) {
    fail('build.yml Test Suite must leave the optimized complete graph to the artifact matrix')
  }
  if (testJob.includes('zig build test-native-preprocessor')) {
    fail('build.yml Test Suite must not run the native suite twice')
  }
  const aggregate = `      - name: Run Tests\n        run: ${zigTestSuitePolicy.workflowCommands.Debug}`
  if (testJob.split(aggregate).length !== 2) {
    fail('build.yml Test Suite must run exactly one complete root Zig test graph')
  }
  const attributedReleaseConsumerSteps = validateReleaseConsumerSteps(testJob)
  return {
    artifactTargets: artifactTargets.length,
    hardTimeoutMinutes,
    interventionMinutes,
    releaseConsumerSteps: attributedReleaseConsumerSteps,
    semanticGraphs: {
      build: 'ReleaseSafe',
      test: 'Debug',
    },
  }
}

export function validateBuildTestGraph(source) {
  const start = source.indexOf('    const test_step = b.step("test", "Run unit tests");')
  const end = source.indexOf('\n\n    const helper_compilation', start)
  if (start === -1 || end === -1) fail('build.zig complete test step is missing or malformed')
  const testGraph = source.slice(start, end)
  for (const runner of nativeTestRunners) {
    const dependency = `    test_step.dependOn(&${runner}.step);`
    if (testGraph.split(dependency).length !== 2) {
      fail(`build.zig complete test graph is missing native runner ${runner}`)
    }
  }
  return { nativeRunners: nativeTestRunners.length }
}

export function validateWorkflowSources(sources) {
  const names = [...sources.keys()].sort()
  const expectedNames = Object.keys(workflowPolicy).sort()
  if (!same(names, expectedNames)) {
    fail(`workflow inventory changed: expected ${JSON.stringify(expectedNames)}, received ${JSON.stringify(names)}`)
  }

  let jobs = 0
  let actions = 0
  for (const filename of expectedNames) {
    const result = validateWorkflowSource(filename, sources.get(filename))
    jobs += result.jobs
    actions += result.actions
  }
  validateActionRuntimeMigration()
  validateSetupZigWorkflowContract(sources)
  validateNativeIntegrityWorkflowContract(sources)
  validateZigTestSuiteRunner()
  validateSelfGate(sources.get('build.yml'))
  validateDocumentationBuildCoverage(sources.get('build.yml'))
  validateDocumentationWorkflowContract(sources.get('docs.yml'), sources.get('build.yml'))
  validateReleaseBuildEvidenceWorkflowContract(sources.get('release.yml'))
  validateTerminalWorkflowTimeouts(sources)
  validatePublicDeliveryWorkflowContract(sources.get('release.yml'))
  validateNixFlakeWorkflowContract(sources.get('build.yml'))
  validatePackageManagerWorkflowContract(sources.get('build.yml'))
  validateBuildSystemWorkflowContract(sources.get('build.yml'))
  validateTurbopackWorkflowContract(sources.get('build.yml'))
  validateSveltekitWorkflowContract(sources.get('build.yml'))
  validateAstroWorkflowContract(sources.get('build.yml'))
  validateNuxtWorkflowContract(sources.get('build.yml'))
  validateNextWebpackWorkflowContract(sources.get('build.yml'))
  validateBuildThroughput(sources.get('build.yml'))
  return { workflows: names.length, jobs, actions }
}

export function readWorkflowSources(root = repositoryRoot) {
  const directory = path.join(root, '.github', 'workflows')
  const entries = fs.readdirSync(directory, { withFileTypes: true })
  const workflowEntries = entries.filter(entry => /\.ya?ml$/.test(entry.name))
  for (const entry of workflowEntries) {
    if (!entry.isFile()) fail(`${entry.name} must be a regular workflow file`)
  }
  return new Map(workflowEntries
    .sort((left, right) => left.name.localeCompare(right.name))
    .map(entry => [entry.name, fs.readFileSync(path.join(directory, entry.name), 'utf8')]))
}

export function validateWorkflows(root = repositoryRoot) {
  const result = validateWorkflowSources(readWorkflowSources(root))
  validateSetupZigAction(root)
  validateBuildTestGraph(fs.readFileSync(path.join(root, 'build.zig'), 'utf8'))
  validateNativeCorpusCheckoutAttributes(fs.readFileSync(path.join(root, '.gitattributes'), 'utf8'))
  return result
}

function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--check') {
    throw new Error('usage: node scripts/validate-workflows.mjs --check')
  }
  const result = validateWorkflows()
  process.stdout.write(`Workflow security verified: ${result.workflows} workflows, ${result.jobs} least-privilege jobs, ${result.actions} immutable action references.\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
