import { spawnSync } from 'node:child_process'
import https from 'node:https'
import path from 'node:path'
import { setTimeout as wait } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { TextDecoder } from 'node:util'
import {
  inspectNpmPackageArchive,
  inspectNpmPackageBytes,
  npmPackageArtifactLimits,
} from './npm-package-artifact.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const registry = 'https://registry.npmjs.org/'
const maximumResponseBytes = 256 * 1024
const maximumAttestationResponseBytes = 256 * 1024
const maximumDssePayloadBytes = 64 * 1024
const downloadTimeoutMs = 30_000
const registryOrigin = 'https://registry.npmjs.org'
const provenancePredicateType = 'https://slsa.dev/provenance/v1'
const publishPredicateType = 'https://github.com/npm/attestation/tree/main/specs/publish/v0.1'
const sigstoreBundleMediaType = 'application/vnd.dev.sigstore.bundle+json;version=0.2'
const inTotoPayloadType = 'application/vnd.in-toto+json'
const githubActionsBuildType = 'https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1'
const workflowRepository = 'https://github.com/vyakymenko/zigcss'
const workflowPath = '.github/workflows/release.yml'
const utf8Decoder = new TextDecoder('utf-8', { fatal: true })
export const npmPublicationReadbackPolicy = Object.freeze({
  attempts: 12,
  delayMs: 5_000,
})

function fail(message) {
  throw new Error(`npm publication readback: ${message}`)
}

function parseJson(source, label, maximumBytes = maximumResponseBytes) {
  let text
  if (Buffer.isBuffer(source)) {
    if (source.length === 0 || source.length > maximumBytes) fail(`${label} is empty or oversized`)
    try {
      text = utf8Decoder.decode(source)
    } catch (error) {
      fail(`${label} is not valid UTF-8: ${error.message}`)
    }
  } else if (typeof source === 'string') {
    if (Buffer.byteLength(source) === 0 || Buffer.byteLength(source) > maximumBytes) {
      fail(`${label} is empty or oversized`)
    }
    text = source
  } else {
    fail(`${label} is empty or oversized`)
  }
  try {
    return JSON.parse(text)
  } catch (error) {
    fail(`${label} is not JSON: ${error.message}`)
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasExactKeys(value, expected) {
  if (!isPlainObject(value)) return false
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index])
}

function decodeBase64(value, label, maximumBytes) {
  if (
    typeof value !== 'string'
    || value.length === 0
    || value.length > Math.ceil(maximumBytes / 3) * 4
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    fail(`${label} is not bounded canonical base64`)
  }
  const decoded = Buffer.from(value, 'base64')
  if (decoded.length === 0 || decoded.length > maximumBytes || decoded.toString('base64') !== value) {
    fail(`${label} is not bounded canonical base64`)
  }
  return decoded
}

function expectedSha512Hex(expectedPackage) {
  return Buffer.from(expectedPackage.integrity.slice('sha512-'.length), 'base64').toString('hex')
}

function expectedAttestationUrl(version) {
  return `${registryOrigin}/-/npm/v1/attestations/zigcss@${version}`
}

function validateAttestationUrl(value, version) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 8 * 1024) {
    fail('npm attestation URL is empty or oversized')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch (error) {
    fail(`npm attestation URL is invalid: ${error.message}`)
  }
  const expected = `/-/npm/v1/attestations/zigcss@${version}`
  if (
    parsed.protocol !== 'https:'
    || parsed.hostname !== 'registry.npmjs.org'
    || parsed.port !== ''
    || parsed.pathname !== expected
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.search !== ''
    || parsed.hash !== ''
  ) {
    fail(`npm attestation URL must be ${registryOrigin}${expected}`)
  }
  return parsed.href
}

function validateExpectedPackage(value, version) {
  if (
    value === null
    || typeof value !== 'object'
    || Array.isArray(value)
    || value.name !== 'zigcss'
    || value.version !== version
    || value.filename !== `zigcss-${version}.tgz`
    || !/^[0-9a-f]{40}$/.test(value.shasum)
    || !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(value.integrity)
  ) {
    fail('tested package artifact identity is invalid')
  }
  const digest = Buffer.from(value.integrity.slice('sha512-'.length), 'base64')
  if (digest.length !== 64) fail('tested package artifact integrity is malformed')
  return value
}

