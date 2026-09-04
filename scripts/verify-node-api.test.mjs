import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test, { after, before } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
const windowsSkip = process.platform === 'win32'
  ? 'the protocol fixture is a shebang executable; the production API itself supports zigcss.exe'
  : false

let fixtureRoot
let binary
let cjs
let esm

function fakeBinarySource() {
  return `#!/usr/bin/env node
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const PROTOCOL = 'zigcss-node-v1'
const chunks = []
process.stdin.on('data', chunk => chunks.push(chunk))
process.stdin.on('end', () => {
  fs.appendFileSync(path.join(__dirname, '..', 'spawn.log'), 'spawn\\n')
  if (process.argv.length !== 3 || process.argv[2] !== '--internal-node-v1') process.exit(91)
  const input = Buffer.concat(chunks)
  if (input.length < 4 || input.readUInt32BE(0) !== input.length - 4) process.exit(92)
  const request = JSON.parse(input.subarray(4).toString('utf8'))
  const source = request.source
  const writeBody = value => {
    const body = Buffer.from(JSON.stringify(value))
    const frame = Buffer.allocUnsafe(body.length + 4)
    frame.writeUInt32BE(body.length, 0)
    body.copy(frame, 4)
    process.stdout.write(frame)
  }
  const success = overrides => writeBody({
    protocol: PROTOCOL,
    requestId: request.requestId,
    ok: true,
    result: {
      css: source.startsWith('__echo__') ? JSON.stringify(request) : '[' + request.options.syntax + ']' + source,
      sourceMap: request.options.sourceMap ? JSON.stringify({
        version: 3,
        sources: [request.sourcePath],
        names: [],
        mappings: '',
        x_nested: { values: [1, { owned: true }] },
      }) : null,
      diagnostics: source === '__owned__'
        ? [{
            severity: 'note',
            code: 'NOTE',
            message: 'owned',
            sourceUrl: request.sourcePath,
            line: 1,
            column: 0,
            nested: { values: [1, 2] },
          }]
        : [],
      dependencies: request.options.syntax === 'css'
        ? [{ kind: 'css-import', specifier: 'theme.css', sourceUrl: request.sourcePath, start: 0, end: 10 }]
        : [{ kind: request.options.syntax === 'scss' ? 'use' : 'import', url: request.sourcePath + '.dep' }],
      ...overrides,
    },
  })

  if (source === '__hang__') {
    setInterval(() => {}, 1000)
    return
  }
  if (source === '__stderr_flood__') {
    process.stderr.write(Buffer.alloc(4 * 1024 * 1024 + 1, 120), () => process.exit(2))
    return
  }
  if (source === '__sync_stdout_flood__') {
    process.stdout.write(Buffer.alloc(4 * 1024 * 1024 + 1, 120))
    return
  }
  if (source === '__process_error__') {
    process.stderr.write('strict target query rejected\\n')
    process.exit(2)
  }
  if (
    source === '.a{content:"🙂";/*xx*/broken;color:red}' ||
    source === '.a{content:"🙂";color:$missing}'
  ) {
    writeBody({
      protocol: PROTOCOL,
      requestId: request.requestId,
      ok: false,
      error: {
        code: 'NODE_COMPILE_ERROR',
        message: 'UTF-16 diagnostic fixture',
        diagnostics: [{
          severity: 'error',
          code: request.options.syntax === 'css' ? 'CSS0007' : 'NATIVE0002',
          message: 'location fixture',
          sourceUrl: request.sourcePath,
          line: 1,
          column: 22,
        }],
      },
    })
    return
  }
  if (source === '__compile_error__') {
    writeBody({
      protocol: PROTOCOL,
      requestId: request.requestId,
      ok: false,
      error: {
        code: 'NODE_COMPILE_ERROR',
        message: 'native syntax rejected',
        diagnostics: [{
          severity: 'error',
          code: 'NATIVE0001',
          message: 'broken',
          sourceUrl: request.sourcePath,
          line: 1,
          column: 0,
          nested: { at: [1] },
        }],
      },
    })
    return
  }
  if (source === '__malformed_json__') {
    process.stdout.write(Buffer.from([0, 0, 0, 1, 123]))
    return
  }
  if (source === '__truncated__') {
    process.stdout.write(Buffer.from([0, 0, 0, 9, 123, 125]))
    return
  }
  if (source === '__trailing__') {
    const body = Buffer.from('{}')
    process.stdout.write(Buffer.from([0, 0, 0, body.length, ...body, 0]))
    return
  }
  if (source === '__oversized__') {
    const header = Buffer.alloc(4)
    header.writeUInt32BE(128 * 1024 * 1024 + 1)
    process.stdout.write(header)
    return
  }
  if (source === '__mismatch__') {
    writeBody({
      protocol: PROTOCOL,
      requestId: request.requestId + '-wrong',
      ok: true,
      result: { css: '', sourceMap: null, diagnostics: [], dependencies: [] },
    })
    return
  }
  if (source === '__wrong_protocol__') {
    writeBody({
      protocol: 'wrong',
      requestId: request.requestId,
      ok: true,
      result: { css: '', sourceMap: null, diagnostics: [], dependencies: [] },
    })
    return
  }
  if (source === '__bad_map__') {
    success({ sourceMap: '{' })
    return
  }
  if (source === '__bad_map_shape__') {
    success({ sourceMap: '{}' })
    return
  }
  if (source === '__bad_diagnostic__') {
    success({ diagnostics: [{ severity: 'note', code: 'NOTE', message: 'missing location' }] })
    return
  }
  if (source === '__zero_line_diagnostic__') {
    success({ diagnostics: [{ severity: 'note', code: 'NOTE', message: 'zero line', sourceUrl: request.sourcePath, line: 0, column: 0 }] })
    return
  }
  if (source === '__bad_dependency__') {
    success({ dependencies: [{ kind: 'css-import', specifier: 'theme.css', sourceUrl: request.sourcePath, start: 10, end: 1 }] })
    return
  }
  if (source === '__bad_css_encoding__') {
    success({ css: '\\ud800' })
    return
  }
  if (source === '__partial_error__') {
    writeBody({
      protocol: PROTOCOL,
      requestId: request.requestId,
      ok: false,
      error: { code: 'NODE_COMPILE_ERROR', message: 'no partial result', diagnostics: [] },
      result: { css: 'must-not-escape', sourceMap: null, diagnostics: [], dependencies: [] },
    })
    return
  }
  success()
})
`
}

