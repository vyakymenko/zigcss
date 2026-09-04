import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

import {
  compareAscii,
  compareVersions,
  hasNotes,
  normalizeSupport,
  parseVersion,
  prefixDataZigCommand,
  validateInputs,
} from './generate-prefix-data.mjs'

const feature = { id: 'property.example' }
const browser = { id: 'safari' }

test('normalizes exact bounded support while retaining conservative qualifiers', () => {
  assert.deepEqual(
    normalizeSupport(feature, browser, {
      version_added: '7.1',
      version_last: '12',
      version_removed: '13',
      prefix: '-webkit-',
      partial_implementation: true,
      notes: ['Qualified behavior.'],
    }),
    [{
      browser: 'safari',
      added: { major: 7, minor: 1, patch: 0 },
      removed: { major: 13, minor: 0, patch: 0 },
      form: { kind: 'prefix', value: '-webkit-' },
      partial: true,
      annotated: true,
    }],
  )
  assert.deepEqual(normalizeSupport(feature, browser, { version_added: false }), [])
})

test('rejects compatibility statements that are ambiguous or unsafe to automate', () => {
  const invalid = [
    { version_added: '01' },
    { version_added: '7', version_removed: '7' },
    { version_added: '7', version_removed: '6' },
    { version_added: '7', version_last: '12', version_removed: null },
    { version_added: '7', version_last: '13', version_removed: '13' },
    { version_added: '7', flags: [] },
    { version_added: '7', partial_implementation: 'yes' },
    { version_added: '7', notes: [''] },
    { version_added: '7', prefix: '-x-', alternative_name: 'x' },
    { version_added: '7', prefix: '\n' },
    { version_added: true },
    null,
  ]
  for (const statement of invalid) {
    assert.throws(() => normalizeSupport(feature, browser, statement))
  }
})

test('uses canonical versions and locale-independent ASCII ordering', () => {
  assert.deepEqual(parseVersion('65535.2.3', 'test'), { major: 65535, minor: 2, patch: 3 })
  assert.throws(() => parseVersion('65536', 'test'))
  assert.throws(() => parseVersion('0', 'test'))
  assert.equal(compareVersions(
    { major: 7, minor: 1, patch: 0 },
    { major: 7, minor: 2, patch: 0 },
  ) < 0, true)
  assert.deepEqual(['z.test', 'a.test', 'm.test'].sort(compareAscii), ['a.test', 'm.test', 'z.test'])
  assert.equal(hasNotes(undefined, 'test'), false)
  assert.equal(hasNotes('Qualified behavior.', 'test'), true)
})

test('formatter command selection is finite and cannot execute an injected path', () => {
  assert.equal(prefixDataZigCommand(undefined), 'zig')
  assert.equal(prefixDataZigCommand('/opt/homebrew/bin/zig'), '/opt/homebrew/bin/zig')
  assert.throws(
    () => prefixDataZigCommand('/tmp/attacker-controlled-zig'),
    /finite reviewed Zig installation/,
  )
})

test('manifest validation binds the generated table to the closed browser grammar', () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL('../data/prefixing/compatibility-source.json', import.meta.url),
    'utf8',
  ))
  validateInputs(manifest)

  const changed = structuredClone(manifest)
  changed.browsers.reverse()
  assert.throws(
    () => validateInputs(changed),
    /target-query browser order/,
  )
})
