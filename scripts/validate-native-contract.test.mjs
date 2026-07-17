import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  contractPath,
  loadContract,
  validateContract,
  validateReleaseTag,
} from './validate-native-contract.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

function clone(value) {
  return structuredClone(value)
}

test('accepts the closed NATIVE-001 migration contract', () => {
  const contract = validateContract(loadContract())
  assert.equal(contract.state, 'reference-only')
  assert.equal(contract.nativeReleaseReady, false)
  assert.equal(contract.productionBoundary.packageDependencies, 0)
  assert.deepEqual(contract.adapters.map(adapter => adapter.id), [
    'css',
    'scss',
    'sass',
    'less',
    'stylus',
  ])
  assert.equal(fs.realpathSync(contractPath).startsWith(`${repositoryRoot}${path.sep}`), true)
})

test('rejects any widened production runtime boundary', () => {
  for (const [field, value] of [
    ['packageDependencies', 1],
    ['packageOptionalDependencies', 1],
    ['externalLanguageEngines', 1],
    ['compileChildProcesses', 1],
    ['compileNetworkAccess', true],
    ['runtimeDownloads', true],
    ['nonSystemDynamicLanguageLibraries', 1],
  ]) {
    const changed = clone(loadContract())
    changed.productionBoundary[field] = value
    assert.throws(() => validateContract(changed), /production boundary drifted/)
  }
})

test('rejects premature native adapter and release claims', () => {
  const adapterClaim = clone(loadContract())
  adapterClaim.adapters[1].current = 'native-graduated'
  assert.throws(() => validateContract(adapterClaim), /must remain reference-only/)

  const releaseClaim = clone(loadContract())
  releaseClaim.nativeReleaseReady = true
  assert.throws(() => validateContract(releaseClaim), /native release must remain fail-closed/)
})

test('binds the current provider package only as migration reference evidence', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  manifest.dependencies = { ...manifest.dependencies, sass: '^1.101.0' }
  assert.throws(
    () => validateContract(loadContract(), { manifest }),
    /canonical reference dependency graph drifted/,
  )
})

test('release tags fail closed until all native rows graduate', () => {
  const contract = validateContract(loadContract())
  assert.throws(
    () => validateReleaseTag(contract, 'v0.5.0-rc.1'),
    /native frontends are not graduated/,
  )
  assert.throws(() => validateReleaseTag(contract, 'not-a-tag'), /invalid release tag/)
})

test('requires the native interlock before npm publication preflight', () => {
  const releaseWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/release.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), { releaseWorkflow: releaseWorkflow.replace(
      'npm run check:native-contract -- --release-tag "$GITHUB_REF_NAME"',
      'npm run check:version',
    ) }),
    /release workflow is missing/,
  )
})
