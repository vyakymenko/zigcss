import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const dependencySurfaces = [
  { label: 'root npm package', directory: '.', dependabotDirectory: '/' },
  { label: 'documentation site', directory: 'docs', dependabotDirectory: '/docs' },
  {
    label: 'Next.js Turbopack example',
    directory: 'examples/next-turbopack',
    dependabotDirectory: '/examples/next-turbopack',
  },
  {
    label: 'SvelteKit example',
    directory: 'examples/sveltekit',
    dependabotDirectory: '/examples/sveltekit',
  },
  {
    label: 'Astro example',
    directory: 'examples/astro',
    dependabotDirectory: '/examples/astro',
  },
  {
    label: 'Nuxt example',
    directory: 'examples/nuxt',
    dependabotDirectory: '/examples/nuxt',
  },
  { label: 'VS Code extension', directory: 'vscode-extension', dependabotDirectory: '/vscode-extension' },
]

export const developmentDependencySurface = Object.freeze({
  label: 'root development graph',
  directory: '.',
})

const developmentAuditScriptPolicy = Object.freeze([
  Object.freeze({ script: 'audit:development', selector: '.' }),
  Object.freeze({ script: 'audit:documentation', selector: 'docs' }),
  Object.freeze({ script: 'audit:turbopack-example', selector: 'examples/next-turbopack' }),
  Object.freeze({ script: 'audit:sveltekit-example', selector: 'examples/sveltekit' }),
  Object.freeze({ script: 'audit:astro-example', selector: 'examples/astro' }),
  Object.freeze({ script: 'audit:nuxt-example', selector: 'examples/nuxt' }),
  Object.freeze({ script: 'audit:vscode', selector: 'vscode-extension' }),
])

export const developmentAuditModes = Object.freeze(developmentAuditScriptPolicy.map(mode => Object.freeze({
  ...mode,
  surface: mode.selector === '.'
    ? developmentDependencySurface
    : dependencySurfaces.find(surface => surface.directory === mode.selector),
})))

export const auditExecutionPolicy = Object.freeze({
  maximumAttempts: 4,
  timeoutMilliseconds: 90_000,
})

const retryableAuditStatusCodes = new Set([408, 425, 429, 500, 502, 503, 504])
const auditEndpointPath = '/-/npm/v1/security/advisories/bulk'

export const locklessLocalManifestSurfaces = Object.freeze([
  Object.freeze({
    label: 'root-lock-bound Parcel example',
    directory: 'examples/parcel',
    manifest: Object.freeze({
      name: 'zigcss-parcel-local-example',
      private: true,
      browserslist: '>= 0.5%, not dead',
      targets: Object.freeze({
        default: Object.freeze({ sourceMap: true }),
      }),
    }),
  }),
])

const ambientDependencyScopeKeys = new Set([
  'node_env',
  'npm_config_dev',
  'npm_config_include',
  'npm_config_omit',
  'npm_config_only',
  'npm_config_optional',
  'npm_config_peer',
  'npm_config_production',
])

const ignoredDirectories = new Set([
  '.git',
  '.zig-cache',
  'dist',
  'node_modules',
  'out',
  'zig-out',
])

function fail(message) {
  throw new Error(`dependency integrity: ${message}`)
}

