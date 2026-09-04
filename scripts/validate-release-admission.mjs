import fs from 'node:fs'
import path from 'node:path'
import { TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'
import { validateNativeIntegritySources } from './validate-native-integrity.mjs'
import {
  compareReleaseVersionPrecedence,
  parseReleaseVersion,
  validateReleaseTag,
} from './validate-release-version.mjs'
import {
  readStableReleaseContract,
  readStableReleaseSources,
  validateStableReleaseContract,
} from './validate-stable-release.mjs'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const plannedCandidateVersion = '0.7.0-rc.1'
export const candidateReleaseSourcePaths = Object.freeze([
  'VERSION',
  'native-integrity.json',
  'package.json',
])
export const publicationApprovalPolicy = Object.freeze({
  environment: 'immutable-release',
  environmentId: 21234930544,
  requiredReviewer: Object.freeze({
    type: 'User',
    login: 'vyakymenko',
    id: 7300673,
  }),
  preventSelfReview: false,
  canAdminsBypass: false,
  deploymentPattern: 'v*',
  deploymentPolicyType: 'tag',
  deploymentPolicyId: 59095548,
  storedSecrets: 0,
})

export const candidateGatePolicy = Object.freeze([
  Object.freeze({
    id: 'candidate-selection',
    evidenceRequirements: Object.freeze([
      'The exact GitHub tag, GitHub release, and npm version were absent when 0.7.0-rc.1 was selected.',
    ]),
  }),
  Object.freeze({
    id: 'version-synchronization',
    evidenceRequirements: Object.freeze([
      'Every active package, CLI, Zig, container, editor, lockfile, and current-source documentation version surface agrees on 0.7.0-rc.1.',
    ]),
  }),
  Object.freeze({
    id: 'native-integrity',
    evidenceRequirements: Object.freeze([
      'All five architecture-matched release archives reproduce the committed 0.7.0-rc.1 SHA-256 inventory.',
    ]),
  }),
  Object.freeze({
    id: 'local-validation',
    evidenceRequirements: Object.freeze([
      'The complete Debug, ReleaseSafe, package, consumer, builder, documentation, and audit gates pass for the candidate source.',
    ]),
  }),
  Object.freeze({
    id: 'documentation-validation',
    evidenceRequirements: Object.freeze([
      'The candidate documentation tests, production build, served bundle, container smoke, and stable-versus-current identity boundary pass.',
    ]),
  }),
  Object.freeze({
    id: 'hosted-validation',
    evidenceRequirements: Object.freeze([
      'A recorded same-repository main Build run passes the complete test job and every architecture-matched build and provenance job for a pre-admission checkpoint, with its run ID and completion time stored without a commit hash.',
      'Recorded default-setup CodeQL analysis covers the Actions, JavaScript/TypeScript, and Ruby categories for the pre-admission checkpoint with no error or warning status and zero open CodeQL alerts; tag admission revalidates Build and CodeQL against the exact runtime candidate commit.',
    ]),
  }),
  Object.freeze({
    id: 'origin-main-integration',
    evidenceRequirements: Object.freeze([
      'Candidate-ready evidence stores no candidate commit hash; after that contract is committed, tag admission requires the peeled runtime candidate commit to equal a fresh exact origin/main readback.',
      'Repository ruleset 22261144 (`Protect release tags`) is re-read immediately before tag admission as active for the tag target including `refs/tags/v*`, with exact update and deletion rules, no bypass actors, and `current_user_can_bypass: never`.',
      'Before tag creation, the repository immutable-releases endpoint records enabled=true and enforced_by_owner=false through a live admin read; the create-release job then waits on the immutable-release environment until its required reviewer repeats that live read immediately before approval.',
    ]),
  }),
  Object.freeze({
    id: 'tag-workflow-publication',
    evidenceRequirements: Object.freeze([
      'The protected tag workflow publishes the first repository GitHub Release required to read back immutable=true, with the verified five-target assets, release attestation, and exact immutable npm package on next.',
    ]),
  }),
])

const preTagSurfaces = Object.freeze(candidateGatePolicy.slice(0, -1).map(gate => gate.id))
const postTagSurfaces = Object.freeze([candidateGatePolicy.at(-1).id])
const plannedVerifiedSurfaces = Object.freeze(preTagSurfaces.slice(0, 5))
const canonicalCommit = /^[0-9a-f]{40}$/
const canonicalSha256 = /^[0-9a-f]{64}$/
const canonicalUtcTimestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
const maximumEvidenceItems = 8
const maximumEvidenceBytes = 512
const maximumReleaseAssetBytes = 1024 * 1024 * 1024
const maximumObservedDraftAssets = 1000
const maximumNpmUnpackedBytes = 4 * 1024 * 1024
const utf8Decoder = new TextDecoder('utf-8', { fatal: true })
const baseContractKeys = Object.freeze([
  'schemaVersion',
  'ownerPackage',
  'releaseGapFamily',
  'state',
  'candidateReady',
  'candidateVersion',
  'candidateTag',
  'npmDistTag',
  'githubPrerelease',
  'closedHistory',
  'publicationApproval',
  'preTagSurfaces',
  'postTagSurfaces',
  'gates',
])
const publicationEvidenceKeys = Object.freeze([
  'tagCommit',
  'finalBuildEvidence',
  'workflowRunId',
  'workflowAttempt',
  'workflowConclusion',
  'workflowCompletedAt',
  'githubReleaseId',
  'githubReleaseUrl',
  'githubPrerelease',
  'githubDraft',
  'githubImmutable',
  'githubReleaseAttestation',
  'githubPublishedAt',
  'githubAssetCount',
  'githubAssetBytes',
  'githubAssetInventorySha256',
  'assetsPerTarget',
  'npmVersion',
  'npmDistTag',
  'npmLatest',
  'npmNext',
  'npmFileCount',
  'npmUnpackedSize',
  'npmIntegrity',
  'npmShasum',
  'npmProvenancePredicateType',
  'anonymousInstall',
])
const finalBuildEvidenceKeys = Object.freeze([
  'workflow',
  'commit',
  'runId',
  'runAttempt',
  'conclusion',
  'completedAt',
])
const publicationFailureEvidenceKeys = Object.freeze([
  'tagCommit',
  'finalBuildEvidence',
  'releaseWorkflowEvidence',
  'githubSurface',
  'npmSurface',
])
const releaseWorkflowEvidenceKeys = Object.freeze([
  'workflow',
  'commit',
  'runId',
  'runAttempt',
  'conclusion',
  'completedAt',
])
const githubFailureSurfaceKeys = Object.freeze([
  'state',
  'releaseId',
  'releaseUrl',
  'publishedAt',
  'assetCount',
  'assetBytes',
  'assetInventorySha256',
  'releaseAttestation',
])
const npmFailureSurfaceKeys = Object.freeze([
  'state',
  'version',
  'distTag',
  'latest',
  'next',
  'fileCount',
  'unpackedSize',
  'integrity',
  'shasum',
  'provenancePredicateType',
  'anonymousInstall',
])
const failedWorkflowConclusions = new Set([
  'action_required',
  'cancelled',
  'failure',
  'stale',
  'startup_failure',
  'timed_out',
])

function fail(message) {
  throw new Error(`release admission: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (!same(actual, expected)) {
    fail(`${label} keys must be ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label} must be ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
}

function expectPositiveInteger(value, label, maximum = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    fail(`${label} must be a bounded positive integer`)
  }
}

