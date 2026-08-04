import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

// Each commit was resolved from the named tag in the action's official repository.
// Dependabot owns reviewed updates to these immutable references.
export const actionPins = Object.freeze({
  'actions/checkout': Object.freeze({
    sha: '34e114876b0b11c390a56381ad16ebd13914f8d5',
    version: 'v4.3.1',
  }),
  'mlugg/setup-zig': Object.freeze({
    sha: 'd1434d08867e3ee9daa34448df10607b98908d29',
    version: 'v2.2.1',
  }),
  'actions/upload-artifact': Object.freeze({
    sha: 'ea165f8d65b6e75b540449e92b4886f43607fa02',
    version: 'v4.6.2',
  }),
  'actions/setup-node': Object.freeze({
    sha: '49933ea5288caeca8642d1e84afbd3f7d6820020',
    version: 'v4.4.0',
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

export const workflowPolicy = Object.freeze({
  'benchmarks.yml': Object.freeze({
    benchmark: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze([
        'actions/checkout',
        'mlugg/setup-zig',
        'actions/setup-node',
        'actions/upload-artifact',
      ]),
    }),
  }),
  'build.yml': Object.freeze({
    build: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'mlugg/setup-zig', 'actions/setup-node', 'actions/upload-artifact']),
    }),
    test: Object.freeze({
      permissions: Object.freeze({ contents: 'read' }),
      actions: Object.freeze(['actions/checkout', 'mlugg/setup-zig', 'actions/setup-node']),
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
        'mlugg/setup-zig',
        'actions/setup-node',
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
  'run_native_less_evaluator_tests',
  'run_native_less_conformance_tests',
  'run_native_sass_arguments_tests',
  'run_native_sass_numeric_tests',
  'run_native_sass_color_tests',
  'run_native_sass_string_tests',
  'run_native_sass_selector_tests',
  'run_native_sass_evaluator_tests',
  'run_native_sass_conformance_tests',
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

function validateBuildThroughput(buildWorkflow) {
  const concurrency = 'concurrency:\n  group: build-${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: false\n'
  if (buildWorkflow.split(concurrency).length !== 2) {
    fail('build.yml must use one bounded non-cancelling concurrency group per workflow ref')
  }
  const testJob = splitJobs(buildWorkflow, 'build.yml').get('test').join('\n')
  if (testJob.includes('zig build test-native-preprocessor')) {
    fail('build.yml Test Suite must not run the native suite twice')
  }
  const aggregate = '      - name: Run Tests\n        run: zig build test --summary all'
  if (testJob.split(aggregate).length !== 2) {
    fail('build.yml Test Suite must run exactly one complete root Zig test graph')
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
  validateBuildTestGraph(fs.readFileSync(path.join(root, 'build.zig'), 'utf8'))
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
