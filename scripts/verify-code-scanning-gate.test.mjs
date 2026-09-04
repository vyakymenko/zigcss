import assert from 'node:assert/strict'
import test from 'node:test'
import {
  codeScanningAnalysesUrl,
  codeScanningGatePolicy,
  codeScanningOpenAlertsUrl,
  validateCodeScanningAnalysesResponse,
  validateCodeScanningOpenAlertsResponse,
  verifyCodeScanningGate,
} from './verify-code-scanning-gate.mjs'

const repository = 'vyakymenko/zigcss'
const commit = 'a956145a92a0461d5baca07bb132e7c3ff9185ba'
const token = 'github-test-token'

function analysis(category, id, overrides = {}) {
  const language = category.slice('/language:'.length)
  return {
    id,
    ref: 'refs/heads/main',
    commit_sha: commit,
    analysis_key: 'dynamic/github-code-scanning/codeql:analyze',
    environment: JSON.stringify({
      'build-mode': 'none',
      category,
      language,
      runner: '["ubuntu-latest"]',
    }),
    error: '',
    warning: '',
    category,
    created_at: '2026-09-04T08:48:49Z',
    results_count: category === '/language:ruby' ? 0 : 2,
    rules_count: 103,
    tool: { guid: null, name: 'CodeQL', version: '2.26.4' },
    ...overrides,
  }
}

function completeAnalyses() {
  return [
    analysis('/language:javascript-typescript', 30),
    analysis('/language:actions', 20),
    analysis('/language:ruby', 10),
  ]
}

function response(source, overrides = {}) {
  return new Response(overrides.body ?? JSON.stringify(source), {
    status: overrides.status ?? 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      ...overrides.headers,
    },
  })
}

test('policy and URLs bind the finite default-setup CodeQL surface', () => {
  assert.deepEqual(codeScanningGatePolicy, {
    analysisKey: 'dynamic/github-code-scanning/codeql:analyze',
    apiOrigin: 'https://api.github.com',
    apiVersion: '2022-11-28',
    branchRef: 'refs/heads/main',
    categories: ['/language:actions', '/language:javascript-typescript', '/language:ruby'],
    maximumAnalyses: 100,
    maximumOpenAlerts: 100,
    maximumResponseBytes: 1024 * 1024,
    timeoutMilliseconds: 15_000,
    toolName: 'CodeQL',
  })
  assert.equal(
    codeScanningAnalysesUrl(repository),
    'https://api.github.com/repos/vyakymenko/zigcss/code-scanning/analyses?ref=refs%2Fheads%2Fmain&tool_name=CodeQL&sort=created&direction=desc&per_page=100&page=1',
  )
  assert.equal(
    codeScanningOpenAlertsUrl(repository),
    'https://api.github.com/repos/vyakymenko/zigcss/code-scanning/alerts?state=open&ref=refs%2Fheads%2Fmain&tool_name=CodeQL&sort=created&direction=desc&per_page=100&page=1',
  )
})

test('accepts exactly the newest clean analysis for every required category', () => {
  const source = [
    analysis('/language:actions', 19, { error: 'superseded failure' }),
    ...completeAnalyses(),
    analysis('/language:ruby', 9, { warning: 'superseded warning' }),
    analysis('/language:javascript-typescript', 8, { commit_sha: 'b'.repeat(40) }),
  ]
  assert.deepEqual(validateCodeScanningAnalysesResponse(source, repository, commit), [
    { analysisId: 20, category: '/language:actions', resultsCount: 2, rulesCount: 103 },
    { analysisId: 30, category: '/language:javascript-typescript', resultsCount: 2, rulesCount: 103 },
    { analysisId: 10, category: '/language:ruby', resultsCount: 0, rulesCount: 103 },
  ])
  assert.equal(validateCodeScanningOpenAlertsResponse([], repository), 0)
})

test('missing, extra, errored, warned, and mismatched analyses fail closed', () => {
  const cases = [
    [completeAnalyses().slice(1), /missing one required/],
    [[...completeAnalyses(), analysis('/language:python', 40)], /unexpected CodeQL analysis category/],
    [completeAnalyses().map(item => item.category === '/language:actions' ? { ...item, error: 'failed' } : item), /did not complete cleanly/],
    [completeAnalyses().map(item => item.category === '/language:ruby' ? { ...item, warning: 'partial' } : item), /did not complete cleanly/],
    [completeAnalyses().map(item => item.category === '/language:ruby' ? { ...item, analysis_key: 'other' } : item), /unexpected CodeQL analysis key/],
    [completeAnalyses().map(item => item.category === '/language:actions'
      ? { ...item, environment: JSON.stringify({ 'build-mode': 'none', category: item.category, language: 'ruby' }) }
      : item), /environment does not match/],
  ]
  for (const [source, expected] of cases) {
    assert.throws(() => validateCodeScanningAnalysesResponse(source, repository, commit), expected)
  }
})

