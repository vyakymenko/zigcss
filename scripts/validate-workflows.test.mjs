import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  actionPins,
  buildThroughputPolicy,
  readWorkflowSources,
  validateActionRuntimeMigration,
  validateBuildThroughput,
  validateBuildTestGraph,
  validateSetupZigAction,
  validateSetupZigWorkflowContract,
  validateWorkflowSources,
  validateWorkflows,
  validateZigTestSuiteRunner,
} from './validate-workflows.mjs'

function cloneSources() {
  return new Map(readWorkflowSources())
}

test('all workflow jobs use explicit least privilege and immutable reviewed actions', () => {
  assert.deepEqual(validateWorkflows(), { workflows: 4, jobs: 10, actions: 32 })
  assert.deepEqual(validateZigTestSuiteRunner(), {
    failureTailBytes: 16 * 1024,
    modes: ['Debug', 'ReleaseSafe'],
  })
})

test('the hosted action runtime migration has a finite reviewed terminal', () => {
  assert.deepEqual(validateActionRuntimeMigration(), {
    actions: 3,
    node24Actions: ['actions/checkout', 'actions/setup-node'],
    replacedActions: ['mlugg/setup-zig'],
    pendingActions: [],
  })
})

test('all four Zig setup placements use the repository-owned terminal and retain bounded cache cleanup', t => {
  const sources = cloneSources()
  const workflowText = [...sources.values()].join('\n')
  assert.equal(workflowText.split('uses: ./.github/actions/setup-zig').length - 1, 4)
  assert.equal(
    workflowText.split('node .github/actions/setup-zig/setup-zig.mjs --prune-cache').length - 1,
    4,
  )
  assert.doesNotMatch(workflowText, /mlugg\/setup-zig/)
  assert.deepEqual(validateSetupZigWorkflowContract(sources), {
    placements: 4,
    pruners: 4,
    version: '0.15.2',
  })
  assert.deepEqual(validateSetupZigAction(), {
    cacheActions: 2,
    cacheRuntime: 'node24',
    files: 2,
    hosts: 5,
    maximumArchiveEntries: 25_000,
    maximumCacheBytes: 2 * 1024 * 1024 * 1024,
    version: '0.15.2',
  })

  const stale = cloneSources()
  stale.set('build.yml', stale.get('build.yml').replace(
    'uses: ./.github/actions/setup-zig',
    'uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1',
  ))
  assert.throws(() => validateWorkflowSources(stale), /unreviewed action|action inventory|repository-owned Zig/)

  const unbounded = cloneSources()
  unbounded.set('release.yml', unbounded.get('release.yml').replace(
    '      - name: Bound Zig cache\n        if: always()\n        run: node .github/actions/setup-zig/setup-zig.mjs --prune-cache\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(unbounded), /terminal always step/)

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-workflow-policy-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const actionDirectory = path.join(temporary, '.github', 'actions', 'setup-zig')
  fs.mkdirSync(actionDirectory, { recursive: true })
  for (const filename of ['action.yml', 'setup-zig.mjs']) {
    fs.copyFileSync(path.join('.github', 'actions', 'setup-zig', filename), path.join(actionDirectory, filename))
  }
  const actionManifest = path.join(actionDirectory, 'action.yml')
  fs.writeFileSync(actionManifest, fs.readFileSync(actionManifest, 'utf8').replace(
    actionPins['actions/cache'].sha,
    '0000000000000000000000000000000000000000',
  ))
  assert.throws(() => validateSetupZigAction(temporary), /exactly two immutable reviewed cache actions/)

  fs.copyFileSync(path.join('.github', 'actions', 'setup-zig', 'action.yml'), actionManifest)
  const actionImplementation = path.join(actionDirectory, 'setup-zig.mjs')
  fs.writeFileSync(actionImplementation, fs.readFileSync(actionImplementation, 'utf8').replace(
    "redirect: 'error'",
    "redirect: 'follow'",
  ))
  assert.throws(() => validateSetupZigAction(temporary), /missing integrity contract/)
})

test('mutable, malformed, unknown, and stale action references fail closed', () => {
  const mutable = cloneSources()
  mutable.set('build.yml', mutable.get('build.yml').replace(
    `@${actionPins['actions/checkout'].sha} # ${actionPins['actions/checkout'].version}`,
    '@v4',
  ))
  assert.throws(() => validateWorkflowSources(mutable), /full lowercase commit SHA/)

  const stale = cloneSources()
  stale.set('build.yml', stale.get('build.yml').replace(
    actionPins['actions/checkout'].sha,
    '0000000000000000000000000000000000000000',
  ))
  assert.throws(() => validateWorkflowSources(stale), /action actions\/checkout must use/)

  const unknown = cloneSources()
  unknown.set('build.yml', unknown.get('build.yml').replace(
    'actions/checkout',
    'unknown/checkout',
  ))
  assert.throws(() => validateWorkflowSources(unknown), /unreviewed action unknown\/checkout/)

  const anchored = cloneSources()
  anchored.set('build.yml', anchored.get('build.yml').replace(
    'uses: actions/checkout@',
    'uses: &checkout actions/checkout@',
  ))
  assert.throws(() => validateWorkflowSources(anchored), /must not use YAML anchors/)
})

test('workflow and job permission expansion fails closed', () => {
  const inherited = cloneSources()
  inherited.set('docs.yml', inherited.get('docs.yml').replace('permissions: {}', 'permissions:\n  contents: read'))
  assert.throws(() => validateWorkflowSources(inherited), /deny all workflow-level token permissions/)

  const expanded = cloneSources()
  expanded.set('release.yml', expanded.get('release.yml').replace(
    '    permissions:\n      attestations: write\n      contents: read\n      id-token: write',
    '    permissions:\n      attestations: write\n      contents: write\n      id-token: write',
  ))
  assert.throws(() => validateWorkflowSources(expanded), /job release permissions changed/)

  const packages = cloneSources()
  packages.set('release.yml', packages.get('release.yml').replace(
    '      id-token: write',
    '      id-token: write\n      packages: write',
  ))
  assert.throws(() => validateWorkflowSources(packages), /job release permissions changed/)
})

test('new workflows, jobs, and action placements require an explicit policy update', () => {
  const workflow = cloneSources()
  workflow.set('unreviewed.yml', 'name: Unreviewed\n')
  assert.throws(() => validateWorkflowSources(workflow), /workflow inventory changed/)

  const job = cloneSources()
  job.set('build.yml', `${job.get('build.yml')}\n  unexpected:\n    permissions:\n      contents: read\n`)
  assert.throws(() => validateWorkflowSources(job), /job inventory changed/)

  const placement = cloneSources()
  placement.set('docs.yml', placement.get('docs.yml').replace(
    'actions/upload-pages-artifact',
    'actions/upload-artifact',
  ).replace(
    actionPins['actions/upload-pages-artifact'].sha,
    actionPins['actions/upload-artifact'].sha,
  ).replace(
    actionPins['actions/upload-pages-artifact'].version,
    actionPins['actions/upload-artifact'].version,
  ))
  assert.throws(() => validateWorkflowSources(placement), /action inventory changed/)
})

test('the workflow security gate runs before dependency installation', () => {
  const sources = cloneSources()
  sources.set('build.yml', sources.get('build.yml').replace('- name: Verify workflow security policy', '- name: Removed gate'))
  assert.throws(() => validateWorkflowSources(sources), /before npm installation/)
})

test('the build workflow preserves one complete aggregate suite within a bounded queue', () => {
  const sources = cloneSources()
  assert.deepEqual(validateWorkflowSources(sources), { workflows: 4, jobs: 10, actions: 32 })

  const unconstrained = cloneSources()
  unconstrained.set('build.yml', unconstrained.get('build.yml').replace(
    'concurrency:\n  group: build-${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: false\n\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(unconstrained), /bounded non-cancelling concurrency/)

  const duplicated = cloneSources()
  duplicated.set('build.yml', duplicated.get('build.yml').replace(
    '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
    '      - name: Verify native stylesheet frontend foundations\n        run: zig build test-native-preprocessor --summary all\n\n      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ))
  assert.throws(() => validateWorkflowSources(duplicated), /must not run the native suite twice/)

  const unoptimizedMatrix = cloneSources()
  unoptimizedMatrix.set('build.yml', unoptimizedMatrix.get('build.yml').replace(
    '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe',
    '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ))
  assert.throws(() => validateWorkflowSources(unoptimizedMatrix), /must not run the complete Zig graph in Debug/)
})

test('required build jobs declare finite hard timeout budgets', () => {
  const workflow = cloneSources().get('build.yml')
  assert.deepEqual(validateBuildThroughput(workflow), {
    artifactTargets: 5,
    hardTimeoutMinutes: {
      build: 240,
      'native-package-evidence': 60,
      test: 240,
    },
    interventionMinutes: {
      build: 180,
      'native-package-evidence': 45,
      test: 180,
    },
    semanticGraphs: {
      build: 'ReleaseSafe',
      test: 'Debug',
    },
  })

  const jobs = Object.keys(buildThroughputPolicy.jobs)
  for (const [index, job] of jobs.entries()) {
    const nextJob = jobs[index + 1]
    const timeoutMinutes = buildThroughputPolicy.jobs[job].timeoutMinutes
    const start = workflow.indexOf(`  ${job}:\n`)
    const end = nextJob === undefined ? workflow.length : workflow.indexOf(`\n  ${nextJob}:\n`, start)
    assert.notEqual(start, -1)
    assert.notEqual(end, -1)
    assert.match(
      workflow.slice(start, end),
      new RegExp(`^    timeout-minutes: ${timeoutMinutes}$`, 'm'),
      `${job} must declare its ${timeoutMinutes}-minute hard timeout`,
    )

    const jobSource = workflow.slice(start, end)
    const timeout = `    timeout-minutes: ${timeoutMinutes}\n`
    const missing = cloneSources()
    missing.set('build.yml', workflow.slice(0, start) + jobSource.replace(timeout, '') + workflow.slice(end))
    assert.throws(() => validateWorkflowSources(missing), new RegExp(`job ${job}.*hard timeout`))

    const malformed = cloneSources()
    malformed.set(
      'build.yml',
      workflow.slice(0, start)
        + jobSource.replace(timeout, `    timeout-minutes: ${timeoutMinutes}.5\n`)
        + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(malformed), new RegExp(`job ${job}.*hard timeout`))

    const drifted = cloneSources()
    drifted.set(
      'build.yml',
      workflow.slice(0, start)
        + jobSource.replace(timeout, `    timeout-minutes: ${timeoutMinutes + 1}\n`)
        + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(drifted), new RegExp(`job ${job}.*hard timeout`))

    const duplicated = cloneSources()
    duplicated.set(
      'build.yml',
      workflow.slice(0, start) + jobSource.replace(timeout, timeout + timeout) + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(duplicated), new RegExp(`job ${job}.*hard timeout`))
  }

  const lowerTargets = cloneSources()
  lowerTargets.set('build.yml', workflow.replace('            target: x86_64-linux\n', ''))
  assert.throws(() => validateWorkflowSources(lowerTargets), /exactly 5 unique targets/)

  const duplicateTarget = cloneSources()
  duplicateTarget.set('build.yml', workflow.replace('            target: aarch64-linux', '            target: x86_64-linux'))
  assert.throws(() => validateWorkflowSources(duplicateTarget), /exactly 5 unique targets/)
})

test('the artifact matrix uses the optimized complete suite while the test job owns Debug', () => {
  const buildWorkflow = cloneSources().get('build.yml')
  const artifactJob = buildWorkflow.slice(
    buildWorkflow.indexOf('  build:'),
    buildWorkflow.indexOf('  native-package-evidence:'),
  )
  const testJob = buildWorkflow.slice(buildWorkflow.indexOf('  test:'))
  const debugArtifactSuite = '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug'
  const optimizedArtifactSuite = '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe'
  const debugAggregate = '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug'
  const optimizedAggregate = '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe'
  assert.equal(artifactJob.includes(debugArtifactSuite), false)
  assert.equal(artifactJob.split(optimizedArtifactSuite).length, 2)
  assert.equal(testJob.split(debugAggregate).length, 2)
  assert.equal(testJob.includes(optimizedAggregate), false)
})

test('the complete Zig test graph owns every native frontend runner', () => {
  const source = fs.readFileSync(new URL('../build.zig', import.meta.url), 'utf8')
  assert.deepEqual(validateBuildTestGraph(source), { nativeRunners: 19 })
  const weakened = source.replace(
    '    test_step.dependOn(&run_native_sass_evaluator_tests.step);',
    '    // removed native Sass evaluator coverage',
  )
  assert.throws(() => validateBuildTestGraph(weakened), /missing native runner run_native_sass_evaluator_tests/)
  const missingConformance = source.replace(
    '    test_step.dependOn(&run_native_sass_conformance_tests.step);',
    '    // removed native Sass conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingConformance),
    /missing native runner run_native_sass_conformance_tests/,
  )
  const missingLessConformance = source.replace(
    '    test_step.dependOn(&run_native_less_conformance_tests.step);',
    '    // removed native Less conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingLessConformance),
    /missing native runner run_native_less_conformance_tests/,
  )
  const missingStylusParser = source.replace(
    '    test_step.dependOn(&run_native_stylus_parser_tests.step);',
    '    // removed native Stylus parser coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusParser),
    /missing native runner run_native_stylus_parser_tests/,
  )
  const missingStylusEvaluator = source.replace(
    '    test_step.dependOn(&run_native_stylus_evaluator_tests.step);',
    '    // removed native Stylus evaluator coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusEvaluator),
    /missing native runner run_native_stylus_evaluator_tests/,
  )
  const missingStylusConformance = source.replace(
    '    test_step.dependOn(&run_native_stylus_conformance_tests.step);',
    '    // removed native Stylus conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusConformance),
    /missing native runner run_native_stylus_conformance_tests/,
  )
  const missingNativeCli = source.replace(
    '    test_step.dependOn(&run_native_cli_tests.step);',
    '    // removed native binary CLI coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingNativeCli),
    /missing native runner run_native_cli_tests/,
  )
})
