import path from 'node:path'
import { TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)

export const releaseControlsPolicy = Object.freeze({
  apiOrigin: 'https://api.github.com',
  apiVersion: '2026-03-10',
  deploymentPolicy: Object.freeze({ id: 59095548, name: 'v*', type: 'tag' }),
  environment: Object.freeze({ id: 21234930544, name: 'immutable-release' }),
  maximumInventoryEntries: 100,
  maximumResponseBytes: 512 * 1024,
  repository: 'vyakymenko/zigcss',
  reviewer: Object.freeze({ id: 7300673, login: 'vyakymenko', type: 'User' }),
  tagPattern: 'refs/tags/v*',
  tagRulesetId: 22261144,
  timeoutMilliseconds: 15_000,
})

class ReleaseControlsError extends Error {}

function fail(message) {
  throw new ReleaseControlsError(`release controls: ${message}`)
}

function plainObject(value, label) {
  if (
    value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  ) fail(`${label} must be one JSON object`)
  return value
}

function positiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) fail(`${label} must be one positive integer`)
  return value
}

function exactStringArray(value, expected, label) {
  if (
    !Array.isArray(value) || value.length !== expected.length ||
    value.some((item, index) => typeof item !== 'string' || item !== expected[index])
  ) fail(`${label} does not match the required finite inventory`)
}

function validateToken(token) {
  if (
    typeof token !== 'string' || token.length === 0 || token.length > 4096 ||
    !/^[\x21-\x7e]+$/.test(token)
  ) fail('GITHUB_TOKEN must be one bounded non-empty printable ASCII token')
  return token
}

function repositoryUrl(pathname) {
  return new URL(`/repos/${releaseControlsPolicy.repository}/${pathname}`, releaseControlsPolicy.apiOrigin).href
}

export const releaseControlsUrls = Object.freeze({
  deploymentPolicies: repositoryUrl(
    `environments/${encodeURIComponent(releaseControlsPolicy.environment.name)}` +
      `/deployment-branch-policies?per_page=${releaseControlsPolicy.maximumInventoryEntries}&page=1`,
  ),
  environment: repositoryUrl(`environments/${encodeURIComponent(releaseControlsPolicy.environment.name)}`),
  environmentSecrets: repositoryUrl(
    `environments/${encodeURIComponent(releaseControlsPolicy.environment.name)}` +
      `/secrets?per_page=${releaseControlsPolicy.maximumInventoryEntries}&page=1`,
  ),
  immutableReleases: repositoryUrl('immutable-releases'),
  tagRuleset: repositoryUrl(`rulesets/${releaseControlsPolicy.tagRulesetId}`),
})

async function readBoundedJson(response) {
  const contentType = response.headers?.get?.('content-type')
  if (typeof contentType !== 'string' || !/^application\/(?:vnd\.github\+)?json(?:\s*;|$)/i.test(contentType)) {
    fail('GitHub API response must use a JSON content type')
  }
  const contentLength = response.headers.get('content-length')
  if (contentLength !== null) {
    if (!/^(?:0|[1-9][0-9]*)$/.test(contentLength)) {
      fail('GitHub API response has an invalid Content-Length')
    }
    const advertisedBytes = Number(contentLength)
    if (
      !Number.isSafeInteger(advertisedBytes) || advertisedBytes <= 0 ||
      advertisedBytes > releaseControlsPolicy.maximumResponseBytes
    ) {
      fail(`GitHub API response must contain 1 through ${releaseControlsPolicy.maximumResponseBytes} bytes`)
    }
  }
  if (response.body === null || typeof response.body?.getReader !== 'function') {
    fail('GitHub API response body is unavailable')
  }

  const reader = response.body.getReader()
  const chunks = []
  let receivedBytes = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!(value instanceof Uint8Array)) fail('GitHub API response returned a non-byte chunk')
      receivedBytes += value.byteLength
      if (receivedBytes > releaseControlsPolicy.maximumResponseBytes) {
        try {
          await reader.cancel()
        } catch {}
        fail(`GitHub API response exceeds ${releaseControlsPolicy.maximumResponseBytes} bytes`)
      }
      chunks.push(Buffer.from(value))
    }
  } catch (error) {
    if (error instanceof ReleaseControlsError) throw error
    fail('GitHub API response body could not be read')
  } finally {
    reader.releaseLock()
  }
  if (receivedBytes === 0) fail('GitHub API response is empty')

  let source
  try {
    source = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, receivedBytes))
  } catch {
    fail('GitHub API response is not UTF-8')
  }
  try {
    return JSON.parse(source)
  } catch {
    fail('GitHub API response is not JSON')
  }
}

