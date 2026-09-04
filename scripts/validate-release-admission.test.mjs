import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  candidateGatePolicy,
  publicationApprovalPolicy,
  readNextReleaseContract,
  readNextReleaseSources,
  validateNextReleaseContract,
  validateReleaseAdmission,
} from './validate-release-admission.mjs'
import {
  readStableReleaseContract,
  readStableReleaseSources,
} from './validate-stable-release.mjs'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const script = path.join(repositoryRoot, 'scripts', 'validate-release-admission.mjs')
const candidateVersion = '0.7.0-rc.1'
const candidateTag = `v${candidateVersion}`
const commit = 'a'.repeat(40)
const finalBuildRunId = 39_999_999_999

function clone(value) {
  return structuredClone(value)
}

function originIntegrationEvidence(
  description = 'Candidate-ready policy records no commit hash; tag admission compares the peeled runtime candidate commit with a fresh origin/main readback.',
) {
  return [
    description,
    'Repository ruleset 22261144 Protect release tags read back active for target tag including refs/tags/v* with exact update and deletion rules, bypass_actors=[], current_user_can_bypass=never.',
    'Repository immutable releases setting read back enabled=true and enforced_by_owner=false before tag creation at 2026-09-04T10:03:00Z; the immutable-release environment blocks create-release until its required reviewer repeats the live read immediately before approval.',
  ]
}

function hostedValidationEvidence(
  description = `Build run ${finalBuildRunId} completed success for the pre-admission checkpoint at 2026-09-04T09:00:00Z; the Release workflow revalidates the exact runtime candidate commit.`,
  codeQl = 'CodeQL default setup passed for the pre-admission checkpoint at 2026-09-04T09:05:00Z: Actions, JavaScript/TypeScript, and Ruby; error=0; warning=0; open alerts=0; security-events: read; same commit Build and CodeQL are enforced for the exact runtime candidate commit by the Release workflow.',
) {
  return [
    description,
    codeQl,
  ]
}

function terminalHostedValidationEvidence(
  description = `Build run ${finalBuildRunId} succeeded for exact candidate commit ${commit}`,
) {
  return hostedValidationEvidence(
    description,
    `CodeQL default setup passed on the same commit ${commit}: Actions, JavaScript/TypeScript, and Ruby; error=0; warning=0; open alerts=0; security-events: read.`,
  )
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
  contract.gates.find(gate => gate.id === 'hosted-validation').evidence = hostedValidationEvidence()
  contract.gates.find(gate => gate.id === 'origin-main-integration').evidence = originIntegrationEvidence()
  return contract
}

function publicationEvidence() {
  return {
    tagCommit: commit,
    finalBuildEvidence: {
      workflow: 'Build',
      commit,
      runId: finalBuildRunId,
      runAttempt: 1,
      conclusion: 'success',
      completedAt: '2026-09-04T12:00:00Z',
    },
    workflowRunId: 40_000_000_001,
    workflowAttempt: 1,
    workflowConclusion: 'success',
    workflowCompletedAt: '2026-09-04T12:34:56Z',
    githubReleaseId: 400_000_001,
    githubReleaseUrl: `https://github.com/vyakymenko/zigcss/releases/tag/${candidateTag}`,
    githubPrerelease: true,
    githubDraft: false,
    githubImmutable: true,
    githubReleaseAttestation: 'verified',
    githubPublishedAt: '2026-09-04T12:34:00Z',
    githubAssetCount: 25,
    githubAssetBytes: 20_000_000,
    githubAssetInventorySha256: 'b'.repeat(64),
    assetsPerTarget: 5,
    npmVersion: candidateVersion,
    npmDistTag: 'next',
    npmLatest: '0.6.0',
    npmNext: candidateVersion,
    npmFileCount: expectedPackedFiles.length,
    npmUnpackedSize: 250_000,
    npmIntegrity: `sha512-${Buffer.alloc(64, 7).toString('base64')}`,
    npmShasum: 'c'.repeat(40),
    npmProvenancePredicateType: 'https://slsa.dev/provenance/v1',
    anonymousInstall: 'verified-five-syntaxes',
  }
}

