import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  auditArguments,
  auditExecutionPolicy,
  auditEnvironment,
  dependencySurfaces,
  developmentAuditModes,
  developmentDependencySurface,
  discoverNpmSurfaces,
  locklessLocalManifestSurfaces,
  parseAuditReport,
  renderDependabotConfig,
  repositoryRoot,
  resolveAuditInvocation,
  runAudit,
  validateLocklessLocalManifests,
  validateManifestLocks,
  validateBuildGraphSecurityPatches,
  validateDevelopmentAuditModes,
  validateExtensionProductionSecurityPatches,
  validateReviewedDevelopmentOracleOverrides,
  validateUpdatePolicy,
} from './audit-production-dependencies.mjs'

const cleanAuditReport = Object.freeze({
  auditReportVersion: 2,
  metadata: Object.freeze({
    vulnerabilities: Object.freeze({ info: 0, low: 1, moderate: 2, high: 0, critical: 0, total: 3 }),
  }),
})

const auditEndpoint = 'https://registry.example.test/-/npm/v1/security/advisories/bulk'
const transientAuditReport = Object.freeze({
  message: `network timeout at: ${auditEndpoint}`,
  method: 'POST',
  uri: auditEndpoint,
})

test('production and development audits have distinct fail-closed scopes', () => {
  assert.equal(validateDevelopmentAuditModes(), true)
  assert.deepEqual(
    developmentAuditModes.map(mode => [mode.script, mode.selector, mode.surface.directory]),
    [
      ['audit:development', '.', '.'],
      ['audit:documentation', 'docs', 'docs'],
      ['audit:turbopack-example', 'examples/next-turbopack', 'examples/next-turbopack'],
      ['audit:sveltekit-example', 'examples/sveltekit', 'examples/sveltekit'],
      ['audit:astro-example', 'examples/astro', 'examples/astro'],
      ['audit:nuxt-example', 'examples/nuxt', 'examples/nuxt'],
      ['audit:vscode', 'vscode-extension', 'vscode-extension'],
    ],
  )
  assert.deepEqual(auditArguments(dependencySurfaces[0]), [
    'audit',
    '--omit=dev',
    '--include=prod',
    '--include=optional',
    '--include=peer',
    '--package-lock-only',
    '--audit-level=high',
    '--json',
  ])
  assert.deepEqual(
    auditArguments(developmentDependencySurface, { omitDevelopment: false }),
    [
      'audit',
      '--include=prod',
      '--include=dev',
      '--include=optional',
      '--include=peer',
      '--package-lock-only',
      '--audit-level=high',
      '--json',
    ],
  )

  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  for (const mode of developmentAuditModes) {
    const suffix = mode.selector === '.' ? '' : ` ${mode.selector}`
    assert.equal(
      manifest.scripts[mode.script],
      `node scripts/audit-production-dependencies.mjs --audit-development${suffix}`,
    )
    const invocation = resolveAuditInvocation([
      '--audit-development',
      ...(mode.selector === '.' ? [] : [mode.selector]),
    ])
    assert.equal(invocation.kind, 'development')
    assert.equal(invocation.mode, mode)
    const args = auditArguments(mode.surface, { omitDevelopment: false })
    assert.ok(args.includes('--include=dev'))
    assert.ok(!args.includes('--omit=dev'))
  }
})

test('audit CLI accepts only exact modes and allowlisted full-graph directories', () => {
  assert.deepEqual(resolveAuditInvocation(['--check']), { kind: 'check' })
  assert.deepEqual(resolveAuditInvocation(['--audit']), { kind: 'production' })
  assert.equal(resolveAuditInvocation(['--audit-development']).mode.selector, '.')
  assert.equal(resolveAuditInvocation(['--audit-development', 'docs']).mode.selector, 'docs')

  for (const invalid of [
    [],
    ['--check', 'extra'],
    ['--audit', 'extra'],
    ['--audit-development', '../docs'],
    ['--audit-development', 'docs', 'extra'],
    ['--unknown'],
  ]) {
    assert.throws(() => resolveAuditInvocation(invalid), /usage:/)
  }
  assert.throws(() => resolveAuditInvocation([42]), /arguments must be strings/)
})

