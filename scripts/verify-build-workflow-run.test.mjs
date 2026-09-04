import assert from 'node:assert/strict'
import test from 'node:test'
import {
  buildWorkflowEvidencePolicy,
  buildWorkflowRunsUrl,
  validateBuildWorkflowRunsResponse,
  verifyBuildWorkflowRun,
} from './verify-build-workflow-run.mjs'

const repository = 'vyakymenko/zigcss'
const commit = 'a956145a92a0461d5baca07bb132e7c3ff9185ba'
const token = 'github-test-token'

function run(overrides = {}) {
  return {
    id: 456789,
    run_attempt: 2,
    name: 'Build',
    path: '.github/workflows/build.yml',
    event: 'push',
    head_branch: 'main',
    head_sha: commit,
    status: 'completed',
    conclusion: 'success',
    repository: { full_name: repository },
    head_repository: { full_name: repository },
    ...overrides,
  }
}

function response(workflowRuns, overrides = {}) {
  const body = JSON.stringify({ total_count: workflowRuns.length, workflow_runs: workflowRuns })
  return new Response(overrides.body ?? body, {
    status: overrides.status ?? 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      ...overrides.headers,
    },
  })
}

test('requests the exact bounded GitHub Actions API surface and accepts exact successful Build evidence', async () => {
  assert.deepEqual(buildWorkflowEvidencePolicy, {
    apiOrigin: 'https://api.github.com',
    apiVersion: '2022-11-28',
    branch: 'main',
    event: 'push',
    maximumResponseBytes: 1024 * 1024,
    maximumRuns: 100,
    timeoutMilliseconds: 15_000,
    workflowFile: 'build.yml',
    workflowName: 'Build',
    workflowPath: '.github/workflows/build.yml',
  })
  const expectedUrl = `https://api.github.com/repos/vyakymenko/zigcss/actions/workflows/build.yml/runs?branch=main&event=push&head_sha=${commit}&status=completed&per_page=100`
  assert.equal(buildWorkflowRunsUrl(repository, commit), expectedUrl)

  const signal = new AbortController().signal
  let request
  const result = await verifyBuildWorkflowRun({ repository, commit, token }, {
    signal,
    fetchImpl: async (url, options) => {
      request = { url, options }
      return response([run()])
    },
  })
  assert.deepEqual(request, {
    url: expectedUrl,
    options: {
      method: 'GET',
      redirect: 'error',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'zigcss-release-build-evidence/1',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      signal,
    },
  })
  assert.deepEqual(result, {
    commit,
    repository,
    runAttempt: 2,
    runId: 456789,
    workflow: 'Build',
  })
})

test('missing, failing, and wrong-SHA Build evidence fail closed', () => {
  assert.throws(
    () => validateBuildWorkflowRunsResponse({ total_count: 0, workflow_runs: [] }, repository, commit),
    /no successful Build run exists/,
  )
  assert.throws(
    () => validateBuildWorkflowRunsResponse({
      total_count: 1,
      workflow_runs: [run({ conclusion: 'failure' })],
    }, repository, commit),
    /no successful Build run exists/,
  )
  assert.throws(
    () => validateBuildWorkflowRunsResponse({
      total_count: 1,
      workflow_runs: [run({ head_sha: 'b'.repeat(40) })],
    }, repository, commit),
    /no successful Build run exists/,
  )
})

test('evidence must be the exact same-repository main push Build workflow terminal', () => {
  for (const mutation of [
    { name: 'Documentation' },
    { path: '.github/workflows/docs.yml' },
    { event: 'workflow_dispatch' },
    { head_branch: 'development' },
    { status: 'in_progress' },
    { conclusion: null },
    { repository: { full_name: 'attacker/zigcss' } },
    { head_repository: { full_name: 'attacker/zigcss' } },
    { run_attempt: 0 },
    { id: Number.MAX_SAFE_INTEGER + 1 },
  ]) {
    assert.throws(
      () => validateBuildWorkflowRunsResponse({ total_count: 1, workflow_runs: [run(mutation)] }, repository, commit),
      /no successful Build run exists/,
    )
  }
})

test('multiple exact successful runs select the newest run id deterministically', () => {
  assert.deepEqual(
    validateBuildWorkflowRunsResponse({
      total_count: 3,
      workflow_runs: [run({ id: 7 }), run({ id: 11, run_attempt: 1 }), run({ id: 9 })],
    }, repository, commit),
    {
      commit,
      repository,
      runAttempt: 1,
      runId: 11,
      workflow: 'Build',
    },
  )
})

test('request identity, authorization, transport, JSON, and response bounds fail closed', async () => {
  for (const input of [
    { repository: '../zigcss', commit, token },
    { repository, commit: commit.toUpperCase(), token },
    { repository, commit, token: '' },
    { repository, commit, token: 'line\nbreak' },
  ]) {
    await assert.rejects(() => verifyBuildWorkflowRun(input, { fetchImpl: async () => response([run()]) }), /release Build evidence:/)
  }

  await assert.rejects(
    () => verifyBuildWorkflowRun({ repository, commit, token }, { fetchImpl: async () => response([], { status: 403 }) }),
    /HTTP 403/,
  )
  await assert.rejects(
    () => verifyBuildWorkflowRun({ repository, commit, token }, {
      fetchImpl: async () => { throw new Error('offline') },
    }),
    /request failed: offline/,
  )
  await assert.rejects(
    () => verifyBuildWorkflowRun({ repository, commit, token }, {
      fetchImpl: async () => response([], { body: '{' }),
    }),
    /not JSON/,
  )
  await assert.rejects(
    () => verifyBuildWorkflowRun({ repository, commit, token }, {
      fetchImpl: async () => response([], { headers: { 'content-type': 'text/html' } }),
    }),
    /JSON content type/,
  )
  await assert.rejects(
    () => verifyBuildWorkflowRun({ repository, commit, token }, {
      fetchImpl: async () => response([], { body: ' '.repeat(buildWorkflowEvidencePolicy.maximumResponseBytes + 1) }),
    }),
    /exceeds 1048576 bytes/,
  )
  assert.throws(
    () => validateBuildWorkflowRunsResponse({ total_count: 101, workflow_runs: Array.from({ length: 101 }, run) }, repository, commit),
    /bounded workflow run inventory/,
  )
})
