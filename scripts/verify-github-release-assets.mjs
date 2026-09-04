import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { isDeepStrictEqual, TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)

const maximumArchiveBytes = 512 * 1024 * 1024
const maximumMetadataBytes = 16 * 1024 * 1024
const maximumReleaseJsonBytes = 2 * 1024 * 1024
const maximumAttestationPayloadBytes = 512 * 1024
const maximumPathBytes = 4096
const maximumDirectoryDepth = 8
const maximumInventoryEntries = 128
const maximumJsonDepth = 32
const maximumJsonNodes = 20_000
const maximumGitHubOutputBytes = 1024 * 1024

function fail(message) {
  throw new Error(`github release integrity: ${message}`)
}

function asciiCompare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function plainObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be a JSON object`)
  }
  return value
}

function boundedPath(value, label) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    Buffer.byteLength(value, 'utf8') > maximumPathBytes ||
    /[\0\r\n]/u.test(value)
  ) {
    fail(`${label} must be a nonempty path of at most ${maximumPathBytes} bytes without control separators`)
  }
  return path.resolve(value)
}

function lstat(filename, label) {
  try {
    return fs.lstatSync(filename, { bigint: true })
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
}

function fileIdentity(stat) {
  return [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs]
}

function sameIdentity(left, right) {
  const a = fileIdentity(left)
  const b = fileIdentity(right)
  return a.every((value, index) => value === b[index])
}

function readStableRegularFile(filename, label, maximumBytes, { allowEmpty = false } = {}) {
  const before = lstat(filename, label)
  if (!before.isFile() || before.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if ((!allowEmpty && before.size === 0n) || before.size > BigInt(maximumBytes)) {
    fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  }

  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0))
  } catch (error) {
    fail(`${label} could not be opened safely: ${error.message}`)
  }

  try {
    const opened = fs.fstatSync(descriptor, { bigint: true })
    if (!opened.isFile() || !sameIdentity(before, opened)) fail(`${label} changed before it was read`)
    const size = Number(opened.size)
    const bytes = Buffer.allocUnsafe(size)
    let offset = 0
    while (offset < size) {
      const count = fs.readSync(descriptor, bytes, offset, size - offset, offset)
      if (count === 0) fail(`${label} ended before its advertised size`)
      offset += count
    }
    const after = fs.fstatSync(descriptor, { bigint: true })
    if (!sameIdentity(opened, after)) fail(`${label} changed while it was read`)
    return { bytes, size }
  } finally {
    fs.closeSync(descriptor)
  }
}

function hashStableRegularFile(filename, label, maximumBytes) {
  const before = lstat(filename, label)
  if (!before.isFile() || before.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (before.size === 0n || before.size > BigInt(maximumBytes)) {
    fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  }

  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0))
  } catch (error) {
    fail(`${label} could not be opened safely: ${error.message}`)
  }

  try {
    const opened = fs.fstatSync(descriptor, { bigint: true })
    if (!opened.isFile() || !sameIdentity(before, opened)) fail(`${label} changed before it was read`)
    const hash = crypto.createHash('sha256')
    const buffer = Buffer.allocUnsafe(64 * 1024)
    let offset = 0
    const size = Number(opened.size)
    while (offset < size) {
      const count = fs.readSync(descriptor, buffer, 0, Math.min(buffer.length, size - offset), offset)
      if (count === 0) fail(`${label} ended before its advertised size`)
      hash.update(buffer.subarray(0, count))
      offset += count
    }
    const after = fs.fstatSync(descriptor, { bigint: true })
    if (!sameIdentity(opened, after)) fail(`${label} changed while it was read`)
    return { size, sha256: hash.digest('hex') }
  } finally {
    fs.closeSync(descriptor)
  }
}

function confinedRealPath(root, candidate, label) {
  let canonical
  try {
    canonical = fs.realpathSync(candidate)
  } catch (error) {
    fail(`${label} cannot be resolved: ${error.message}`)
  }
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the assets directory`)
  }
  return canonical
}

