import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import test from 'node:test'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'
import { npmPackageExecutableFiles } from './npm-package-artifact.mjs'
import {
  downloadRegistryAttestations,
  npmPublicationReadbackPolicy,
  validateDownloadedNpmPackage,
  validateNpmAttestationReadback,
  validateNpmPublicationReadback,
  verifyNpmPublication,
} from './verify-npm-publication.mjs'

const version = '0.6.0-rc.2'
const stableVersion = '0.6.0'
const commit = '0123456789abcdef0123456789abcdef01234567'
const provenancePredicateType = 'https://slsa.dev/provenance/v1'
const publishPredicateType = 'https://github.com/npm/attestation/tree/main/specs/publish/v0.1'

function packageFixture(releaseVersion) {
  const source = Buffer.from(`exact-${releaseVersion}`)
  return Object.freeze({
    name: 'zigcss',
    version: releaseVersion,
    filename: `zigcss-${releaseVersion}.tgz`,
    bytes: 24_000,
    unpackedBytes: 60_000,
    entryCount: expectedPackedFiles.length,
    shasum: crypto.createHash('sha1').update(source).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(source).digest('base64')}`,
    manifestText: `${JSON.stringify({ name: 'zigcss', version: releaseVersion })}\n`,
    files: Object.freeze(expectedPackedFiles.map((file, index) => Object.freeze({
      path: file,
      size: 100 + index,
      mode: npmPackageExecutableFiles.includes(file) ? 0o755 : 0o644,
    }))),
  })
}

function distSource(expected, overrides = {}) {
  return JSON.stringify({
    shasum: expected.shasum,
    integrity: expected.integrity,
    tarball: `https://registry.npmjs.org/zigcss/-/${expected.filename}`,
    attestations: {
      url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${expected.version}`,
      provenance: { predicateType: provenancePredicateType },
    },
    ...overrides,
  })
}

function subjectFixture(releaseVersion, packageIdentity) {
  return [{
    name: `pkg:npm/zigcss@${releaseVersion}`,
    digest: {
      sha512: Buffer.from(packageIdentity.integrity.slice('sha512-'.length), 'base64').toString('hex'),
    },
  }]
}

function sigstoreBundle(statement, keyKind) {
  const keyid = keyKind === 'certificate'
    ? ''
    : `SHA256:${Buffer.from('npm-public-key').toString('base64')}`
  return {
    mediaType: 'application/vnd.dev.sigstore.bundle+json;version=0.2',
    dsseEnvelope: {
      payload: Buffer.from(JSON.stringify(statement)).toString('base64'),
      payloadType: 'application/vnd.in-toto+json',
      signatures: [{ keyid, sig: Buffer.from('signature').toString('base64') }],
    },
    verificationMaterial: keyKind === 'certificate'
      ? {
          x509CertificateChain: {
            certificates: [{ rawBytes: Buffer.from('certificate').toString('base64') }],
          },
          tlogEntries: [{}],
          timestampVerificationData: { rfc3161Timestamps: [] },
        }
      : {
          publicKey: { hint: keyid },
          tlogEntries: [{}],
          timestampVerificationData: { rfc3161Timestamps: [] },
        },
  }
}

function provenanceStatement(releaseVersion, packageIdentity) {
  return {
    _type: 'https://in-toto.io/Statement/v1',
    subject: subjectFixture(releaseVersion, packageIdentity),
    predicateType: provenancePredicateType,
    predicate: {
      buildDefinition: {
        buildType: 'https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1',
        externalParameters: {
          workflow: {
            ref: `refs/tags/v${releaseVersion}`,
            repository: 'https://github.com/vyakymenko/zigcss',
            path: '.github/workflows/release.yml',
          },
        },
        internalParameters: { github: { event_name: 'push' } },
        resolvedDependencies: [{
          uri: `git+https://github.com/vyakymenko/zigcss@refs/tags/v${releaseVersion}`,
          digest: { gitCommit: commit },
        }],
      },
      runDetails: {
        builder: { id: 'https://github.com/actions/runner/github-hosted' },
        metadata: {
          invocationId: 'https://github.com/vyakymenko/zigcss/actions/runs/123/attempts/1',
        },
      },
    },
  }
}

