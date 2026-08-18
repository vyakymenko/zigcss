import assert from 'node:assert/strict'
import test from 'node:test'
import {
  npmPublicationReadbackPolicy,
  validateNpmPublicationReadback,
  verifyNpmPublication,
} from './verify-npm-publication.mjs'

const version = '0.6.0-rc.2'
const visibleVersion = JSON.stringify(version)
const visibleTags = JSON.stringify({ latest: '0.3.0', next: version })
const stableVersion = '0.6.0'
const stableTags = JSON.stringify({ latest: stableVersion, next: version })

test('readback accepts the exact immutable version on next without moving latest', () => {
  assert.deepEqual(npmPublicationReadbackPolicy, { attempts: 12, delayMs: 5_000 })
  assert.deepEqual(validateNpmPublicationReadback(version, visibleVersion, visibleTags), {
    version,
    channel: 'next',
  })
})

test('readback accepts the exact stable version on latest while retaining next', () => {
  assert.deepEqual(
    validateNpmPublicationReadback(stableVersion, JSON.stringify(stableVersion), stableTags),
    { version: stableVersion, channel: 'latest' },
  )
})

test('readback rejects malformed, mismatched, wrong-channel, and unbounded responses', () => {
  assert.throws(
    () => validateNpmPublicationReadback(version, 'null', visibleTags),
    /published version must be/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, '{'),
    /not JSON/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, '{}'),
    /bounded non-empty object/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, '{"latest":"0.3.0","next":"0.4.0-rc.2"}'),
    /next tag must be/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, JSON.stringify({ latest: version, next: version })),
    /retain a stable latest/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, JSON.stringify({ next: version })),
    /retain a stable latest/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(stableVersion, JSON.stringify(stableVersion), JSON.stringify({ latest: version, next: version })),
    /latest tag must be/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(stableVersion, JSON.stringify(stableVersion), JSON.stringify({ latest: stableVersion })),
    /retain a prerelease next/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(stableVersion, JSON.stringify(stableVersion), JSON.stringify({ latest: stableVersion, next: '0.3.0' })),
    /retain a prerelease next/,
  )
  assert.throws(
    () => validateNpmPublicationReadback(version, visibleVersion, ' '.repeat(256 * 1024 + 1)),
    /oversized/,
  )
})

test('verification retries bounded propagation failures and reports convergence', async () => {
  const waits = []
  let reads = 0
  const result = await verifyNpmPublication(version, {
    attempts: 3,
    delayMs: 7,
    read: async () => {
      reads += 1
      if (reads === 1) throw new Error('temporary registry 404')
      if (reads === 2) {
        return { versionSource: visibleVersion, tagsSource: '{"latest":"0.3.0"}' }
      }
      return { versionSource: visibleVersion, tagsSource: visibleTags }
    },
    wait: async delayMs => waits.push(delayMs),
  })

  assert.deepEqual(result, { version, channel: 'next', attempts: 3 })
  assert.equal(reads, 3)
  assert.deepEqual(waits, [7, 7])
})

test('verification fails closed after the exact bounded retry budget', async () => {
  let reads = 0
  await assert.rejects(
    verifyNpmPublication(version, {
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
    verifyNpmPublication(version, { attempts: 13 }),
    /attempt count/,
  )

  let invalidReads = 0
  await assert.rejects(
    verifyNpmPublication('../release', {
      read: async () => {
        invalidReads += 1
        throw new Error('must not query')
      },
    }),
    /not canonical Semantic Versioning/,
  )
  assert.equal(invalidReads, 0)
})