function expectedAssetPolicy(version) {
  const expected = new Map()
  for (const target of releaseTargets) {
    const assets = releaseAssetsFor(version, target.target)
    for (const [kind, name] of Object.entries(assets)) {
      if (expected.has(name)) fail(`generated release asset name is duplicated: ${name}`)
      expected.set(name, {
        kind,
        maximumBytes: kind === 'archive' ? maximumArchiveBytes : maximumMetadataBytes,
      })
    }
  }
  if (expected.size !== 25) fail(`release asset contract must contain exactly 25 names, received ${expected.size}`)
  return expected
}

function validateDirectoryName(name, label) {
  if (
    name === '.' ||
    name === '..' ||
    Buffer.byteLength(name, 'utf8') > 255 ||
    !/^[0-9A-Za-z._-]+$/u.test(name)
  ) {
    fail(`${label} has an unsafe directory name`)
  }
}

function collectLocalAssets(directory, expected) {
  const requestedRoot = boundedPath(directory, 'assets directory')
  const rootStat = lstat(requestedRoot, 'assets directory')
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    fail('assets directory must be a regular non-symlink directory')
  }
  const root = fs.realpathSync(requestedRoot)
  const assets = new Map()
  let entriesSeen = 0

  function walk(current, depth) {
    if (depth > maximumDirectoryDepth) {
      fail(`assets directory exceeds maximum depth ${maximumDirectoryDepth}`)
    }
    let handle
    try {
      handle = fs.opendirSync(current)
    } catch (error) {
      fail(`assets directory cannot be enumerated: ${error.message}`)
    }

    const entries = []
    try {
      while (true) {
        const entry = handle.readSync()
        if (entry === null) break
        entriesSeen += 1
        if (entriesSeen > maximumInventoryEntries) {
          fail(`assets directory exceeds ${maximumInventoryEntries} entries`)
        }
        entries.push(entry)
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith('github release integrity:')) throw error
      fail(`assets directory cannot be enumerated: ${error.message}`)
    } finally {
      handle.closeSync()
    }
    entries.sort((left, right) => asciiCompare(left.name, right.name))

    for (const entry of entries) {
      const candidate = path.join(current, entry.name)
      if (Buffer.byteLength(candidate, 'utf8') > maximumPathBytes) {
        fail(`release asset path exceeds ${maximumPathBytes} bytes`)
      }
      const relative = path.relative(root, candidate)
      const label = `release asset ${JSON.stringify(relative)}`
      const stat = lstat(candidate, label)
      if (stat.isSymbolicLink()) fail(`${label} must not be a symlink`)
      const canonical = confinedRealPath(root, candidate, label)

      if (stat.isDirectory()) {
        validateDirectoryName(entry.name, label)
        walk(canonical, depth + 1)
        continue
      }
      if (!stat.isFile()) fail(`${label} must be a regular non-symlink file`)

      const name = path.basename(candidate)
      const policy = expected.get(name)
      if (policy === undefined) fail(`unexpected release asset ${JSON.stringify(name)}`)
      if (assets.has(name)) fail(`duplicate release asset basename ${JSON.stringify(name)}`)
      const file = hashStableRegularFile(canonical, label, policy.maximumBytes)
      assets.set(name, {
        name,
        path: canonical,
        size: file.size,
        sha256: file.sha256,
      })
    }
  }

  walk(root, 0)
  const missing = [...expected.keys()].filter(name => !assets.has(name)).sort(asciiCompare)
  if (missing.length !== 0) fail(`missing release assets: ${missing.join(', ')}`)
  if (assets.size !== expected.size) {
    fail(`local release asset inventory must contain exactly ${expected.size} files, received ${assets.size}`)
  }
  return assets
}

function validateJsonBounds(value, label) {
  const stack = [{ value, depth: 0 }]
  let nodes = 0
  while (stack.length !== 0) {
    const current = stack.pop()
    nodes += 1
    if (nodes > maximumJsonNodes) fail(`${label} exceeds ${maximumJsonNodes} JSON nodes`)
    if (current.depth > maximumJsonDepth) fail(`${label} exceeds JSON depth ${maximumJsonDepth}`)
    if (current.value === null || typeof current.value !== 'object') continue
    const children = Array.isArray(current.value) ? current.value : Object.values(current.value)
    for (const child of children) stack.push({ value: child, depth: current.depth + 1 })
  }
}