async function requestGitHubJson(url, token, fetchImpl, signal) {
  let response
  try {
    response = await fetchImpl(url, {
      method: 'GET',
      redirect: 'error',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'zigcss-release-controls/1',
        'X-GitHub-Api-Version': releaseControlsPolicy.apiVersion,
      },
      signal,
    })
  } catch {
    if (signal.aborted) fail('GitHub API request was aborted')
    fail('GitHub API request failed')
  }
  if (response === null || typeof response !== 'object' || response.status !== 200) {
    const status = Number.isSafeInteger(response?.status) && response.status >= 100 && response.status <= 599
      ? response.status
      : 0
    fail(`GitHub API request returned HTTP ${status}`)
  }
  try {
    return await readBoundedJson(response)
  } catch (error) {
    if (error instanceof ReleaseControlsError) throw error
    fail('GitHub API response could not be validated')
  }
}

export function validateImmutableReleases(source) {
  const value = plainObject(source, 'immutable releases response')
  if (value.enabled !== true || value.enforced_by_owner !== false) {
    fail('immutable releases must be enabled directly by the repository')
  }
  return Object.freeze({ enabled: true, enforcedByOwner: false })
}

export function validateTagRuleset(source) {
  const value = plainObject(source, 'tag ruleset response')
  if (
    value.id !== releaseControlsPolicy.tagRulesetId || value.target !== 'tag' ||
    value.enforcement !== 'active' || value.source_type !== 'Repository' ||
    value.source !== releaseControlsPolicy.repository || value.current_user_can_bypass !== 'never'
  ) fail('tag ruleset identity, source, target, or enforcement does not match')
  if (!Array.isArray(value.bypass_actors) || value.bypass_actors.length !== 0) {
    fail('tag ruleset must expose exactly zero bypass actors')
  }

  const conditions = plainObject(value.conditions, 'tag ruleset conditions')
  const conditionKeys = Reflect.ownKeys(conditions)
  if (conditionKeys.length !== 1 || conditionKeys[0] !== 'ref_name') {
    fail('tag ruleset must contain only the exact ref-name condition')
  }
  const refName = plainObject(conditions.ref_name, 'tag ruleset ref-name condition')
  exactStringArray(refName.include, [releaseControlsPolicy.tagPattern], 'tag ruleset includes')
  exactStringArray(refName.exclude, [], 'tag ruleset exclusions')

  if (!Array.isArray(value.rules) || value.rules.length !== 2) {
    fail('tag ruleset must contain exactly update and deletion rules')
  }
  const ruleTypes = []
  for (const ruleSource of value.rules) {
    const rule = plainObject(ruleSource, 'tag ruleset rule')
    const keys = Reflect.ownKeys(rule)
    if (keys.length !== 1 || keys[0] !== 'type' || !['update', 'deletion'].includes(rule.type)) {
      fail('tag ruleset contains an unexpected rule')
    }
    ruleTypes.push(rule.type)
  }
  ruleTypes.sort()
  exactStringArray(ruleTypes, ['deletion', 'update'], 'tag ruleset rules')
  return Object.freeze({
    bypassActorCount: 0,
    currentUserCanBypass: 'never',
    enforcement: 'active',
    id: releaseControlsPolicy.tagRulesetId,
    include: releaseControlsPolicy.tagPattern,
    rules: Object.freeze([...ruleTypes]),
    target: 'tag',
  })
}