function publishStatement(releaseVersion, packageIdentity) {
  return {
    _type: 'https://in-toto.io/Statement/v0.1',
    subject: subjectFixture(releaseVersion, packageIdentity),
    predicateType: publishPredicateType,
    predicate: {
      name: 'zigcss',
      version: releaseVersion,
      registry: 'https://registry.npmjs.org',
    },
  }
}

function attestationFixture(releaseVersion, packageIdentity, includePublish = true) {
  const attestations = []
  if (includePublish) {
    attestations.push({
      predicateType: publishPredicateType,
      signedAccessSignatureUrl: '',
      bundle: sigstoreBundle(publishStatement(releaseVersion, packageIdentity), 'public-key'),
    })
  }
  attestations.push({
    predicateType: provenancePredicateType,
    signedAccessSignatureUrl: '',
    bundle: sigstoreBundle(provenanceStatement(releaseVersion, packageIdentity), 'certificate'),
  })
  return { attestations }
}

function editStatement(source, predicateType, mutate) {
  const response = structuredClone(source)
  const attestation = response.attestations.find(entry => entry.predicateType === predicateType)
  const statement = JSON.parse(Buffer.from(attestation.bundle.dsseEnvelope.payload, 'base64').toString())
  mutate(statement)
  attestation.bundle.dsseEnvelope.payload = Buffer.from(JSON.stringify(statement)).toString('base64')
  return response
}

const expected = packageFixture(version)
const stableExpected = packageFixture(stableVersion)
const visibleVersion = JSON.stringify(version)
const visibleTags = JSON.stringify({ latest: '0.3.0', next: version })
const visibleDist = distSource(expected)
const visibleAttestations = attestationFixture(version, expected)
const stableTags = JSON.stringify({ latest: stableVersion, next: version })
const stableDist = distSource(stableExpected)

test('readback accepts exact version, tags, integrity, shasum, and canonical tarball URL', () => {
  assert.deepEqual(npmPublicationReadbackPolicy, { attempts: 12, delayMs: 5_000 })
  assert.deepEqual(
    validateNpmPublicationReadback(version, visibleVersion, visibleTags, visibleDist, expected),
    {
      version,
      channel: 'next',
      tarballUrl: `https://registry.npmjs.org/zigcss/-/${expected.filename}`,
      attestationUrl: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
    },
  )
})

test('readback accepts the exact stable version on latest while retaining next', () => {
  assert.deepEqual(
    validateNpmPublicationReadback(
      stableVersion,
      JSON.stringify(stableVersion),
      stableTags,
      stableDist,
      stableExpected,
    ),
    {
      version: stableVersion,
      channel: 'latest',
      tarballUrl: `https://registry.npmjs.org/zigcss/-/${stableExpected.filename}`,
      attestationUrl: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${stableVersion}`,
    },
  )
})

test('readback rejects malformed, mismatched, wrong-channel, and unbounded responses', () => {
  const validate = (versionValue, tagsValue, distValue = visibleDist) => (
    validateNpmPublicationReadback(version, versionValue, tagsValue, distValue, expected)
  )
  assert.throws(() => validate('null', visibleTags), /published version must be/)
  assert.throws(() => validate(visibleVersion, '{'), /not JSON/)
  assert.throws(() => validate(visibleVersion, '{}'), /bounded non-empty object/)
  assert.throws(
    () => validate(visibleVersion, '{"latest":"0.3.0","next":"0.4.0-rc.2"}'),
    /next tag must be/,
  )
  assert.throws(
    () => validate(visibleVersion, JSON.stringify({ latest: version, next: version })),
    /retain a stable latest/,
  )
  assert.throws(
    () => validate(visibleVersion, JSON.stringify({ next: version })),
    /retain a stable latest/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(
      stableVersion,
      JSON.stringify(stableVersion),
      JSON.stringify({ latest: version, next: version }),
      stableDist,
      stableExpected,
    ),
    /latest tag must be/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(
      stableVersion,
      JSON.stringify(stableVersion),
      JSON.stringify({ latest: stableVersion }),
      stableDist,
      stableExpected,
    ),
    /retain a prerelease next/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(
      stableVersion,
      JSON.stringify(stableVersion),
      JSON.stringify({ latest: stableVersion, next: '0.3.0' }),
      stableDist,
      stableExpected,
    ),
    /retain a prerelease next/,
  )
  assert.throws(() => validate(visibleVersion, ' '.repeat(256 * 1024 + 1)), /oversized/)
  assert.throws(() => validate(visibleVersion, visibleTags, '{}'), /bounded object/)
})

test('readback rejects registry digest and canonical tarball identity drift', () => {
  assert.throws(
    () => validateNpmPublicationReadback(
      version,
      visibleVersion,
      visibleTags,
      distSource(expected, { shasum: '0'.repeat(40) }),
      expected,
    ),
    /published shasum/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(
      version,
      visibleVersion,
      visibleTags,
      distSource(expected, { integrity: packageFixture('0.6.0-rc.3').integrity }),
      expected,
    ),
    /published integrity/,
  )
  for (const tarball of [
    `http://registry.npmjs.org/zigcss/-/${expected.filename}`,
    `https://example.com/zigcss/-/${expected.filename}`,
    'https://registry.npmjs.org/zigcss/-/zigcss-0.6.0-rc.3.tgz',
    `https://registry.npmjs.org/zigcss/-/${expected.filename}?redirect=1`,
  ]) {
    assert.throws(
      () => validateNpmPublicationReadback(
        version,
        visibleVersion,
        visibleTags,
        distSource(expected, { tarball }),
        expected,
      ),
      /published tarball URL must be/,
    )
  }
})