export function validateDevelopmentAuditModes() {
  const expectedSelectors = dependencySurfaces.map(surface => surface.directory).sort()
  const actualSelectors = developmentAuditModes.map(mode => mode.selector).sort()
  if (JSON.stringify(actualSelectors) !== JSON.stringify(expectedSelectors)) {
    fail(`full-graph audit inventory changed: expected ${JSON.stringify(expectedSelectors)}, received ${JSON.stringify(actualSelectors)}`)
  }
  if (
    new Set(developmentAuditModes.map(mode => mode.script)).size !== developmentAuditModes.length
    || developmentAuditModes.some(mode => mode.surface?.directory !== mode.selector)
  ) {
    fail('full-graph audit modes must map unique scripts to their exact allowlisted dependency surfaces')
  }
  return true
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${file} is not valid JSON: ${error.message}`)
  }
}

function relative(root, file) {
  return path.relative(root, file).split(path.sep).join('/')
}

function normalizedRecord(value) {
  return Object.fromEntries(Object.entries(value ?? {}).sort(([left], [right]) => left === right ? 0 : left < right ? -1 : 1))
}

export const reviewedDevelopmentOracleOverrides = Object.freeze({
  'brace-expansion': '5.0.9',
})

export const reviewedExtensionProductionPatches = Object.freeze({
  'brace-expansion': '5.0.9',
})
export const reviewedBuildGraphSecurityPatches = Object.freeze({
  browserslist: '4.28.8',
  qs: '6.16.0',
})

export function validateReviewedDevelopmentOracleOverrides(manifest, lock) {
  if (JSON.stringify(normalizedRecord(manifest?.overrides)) !== JSON.stringify(reviewedDevelopmentOracleOverrides)) {
    fail(`development oracle overrides must equal ${JSON.stringify(reviewedDevelopmentOracleOverrides)}`)
  }
  const minimatch = lock?.packages?.['node_modules/minimatch']
  if (minimatch?.dependencies?.['brace-expansion'] !== '^2.0.2') {
    fail('reviewed brace-expansion override no longer matches the locked minimatch dependency edge')
  }
  const patched = lock?.packages?.['node_modules/brace-expansion']
  if (patched?.version !== reviewedDevelopmentOracleOverrides['brace-expansion']) {
    fail(`development oracle graph must lock brace-expansion ${reviewedDevelopmentOracleOverrides['brace-expansion']}`)
  }
  return true
}

export function validateExtensionProductionSecurityPatches(lock) {
  const minimatch = lock?.packages?.['node_modules/minimatch']
  if (minimatch?.dependencies?.['brace-expansion'] !== '^5.0.8') {
    fail('reviewed VS Code brace-expansion patch no longer matches the locked minimatch dependency edge')
  }
  const patched = lock?.packages?.['node_modules/brace-expansion']
  if (patched?.version !== reviewedExtensionProductionPatches['brace-expansion']) {
    fail(`VS Code production graph must lock brace-expansion ${reviewedExtensionProductionPatches['brace-expansion']}`)
  }
  return true
}

export function validateBuildGraphSecurityPatches(docsLock, extensionLock) {
  const browserslist = docsLock?.packages?.['node_modules/browserslist']
  if (browserslist?.version !== reviewedBuildGraphSecurityPatches.browserslist) {
    fail(`documentation build graph must lock browserslist ${reviewedBuildGraphSecurityPatches.browserslist}`)
  }
  const querystring = extensionLock?.packages?.['node_modules/qs']
  if (querystring?.version !== reviewedBuildGraphSecurityPatches.qs) {
    fail(`VS Code build graph must lock qs ${reviewedBuildGraphSecurityPatches.qs}`)
  }
  return true
}

function recursiveLockfiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) return []
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) return recursiveLockfiles(entryPath)
    return entry.name === 'package-lock.json' ? [entryPath] : []
  })
}

function recursiveManifests(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) return []
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) return recursiveManifests(entryPath)
    return entry.name === 'package.json' ? [entryPath] : []
  })
}

function normalizedJson(value) {
  if (Array.isArray(value)) return value.map(normalizedJson)
  if (value === null || typeof value !== 'object') return value
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left === right ? 0 : left < right ? -1 : 1)
      .map(([name, nested]) => [name, normalizedJson(nested)]),
  )
}

export function discoverNpmSurfaces(root = repositoryRoot) {
  const manifests = recursiveManifests(root).map(file => relative(root, path.dirname(file))).sort()
  const expectedManifests = [
    ...dependencySurfaces.map(surface => surface.directory === '.' ? '' : surface.directory),
    ...locklessLocalManifestSurfaces.map(surface => surface.directory),
  ].sort()
  if (JSON.stringify(manifests) !== JSON.stringify(expectedManifests)) {
    fail(`npm manifest inventory changed: expected ${JSON.stringify(expectedManifests)}, received ${JSON.stringify(manifests)}`)
  }

  const discovered = recursiveLockfiles(root).map(file => relative(root, path.dirname(file))).sort()
  const expected = dependencySurfaces.map(surface => surface.directory === '.' ? '' : surface.directory).sort()
  if (JSON.stringify(discovered) !== JSON.stringify(expected)) {
    fail(`npm lockfile inventory changed: expected ${JSON.stringify(expected)}, received ${JSON.stringify(discovered)}`)
  }
  return dependencySurfaces
}

export function validateLocklessLocalManifests(root = repositoryRoot) {
  for (const surface of locklessLocalManifestSurfaces) {
    const actual = normalizedJson(readJson(path.join(root, surface.directory, 'package.json')))
    const expected = normalizedJson(surface.manifest)
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      fail(`${surface.label} must retain its exact dependency-free and script-free local manifest`)
    }
  }
  return locklessLocalManifestSurfaces.length
}

function exactSpecifier(specifier) {
  return /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(specifier)
}

export function validateManifestLocks(root = repositoryRoot) {
  const allowedLocal = new Map([['docs:zigcss', 'file:..']])
  for (const surface of discoverNpmSurfaces(root)) {
    const directory = path.resolve(root, surface.directory)
    const manifest = readJson(path.join(directory, 'package.json'))
    const lock = readJson(path.join(directory, 'package-lock.json'))
    const lockRoot = lock.packages?.['']
    if (lock.lockfileVersion !== 3 || lockRoot === undefined) fail(`${surface.label} must use npm lockfileVersion 3 with a root package`)
    if (lockRoot.name !== manifest.name || lockRoot.version !== manifest.version) fail(`${surface.label} manifest and lock identity diverge`)

    for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
      const expected = normalizedRecord(manifest[section])
      const actual = normalizedRecord(lockRoot[section])
      if (JSON.stringify(actual) !== JSON.stringify(expected)) fail(`${surface.label} ${section} diverges from its lockfile`)
    }

    for (const section of ['dependencies', 'devDependencies', 'optionalDependencies']) {
      for (const [name, specifier] of Object.entries(manifest[section] ?? {})) {
        const localKey = `${surface.directory}:${name}`
        if (allowedLocal.get(localKey) === specifier) continue
        if (!exactSpecifier(specifier)) fail(`${surface.label} ${section}.${name} is not an exact version: ${specifier}`)
      }
    }
  }
  const locklessLocal = validateLocklessLocalManifests(root)
  return Object.freeze({ locked: dependencySurfaces.length, locklessLocal })
}

export function renderDependabotConfig() {
  return `version: 2
updates:
  - package-ecosystem: "npm"
    directories:
      - "/"
      - "/docs"
      - "/examples/next-turbopack"
      - "/examples/sveltekit"
      - "/examples/astro"
      - "/examples/nuxt"
      - "/vscode-extension"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 3
    versioning-strategy: "increase"

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 2

  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 1
`
}

export function validateUpdatePolicy(root = repositoryRoot) {
  const configPath = path.join(root, '.github', 'dependabot.yml')
  const actual = fs.readFileSync(configPath, 'utf8')
  const expected = renderDependabotConfig()
  if (actual !== expected) fail('.github/dependabot.yml does not match the bounded reviewed policy')

  const manifest = readJson(path.join(root, 'package.json'))
  const lock = readJson(path.join(root, 'package-lock.json'))
  const docsLock = readJson(path.join(root, 'docs', 'package-lock.json'))
  const extensionLock = readJson(path.join(root, 'vscode-extension', 'package-lock.json'))
  validateReviewedDevelopmentOracleOverrides(manifest, lock)
  validateExtensionProductionSecurityPatches(extensionLock)
  validateBuildGraphSecurityPatches(docsLock, extensionLock)
  validateDevelopmentAuditModes()
  if (manifest.scripts?.['test:dependencies'] !== 'node --test scripts/audit-production-dependencies.test.mjs') {
    fail('package.json is missing the exact dependency policy test script')
  }
  if (manifest.scripts?.['audit:production'] !== 'node scripts/audit-production-dependencies.mjs --audit') {
    fail('package.json is missing the exact production audit script')
  }
  for (const mode of developmentAuditModes) {
    const selector = mode.selector === '.' ? '' : ` ${mode.selector}`
    const expected = `node scripts/audit-production-dependencies.mjs --audit-development${selector}`
    if (manifest.scripts?.[mode.script] !== expected) {
      fail(`package.json is missing the exact bounded ${mode.surface.label} full-graph audit script`)
    }
  }

  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const installs = workflow.indexOf('Install VS Code extension dependencies')
  const dependencyGate = workflow.indexOf('npm run test:dependencies && npm run audit:production && npm run audit:development && npm run audit:documentation && npm run audit:vscode && npm run audit:turbopack-example && npm run audit:sveltekit-example && npm run audit:astro-example && npm run audit:nuxt-example')
  const nativeTests = workflow.indexOf('- name: Run Tests', dependencyGate)
  if (installs === -1 || dependencyGate <= installs || nativeTests <= dependencyGate) {
    fail('build workflow does not audit dependencies after locked installs and before native tests')
  }
  return true
}

function numericCount(counts, name, label) {
  const value = counts?.[name]
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} audit has invalid ${name} count`)
  return value
}

