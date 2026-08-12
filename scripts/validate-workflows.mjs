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
    sha: 'ea165f8d65b6e75b540449e92b4886f43607fa02',
    version: 'v4.6.2',
  }),
  'actions/setup-node': Object.freeze({
    sha: '820762786026740c76f36085b0efc47a31fe5020',
    version: 'v7.0.0',
    runtime: 'node24',
  }),
  'actions/upload-pages-artifact': Object.freeze({
    sha: '7b1f4a764d45c48632c6b24a0339c27f5614fb0b',
    version: 'v4.0.0',
  }),
  'actions/deploy-pages': Object.freeze({
    sha: 'd6db90164ac5ed86f2b6aed7e0febac5b3c0c03e',
    version: 'v4.0.5',
  }),
  'actions/download-artifact': Object.freeze({
    sha: 'd3f86a106a0bac45b974a628896c90dbdf5c8093',
    version: 'v4.3.0',
  }),
  'actions/attest': Object.freeze({
    sha: 'a1948c3f048ba23858d222213b7c278aabede763',
    version: 'v4.1.1',
  }),
  'softprops/action-gh-release': Object.freeze({
    sha: 'de2c0eb89ae2a093876385947365aca7b0e5f844',
    version: 'v1',
  }),
})

// Public Build annotations define this exact finite migration inventory. The
// two official workflow actions have tagged Node 24 releases. The sole tagged
// setup-zig remainder is retired in favor of the repository-owned composite.
export const actionRuntimeMigration = Object.freeze({
  requiredRuntime: 'node24',
  terminalActions: Object.freeze([
    'actions/checkout',
    'actions/setup-node',
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
      actions: Object.freeze(['actions/checkout', 'actions/setup-node', setupZigAction, 'actions/upload-artifact']),
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
      actions: Object.freeze(['actions/checkout', 'actions/setup-node', setupZigAction]),
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
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'actions/setup-node']),
    }),
    release: Object.freeze({
      permissions: Object.freeze({ attestations: 'write', contents: 'read', 'id-token': 'write' }),
      actions: Object.freeze([
        'actions/checkout',
        'actions/setup-node',
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
      actions: Object.freeze(['actions/checkout', 'actions/setup-node']),
    }),
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
    'native-package-evidence': Object.freeze({ timeoutMinutes: 60 }),
    test: Object.freeze({ timeoutMinutes: 240 }),
  }),
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

export const stylusCorpusCheckoutAttributes = Object.freeze([
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

export function validateStylusCorpusCheckoutAttributes(source) {
  if (source.includes('\r')) fail('.gitattributes must use LF line endings')
  const actual = source
    .split('\n')
    .filter(line => line.startsWith('tests/preprocessors/stylus/corpus/files/'))
  if (!same(actual, stylusCorpusCheckoutAttributes)) {
    fail(`Stylus corpus checkout attributes changed: expected ${JSON.stringify(stylusCorpusCheckoutAttributes)}, received ${JSON.stringify(actual)}`)
  }
  return {
    patterns: stylusCorpusCheckoutAttributes.length,
    extensions: stylusCorpusCheckoutAttributes.map(line => line.match(/\.([a-z]+) text eol=lf$/)[1]),
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

function parseJobTimeout(lines, job) {
  const candidates = lines.filter(line => /^\s*timeout-minutes\s*:/.test(line))
  if (candidates.length !== 1) {
    fail(`build.yml job ${job} must declare exactly one hard timeout`)
  }
  const match = candidates[0].match(/^    timeout-minutes: ([1-9][0-9]*)$/)
  if (match === null) fail(`build.yml job ${job} has a malformed hard timeout`)
  return Number.parseInt(match[1], 10)
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
  return {
    artifactTargets: artifactTargets.length,
    hardTimeoutMinutes,
    interventionMinutes,
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
  validateZigTestSuiteRunner()
  validateSelfGate(sources.get('build.yml'))
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
  validateStylusCorpusCheckoutAttributes(fs.readFileSync(path.join(root, '.gitattributes'), 'utf8'))
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
