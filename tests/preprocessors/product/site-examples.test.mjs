import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const binaryPath = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const examples = JSON.parse(fs.readFileSync(
  path.join(repositoryRoot, 'docs/src/data/format-examples.json'),
  'utf8',
))

test('website input/output lab is exact executable evidence for all five syntaxes', () => {
  assert.deepEqual(examples.map(example => example.id), [
    'css',
    'scss',
    'sass',
    'less',
    'stylus',
  ])
  for (const example of examples) {
    assert.deepEqual(Object.keys(example).sort(), [
      'extension',
      'frontend',
      'id',
      'input',
      'label',
      'note',
      'output',
      'pipeline',
    ])
    const result = spawnSync(binaryPath, ['-', '--syntax', example.id, '--minify'], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      input: example.input,
      maxBuffer: 1024 * 1024,
      timeout: 30_000,
    })
    assert.equal(result.error, undefined, example.id)
    assert.equal(result.signal, null, example.id)
    assert.equal(result.status, 0, `${example.id}: ${result.stderr}`)
    assert.equal(result.stdout, example.output, example.id)
    assert.doesNotMatch(result.stderr, /experimental release candidate/)
  }
})
