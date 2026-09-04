import assert from 'node:assert/strict'
import test from 'node:test'
import {
  releaseControlsPolicy,
  releaseControlsUrls,
  validateDeploymentPolicies,
  validateEnvironmentSecrets,
  validateImmutableReleases,
  validateReleaseEnvironment,
  validateTagRuleset,
  verifyReleaseControls,
} from './verify-release-controls.mjs'

const token = 'github-test-token'
const checkedAt = '2026-09-04T12:34:56.000Z'

function immutableFixture() {
  return { enabled: true, enforced_by_owner: false }
}

function rulesetFixture() {
  return {
    id: 22261144,
    name: 'Protect release tags',
    target: 'tag',
    source_type: 'Repository',
    source: 'vyakymenko/zigcss',
    enforcement: 'active',
    current_user_can_bypass: 'never',
    bypass_actors: [],
    conditions: {
      ref_name: { exclude: [], include: ['refs/tags/v*'] },
    },
    rules: [{ type: 'update' }, { type: 'deletion' }],
  }
}

function environmentFixture() {
  return {
    id: 21234930544,
    name: 'immutable-release',
    can_admins_bypass: false,
    protection_rules: [
      {
        id: 64608557,
        type: 'required_reviewers',
        prevent_self_review: false,
        reviewers: [{
          type: 'User',
          reviewer: { id: 7300673, login: 'vyakymenko', type: 'User' },
        }],
      },
      { id: 64608558, type: 'branch_policy' },
    ],
    deployment_branch_policy: {
      protected_branches: false,
      custom_branch_policies: true,
    },
  }
}

function secretsFixture() {
  return { total_count: 0, secrets: [] }
}