function spawnCount() {
  const filename = path.join(fixtureRoot, 'spawn.log')
  return fs.existsSync(filename) ? fs.readFileSync(filename, 'utf8').trim().split(/\n/).length : 0
}

function expectCompileError(code) {
  return error => {
    assert.equal(error instanceof cjs.ZigCssCompileError, true)
    assert.equal(error.code, code)
    assert.equal('css' in error, false)
    return true
  }
}

before(async () => {
  if (windowsSkip) return
  fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-node-api-'))
  fs.copyFileSync(path.join(repositoryRoot, 'api.cjs'), path.join(fixtureRoot, 'api.cjs'))
  fs.copyFileSync(path.join(repositoryRoot, 'api.mjs'), path.join(fixtureRoot, 'api.mjs'))
  fs.mkdirSync(path.join(fixtureRoot, 'bin'))
  for (const directory of ['workspace', 'imports', 'parallel']) {
    fs.mkdirSync(path.join(fixtureRoot, directory))
  }
  binary = path.join(fixtureRoot, 'bin', binaryName)
  fs.writeFileSync(binary, fakeBinarySource(), { mode: 0o755 })
  fs.chmodSync(binary, 0o755)
  cjs = createRequire(import.meta.url)(path.join(fixtureRoot, 'api.cjs'))
  esm = await import(`${pathToFileURL(path.join(fixtureRoot, 'api.mjs')).href}?fixture=1`)
})

after(() => {
  if (fixtureRoot) fs.rmSync(fixtureRoot, { recursive: true, force: true })
})

