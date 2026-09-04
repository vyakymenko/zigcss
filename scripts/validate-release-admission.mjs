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

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const plannedCandidateVersion = '0.7.0-rc.1'
export const candidateReleaseSourcePaths = Object.freeze([
  'VERSION',
  'native-integrity.json',
  'package.json',
])

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
      'A same-repository main Build run passes the complete test job and every architecture-matched build and provenance job for the candidate checkpoint.',
    ]),
  }),
  Object.freeze({
    id: 'origin-main-integration',
    evidenceRequirements: Object.freeze([
      'The final candidate is integrated into origin/main; tag admission independently requires the peeled candidate commit to equal the exact origin/main commit.',
    ]),
  }),
  Object.freeze({
    id: 'tag-workflow-publication',
    evidenceRequirements: Object.freeze([
      'The immutable tag workflow publishes the five-target GitHub prerelease and exact npm package on next with provenance and complete readback.',
    ]),
  }),
])

const preTagSurfaces = Object.freeze(candidateGatePolicy.slice(0, -1).map(gate => gate.id))
const postTagSurfaces = Object.freeze([candidateGatePolicy.at(-1).id])
const canonicalCommit = /^[0-9a-f]{40}$/
const maximumEvidenceItems = 8
const maximumEvidenceBytes = 512
const utf8Decoder = new TextDecoder('utf-8', { fatal: true })

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
}

function expectedImmutableHistory(stableContract) {
  return [
    {
      version: stableContract.previousPrerelease.version,
      tag: stableContract.previousPrerelease.tag,
      commit: stableContract.previousPrerelease.commit,
      npmDistTag: stableContract.previousPrerelease.npmDistTag,
      githubPrerelease: true,
    },
    {
      version: stableContract.candidateVersion,
      tag: stableContract.candidateTag,
      commit: stableContract.publicationEvidence.tagCommit,
      npmDistTag: stableContract.publicationEvidence.npmDistTag,
      githubPrerelease: stableContract.publicationEvidence.githubPrerelease,
    },
  ]
}

function validateImmutableHistory(history, stableContract) {
  if (!Array.isArray(history) || history.length !== 2) {
    fail('immutableHistory must contain the published prerelease and stable release exactly once')
  }
  for (const [index, entry] of history.entries()) {
    exactKeys(
      entry,
      ['version', 'tag', 'commit', 'npmDistTag', 'githubPrerelease'],
      `immutableHistory[${index}]`,
    )
    parseReleaseVersion(entry.version, `immutableHistory[${index}].version`)
    validateReleaseTag(entry.version, entry.tag)
    if (!canonicalCommit.test(entry.commit)) fail(`immutableHistory[${index}].commit is not canonical`)
  }
  const expected = expectedImmutableHistory(stableContract)
  if (!same(history, expected)) {
    fail('immutableHistory no longer matches the closed 0.6.0 publication evidence')
  }
}

function validateActiveSources(sources, candidateVersion, publishedStableVersion, candidateReady) {
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
  if (candidateReady) expectEqual(activeVersion, candidateVersion, 'publication-ready active version')
  return activeVersion
}

function validateContractShape(contract) {
  exactKeys(contract, [
    'schemaVersion',
    'ownerPackage',
    'releaseGapFamily',
    'state',
    'candidateReady',
    'candidateVersion',
    'candidateTag',
    'npmDistTag',
    'githubPrerelease',
    'immutableHistory',
    'preTagSurfaces',
    'postTagSurfaces',
    'gates',
  ], 'next release contract')
  expectEqual(contract.schemaVersion, 1, 'schemaVersion')
  expectEqual(contract.ownerPackage, 'REL-011', 'ownerPackage')
  expectEqual(contract.releaseGapFamily, 'next-release-candidate', 'releaseGapFamily')
  if (!['planned', 'candidate-ready'].includes(contract.state)) fail('state must be planned or candidate-ready')
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
    if (!['pending', 'verified'].includes(gate.state)) fail(`${gate.id} state is invalid`)
    if (!same(gate.evidenceRequirements, expected.evidenceRequirements)) {
      fail(`${gate.id} evidence requirements changed`)
    }
    validateEvidence(gate.evidence, gate.state, `${gate.id}.evidence`)
    byId.set(gate.id, gate)
  }
  return byId
}

function validateCandidateState(contract, gates) {
  const preTagComplete = preTagSurfaces.every(id => gates.get(id)?.state === 'verified')
  const publication = gates.get(postTagSurfaces[0])
  if (publication?.state !== 'pending' || publication.evidence.length !== 0) {
    fail('tag-workflow-publication must remain pending before the immutable tag runs')
  }
  if (contract.state === 'planned') {
    expectEqual(contract.candidateReady, false, 'planned candidateReady')
    if (preTagComplete) fail('planned candidate has every pre-tag gate verified but is not candidate-ready')
  } else {
    expectEqual(contract.candidateReady, true, 'candidate-ready candidateReady')
    if (!preTagComplete) fail('candidate-ready release has an incomplete pre-tag gate')
  }
}

export function validateNextReleaseContract(contract, sources, stableContract) {
  validateContractShape(contract)
  validateImmutableHistory(contract.immutableHistory, stableContract)
  const publishedStable = parseReleaseVersion(stableContract.candidateVersion, 'published stable version')
  if (compareReleaseVersionPrecedence(contract.candidateVersion, publishedStable.value) <= 0) {
    fail('planned candidate must be newer than the immutable published stable release')
  }
  const gates = validateGates(contract)
  validateCandidateState(contract, gates)
  const activeVersion = validateActiveSources(
    sources,
    contract.candidateVersion,
    publishedStable.value,
    contract.candidateReady,
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
  if (!canonicalCommit.test(options.candidateCommit)) fail('candidate commit must be a canonical lowercase SHA-1')
  if (!canonicalCommit.test(options.originMainCommit)) fail('origin main commit must be a canonical lowercase SHA-1')
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
    fail(`immutable stable evidence failed validation: ${error.message}`)
  }
  if (stableResult.state !== 'closed') {
    fail('immutable 0.6.0 stable evidence must remain closed')
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

  const historicalTags = new Set(candidateContract.immutableHistory.map(entry => entry.tag))
  const attemptVersion = attempt.releaseTag.slice(1)
  if (
    historicalTags.has(attempt.releaseTag)
    || compareReleaseVersionPrecedence(attemptVersion, stableContract.candidateVersion) <= 0
  ) {
    fail(`historical release tag ${attempt.releaseTag} is immutable and cannot be admitted again`)
  }
  if (attempt.releaseTag !== candidateContract.candidateTag) {
    fail(`release tag must match the sole planned candidate ${candidateContract.candidateTag}`)
  }
  if (candidateContract.state !== 'candidate-ready' || candidateContract.candidateReady !== true) {
    fail(`candidate ${candidateContract.candidateTag} is planned but not publication-ready`)
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