test('readback requires the exact canonical npm provenance advertisement', () => {
  for (const attestations of [
    undefined,
    {},
    {
      url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
      provenance: { predicateType: 'https://slsa.dev/provenance/v0.2' },
    },
    {
      url: `https://example.com/-/npm/v1/attestations/zigcss@${version}`,
      provenance: { predicateType: provenancePredicateType },
    },
    {
      url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}?redirect=1`,
      provenance: { predicateType: provenancePredicateType },
    },
    {
      url: 'https://registry.npmjs.org/-/npm/v1/attestations/zigcss@0.6.0-rc.3',
      provenance: { predicateType: provenancePredicateType },
    },
    {
      url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
      provenance: { predicateType: provenancePredicateType },
      extra: true,
    },
  ]) {
    assert.throws(
      () => validateNpmPublicationReadback(
        version,
        visibleVersion,
        visibleTags,
        distSource(expected, { attestations }),
        expected,
      ),
      /provenance|attestation URL/,
    )
  }
})

test('attestation readback accepts one exact SLSA provenance and preserves the npm publish attestation', () => {
  for (const response of [visibleAttestations, attestationFixture(version, expected, false)]) {
    assert.deepEqual(
      validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
      { predicateType: provenancePredicateType },
    )
  }
})

test('attestation readback rejects missing, duplicate, unexpected, and malformed predicates', () => {
  const provenance = visibleAttestations.attestations[1]
  const publish = visibleAttestations.attestations[0]
  const cases = [
    { attestations: [] },
    { attestations: [publish] },
    { attestations: [provenance, provenance] },
    {
      attestations: [provenance, {
        predicateType: 'https://example.com/untrusted',
        signedAccessSignatureUrl: '',
        bundle: provenance.bundle,
      }],
    },
    { attestations: [publish, provenance, publish] },
    { attestations: [null, provenance] },
    { attestations: [provenance], extra: true },
  ]
  for (const response of cases) {
    assert.throws(
      () => validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
      /attestation response|duplicate|unexpected|malformed|missing/,
    )
  }
})

test('attestation readback binds the exact package subject and sha512 digest', () => {
  const mutations = [
    statement => { statement.subject = [] },
    statement => { statement.subject[0].name = 'pkg:npm/not-zigcss@0.6.0-rc.2' },
    statement => { statement.subject[0].digest.sha512 = '0'.repeat(128) },
    statement => { statement.subject[0].digest.sha256 = '0'.repeat(64) },
  ]
  for (const mutate of mutations) {
    const response = editStatement(visibleAttestations, provenancePredicateType, mutate)
    assert.throws(
      () => validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
      /subject/,
    )
  }
})

test('attestation readback binds repository, workflow, ref, build type, and resolved commit', () => {
  const mutations = [
    statement => { statement.predicate.buildDefinition.buildType = 'https://example.com/build' },
    statement => {
      statement.predicate.buildDefinition.externalParameters.workflow.repository =
        'https://github.com/attacker/zigcss'
    },
    statement => {
      statement.predicate.buildDefinition.externalParameters.workflow.path = '.github/workflows/other.yml'
    },
    statement => {
      statement.predicate.buildDefinition.externalParameters.workflow.ref = 'refs/heads/main'
    },
    statement => {
      statement.predicate.buildDefinition.resolvedDependencies[0].uri =
        'git+https://github.com/attacker/zigcss@refs/tags/v0.6.0-rc.2'
    },
    statement => {
      statement.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit = 'f'.repeat(40)
    },
    statement => {
      statement.predicate.runDetails.metadata.invocationId =
        'https://github.com/attacker/zigcss/actions/runs/123/attempts/1'
    },
  ]
  for (const mutate of mutations) {
    const response = editStatement(visibleAttestations, provenancePredicateType, mutate)
    assert.throws(
      () => validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
      /build definition|workflow identity|resolved dependency|run details/,
    )
  }
})

test('attestation readback requires the exact resolved release dependency', () => {
  const response = editStatement(visibleAttestations, provenancePredicateType, statement => {
    delete statement.predicate.buildDefinition.resolvedDependencies
  })
  assert.throws(
    () => validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
    /build definition/,
  )
})

test('attestation readback rejects malformed Sigstore bundles and DSSE payloads', () => {
  const cases = []
  for (const mutate of [
    attestation => { attestation.bundle.mediaType = 'application/json' },
    attestation => { attestation.bundle.dsseEnvelope.payloadType = 'application/json' },
    attestation => { attestation.bundle.dsseEnvelope.payload = 'not base64!' },
    attestation => { attestation.bundle.dsseEnvelope.signatures = [] },
    attestation => { attestation.bundle.dsseEnvelope.signatures[0].keyid = 'unexpected' },
    attestation => { attestation.bundle.verificationMaterial.x509CertificateChain.certificates = [] },
    attestation => { attestation.bundle.verificationMaterial.tlogEntries = [] },
  ]) {
    const response = structuredClone(visibleAttestations)
    mutate(response.attestations[1])
    cases.push(response)
  }
  cases.push(editStatement(visibleAttestations, provenancePredicateType, statement => {
    statement.predicateType = publishPredicateType
  }))
  for (const response of cases) {
    assert.throws(
      () => validateNpmAttestationReadback(version, JSON.stringify(response), expected, commit),
      /Sigstore|DSSE|statement/,
    )
  }
})

test('attestation parser rejects oversized, invalid UTF-8, and unbound commit inputs', () => {
  assert.throws(
    () => validateNpmAttestationReadback(
      version,
      Buffer.alloc(256 * 1024 + 1, 0x20),
      expected,
      commit,
    ),
    /oversized/,
  )
  assert.throws(
    () => validateNpmAttestationReadback(version, Buffer.from([0xff]), expected, commit),
    /valid UTF-8/,
  )
  assert.throws(
    () => validateNpmAttestationReadback(version, JSON.stringify(visibleAttestations), expected, 'main'),
    /expected GitHub release commit/,
  )
})

function fakeHttpsRequest(body, options = {}) {
  return (url, requestOptions, callback) => {
    options.observe?.(url, requestOptions)
    const request = new EventEmitter()
    request.destroy = error => queueMicrotask(() => request.emit('error', error))
    if (!options.neverRespond) {
      queueMicrotask(() => {
        const response = new PassThrough()
        response.statusCode = options.statusCode ?? 200
        response.headers = {
          'content-type': options.contentType ?? 'application/json',
          ...(options.contentLength === undefined
            ? {}
            : { 'content-length': String(options.contentLength) }),
        }
        callback(response)
        response.end(body)
      })
    }
    return request
  }
}

test('attestation downloader uses only the canonical unauthenticated npm HTTPS endpoint', async () => {
  const body = Buffer.from(JSON.stringify(visibleAttestations))
  const observations = []
  const url = `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`
  const downloaded = await downloadRegistryAttestations(url, 32 * 1024, {
    request: fakeHttpsRequest(body, {
      contentLength: body.length,
      observe: (...args) => observations.push(args),
    }),
    timeoutMs: 100,
  })
  assert.deepEqual(downloaded, body)
  assert.equal(observations.length, 1)
  assert.equal(observations[0][0], url)
  assert.deepEqual(observations[0][1].headers, {
    Accept: 'application/json',
    'User-Agent': 'zigcss-npm-publication-readback/1',
  })

  for (const rejectedUrl of [
    `http://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
    `https://example.com/-/npm/v1/attestations/zigcss@${version}`,
    `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}?redirect=1`,
    'https://registry.npmjs.org/-/npm/v1/attestations/zigcss@../other',
  ]) {
    await assert.rejects(
      downloadRegistryAttestations(rejectedUrl, 32 * 1024, {
        request: () => { throw new Error('must not request') },
      }),
      /canonical|Semantic Versioning/,
    )
  }
})