export function parseAuditReport(report, label = 'npm') {
  if (report === null || typeof report !== 'object' || Array.isArray(report) || report.auditReportVersion !== 2) {
    fail(`${label} did not return npm audit report version 2`)
  }
  const counts = report.metadata?.vulnerabilities
  const normalized = Object.fromEntries(
    ['info', 'low', 'moderate', 'high', 'critical', 'total'].map(name => [name, numericCount(counts, name, label)]),
  )
  const summed = normalized.info + normalized.low + normalized.moderate + normalized.high + normalized.critical
  if (normalized.total !== summed) fail(`${label} audit vulnerability total is inconsistent`)
  if (normalized.high !== 0 || normalized.critical !== 0) {
    fail(`${label} has ${normalized.high} high and ${normalized.critical} critical audited vulnerabilities`)
  }
  return normalized
}

export function auditArguments(surface, { omitDevelopment = true } = {}) {
  const args = []
  if (surface.directory !== '.') args.push('--prefix', surface.directory)
  args.push('audit')
  if (omitDevelopment) {
    args.push('--omit=dev', '--include=prod', '--include=optional', '--include=peer')
  } else {
    args.push('--include=prod', '--include=dev', '--include=optional', '--include=peer')
  }
  args.push('--package-lock-only', '--audit-level=high', '--json')
  return args
}