test('malformed and oversized analysis inventories fail closed', () => {
  for (const mutation of [
    { id: 0 },
    { ref: 'refs/heads/development' },
    { commit_sha: commit.toUpperCase() },
    { category: null },
    { created_at: 'not-a-date' },
    { results_count: -1 },
    { rules_count: 0 },
    { tool: { name: 'Other', version: '1' } },
    { environment: '{' },
  ]) {
    const source = completeAnalyses()
    source[0] = { ...source[0], ...mutation }
    assert.throws(
      () => validateCodeScanningAnalysesResponse(source, repository, commit),
      /release code scanning gate:/,
    )
  }
  assert.throws(
    () => validateCodeScanningAnalysesResponse(Array.from({ length: 101 }, (_, id) => analysis('/language:actions', id + 1)), repository, commit),
    /bounded CodeQL analysis inventory/,
  )
})

test('any open CodeQL alert blocks release without trusting alert text', () => {
  assert.throws(
    () => validateCodeScanningOpenAlertsResponse([{ number: 7, message: 'untrusted\ntext' }], repository),
    /at least 1 open CodeQL alert$/,
  )
  assert.throws(
    () => validateCodeScanningOpenAlertsResponse(Array.from({ length: 101 }, () => ({})), repository),
    /bounded open CodeQL alert inventory/,
  )
})

test('verifier performs two exact authenticated bounded requests and returns evidence', async () => {
  const signal = new AbortController().signal
  const requests = []
  const result = await verifyCodeScanningGate({ repository, commit, token }, {
    signal,
    fetchImpl: async (url, options) => {
      requests.push({ url, options })
      return requests.length === 1 ? response(completeAnalyses()) : response([])
    },
  })
  assert.deepEqual(requests.map(request => request.url), [
    codeScanningAnalysesUrl(repository),
    codeScanningOpenAlertsUrl(repository),
  ])
  for (const request of requests) {
    assert.deepEqual(request.options, {
      method: 'GET',
      redirect: 'error',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'zigcss-release-code-scanning-gate/1',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      signal,
    })
  }
  assert.equal(result.commit, commit)
  assert.equal(result.repository, repository)
  assert.equal(result.tool, 'CodeQL')
  assert.equal(result.openAlerts, 0)
  assert.equal(result.analyses.length, 3)
})

test('identity, authorization, transport, response, and JSON bounds fail closed', async () => {
  for (const input of [
    { repository: '../zigcss', commit, token },
    { repository, commit: '0'.repeat(40), token },
    { repository, commit: commit.toUpperCase(), token },
    { repository, commit, token: '' },
    { repository, commit, token: 'line\nbreak' },
  ]) {
    await assert.rejects(
      () => verifyCodeScanningGate(input, { fetchImpl: async () => response(completeAnalyses()) }),
      /release code scanning gate:/,
    )
  }
  await assert.rejects(
    () => verifyCodeScanningGate({ repository, commit, token }, { fetchImpl: async () => response([], { status: 403 }) }),
    /HTTP 403/,
  )
  await assert.rejects(
    () => verifyCodeScanningGate({ repository, commit, token }, { fetchImpl: async () => { throw new Error('offline') } }),
    /GitHub API request failed/,
  )
  await assert.rejects(
    () => verifyCodeScanningGate({ repository, commit, token }, { fetchImpl: async () => response([], { body: '{' }) }),
    /not JSON/,
  )
  await assert.rejects(
    () => verifyCodeScanningGate({ repository, commit, token }, {
      fetchImpl: async () => response([], { headers: { 'content-type': 'text/html' } }),
    }),
    /JSON content type/,
  )
  await assert.rejects(
    () => verifyCodeScanningGate({ repository, commit, token }, {
      fetchImpl: async () => response([], { body: ' '.repeat(codeScanningGatePolicy.maximumResponseBytes + 1) }),
    }),
    /exceeds 1048576 bytes/,
  )
})