function readBoundedJson(filename, label = 'release JSON') {
  const resolved = boundedPath(filename, `${label} path`)
  const { bytes } = readStableRegularFile(resolved, label, maximumReleaseJsonBytes)
  let text
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch (error) {
    fail(`${label} is not valid UTF-8: ${error.message}`)
  }
  let value
  try {
    value = JSON.parse(text)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
  validateJsonBounds(value, label)
  return value
}

function exactObjectKeys(value, expected, label) {
  const object = plainObject(value, label)
  const actual = Object.keys(object).sort(asciiCompare)
  const orderedExpected = [...expected].sort(asciiCompare)
  if (JSON.stringify(actual) !== JSON.stringify(orderedExpected)) {
    fail(`${label} must contain exactly ${orderedExpected.join(', ')}`)
  }
  return object
}

function decodeCanonicalBase64(value, label, maximumBytes) {
  if (
    typeof value !== 'string'
    || value.length === 0
    || value.length > Math.ceil(maximumBytes / 3) * 4
    || !/^(?:[0-9A-Za-z+/]{4})*(?:[0-9A-Za-z+/]{2}==|[0-9A-Za-z+/]{3}=)?$/u.test(value)
  ) {
    fail(`${label} must be canonical bounded base64`)
  }
  const bytes = Buffer.from(value, 'base64')
  if (bytes.length === 0 || bytes.length > maximumBytes || bytes.toString('base64') !== value) {
    fail(`${label} must decode to 1 through ${maximumBytes} bytes`)
  }
  return bytes
}

function decodeAttestationStatement(value) {
  const bytes = decodeCanonicalBase64(value, 'release attestation DSSE payload', maximumAttestationPayloadBytes)
  let text
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch (error) {
    fail(`release attestation DSSE payload is not valid UTF-8: ${error.message}`)
  }
  let statement
  try {
    statement = JSON.parse(text)
  } catch (error) {
    fail(`release attestation DSSE payload is not valid JSON: ${error.message}`)
  }
  validateJsonBounds(statement, 'release attestation statement')
  return plainObject(statement, 'release attestation statement')
}

function validateOptions(options) {
  plainObject(options, 'verification options')
  const phases = new Set(['absent', 'attestation', 'discovery', 'draft', 'latest', 'local', 'published', 'setting', 'tag'])
  if (!phases.has(options.phase)) {
    fail('release phase must be absent, attestation, discovery, draft, latest, local, published, setting, or tag')
  }
  const namesByPhase = {
    absent: ['phase', 'releaseJson', 'version'],
    attestation: ['assetsDirectory', 'attestationJson', 'commit', 'phase', 'releaseId', 'repository', 'version'],
    discovery: ['githubOutput', 'phase', 'releaseJson', 'version'],
    draft: ['assetsDirectory', 'phase', 'releaseJson', 'version'],
    latest: ['phase', 'releaseId', 'releaseJson', 'version'],
    local: ['assetsDirectory', 'phase', 'version'],
    published: ['assetsDirectory', 'commit', 'phase', 'releaseJson', 'tagRefJson', 'version'],
    setting: ['phase', 'releaseJson'],
    tag: ['commit', 'phase', 'tagRefJson', 'version'],
  }
  const names = namesByPhase[options.phase]
  const actualNames = Object.keys(options).sort(asciiCompare)
  if (JSON.stringify(actualNames) !== JSON.stringify(names)) {
    fail(`${options.phase} verification options must contain exactly ${names.join(', ')}`)
  }
  let parsedVersion
  if (options.phase !== 'setting') {
    parsedVersion = parseReleaseVersion(options.version, 'GitHub release version')
    if (parsedVersion.build !== null) fail('GitHub release version must not contain build metadata')
  }
  if (['attestation', 'published', 'tag'].includes(options.phase) && !/^[0-9a-f]{40}$/u.test(options.commit ?? '')) {
    fail('release commit must contain 40 lowercase hexadecimal characters')
  }
  let releaseId
  if (['attestation', 'latest'].includes(options.phase)) {
    if (typeof options.releaseId !== 'string' || !/^[1-9][0-9]*$/u.test(options.releaseId)) {
      fail('release ID must be a canonical positive decimal integer')
    }
    releaseId = Number(options.releaseId)
    if (!Number.isSafeInteger(releaseId)) fail('release ID must be a safe integer')
  }
  if (options.phase === 'attestation') {
    if (
      typeof options.repository !== 'string'
      || options.repository.length > 201
      || !/^[0-9A-Za-z](?:[0-9A-Za-z._-]{0,99})\/[0-9A-Za-z](?:[0-9A-Za-z._-]{0,99})$/u.test(options.repository)
    ) {
      fail('release repository must be a canonical owner/name pair')
    }
  }
  return { ...options, parsedVersion, ...(releaseId === undefined ? {} : { releaseId }) }
}

function validateReleaseIdentity(release, options) {
  const expectedTag = `v${options.version}`
  if (release.tag_name !== expectedTag) {
    fail(`release tag_name must be ${expectedTag}, received ${JSON.stringify(release.tag_name)}`)
  }
  const expectedPrerelease = options.parsedVersion.prerelease !== null
  if (release.prerelease !== expectedPrerelease) {
    fail(`release prerelease must be ${expectedPrerelease}, received ${JSON.stringify(release.prerelease)}`)
  }
  const expectedDraft = options.phase === 'draft'
  if (release.draft !== expectedDraft) {
    fail(`release draft must be ${expectedDraft} during ${options.phase} verification, received ${JSON.stringify(release.draft)}`)
  }
  if (options.phase === 'published') {
    if (release.immutable !== true) fail('published release must have immutable=true')
  } else if (Object.hasOwn(release, 'immutable') && release.immutable !== false) {
    fail('draft release immutable must be false or absent')
  }
  return expectedPrerelease
}

function verifyTagRefIdentity(normalized) {
  const tagRef = plainObject(readBoundedJson(normalized.tagRefJson), 'tag ref JSON')
  const expectedTag = `v${normalized.version}`
  const expectedRef = `refs/tags/${expectedTag}`
  if (tagRef.ref !== expectedRef) {
    fail(`tag ref must be ${expectedRef}, received ${JSON.stringify(tagRef.ref)}`)
  }
  const object = plainObject(tagRef.object, 'tag ref object')
  if (object.type !== 'commit') {
    fail(`tag ref object.type must be commit for the lightweight-tag release contract, received ${JSON.stringify(object.type)}`)
  }
  if (object.sha !== normalized.commit) {
    fail(`tag ref object.sha must be exact commit ${normalized.commit}, received ${JSON.stringify(object.sha)}`)
  }
  return Object.freeze({
    version: normalized.version,
    tag: expectedTag,
    ref: expectedRef,
    commit: normalized.commit,
    phase: 'tag',
    lightweight: true,
  })
}

function validateRemoteAssets(release, expected, localAssets) {
  if (!Array.isArray(release.assets) || release.assets.length !== expected.size) {
    fail(`GitHub release must contain exactly ${expected.size} assets, received ${Array.isArray(release.assets) ? release.assets.length : JSON.stringify(release.assets)}`)
  }
  const seen = new Set()
  for (const [index, value] of release.assets.entries()) {
    const asset = plainObject(value, `GitHub release asset ${index}`)
    if (typeof asset.name !== 'string' || !expected.has(asset.name)) {
      fail(`unexpected GitHub release asset name ${JSON.stringify(asset.name)}`)
    }
    if (seen.has(asset.name)) fail(`duplicate GitHub release asset name ${JSON.stringify(asset.name)}`)
    seen.add(asset.name)
  }
  seen.clear()
  for (const [index, value] of release.assets.entries()) {
    const asset = plainObject(value, `GitHub release asset ${index}`)
    seen.add(asset.name)
    if (asset.state !== 'uploaded') {
      fail(`GitHub release asset ${asset.name} state must be uploaded, received ${JSON.stringify(asset.state)}`)
    }
    const local = localAssets.get(asset.name)
    const maximumBytes = expected.get(asset.name).maximumBytes
    if (!Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size > maximumBytes) {
      fail(`GitHub release asset ${asset.name} size must be an integer from 1 through ${maximumBytes}`)
    }
    if (asset.size !== local.size) {
      fail(`GitHub release asset ${asset.name} size ${asset.size} does not match local size ${local.size}`)
    }
    const expectedDigest = `sha256:${local.sha256}`
    if (asset.digest !== expectedDigest) {
      fail(`GitHub release asset ${asset.name} digest does not match local SHA-256`)
    }
  }
  const missing = [...expected.keys()].filter(name => !seen.has(name)).sort(asciiCompare)
  if (missing.length !== 0) fail(`GitHub release is missing assets: ${missing.join(', ')}`)
}

function inventorySummary(version, phase, localAssets) {
  const ordered = [...localAssets.values()].sort((left, right) => asciiCompare(left.name, right.name))
  const inventory = ordered.map(asset => `${asset.sha256} ${asset.size} ${asset.name}\n`).join('')
  return {
    version,
    phase,
    assetCount: ordered.length,
    totalBytes: ordered.reduce((total, asset) => total + asset.size, 0),
    inventorySha256: crypto.createHash('sha256').update(inventory, 'utf8').digest('hex'),
  }
}

function releaseListingEntries(value) {
  if (!Array.isArray(value)) fail('release listing JSON must be an array or array of arrays')
  const nested = value.some(Array.isArray)
  if (nested && value.some(page => !Array.isArray(page))) {
    fail('release listing JSON must not mix pages and release entries')
  }
  const values = nested ? value.flatMap((page, pageIndex) => {
    if (page.some(Array.isArray)) fail(`release listing page ${pageIndex} must contain only release objects`)
    return page
  }) : value
  return values.map((entry, index) => {
    const release = plainObject(entry, `release listing entry ${index}`)
    if (typeof release.tag_name !== 'string' || release.tag_name.length === 0 || release.tag_name.length > 256) {
      fail(`release listing entry ${index} must have a bounded string tag_name`)
    }
    return release
  })
}

function verifyAbsentRelease(normalized) {
  const releases = releaseListingEntries(readBoundedJson(normalized.releaseJson))
  const tag = `v${normalized.version}`
  const match = releases.find(release => release.tag_name === tag)
  if (match !== undefined) {
    fail(`release tag ${tag} already exists in the authenticated listing (draft=${JSON.stringify(match.draft)})`)
  }
  return Object.freeze({
    version: normalized.version,
    tag,
    phase: 'absent',
    inspectedReleases: releases.length,
    matchingReleases: 0,
  })
}

function appendGitHubOutput(filename, values) {
  const resolved = boundedPath(filename, 'GitHub output path')
  const stat = lstat(resolved, 'GitHub output')
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > BigInt(maximumGitHubOutputBytes)) {
    fail('GitHub output must be a bounded regular non-symlink file')
  }
  const output = Object.entries(values).map(([name, value]) => `${name}=${value}\n`).join('')
  if (stat.size + BigInt(Buffer.byteLength(output)) > BigInt(maximumGitHubOutputBytes)) {
    fail('GitHub output would exceed its byte limit')
  }
  fs.appendFileSync(resolved, output, { encoding: 'utf8', flag: 'a' })
}