function validateTarballUrl(value, version, filename) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 8 * 1024) {
    fail('published tarball URL is empty or oversized')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch (error) {
    fail(`published tarball URL is invalid: ${error.message}`)
  }
  const expected = `/zigcss/-/${filename}`
  if (
    parsed.protocol !== 'https:'
    || parsed.hostname !== 'registry.npmjs.org'
    || parsed.port !== ''
    || parsed.pathname !== expected
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.search !== ''
    || parsed.hash !== ''
  ) {
    fail(`published tarball URL must be https://registry.npmjs.org${expected}`)
  }
  parseReleaseVersion(version, 'published tarball version')
  return parsed.href
}

export function validateNpmPublicationReadback(
  version,
  versionSource,
  tagsSource,
  distSource,
  expectedPackage,
) {
  const parsedVersion = parseReleaseVersion(version, 'npm publication version')
  const channel = parsedVersion.prerelease === null ? 'latest' : 'next'
  const expected = validateExpectedPackage(expectedPackage, version)

  const publishedVersion = parseJson(versionSource, 'published version response')
  if (publishedVersion !== version) {
    fail(`published version must be ${version}, received ${JSON.stringify(publishedVersion)}`)
  }

  const tags = parseJson(tagsSource, 'distribution-tag response')
  if (tags === null || typeof tags !== 'object' || Array.isArray(tags)) {
    fail('distribution tags must be a JSON object')
  }
  const entries = Object.entries(tags)
  if (entries.length === 0 || entries.length > 100) {
    fail('distribution tags must be a bounded non-empty object')
  }
  const parsedTags = new Map()
  for (const [name, value] of entries) {
    if (!/^[a-z][a-z0-9._-]{0,63}$/.test(name) || typeof value !== 'string') {
      fail('distribution tags contain an invalid name or non-string version')
    }
    parsedTags.set(name, parseReleaseVersion(value, `npm distribution tag ${name}`))
  }
  if (tags[channel] !== version) {
    fail(`${channel} tag must be ${version}, received ${JSON.stringify(tags[channel])}`)
  }
  if (channel === 'next') {
    if (!parsedTags.has('latest') || parsedTags.get('latest').prerelease !== null) {
      fail('prerelease publication must retain a stable latest tag')
    }
  } else if (!parsedTags.has('next') || parsedTags.get('next').prerelease === null) {
    fail('stable publication must retain a prerelease next tag')
  }

  const dist = parseJson(distSource, 'distribution metadata response')
  if (dist === null || typeof dist !== 'object' || Array.isArray(dist)) {
    fail('distribution metadata must be a JSON object')
  }
  const distKeys = Object.keys(dist)
  if (distKeys.length < 3 || distKeys.length > 32) {
    fail('distribution metadata must be a bounded object')
  }
  if (dist.shasum !== expected.shasum) {
    fail(`published shasum must be ${expected.shasum}, received ${JSON.stringify(dist.shasum)}`)
  }
  if (dist.integrity !== expected.integrity) {
    fail(`published integrity must be ${expected.integrity}, received ${JSON.stringify(dist.integrity)}`)
  }
  if (!hasExactKeys(dist.attestations, ['provenance', 'url'])) {
    fail('distribution metadata must advertise one exact npm provenance endpoint')
  }
  if (
    !hasExactKeys(dist.attestations.provenance, ['predicateType'])
    || dist.attestations.provenance.predicateType !== provenancePredicateType
  ) {
    fail(`distribution metadata provenance must advertise ${provenancePredicateType}`)
  }
  const tarballUrl = validateTarballUrl(dist.tarball, version, expected.filename)
  const attestationUrl = validateAttestationUrl(dist.attestations.url, version)
  return { version, channel, tarballUrl, attestationUrl }
}

function validateDsseSignature(signature, label, expectedKeyKind) {
  if (!hasExactKeys(signature, ['keyid', 'sig']) || typeof signature.keyid !== 'string') {
    fail(`${label} DSSE signature is malformed`)
  }
  decodeBase64(signature.sig, `${label} DSSE signature`, 16 * 1024)
  if (expectedKeyKind === 'certificate' && signature.keyid !== '') {
    fail(`${label} certificate-backed DSSE signature must have an empty key ID`)
  }
  if (
    expectedKeyKind === 'public-key'
    && (!/^SHA256:[A-Za-z0-9+/]+={0,2}$/.test(signature.keyid) || Buffer.byteLength(signature.keyid) > 256)
  ) {
    fail(`${label} public-key DSSE signature has an invalid key ID`)
  }
}

