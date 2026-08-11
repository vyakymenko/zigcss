import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  discoverNpmSurfaces,
  parseAuditReport,
  renderDependabotConfig,
  repositoryRoot,
  validateManifestLocks,
  validateExtensionProductionSecurityPatches,
  validateReviewedDevelopmentOracleOverrides,
  validateUpdatePolicy,
} from './audit-production-dependencies.mjs'

test('all npm manifests have synchronized lockfiles and exact direct versions', () => {
  assert.equal(validateManifestLocks(), 3)
  assert.deepEqual(discoverNpmSurfaces().map(surface => surface.dependabotDirectory), [
    '/',
    '/docs',
    '/vscode-extension',
  ])
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
  writeSurface('vscode-extension', 'extension')
  assert.throws(() => validateManifestLocks(root), /not an exact version/)

  writeSurface('.', 'root', { safe: '1.0.0' })
  writeSurface('extra', 'extra')
  assert.throws(() => discoverNpmSurfaces(root), /lockfile inventory changed/)
})

test('production audit parsing requires a consistent v2 report with no high or critical findings', () => {
  const clean = {
    auditReportVersion: 2,
    metadata: { vulnerabilities: { info: 0, low: 1, moderate: 2, high: 0, critical: 0, total: 3 } },
  }
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
  assert.match(expected, /directories:\n      - "\/"\n      - "\/docs"\n      - "\/vscode-extension"/)
  assert.equal(validateUpdatePolicy(), true)
})