test('programmatic Node API exposes matching CommonJS and real ESM surfaces', { skip: windowsSkip }, () => {
  const names = [
    'compile',
    'compileSync',
    'compileFile',
    'compileFileSync',
    'detectSyntax',
    'ZigCssCompileError',
  ]
  assert.deepEqual(Object.keys(cjs), names)
  for (const name of names) {
    assert.equal(esm[name], cjs[name])
    assert.equal(esm.default[name], cjs[name])
  }
  assert.equal(Object.isFrozen(cjs), true)
  assert.equal(Object.isFrozen(esm.default), true)
})

test('detectSyntax owns the closed five-syntax extension set', { skip: windowsSkip }, () => {
  for (const [filename, syntax] of [
    ['input.css', 'css'],
    ['input.scss', 'scss'],
    ['input.sass', 'sass'],
    ['input.less', 'less'],
    ['input.styl', 'stylus'],
    ['input.stylus', 'stylus'],
    ['INPUT.SCSS', 'scss'],
  ]) {
    assert.equal(cjs.detectSyntax(filename), syntax)
  }
  assert.throws(() => cjs.detectSyntax('input.txt'), expectCompileError('API_OPTIONS'))
})

test('string API routes all five syntaxes through one exact framed request', { skip: windowsSkip }, async () => {
  for (const syntax of ['css', 'scss', 'sass', 'less', 'stylus']) {
    const sourcePath = path.join(fixtureRoot, 'workspace', `input.${syntax === 'stylus' ? 'styl' : syntax}`)
    const asyncResult = await cjs.compile('.item { color: red; }', {
      syntax,
      sourcePath,
      format: 'minified',
    })
    const syncResult = cjs.compileSync('.item { color: red; }', {
      syntax,
      sourcePath,
      format: 'minified',
    })
    assert.equal(asyncResult.css, `[${syntax}].item { color: red; }`)
    assert.deepEqual(syncResult, asyncResult)
    assert.equal(Object.isFrozen(asyncResult), true)
  }
})

test('request normalization carries maps, dependencies, optimizer, prefix query, and roots', { skip: windowsSkip }, async () => {
  const sourcePath = path.join(fixtureRoot, 'workspace', 'input.scss')
  const relativeRoot = path.relative(process.cwd(), path.join(fixtureRoot, 'imports'))
  const mapResult = await esm.compile('__owned__', {
    sourcePath,
    syntax: 'scss',
    sourceMap: true,
  })
  const canonicalSourcePath = path.join(fs.realpathSync(path.dirname(sourcePath)), path.basename(sourcePath))
  assert.deepEqual(mapResult.sourceMap.sources, [canonicalSourcePath])
  assert.equal(mapResult.dependencies[0].kind, 'use')
  assert.equal(Object.isFrozen(mapResult.sourceMap), true)
  assert.equal(Object.isFrozen(mapResult.sourceMap.x_nested), true)
  assert.equal(Object.isFrozen(mapResult.sourceMap.x_nested.values), true)
  assert.equal(Object.isFrozen(mapResult.diagnostics), true)
  assert.equal(Object.isFrozen(mapResult.diagnostics[0]), true)
  assert.equal(Object.isFrozen(mapResult.diagnostics[0].nested.values), true)
  assert.equal(Object.isFrozen(mapResult.dependencies), true)
  assert.equal(Object.isFrozen(mapResult.dependencies[0]), true)

  const echoed = JSON.parse((await cjs.compile('__echo__', {
    sourcePath,
    syntax: 'scss',
    rootPaths: [path.dirname(sourcePath), relativeRoot],
    optimize: true,
    browsers: 'safari >= 7, ie >= 11',
    format: 'minified',
  })).css)
  assert.equal(echoed.protocol, 'zigcss-node-v1')
  assert.equal(echoed.operation, 'compile')
  assert.equal(echoed.sourcePath, canonicalSourcePath)
  assert.deepEqual(echoed.rootPaths, [
    fs.realpathSync(path.dirname(sourcePath)),
    fs.realpathSync(path.resolve(relativeRoot)),
  ])
  assert.deepEqual(echoed.options, {
    syntax: 'scss',
    format: 'minified',
    sourceMap: false,
    optimize: true,
    browsers: 'safari >= 7, ie >= 11',
  })
})