function validateVerificationMaterial(value, label, expectedKeyKind, signatureKeyId) {
  const expectedKeys = expectedKeyKind === 'certificate'
    ? ['timestampVerificationData', 'tlogEntries', 'x509CertificateChain']
    : ['publicKey', 'timestampVerificationData', 'tlogEntries']
  if (!hasExactKeys(value, expectedKeys)) fail(`${label} Sigstore verification material is malformed`)
  if (!Array.isArray(value.tlogEntries) || value.tlogEntries.length !== 1 || !isPlainObject(value.tlogEntries[0])) {
    fail(`${label} Sigstore transparency-log material is malformed`)
  }
  if (
    !hasExactKeys(value.timestampVerificationData, ['rfc3161Timestamps'])
    || !Array.isArray(value.timestampVerificationData.rfc3161Timestamps)
    || value.timestampVerificationData.rfc3161Timestamps.length > 8
  ) {
    fail(`${label} Sigstore timestamp material is malformed`)
  }
  if (expectedKeyKind === 'certificate') {
    const chain = value.x509CertificateChain
    if (
      !hasExactKeys(chain, ['certificates'])
      || !Array.isArray(chain.certificates)
      || chain.certificates.length !== 1
      || !hasExactKeys(chain.certificates[0], ['rawBytes'])
    ) {
      fail(`${label} Sigstore certificate chain is malformed`)
    }
    decodeBase64(chain.certificates[0].rawBytes, `${label} Sigstore certificate`, 32 * 1024)
  } else if (
    !hasExactKeys(value.publicKey, ['hint'])
    || value.publicKey.hint !== signatureKeyId
  ) {
    fail(`${label} Sigstore public-key material does not match its DSSE signature`)
  }
}

function parseSigstoreStatement(attestation, label, expectedKeyKind) {
  if (
    !hasExactKeys(attestation, ['bundle', 'predicateType', 'signedAccessSignatureUrl'])
    || attestation.signedAccessSignatureUrl !== ''
  ) {
    fail(`${label} npm attestation is malformed`)
  }
  const bundle = attestation.bundle
  if (!hasExactKeys(bundle, ['dsseEnvelope', 'mediaType', 'verificationMaterial'])) {
    fail(`${label} Sigstore bundle is malformed`)
  }
  if (bundle.mediaType !== sigstoreBundleMediaType) {
    fail(`${label} Sigstore bundle has an unexpected media type`)
  }
  const envelope = bundle.dsseEnvelope
  if (!hasExactKeys(envelope, ['payload', 'payloadType', 'signatures'])) {
    fail(`${label} DSSE envelope is malformed`)
  }
  if (envelope.payloadType !== inTotoPayloadType) {
    fail(`${label} DSSE payload type must be ${inTotoPayloadType}`)
  }
  if (!Array.isArray(envelope.signatures) || envelope.signatures.length !== 1) {
    fail(`${label} DSSE envelope must contain exactly one signature`)
  }
  validateDsseSignature(envelope.signatures[0], label, expectedKeyKind)
  validateVerificationMaterial(
    bundle.verificationMaterial,
    label,
    expectedKeyKind,
    envelope.signatures[0].keyid,
  )
  const payload = decodeBase64(envelope.payload, `${label} DSSE payload`, maximumDssePayloadBytes)
  return parseJson(payload, `${label} DSSE payload`, maximumDssePayloadBytes)
}

function validateStatementSubject(statement, version, expectedPackage, label) {
  if (!Array.isArray(statement.subject) || statement.subject.length !== 1) {
    fail(`${label} statement must contain exactly one subject`)
  }
  const subject = statement.subject[0]
  if (
    !hasExactKeys(subject, ['digest', 'name'])
    || subject.name !== `pkg:npm/zigcss@${version}`
    || !hasExactKeys(subject.digest, ['sha512'])
    || subject.digest.sha512 !== expectedSha512Hex(expectedPackage)
  ) {
    fail(`${label} statement subject does not match the exact tested npm archive`)
  }
}

