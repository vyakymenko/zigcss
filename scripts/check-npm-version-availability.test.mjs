import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { checkNpmVersionAvailability } from './check-npm-version-availability.mjs'

const script = new URL('./check-npm-version-availability.mjs', import.meta.url)

test('an absent canonical prerelease is admitted only to the next channel', () => {
  assert.deepEqual(checkNpmVersionAvailability('0.4.0-rc.1', '["0.2.0","0.3.0"]\n'), {
    version: '0.4.0-rc.1',
    publishedVersions: 2,
    channel: 'next',
  })
})

test('published, stable, malformed, duplicate, and unbounded inventories fail closed', () => {
  assert.throws(
    () => checkNpmVersionAvailability('0.4.0-rc.1', '["0.3.0","0.4.0-rc.1"]'),
    /already published and immutable/,
  )
  assert.throws(() => checkNpmVersionAvailability('0.4.0', '["0.3.0"]'), /only.*prerelease/)
  assert.throws(() => checkNpmVersionAvailability('0.4.0-rc.1', '{'), /not JSON/)
  assert.throws(() => checkNpmVersionAvailability('0.4.0-rc.1', '[]'), /non-empty array/)
  assert.throws(() => checkNpmVersionAvailability('0.4.0-rc.1', '["0.3.0","0.3.0"]'), /repeats/)
  assert.throws(() => checkNpmVersionAvailability('0.4.0-rc.1', '[7]'), /non-string/)
  assert.throws(() => checkNpmVersionAvailability('0.4.0-rc.1', ' '.repeat(1024 * 1024 + 1)), /oversized/)
})

test('the CLI accepts only an absolute bounded regular inventory file', t => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-npm-preflight-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const inventory = path.join(temporary, 'versions.json')
  fs.writeFileSync(inventory, '["0.2.0","0.3.0"]\n')

  const output = execFileSync(process.execPath, [
    fileURLToPath(script),
    '--version', '0.4.0-rc.1',
    '--versions-file', inventory,
  ], { encoding: 'utf8' })
  assert.match(output, /0\.4\.0-rc\.1 is absent from 2 immutable versions and will use next/)

  const symlink = path.join(temporary, 'versions-link.json')
  fs.symlinkSync(inventory, symlink)
  assert.throws(
    () => execFileSync(process.execPath, [
      fileURLToPath(script),
      '--version', '0.4.0-rc.1',
      '--versions-file', symlink,
    ], { stdio: 'pipe' }),
    /Command failed/,
  )
})