function verifyReleaseDiscovery(normalized) {
  const response = plainObject(readBoundedJson(normalized.releaseJson), 'release discovery JSON')
  if (Object.hasOwn(response, 'errors')) fail('release discovery JSON must not contain GraphQL errors')
  const data = plainObject(response.data, 'release discovery data')
  const repository = plainObject(data.repository, 'release discovery repository')
  const discovered = repository.release
  const tag = `v${normalized.version}`

  let mode = 'create'
  let releaseId = 0
  if (discovered !== null) {
    const release = plainObject(discovered, 'discovered release')
    if (release.tagName !== tag) {
      fail(`discovered release tagName must be ${tag}, received ${JSON.stringify(release.tagName)}`)
    }
    if (!Number.isSafeInteger(release.databaseId) || release.databaseId <= 0) {
      fail(`existing release ${tag} must have a positive safe integer id`)
    }
    const expectedPrerelease = normalized.parsedVersion.prerelease !== null
    if (release.isPrerelease !== expectedPrerelease) {
      fail(`existing release ${tag} prerelease must be ${expectedPrerelease}`)
    }
    if (typeof release.isDraft !== 'boolean') fail(`existing release ${tag} isDraft must be boolean`)
    releaseId = release.databaseId
    mode = release.isDraft ? 'draft' : 'published'
  }

  appendGitHubOutput(normalized.githubOutput, {
    'release-mode': mode,
    'release-id': releaseId,
  })
  return Object.freeze({
    version: normalized.version,
    tag,
    phase: 'discovery',
    inspectedReleases: discovered === null ? 0 : 1,
    mode,
    releaseId,
  })
}