function closedContract() {
  const contract = readyContract()
  contract.schemaVersion = 2
  contract.state = 'closed'
  contract.candidateReady = false
  contract.gates.find(gate => gate.id === 'origin-main-integration').evidence = originIntegrationEvidence(
    `origin/main and the candidate tag commit are ${commit}`,
  )
  contract.gates.find(gate => gate.id === 'hosted-validation').evidence = terminalHostedValidationEvidence(
    `Build run ${finalBuildRunId} succeeded for exact candidate commit ${commit}`,
  )
  contract.gates.at(-1).state = 'verified'
  contract.gates.at(-1).evidence = [
    `Release run 40000000001 completed for ${candidateVersion} at ${commit}; immutable GitHub release 400000001 and its release attestation are verified; npm next serves ${candidateVersion}.`,
  ]
  contract.publicationEvidence = publicationEvidence()
  return contract
}

function failedPublicationEvidence({
  githubState = 'absent',
  npmState = 'absent',
  includeFinalBuild = true,
  draftAssetCount = 0,
} = {}) {
  const githubSurface = {
    state: githubState,
    releaseId: null,
    releaseUrl: null,
    publishedAt: null,
    assetCount: 0,
    assetBytes: 0,
    assetInventorySha256: null,
    releaseAttestation: 'absent',
  }
  if (githubState === 'draft') {
    githubSurface.releaseId = 400_000_001
    githubSurface.assetCount = draftAssetCount
    if (draftAssetCount > 0) {
      githubSurface.assetBytes = 4_000_000
      githubSurface.assetInventorySha256 = 'b'.repeat(64)
    }
  } else if (githubState === 'immutable-published') {
    Object.assign(githubSurface, {
      releaseId: 400_000_001,
      releaseUrl: `https://github.com/vyakymenko/zigcss/releases/tag/${candidateTag}`,
      publishedAt: '2026-09-04T12:30:00Z',
      assetCount: 25,
      assetBytes: 20_000_000,
      assetInventorySha256: 'b'.repeat(64),
      releaseAttestation: 'verified',
    })
  }

  const npmSurface = {
    state: npmState,
    version: candidateVersion,
    distTag: 'next',
    latest: '0.6.0',
    next: npmState === 'published-exact' ? candidateVersion : '0.6.0-rc.2',
    fileCount: 0,
    unpackedSize: 0,
    integrity: null,
    shasum: null,
    provenancePredicateType: null,
    anonymousInstall: 'not-run',
  }
  if (npmState === 'published-exact') {
    Object.assign(npmSurface, {
      fileCount: expectedPackedFiles.length,
      unpackedSize: 250_000,
      integrity: `sha512-${Buffer.alloc(64, 7).toString('base64')}`,
      shasum: 'c'.repeat(40),
      provenancePredicateType: 'https://slsa.dev/provenance/v1',
      anonymousInstall: 'failed',
    })
  }

  return {
    tagCommit: commit,
    finalBuildEvidence: includeFinalBuild
      ? {
          workflow: 'Build',
          commit,
          runId: finalBuildRunId,
          runAttempt: 1,
          conclusion: 'success',
          completedAt: '2026-09-04T12:00:00Z',
        }
      : null,
    releaseWorkflowEvidence: {
      workflow: 'Release',
      commit,
      runId: 40_000_000_002,
      runAttempt: 1,
      conclusion: 'failure',
      completedAt: '2026-09-04T12:34:56Z',
    },
    githubSurface,
    npmSurface,
  }
}

function failedContract(options = {}) {
  const contract = readyContract()
  const failure = failedPublicationEvidence(options)
  const verifiedPreTagGates = options.verifiedPreTagGates ?? 7
  assert.ok(Number.isInteger(verifiedPreTagGates) && verifiedPreTagGates >= 5 && verifiedPreTagGates <= 7)
  for (const gate of contract.gates.slice(verifiedPreTagGates, -1)) {
    gate.state = 'pending'
    gate.evidence = []
  }
  contract.schemaVersion = 3
  contract.state = 'publication-failed'
  contract.candidateReady = false
  const originMain = contract.gates.find(gate => gate.id === 'origin-main-integration')
  if (originMain.state === 'verified') {
    originMain.evidence = originIntegrationEvidence(
      `origin/main and the failed tag commit are ${commit}`,
    )
  }
  const hostedValidation = contract.gates.find(gate => gate.id === 'hosted-validation')
  if (hostedValidation.state === 'verified') {
    hostedValidation.evidence = terminalHostedValidationEvidence(
      `Build run ${finalBuildRunId} succeeded for exact candidate commit ${commit}`,
    )
  }
  contract.gates.at(-1).state = 'failed'
  contract.gates.at(-1).evidence = [
    `Release run ${failure.releaseWorkflowEvidence.runId} failed with ${failure.releaseWorkflowEvidence.conclusion} at ${commit}; GitHub surface ${failure.githubSurface.state}; npm surface ${failure.npmSurface.state}.`,
  ]
  contract.publicationFailureEvidence = failure
  return contract
}

