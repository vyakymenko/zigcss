import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  ProviderFailure,
  normalizeDependencies,
  normalizeDiagnostics,
} from '../../../preprocessor/metadata.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function rejectsWithCode(code) {
  return error => error?.code === code
}

test('normalizes provider diagnostics without terminal controls or order drift', () => {
  const diagnostics = normalizeDiagnostics([
    {
      severity: 'warning',
      code: 'deprecated.api',
      message: '\u001b[31mDeprecated\u001b[0m\r\nUse the module API\u0000',
      sourceUrl: null,
      line: 2,
      column: 4,
    },
    {
      severity: 'deprecation',
      code: null,
      message: 'Second warning',
      sourceUrl: 'file:///workspace/dependency.scss',
      line: null,
      column: null,
    },
  ], {
    provider: 'dart-sass',
    defaultSourceUrl: 'file:///workspace/input.scss',
  })

  assert.deepEqual(diagnostics, [
    {
      severity: 'warning',
      code: 'deprecated.api',
      message: 'Deprecated\nUse the module API',
      sourceUrl: 'file:///workspace/input.scss',
      line: 2,
      column: 4,
    },
    {
      severity: 'warning',
      code: null,
      message: 'Second warning',
      sourceUrl: 'file:///workspace/dependency.scss',
      line: null,
      column: null,
    },
  ])
})

test('diagnostic normalization rejects unknown shapes, remote sources, and incoherent locations', () => {
  const base = {
    severity: 'error',
    code: null,
    message: 'Invalid syntax',
    sourceUrl: null,
    line: 1,
    column: 1,
  }
  for (const [diagnostic, code] of [
    [{ ...base, extra: true }, 'METADATA_DIAGNOSTIC_SHAPE'],
    [{ ...base, severity: 'notice' }, 'METADATA_DIAGNOSTIC_SHAPE'],
    [{ ...base, code: '../bad' }, 'METADATA_DIAGNOSTIC_SHAPE'],
    [{ ...base, sourceUrl: 'https://example.com/input.scss' }, 'METADATA_SOURCE_URL'],
    [{ ...base, line: null, column: 1 }, 'METADATA_DIAGNOSTIC_SHAPE'],
    [{ ...base, message: 'x'.repeat(4097) }, 'METADATA_DIAGNOSTIC_LIMIT'],
  ]) {
    assert.throws(
      () => normalizeDiagnostics([diagnostic], {
        provider: 'dart-sass',
        defaultSourceUrl: 'file:///workspace/input.scss',
      }),
      rejectsWithCode(code),
    )
  }
  assert.throws(
    () => normalizeDiagnostics([base], { provider: 'unknown', defaultSourceUrl: null }),
    rejectsWithCode('METADATA_PROVIDER'),
  )
})

test('normalizes and deduplicates canonical dependency facts by first-seen URL', () => {
  assert.deepEqual(normalizeDependencies([
    { url: 'file:///workspace/_tokens.scss', kind: 'use' },
    { url: 'file:///workspace/theme.scss', kind: 'import' },
    { url: 'file:///workspace/_tokens.scss', kind: 'forward' },
  ]), [
    { url: 'file:///workspace/_tokens.scss', kind: 'use' },
    { url: 'file:///workspace/theme.scss', kind: 'import' },
  ])
})

test('dependency normalization rejects non-local, aliased, and malformed facts', () => {
  for (const dependency of [
    { url: 'https://example.com/a.scss', kind: 'import' },
    { url: 'file:///workspace/a.scss?raw=1', kind: 'import' },
    { url: 'file:///workspace/a.scss', kind: 'plugin' },
    { url: null, kind: 'import' },
    { url: 'file:///workspace/a.scss', kind: 'import', extra: true },
  ]) {
    assert.throws(() => normalizeDependencies([dependency]), rejectsWithCode('METADATA_DEPENDENCY'))
  }
})

test('ProviderFailure owns only a bounded public code, message, and normalized diagnostics', () => {
  const diagnostics = normalizeDiagnostics([{
    severity: 'error',
    code: 'sass.parse',
    message: 'Expected expression',
    sourceUrl: 'file:///workspace/input.scss',
    line: 1,
    column: 8,
  }], { provider: 'dart-sass', defaultSourceUrl: null })
  const failure = new ProviderFailure(
    'SASS_COMPILE_ERROR',
    'Dart Sass rejected the input',
    diagnostics,
  )
  assert.equal(failure.code, 'SASS_COMPILE_ERROR')
  assert.equal(failure.message, 'Dart Sass rejected the input')
  assert.deepEqual(failure.diagnostics, diagnostics)
  assert.throws(
    () => new ProviderFailure('bad-code', 'message', diagnostics),
    rejectsWithCode('METADATA_FAILURE'),
  )
})

test('documents closed result ownership without claiming public preprocessor support', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'ordered normalized diagnostics',
    'greatest-lower-bound lookup',
    'UTF-16 columns',
    'reject the entire composition',
    'still publicly unavailable',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