test('documentation and VS Code build graphs lock the reviewed advisory fixes', () => {
  const docsLock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'docs', 'package-lock.json'), 'utf8'))
  const extensionLock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'vscode-extension', 'package-lock.json'), 'utf8'))
  assert.equal(validateBuildGraphSecurityPatches(docsLock, extensionLock), true)

  const vulnerableDocs = structuredClone(docsLock)
  vulnerableDocs.packages['node_modules/browserslist'].version = '4.28.6'
  assert.throws(
    () => validateBuildGraphSecurityPatches(vulnerableDocs, extensionLock),
    /must lock browserslist 4\.28\.8/,
  )

  const vulnerableExtension = structuredClone(extensionLock)
  vulnerableExtension.packages['node_modules/qs'].version = '6.15.3'
  assert.throws(
    () => validateBuildGraphSecurityPatches(docsLock, vulnerableExtension),
    /must lock qs 6\.16\.0/,
  )
})

test('audit environment removes ambient dependency-scope overrides case-insensitively', () => {
  const sanitized = auditEnvironment({
    PATH: '/usr/bin',
    npm_config_registry: 'https://registry.example.test',
    npm_config_omit: 'dev optional',
    NPM_CONFIG_INCLUDE: 'dev',
    Npm_Config_Production: 'true',
    npm_CONFIG_only: 'production',
    NPM_CONFIG_DEV: 'false',
    npm_config_optional: 'false',
    NpM_cOnFiG_pEeR: 'false',
    NoDe_EnV: 'production',
    no_color: '0',
  })

  assert.deepEqual(sanitized, {
    PATH: '/usr/bin',
    npm_config_registry: 'https://registry.example.test',
    no_color: '0',
    NO_COLOR: '1',
  })
  assert.equal(
    Object.keys(sanitized).some(name => [
      'node_env',
      'npm_config_dev',
      'npm_config_include',
      'npm_config_omit',
      'npm_config_only',
      'npm_config_optional',
      'npm_config_peer',
      'npm_config_production',
    ].includes(name.toLowerCase())),
    false,
  )
})

test('all npm manifests have synchronized lockfiles and exact direct versions', () => {
  assert.deepEqual(validateManifestLocks(), { locked: 7, locklessLocal: 1 })
  assert.deepEqual(discoverNpmSurfaces().map(surface => surface.dependabotDirectory), [
    '/',
    '/docs',
    '/examples/next-turbopack',
    '/examples/sveltekit',
    '/examples/astro',
    '/examples/nuxt',
    '/vscode-extension',
  ])
  assert.deepEqual(locklessLocalManifestSurfaces.map(surface => surface.directory), ['examples/parcel'])
  assert.equal(validateLocklessLocalManifests(), 1)
})

test('manifest inventory rejects unpinned direct versions and unowned lockfiles', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-dependency-policy-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const writeSurface = (directory, name, dependencies = {}) => {
    const target = path.join(root, directory)
    fs.mkdirSync(target, { recursive: true })
    const manifest = { name, version: '1.0.0', dependencies }
    fs.writeFileSync(path.join(target, 'package.json'), JSON.stringify(manifest))
    fs.writeFileSync(path.join(target, 'package-lock.json'), JSON.stringify({
      name,
      version: '1.0.0',
      lockfileVersion: 3,
      requires: true,
      packages: { '': manifest },
    }))
  }

  writeSurface('.', 'root', { unsafe: '^1.0.0' })
  writeSurface('docs', 'docs', { zigcss: 'file:..' })
  writeSurface('examples/next-turbopack', 'turbopack-example')
  writeSurface('examples/sveltekit', 'sveltekit-example')
  writeSurface('examples/astro', 'astro-example')
  writeSurface('examples/nuxt', 'nuxt-example')
  writeSurface('vscode-extension', 'extension')
  fs.mkdirSync(path.join(root, 'examples', 'parcel'), { recursive: true })
  fs.writeFileSync(
    path.join(root, 'examples', 'parcel', 'package.json'),
    JSON.stringify(locklessLocalManifestSurfaces[0].manifest),
  )
  assert.throws(() => validateManifestLocks(root), /not an exact version/)

  writeSurface('.', 'root', { safe: '1.0.0' })
  writeSurface('extra', 'extra')
  assert.throws(() => discoverNpmSurfaces(root), /manifest inventory changed/)
})

test('root-lock-bound Parcel manifest stays dependency-free and script-free', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-parcel-manifest-policy-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const directory = path.join(root, 'examples', 'parcel')
  fs.mkdirSync(directory, { recursive: true })
  const exact = structuredClone(locklessLocalManifestSurfaces[0].manifest)
  fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify(exact))
  assert.equal(validateLocklessLocalManifests(root), 1)

  for (const mutation of [
    { ...exact, scripts: { build: 'parcel build' } },
    { ...exact, dependencies: { parcel: '2.16.4' } },
    { ...exact, private: false },
  ]) {
    fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify(mutation))
    assert.throws(
      () => validateLocklessLocalManifests(root),
      /exact dependency-free and script-free local manifest/,
    )
  }
})

