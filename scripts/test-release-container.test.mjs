import assert from 'node:assert/strict'
import test from 'node:test'

import { finishReleaseContainerSmoke } from './test-release-container.mjs'

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
