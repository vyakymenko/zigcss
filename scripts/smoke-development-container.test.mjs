import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import {
  expectedDevelopmentCompilerVersion,
  finishSmoke,
  hasObservedRootInputRebuild,
  maximumWaitMs,
  repositoryRoot,
  validateContainerInspection,
  writableMounts,
} from './smoke-development-container.mjs'

test('development container expects the active canonical compiler version', () => {
  const version = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  assert.equal(expectedDevelopmentCompilerVersion(), `zigcss ${version}`)
})

test('development container hot-rebuild evidence requires the root event and two successful builds', () => {
  assert.equal(hasObservedRootInputRebuild('Changed: build.zig\nRebuilt in 12ms\nRebuilt in 9ms'), true)
  assert.equal(hasObservedRootInputRebuild('Changed: build.zig\nRebuilt in 12ms'), false)
  assert.equal(hasObservedRootInputRebuild('Rebuilt in 12ms\nRebuilt in 9ms'), false)
  assert.equal(hasObservedRootInputRebuild('Changed: src/main.zig\nRebuilt in 12ms\nRebuilt in 9ms'), false)
})

function inspection(overrides = {}) {
  return {
    Config: { User: 'node' },
    State: { Running: true, Health: { Status: 'healthy' } },
    Mounts: [
      { Destination: '/workspace', Type: 'bind', RW: false },
      { Destination: '/app/docs/vite.config.ts', Type: 'bind', RW: false },
      ...writableMounts.map(Destination => ({ Destination, Type: 'volume', RW: true })),
    ],
    ...overrides,
  }
}

test('development container inspection requires the exact healthy mount boundary', () => {
  assert.equal(maximumWaitMs, 240_000)
  assert.equal(validateContainerInspection(inspection()), true)

  assert.throws(
    () => validateContainerInspection(inspection({ State: { Running: true, Health: { Status: 'unhealthy' } } })),
    /must be healthy/,
  )
  assert.throws(
    () => validateContainerInspection(inspection({ Config: { User: 'root' } })),
    /node user/,
  )
  const writableSource = inspection()
  writableSource.Mounts[0] = { Destination: '/workspace', Type: 'bind', RW: true }
  assert.throws(() => validateContainerInspection(writableSource), /read-only/)
  const missingVolume = inspection()
  missingVolume.Mounts.pop()
  assert.throws(() => validateContainerInspection(missingVolume), /isolated volume/)
})

test('development container cleanup failures cannot be reported as success', () => {
  const outcome = { mounts: 8, project: 'zigcss-dev-smoke-test' }
  assert.equal(finishSmoke(outcome, undefined, undefined), outcome)

  const primary = new Error('build failed')
  const cleanup = new Error('cleanup failed')
  assert.throws(() => finishSmoke(outcome, primary, undefined), error => error === primary)
  assert.throws(() => finishSmoke(outcome, undefined, cleanup), error => error === cleanup)
  assert.throws(
    () => finishSmoke(outcome, primary, cleanup),
    error => error instanceof AggregateError && error.errors[0] === primary && error.errors[1] === cleanup,
  )
})
