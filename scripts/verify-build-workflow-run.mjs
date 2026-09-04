import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)

export const buildWorkflowEvidencePolicy = Object.freeze({
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

function fail(message) {
  throw new Error(`release Build evidence: ${message}`)
}

function validateRepository(repository) {
  if (
    typeof repository !== 'string'
    || repository.length > 201
    || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/.test(repository)
  ) {
    fail('repository must be one bounded owner/name slug')
  }
  const [owner, name] = repository.split('/')
  if (['.', '..'].includes(owner) || ['.', '..'].includes(name)) {
    fail('repository must be one bounded owner/name slug')
  }
  return { owner, name }
}

function validateCommit(commit) {
  if (typeof commit !== 'string' || !/^[0-9a-f]{40}$/.test(commit)) {
    fail('commit must be one exact lowercase 40-character SHA')
  }
  return commit
}

function validateToken(token) {
  if (
    typeof token !== 'string'
    || token.length === 0
    || token.length > 4096
    || !/^[\x21-\x7e]+$/.test(token)
  ) {
    fail('GITHUB_TOKEN must be one bounded non-empty ASCII token')
  }
  return token
}

export function buildWorkflowRunsUrl(repository, commit) {
  const { owner, name } = validateRepository(repository)
  validateCommit(commit)
  const url = new URL(
    `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/actions/workflows/${buildWorkflowEvidencePolicy.workflowFile}/runs`,
    buildWorkflowEvidencePolicy.apiOrigin,
  )
  url.searchParams.set('branch', buildWorkflowEvidencePolicy.branch)
  url.searchParams.set('event', buildWorkflowEvidencePolicy.event)
  url.searchParams.set('head_sha', commit)
  url.searchParams.set('status', 'completed')
  url.searchParams.set('per_page', String(buildWorkflowEvidencePolicy.maximumRuns))
  return url.href
}

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
      !Number.isSafeInteger(advertisedBytes)
      || advertisedBytes <= 0
      || advertisedBytes > buildWorkflowEvidencePolicy.maximumResponseBytes
    ) {
      fail(`GitHub API response must contain 1 through ${buildWorkflowEvidencePolicy.maximumResponseBytes} bytes`)
    }
  }
  if (response.body === null || typeof response.body?.getReader !== 'function') {
    fail('GitHub API response body is unavailable')
  }

  const chunks = []
  let receivedBytes = 0
  const reader = response.body.getReader()
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      if (!(value instanceof Uint8Array)) fail('GitHub API response returned a non-byte chunk')
      receivedBytes += value.byteLength
      if (receivedBytes > buildWorkflowEvidencePolicy.maximumResponseBytes) {
        await reader.cancel()
        fail(`GitHub API response exceeds ${buildWorkflowEvidencePolicy.maximumResponseBytes} bytes`)
      }
      chunks.push(Buffer.from(value))
    }
  } finally {
    reader.releaseLock()
  }
  if (receivedBytes === 0) fail('GitHub API response is empty')

  let source
  try {
    source = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, receivedBytes))
  } catch (error) {
    fail(`GitHub API response is not UTF-8: ${error.message}`)
  }
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`GitHub API response is not JSON: ${error.message}`)
  }
}

function isExactSuccessfulBuildRun(run, repository, commit) {
  return (
    run !== null
    && typeof run === 'object'
    && !Array.isArray(run)
    && Number.isSafeInteger(run.id)
    && run.id > 0
    && Number.isSafeInteger(run.run_attempt)
    && run.run_attempt > 0
    && run.name === buildWorkflowEvidencePolicy.workflowName
    && run.path === buildWorkflowEvidencePolicy.workflowPath
    && run.event === buildWorkflowEvidencePolicy.event
    && run.head_branch === buildWorkflowEvidencePolicy.branch
    && run.head_sha === commit
    && run.status === 'completed'
    && run.conclusion === 'success'
    && run.repository?.full_name === repository
    && run.head_repository?.full_name === repository
  )
}

export function validateBuildWorkflowRunsResponse(source, repository, commit) {
  validateRepository(repository)
  validateCommit(commit)
  if (source === null || typeof source !== 'object' || Array.isArray(source)) {
    fail('GitHub API response must be an object')
  }
  if (
    !Number.isSafeInteger(source.total_count)
    || source.total_count < 0
    || !Array.isArray(source.workflow_runs)
    || source.workflow_runs.length > buildWorkflowEvidencePolicy.maximumRuns
    || source.total_count < source.workflow_runs.length
  ) {
    fail('GitHub API response must contain one bounded workflow run inventory')
  }

  const matches = source.workflow_runs
    .filter(run => isExactSuccessfulBuildRun(run, repository, commit))
    .sort((left, right) => right.id - left.id)
  if (matches.length === 0) {
    fail(`no successful ${buildWorkflowEvidencePolicy.workflowName} run exists for ${repository}@${commit}`)
  }
  const selected = matches[0]
  return Object.freeze({
    commit,
    repository,
    runAttempt: selected.run_attempt,
    runId: selected.id,
    workflow: buildWorkflowEvidencePolicy.workflowName,
  })
}

export async function verifyBuildWorkflowRun({ repository, commit, token }, options = {}) {
  validateRepository(repository)
  validateCommit(commit)
  validateToken(token)
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  if (typeof fetchImpl !== 'function') fail('fetch implementation is unavailable')
  const signal = options.signal ?? AbortSignal.timeout(buildWorkflowEvidencePolicy.timeoutMilliseconds)
  let response
  try {
    response = await fetchImpl(buildWorkflowRunsUrl(repository, commit), {
      method: 'GET',
      redirect: 'error',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'User-Agent': 'zigcss-release-build-evidence/1',
        'X-GitHub-Api-Version': buildWorkflowEvidencePolicy.apiVersion,
      },
      signal,
    })
  } catch (error) {
    fail(`GitHub API request failed: ${error.message}`)
  }
  if (response === null || typeof response !== 'object' || response.status !== 200) {
    fail(`GitHub API request returned HTTP ${response?.status ?? 0}`)
  }
  return validateBuildWorkflowRunsResponse(await readBoundedJson(response), repository, commit)
}

function parseArgs(args) {
  if (args.length !== 4) fail('usage: --repository owner/name --commit exact-sha')
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!['--repository', '--commit'].includes(name) || value === undefined || values.has(name)) {
      fail('usage: --repository owner/name --commit exact-sha')
    }
    values.set(name, value)
  }
  if (!values.has('--repository') || !values.has('--commit')) {
    fail('usage: --repository owner/name --commit exact-sha')
  }
  return values
}

async function main() {
  const values = parseArgs(process.argv.slice(2))
  const result = await verifyBuildWorkflowRun({
    repository: values.get('--repository'),
    commit: values.get('--commit'),
    token: process.env.GITHUB_TOKEN,
  })
  process.stdout.write(
    `Release Build evidence verified: ${result.repository}@${result.commit} passed ${result.workflow} run ${result.runId} attempt ${result.runAttempt}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) await main()
