import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  candidateGatePolicy,
  readNextReleaseContract,
  readNextReleaseSources,
  validateNextReleaseContract,
  validateReleaseAdmission,
} from './validate-release-admission.mjs'
import {
  readStableReleaseContract,
  readStableReleaseSources,
} from './validate-stable-release.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const script = path.join(repositoryRoot, 'scripts', 'validate-release-admission.mjs')
const candidateVersion = '0.7.0-rc.1'
const candidateTag = `v${candidateVersion}`
const commit = 'a'.repeat(40)

function clone(value) {
  return structuredClone(value)
}

function candidateSources(version) {
  const sources = readNextReleaseSources()
  const manifest = JSON.parse(sources.get('package.json'))
  const integrity = JSON.parse(sources.get('native-integrity.json'))
  manifest.version = version
  integrity.version = version
  for (const archive of integrity.archives) {
    const extension = archive.target.endsWith('-windows') ? 'zip' : 'tar.gz'
    archive.filename = `zigcss-v${version}-${archive.target}.${extension}`
  }
  sources.set('VERSION', `${version}\n`)
  sources.set('package.json', `${JSON.stringify(manifest, null, 2)}\n`)
  sources.set('native-integrity.json', `${JSON.stringify(integrity, null, 2)}\n`)
  return sources
}

function stableSources(version) {
  const sources = readStableReleaseSources()
  const manifest = JSON.parse(sources.get('package.json'))
  manifest.version = version
  sources.set('VERSION', `${version}\n`)
  sources.set('package.json', `${JSON.stringify(manifest, null, 2)}\n`)
  return sources
}

function readyContract() {
  const contract = readNextReleaseContract()
  contract.state = 'candidate-ready'
  contract.candidateReady = true
  for (const gate of contract.gates.slice(0, -1)) {
    gate.state = 'verified'
    gate.evidence = [`verified evidence for ${gate.id}`]
  }
  return contract
}

test('accepts the canonical evidenced candidate while keeping publication closed', () => {
  const contract = readNextReleaseContract()
  const result = validateReleaseAdmission(
    contract,
    candidateSources('0.6.0'),
    readStableReleaseContract(),
    stableSources('0.6.0'),
  )
  assert.deepEqual(result, {
    activeVersion: '0.6.0',
    candidateReady: false,
    state: 'planned',
    tag: candidateTag,
    totalGates: 8,
    verifiedGates: 5,
    version: candidateVersion,
  })
})

test('refuses the exact planned tag until every pre-tag gate is explicitly verified', () => {
  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      candidateSources(candidateVersion),
      readStableReleaseContract(),
      stableSources(candidateVersion),
      { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: commit },
    ),
    /planned but not publication-ready/,
  )

  const incomplete = readyContract()
  incomplete.gates[2].state = 'pending'
  incomplete.gates[2].evidence = []
  assert.throws(
    () => validateNextReleaseContract(
      incomplete,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /candidate-ready release has an incomplete pre-tag gate/,
  )
})

test('admits only the ready exact candidate on the exact origin main commit', () => {
  const contract = readyContract()
  const sources = candidateSources(candidateVersion)
  const historical = readStableReleaseContract()
  const historicalSources = stableSources(candidateVersion)
  assert.deepEqual(
    validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: commit },
    ),
    {
      activeVersion: candidateVersion,
      candidateReady: true,
      state: 'candidate-ready',
      tag: candidateTag,
      totalGates: 8,
      verifiedGates: 7,
      version: candidateVersion,
    },
  )

  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: 'b'.repeat(40) },
    ),
    /candidate commit must equal the exact origin\/main commit/,
  )
  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: 'not-a-commit', originMainCommit: 'not-a-commit' },
    ),
    /candidate commit must be a canonical lowercase SHA-1/,
  )
  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: 'v0.7.0-rc.2', candidateCommit: commit, originMainCommit: commit },
    ),
    /sole planned candidate v0\.7\.0-rc\.1/,
  )
})

test('rejects every immutable 0.6 tag before considering candidate readiness', () => {
  const contract = readyContract()
  for (const releaseTag of ['v0.6.0-rc.2', 'v0.6.0', 'v0.5.9']) {
    assert.throws(
      () => validateReleaseAdmission(
        contract,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
        stableSources(candidateVersion),
        { releaseTag, candidateCommit: commit, originMainCommit: commit },
      ),
      /historical release tag .* is immutable/,
      releaseTag,
    )
  }
})

test('rejects candidate identity, immutable history, and gate-policy drift', () => {
  for (const mutate of [
    contract => { contract.candidateVersion = '0.7.0-rc.2' },
    contract => { contract.candidateTag = 'v0.7.0' },
    contract => { contract.npmDistTag = 'latest' },
    contract => { contract.githubPrerelease = false },
    contract => { contract.immutableHistory[1].commit = '0'.repeat(40) },
    contract => { contract.preTagSurfaces.reverse() },
    contract => { contract.gates[0].evidenceRequirements = ['we ran something'] },
    contract => { contract.gates.push(clone(contract.gates.at(-1))) },
    contract => { contract.gates[0].state = 'pending' },
    contract => {
      contract.gates[0].state = 'verified'
      contract.gates[0].evidence = [' ']
    },
    contract => {
      for (const gate of contract.gates.slice(0, -1)) {
        gate.state = 'verified'
        gate.evidence = [`verified evidence for ${gate.id}`]
      }
    },
    contract => {
      contract.gates.at(-1).state = 'verified'
      contract.gates.at(-1).evidence = ['publication has not actually happened']
    },
    contract => { contract.unexpected = true },
  ]) {
    const contract = readNextReleaseContract()
    mutate(contract)
    assert.throws(
      () => validateNextReleaseContract(
        contract,
        candidateSources('0.6.0'),
        readStableReleaseContract(),
      ),
      /release admission:/,
    )
  }
  assert.equal(candidateGatePolicy.length, 8)
})