test('attestation downloader denies redirects, wrong media types, and oversized bodies', async () => {
  const url = `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, {
      request: fakeHttpsRequest('', { statusCode: 302 }),
    }),
    /HTTP 302/,
  )
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, {
      request: fakeHttpsRequest('{}', { contentType: 'text/html' }),
    }),
    /application\/json/,
  )
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, {
      request: fakeHttpsRequest('{}', { contentLength: 1025 }),
    }),
    /exceeds its byte limit/,
  )
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, {
      request: fakeHttpsRequest(Buffer.alloc(1025, 0x20)),
    }),
    /exceeds its byte limit/,
  )
  await assert.rejects(downloadRegistryAttestations(url, 256 * 1024 + 1), /byte limit/)
})

test('attestation downloader enforces its strict request timeout', async () => {
  const url = `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, {
      request: fakeHttpsRequest('', { neverRespond: true }),
      timeoutMs: 5,
    }),
    /timed out after 5 ms/,
  )
  await assert.rejects(
    downloadRegistryAttestations(url, 1024, { timeoutMs: 30_001 }),
    /timeout is invalid/,
  )
})

test('downloaded registry tarball must equal the exact tested package inspection', () => {
  assert.equal(validateDownloadedNpmPackage(expected, expected), true)
  for (const mutation of [
    { bytes: expected.bytes + 1 },
    { unpackedBytes: expected.unpackedBytes + 1 },
    { entryCount: expected.entryCount - 1 },
    { shasum: '0'.repeat(40) },
    { integrity: stableExpected.integrity },
    { manifestText: '{}\n' },
    { files: expected.files.slice(1) },
  ]) {
    assert.throws(
      () => validateDownloadedNpmPackage(expected, { ...expected, ...mutation }),
      /differs from the exact tested package/,
    )
  }
})