test('accepts the canonical evidenced candidate while keeping publication closed', () => {
  const contract = readNextReleaseContract()
  assert.deepEqual(contract.publicationApproval, publicationApprovalPolicy)
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
    /is planned and not publication-ready/,
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
  assert.doesNotThrow(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      {
        releaseTag: candidateTag,
        candidateCommit: 'b'.repeat(40),
        originMainCommit: 'b'.repeat(40),
      },
    ),
  )
  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: 'not-a-commit', originMainCommit: 'not-a-commit' },
    ),
    /candidate commit must be a nonzero canonical lowercase SHA-1/,
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

test('candidate admission binds same-commit CodeQL and protected release-tag interlocks', () => {
  const missingCodeQl = readyContract()
  missingCodeQl.gates.find(gate => gate.id === 'hosted-validation').evidence = [
    'Hosted Build evidence recorded',
  ]
  assert.throws(
    () => validateNextReleaseContract(
      missingCodeQl,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /hosted-validation evidence must reference same-commit CodeQL interlock/,
  )

  const missingTagProtection = readyContract()
  missingTagProtection.gates.find(gate => gate.id === 'origin-main-integration').evidence = [
    'origin/main integration policy recorded without a commit hash',
  ]
  assert.throws(
    () => validateNextReleaseContract(
      missingTagProtection,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /origin-main-integration evidence must reference protected release-tag interlock/,
  )

  for (const gateId of ['hosted-validation', 'origin-main-integration']) {
    const selfReferential = readyContract()
    selfReferential.gates.find(gate => gate.id === gateId).evidence.push(
      `Candidate-ready contract commit ${commit}`,
    )
    assert.throws(
      () => validateNextReleaseContract(
        selfReferential,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
      ),
      new RegExp(`${gateId} candidate-ready evidence must not embed a commit hash`),
    )
  }
})

test('candidate-ready contract can be committed without a self-referential commit hash', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-candidate-ready-'))
  try {
    const contract = readyContract()
    const filename = path.join(temporary, 'next-release.json')
    fs.writeFileSync(filename, `${JSON.stringify(contract, null, 2)}\n`)

    for (const args of [
      ['init', '--quiet'],
      ['config', 'user.name', 'zigcss release test'],
      ['config', 'user.email', 'release-test@invalid.example'],
      ['add', 'next-release.json'],
      ['commit', '--quiet', '-m', 'Record candidate-ready evidence'],
    ]) {
      const result = spawnSync('git', args, { cwd: temporary, encoding: 'utf8' })
      assert.equal(result.status, 0, result.stderr)
    }
    const headResult = spawnSync('git', ['rev-parse', 'HEAD'], {
      cwd: temporary,
      encoding: 'utf8',
    })
    assert.equal(headResult.status, 0, headResult.stderr)
    const committedHead = headResult.stdout.trim()
    assert.match(committedHead, /^[0-9a-f]{40}$/)

    const committedContract = JSON.parse(fs.readFileSync(filename, 'utf8'))
    for (const gateId of ['hosted-validation', 'origin-main-integration']) {
      const evidence = committedContract.gates.find(gate => gate.id === gateId).evidence.join('\n')
      assert.doesNotMatch(evidence, /\b[0-9a-f]{40}\b/)
      assert.equal(evidence.includes(committedHead), false)
    }
    assert.doesNotThrow(() => validateReleaseAdmission(
      committedContract,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
      stableSources(candidateVersion),
      {
        releaseTag: candidateTag,
        candidateCommit: committedHead,
        originMainCommit: committedHead,
      },
    ))
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('accepts a schema-2 closed publication and permanently closes tag admission', () => {
  const contract = closedContract()
  const sources = candidateSources(candidateVersion)
  const historical = readStableReleaseContract()
  const historicalSources = stableSources(candidateVersion)

  assert.deepEqual(
    validateReleaseAdmission(contract, sources, historical, historicalSources),
    {
      activeVersion: candidateVersion,
      candidateReady: false,
      state: 'closed',
      tag: candidateTag,
      totalGates: 8,
      verifiedGates: 8,
      version: candidateVersion,
    },
  )
  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      historical,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: commit },
    ),
    /is closed and not publication-ready/,
  )
})

test('accepts exhaustive publication-failed terminals for every reachable public-surface state', () => {
  const variants = [
    { githubState: 'absent', npmState: 'absent', includeFinalBuild: false, verifiedPreTagGates: 5 },
    { githubState: 'absent', npmState: 'absent', includeFinalBuild: true, verifiedPreTagGates: 5 },
    { githubState: 'absent', npmState: 'absent', includeFinalBuild: true, verifiedPreTagGates: 6 },
    { githubState: 'draft', npmState: 'absent', draftAssetCount: 0 },
    { githubState: 'draft', npmState: 'absent', draftAssetCount: 12 },
    { githubState: 'draft', npmState: 'absent', draftAssetCount: 26 },
    { githubState: 'immutable-published', npmState: 'absent' },
    { githubState: 'immutable-published', npmState: 'published-exact' },
  ]
  for (const options of variants) {
    const contract = failedContract(options)
    assert.deepEqual(
      validateReleaseAdmission(
        contract,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
        stableSources(candidateVersion),
      ),
      {
        activeVersion: candidateVersion,
        candidateReady: false,
        state: 'publication-failed',
        tag: candidateTag,
        totalGates: 8,
        verifiedGates: options.verifiedPreTagGates ?? 7,
        version: candidateVersion,
      },
      JSON.stringify(options),
    )
    assert.throws(
      () => validateReleaseAdmission(
        contract,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
        stableSources(candidateVersion),
        { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: commit },
      ),
      /is publication-failed and not publication-ready/,
      JSON.stringify(options),
    )
  }
})

test('publication-failed evidence rejects successful conclusions, impossible surfaces, and partial digest drift', () => {
  const mutations = [
    contract => { delete contract.publicationFailureEvidence.githubSurface.state },
    contract => { contract.publicationFailureEvidence.unexpected = true },
    contract => { contract.publicationFailureEvidence.tagCommit = '0'.repeat(40) },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.workflow = 'Build' },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.commit = 'b'.repeat(40) },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.runId = 0 },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.runAttempt = 1001 },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.conclusion = 'success' },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.conclusion = 'neutral' },
    contract => { contract.publicationFailureEvidence.releaseWorkflowEvidence.completedAt = '2026-02-30T00:00:00Z' },
    contract => { contract.publicationFailureEvidence.githubSurface.state = 'published' },
    contract => { contract.publicationFailureEvidence.githubSurface.releaseId = 1 },
    contract => { contract.publicationFailureEvidence.githubSurface.assetCount = 1 },
    contract => { contract.publicationFailureEvidence.npmSurface.state = 'published' },
    contract => { contract.publicationFailureEvidence.npmSurface.next = candidateVersion },
    contract => { contract.publicationFailureEvidence.npmSurface.fileCount = 1 },
    contract => { contract.publicationFailureEvidence.npmSurface.anonymousInstall = 'verified-five-syntaxes' },
    contract => { contract.gates.at(-1).evidence = [`Release run 40000000002 failure at ${commit}; GitHub surface absent.`] },
    contract => { contract.gates.at(-1).evidence = [`Release workflow succeeded at ${commit}; GitHub surface absent; npm surface absent; run 40000000002.`] },
    contract => { contract.gates.at(-1).evidence = [`Release succeeded at ${commit}; GitHub surface absent; npm surface absent; run 40000000002 failure.`] },
    contract => { contract.gates.find(gate => gate.id === 'origin-main-integration').evidence = originIntegrationEvidence('origin/main integrated') },
  ]
  for (const mutate of mutations) {
    const contract = failedContract()
    mutate(contract)
    assert.throws(
      () => validateNextReleaseContract(
        contract,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
      ),
      /release admission:/,
    )
  }

  const draftMutations = [
    contract => { contract.publicationFailureEvidence.githubSurface.assetCount = 1001 },
    contract => { contract.publicationFailureEvidence.githubSurface.assetBytes = 1 },
    contract => { contract.publicationFailureEvidence.githubSurface.assetInventorySha256 = 'b'.repeat(64) },
    contract => { contract.publicationFailureEvidence.githubSurface.releaseAttestation = 'verified' },
  ]
  for (const mutate of draftMutations) {
    const contract = failedContract({ githubState: 'draft', npmState: 'absent' })
    mutate(contract)
    assert.throws(
      () => validateNextReleaseContract(contract, candidateSources(candidateVersion), readStableReleaseContract()),
      /release admission:/,
    )
  }

  const publishedMutations = [
    contract => { contract.publicationFailureEvidence.githubSurface.assetCount = 24 },
    contract => { contract.publicationFailureEvidence.githubSurface.assetInventorySha256 = '0'.repeat(64) },
    contract => { contract.publicationFailureEvidence.githubSurface.releaseAttestation = 'absent' },
    contract => { contract.publicationFailureEvidence.npmSurface.fileCount = expectedPackedFiles.length - 1 },
    contract => { contract.publicationFailureEvidence.npmSurface.unpackedSize = (4 * 1024 * 1024) + 1 },
    contract => { contract.publicationFailureEvidence.npmSurface.integrity = 'sha512-invalid' },
    contract => { contract.publicationFailureEvidence.npmSurface.shasum = '0'.repeat(40) },
    contract => { contract.publicationFailureEvidence.npmSurface.provenancePredicateType = null },
    contract => { contract.publicationFailureEvidence.npmSurface.anonymousInstall = 'verified-five-syntaxes' },
  ]
  for (const mutate of publishedMutations) {
    const contract = failedContract({ githubState: 'immutable-published', npmState: 'published-exact' })
    mutate(contract)
    assert.throws(
      () => validateNextReleaseContract(contract, candidateSources(candidateVersion), readStableReleaseContract()),
      /release admission:/,
    )
  }

  const impossible = failedContract({ githubState: 'absent', npmState: 'published-exact' })
  assert.throws(
    () => validateNextReleaseContract(impossible, candidateSources(candidateVersion), readStableReleaseContract()),
    /published npm failure GitHub surface state/,
  )

  const missingVerifiedBuild = failedContract({ includeFinalBuild: false })
  assert.throws(
    () => validateNextReleaseContract(
      missingVerifiedBuild,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /finalBuildEvidence is required when hosted-validation is verified/,
  )

  const regressedEvidence = failedContract({ verifiedPreTagGates: 5, includeFinalBuild: false })
  regressedEvidence.gates[4].state = 'pending'
  regressedEvidence.gates[4].evidence = []
  assert.throws(
    () => validateNextReleaseContract(
      regressedEvidence,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /publication-failed release requires documentation-validation to be verified/,
  )

  const outOfOrderEvidence = failedContract({ verifiedPreTagGates: 5, includeFinalBuild: false })
  outOfOrderEvidence.gates[6].state = 'verified'
  outOfOrderEvidence.gates[6].evidence = originIntegrationEvidence(
    `origin/main and the failed tag commit are ${commit}`,
  )
  assert.throws(
    () => validateNextReleaseContract(
      outOfOrderEvidence,
      candidateSources(candidateVersion),
      readStableReleaseContract(),
    ),
    /publication-failed release pre-tag evidence is out of order/,
  )
})