test('source parents and explicit roots are canonical across directory symlinks', {
  skip: windowsSkip,
}, async () => {
  const canonicalRoot = path.join(fixtureRoot, 'canonical-root')
  const linkedRoot = path.join(fixtureRoot, 'linked-root')
  fs.mkdirSync(canonicalRoot)
  fs.symlinkSync(canonicalRoot, linkedRoot, 'dir')
  const echoed = JSON.parse((await cjs.compile('__echo__', {
    syntax: 'scss',
    sourcePath: path.join(linkedRoot, 'virtual.scss'),
    rootPaths: [linkedRoot],
  })).css)
  assert.equal(echoed.sourcePath, path.join(fs.realpathSync(canonicalRoot), 'virtual.scss'))
  assert.deepEqual(echoed.rootPaths, [fs.realpathSync(canonicalRoot)])

  const linkedFile = path.join(linkedRoot, 'entry.scss')
  fs.writeFileSync(path.join(canonicalRoot, 'entry.scss'), '__echo__')
  const fileRequest = JSON.parse((await cjs.compileFile(linkedFile)).css)
  assert.equal(fileRequest.sourcePath, fs.realpathSync(path.join(canonicalRoot, 'entry.scss')))
  assert.deepEqual(fileRequest.rootPaths, [fs.realpathSync(canonicalRoot)])
})

test('shell-hostile Unicode and newlines remain framed data, never command text', { skip: windowsSkip }, async () => {
  const sentinel = path.join(fixtureRoot, 'must-not-exist')
  const source = `__echo__\n.card::before { content: "🙂 \` $(touch ${sentinel})"; }`
  const browsers = `chrome >= 120,\nfirefox >= 120 $(touch ${sentinel}) 🙂`
  const result = await cjs.compile(source, {
    syntax: 'css',
    sourcePath: path.join(fixtureRoot, 'hostile.css'),
    browsers,
  })
  const request = JSON.parse(result.css)
  assert.equal(request.source, source)
  assert.equal(request.options.browsers, browsers)
  assert.equal(fs.existsSync(sentinel), false)
})

test('file APIs infer all five syntaxes and default roots to the entry directory', { skip: windowsSkip }, async () => {
  const cases = [
    ['css', 'css'],
    ['scss', 'scss'],
    ['sass', 'sass'],
    ['less', 'less'],
    ['styl', 'stylus'],
    ['stylus', 'stylus'],
  ]
  for (const [extension, syntax] of cases) {
    const filename = path.join(fixtureRoot, 'files', `input.${extension}`)
    fs.mkdirSync(path.dirname(filename), { recursive: true })
    fs.writeFileSync(filename, '__echo__')
    const asynchronous = JSON.parse((await cjs.compileFile(filename)).css)
    const synchronous = JSON.parse(cjs.compileFileSync(filename).css)
    const canonicalFilename = fs.realpathSync(filename)
    for (const request of [asynchronous, synchronous]) {
      assert.equal(request.sourcePath, canonicalFilename)
      assert.equal(request.options.syntax, syntax)
      assert.deepEqual(request.rootPaths, [path.dirname(canonicalFilename)])
    }
  }
})