function validatePublishStatement(statement, version, expectedPackage) {
  const label = 'npm publish attestation'
  if (
    !hasExactKeys(statement, ['_type', 'predicate', 'predicateType', 'subject'])
    || statement._type !== 'https://in-toto.io/Statement/v0.1'
    || statement.predicateType !== publishPredicateType
  ) {
    fail(`${label} statement is malformed`)
  }
  validateStatementSubject(statement, version, expectedPackage, label)
  if (
    !hasExactKeys(statement.predicate, ['name', 'registry', 'version'])
    || statement.predicate.name !== 'zigcss'
    || statement.predicate.version !== version
    || statement.predicate.registry !== registryOrigin
  ) {
    fail(`${label} predicate does not match the exact npm publication`)
  }
}

function validateProvenanceStatement(statement, version, expectedPackage, expectedCommit) {
  const label = 'npm provenance attestation'
  if (
    !hasExactKeys(statement, ['_type', 'predicate', 'predicateType', 'subject'])
    || statement._type !== 'https://in-toto.io/Statement/v1'
    || statement.predicateType !== provenancePredicateType
  ) {
    fail(`${label} statement is malformed`)
  }
  validateStatementSubject(statement, version, expectedPackage, label)
  if (!hasExactKeys(statement.predicate, ['buildDefinition', 'runDetails'])) {
    fail(`${label} predicate is malformed`)
  }
  const buildDefinition = statement.predicate.buildDefinition
  if (
    !hasExactKeys(
      buildDefinition,
      ['buildType', 'externalParameters', 'internalParameters', 'resolvedDependencies'],
    )
    || buildDefinition.buildType !== githubActionsBuildType
  ) {
    fail(`${label} build definition is malformed`)
  }
  const external = buildDefinition.externalParameters
  const workflow = isPlainObject(external) ? external.workflow : null
  if (
    !hasExactKeys(external, ['workflow'])
    || !hasExactKeys(workflow, ['path', 'ref', 'repository'])
    || workflow.repository !== workflowRepository
    || workflow.path !== workflowPath
    || workflow.ref !== `refs/tags/v${version}`
  ) {
    fail(`${label} workflow identity does not match the exact release workflow`)
  }
  if (!isPlainObject(buildDefinition.internalParameters)) {
    fail(`${label} internal parameters are malformed`)
  }
  const dependencies = buildDefinition.resolvedDependencies
  const expectedUri = `git+${workflowRepository}@refs/tags/v${version}`
  if (
    !Array.isArray(dependencies)
    || dependencies.length !== 1
    || !hasExactKeys(dependencies[0], ['digest', 'uri'])
    || dependencies[0].uri !== expectedUri
    || !hasExactKeys(dependencies[0].digest, ['gitCommit'])
    || dependencies[0].digest.gitCommit !== expectedCommit
  ) {
    fail(`${label} resolved dependency does not match the exact release commit`)
  }
  const runDetails = statement.predicate.runDetails
  if (
    !hasExactKeys(runDetails, ['builder', 'metadata'])
    || !hasExactKeys(runDetails.builder, ['id'])
    || runDetails.builder.id !== 'https://github.com/actions/runner/github-hosted'
    || !hasExactKeys(runDetails.metadata, ['invocationId'])
    || !/^https:\/\/github\.com\/vyakymenko\/zigcss\/actions\/runs\/[1-9][0-9]*\/attempts\/[1-9][0-9]*$/.test(
      runDetails.metadata.invocationId,
    )
  ) {
    fail(`${label} GitHub Actions run details are malformed`)
  }
}

export function validateNpmAttestationReadback(version, source, expectedPackage, expectedCommit) {
  parseReleaseVersion(version, 'npm attestation version')
  const expected = validateExpectedPackage(expectedPackage, version)
  if (typeof expectedCommit !== 'string' || !/^[0-9a-f]{40}$/.test(expectedCommit)) {
    fail('expected GitHub release commit must be one lowercase 40-character SHA')
  }
  const response = parseJson(source, 'npm attestation response', maximumAttestationResponseBytes)
  if (!hasExactKeys(response, ['attestations']) || !Array.isArray(response.attestations)) {
    fail('npm attestation response is malformed')
  }
  if (response.attestations.length < 1 || response.attestations.length > 2) {
    fail('npm attestation response must contain only provenance and optional publish attestations')
  }

  const seen = new Set()
  for (const attestation of response.attestations) {
    if (!isPlainObject(attestation) || typeof attestation.predicateType !== 'string') {
      fail('npm attestation response contains a malformed attestation')
    }
    if (seen.has(attestation.predicateType)) fail('npm attestation response contains duplicate predicate types')
    seen.add(attestation.predicateType)
    if (attestation.predicateType === provenancePredicateType) {
      const statement = parseSigstoreStatement(attestation, 'npm provenance attestation', 'certificate')
      validateProvenanceStatement(statement, version, expected, expectedCommit)
    } else if (attestation.predicateType === publishPredicateType) {
      const statement = parseSigstoreStatement(attestation, 'npm publish attestation', 'public-key')
      validatePublishStatement(statement, version, expected)
    } else {
      fail(`npm attestation response contains unexpected predicate ${JSON.stringify(attestation.predicateType)}`)
    }
  }
  if (!seen.has(provenancePredicateType)) {
    fail(`npm attestation response is missing ${provenancePredicateType}`)
  }
  return { predicateType: provenancePredicateType }
}