test('production audit parsing requires a consistent v2 report with no high or critical findings', () => {
  const clean = structuredClone(cleanAuditReport)
  assert.deepEqual(parseAuditReport(clean, 'fixture'), clean.metadata.vulnerabilities)

  const high = structuredClone(clean)
  high.metadata.vulnerabilities.high = 1
  high.metadata.vulnerabilities.total = 4
  assert.throws(() => parseAuditReport(high, 'fixture'), /1 high and 0 critical/)

  const inconsistent = structuredClone(clean)
  inconsistent.metadata.vulnerabilities.total = 4
  assert.throws(() => parseAuditReport(inconsistent, 'fixture'), /total is inconsistent/)
  assert.throws(() => parseAuditReport({ error: 'offline' }, 'fixture'), /report version 2/)
})

test('audit execution retries one bounded timeout and then validates the report', () => {
  assert.deepEqual(auditExecutionPolicy, {
    maximumAttempts: 2,
    timeoutMilliseconds: 180_000,
  })
  const invocations = []
  const counts = runAudit(dependencySurfaces[1], '/fixture/repository', {
    spawn(command, args, options) {
      invocations.push({ command, args, options })
      if (invocations.length === 1) {
        return { error: Object.assign(new Error('operation timed out'), { code: 'ETIMEDOUT' }) }
      }
      return { error: undefined, status: 0, stdout: JSON.stringify(cleanAuditReport), stderr: '' }
    },
  })

  assert.deepEqual(counts, cleanAuditReport.metadata.vulnerabilities)
  assert.equal(invocations.length, auditExecutionPolicy.maximumAttempts)
  for (const invocation of invocations) {
    assert.equal(invocation.command, 'npm')
    assert.deepEqual(invocation.args, auditArguments(dependencySurfaces[1]))
    assert.equal(invocation.options.cwd, '/fixture/repository')
    assert.equal(invocation.options.timeout, auditExecutionPolicy.timeoutMilliseconds)
    assert.equal(invocation.options.maxBuffer, 16 * 1024 * 1024)
  }
})

test('audit execution stays fail-closed after its bounded timeout retry', () => {
  let invocations = 0
  assert.throws(
    () => runAudit(dependencySurfaces[1], '/fixture/repository', {
      spawn() {
        invocations += 1
        return { error: Object.assign(new Error('operation timed out'), { code: 'ETIMEDOUT' }) }
      },
    }),
    /documentation site audit could not reach the npm audit endpoint after 2 bounded attempts/,
  )
  assert.equal(invocations, auditExecutionPolicy.maximumAttempts)
})

test('audit execution retries only structured transient npm endpoint failures', () => {
  let networkAttempts = 0
  const counts = runAudit(dependencySurfaces[1], '/fixture/repository', {
    omitDevelopment: false,
    spawn(_command, args) {
      networkAttempts += 1
      assert.ok(args.includes('--include=dev'))
      if (networkAttempts === 1) {
        return { error: undefined, status: 1, stdout: JSON.stringify(transientAuditReport), stderr: '' }
      }
      return { error: undefined, status: 0, stdout: JSON.stringify(cleanAuditReport), stderr: '' }
    },
  })
  assert.deepEqual(counts, cleanAuditReport.metadata.vulnerabilities)
  assert.equal(networkAttempts, 2)

  let unavailableAttempts = 0
  const unavailable = { ...transientAuditReport, message: 'service unavailable', statusCode: 503 }
  assert.throws(
    () => runAudit(dependencySurfaces[1], '/fixture/repository', {
      spawn() {
        unavailableAttempts += 1
        return { error: undefined, status: 1, stdout: JSON.stringify(unavailable), stderr: '' }
      },
    }),
    /could not reach the npm audit endpoint after 2 bounded attempts/,
  )
  assert.equal(unavailableAttempts, 2)

  for (const terminal of [
    { ...transientAuditReport, message: 'authentication required', statusCode: 401 },
    { ...transientAuditReport, uri: 'https://registry.example.test/not-the-audit-endpoint', statusCode: 503 },
  ]) {
    let attempts = 0
    assert.throws(
      () => runAudit(dependencySurfaces[1], '/fixture/repository', {
        spawn() {
          attempts += 1
          return { error: undefined, status: 1, stdout: JSON.stringify(terminal), stderr: '' }
        },
      }),
      /did not return npm audit report version 2/,
    )
    assert.equal(attempts, 1)
  }
})

