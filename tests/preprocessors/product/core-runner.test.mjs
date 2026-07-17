import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'
import {
  runZigCssCore,
  validateCoreRequest,
} from '../../../preprocessor/core-runner.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const binaryPath = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const fixture = path.join(repositoryRoot, 'tests/preprocessors/fixtures/core-child-behavior.mjs')

function rejectsWithCode(code) {
  return error => error?.code === code
}

function request(overrides = {}) {
  return {
    protocol: 'zigcss-core-v1',
    requestId: 'request-001',
    operation: 'compile',
    source: '.card { color: red; }',
    sourceUrl: 'file:///workspace/.zigcss-intermediate.css',
    options: {
      format: 'minified',
      sourceMap: true,
      optimize: false,
    },
    ...overrides,
  }
}

test('real core supervisor validates canonical CSS through ZigCSS', async () => {
  const response = await runZigCssCore(request(), { binaryPath })
  assert.equal(response.ok, true)
  assert.equal(response.result.css, '.card{color:red}')
  assert.deepEqual(response.result.diagnostics, [])
  const map = parseSourceMap(response.result.sourceMap)
  assert.deepEqual(map.sources, ['file:///workspace/.zigcss-intermediate.css'])
})

test('real core supervisor exposes no partial CSS after generated-CSS rejection', async () => {
  const response = await runZigCssCore(request({
    requestId: 'request-002',
    source: '.card { broken; color: red; }',
    options: { format: 'pretty', sourceMap: false, optimize: false },
  }), { binaryPath })
  assert.equal(response.ok, false)
  assert.equal('result' in response, false)
  assert.equal(response.error.code, 'CORE_COMPILE_ERROR')
  assert.equal(response.error.diagnostics[0].code, 'CSS0007')
})

test('core request validation owns a closed non-mutating schema', () => {
  const valid = request({
    options: { format: 'pretty', sourceMap: false, optimize: true },
  })
  const normalized = validateCoreRequest(valid)
  valid.options.format = 'minified'
  assert.equal(normalized.options.format, 'pretty')

  for (const invalid of [
    { ...request(), unexpected: true },
    request({ protocol: 'other' }),
    request({ requestId: '../bad' }),
    request({ sourceUrl: 'https://example.com/input.css' }),
    request({ options: { format: 'pretty', sourceMap: true, optimize: true } }),
  ]) {
    assert.throws(() => validateCoreRequest(invalid), error => error?.code?.startsWith('CORE_'))
  }
})

test('core supervisor kills timeouts, cancellation, overflow, stderr, malformed and failed children', async () => {
  const fixtureOptions = mode => ({
    binaryPath: process.execPath,
    binaryArguments: [fixture, mode],
    timeoutMs: 1000,
  })
  const fixtureRequest = request({
    options: { format: 'pretty', sourceMap: false, optimize: false },
  })

  await assert.rejects(
    runZigCssCore(fixtureRequest, { ...fixtureOptions('hang'), timeoutMs: 50 }),
    rejectsWithCode('CORE_PROCESS_TIMEOUT'),
  )
  await assert.rejects(
    runZigCssCore(fixtureRequest, { ...fixtureOptions('flood'), maxStdoutBytes: 1024 }),
    rejectsWithCode('CORE_STDOUT_LIMIT'),
  )
  for (const [mode, code] of [
    ['stderr', 'CORE_STDERR_OUTPUT'],
    ['malformed', 'CORE_RESPONSE_INVALID'],
    ['extra', 'CORE_RESPONSE_INVALID'],
    ['wrong-id', 'CORE_RESPONSE_INVALID'],
    ['exit', 'CORE_PROCESS_EXIT'],
  ]) {
    await assert.rejects(
      runZigCssCore(fixtureRequest, fixtureOptions(mode)),
      rejectsWithCode(code),
      mode,
    )
  }

  const controller = new AbortController()
  setTimeout(() => controller.abort(), 10)
  await assert.rejects(
    runZigCssCore(fixtureRequest, { ...fixtureOptions('hang'), signal: controller.signal }),
    rejectsWithCode('CORE_PROCESS_ABORTED'),
  )
  controller.abort()
  await assert.rejects(
    runZigCssCore(fixtureRequest, { ...fixtureOptions('hang'), signal: controller.signal }),
    rejectsWithCode('CORE_PROCESS_ABORTED'),
  )
})

test('core binary must be an absolute executable regular non-symlink file', {
  skip: process.platform === 'win32',
}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-core-binary-'))
  try {
    const link = path.join(temporary, 'zigcss')
    fs.symlinkSync(process.execPath, link)
    await assert.rejects(
      runZigCssCore(request(), { binaryPath: link }),
      rejectsWithCode('CORE_BINARY_INVALID'),
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