export function auditEnvironment(environment = process.env) {
  const sanitized = new Map()
  for (const [name, value] of Object.entries(environment)) {
    if (!ambientDependencyScopeKeys.has(name.toLowerCase())) sanitized.set(name, value)
  }
  sanitized.set('NO_COLOR', '1')
  return Object.fromEntries(sanitized)
}

function isAuditEndpoint(uri) {
  if (typeof uri !== 'string') return false
  try {
    const parsed = new URL(uri)
    return ['http:', 'https:'].includes(parsed.protocol) && parsed.pathname.endsWith(auditEndpointPath)
  } catch {
    return false
  }
}

function isRetryableAuditEndpointFailure(result, report) {
  if (
    result.error !== undefined
    || result.status === 0
    || report === null
    || typeof report !== 'object'
    || Array.isArray(report)
    || report.method !== 'POST'
    || !isAuditEndpoint(report.uri)
  ) return false

  if (retryableAuditStatusCodes.has(report.statusCode)) return true
  if (typeof report.message !== 'string') return false
  if (/^network timeout at:/i.test(report.message)) return true
  return /^request to .* failed, reason:/i.test(report.message)
    && /\b(?:EAI_AGAIN|ECONNRESET|ETIMEDOUT|ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|ENETDOWN|UND_ERR_CONNECT_TIMEOUT|network timeout|socket timeout)\b/i.test(report.message)
}