function verifyLatestRelease(normalized) {
  if (normalized.parsedVersion.prerelease !== null) {
    fail('latest release verification requires a stable version')
  }
  const release = plainObject(readBoundedJson(normalized.releaseJson, 'latest release JSON'), 'latest release JSON')
  const expectedTag = `v${normalized.version}`
  if (release.id !== normalized.releaseId) {
    fail(`latest release id must be ${normalized.releaseId}, received ${JSON.stringify(release.id)}`)
  }
  if (release.tag_name !== expectedTag) {
    fail(`latest release tag_name must be ${expectedTag}, received ${JSON.stringify(release.tag_name)}`)
  }
  if (release.draft !== false || release.prerelease !== false) {
    fail('latest release must be a published stable release')
  }
  if (release.immutable !== true) fail('latest release must have immutable=true')
  return Object.freeze({
    version: normalized.version,
    tag: expectedTag,
    releaseId: normalized.releaseId,
    phase: 'latest',
    latest: true,
    immutable: true,
  })
}

function verifyReleaseAttestation(normalized, expected, localAssets) {
  const response = plainObject(
    readBoundedJson(normalized.attestationJson, 'release attestation JSON'),
    'release attestation JSON',
  )
  const attestation = plainObject(response.attestation, 'release attestation')
  const bundle = plainObject(attestation.bundle, 'release attestation bundle')
  if (bundle.mediaType !== 'application/vnd.dev.sigstore.bundle.v0.3+json') {
    fail('release attestation bundle has an unsupported mediaType')
  }
  const envelope = plainObject(bundle.dsseEnvelope, 'release attestation DSSE envelope')
  if (envelope.payloadType !== 'application/vnd.in-toto+json') {
    fail('release attestation DSSE payloadType must be application/vnd.in-toto+json')
  }
  if (!Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) {
    fail('release attestation DSSE envelope must contain exactly one signature')
  }
  const signature = exactObjectKeys(envelope.signatures[0], ['sig'], 'release attestation DSSE signature')
  decodeCanonicalBase64(signature.sig, 'release attestation DSSE signature', 16 * 1024)

  const statement = decodeAttestationStatement(envelope.payload)
  const verification = plainObject(response.verificationResult, 'release attestation verification result')
  if (verification.mediaType !== 'application/vnd.dev.sigstore.verificationresult+json;version=0.1') {
    fail('release attestation verification result has an unsupported mediaType')
  }
  const certificate = plainObject(
    plainObject(verification.signature, 'release attestation verified signature').certificate,
    'release attestation verified certificate',
  )
  if (certificate.subjectAlternativeName !== 'https://dotcom.releases.github.com') {
    fail('release attestation verified signer must be GitHub Releases')
  }
  const verifiedStatement = plainObject(verification.statement, 'release attestation verified statement')
  if (!isDeepStrictEqual(verifiedStatement, statement)) {
    fail('release attestation DSSE payload must equal the signature-verified statement')
  }

  if (statement._type !== 'https://in-toto.io/Statement/v1') {
    fail('release attestation statement has an unsupported _type')
  }
  const predicateType = 'https://in-toto.io/attestation/release/v0.2'
  if (statement.predicateType !== predicateType) {
    fail(`release attestation predicateType must be ${predicateType}`)
  }
  const predicate = plainObject(statement.predicate, 'release attestation predicate')
  const tag = `v${normalized.version}`
  const purl = `pkg:github/${normalized.repository}@${tag}`
  if (predicate.databaseId !== String(normalized.releaseId)) {
    fail(`release attestation databaseId must be ${normalized.releaseId}`)
  }
  if (predicate.repository !== normalized.repository) {
    fail(`release attestation repository must be ${normalized.repository}`)
  }
  if (predicate.tag !== tag) fail(`release attestation tag must be ${tag}`)
  if (predicate.purl !== purl) fail(`release attestation purl must be ${purl}`)
  for (const name of ['ownerId', 'packageId', 'repositoryId']) {
    if (typeof predicate[name] !== 'string' || !/^[1-9][0-9]*$/u.test(predicate[name])) {
      fail(`release attestation predicate ${name} must be a canonical positive decimal integer`)
    }
  }
  if (predicate.packageId !== predicate.repositoryId) {
    fail('release attestation packageId must equal repositoryId')
  }

  if (!Array.isArray(statement.subject) || statement.subject.length !== expected.size + 1) {
    fail(`release attestation must contain exactly one tag and ${expected.size} asset subjects`)
  }
  let tagSubjects = 0
  const seen = new Set()
  for (const [index, value] of statement.subject.entries()) {
    const subject = plainObject(value, `release attestation subject ${index}`)
    if (Object.hasOwn(subject, 'uri')) {
      exactObjectKeys(subject, ['digest', 'uri'], `release attestation tag subject ${index}`)
      if (subject.uri !== purl) fail(`release attestation tag subject uri must be ${purl}`)
      const digest = exactObjectKeys(subject.digest, ['sha1'], `release attestation tag subject ${index} digest`)
      if (digest.sha1 !== normalized.commit) {
        fail(`release attestation tag subject must bind exact commit ${normalized.commit}`)
      }
      tagSubjects += 1
      if (tagSubjects > 1) fail('release attestation repeats the tag subject')
      continue
    }

    exactObjectKeys(subject, ['digest', 'name'], `release attestation asset subject ${index}`)
    if (typeof subject.name !== 'string' || !expected.has(subject.name)) {
      fail(`unexpected release attestation asset subject ${JSON.stringify(subject.name)}`)
    }
    if (seen.has(subject.name)) fail(`duplicate release attestation asset subject ${JSON.stringify(subject.name)}`)
    const digest = exactObjectKeys(subject.digest, ['sha256'], `release attestation asset subject ${subject.name} digest`)
    if (digest.sha256 !== localAssets.get(subject.name).sha256) {
      fail(`release attestation asset subject ${subject.name} does not match local SHA-256`)
    }
    seen.add(subject.name)
  }
  if (tagSubjects !== 1) fail('release attestation must contain exactly one tag subject')
  const missing = [...expected.keys()].filter(name => !seen.has(name)).sort(asciiCompare)
  if (missing.length !== 0) fail(`release attestation is missing asset subjects: ${missing.join(', ')}`)

  return Object.freeze({
    ...inventorySummary(normalized.version, 'attestation', localAssets),
    repository: normalized.repository,
    tag,
    commit: normalized.commit,
    releaseId: normalized.releaseId,
    predicateType,
    attestedAssetCount: seen.size,
  })
}

