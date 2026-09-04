import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)

const categoryLanguages = new Map([
  ['/language:actions', 'actions'],
  ['/language:javascript-typescript', 'javascript-typescript'],
  ['/language:ruby', 'ruby'],
])

export const codeScanningGatePolicy = Object.freeze({
  analysisKey: 'dynamic/github-code-scanning/codeql:analyze',
  apiOrigin: 'https://api.github.com',
  apiVersion: '2022-11-28',
  branchRef: 'refs/heads/main',
  categories: Object.freeze([...categoryLanguages.keys()]),
  maximumAnalyses: 100,
  maximumOpenAlerts: 100,
  maximumResponseBytes: 1024 * 1024,
  timeoutMilliseconds: 15_000,
  toolName: 'CodeQL',
})

function fail(message) {
  throw new Error(`release code scanning gate: ${message}`)
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
  if (typeof commit !== 'string' || !/^[0-9a-f]{40}$/.test(commit) || /^0+$/.test(commit)) {
    fail('commit must be one exact non-zero lowercase 40-character SHA')
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

function repositoryApiUrl(repository, endpoint, parameters) {
  const { owner, name } = validateRepository(repository)
  const url = new URL(
    `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/code-scanning/${endpoint}`,
    codeScanningGatePolicy.apiOrigin,
  )
  for (const [key, value] of parameters) url.searchParams.set(key, value)
  return url.href
}

export function codeScanningAnalysesUrl(repository) {
  return repositoryApiUrl(repository, 'analyses', new Map([
    ['ref', codeScanningGatePolicy.branchRef],
    ['tool_name', codeScanningGatePolicy.toolName],
    ['sort', 'created'],
    ['direction', 'desc'],
    ['per_page', String(codeScanningGatePolicy.maximumAnalyses)],
    ['page', '1'],
  ]))
}

export function codeScanningOpenAlertsUrl(repository) {
  return repositoryApiUrl(repository, 'alerts', new Map([
    ['state', 'open'],
    ['ref', codeScanningGatePolicy.branchRef],
    ['tool_name', codeScanningGatePolicy.toolName],
    ['sort', 'created'],
    ['direction', 'desc'],
    ['per_page', String(codeScanningGatePolicy.maximumOpenAlerts)],
    ['page', '1'],
  ]))
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
      || advertisedBytes > codeScanningGatePolicy.maximumResponseBytes
    ) {
      fail(`GitHub API response must contain 1 through ${codeScanningGatePolicy.maximumResponseBytes} bytes`)
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
      if (receivedBytes > codeScanningGatePolicy.maximumResponseBytes) {
        await reader.cancel()
        fail(`GitHub API response exceeds ${codeScanningGatePolicy.maximumResponseBytes} bytes`)
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
  } catch {
    fail('GitHub API response is not UTF-8')
  }
  try {
    return JSON.parse(source)
  } catch {
    fail('GitHub API response is not JSON')
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function parseAnalysisEnvironment(source) {
  if (typeof source !== 'string' || source.length === 0 || source.length > 4096) {
    fail('CodeQL analysis environment must be one bounded JSON object')
  }
  let environment
  try {
    environment = JSON.parse(source)
  } catch {
    fail('CodeQL analysis environment must be one bounded JSON object')
  }
  if (!isPlainObject(environment)) fail('CodeQL analysis environment must be one bounded JSON object')
  return environment
}

function validateAnalysisShape(analysis) {
  if (
    !isPlainObject(analysis)
    || !Number.isSafeInteger(analysis.id)
    || analysis.id <= 0
    || analysis.ref !== codeScanningGatePolicy.branchRef
    || typeof analysis.commit_sha !== 'string'
    || !/^[0-9a-f]{40}$/.test(analysis.commit_sha)
    || typeof analysis.analysis_key !== 'string'
    || analysis.analysis_key.length > 256
    || typeof analysis.category !== 'string'
    || analysis.category.length > 128
    || typeof analysis.error !== 'string'
    || analysis.error.length > 4096
    || typeof analysis.warning !== 'string'
    || analysis.warning.length > 4096
    || typeof analysis.created_at !== 'string'
    || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(analysis.created_at)
    || !Number.isSafeInteger(analysis.results_count)
    || analysis.results_count < 0
    || !Number.isSafeInteger(analysis.rules_count)
    || analysis.rules_count <= 0
    || !isPlainObject(analysis.tool)
    || analysis.tool.name !== codeScanningGatePolicy.toolName
    || typeof analysis.tool.version !== 'string'
    || analysis.tool.version.length === 0
    || analysis.tool.version.length > 128
  ) {
    fail('GitHub API returned one malformed CodeQL analysis')
  }
}

export function validateCodeScanningAnalysesResponse(source, repository, commit) {
  validateRepository(repository)
  validateCommit(commit)
  if (!Array.isArray(source) || source.length > codeScanningGatePolicy.maximumAnalyses) {
    fail('GitHub API must return one bounded CodeQL analysis inventory')
  }

  const newestByCategory = new Map()
  for (const analysis of source) {
    validateAnalysisShape(analysis)
    if (analysis.commit_sha !== commit) continue
    if (analysis.analysis_key !== codeScanningGatePolicy.analysisKey) {
      fail('candidate commit has an unexpected CodeQL analysis key')
    }
    const expectedLanguage = categoryLanguages.get(analysis.category)
    if (expectedLanguage === undefined) {
      fail('candidate commit has an unexpected CodeQL analysis category')
    }
    const environment = parseAnalysisEnvironment(analysis.environment)
    if (
      environment.category !== analysis.category
      || environment.language !== expectedLanguage
      || environment['build-mode'] !== 'none'
    ) {
      fail('candidate commit CodeQL analysis environment does not match its category')
    }
    const previous = newestByCategory.get(analysis.category)
    if (previous === undefined || analysis.id > previous.id) newestByCategory.set(analysis.category, analysis)
  }

  const evidence = []
  for (const category of codeScanningGatePolicy.categories) {
    const analysis = newestByCategory.get(category)
    if (analysis === undefined) fail('candidate commit is missing one required CodeQL analysis category')
    if (analysis.error !== '' || analysis.warning !== '') {
      fail('candidate commit newest CodeQL analysis did not complete cleanly')
    }
    evidence.push(Object.freeze({
      analysisId: analysis.id,
      category,
      resultsCount: analysis.results_count,
      rulesCount: analysis.rules_count,
    }))
  }
  return Object.freeze(evidence)
}

export function validateCodeScanningOpenAlertsResponse(source, repository) {
  validateRepository(repository)
  if (!Array.isArray(source) || source.length > codeScanningGatePolicy.maximumOpenAlerts) {
    fail('GitHub API must return one bounded open CodeQL alert inventory')
  }
  if (source.length !== 0) {
    fail(`repository has at least ${source.length} open CodeQL alert${source.length === 1 ? '' : 's'}`)
  }
  return 0
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
        'User-Agent': 'zigcss-release-code-scanning-gate/1',
        'X-GitHub-Api-Version': codeScanningGatePolicy.apiVersion,
      },
      signal,
    })
  } catch {
    fail('GitHub API request failed')
  }
  if (response === null || typeof response !== 'object' || response.status !== 200) {
    const status = Number.isSafeInteger(response?.status) && response.status >= 100 && response.status <= 599
      ? response.status
      : 0
    fail(`GitHub API request returned HTTP ${status}`)
  }
  return readBoundedJson(response)
}

export async function verifyCodeScanningGate({ repository, commit, token }, options = {}) {
  validateRepository(repository)
  validateCommit(commit)
  validateToken(token)
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  if (typeof fetchImpl !== 'function') fail('fetch implementation is unavailable')
  const signal = options.signal ?? AbortSignal.timeout(codeScanningGatePolicy.timeoutMilliseconds)

  const analyses = validateCodeScanningAnalysesResponse(
    await requestGitHubJson(codeScanningAnalysesUrl(repository), token, fetchImpl, signal),
    repository,
    commit,
  )
  const openAlerts = validateCodeScanningOpenAlertsResponse(
    await requestGitHubJson(codeScanningOpenAlertsUrl(repository), token, fetchImpl, signal),
    repository,
  )
  return Object.freeze({ analyses, commit, openAlerts, repository, tool: codeScanningGatePolicy.toolName })
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
  const result = await verifyCodeScanningGate({
    repository: values.get('--repository'),
    commit: values.get('--commit'),
    token: process.env.GITHUB_TOKEN,
  })
  process.stdout.write(
    `Release CodeQL gate verified: ${result.repository}@${result.commit} has ${result.analyses.length} exact analyses and zero open alerts.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) await main()
