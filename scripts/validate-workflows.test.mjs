import assert from 'node:assert/strict'
import test from 'node:test'
import {
  actionPins,
  readWorkflowSources,
  validateWorkflowSources,
  validateWorkflows,
} from './validate-workflows.mjs'

function cloneSources() {
  return new Map(readWorkflowSources())
}

test('all workflow jobs use explicit least privilege and immutable reviewed actions', () => {
  assert.deepEqual(validateWorkflows(), { workflows: 4, jobs: 8, actions: 26 })
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