function verifyImmutableSetting(normalized) {
  const setting = exactObjectKeys(
    readBoundedJson(normalized.releaseJson),
    ['enabled', 'enforced_by_owner'],
    'immutable releases setting JSON',
  )
  if (setting.enabled !== true) fail('repository immutable releases setting must have enabled=true')
  if (setting.enforced_by_owner !== false) {
    fail('repository immutable releases setting must have enforced_by_owner=false')
  }
  return Object.freeze({
    phase: 'setting',
    immutableReleasesEnabled: true,
    enforcedByOwner: false,
  })
}

export function verifyGitHubReleaseAssets(options) {
  const normalized = validateOptions(options)
  if (normalized.phase === 'absent') return verifyAbsentRelease(normalized)
  if (normalized.phase === 'discovery') return verifyReleaseDiscovery(normalized)
  if (normalized.phase === 'latest') return verifyLatestRelease(normalized)
  if (normalized.phase === 'setting') return verifyImmutableSetting(normalized)
  if (normalized.phase === 'tag') return verifyTagRefIdentity(normalized)

  const expected = expectedAssetPolicy(normalized.version)
  const localAssets = collectLocalAssets(normalized.assetsDirectory, expected)
  if (normalized.phase === 'attestation') return verifyReleaseAttestation(normalized, expected, localAssets)
  const localSummary = inventorySummary(normalized.version, normalized.phase, localAssets)
  if (normalized.phase === 'local') return Object.freeze(localSummary)

  const release = plainObject(readBoundedJson(normalized.releaseJson), 'release JSON')
  const prerelease = validateReleaseIdentity(release, normalized)
  if (normalized.phase === 'published') verifyTagRefIdentity(normalized)
  validateRemoteAssets(release, expected, localAssets)

  return Object.freeze({
    ...localSummary,
    tag: `v${normalized.version}`,
    ...(normalized.phase === 'published' ? { commit: normalized.commit } : {}),
    prerelease,
    immutable: release.immutable === true,
  })
}