test('binds schema versions to exact planned, candidate-ready, closed, and publication-failed phases', () => {
  const stable = readStableReleaseContract()

  const plannedWithTerminalGate = readNextReleaseContract()
  plannedWithTerminalGate.gates[5].state = 'verified'
  plannedWithTerminalGate.gates[5].evidence = ['hosted evidence arrived out of phase']
  assert.throws(
    () => validateNextReleaseContract(plannedWithTerminalGate, candidateSources(candidateVersion), stable),
    /planned candidate requires hosted-validation to be pending/,
  )

  const readyV2 = readyContract()
  readyV2.schemaVersion = 2
  readyV2.publicationEvidence = publicationEvidence()
  assert.throws(
    () => validateNextReleaseContract(readyV2, candidateSources(candidateVersion), stable),
    /schemaVersion 2 state must be "closed"/,
  )

  const closedV1 = closedContract()
  closedV1.schemaVersion = 1
  delete closedV1.publicationEvidence
  assert.throws(
    () => validateNextReleaseContract(closedV1, candidateSources(candidateVersion), stable),
    /schemaVersion 1 state must be planned or candidate-ready/,
  )

  const readyWithEvidence = readyContract()
  readyWithEvidence.publicationEvidence = publicationEvidence()
  assert.throws(
    () => validateNextReleaseContract(readyWithEvidence, candidateSources(candidateVersion), stable),
    /next release contract schema 1 keys/,
  )

  const failedV2 = failedContract()
  failedV2.schemaVersion = 2
  failedV2.publicationEvidence = publicationEvidence()
  delete failedV2.publicationFailureEvidence
  assert.throws(
    () => validateNextReleaseContract(failedV2, candidateSources(candidateVersion), stable),
    /schemaVersion 2 state must be "closed"/,
  )

  const failedWithVerifiedTerminal = failedContract()
  failedWithVerifiedTerminal.gates.at(-1).state = 'verified'
  assert.throws(
    () => validateNextReleaseContract(failedWithVerifiedTerminal, candidateSources(candidateVersion), stable),
    /publication-failed release requires tag-workflow-publication to be failed/,
  )

  const failedWithSuccessEvidence = failedContract()
  failedWithSuccessEvidence.publicationEvidence = publicationEvidence()
  assert.throws(
    () => validateNextReleaseContract(failedWithSuccessEvidence, candidateSources(candidateVersion), stable),
    /next release contract schema 3 keys/,
  )
})

