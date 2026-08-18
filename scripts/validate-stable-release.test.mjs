import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  readStableReleaseContract,
  readStableReleaseSources,
  validateStableReleaseContract,
} from './validate-stable-release.mjs'

const script = fileURLToPath(new URL('./validate-stable-release.mjs', import.meta.url))

function clone(value) {
  return structuredClone(value)
}

function changedSources(relativePath, transform) {
  const sources = readStableReleaseSources()
  sources.set(relativePath, transform(sources.get(relativePath)))
  return sources
}

test('accepts the finite candidate-ready stable promotion contract', () => {
  assert.deepEqual(
    validateStableReleaseContract(readStableReleaseContract(), readStableReleaseSources()),
    {
      version: '0.6.0',
      tag: 'v0.6.0',
      state: 'candidate-ready',
      verifiedGates: 9,
      totalGates: 10,
    },
  )
  assert.match(
    execFileSync(process.execPath, [script, '--check'], { encoding: 'utf8' }),
    /0\.6\.0 \(candidate-ready\), 9\/10 gates/,
  )
})

test('rejects stable identity, history, channel, target, and gate drift', () => {
  for (const mutate of [
    contract => { contract.candidateVersion = '0.6.1' },
    contract => { contract.candidateTag = 'v0.6.0-rc.2' },
    contract => { contract.previousPrerelease.tag = 'v0.6.0' },
    contract => { contract.claimsPolicy.comparativeClaimsAllowed = true },
    contract => { contract.terminalContract.npmDistTag = 'next' },
    contract => { contract.terminalContract.githubPrerelease = true },
    contract => { contract.terminalContract.targets.pop() },
    contract => { contract.gates[0].state = 'pending'; contract.gates[0].evidence = [] },
    contract => { contract.gates.push(clone(contract.gates[9])) },
  ]) {
    const contract = readStableReleaseContract()
    mutate(contract)
    assert.throws(
      () => validateStableReleaseContract(contract, readStableReleaseSources()),
      /stable release promotion:/,
    )
  }
})

test('binds native prerelease, zero-dependency, benchmark, plan, and workflow evidence', () => {
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('tests/preprocessors/native/contract.json', source => source.replace('"nativeReleaseReady": true', '"nativeReleaseReady": false')),
    ),
    /native release evidence/,
  )
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('package.json', source => source.replace('"dependencies": {},', '"dependencies": {"sass":"1.101.0"},')),
    ),
    /zero production and optional dependencies/,
  )
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('benchmarks/publication.json', source => source.replace('"status": "withdrawn"', '"status": "verified"')),
    ),
    /benchmark publication source status/,
  )
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('README.md', source => `${source}\nThe world's fastest CSS compiler.\n`),
    ),
    /unverified comparative claim/,
  )
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('.github/workflows/release.yml', source => source.replace('npm publish --tag "$RELEASE_CHANNEL" --provenance', 'npm publish --provenance')),
    ),
    /channel-aware npm publication/,
  )
})

test('admits only an exact-main immutable tag after every pre-tag surface is verified', () => {
  const commit = 'a'.repeat(40)
  assert.equal(
    validateStableReleaseContract(
      readStableReleaseContract(),
      readStableReleaseSources(),
      { releaseTag: 'v0.6.0', candidateCommit: commit, originMainCommit: commit },
    ).state,
    'candidate-ready',
  )
  assert.match(
    execFileSync(process.execPath, [
      script,
      '--check',
      '--release-tag', 'v0.6.0',
      '--candidate-commit', commit,
      '--origin-main-commit', commit,
    ], { encoding: 'utf8' }),
    /0\.6\.0 \(candidate-ready\), 9\/10 gates/,
  )
  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      readStableReleaseSources(),
      { releaseTag: 'v0.6.0', candidateCommit: commit, originMainCommit: 'b'.repeat(40) },
    ),
    /must equal origin main commit/,
  )

  const blocked = readStableReleaseContract()
  blocked.state = 'in-progress'
  blocked.stableReleaseReady = false
  blocked.gates[8].state = 'pending'
  blocked.gates[8].evidence = []
  assert.throws(
    () => validateStableReleaseContract(
      blocked,
      readStableReleaseSources(),
      { releaseTag: 'v0.6.0', candidateCommit: commit, originMainCommit: commit },
    ),
    /not release-ready/,
  )
})

test('rejects missing, extra, and prerelease-regressed release sources', () => {
  const missing = readStableReleaseSources()
  missing.delete('README.md')
  assert.throws(
    () => validateStableReleaseContract(readStableReleaseContract(), missing),
    /source inventory drifted/,
  )

  const extra = readStableReleaseSources()
  extra.set('extra', '')
  assert.throws(
    () => validateStableReleaseContract(readStableReleaseContract(), extra),
    /source inventory drifted/,
  )

  assert.throws(
    () => validateStableReleaseContract(
      readStableReleaseContract(),
      changedSources('VERSION', () => '0.6.0-rc.2\n'),
    ),
    /current source VERSION/,
  )
})
