import assert from 'node:assert/strict'
import path from 'node:path'
import test from 'node:test'

import {
  findZig,
  finishReleaseContainerSmoke,
  releaseContainerZigCandidates,
} from './test-release-container.mjs'

test('release container cleanup failures cannot be reported as success', () => {
  const outcome = { dockerPlatform: 'linux/amd64' }
  assert.equal(finishReleaseContainerSmoke(outcome, undefined, []), outcome)

  const primary = new Error('image verification failed')
  const imageCleanup = new Error('image cleanup failed')
  const temporaryCleanup = new Error('temporary cleanup failed')
  assert.throws(() => finishReleaseContainerSmoke(outcome, primary, []), error => error === primary)
  assert.throws(() => finishReleaseContainerSmoke(outcome, undefined, [imageCleanup]), error => error === imageCleanup)
  assert.throws(
    () => finishReleaseContainerSmoke(outcome, primary, [imageCleanup, temporaryCleanup]),
    error => error instanceof AggregateError
      && error.errors[0] === primary
      && error.errors[1] === imageCleanup
      && error.errors[2] === temporaryCleanup,
  )
})

test('release container Zig discovery uses only bounded absolute candidates', () => {
  const candidates = releaseContainerZigCandidates('/fixture-home')
  assert.ok(candidates.length > 5)
  assert.equal(candidates.every(candidate => path.isAbsolute(candidate)), true)
  assert.throws(() => findZig([]), /Zig 0\.15\.2 executable is unavailable/)
})