test('closed publication evidence rejects shape, identity, channel, provenance, and bound drift', () => {
  const mutations = [
    contract => { delete contract.publicationEvidence.npmShasum },
    contract => { contract.publicationEvidence.unexpected = true },
    contract => { contract.publicationEvidence.tagCommit = contract.closedHistory[0].commit },
    contract => { contract.publicationEvidence.tagCommit = '0'.repeat(40) },
    contract => { delete contract.publicationEvidence.finalBuildEvidence.runId },
    contract => { contract.publicationEvidence.finalBuildEvidence.unexpected = true },
    contract => { contract.publicationEvidence.finalBuildEvidence.workflow = 'Release' },
    contract => { contract.publicationEvidence.finalBuildEvidence.commit = 'b'.repeat(40) },
    contract => { contract.publicationEvidence.finalBuildEvidence.commit = '0'.repeat(40) },
    contract => { contract.publicationEvidence.finalBuildEvidence.runId = 0 },
    contract => { contract.publicationEvidence.finalBuildEvidence.runAttempt = 1001 },
    contract => { contract.publicationEvidence.finalBuildEvidence.conclusion = 'failure' },
    contract => { contract.publicationEvidence.finalBuildEvidence.completedAt = '2026-09-04T12:34:30Z' },
    contract => { contract.publicationEvidence.finalBuildEvidence.completedAt = '2026-09-04T12:35:00Z' },
    contract => { contract.publicationEvidence.workflowRunId = 0 },
    contract => { contract.publicationEvidence.workflowAttempt = 1001 },
    contract => { contract.publicationEvidence.workflowConclusion = 'failure' },
    contract => { contract.publicationEvidence.workflowCompletedAt = '2026-02-30T00:00:00Z' },
    contract => { contract.publicationEvidence.githubReleaseId = 0 },
    contract => { contract.publicationEvidence.githubReleaseUrl += '?draft=true' },
    contract => { contract.publicationEvidence.githubPrerelease = false },
    contract => { contract.publicationEvidence.githubDraft = true },
    contract => { contract.publicationEvidence.githubImmutable = false },
    contract => { contract.publicationEvidence.githubReleaseAttestation = 'missing' },
    contract => { contract.publicationEvidence.githubPublishedAt = '2026-09-04T12:35:00Z' },
    contract => { contract.publicationEvidence.githubAssetCount = 24 },
    contract => { contract.publicationEvidence.githubAssetBytes = (1024 * 1024 * 1024) + 1 },
    contract => { contract.publicationEvidence.githubAssetInventorySha256 = 'B'.repeat(64) },
    contract => { contract.publicationEvidence.githubAssetInventorySha256 = '0'.repeat(64) },
    contract => { contract.publicationEvidence.assetsPerTarget = 4 },
    contract => { contract.publicationEvidence.npmVersion = '0.7.0-rc.2' },
    contract => { contract.publicationEvidence.npmDistTag = 'latest' },
    contract => { contract.publicationEvidence.npmLatest = candidateVersion },
    contract => { contract.publicationEvidence.npmNext = '0.6.0-rc.2' },
    contract => { contract.publicationEvidence.npmFileCount = expectedPackedFiles.length - 1 },
    contract => { contract.publicationEvidence.npmFileCount = expectedPackedFiles.length + 1 },
    contract => { contract.publicationEvidence.npmUnpackedSize = (4 * 1024 * 1024) + 1 },
    contract => { contract.publicationEvidence.npmIntegrity = 'sha512-invalid' },
    contract => { contract.publicationEvidence.npmIntegrity = `sha512-${Buffer.alloc(64).toString('base64')}` },
    contract => { contract.publicationEvidence.npmShasum = 'C'.repeat(40) },
    contract => { contract.publicationEvidence.npmShasum = '0'.repeat(40) },
    contract => { contract.publicationEvidence.npmProvenancePredicateType = 'https://slsa.dev/provenance/v0.2' },
    contract => { contract.publicationEvidence.anonymousInstall = 'not-run' },
    contract => { contract.gates.at(-1).evidence = ['publication happened'] },
    contract => { contract.gates.find(gate => gate.id === 'hosted-validation').evidence = terminalHostedValidationEvidence(`Build succeeded for ${commit}`) },
    contract => {
      const evidence = terminalHostedValidationEvidence(`Build run ${finalBuildRunId} succeeded`)
      evidence[1] = evidence[1].replace(commit, 'b'.repeat(40))
      contract.gates.find(gate => gate.id === 'hosted-validation').evidence = evidence
    },
    contract => { contract.gates.find(gate => gate.id === 'hosted-validation').evidence = terminalHostedValidationEvidence(`Workflow run ${finalBuildRunId} succeeded for ${commit}`) },
    contract => { contract.gates.find(gate => gate.id === 'origin-main-integration').evidence = originIntegrationEvidence('origin/main integrated') },
  ]
  for (const [index, mutate] of mutations.entries()) {
    const contract = closedContract()
    mutate(contract)
    assert.throws(
      () => validateNextReleaseContract(
        contract,
        candidateSources(candidateVersion),
        readStableReleaseContract(),
      ),
      /release admission:/,
      `closed evidence mutation ${index} must fail closed`,
    )
  }
})