function policiesFixture() {
  return {
    total_count: 1,
    branch_policies: [{ id: 59095548, name: 'v*', type: 'tag' }],
  }
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

function fixtureByUrl() {
  return new Map([
    [releaseControlsUrls.immutableReleases, immutableFixture()],
    [releaseControlsUrls.tagRuleset, rulesetFixture()],
    [releaseControlsUrls.environment, environmentFixture()],
    [releaseControlsUrls.environmentSecrets, secretsFixture()],
    [releaseControlsUrls.deploymentPolicies, policiesFixture()],
  ])
}

test('policy fixes the operator-only repository and every irreversible control identity', () => {
  assert.deepEqual(releaseControlsPolicy, {
    apiOrigin: 'https://api.github.com',
    apiVersion: '2026-03-10',
    deploymentPolicy: { id: 59095548, name: 'v*', type: 'tag' },
    environment: { id: 21234930544, name: 'immutable-release' },
    maximumInventoryEntries: 100,
    maximumResponseBytes: 512 * 1024,
    repository: 'vyakymenko/zigcss',
    reviewer: { id: 7300673, login: 'vyakymenko', type: 'User' },
    tagPattern: 'refs/tags/v*',
    tagRulesetId: 22261144,
    timeoutMilliseconds: 15_000,
  })
  assert.deepEqual(releaseControlsUrls, {
    deploymentPolicies: 'https://api.github.com/repos/vyakymenko/zigcss/environments/immutable-release/deployment-branch-policies?per_page=100&page=1',
    environment: 'https://api.github.com/repos/vyakymenko/zigcss/environments/immutable-release',
    environmentSecrets: 'https://api.github.com/repos/vyakymenko/zigcss/environments/immutable-release/secrets?per_page=100&page=1',
    immutableReleases: 'https://api.github.com/repos/vyakymenko/zigcss/immutable-releases',
    tagRuleset: 'https://api.github.com/repos/vyakymenko/zigcss/rulesets/22261144',
  })
})

test('accepts only the exact immutable release, tag, reviewer, secret, and deployment controls', () => {
  assert.deepEqual(validateImmutableReleases(immutableFixture()), {
    enabled: true,
    enforcedByOwner: false,
  })
  assert.deepEqual(validateTagRuleset(rulesetFixture()), {
    bypassActorCount: 0,
    currentUserCanBypass: 'never',
    enforcement: 'active',
    id: 22261144,
    include: 'refs/tags/v*',
    rules: ['deletion', 'update'],
    target: 'tag',
  })
  assert.deepEqual(validateReleaseEnvironment(environmentFixture()), {
    canAdminsBypass: false,
    customDeploymentPolicies: true,
    id: 21234930544,
    name: 'immutable-release',
    preventSelfReview: false,
    protectedBranches: false,
    reviewer: { id: 7300673, login: 'vyakymenko', type: 'User' },
  })
  assert.equal(validateEnvironmentSecrets(secretsFixture()), 0)
  assert.deepEqual(validateDeploymentPolicies(policiesFixture()), {
    id: 59095548,
    name: 'v*',
    type: 'tag',
  })
})

test('immutable release and tag ruleset drift fail closed', () => {
  for (const source of [
    { enabled: false, enforced_by_owner: false },
    { enabled: true, enforced_by_owner: true },
    { enabled: true },
    [],
  ]) assert.throws(() => validateImmutableReleases(source), /release controls:/)

  const mutations = [
    value => { value.id = 22261145 },
    value => { value.target = 'branch' },
    value => { value.source = 'other/zigcss' },
    value => { value.enforcement = 'evaluate' },
    value => { value.current_user_can_bypass = 'always' },
    value => { delete value.current_user_can_bypass },
    value => { value.bypass_actors.push({ actor_id: 1, actor_type: 'User', bypass_mode: 'always' }) },
    value => { delete value.bypass_actors },
    value => { value.conditions.ref_name.include = ['refs/tags/v*', 'refs/tags/release-*'] },
    value => { value.conditions.ref_name.exclude = ['refs/tags/v0*'] },
    value => { value.conditions.repository_name = { include: ['zigcss'], exclude: [] } },
    value => { value.rules = [{ type: 'update' }] },
    value => { value.rules = [{ type: 'update' }, { type: 'update' }] },
    value => { value.rules.push({ type: 'creation' }) },
    value => { value.rules[0].parameters = {} },
  ]
  for (const mutate of mutations) {
    const source = rulesetFixture()
    mutate(source)
    assert.throws(() => validateTagRuleset(source), /release controls:/)
  }
})

test('environment reviewer, bypass, secret, and deployment-policy ambiguity fail closed', () => {
  const mutations = [
    value => { value.id = 21234930545 },
    value => { value.name = 'release' },
    value => { value.can_admins_bypass = true },
    value => { delete value.can_admins_bypass },
    value => { value.deployment_branch_policy.protected_branches = true },
    value => { value.deployment_branch_policy.custom_branch_policies = false },
    value => { value.protection_rules.push({ id: 3, type: 'wait_timer', wait_timer: 0 }) },
    value => { value.protection_rules[0].prevent_self_review = true },
    value => { value.protection_rules[0].reviewers.push(structuredClone(value.protection_rules[0].reviewers[0])) },
    value => { value.protection_rules[0].reviewers[0].type = 'Team' },
    value => { value.protection_rules[0].reviewers[0].reviewer.id = 1 },
    value => { value.protection_rules[0].reviewers[0].reviewer.login = 'other' },
    value => { value.protection_rules[1].type = 'required_reviewers' },
  ]
  for (const mutate of mutations) {
    const source = environmentFixture()
    mutate(source)
    assert.throws(() => validateReleaseEnvironment(source), /release controls:/)
  }

  for (const source of [
    { total_count: 1, secrets: [] },
    { total_count: 0, secrets: [{ name: 'TOKEN' }] },
    { total_count: 0 },
  ]) assert.throws(() => validateEnvironmentSecrets(source), /release controls:/)

  const policyMutations = [
    value => { value.total_count = 2 },
    value => { value.branch_policies.push({ id: 2, name: 'main', type: 'branch' }) },
    value => { value.branch_policies[0].id = 59094892 },
    value => { value.branch_policies[0].name = 'release-*' },
    value => { value.branch_policies[0].type = 'branch' },
  ]
  for (const mutate of policyMutations) {
    const source = policiesFixture()
    mutate(source)
    assert.throws(() => validateDeploymentPolicies(source), /release controls:/)
  }
})

test('verifier makes five exact authenticated REST requests and returns token-free JSON evidence', async () => {
  const fixtures = fixtureByUrl()
  const requests = []
  const evidence = await verifyReleaseControls({ token }, {
    fetchImpl: async (url, options) => {
      requests.push({ url, options })
      assert.equal(fixtures.has(url), true)
      return response(fixtures.get(url))
    },
    now: () => new Date(checkedAt),
  })
  assert.deepEqual(requests.map(item => item.url), [
    releaseControlsUrls.immutableReleases,
    releaseControlsUrls.tagRuleset,
    releaseControlsUrls.environment,
    releaseControlsUrls.environmentSecrets,
    releaseControlsUrls.deploymentPolicies,
  ])
  const requestSignal = requests[0].options.signal
  assert.equal(requestSignal instanceof AbortSignal, true)
  for (const request of requests) {
    assert.deepEqual(request.options, {
      method: 'GET',
      redirect: 'error',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'zigcss-release-controls/1',
        'X-GitHub-Api-Version': '2026-03-10',
      },
      signal: requestSignal,
    })
  }
  assert.equal(evidence.checkedAt, checkedAt)
  assert.equal(evidence.repository, 'vyakymenko/zigcss')
  assert.equal(evidence.immutableReleases.enabled, true)
  assert.equal(evidence.tagRuleset.currentUserCanBypass, 'never')
  assert.equal(evidence.environment.canAdminsBypass, false)
  assert.equal(evidence.environment.secretCount, 0)
  assert.deepEqual(evidence.deploymentPolicy, { id: 59095548, name: 'v*', type: 'tag' })
  assert.equal(JSON.stringify(evidence).includes(token), false)
})

