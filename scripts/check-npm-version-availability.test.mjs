import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { checkNpmVersionAvailability } from './check-npm-version-availability.mjs'

const script = new URL('./check-npm-version-availability.mjs', import.meta.url)

test('absent canonical prerelease and stable versions select distinct channels', () => {
  assert.deepEqual(checkNpmVersionAvailability('0.6.0-rc.2', '["0.2.0","0.3.0"]\n'), {
    version: '0.6.0-rc.2',
    publishedVersions: 2,
    channel: 'next',
    githubPrerelease: true,
    githubMakeLatest: false,
    alreadyPublished: false,
  })
  assert.deepEqual(checkNpmVersionAvailability('0.6.0', '["0.3.0","0.6.0-rc.2"]\n'), {
    version: '0.6.0',
    publishedVersions: 2,
    channel: 'latest',
    githubPrerelease: false,
    githubMakeLatest: true,
    alreadyPublished: false,
  })
  assert.deepEqual(checkNpmVersionAvailability('0.6.0-rc.2', '["0.3.0","0.6.0-rc.2"]'), {
    version: '0.6.0-rc.2',
    publishedVersions: 2,
    channel: 'next',
    githubPrerelease: true,
    githubMakeLatest: false,
    alreadyPublished: true,
  })
})

test('malformed, duplicate, and unbounded inventories fail closed', () => {
  assert.throws(() => checkNpmVersionAvailability('0.6.0-rc.2', '{'), /not JSON/)
  assert.throws(() => checkNpmVersionAvailability('0.6.0-rc.2', '[]'), /non-empty array/)
  assert.throws(() => checkNpmVersionAvailability('0.6.0-rc.2', '["0.3.0","0.3.0"]'), /repeats/)
  assert.throws(() => checkNpmVersionAvailability('0.6.0-rc.2', '[7]'), /non-string/)
  assert.throws(() => checkNpmVersionAvailability('0.6.0-rc.2', ' '.repeat(1024 * 1024 + 1)), /oversized/)
})

test('the CLI accepts only an absolute bounded regular inventory file', t => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-npm-preflight-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const inventory = path.join(temporary, 'versions.json')
  const githubOutput = path.join(temporary, 'github-output.txt')
  fs.writeFileSync(inventory, '["0.2.0","0.3.0"]\n')
  fs.writeFileSync(githubOutput, '')

  const output = execFileSync(process.execPath, [
    fileURLToPath(script),
    '--version', '0.6.0-rc.2',
    '--versions-file', inventory,
    '--github-output', githubOutput,
  ], { encoding: 'utf8' })
  assert.match(output, /0\.6\.0-rc\.2 is absent from 2 immutable versions and will use next/)
  assert.equal(
    fs.readFileSync(githubOutput, 'utf8'),
    'channel=next\ngithub_prerelease=true\ngithub_make_latest=false\nalready_published=false\n',
  )

  const symlink = path.join(temporary, 'versions-link.json')
  fs.symlinkSync(inventory, symlink)
  assert.throws(
    () => execFileSync(process.execPath, [
      fileURLToPath(script),
      '--version', '0.6.0-rc.2',
      '--versions-file', symlink,
    ], { stdio: 'pipe' }),
    /Command failed/,
  )
})
