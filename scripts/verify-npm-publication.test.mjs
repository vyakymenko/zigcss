import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import test from 'node:test'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'
import { npmPackageExecutableFiles } from './npm-package-artifact.mjs'
import {
  npmPublicationReadbackPolicy,
  validateDownloadedNpmPackage,
  validateNpmPublicationReadback,
  verifyNpmPublication,
} from './verify-npm-publication.mjs'

const version = '0.6.0-rc.2'
const stableVersion = '0.6.0'

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
    ...overrides,
  })
}

const expected = packageFixture(version)
const stableExpected = packageFixture(stableVersion)
const visibleVersion = JSON.stringify(version)
const visibleTags = JSON.stringify({ latest: '0.3.0', next: version })
const visibleDist = distSource(expected)
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
  let reads = 0
  let inspections = 0
  const result = await verifyNpmPublication(version, {
    localPackage: expected,
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
    attempts: 3,
    integrity: expected.integrity,
  })
  assert.equal(reads, 3)
  assert.deepEqual(waits, [7, 7])
  assert.equal(downloads.length, 1)
  assert.equal(downloads[0].url, `https://registry.npmjs.org/zigcss/-/${expected.filename}`)
  assert.equal(downloads[0].maximumBytes, 2 * 1024 * 1024)
  assert.equal(inspections, 1)
})

test('verification retries when downloaded registry bytes do not match', async () => {
  let downloads = 0
  const result = await verifyNpmPublication(version, {
    localPackage: expected,
    attempts: 2,
    delayMs: 0,
    read: async () => ({
      versionSource: visibleVersion,
      tagsSource: visibleTags,
      distSource: visibleDist,
    }),
    wait: async () => {},
    download: async () => {
      downloads += 1
      return Buffer.from(`registry tarball ${downloads}`)
    },
    inspectDownloaded: () => downloads === 1 ? { ...expected, bytes: expected.bytes + 1 } : expected,
  })
  assert.equal(result.attempts, 2)
  assert.equal(downloads, 2)
})

test('verification fails closed after the exact bounded retry budget', async () => {
  let reads = 0
  await assert.rejects(
    verifyNpmPublication(version, {
      localPackage: expected,
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
    verifyNpmPublication(version, { localPackage: expected, attempts: 13 }),
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