function validateUtcTimestamp(value, label) {
  if (typeof value !== 'string' || !canonicalUtcTimestamp.test(value)) {
    fail(`${label} must be a canonical UTC timestamp`)
  }
  const parsed = Date.parse(value)
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString().replace('.000Z', 'Z') !== value) {
    fail(`${label} must be a real canonical UTC timestamp`)
  }
  return parsed
}

function parseJson(source, label) {
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function validateEvidence(values, state, label) {
  if (!Array.isArray(values) || values.length > maximumEvidenceItems) {
    fail(`${label} must contain at most ${maximumEvidenceItems} evidence strings`)
  }
  const seen = new Set()
  for (const value of values) {
    if (
      typeof value !== 'string'
      || Buffer.byteLength(value) === 0
      || Buffer.byteLength(value) > maximumEvidenceBytes
      || value.trim() !== value
      || /[\0\r\n]/.test(value)
      || seen.has(value)
    ) {
      fail(`${label} contains invalid, duplicate, or oversized evidence`)
    }
    seen.add(value)
  }
  if (state === 'pending' && values.length !== 0) fail(`${label} is pending but already carries evidence`)
  if (state === 'verified' && values.length === 0) fail(`${label} is verified without evidence`)
  if (state === 'failed' && values.length === 0) fail(`${label} is failed without evidence`)
}

function expectedClosedHistory(stableContract) {
  return [
    {
      version: stableContract.previousPrerelease.version,
      tag: stableContract.previousPrerelease.tag,
      commit: stableContract.previousPrerelease.commit,
      githubReleaseId: stableContract.previousPrerelease.githubReleaseId,
      githubImmutable: stableContract.previousPrerelease.githubImmutable,
      npmDistTag: stableContract.previousPrerelease.npmDistTag,
      npmVersionImmutable: true,
      githubPrerelease: true,
    },
    {
      version: stableContract.candidateVersion,
      tag: stableContract.candidateTag,
      commit: stableContract.publicationEvidence.tagCommit,
      githubReleaseId: stableContract.publicationEvidence.githubReleaseId,
      githubImmutable: stableContract.publicationEvidence.githubImmutable,
      npmDistTag: stableContract.publicationEvidence.npmDistTag,
      npmVersionImmutable: true,
      githubPrerelease: stableContract.publicationEvidence.githubPrerelease,
    },
  ]
}

function validateClosedHistory(history, stableContract) {
  if (!Array.isArray(history) || history.length !== 2) {
    fail('closedHistory must contain the published prerelease and stable release exactly once')
  }
  for (const [index, entry] of history.entries()) {
    exactKeys(
      entry,
      [
        'version',
        'tag',
        'commit',
        'githubReleaseId',
        'githubImmutable',
        'npmDistTag',
        'npmVersionImmutable',
        'githubPrerelease',
      ],
      `closedHistory[${index}]`,
    )
    parseReleaseVersion(entry.version, `closedHistory[${index}].version`)
    validateReleaseTag(entry.version, entry.tag)
    if (!canonicalCommit.test(entry.commit)) fail(`closedHistory[${index}].commit is not canonical`)
    expectPositiveInteger(entry.githubReleaseId, `closedHistory[${index}].githubReleaseId`)
    expectEqual(entry.githubImmutable, false, `closedHistory[${index}].githubImmutable`)
    expectEqual(entry.npmVersionImmutable, true, `closedHistory[${index}].npmVersionImmutable`)
  }
  const expected = expectedClosedHistory(stableContract)
  if (!same(history, expected)) {
    fail('closedHistory no longer matches the closed 0.6.0 publication evidence')
  }
}

function validatePublicationApprovalPolicy(policy) {
  exactKeys(policy, Object.keys(publicationApprovalPolicy), 'publicationApproval')
  exactKeys(
    policy.requiredReviewer,
    Object.keys(publicationApprovalPolicy.requiredReviewer),
    'publicationApproval.requiredReviewer',
  )
  if (!same(policy, publicationApprovalPolicy)) {
    fail('publicationApproval no longer matches the live immutable-release environment policy')
  }
}

function validateActiveSources(sources, candidateVersion, publishedStableVersion, state) {
  if (!(sources instanceof Map)) fail('active release sources must be a Map')
  const actualPaths = [...sources.keys()].sort()
  const expectedPaths = [...candidateReleaseSourcePaths].sort()
  if (!same(actualPaths, expectedPaths)) {
    fail(`active release source inventory must be ${JSON.stringify(expectedPaths)}`)
  }

  const versionSource = sources.get('VERSION')
  if (typeof versionSource !== 'string' || !versionSource.endsWith('\n') || versionSource.trim() + '\n' !== versionSource) {
    fail('VERSION must contain one canonical version and a final newline')
  }
  const activeVersion = parseReleaseVersion(versionSource.trim(), 'active source version').value
  if (![publishedStableVersion, candidateVersion].includes(activeVersion)) {
    fail(`active source version must remain ${publishedStableVersion} or advance exactly to ${candidateVersion}`)
  }

  let nativeIntegrity
  try {
    nativeIntegrity = validateNativeIntegritySources({
      manifest: sources.get('native-integrity.json'),
      packageManifest: sources.get('package.json'),
      version: versionSource,
    })
  } catch (error) {
    fail(error.message)
  }
  expectEqual(nativeIntegrity.version, activeVersion, 'native integrity active version')
  if (state !== 'planned') expectEqual(activeVersion, candidateVersion, `${state} active version`)
  return activeVersion
}

function validateContractShape(contract) {
  if (contract?.schemaVersion === 1) {
    exactKeys(contract, baseContractKeys, 'next release contract schema 1')
    if (!['planned', 'candidate-ready'].includes(contract.state)) {
      fail('schemaVersion 1 state must be planned or candidate-ready')
    }
  } else if (contract?.schemaVersion === 2) {
    exactKeys(contract, [...baseContractKeys, 'publicationEvidence'], 'next release contract schema 2')
    expectEqual(contract.state, 'closed', 'schemaVersion 2 state')
  } else if (contract?.schemaVersion === 3) {
    exactKeys(
      contract,
      [...baseContractKeys, 'publicationFailureEvidence'],
      'next release contract schema 3',
    )
    expectEqual(contract.state, 'publication-failed', 'schemaVersion 3 state')
  } else {
    fail('schemaVersion must be 1 for an open candidate, 2 for a closed publication, or 3 for a failed publication terminal')
  }
  expectEqual(contract.ownerPackage, 'REL-011', 'ownerPackage')
  expectEqual(contract.releaseGapFamily, 'next-release-candidate', 'releaseGapFamily')
  if (typeof contract.candidateReady !== 'boolean') fail('candidateReady must be boolean')
  expectEqual(contract.candidateVersion, plannedCandidateVersion, 'candidateVersion')
  const parsedCandidate = parseReleaseVersion(contract.candidateVersion, 'candidateVersion')
  if (parsedCandidate.prerelease === null || parsedCandidate.build !== null) {
    fail('the planned candidate must be a prerelease without build metadata')
  }
  expectEqual(contract.candidateTag, `v${contract.candidateVersion}`, 'candidateTag')
  validateReleaseTag(contract.candidateVersion, contract.candidateTag)
  expectEqual(contract.npmDistTag, 'next', 'npmDistTag')
  expectEqual(contract.githubPrerelease, true, 'githubPrerelease')
  validatePublicationApprovalPolicy(contract.publicationApproval)
  if (!same(contract.preTagSurfaces, preTagSurfaces)) fail('preTagSurfaces inventory or order changed')
  if (!same(contract.postTagSurfaces, postTagSurfaces)) fail('postTagSurfaces inventory or order changed')
}

function validateGates(contract) {
  if (!Array.isArray(contract.gates) || contract.gates.length !== candidateGatePolicy.length) {
    fail(`gates must contain exactly ${candidateGatePolicy.length} ordered entries`)
  }
  const seen = new Set()
  const byId = new Map()
  for (const [index, gate] of contract.gates.entries()) {
    exactKeys(gate, ['id', 'state', 'evidenceRequirements', 'evidence'], `gates[${index}]`)
    const expected = candidateGatePolicy[index]
    expectEqual(gate.id, expected.id, `gates[${index}].id`)
    if (seen.has(gate.id)) fail(`duplicate gate ${gate.id}`)
    seen.add(gate.id)
    if (!['pending', 'verified', 'failed'].includes(gate.state)) fail(`${gate.id} state is invalid`)
    if (!same(gate.evidenceRequirements, expected.evidenceRequirements)) {
      fail(`${gate.id} evidence requirements changed`)
    }
    validateEvidence(gate.evidence, gate.state, `${gate.id}.evidence`)
    byId.set(gate.id, gate)
  }
  return byId
}

function expectGateState(gates, id, state, label) {
  if (gates.get(id)?.state !== state) fail(`${label} requires ${id} to be ${state}`)
}

function validateReleaseTagProtectionEvidence(originMainGate) {
  const recorded = originMainGate.evidence.join('\n')
  for (const value of [
    'ruleset 22261144',
    'Protect release tags',
    'active',
    'target tag',
    'refs/tags/v*',
    'update',
    'deletion',
    'bypass_actors=[]',
    'current_user_can_bypass=never',
  ]) {
    if (!recorded.includes(value)) {
      fail(`origin-main-integration evidence must reference protected release-tag interlock ${value}`)
    }
  }
}

function validateImmutableReleasesCheckpointEvidence(originMainGate) {
  const recorded = originMainGate.evidence.join('\n')
  for (const value of [
    'immutable releases setting',
    'enabled=true',
    'enforced_by_owner=false',
    'before tag creation',
    'immutable-release environment',
    'required reviewer repeats',
  ]) {
    if (!recorded.includes(value)) {
      fail(`origin-main-integration evidence must reference immutable-releases pre-tag interlock ${value}`)
    }
  }
  const timestamp = recorded.match(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b/)?.[0]
  if (timestamp === undefined) {
    fail('origin-main-integration evidence must timestamp the immutable-releases pre-tag readback')
  }
  validateUtcTimestamp(timestamp, 'origin-main-integration immutable-releases readback time')
}

function rejectSelfReferentialCandidateEvidence(gates) {
  for (const id of ['hosted-validation', 'origin-main-integration']) {
    const recorded = gates.get(id).evidence.join('\n')
    if (/\b[0-9a-f]{40}\b/.test(recorded)) {
      fail(`${id} candidate-ready evidence must not embed a commit hash`)
    }
  }
}

function validateHostedCheckpointEvidence(hostedValidationGate, expectedCommit = null) {
  const recorded = hostedValidationGate.evidence.join('\n')
  for (const value of [
    'CodeQL default setup',
    'Actions',
    'JavaScript/TypeScript',
    'Ruby',
    'same commit',
    'error=0',
    'warning=0',
    'open alerts=0',
    'security-events: read',
  ]) {
    if (!recorded.includes(value)) {
      fail(`hosted-validation evidence must reference same-commit CodeQL interlock ${value}`)
    }
  }
  const buildRunMatch = recorded.match(/\bBuild run ([1-9][0-9]*)\b/)
  if (buildRunMatch === null) {
    fail('hosted-validation evidence must record a positive Build run ID')
  }
  expectPositiveInteger(Number(buildRunMatch[1]), 'hosted-validation Build run ID')
  if (expectedCommit === null) {
    for (const value of [
      'pre-admission checkpoint',
      'exact runtime candidate commit',
      'Release workflow',
    ]) {
      if (!recorded.includes(value)) {
        fail(`hosted-validation candidate-ready evidence must reference ${value}`)
      }
    }
    const timestamps = recorded.match(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b/g) ?? []
    if (timestamps.length < 2) {
      fail('hosted-validation candidate-ready evidence must timestamp Build and CodeQL checkpoint observations')
    }
    for (const [index, timestamp] of timestamps.entries()) {
      validateUtcTimestamp(timestamp, `hosted-validation checkpoint time ${index}`)
    }
    return Object.freeze({ buildRunId: Number(buildRunMatch[1]) })
  }

  const buildMatch = recorded.match(/\bBuild run ([1-9][0-9]*)[^\n]{0,256}\b([0-9a-f]{40})\b/)
  if (buildMatch === null || /^0+$/.test(buildMatch[2])) {
    fail('hosted-validation terminal evidence must bind the Build run ID to one nonzero candidate commit')
  }
  const codeQlMatch = recorded.match(/\bCodeQL default setup[^\n]{0,256}\bsame commit ([0-9a-f]{40})\b/)
  if (codeQlMatch === null || /^0+$/.test(codeQlMatch[1])) {
    fail('hosted-validation terminal evidence must bind CodeQL default setup to one nonzero candidate commit')
  }
  expectEqual(codeQlMatch[1], buildMatch[2], 'hosted-validation Build and CodeQL commit')
  expectEqual(buildMatch[2], expectedCommit, 'hosted-validation candidate commit')
  return buildMatch[2]
}

function validateFinalBuildEvidence(finalBuild, tagCommit, label) {
  exactKeys(finalBuild, finalBuildEvidenceKeys, label)
  expectEqual(finalBuild.workflow, 'Build', `${label}.workflow`)
  if (!canonicalCommit.test(finalBuild.commit) || /^0+$/.test(finalBuild.commit)) {
    fail(`${label}.commit must be a nonzero canonical lowercase SHA-1`)
  }
  expectEqual(finalBuild.commit, tagCommit, `${label}.commit`)
  expectPositiveInteger(finalBuild.runId, `${label}.runId`)
  expectPositiveInteger(finalBuild.runAttempt, `${label}.runAttempt`, 1000)
  expectEqual(finalBuild.conclusion, 'success', `${label}.conclusion`)
  return validateUtcTimestamp(finalBuild.completedAt, `${label}.completedAt`)
}

function validateSha256(value, label) {
  if (!canonicalSha256.test(value) || /^0+$/.test(value)) {
    fail(`${label} must be a nonzero canonical SHA-256`)
  }
}

function validateNpmIntegrity(value, label) {
  if (typeof value !== 'string' || !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    fail(`${label} must be a canonical SHA-512 Subresource Integrity value`)
  }
  const integrityBytes = Buffer.from(value.slice('sha512-'.length), 'base64')
  if (
    integrityBytes.length !== 64
    || integrityBytes.every(byte => byte === 0)
    || `sha512-${integrityBytes.toString('base64')}` !== value
  ) {
    fail(`${label} must encode exactly one SHA-512 digest`)
  }
}

function validatePublicationEvidence(
  evidence,
  contract,
  stableContract,
  publicationGate,
  hostedValidationGate,
  originMainGate,
) {
  exactKeys(evidence, publicationEvidenceKeys, 'publicationEvidence')
  if (!canonicalCommit.test(evidence.tagCommit) || /^0+$/.test(evidence.tagCommit)) {
    fail('publicationEvidence.tagCommit must be a nonzero canonical lowercase SHA-1')
  }
  if (contract.closedHistory.some(entry => entry.commit === evidence.tagCommit)) {
    fail('publicationEvidence.tagCommit must not reuse a closed historical publication commit')
  }
  const finalBuild = evidence.finalBuildEvidence
  const finalBuildCompletedAt = validateFinalBuildEvidence(
    finalBuild,
    evidence.tagCommit,
    'publicationEvidence.finalBuildEvidence',
  )
  expectPositiveInteger(evidence.workflowRunId, 'publicationEvidence.workflowRunId')
  expectPositiveInteger(evidence.workflowAttempt, 'publicationEvidence.workflowAttempt', 1000)
  expectEqual(evidence.workflowConclusion, 'success', 'publicationEvidence.workflowConclusion')
  const workflowCompletedAt = validateUtcTimestamp(
    evidence.workflowCompletedAt,
    'publicationEvidence.workflowCompletedAt',
  )
  if (finalBuildCompletedAt > workflowCompletedAt) {
    fail('publicationEvidence.finalBuildEvidence.completedAt must not be after release workflow completion')
  }
  expectPositiveInteger(evidence.githubReleaseId, 'publicationEvidence.githubReleaseId')
  expectEqual(
    evidence.githubReleaseUrl,
    `https://github.com/vyakymenko/zigcss/releases/tag/${contract.candidateTag}`,
    'publicationEvidence.githubReleaseUrl',
  )
  expectEqual(evidence.githubPrerelease, contract.githubPrerelease, 'publicationEvidence.githubPrerelease')
  expectEqual(evidence.githubDraft, false, 'publicationEvidence.githubDraft')
  expectEqual(evidence.githubImmutable, true, 'publicationEvidence.githubImmutable')
  expectEqual(
    evidence.githubReleaseAttestation,
    'verified',
    'publicationEvidence.githubReleaseAttestation',
  )
  const githubPublishedAt = validateUtcTimestamp(
    evidence.githubPublishedAt,
    'publicationEvidence.githubPublishedAt',
  )
  if (finalBuildCompletedAt > githubPublishedAt) {
    fail('publicationEvidence.finalBuildEvidence.completedAt must not be after GitHub publication')
  }
  if (githubPublishedAt > workflowCompletedAt) {
    fail('publicationEvidence.githubPublishedAt must not be after workflow completion')
  }
  expectEqual(evidence.githubAssetCount, 25, 'publicationEvidence.githubAssetCount')
  expectPositiveInteger(
    evidence.githubAssetBytes,
    'publicationEvidence.githubAssetBytes',
    maximumReleaseAssetBytes,
  )
  validateSha256(evidence.githubAssetInventorySha256, 'publicationEvidence.githubAssetInventorySha256')
  expectEqual(evidence.assetsPerTarget, 5, 'publicationEvidence.assetsPerTarget')
  expectEqual(evidence.npmVersion, contract.candidateVersion, 'publicationEvidence.npmVersion')
  expectEqual(evidence.npmDistTag, contract.npmDistTag, 'publicationEvidence.npmDistTag')
  expectEqual(evidence.npmLatest, stableContract.candidateVersion, 'publicationEvidence.npmLatest')
  expectEqual(evidence.npmNext, contract.candidateVersion, 'publicationEvidence.npmNext')
  expectEqual(
    evidence.npmFileCount,
    expectedPackedFiles.length,
    'publicationEvidence.npmFileCount',
  )
  expectPositiveInteger(
    evidence.npmUnpackedSize,
    'publicationEvidence.npmUnpackedSize',
    maximumNpmUnpackedBytes,
  )
  validateNpmIntegrity(evidence.npmIntegrity, 'publicationEvidence.npmIntegrity')
  if (!canonicalCommit.test(evidence.npmShasum) || /^0+$/.test(evidence.npmShasum)) {
    fail('publicationEvidence.npmShasum must be a nonzero canonical lowercase SHA-1')
  }
  expectEqual(
    evidence.npmProvenancePredicateType,
    'https://slsa.dev/provenance/v1',
    'publicationEvidence.npmProvenancePredicateType',
  )
  expectEqual(evidence.anonymousInstall, 'verified-five-syntaxes', 'publicationEvidence.anonymousInstall')

  const recorded = publicationGate.evidence.join('\n')
  if (!/immutable/i.test(recorded) || !/attestation/i.test(recorded)) {
    fail('tag-workflow-publication evidence must reference immutable release attestation verification')
  }
  for (const value of [
    evidence.tagCommit,
    String(evidence.workflowRunId),
    String(evidence.githubReleaseId),
    contract.candidateVersion,
    contract.npmDistTag,
  ]) {
    if (!recorded.includes(value)) fail(`tag-workflow-publication evidence must reference ${value}`)
  }
  if (!originMainGate.evidence.join('\n').includes(evidence.tagCommit)) {
    fail('origin-main-integration evidence must reference publicationEvidence.tagCommit')
  }
  const hostedValidation = hostedValidationGate.evidence.join('\n')
  for (const value of ['Build', finalBuild.commit, String(finalBuild.runId)]) {
    if (!hostedValidation.includes(value)) {
      fail(`hosted-validation evidence must reference final Build evidence ${value}`)
    }
  }
}

function validatePublicationFailureEvidence(
  evidence,
  contract,
  stableContract,
  publicationGate,
  hostedValidationGate,
  originMainGate,
) {
  exactKeys(evidence, publicationFailureEvidenceKeys, 'publicationFailureEvidence')
  if (!canonicalCommit.test(evidence.tagCommit) || /^0+$/.test(evidence.tagCommit)) {
    fail('publicationFailureEvidence.tagCommit must be a nonzero canonical lowercase SHA-1')
  }
  if (contract.closedHistory.some(entry => entry.commit === evidence.tagCommit)) {
    fail('publicationFailureEvidence.tagCommit must not reuse a closed historical publication commit')
  }

  let finalBuildCompletedAt = null
  if (evidence.finalBuildEvidence !== null) {
    finalBuildCompletedAt = validateFinalBuildEvidence(
      evidence.finalBuildEvidence,
      evidence.tagCommit,
      'publicationFailureEvidence.finalBuildEvidence',
    )
    if (hostedValidationGate.state === 'verified') {
      const hostedValidation = hostedValidationGate.evidence.join('\n')
      for (const value of [
        'Build',
        evidence.finalBuildEvidence.commit,
        String(evidence.finalBuildEvidence.runId),
      ]) {
        if (!hostedValidation.includes(value)) {
          fail(`hosted-validation evidence must reference failed-terminal final Build evidence ${value}`)
        }
      }
    }
  } else if (hostedValidationGate.state === 'verified') {
    fail('publicationFailureEvidence.finalBuildEvidence is required when hosted-validation is verified')
  }

  const workflow = evidence.releaseWorkflowEvidence
  exactKeys(workflow, releaseWorkflowEvidenceKeys, 'publicationFailureEvidence.releaseWorkflowEvidence')
  expectEqual(workflow.workflow, 'Release', 'publicationFailureEvidence.releaseWorkflowEvidence.workflow')
  if (!canonicalCommit.test(workflow.commit) || /^0+$/.test(workflow.commit)) {
    fail('publicationFailureEvidence.releaseWorkflowEvidence.commit must be a nonzero canonical lowercase SHA-1')
  }
  expectEqual(workflow.commit, evidence.tagCommit, 'publicationFailureEvidence.releaseWorkflowEvidence.commit')
  expectPositiveInteger(workflow.runId, 'publicationFailureEvidence.releaseWorkflowEvidence.runId')
  expectPositiveInteger(workflow.runAttempt, 'publicationFailureEvidence.releaseWorkflowEvidence.runAttempt', 1000)
  if (!failedWorkflowConclusions.has(workflow.conclusion)) {
    fail('publicationFailureEvidence.releaseWorkflowEvidence.conclusion must be a terminal non-success conclusion')
  }
  const workflowCompletedAt = validateUtcTimestamp(
    workflow.completedAt,
    'publicationFailureEvidence.releaseWorkflowEvidence.completedAt',
  )
  if (finalBuildCompletedAt !== null && finalBuildCompletedAt > workflowCompletedAt) {
    fail('publicationFailureEvidence.finalBuildEvidence.completedAt must not be after failed workflow completion')
  }

  const github = evidence.githubSurface
  exactKeys(github, githubFailureSurfaceKeys, 'publicationFailureEvidence.githubSurface')
  if (!['absent', 'draft', 'immutable-published'].includes(github.state)) {
    fail('publicationFailureEvidence.githubSurface.state is invalid')
  }
  if (github.state === 'absent') {
    for (const [key, value] of [
      ['releaseId', null],
      ['releaseUrl', null],
      ['publishedAt', null],
      ['assetCount', 0],
      ['assetBytes', 0],
      ['assetInventorySha256', null],
      ['releaseAttestation', 'absent'],
    ]) {
      expectEqual(github[key], value, `publicationFailureEvidence.githubSurface.${key}`)
    }
  } else if (github.state === 'draft') {
    expectPositiveInteger(github.releaseId, 'publicationFailureEvidence.githubSurface.releaseId')
    expectEqual(github.releaseUrl, null, 'publicationFailureEvidence.githubSurface.releaseUrl')
    expectEqual(github.publishedAt, null, 'publicationFailureEvidence.githubSurface.publishedAt')
    expectEqual(github.releaseAttestation, 'absent', 'publicationFailureEvidence.githubSurface.releaseAttestation')
    if (
      !Number.isSafeInteger(github.assetCount)
      || github.assetCount < 0
      || github.assetCount > maximumObservedDraftAssets
    ) {
      fail(`publicationFailureEvidence.githubSurface.assetCount must be between 0 and ${maximumObservedDraftAssets}`)
    }
    if (github.assetCount === 0) {
      expectEqual(github.assetBytes, 0, 'publicationFailureEvidence.githubSurface.assetBytes')
      expectEqual(github.assetInventorySha256, null, 'publicationFailureEvidence.githubSurface.assetInventorySha256')
    } else {
      expectPositiveInteger(
        github.assetBytes,
        'publicationFailureEvidence.githubSurface.assetBytes',
        maximumReleaseAssetBytes,
      )
      validateSha256(
        github.assetInventorySha256,
        'publicationFailureEvidence.githubSurface.assetInventorySha256',
      )
    }
  } else {
    expectPositiveInteger(github.releaseId, 'publicationFailureEvidence.githubSurface.releaseId')
    expectEqual(
      github.releaseUrl,
      `https://github.com/vyakymenko/zigcss/releases/tag/${contract.candidateTag}`,
      'publicationFailureEvidence.githubSurface.releaseUrl',
    )
    const githubPublishedAt = validateUtcTimestamp(
      github.publishedAt,
      'publicationFailureEvidence.githubSurface.publishedAt',
    )
    if (githubPublishedAt > workflowCompletedAt) {
      fail('publicationFailureEvidence.githubSurface.publishedAt must not be after failed workflow completion')
    }
    if (finalBuildCompletedAt !== null && finalBuildCompletedAt > githubPublishedAt) {
      fail('publicationFailureEvidence.finalBuildEvidence.completedAt must not be after GitHub publication')
    }
    expectEqual(github.assetCount, 25, 'publicationFailureEvidence.githubSurface.assetCount')
    expectPositiveInteger(
      github.assetBytes,
      'publicationFailureEvidence.githubSurface.assetBytes',
      maximumReleaseAssetBytes,
    )
    validateSha256(
      github.assetInventorySha256,
      'publicationFailureEvidence.githubSurface.assetInventorySha256',
    )
    expectEqual(
      github.releaseAttestation,
      'verified',
      'publicationFailureEvidence.githubSurface.releaseAttestation',
    )
  }

  const npm = evidence.npmSurface
  exactKeys(npm, npmFailureSurfaceKeys, 'publicationFailureEvidence.npmSurface')
  if (!['absent', 'published-exact'].includes(npm.state)) {
    fail('publicationFailureEvidence.npmSurface.state is invalid')
  }
  expectEqual(npm.version, contract.candidateVersion, 'publicationFailureEvidence.npmSurface.version')
  expectEqual(npm.distTag, contract.npmDistTag, 'publicationFailureEvidence.npmSurface.distTag')
  expectEqual(npm.latest, stableContract.candidateVersion, 'publicationFailureEvidence.npmSurface.latest')
  parseReleaseVersion(npm.next, 'publicationFailureEvidence.npmSurface.next')
  if (npm.state === 'absent') {
    if (npm.next === contract.candidateVersion) {
      fail('publicationFailureEvidence.npmSurface.next must not claim an absent candidate')
    }
    for (const [key, value] of [
      ['fileCount', 0],
      ['unpackedSize', 0],
      ['integrity', null],
      ['shasum', null],
      ['provenancePredicateType', null],
      ['anonymousInstall', 'not-run'],
    ]) {
      expectEqual(npm[key], value, `publicationFailureEvidence.npmSurface.${key}`)
    }
  } else {
    expectEqual(github.state, 'immutable-published', 'published npm failure GitHub surface state')
    expectEqual(npm.next, contract.candidateVersion, 'publicationFailureEvidence.npmSurface.next')
    expectEqual(npm.fileCount, expectedPackedFiles.length, 'publicationFailureEvidence.npmSurface.fileCount')
    expectPositiveInteger(
      npm.unpackedSize,
      'publicationFailureEvidence.npmSurface.unpackedSize',
      maximumNpmUnpackedBytes,
    )
    validateNpmIntegrity(npm.integrity, 'publicationFailureEvidence.npmSurface.integrity')
    if (!canonicalCommit.test(npm.shasum) || /^0+$/.test(npm.shasum)) {
      fail('publicationFailureEvidence.npmSurface.shasum must be a nonzero canonical lowercase SHA-1')
    }
    expectEqual(
      npm.provenancePredicateType,
      'https://slsa.dev/provenance/v1',
      'publicationFailureEvidence.npmSurface.provenancePredicateType',
    )
    if (!['not-run', 'failed'].includes(npm.anonymousInstall)) {
      fail('publicationFailureEvidence.npmSurface.anonymousInstall must not claim terminal success')
    }
  }

  if (
    originMainGate.state === 'verified'
    && !originMainGate.evidence.join('\n').includes(evidence.tagCommit)
  ) {
    fail('origin-main-integration evidence must reference publicationFailureEvidence.tagCommit')
  }
  const recorded = publicationGate.evidence.join('\n')
  for (const value of [evidence.tagCommit, String(workflow.runId), workflow.conclusion]) {
    if (!recorded.includes(value)) {
      fail(`tag-workflow-publication failure evidence must reference ${value}`)
    }
  }
  for (const value of [
    `GitHub surface ${github.state}`,
    `npm surface ${npm.state}`,
  ]) {
    if (!recorded.includes(value)) {
      fail(`tag-workflow-publication failure evidence must reference ${value}`)
    }
  }
  if (
    /\b(?:publication|release|workflow)\s+(?:is\s+)?(?:closed|complete(?:d)?|success(?:ful(?:ly)?)?|succeed(?:ed|s)?)\b/i
      .test(recorded)
  ) {
    fail('tag-workflow-publication failure evidence must not claim a closed or successful publication')
  }
}

function validateCandidateState(contract, gates, stableContract) {
  const preTagComplete = preTagSurfaces.every(id => gates.get(id)?.state === 'verified')
  const publication = gates.get(postTagSurfaces[0])
  if (contract.state === 'planned') {
    expectEqual(contract.candidateReady, false, 'planned candidateReady')
    for (const id of plannedVerifiedSurfaces) expectGateState(gates, id, 'verified', 'planned candidate')
    for (const id of preTagSurfaces.slice(plannedVerifiedSurfaces.length)) {
      expectGateState(gates, id, 'pending', 'planned candidate')
    }
    expectGateState(gates, postTagSurfaces[0], 'pending', 'planned candidate')
  } else if (contract.state === 'candidate-ready') {
    expectEqual(contract.candidateReady, true, 'candidate-ready candidateReady')
    if (!preTagComplete) fail('candidate-ready release has an incomplete pre-tag gate')
    rejectSelfReferentialCandidateEvidence(gates)
    validateHostedCheckpointEvidence(gates.get('hosted-validation'))
    validateReleaseTagProtectionEvidence(gates.get('origin-main-integration'))
    validateImmutableReleasesCheckpointEvidence(gates.get('origin-main-integration'))
    expectGateState(gates, postTagSurfaces[0], 'pending', 'candidate-ready release')
  } else if (contract.state === 'closed') {
    expectEqual(contract.candidateReady, false, 'closed candidateReady')
    if (!preTagComplete) fail('closed release has an incomplete pre-tag gate')
    validateReleaseTagProtectionEvidence(gates.get('origin-main-integration'))
    validateImmutableReleasesCheckpointEvidence(gates.get('origin-main-integration'))
    expectGateState(gates, postTagSurfaces[0], 'verified', 'closed release')
    validatePublicationEvidence(
      contract.publicationEvidence,
      contract,
      stableContract,
      publication,
      gates.get('hosted-validation'),
      gates.get('origin-main-integration'),
    )
    validateHostedCheckpointEvidence(
      gates.get('hosted-validation'),
      contract.publicationEvidence.tagCommit,
    )
  } else {
    expectEqual(contract.candidateReady, false, 'publication-failed candidateReady')
    for (const id of plannedVerifiedSurfaces) {
      expectGateState(gates, id, 'verified', 'publication-failed release')
    }
    let pendingSeen = false
    for (const id of preTagSurfaces) {
      const state = gates.get(id)?.state
      if (state === 'pending') {
        pendingSeen = true
      } else if (state !== 'verified') {
        fail(`publication-failed release requires pre-tag gate ${id} to be verified or pending`)
      } else if (pendingSeen) {
        fail(`publication-failed release pre-tag evidence is out of order at ${id}`)
      }
    }
    if (gates.get('hosted-validation').state === 'verified') {
      validateHostedCheckpointEvidence(
        gates.get('hosted-validation'),
        contract.publicationFailureEvidence?.tagCommit,
      )
    }
    if (gates.get('origin-main-integration').state === 'verified') {
      validateReleaseTagProtectionEvidence(gates.get('origin-main-integration'))
      validateImmutableReleasesCheckpointEvidence(gates.get('origin-main-integration'))
    }
    expectGateState(gates, postTagSurfaces[0], 'failed', 'publication-failed release')
    validatePublicationFailureEvidence(
      contract.publicationFailureEvidence,
      contract,
      stableContract,
      publication,
      gates.get('hosted-validation'),
      gates.get('origin-main-integration'),
    )
  }
}

export function validateNextReleaseContract(contract, sources, stableContract) {
  validateContractShape(contract)
  validateClosedHistory(contract.closedHistory, stableContract)
  const publishedStable = parseReleaseVersion(stableContract.candidateVersion, 'published stable version')
  if (compareReleaseVersionPrecedence(contract.candidateVersion, publishedStable.value) <= 0) {
    fail('planned candidate must be newer than the closed published stable version')
  }
  const gates = validateGates(contract)
  validateCandidateState(contract, gates, stableContract)
  const activeVersion = validateActiveSources(
    sources,
    contract.candidateVersion,
    publishedStable.value,
    contract.state,
  )
  return Object.freeze({
    activeVersion,
    candidateReady: contract.candidateReady,
    state: contract.state,
    tag: contract.candidateTag,
    totalGates: contract.gates.length,
    verifiedGates: contract.gates.filter(gate => gate.state === 'verified').length,
    version: contract.candidateVersion,
  })
}

function validateAttemptOptions(options) {
  if (options === undefined) return undefined
  exactKeys(options, ['releaseTag', 'candidateCommit', 'originMainCommit'], 'release attempt')
  if (typeof options.releaseTag !== 'string' || !options.releaseTag.startsWith('v')) {
    fail('release tag must start with v')
  }
  parseReleaseVersion(options.releaseTag.slice(1), 'release tag version')
  if (!canonicalCommit.test(options.candidateCommit) || /^0+$/.test(options.candidateCommit)) {
    fail('candidate commit must be a nonzero canonical lowercase SHA-1')
  }
  if (!canonicalCommit.test(options.originMainCommit) || /^0+$/.test(options.originMainCommit)) {
    fail('origin main commit must be a nonzero canonical lowercase SHA-1')
  }
  if (options.candidateCommit !== options.originMainCommit) {
    fail('candidate commit must equal the exact origin/main commit')
  }
  return options
}

export function validateReleaseAdmission(
  candidateContract,
  candidateSources,
  stableContract,
  stableSources,
  options = undefined,
) {
  let stableResult
  try {
    stableResult = validateStableReleaseContract(stableContract, stableSources)
  } catch (error) {
    fail(`closed stable evidence failed validation: ${error.message}`)
  }
  if (stableResult.state !== 'closed') {
    fail('0.6.0 stable evidence must remain terminally closed')
  }
  if (!(candidateSources instanceof Map)) fail('active release sources must be a Map')
  for (const relativePath of ['VERSION', 'package.json']) {
    if (stableSources.get(relativePath) !== candidateSources.get(relativePath)) {
      fail(`candidate and historical validators observed different active ${relativePath} bytes`)
    }
  }
  const result = validateNextReleaseContract(candidateContract, candidateSources, stableContract)
  const attempt = validateAttemptOptions(options)
  if (attempt === undefined) return result

  const historicalTags = new Set(candidateContract.closedHistory.map(entry => entry.tag))
  const attemptVersion = attempt.releaseTag.slice(1)
  if (
    historicalTags.has(attempt.releaseTag)
    || compareReleaseVersionPrecedence(attemptVersion, stableContract.candidateVersion) <= 0
  ) {
    fail(`historical release tag ${attempt.releaseTag} is closed and cannot be admitted again`)
  }
  if (attempt.releaseTag !== candidateContract.candidateTag) {
    fail(`release tag must match the sole planned candidate ${candidateContract.candidateTag}`)
  }
  if (candidateContract.state !== 'candidate-ready' || candidateContract.candidateReady !== true) {
    fail(`candidate ${candidateContract.candidateTag} is ${candidateContract.state} and not publication-ready`)
  }
  return result
}

function canonicalDirectory(root) {
  let stat
  try {
    stat = fs.lstatSync(root)
  } catch (error) {
    fail(`repository root is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail('repository root must be a regular non-symlink directory')
  return fs.realpathSync(root)
}

function readRegularText(root, relativePath, maximumBytes) {
  const filename = path.resolve(root, relativePath)
  const relative = path.relative(root, filename)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${relativePath} escapes the repository`)
  }
  let pathStat
  try {
    pathStat = fs.lstatSync(filename, { bigint: true })
  } catch (error) {
    fail(`${relativePath} is unavailable: ${error.message}`)
  }
  if (
    !pathStat.isFile()
    || pathStat.isSymbolicLink()
    || pathStat.size === 0n
    || pathStat.size > BigInt(maximumBytes)
  ) {
    fail(`${relativePath} must be a bounded regular non-symlink file`)
  }
  const canonical = fs.realpathSync(filename)
  const canonicalRelative = path.relative(root, canonical)
  if (canonicalRelative === '..' || canonicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(canonicalRelative)) {
    fail(`${relativePath} escapes the repository`)
  }

  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  const closeOnExec = fs.constants.O_CLOEXEC ?? 0
  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | noFollow | closeOnExec)
  } catch (error) {
    fail(`${relativePath} could not be opened safely: ${error.message}`)
  }

  try {
    const before = fs.fstatSync(descriptor, { bigint: true })
    const openedPath = fs.lstatSync(filename, { bigint: true })
    if (
      !before.isFile()
      || !openedPath.isFile()
      || openedPath.isSymbolicLink()
      || before.dev !== pathStat.dev
      || before.ino !== pathStat.ino
      || before.size !== pathStat.size
      || openedPath.dev !== before.dev
      || openedPath.ino !== before.ino
      || openedPath.size !== before.size
    ) {
      fail(`${relativePath} changed while it was being opened`)
    }

    const bytes = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor, { bigint: true })
    const finalPath = fs.lstatSync(filename, { bigint: true })
    if (
      !after.isFile()
      || !finalPath.isFile()
      || finalPath.isSymbolicLink()
      || after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs
      || after.ctimeNs !== before.ctimeNs
      || finalPath.dev !== after.dev
      || finalPath.ino !== after.ino
      || finalPath.size !== after.size
      || BigInt(bytes.length) !== before.size
    ) {
      fail(`${relativePath} changed while it was being read`)
    }

    let source
    try {
      source = utf8Decoder.decode(bytes)
    } catch (error) {
      fail(`${relativePath} is not valid UTF-8: ${error.message}`)
    }
    return source.replaceAll('\r\n', '\n')
  } finally {
    fs.closeSync(descriptor)
  }
}