test('authorization, HTTP, response schema, encoding, and body bounds fail without exposing token', async () => {
  for (const invalidToken of ['', 'line\nbreak', ' ', 'x'.repeat(4097)]) {
    await assert.rejects(
      () => verifyReleaseControls({ token: invalidToken }, { fetchImpl: async () => response({}) }),
      /release controls:/,
    )
  }

  const cases = [
    async () => { throw new Error(`transport leaked ${token}`) },
    async () => response({}, { status: 403 }),
    async () => response({}, { body: '{' }),
    async () => response({}, { headers: { 'content-type': 'text/html' } }),
    async () => response({}, { headers: { 'content-length': 'invalid' } }),
    async () => response({}, { body: 'x'.repeat(releaseControlsPolicy.maximumResponseBytes + 1) }),
  ]
  for (const fetchImpl of cases) {
    await assert.rejects(
      () => verifyReleaseControls({ token }, { fetchImpl }),
      error => {
        assert.match(error.message, /^release controls:/)
        assert.equal(error.message.includes(token), false)
        return true
      },
    )
  }
})

test('the global deadline aborts even an injected transport that never settles', async () => {
  const signals = []
  const started = Date.now()
  await assert.rejects(
    () => verifyReleaseControls({ token }, {
      fetchImpl: async (_url, options) => {
        signals.push(options.signal)
        return new Promise(() => {})
      },
      timeoutMilliseconds: 10,
    }),
    /verification exceeded 10 milliseconds/,
  )
  assert.equal(Date.now() - started < 1_000, true)
  assert.equal(signals.length, 5)
  assert.equal(signals.every(signal => signal.aborted), true)
})

test('invalid cancellation and clock injection fail closed', async () => {
  const controller = new AbortController()
  controller.abort()
  await assert.rejects(
    () => verifyReleaseControls({ token }, { signal: controller.signal }),
    /aborted before it started/,
  )
  await assert.rejects(
    () => verifyReleaseControls({ token }, { signal: {} }),
    /cancellation signal is invalid/,
  )
  await assert.rejects(
    () => verifyReleaseControls({ token }, {
      fetchImpl: async url => response(fixtureByUrl().get(url)),
      now: () => new Date(Number.NaN),
    }),
    /clock returned an invalid date/,
  )
})