test('rejects every closed 0.6 tag before considering candidate readiness', () => {
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
      /historical release tag .* is closed/,
      releaseTag,
    )
  }
})

test('rejects candidate identity, closed history, approval policy, and gate-policy drift', () => {
  for (const mutate of [
    contract => { contract.candidateVersion = '0.7.0-rc.2' },
    contract => { contract.candidateTag = 'v0.7.0' },
    contract => { contract.npmDistTag = 'latest' },
    contract => { contract.githubPrerelease = false },
    contract => { contract.closedHistory[1].commit = '0'.repeat(40) },
    contract => { contract.closedHistory[0].githubImmutable = true },
    contract => { contract.publicationApproval.environment = 'release' },
    contract => { contract.publicationApproval.environmentId += 1 },
    contract => { contract.publicationApproval.requiredReviewer.id += 1 },
    contract => { contract.publicationApproval.deploymentPolicyType = 'branch' },
    contract => { contract.publicationApproval.storedSecrets = 1 },
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

test('release attempts reject all-zero candidate and origin/main SHAs', () => {
  const contract = readyContract()
  const sources = candidateSources(candidateVersion)
  const stable = readStableReleaseContract()
  const historicalSources = stableSources(candidateVersion)

  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      stable,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: '0'.repeat(40), originMainCommit: '0'.repeat(40) },
    ),
    /candidate commit must be a nonzero canonical lowercase SHA-1/,
  )
  assert.throws(
    () => validateReleaseAdmission(
      contract,
      sources,
      stable,
      historicalSources,
      { releaseTag: candidateTag, candidateCommit: commit, originMainCommit: '0'.repeat(40) },
    ),
    /origin main commit must be a nonzero canonical lowercase SHA-1/,
  )
})

test('requires the 0.6.0 stable contract to remain terminally closed', () => {
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
    /0\.6\.0 stable evidence must remain terminally closed/,
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
    /candidate-ready active version must be "0\.7\.0-rc\.1"/,
  )

  assert.throws(
    () => validateNextReleaseContract(
      closedContract(),
      candidateSources('0.6.0'),
      readStableReleaseContract(),
    ),
    /closed active version must be "0\.7\.0-rc\.1"/,
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
  assert.match(releaseResult.stderr, /is planned and not publication-ready/)
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