function runNpmView(args, label) {
  const executable = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const result = spawnSync(executable, [...args, '--json', `--registry=${registry}`], {
    encoding: 'utf8',
    maxBuffer: maximumResponseBytes,
    timeout: 30_000,
  })
  if (result.error !== undefined) {
    throw new Error(`${label} failed to start: ${result.error.message}`)
  }
  if (result.signal !== null || result.status !== 0) {
    throw new Error(`${label} failed with ${result.signal ?? `exit ${result.status}`}`)
  }
  return result.stdout
}

function readRegistry(version) {
  return {
    versionSource: runNpmView(['view', `zigcss@${version}`, 'version'], 'published version lookup'),
    tagsSource: runNpmView(['view', 'zigcss', 'dist-tags'], 'distribution-tag lookup'),
    distSource: runNpmView(['view', `zigcss@${version}`, 'dist'], 'distribution metadata lookup'),
  }
}

function validateCanonicalAttestationDownloadUrl(value) {
  let parsed
  try {
    parsed = new URL(value)
  } catch (error) {
    throw new Error(`npm attestation URL is invalid: ${error.message}`)
  }
  const prefix = '/-/npm/v1/attestations/zigcss@'
  const candidateVersion = parsed.pathname.startsWith(prefix) ? parsed.pathname.slice(prefix.length) : ''
  let parsedVersion
  try {
    parsedVersion = parseReleaseVersion(candidateVersion, 'npm attestation URL version')
  } catch (error) {
    throw new Error(`npm attestation URL is not canonical: ${error.message}`)
  }
  if (
    parsed.protocol !== 'https:'
    || parsed.hostname !== 'registry.npmjs.org'
    || parsed.port !== ''
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.search !== ''
    || parsed.hash !== ''
    || parsed.href !== expectedAttestationUrl(parsedVersion.value)
  ) {
    throw new Error('npm attestation URL must use the canonical public npm registry endpoint')
  }
  return parsed.href
}

export function downloadRegistryAttestations(
  url,
  maximumBytes = maximumAttestationResponseBytes,
  options = {},
) {
  if (
    !Number.isSafeInteger(maximumBytes)
    || maximumBytes <= 0
    || maximumBytes > maximumAttestationResponseBytes
  ) {
    return Promise.reject(new Error('npm attestation response byte limit is invalid'))
  }
  const timeoutMs = options.timeoutMs ?? downloadTimeoutMs
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > downloadTimeoutMs) {
    return Promise.reject(new Error('npm attestation response timeout is invalid'))
  }
  let validated
  try {
    validated = validateCanonicalAttestationDownloadUrl(url)
  } catch (error) {
    return Promise.reject(error)
  }
  const requestResource = options.request ?? https.get
  if (typeof requestResource !== 'function') {
    return Promise.reject(new Error('npm attestation request implementation is invalid'))
  }

  return new Promise((resolve, reject) => {
    let settled = false
    let request
    let response
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (error) reject(error)
      else resolve(value)
    }
    const timer = setTimeout(() => {
      const error = new Error(`npm attestation download timed out after ${timeoutMs} ms`)
      request?.destroy(error)
      finish(error)
    }, timeoutMs)

    try {
      request = requestResource(validated, {
        headers: {
          Accept: 'application/json',
          'User-Agent': 'zigcss-npm-publication-readback/1',
        },
      }, incoming => {
        response = incoming
        if (response.statusCode !== 200) {
          response.resume()
          finish(new Error(`npm attestation download failed with HTTP ${response.statusCode ?? 0}`))
          return
        }
        if (response.headers['content-type'] !== 'application/json') {
          response.resume()
          finish(new Error('npm attestation response must use application/json'))
          return
        }
        const length = response.headers['content-length']
        if (length !== undefined) {
          if (Array.isArray(length) || !/^(?:0|[1-9]\d*)$/.test(length)) {
            response.resume()
            finish(new Error('npm attestation response returned an invalid Content-Length'))
            return
          }
          const advertised = Number(length)
          if (!Number.isSafeInteger(advertised) || advertised <= 0 || advertised > maximumBytes) {
            response.resume()
            finish(new Error('npm attestation response exceeds its byte limit'))
            return
          }
        }

        const chunks = []
        let received = 0
        response.on('data', chunk => {
          if (settled) return
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
          received += bytes.length
          if (received > maximumBytes) {
            response.destroy(new Error('npm attestation response exceeds its byte limit'))
            finish(new Error('npm attestation response exceeds its byte limit'))
            return
          }
          chunks.push(bytes)
        })
        response.on('aborted', () => finish(new Error('npm attestation response was aborted')))
        response.on('error', error => finish(error))
        response.on('end', () => {
          if (received <= 0) finish(new Error('npm attestation response is empty'))
          else finish(null, Buffer.concat(chunks, received))
        })
      })
      request.on('error', error => finish(error))
    } catch (error) {
      response?.resume()
      finish(error)
    }
  })
}