function parseCliOptions(args) {
  const mapping = new Map([
    ['--release-json', 'releaseJson'],
    ['--attestation-json', 'attestationJson'],
    ['--assets-directory', 'assetsDirectory'],
    ['--version', 'version'],
    ['--commit', 'commit'],
    ['--github-output', 'githubOutput'],
    ['--release-id', 'releaseId'],
    ['--repository', 'repository'],
    ['--tag-ref-json', 'tagRefJson'],
    ['--phase', 'phase'],
  ])
  const values = {}
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index]
    const value = args[index + 1]
    const key = mapping.get(option)
    if (key === undefined || value === undefined || Object.hasOwn(values, key)) {
      fail(`invalid or repeated command option ${JSON.stringify(option)}`)
    }
    values[key] = value
  }
  const requiredByPhase = {
    absent: ['releaseJson', 'version', 'phase'],
    attestation: ['attestationJson', 'assetsDirectory', 'version', 'commit', 'releaseId', 'repository', 'phase'],
    discovery: ['releaseJson', 'githubOutput', 'version', 'phase'],
    draft: ['releaseJson', 'assetsDirectory', 'version', 'phase'],
    latest: ['releaseJson', 'version', 'releaseId', 'phase'],
    local: ['assetsDirectory', 'version', 'phase'],
    published: ['releaseJson', 'assetsDirectory', 'tagRefJson', 'version', 'commit', 'phase'],
    setting: ['releaseJson', 'phase'],
    tag: ['tagRefJson', 'version', 'commit', 'phase'],
  }
  const required = requiredByPhase[values.phase]
  const actual = Object.keys(values).sort(asciiCompare)
  if (required === undefined || JSON.stringify(actual) !== JSON.stringify([...required].sort(asciiCompare))) {
    fail('command options must exactly match phase: setting=release-json; absent=release-json+version; discovery=release-json+github-output+version; local=assets-directory+version; draft=release-json+assets-directory+version; tag=tag-ref-json+version+commit; published=release-json+assets-directory+tag-ref-json+version+commit; latest=release-json+release-id+version; attestation=attestation-json+assets-directory+repository+release-id+version+commit')
  }
  return values
}

function main() {
  const summary = verifyGitHubReleaseAssets(parseCliOptions(process.argv.slice(2)))
  process.stdout.write(`${JSON.stringify(summary)}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  }
}