export function validateReleaseEnvironment(source) {
  const value = plainObject(source, 'release environment response')
  if (
    value.id !== releaseControlsPolicy.environment.id ||
    value.name !== releaseControlsPolicy.environment.name ||
    value.can_admins_bypass !== false
  ) fail('release environment identity or administrator bypass setting does not match')

  const deployment = plainObject(value.deployment_branch_policy, 'release environment deployment policy')
  if (deployment.protected_branches !== false || deployment.custom_branch_policies !== true) {
    fail('release environment must use only custom deployment policies')
  }
  if (!Array.isArray(value.protection_rules) || value.protection_rules.length !== 2) {
    fail('release environment must expose exactly reviewer and branch-policy protection rules')
  }
  const reviewerRules = value.protection_rules.filter(rule => plainObject(rule, 'environment protection rule').type === 'required_reviewers')
  const branchRules = value.protection_rules.filter(rule => rule.type === 'branch_policy')
  if (reviewerRules.length !== 1 || branchRules.length !== 1) {
    fail('release environment protection rules are missing or ambiguous')
  }

  const reviewerRule = reviewerRules[0]
  positiveInteger(reviewerRule.id, 'required-reviewers rule ID')
  positiveInteger(branchRules[0].id, 'branch-policy rule ID')
  if (reviewerRule.prevent_self_review !== false) {
    fail('release environment must allow the configured reviewer to approve their own deployment')
  }
  if (!Array.isArray(reviewerRule.reviewers) || reviewerRule.reviewers.length !== 1) {
    fail('release environment must have exactly one required reviewer')
  }
  const reviewerEntry = plainObject(reviewerRule.reviewers[0], 'required reviewer entry')
  const reviewer = plainObject(reviewerEntry.reviewer, 'required reviewer identity')
  if (
    reviewerEntry.type !== releaseControlsPolicy.reviewer.type ||
    reviewer.type !== releaseControlsPolicy.reviewer.type ||
    reviewer.id !== releaseControlsPolicy.reviewer.id ||
    reviewer.login !== releaseControlsPolicy.reviewer.login
  ) fail('release environment required reviewer does not match')

  return Object.freeze({
    canAdminsBypass: false,
    customDeploymentPolicies: true,
    id: releaseControlsPolicy.environment.id,
    name: releaseControlsPolicy.environment.name,
    preventSelfReview: false,
    protectedBranches: false,
    reviewer: releaseControlsPolicy.reviewer,
  })
}

export function validateEnvironmentSecrets(source) {
  const value = plainObject(source, 'environment secrets response')
  if (value.total_count !== 0 || !Array.isArray(value.secrets) || value.secrets.length !== 0) {
    fail('release environment must contain exactly zero secrets')
  }
  return 0
}

export function validateDeploymentPolicies(source) {
  const value = plainObject(source, 'deployment policies response')
  if (
    value.total_count !== 1 || !Array.isArray(value.branch_policies) ||
    value.branch_policies.length !== 1
  ) fail('release environment must contain exactly one deployment policy')
  const policy = plainObject(value.branch_policies[0], 'deployment policy')
  if (
    policy.id !== releaseControlsPolicy.deploymentPolicy.id ||
    policy.name !== releaseControlsPolicy.deploymentPolicy.name ||
    policy.type !== releaseControlsPolicy.deploymentPolicy.type
  ) fail('release environment deployment policy does not match the exact tag policy')
  return releaseControlsPolicy.deploymentPolicy
}

function checkedAt(now) {
  if (typeof now !== 'function') fail('clock implementation is unavailable')
  let value
  try {
    value = now()
  } catch {
    fail('clock implementation failed')
  }
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) fail('clock returned an invalid date')
  return value.toISOString()
}