test('requires the immutable 0.6.0 stable contract to remain terminally closed', () => {
  const historical = readStableReleaseContract()
  historical.state = 'candidate-ready'
  historical.packageState = 'in-progress'
  historical.stableReleaseReady = true
  historical.gates.at(-1).state = 'pending'
  historical.gates.at(-1).evidence = []
  historical.publicationEvidence = null

  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      candidateSources('0.6.0'),
      historical,
      stableSources('0.6.0'),
    ),
    /immutable 0\.6\.0 stable evidence must remain closed/,
  )
})

test('rejects incomplete, divergent, or unbounded active source inputs', () => {
  const incomplete = candidateSources(candidateVersion)
  incomplete.delete('native-integrity.json')
  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      incomplete,
      readStableReleaseContract(),
      stableSources(candidateVersion),
    ),
    /active release source inventory/,
  )

  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      {},
      readStableReleaseContract(),
      stableSources(candidateVersion),
    ),
    /active release sources must be a Map/,
  )

  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      candidateSources(candidateVersion),
      readStableReleaseContract(),
      stableSources('0.6.0'),
    ),
    /observed different active VERSION bytes/,
  )

  const divergentPackage = candidateSources(candidateVersion)
  const manifest = JSON.parse(divergentPackage.get('package.json'))
  manifest.description = 'divergent package bytes'
  divergentPackage.set('package.json', `${JSON.stringify(manifest, null, 2)}\n`)
  assert.throws(
    () => validateReleaseAdmission(
      readNextReleaseContract(),
      divergentPackage,
      readStableReleaseContract(),
      stableSources(candidateVersion),
    ),
    /observed different active package\.json bytes/,
  )

  assert.throws(
    () => validateNextReleaseContract(
      readNextReleaseContract(),
      candidateSources('0.7.0-rc.2'),
      readStableReleaseContract(),
    ),
    /active source version must remain 0\.6\.0 or advance exactly to 0\.7\.0-rc\.1/,
  )
})

test('publication-ready state requires synchronized candidate package and integrity bytes', () => {
  const contract = readyContract()
  assert.throws(
    () => validateNextReleaseContract(
      contract,
      candidateSources('0.6.0'),
      readStableReleaseContract(),
    ),
    /publication-ready active version must be "0\.7\.0-rc\.1"/,
  )

  const mismatched = candidateSources(candidateVersion)
  const integrity = JSON.parse(mismatched.get('native-integrity.json'))
  integrity.version = '0.6.0'
  mismatched.set('native-integrity.json', `${JSON.stringify(integrity, null, 2)}\n`)
  assert.throws(
    () => validateNextReleaseContract(contract, mismatched, readStableReleaseContract()),
    /manifest version must be 0\.7\.0-rc\.1/,
  )
})

test('the CLI validates static policy and rejects the still-planned real candidate', () => {
  const staticResult = spawnSync(process.execPath, [script, '--check'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.equal(staticResult.status, 0, staticResult.stderr)
  assert.match(staticResult.stdout, /v0\.7\.0-rc\.1 is planned, candidateReady=false/)

  const releaseResult = spawnSync(process.execPath, [
    script,
    '--check',
    '--release-tag', candidateTag,
    '--candidate-commit', commit,
    '--origin-main-commit', commit,
  ], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.notEqual(releaseResult.status, 0)
  assert.equal(releaseResult.stdout, '')
  assert.match(releaseResult.stderr, /planned but not publication-ready/)
})

test('the on-disk candidate contract is bounded canonical JSON', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-admission-'))
  try {
    fs.mkdirSync(path.join(temporary, 'release'))
    const contract = readNextReleaseContract()
    fs.writeFileSync(
      path.join(temporary, 'release', 'next-release.json'),
      `${JSON.stringify(contract)}\n`,
    )
    assert.throws(
      () => readNextReleaseContract(temporary),
      /must use the canonical JSON representation/,
    )

    fs.writeFileSync(
      path.join(temporary, 'release', 'next-release.json'),
      Buffer.concat([
        Buffer.from('{"invalid":"'),
        Buffer.from([0xff]),
        Buffer.from('"}\n'),
      ]),
    )
    assert.throws(
      () => readNextReleaseContract(temporary),
      /is not valid UTF-8/,
    )

    fs.writeFileSync(
      path.join(temporary, 'release', 'next-release.json'),
      `${' '.repeat((64 * 1024) + 1)}\n`,
    )
    assert.throws(
      () => readNextReleaseContract(temporary),
      /bounded regular non-symlink file/,
    )

    fs.rmSync(path.join(temporary, 'release', 'next-release.json'))
    fs.symlinkSync(
      path.join(repositoryRoot, 'release', 'next-release.json'),
      path.join(temporary, 'release', 'next-release.json'),
    )
    assert.throws(
      () => readNextReleaseContract(temporary),
      /bounded regular non-symlink file/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