function downloadRegistryTarball(url, maximumBytes = npmPackageArtifactLimits.archiveBytes) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0 || maximumBytes > npmPackageArtifactLimits.archiveBytes) {
    return Promise.reject(new Error('registry tarball byte limit is invalid'))
  }
  let validated
  try {
    const parsed = new URL(url)
    if (
      parsed.protocol !== 'https:'
      || parsed.hostname !== 'registry.npmjs.org'
      || parsed.port !== ''
      || parsed.username !== ''
      || parsed.password !== ''
      || parsed.search !== ''
      || parsed.hash !== ''
    ) {
      throw new Error('registry tarball URL must use the canonical npm registry origin')
    }
    validated = parsed.href
  } catch (error) {
    return Promise.reject(error)
  }

  return new Promise((resolve, reject) => {
    let settled = false
    let request
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (error) reject(error)
      else resolve(value)
    }
    const timer = setTimeout(() => {
      const error = new Error(`registry tarball download timed out after ${downloadTimeoutMs} ms`)
      request?.destroy(error)
      finish(error)
    }, downloadTimeoutMs)

    request = https.get(validated, {
      headers: {
        Accept: 'application/octet-stream',
        'User-Agent': 'zigcss-npm-publication-readback/1',
      },
    }, response => {
      if (response.statusCode !== 200) {
        response.resume()
        finish(new Error(`registry tarball download failed with HTTP ${response.statusCode ?? 0}`))
        return
      }
      const length = response.headers['content-length']
      if (length !== undefined) {
        if (!/^(?:0|[1-9]\d*)$/.test(length)) {
          response.resume()
          finish(new Error('registry tarball returned an invalid Content-Length'))
          return
        }
        const advertised = Number(length)
        if (!Number.isSafeInteger(advertised) || advertised <= 0 || advertised > maximumBytes) {
          response.resume()
          finish(new Error('registry tarball exceeds its byte limit'))
          return
        }
      }

      const chunks = []
      let received = 0
      response.on('data', chunk => {
        received += chunk.length
        if (received > maximumBytes) {
          response.destroy(new Error('registry tarball exceeds its byte limit'))
          return
        }
        chunks.push(chunk)
      })
      response.on('error', error => finish(error))
      response.on('end', () => {
        if (received <= 0) finish(new Error('registry tarball is empty'))
        else finish(null, Buffer.concat(chunks, received))
      })
    })
    request.on('error', error => finish(error))
  })
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

export function sanitizeLogMessage(value) {
  return String(value)
    .replace(/\n|\r|\u2028|\u2029/gu, ' ')
    .replace(/[\u0000-\u0009\u000b\u000c\u000e-\u001f\u007f-\u009f]/gu, ' ')
    .slice(0, 2_048)
}