test('verification retries bounded metadata and tarball propagation failures', async () => {
  const waits = []
  const downloads = []
  const attestationDownloads = []
  let reads = 0
  let inspections = 0
  const result = await verifyNpmPublication(version, {
    localPackage: expected,
    commit,
    attempts: 3,
    delayMs: 7,
    read: async () => {
      reads += 1
      if (reads === 1) throw new Error('temporary registry 404')
      if (reads === 2) {
        return {
          versionSource: visibleVersion,
          tagsSource: '{"latest":"0.3.0"}',
          distSource: visibleDist,
        }
      }
      return { versionSource: visibleVersion, tagsSource: visibleTags, distSource: visibleDist }
    },
    wait: async delayMs => waits.push(delayMs),
    downloadAttestations: async (url, maximumBytes) => {
      attestationDownloads.push({ url, maximumBytes })
      return Buffer.from(JSON.stringify(visibleAttestations))
    },
    download: async (url, maximumBytes) => {
      downloads.push({ url, maximumBytes })
      return Buffer.from('registry tarball')
    },
    inspectDownloaded: () => {
      inspections += 1
      return expected
    },
  })

  assert.deepEqual(result, {
    version,
    channel: 'next',
    tarballUrl: `https://registry.npmjs.org/zigcss/-/${expected.filename}`,
    attestationUrl: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
    attempts: 3,
    integrity: expected.integrity,
    provenancePredicateType,
  })
  assert.equal(reads, 3)
  assert.deepEqual(waits, [7, 7])
  assert.equal(downloads.length, 1)
  assert.equal(downloads[0].url, `https://registry.npmjs.org/zigcss/-/${expected.filename}`)
  assert.equal(downloads[0].maximumBytes, 2 * 1024 * 1024)
  assert.deepEqual(attestationDownloads, [{
    url: `https://registry.npmjs.org/-/npm/v1/attestations/zigcss@${version}`,
    maximumBytes: 256 * 1024,
  }])
  assert.equal(inspections, 1)
})