test('file APIs bind one stable no-follow descriptor across admission and read', {
  skip: windowsSkip,
}, async () => {
  const directory = path.join(fixtureRoot, 'descriptor-races')
  fs.mkdirSync(directory)
  const input = path.join(directory, 'input.scss')
  const replacement = path.join(directory, 'replacement.scss')
  fs.writeFileSync(input, '__echo__')
  fs.writeFileSync(replacement, '__echo__replacement')
  const canonicalInput = fs.realpathSync(input)
  const beforeCount = spawnCount()

  const originalAsyncOpen = fs.promises.open
  let swappedAsync = false
  fs.promises.open = async function racedOpen(filename, flags, mode) {
    if (!swappedAsync && filename === canonicalInput) {
      swappedAsync = true
      fs.unlinkSync(input)
      fs.symlinkSync(replacement, input)
    }
    return originalAsyncOpen.call(this, filename, flags, mode)
  }
  try {
    await assert.rejects(cjs.compileFile(input), expectCompileError('API_INPUT'))
  } finally {
    fs.promises.open = originalAsyncOpen
    fs.unlinkSync(input)
    fs.writeFileSync(input, '__echo__')
  }

  const originalSyncOpen = fs.openSync
  let swappedSync = false
  fs.openSync = function racedOpenSync(filename, flags, mode) {
    if (!swappedSync && filename === canonicalInput) {
      swappedSync = true
      fs.unlinkSync(input)
      fs.symlinkSync(replacement, input)
    }
    return originalSyncOpen.call(this, filename, flags, mode)
  }
  try {
    assert.throws(() => cjs.compileFileSync(input), expectCompileError('API_INPUT'))
  } finally {
    fs.openSync = originalSyncOpen
    fs.unlinkSync(input)
    fs.writeFileSync(input, '__echo__')
  }

  const originalGrowingOpen = fs.promises.open
  let grew = false
  fs.promises.open = async function growingOpen(filename, flags, mode) {
    const handle = await originalGrowingOpen.call(this, filename, flags, mode)
    if (filename !== canonicalInput) return handle
    const originalRead = handle.read.bind(handle)
    handle.read = async (...arguments_) => {
      const result = await originalRead(...arguments_)
      if (!grew && result.bytesRead > 0) {
        grew = true
        fs.appendFileSync(input, 'x')
      }
      return result
    }
    return handle
  }
  try {
    await assert.rejects(cjs.compileFile(input), expectCompileError('API_INPUT'))
  } finally {
    fs.promises.open = originalGrowingOpen
  }

  assert.equal(spawnCount(), beforeCount)
})

test('validation is closed and rejects unsafe combinations before process launch', { skip: windowsSkip }, async () => {
  const beforeCount = spawnCount()
  const invalidAsync = [
    [{ unexpected: true }, 'API_OPTIONS'],
    [{ syntax: 'unknown' }, 'API_OPTIONS'],
    [{ sourceMap: true, optimize: true }, 'API_OPTIONS'],
    [{ rootPaths: [] }, 'API_OPTIONS'],
    [{ rootPaths: Array(1) }, 'API_OPTIONS'],
    [{ rootPaths: Array.from({ length: 17 }, (_, index) => `root-${index}`) }, 'API_OPTIONS'],
    [{ rootPaths: ['same', './same'] }, 'API_OPTIONS'],
    [{ sourcePath: 'bad\npath.scss' }, 'API_OPTIONS'],
    [{ rootPaths: ['bad\rroot'] }, 'API_OPTIONS'],
    [{ sourcePath: path.join(fixtureRoot, 'missing-parent', 'input.scss') }, 'API_OPTIONS'],
    [{ rootPaths: [path.join(fixtureRoot, 'missing-root')] }, 'API_OPTIONS'],
    [{ browsers: '' }, 'API_OPTIONS'],
    [{ browsers: 'a'.repeat(4097) }, 'API_OPTIONS'],
    [{ timeoutMs: 0 }, 'API_OPTIONS'],
    [{ signal: {} }, 'API_OPTIONS'],
  ]
  for (const [options, code] of invalidAsync) {
    await assert.rejects(cjs.compile('.a{}', options), expectCompileError(code))
  }
  assert.throws(
    () => cjs.compileSync('.a{}', { signal: new AbortController().signal }),
    expectCompileError('API_OPTIONS'),
  )
  assert.throws(
    () => cjs.compileSync('x'.repeat(10 * 1024 * 1024 + 1)),
    expectCompileError('API_INPUT'),
  )
  assert.throws(
    () => cjs.compileSync('\ud800'),
    expectCompileError('API_INPUT_ENCODING'),
  )
  assert.throws(
    () => cjs.detectSyntax('bad\ud800.scss'),
    expectCompileError('API_OPTIONS'),
  )
  await assert.rejects(
    cjs.compile('.a{}', { browsers: 'ie >= 11\ud800' }),
    expectCompileError('API_OPTIONS'),
  )
  await assert.rejects(
    cjs.compile('.a{}', {
      sourcePath: path.join(fixtureRoot, 'workspace', 'outside.css'),
      rootPaths: [path.join(fixtureRoot, 'imports')],
    }),
    expectCompileError('API_OPTIONS'),
  )
  const invalidUtf8 = path.join(fixtureRoot, 'invalid.scss')
  fs.writeFileSync(invalidUtf8, Buffer.from([0xff, 0xfe]))
  await assert.rejects(cjs.compileFile(invalidUtf8), expectCompileError('API_INPUT_ENCODING'))
  assert.throws(() => cjs.compileFileSync(invalidUtf8), expectCompileError('API_INPUT_ENCODING'))
  await assert.rejects(
    cjs.compileFile(path.join(fixtureRoot, 'missing.scss')),
    expectCompileError('API_INPUT'),
  )
  const rootFile = path.join(fixtureRoot, 'not-a-root')
  fs.writeFileSync(rootFile, '')
  await assert.rejects(
    cjs.compile('.a{}', { rootPaths: [rootFile] }),
    expectCompileError('API_OPTIONS'),
  )
  assert.equal(spawnCount(), beforeCount)
})