export function validateDownloadedNpmPackage(localPackage, downloadedPackage) {
  validateExpectedPackage(localPackage, localPackage.version)
  if (
    downloadedPackage.name !== localPackage.name
    || downloadedPackage.version !== localPackage.version
    || downloadedPackage.bytes !== localPackage.bytes
    || downloadedPackage.unpackedBytes !== localPackage.unpackedBytes
    || downloadedPackage.entryCount !== localPackage.entryCount
    || downloadedPackage.shasum !== localPackage.shasum
    || downloadedPackage.integrity !== localPackage.integrity
    || downloadedPackage.manifestText !== localPackage.manifestText
    || !same(downloadedPackage.files, localPackage.files)
  ) {
    fail('downloaded registry tarball differs from the exact tested package')
  }
  return true
}

export async function verifyNpmPublication(version, options = {}) {
  parseReleaseVersion(version, 'npm publication version')
  const localPackage = options.localPackage ?? (
    typeof options.archive === 'string'
      ? inspectNpmPackageArchive(options.archive, version)
      : null
  )
  validateExpectedPackage(localPackage, version)
  const attempts = options.attempts ?? npmPublicationReadbackPolicy.attempts
  const delayMs = options.delayMs ?? npmPublicationReadbackPolicy.delayMs
  const read = options.read ?? readRegistry
  const sleep = options.wait ?? wait
  const download = options.download ?? downloadRegistryTarball
  const downloadAttestations = options.downloadAttestations ?? downloadRegistryAttestations
  const inspectDownloaded = options.inspectDownloaded ?? ((bytes, expected) => (
    inspectNpmPackageBytes(bytes, version, Buffer.from(expected.manifestText))
  ))
  const expectedCommit = options.commit ?? process.env.GITHUB_SHA
  if (typeof expectedCommit !== 'string' || !/^[0-9a-f]{40}$/.test(expectedCommit)) {
    fail('expected GitHub release commit must be one lowercase 40-character SHA')
  }
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > npmPublicationReadbackPolicy.attempts) {
    fail(`attempt count must be an integer from 1 through ${npmPublicationReadbackPolicy.attempts}`)
  }
  if (!Number.isSafeInteger(delayMs) || delayMs < 0 || delayMs > npmPublicationReadbackPolicy.delayMs) {
    fail(`retry delay must be an integer from 0 through ${npmPublicationReadbackPolicy.delayMs} milliseconds`)
  }

  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await read(version, attempt)
      const result = validateNpmPublicationReadback(
        version,
        response.versionSource,
        response.tagsSource,
        response.distSource,
        localPackage,
      )
      const attestationBytes = await downloadAttestations(
        result.attestationUrl,
        maximumAttestationResponseBytes,
      )
      const provenance = validateNpmAttestationReadback(
        version,
        attestationBytes,
        localPackage,
        expectedCommit,
      )
      const bytes = await download(result.tarballUrl, npmPackageArtifactLimits.archiveBytes)
      const downloadedPackage = inspectDownloaded(bytes, localPackage)
      validateDownloadedNpmPackage(localPackage, downloadedPackage)
      return {
        ...result,
        attempts: attempt,
        integrity: localPackage.integrity,
        provenancePredicateType: provenance.predicateType,
      }
    } catch (error) {
      lastError = error
    }
    if (attempt < attempts) await sleep(delayMs)
  }
  fail(`registry did not converge after ${attempts} attempts: ${lastError?.message ?? 'unknown error'}`)
}

function parseArgs(args) {
  if (args.length !== 4) fail('usage: --version semver --archive absolute-path')
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    if (!['--version', '--archive'].includes(args[index]) || values.has(args[index]) || args[index + 1].length === 0) {
      fail('usage: --version semver --archive absolute-path')
    }
    values.set(args[index], args[index + 1])
  }
  if (!values.has('--version') || !values.has('--archive')) {
    fail('usage: --version semver --archive absolute-path')
  }
  return values
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const result = await verifyNpmPublication(args.get('--version'), { archive: args.get('--archive') })
  process.stdout.write(`npm publication verified: ${JSON.stringify({
    attempts: result.attempts,
    channel: result.channel,
    integrity: result.integrity,
    provenancePredicateType: result.provenancePredicateType,
    version: result.version,
  })}\n`)
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main().catch(error => {
    const message = error instanceof Error ? error.message : String(error)
    process.stderr.write(`npm publication verification failed: ${sanitizeLogMessage(message)}\n`)
    process.exitCode = 1
  })
}
