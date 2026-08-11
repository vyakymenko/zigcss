import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const dependencySurfaces = [
  { label: 'root npm package', directory: '.', dependabotDirectory: '/' },
  { label: 'documentation site', directory: 'docs', dependabotDirectory: '/docs' },
  { label: 'VS Code extension', directory: 'vscode-extension', dependabotDirectory: '/vscode-extension' },
]

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

function recursiveLockfiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) return []
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) return recursiveLockfiles(entryPath)
    return entry.name === 'package-lock.json' ? [entryPath] : []
  })
}

export function discoverNpmSurfaces(root = repositoryRoot) {
  const discovered = recursiveLockfiles(root).map(file => relative(root, path.dirname(file))).sort()
  const expected = dependencySurfaces.map(surface => surface.directory === '.' ? '' : surface.directory).sort()
  if (JSON.stringify(discovered) !== JSON.stringify(expected)) {
    fail(`npm lockfile inventory changed: expected ${JSON.stringify(expected)}, received ${JSON.stringify(discovered)}`)
  }
  return dependencySurfaces
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
  return dependencySurfaces.length
}

export function renderDependabotConfig() {
  return `version: 2
updates:
  - package-ecosystem: "npm"
    directories:
      - "/"
      - "/docs"
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
  validateReviewedDevelopmentOracleOverrides(manifest, lock)
  validateExtensionProductionSecurityPatches(readJson(path.join(root, 'vscode-extension', 'package-lock.json')))
  if (manifest.scripts?.['test:dependencies'] !== 'node --test scripts/audit-production-dependencies.test.mjs') {
    fail('package.json is missing the exact dependency policy test script')
  }
  if (manifest.scripts?.['audit:production'] !== 'node scripts/audit-production-dependencies.mjs --audit') {
    fail('package.json is missing the exact production audit script')
  }

  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const installs = workflow.indexOf('Install VS Code extension dependencies')
  const dependencyGate = workflow.indexOf('npm run test:dependencies && npm run audit:production')
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
    fail(`${label} has ${normalized.high} high and ${normalized.critical} critical production vulnerabilities`)
  }
  return normalized
}

function runAudit(surface, root) {
  const args = []
  if (surface.directory !== '.') args.push('--prefix', surface.directory)
  args.push('audit', '--omit=dev', '--package-lock-only', '--audit-level=high', '--json')
  const result = spawnSync('npm', args, {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, NO_COLOR: '1' },
    maxBuffer: 16 * 1024 * 1024,
    timeout: 60_000,
  })
  if (result.error) fail(`${surface.label} audit failed to run: ${result.error.message}`)
  let report
  try {
    report = JSON.parse(result.stdout)
  } catch (error) {
    fail(`${surface.label} audit returned invalid JSON (exit ${result.status}): ${error.message}; ${result.stderr.trim()}`)
  }
  const counts = parseAuditReport(report, surface.label)
  if (result.status !== 0) fail(`${surface.label} audit exited ${result.status} without a high/critical finding`)
  return counts
}

export function auditProductionDependencies(root = repositoryRoot) {
  validateManifestLocks(root)
  validateUpdatePolicy(root)
  return dependencySurfaces.map(surface => ({ ...surface, counts: runAudit(surface, root) }))
}

function main() {
  if (process.argv.length !== 3 || !['--check', '--audit'].includes(process.argv[2])) {
    throw new Error('usage: node scripts/audit-production-dependencies.mjs --check|--audit')
  }
  const count = validateManifestLocks(repositoryRoot)
  validateUpdatePolicy(repositoryRoot)
  if (process.argv[2] === '--check') {
    process.stdout.write(`Dependency policy verified: ${count} exact npm manifests/lockfiles and bounded npm, GitHub Actions, and Docker update scopes.\n`)
    return
  }
  const audits = dependencySurfaces.map(surface => ({ ...surface, counts: runAudit(surface, repositoryRoot) }))
  process.stdout.write(
    `Production dependency audit verified: ${audits.map(({ label, counts }) => `${label} ${counts.total} total (${counts.high} high, ${counts.critical} critical)`).join('; ')}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