test('compile failures expose immutable diagnostics and never partial CSS', { skip: windowsSkip }, async () => {
  await assert.rejects(cjs.compile('__compile_error__'), error => {
    assert.equal(expectCompileError('NODE_COMPILE_ERROR')(error), true)
    assert.equal(error.message, 'native syntax rejected')
    assert.equal(error.diagnostics[0].code, 'NATIVE0001')
    assert.equal(Object.isFrozen(error.diagnostics), true)
    assert.equal(Object.isFrozen(error.diagnostics[0]), true)
    assert.equal(Object.isFrozen(error.diagnostics[0].nested.at), true)
    return true
  })
  assert.throws(
    () => cjs.compileSync('__partial_error__'),
    expectCompileError('API_PROTOCOL'),
  )
  await assert.rejects(cjs.compile('__process_error__'), error => {
    assert.equal(expectCompileError('API_PROCESS')(error), true)
    assert.match(error.message, /strict target query rejected/)
    return true
  })
})

test('CSS and native diagnostics expose one-based lines and zero-based UTF-16 columns', {
  skip: windowsSkip,
}, async () => {
  const cases = [
    ['css', '.a{content:"🙂";/*xx*/broken;color:red}'],
    ['scss', '.a{content:"🙂";color:$missing}'],
  ]
  for (const [syntax, source] of cases) {
    const sourcePath = path.join(fixtureRoot, 'workspace', `diagnostic.${syntax}`)
    const canonicalSourcePath = path.join(
      fs.realpathSync(path.dirname(sourcePath)),
      path.basename(sourcePath),
    )
    await assert.rejects(cjs.compile(source, { syntax, sourcePath }), error => {
      assert.equal(expectCompileError('NODE_COMPILE_ERROR')(error), true)
      assert.equal(error.diagnostics[0].line, 1)
      assert.equal(error.diagnostics[0].column, 22)
      assert.equal(error.diagnostics[0].sourceUrl, canonicalSourcePath)
      return true
    })
    assert.throws(() => cjs.compileSync(source, { syntax, sourcePath }), error => {
      assert.equal(expectCompileError('NODE_COMPILE_ERROR')(error), true)
      assert.equal(error.diagnostics[0].line, 1)
      assert.equal(error.diagnostics[0].column, 22)
      return true
    })
  }
})