async function verifyResponses(token, fetchImpl, signal) {
  const [immutableSource, rulesetSource, environmentSource, secretsSource, policiesSource] = await Promise.all([
    requestGitHubJson(releaseControlsUrls.immutableReleases, token, fetchImpl, signal),
    requestGitHubJson(releaseControlsUrls.tagRuleset, token, fetchImpl, signal),
    requestGitHubJson(releaseControlsUrls.environment, token, fetchImpl, signal),
    requestGitHubJson(releaseControlsUrls.environmentSecrets, token, fetchImpl, signal),
    requestGitHubJson(releaseControlsUrls.deploymentPolicies, token, fetchImpl, signal),
  ])
  return {
    deploymentPolicy: validateDeploymentPolicies(policiesSource),
    environment: validateReleaseEnvironment(environmentSource),
    immutableReleases: validateImmutableReleases(immutableSource),
    secretCount: validateEnvironmentSecrets(secretsSource),
    tagRuleset: validateTagRuleset(rulesetSource),
  }
}

export async function verifyReleaseControls({ token }, options = {}) {
  validateToken(token)
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  if (typeof fetchImpl !== 'function') fail('fetch implementation is unavailable')
  const timeoutMilliseconds = options.timeoutMilliseconds ?? releaseControlsPolicy.timeoutMilliseconds
  if (
    !Number.isSafeInteger(timeoutMilliseconds) || timeoutMilliseconds <= 0 ||
    timeoutMilliseconds > releaseControlsPolicy.timeoutMilliseconds
  ) fail(`timeout must be between 1 and ${releaseControlsPolicy.timeoutMilliseconds} milliseconds`)
  if (options.signal !== undefined && !(options.signal instanceof AbortSignal)) {
    fail('external cancellation signal is invalid')
  }
  if (options.signal?.aborted === true) fail('verification was aborted before it started')

  const controller = new AbortController()
  const requestSignal = options.signal === undefined
    ? controller.signal
    : AbortSignal.any([controller.signal, options.signal])
  const timeoutMarker = Object.freeze({ type: 'timeout' })
  const abortMarker = Object.freeze({ type: 'abort' })
  let timeoutHandle
  let abortListener
  const timeoutPromise = new Promise((resolve, reject) => {
    timeoutHandle = setTimeout(() => {
      reject(timeoutMarker)
      controller.abort()
    }, timeoutMilliseconds)
    timeoutHandle.unref?.()
  })
  const candidates = [verifyResponses(token, fetchImpl, requestSignal), timeoutPromise]
  if (options.signal !== undefined) {
    candidates.push(new Promise((resolve, reject) => {
      abortListener = () => reject(abortMarker)
      options.signal.addEventListener('abort', abortListener, { once: true })
    }))
  }

  let responses
  try {
    responses = await Promise.race(candidates)
  } catch (error) {
    controller.abort()
    if (error === timeoutMarker) fail(`verification exceeded ${timeoutMilliseconds} milliseconds`)
    if (error === abortMarker) fail('verification was aborted')
    throw error
  } finally {
    clearTimeout(timeoutHandle)
    if (abortListener !== undefined) options.signal.removeEventListener('abort', abortListener)
  }

  return Object.freeze({
    checkedAt: checkedAt(options.now ?? (() => new Date())),
    deploymentPolicy: responses.deploymentPolicy,
    environment: Object.freeze({
      ...responses.environment,
      deploymentPolicy: responses.deploymentPolicy,
      secretCount: responses.secretCount,
    }),
    immutableReleases: responses.immutableReleases,
    repository: releaseControlsPolicy.repository,
    tagRuleset: responses.tagRuleset,
  })
}

async function main() {
  if (process.argv.length !== 2) fail('usage: GITHUB_TOKEN=... node scripts/verify-release-controls.mjs')
  const evidence = await verifyReleaseControls({ token: process.env.GITHUB_TOKEN })
  process.stdout.write(`${JSON.stringify(evidence)}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  try {
    await main()
  } catch (error) {
    const message = error instanceof ReleaseControlsError
      ? error.message
      : 'release controls: unexpected verification failure'
    process.stderr.write(`${message}\n`)
    process.exitCode = 1
  }
}