test('verification retries when downloaded registry bytes do not match', async () => {
  let downloads = 0
  const result = await verifyNpmPublication(version, {
    localPackage: expected,
    commit,
    attempts: 2,
    delayMs: 0,
    read: async () => ({
      versionSource: visibleVersion,
      tagsSource: visibleTags,
      distSource: visibleDist,
    }),
    wait: async () => {},
    downloadAttestations: async () => Buffer.from(JSON.stringify(visibleAttestations)),
    download: async () => {
      downloads += 1
      return Buffer.from(`registry tarball ${downloads}`)
    },
    inspectDownloaded: () => downloads === 1 ? { ...expected, bytes: expected.bytes + 1 } : expected,
  })
  assert.equal(result.attempts, 2)
  assert.equal(downloads, 2)
})

test('verification requires provenance convergence inside every bounded readback attempt', async () => {
  let attestationDownloads = 0
  let tarballDownloads = 0
  const waits = []
  const result = await verifyNpmPublication(version, {
    localPackage: expected,
    commit,
    attempts: 3,
    delayMs: 4,
    read: async () => ({
      versionSource: visibleVersion,
      tagsSource: visibleTags,
      distSource: visibleDist,
    }),
    wait: async delay => waits.push(delay),
    downloadAttestations: async () => {
      attestationDownloads += 1
      if (attestationDownloads === 1) throw new Error('npm attestation download timed out after 30 ms')
      if (attestationDownloads === 2) return Buffer.from(JSON.stringify({ attestations: [] }))
      return Buffer.from(JSON.stringify(visibleAttestations))
    },
    download: async () => {
      tarballDownloads += 1
      return Buffer.from('registry tarball')
    },
    inspectDownloaded: () => expected,
  })
  assert.equal(result.attempts, 3)
  assert.equal(result.provenancePredicateType, provenancePredicateType)
  assert.equal(attestationDownloads, 3)
  assert.equal(tarballDownloads, 1)
  assert.deepEqual(waits, [4, 4])
})

test('verification fails before registry access when GITHUB_SHA is unset or invalid', async () => {
  let reads = 0
  const read = async () => {
    reads += 1
    throw new Error('must not query')
  }
  const savedCommit = process.env.GITHUB_SHA
  delete process.env.GITHUB_SHA
  try {
    await assert.rejects(
      verifyNpmPublication(version, { localPackage: expected, attempts: 1, read }),
      /expected GitHub release commit/,
    )
  } finally {
    if (savedCommit === undefined) delete process.env.GITHUB_SHA
    else process.env.GITHUB_SHA = savedCommit
  }
  await assert.rejects(
    verifyNpmPublication(version, { localPackage: expected, commit: 'main', attempts: 1, read }),
    /expected GitHub release commit/,
  )
  assert.equal(reads, 0)
})

test('verification fails closed after the exact bounded retry budget', async () => {
  let reads = 0
  await assert.rejects(
    verifyNpmPublication(version, {
      localPackage: expected,
      commit,
      attempts: 3,
      delayMs: 0,
      read: async () => {
        reads += 1
        throw new Error('temporary registry 404')
      },
      wait: async () => {},
    }),
    /did not converge after 3 attempts.*temporary registry 404/,
  )
  assert.equal(reads, 3)
  await assert.rejects(
    verifyNpmPublication(version, { localPackage: expected, commit, attempts: 13 }),
    /attempt count/,
  )

  let invalidReads = 0
  await assert.rejects(
    verifyNpmPublication('../release', {
      localPackage: expected,
      read: async () => {
        invalidReads += 1
        throw new Error('must not query')
      },
    }),
    /not canonical Semantic Versioning/,
  )
  assert.equal(invalidReads, 0)
})