test('malformed, truncated, mismatched, oversized, and invalid typed responses fail closed', { skip: windowsSkip }, async () => {
  const cases = [
    ['__malformed_json__', 'API_PROTOCOL'],
    ['__truncated__', 'API_PROTOCOL'],
    ['__trailing__', 'API_PROTOCOL'],
    ['__mismatch__', 'API_PROTOCOL'],
    ['__wrong_protocol__', 'API_PROTOCOL'],
    ['__oversized__', 'API_RESPONSE_LIMIT'],
    ['__bad_map__', 'API_PROTOCOL'],
    ['__bad_map_shape__', 'API_PROTOCOL'],
    ['__bad_diagnostic__', 'API_PROTOCOL'],
    ['__zero_line_diagnostic__', 'API_PROTOCOL'],
    ['__bad_dependency__', 'API_PROTOCOL'],
    ['__bad_css_encoding__', 'API_PROTOCOL'],
  ]
  for (const [source, code] of cases) {
    await assert.rejects(cjs.compile(source), expectCompileError(code))
    assert.throws(() => cjs.compileSync(source), expectCompileError(code))
  }
})

test('async API enforces timeout and AbortSignal termination', { skip: windowsSkip }, async () => {
  await assert.rejects(
    cjs.compile('__hang__', { timeoutMs: 25 }),
    expectCompileError('API_TIMEOUT'),
  )
  const controller = new AbortController()
  const pending = cjs.compile('__hang__', { timeoutMs: 1000, signal: controller.signal })
  setTimeout(() => controller.abort(), 25)
  await assert.rejects(pending, expectCompileError('API_ABORTED'))

  const alreadyAborted = new AbortController()
  alreadyAborted.abort()
  await assert.rejects(
    cjs.compile('.a{}', { signal: alreadyAborted.signal }),
    expectCompileError('API_ABORTED'),
  )
})

test('stderr floods are bounded independently of response data', { skip: windowsSkip }, async () => {
  await assert.rejects(cjs.compile('__stderr_flood__'), expectCompileError('API_STDERR_LIMIT'))
  assert.throws(() => cjs.compileSync('__stderr_flood__'), expectCompileError('API_STDERR_LIMIT'))
})

test('sync response buffering is capped at one 4 MiB framed output', { skip: windowsSkip }, () => {
  assert.throws(() => cjs.compileSync('__sync_stdout_flood__'), expectCompileError('API_RESPONSE_LIMIT'))
})

test('parallel asynchronous compilation is deterministic and request-isolated', { skip: windowsSkip }, async () => {
  const results = await Promise.all(Array.from({ length: 20 }, (_, index) => (
    cjs.compile(`source-${index}`, {
      syntax: ['css', 'scss', 'sass', 'less', 'stylus'][index % 5],
      sourcePath: path.join(fixtureRoot, 'parallel', `input-${index}.css`),
    })
  )))
  assert.deepEqual(results.map(result => result.css), Array.from({ length: 20 }, (_, index) => (
    `[${['css', 'scss', 'sass', 'less', 'stylus'][index % 5]}]source-${index}`
  )))
})