export function resolveAuditInvocation(arguments_) {
  if (!Array.isArray(arguments_) || arguments_.some(argument => typeof argument !== 'string')) {
    throw new Error('audit invocation arguments must be strings')
  }
  if (arguments_.length === 1 && arguments_[0] === '--check') return Object.freeze({ kind: 'check' })
  if (arguments_.length === 1 && arguments_[0] === '--audit') return Object.freeze({ kind: 'production' })
  if (arguments_[0] === '--audit-development' && arguments_.length >= 1 && arguments_.length <= 2) {
    const selector = arguments_[1] ?? '.'
    const mode = developmentAuditModes.find(candidate => candidate.selector === selector)
    if (mode !== undefined) return Object.freeze({ kind: 'development', mode })
  }
  throw new Error('usage: node scripts/audit-production-dependencies.mjs --check|--audit|--audit-development [directory]')
}

export function runAudit(surface, root, { omitDevelopment = true, spawn = spawnSync } = {}) {
  const args = auditArguments(surface, { omitDevelopment })
  for (let attempt = 1; attempt <= auditExecutionPolicy.maximumAttempts; attempt += 1) {
    const result = spawn('npm', args, {
      cwd: root,
      encoding: 'utf8',
      env: auditEnvironment(process.env),
      maxBuffer: 16 * 1024 * 1024,
      timeout: auditExecutionPolicy.timeoutMilliseconds,
    })

    let report
    let reportParsingError
    try {
      report = JSON.parse(result.stdout)
    } catch (error) {
      reportParsingError = error
    }

    if (report?.auditReportVersion === 2) {
      const counts = parseAuditReport(report, surface.label)
      if (result.error === undefined && result.status === 0) return counts
      if (result.error === undefined) {
        fail(`${surface.label} audit exited ${result.status} without a high/critical finding`)
      }
    }

    const retryable = result.error?.code === 'ETIMEDOUT'
      || isRetryableAuditEndpointFailure(result, report)
    if (retryable && attempt < auditExecutionPolicy.maximumAttempts) continue
    if (retryable) {
      fail(`${surface.label} audit could not reach the npm audit endpoint after ${attempt} bounded attempts`)
    }
    if (result.error) {
      fail(`${surface.label} audit failed to run after ${attempt} attempt${attempt === 1 ? '' : 's'}: ${result.error.message}`)
    }
    if (reportParsingError !== undefined) {
      fail(`${surface.label} audit returned invalid JSON (exit ${result.status}): ${reportParsingError.message}; ${String(result.stderr ?? '').trim()}`)
    }
    parseAuditReport(report, surface.label)
  }
  fail(`${surface.label} audit exhausted its bounded execution policy`)
}

export function auditProductionDependencies(root = repositoryRoot) {
  validateManifestLocks(root)
  validateUpdatePolicy(root)
  return dependencySurfaces.map(surface => ({ ...surface, counts: runAudit(surface, root) }))
}

export function auditDevelopmentDependencies(root = repositoryRoot) {
  validateManifestLocks(root)
  validateUpdatePolicy(root)
  return {
    ...developmentDependencySurface,
    counts: runAudit(developmentDependencySurface, root, { omitDevelopment: false }),
  }
}

function main() {
  const invocation = resolveAuditInvocation(process.argv.slice(2))
  const inventory = validateManifestLocks(repositoryRoot)
  validateUpdatePolicy(repositoryRoot)
  if (invocation.kind === 'check') {
    process.stdout.write(`Dependency policy verified: ${inventory.locked} exact npm manifest/lockfile pairs, ${inventory.locklessLocal} exact root-lock-bound local manifest, and bounded npm, GitHub Actions, and Docker update scopes.\n`)
    return
  }
  if (invocation.kind === 'development') {
    const counts = runAudit(invocation.mode.surface, repositoryRoot, {
      omitDevelopment: false,
    })
    process.stdout.write(
      `${invocation.mode.surface.label} full dependency audit verified: ${counts.total} total (${counts.high} high, ${counts.critical} critical).\n`,
    )
    return
  }
  const audits = dependencySurfaces.map(surface => ({ ...surface, counts: runAudit(surface, repositoryRoot) }))
  process.stdout.write(
    `Production dependency audit verified: ${audits.map(({ label, counts }) => `${label} ${counts.total} total (${counts.high} high, ${counts.critical} critical)`).join('; ')}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