export function readNextReleaseContract(root = repositoryRoot) {
  const canonicalRoot = canonicalDirectory(root)
  const source = readRegularText(canonicalRoot, 'release/next-release.json', 64 * 1024)
  const contract = parseJson(source, 'release/next-release.json')
  if (`${JSON.stringify(contract, null, 2)}\n` !== source) {
    fail('release/next-release.json must use the canonical JSON representation')
  }
  return contract
}

export function readNextReleaseSources(root = repositoryRoot) {
  const canonicalRoot = canonicalDirectory(root)
  const limits = new Map([
    ['VERSION', 1024],
    ['native-integrity.json', 64 * 1024],
    ['package.json', 256 * 1024],
  ])
  return new Map(candidateReleaseSourcePaths.map(relativePath => [
    relativePath,
    readRegularText(canonicalRoot, relativePath, limits.get(relativePath)),
  ]))
}

function parseArgs(args) {
  if (same(args, ['--check'])) return undefined
  if (args.length !== 7 || args[0] !== '--check') {
    fail('usage: --check [--release-tag vX.Y.Z --candidate-commit sha --origin-main-commit sha]')
  }
  const values = new Map()
  for (let index = 1; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (
      !['--release-tag', '--candidate-commit', '--origin-main-commit'].includes(name)
      || typeof value !== 'string'
      || value.length === 0
      || values.has(name)
    ) {
      fail('usage: --check [--release-tag vX.Y.Z --candidate-commit sha --origin-main-commit sha]')
    }
    values.set(name, value)
  }
  if (values.size !== 3) {
    fail('usage: --check [--release-tag vX.Y.Z --candidate-commit sha --origin-main-commit sha]')
  }
  return {
    releaseTag: values.get('--release-tag'),
    candidateCommit: values.get('--candidate-commit'),
    originMainCommit: values.get('--origin-main-commit'),
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2))
  const result = validateReleaseAdmission(
    readNextReleaseContract(),
    readNextReleaseSources(),
    readStableReleaseContract(),
    readStableReleaseSources(),
    options,
  )
  process.stdout.write(
    `Release admission contract verified: ${result.tag} is ${result.state}, candidateReady=${result.candidateReady}, ${result.verifiedGates}/${result.totalGates} gates verified.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