test('audit execution never retries non-timeout failures or invalid reports', () => {
  let executionFailures = 0
  assert.throws(
    () => runAudit(dependencySurfaces[0], '/fixture/repository', {
      spawn() {
        executionFailures += 1
        return { error: Object.assign(new Error('npm is unavailable'), { code: 'ENOENT' }) }
      },
    }),
    /root npm package audit failed to run after 1 attempt: npm is unavailable/,
  )
  assert.equal(executionFailures, 1)

  let invalidReports = 0
  assert.throws(
    () => runAudit(dependencySurfaces[0], '/fixture/repository', {
      spawn() {
        invalidReports += 1
        return { error: undefined, status: 1, stdout: '{', stderr: `network timeout at: ${auditEndpoint}` }
      },
    }),
    /audit returned invalid JSON/,
  )
  assert.equal(invalidReports, 1)

  let vulnerableReports = 0
  const high = structuredClone(cleanAuditReport)
  high.metadata.vulnerabilities.high = 1
  high.metadata.vulnerabilities.total += 1
  Object.assign(high, transientAuditReport, { statusCode: 503 })
  assert.throws(
    () => runAudit(dependencySurfaces[0], '/fixture/repository', {
      spawn() {
        vulnerableReports += 1
        return { error: undefined, status: 1, stdout: JSON.stringify(high), stderr: `network timeout at: ${auditEndpoint}` }
      },
    }),
    /has 1 high and 0 critical audited vulnerabilities/,
  )
  assert.equal(vulnerableReports, 1)

  let unexplainedFailures = 0
  const cleanWithTransientNoise = { ...cleanAuditReport, ...transientAuditReport, statusCode: 503 }
  assert.throws(
    () => runAudit(dependencySurfaces[0], '/fixture/repository', {
      spawn() {
        unexplainedFailures += 1
        return { error: undefined, status: 1, stdout: JSON.stringify(cleanWithTransientNoise), stderr: '' }
      },
    }),
    /audit exited 1 without a high\/critical finding/,
  )
  assert.equal(unexplainedFailures, 1)
})

test('development oracle override is exact and locks the reviewed minimatch security patch', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  assert.equal(validateReviewedDevelopmentOracleOverrides(manifest, lock), true)

  const missing = structuredClone(manifest)
  delete missing.overrides
  assert.throws(
    () => validateReviewedDevelopmentOracleOverrides(missing, lock),
    /overrides must equal/,
  )

  const extra = structuredClone(manifest)
  extra.overrides.unreviewed = '1.0.0'
  assert.throws(
    () => validateReviewedDevelopmentOracleOverrides(extra, lock),
    /overrides must equal/,
  )

  const vulnerable = structuredClone(lock)
  vulnerable.packages['node_modules/brace-expansion'].version = '2.1.2'
  assert.throws(
    () => validateReviewedDevelopmentOracleOverrides(manifest, vulnerable),
    /must lock brace-expansion 5\.0\.9/,
  )

  const detached = structuredClone(lock)
  detached.packages['node_modules/minimatch'].dependencies['brace-expansion'] = '^5.0.8'
  assert.throws(
    () => validateReviewedDevelopmentOracleOverrides(manifest, detached),
    /no longer matches the locked minimatch dependency edge/,
  )
})

test('VS Code production graph locks the reviewed brace-expansion security patch', () => {
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'vscode-extension', 'package-lock.json'), 'utf8'))
  assert.equal(validateExtensionProductionSecurityPatches(lock), true)

  const vulnerable = structuredClone(lock)
  vulnerable.packages['node_modules/brace-expansion'].version = '5.0.8'
  assert.throws(
    () => validateExtensionProductionSecurityPatches(vulnerable),
    /must lock brace-expansion 5\.0\.9/,
  )

  const detached = structuredClone(lock)
  detached.packages['node_modules/minimatch'].dependencies['brace-expansion'] = '^6.0.0'
  assert.throws(
    () => validateExtensionProductionSecurityPatches(detached),
    /no longer matches the locked minimatch dependency edge/,
  )
})

test('Dependabot policy is exact, bounded, and cannot silently gain release authority', () => {
  const expected = renderDependabotConfig()
  assert.equal(fs.readFileSync(path.join(repositoryRoot, '.github/dependabot.yml'), 'utf8'), expected)
  assert.doesNotMatch(expected, /target-branch|registries|reviewers|assignees|automerge/i)
  assert.equal((expected.match(/package-ecosystem:/g) ?? []).length, 3)
  assert.match(expected, /directories:\n      - "\/"\n      - "\/docs"\n      - "\/examples\/next-turbopack"\n      - "\/examples\/sveltekit"\n      - "\/examples\/astro"\n      - "\/examples\/nuxt"\n      - "\/vscode-extension"/)
  assert.equal(validateUpdatePolicy(), true)
})