test('missing packaged binary has one stable API error in sync and async modes', { skip: windowsSkip }, async () => {
  const parked = `${binary}.parked`
  fs.renameSync(binary, parked)
  try {
    assert.throws(() => cjs.compileSync('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
    await assert.rejects(cjs.compile('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
  } finally {
    fs.renameSync(parked, binary)
  }
})

test('a direct source checkout selects only its marker-verified confined freshly built native binary', { skip: windowsSkip }, t => {
  const sourceRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-node-api-source-')))
  const externalRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-node-api-external-')))
  t.after(() => {
    fs.rmSync(sourceRoot, { recursive: true, force: true })
    fs.rmSync(externalRoot, { recursive: true, force: true })
  })
  fs.copyFileSync(path.join(repositoryRoot, 'api.cjs'), path.join(sourceRoot, 'api.cjs'))
  fs.writeFileSync(path.join(sourceRoot, 'build.zig'), '// source-checkout marker\n')
  fs.mkdirSync(path.join(sourceRoot, 'src'))
  const protocolMarker = path.join(sourceRoot, 'src', 'node_protocol.zig')
  fs.writeFileSync(protocolMarker, '// source-checkout protocol marker\n')
  const zigOut = path.join(sourceRoot, 'zig-out')
  fs.mkdirSync(path.join(zigOut, 'bin'), { recursive: true })
  const sourceBinary = path.join(sourceRoot, 'zig-out', 'bin', binaryName)
  fs.writeFileSync(sourceBinary, fakeBinarySource(), { mode: 0o755 })
  fs.chmodSync(sourceBinary, 0o755)

  const sourceApi = createRequire(import.meta.url)(path.join(sourceRoot, 'api.cjs'))
  assert.equal(sourceApi.compileSync('.source{}').css, '[css].source{}')

  const assertBinaryNotFound = label => assert.throws(
    () => sourceApi.compileSync('.source{}'),
    error => {
      assert.equal(error.code, 'API_BINARY_NOT_FOUND', label)
      return true
    },
  )

  const parkedMarker = `${protocolMarker}.regular`
  fs.renameSync(protocolMarker, parkedMarker)
  assertBinaryNotFound('source-checkout API must reject a missing protocol marker')
  fs.symlinkSync(path.basename(parkedMarker), protocolMarker)
  assertBinaryNotFound('source-checkout API must reject a symlink protocol marker')
  fs.unlinkSync(protocolMarker)
  fs.renameSync(parkedMarker, protocolMarker)

  const regular = `${sourceBinary}.regular`
  fs.renameSync(sourceBinary, regular)
  fs.symlinkSync(regular, sourceBinary)
  assertBinaryNotFound('source-checkout API must reject a final binary symlink')
  fs.unlinkSync(sourceBinary)
  fs.renameSync(regular, sourceBinary)

  const localZigOut = `${zigOut}.local`
  fs.renameSync(zigOut, localZigOut)
  const externalZigOut = path.join(externalRoot, 'zig-out')
  const externalBinaryDirectory = path.join(externalZigOut, 'bin')
  fs.mkdirSync(externalBinaryDirectory, { recursive: true })
  const externalBinary = path.join(externalBinaryDirectory, binaryName)
  fs.writeFileSync(externalBinary, fakeBinarySource(), { mode: 0o755 })
  fs.chmodSync(externalBinary, 0o755)
  fs.symlinkSync(externalZigOut, zigOut, 'dir')
  assertBinaryNotFound('source-checkout API must reject an intermediate-directory escape')
})

test('packaged Node API rejects non-executable, symlink, and package-root escape substitution', {
  skip: windowsSkip,
}, async () => {
  fs.chmodSync(binary, 0o644)
  try {
    assert.throws(() => cjs.compileSync('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
    await assert.rejects(cjs.compile('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
  } finally {
    fs.chmodSync(binary, 0o755)
  }

  const parked = `${binary}.regular`
  fs.renameSync(binary, parked)
  fs.symlinkSync(parked, binary)
  try {
    assert.throws(() => cjs.compileSync('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
    await assert.rejects(cjs.compile('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
  } finally {
    fs.unlinkSync(binary)
    fs.renameSync(parked, binary)
  }

  const packageBin = path.dirname(binary)
  const localBin = `${packageBin}.local`
  const externalRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-node-api-packaged-external-')))
  const externalBin = path.join(externalRoot, 'bin')
  fs.mkdirSync(externalBin)
  const externalBinary = path.join(externalBin, binaryName)
  fs.writeFileSync(externalBinary, fakeBinarySource(), { mode: 0o755 })
  fs.chmodSync(externalBinary, 0o755)
  fs.renameSync(packageBin, localBin)
  fs.symlinkSync(externalBin, packageBin, 'dir')
  try {
    assert.throws(() => cjs.compileSync('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
    await assert.rejects(cjs.compile('.a{}'), expectCompileError('API_BINARY_NOT_FOUND'))
  } finally {
    fs.unlinkSync(packageBin)
    fs.renameSync(localBin, packageBin)
    fs.rmSync(externalRoot, { recursive: true, force: true })
  }
})
