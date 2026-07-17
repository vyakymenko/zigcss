import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { runZigCssCore } from '../../../preprocessor/core-runner.mjs'
import { compileStringWithRuntime } from '../../../preprocessor/product-api.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const binaryPath = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const runtime = Object.freeze({ binaryPath, runCore: runZigCssCore, runHost: runPreprocessorHost })
const examples = JSON.parse(fs.readFileSync(
  path.join(repositoryRoot, 'docs/src/data/format-examples.json'),
  'utf8',
))

test('website input/output lab is exact executable evidence for all five syntaxes', async () => {
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
      'id',
      'input',
      'label',
      'note',
      'output',
      'pipeline',
      'provider',
    ])
    const result = await compileStringWithRuntime(example.input, {
      syntax: example.id,
      sourceUrl: `file:///workspace/site-lab/input${example.extension}`,
      format: 'minified',
    }, runtime)
    assert.equal(result.css, example.output, example.id)
    assert.deepEqual(result.diagnostics, [], example.id)
    assert.deepEqual(result.dependencies, [], example.id)
  }
})
