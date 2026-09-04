import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const require = createRequire(import.meta.url)
const parcelManifestPath = require.resolve('parcel/package.json')
const parcelManifest = JSON.parse(fs.readFileSync(parcelManifestPath, 'utf8'))
const parcelCli = path.resolve(
  path.dirname(parcelManifestPath),
  typeof parcelManifest.bin === 'string' ? parcelManifest.bin : parcelManifest.bin.parcel,
)
const nativeBinaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
const configuredNativeBinary = process.env.ZIGCSS_PARCEL_NATIVE_BINARY
const nativeBinary = configuredNativeBinary === undefined
  ? path.join(repositoryRoot, 'zig-out', 'bin', nativeBinaryName)
  : path.resolve(configuredNativeBinary)
const exampleFiles = Object.freeze([
  '.parcelrc',
  'README.md',
  '_tokens.scss',
  'index.html',
  'package.json',
  'parcel-transformer-zigcss.cjs',
  'styles.scss',
])

function fakeBinarySource() {
  return `#!/usr/bin/env node
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const { pathToFileURL } = require('node:url')
const chunks = []
process.stdin.on('data', chunk => chunks.push(chunk))
process.stdin.on('end', () => {
  if (process.argv.length !== 3 || process.argv[2] !== '--internal-node-v1') process.exit(91)
  const frame = Buffer.concat(chunks)
  if (frame.length < 4 || frame.readUInt32BE(0) !== frame.length - 4) process.exit(92)
  const request = JSON.parse(frame.subarray(4).toString('utf8'))
  const dependency = path.join(path.dirname(request.sourcePath), '_tokens.scss')
  const tokenSource = fs.readFileSync(dependency, 'utf8')
  const accent = tokenSource.match(/\\$accent:\\s*([^;]+);/)?.[1]?.trim()
  if (!accent) process.exit(93)
  fs.appendFileSync(path.join(__dirname, 'compile.log'), request.requestId + '\\n')
  const diagnostic = {
    severity: request.source.includes('__error__') ? 'error' : 'warning',
    code: request.source.includes('__error__') ? 'PARCEL_EXAMPLE_ERROR' : 'PARCEL_EXAMPLE_WARNING',
    message: request.source.includes('__error__') ? 'fixture compilation failed' : 'fixture diagnostic',
    sourceUrl: pathToFileURL(request.sourcePath).href,
    line: 3,
    column: 0,
  }
  const response = request.source.includes('__error__')
    ? {
        protocol: request.protocol,
        requestId: request.requestId,
        ok: false,
        error: {
          code: 'PARCEL_EXAMPLE_ERROR',
          message: 'fixture compilation failed',
          diagnostics: [diagnostic],
        },
      }
    : {
        protocol: request.protocol,
        requestId: request.requestId,
        ok: true,
        result: {
          css: '.card { --parcel-accent: "' + accent + '"; }',
          sourceMap: JSON.stringify({
            version: 3,
            sources: [request.sourcePath],
            sourcesContent: [request.source],
            names: [],
            mappings: 'AAAA',
          }),
          diagnostics: [diagnostic],
          dependencies: [{ kind: 'use', url: pathToFileURL(dependency).href }],
        },
      }
  const body = Buffer.from(JSON.stringify(response))
  const output = Buffer.allocUnsafe(body.length + 4)
  output.writeUInt32BE(body.length)
  body.copy(output, 4)
  process.stdout.write(output)
})
`
}

function createFixture(binary = undefined) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-parcel-')))
  const example = path.join(root, 'examples', 'parcel')
  fs.mkdirSync(example, { recursive: true })
  fs.mkdirSync(path.join(root, 'adapters'))
  fs.mkdirSync(path.join(root, 'bin'))
  for (const filename of exampleFiles) {
    fs.copyFileSync(
      path.join(repositoryRoot, 'examples', 'parcel', filename),
      path.join(example, filename),
    )
  }
  fs.copyFileSync(path.join(repositoryRoot, 'adapters', 'core.cjs'), path.join(root, 'adapters', 'core.cjs'))
  fs.copyFileSync(path.join(repositoryRoot, 'api.cjs'), path.join(root, 'api.cjs'))
  const installedModules = path.join(repositoryRoot, 'node_modules')
  fs.symlinkSync(installedModules, path.join(root, 'node_modules'), process.platform === 'win32' ? 'junction' : 'dir')
  const installedBinary = path.join(root, 'bin', nativeBinaryName)
  if (binary === undefined) {
    fs.writeFileSync(installedBinary, fakeBinarySource(), { mode: 0o755 })
  } else {
    fs.copyFileSync(binary, installedBinary)
    if (process.platform !== 'win32') fs.chmodSync(installedBinary, 0o755)
  }
  return Object.freeze({ root, example, installedBinary })
}

function runParcel(fixture, label) {
  const result = spawnSync(process.execPath, [
    parcelCli,
    'build',
    'index.html',
    '--dist-dir', 'dist',
    '--cache-dir', path.join(fixture.root, '.parcel-cache'),
    '--no-content-hash',
    '--no-optimize',
    '--no-autoinstall',
    '--log-level', 'verbose',
  ], {
    cwd: fixture.example,
    encoding: 'utf8',
    env: { ...process.env, CI: '1', NO_COLOR: '1' },
    maxBuffer: 2 * 1024 * 1024,
    timeout: 30_000,
    windowsHide: true,
  })
  if (result.error !== undefined) {
    throw new Error(`${label} failed to start: ${result.error.message}`)
  }
  return result
}

function outputCss(example) {
  const dist = path.join(example, 'dist')
  const files = fs.readdirSync(dist).filter(filename => filename.endsWith('.css'))
  assert.equal(files.length, 1)
  return fs.readFileSync(path.join(dist, files[0]), 'utf8')
}

function outputMap(example) {
  const dist = path.join(example, 'dist')
  const files = fs.readdirSync(dist).filter(filename => filename.endsWith('.css.map'))
  assert.equal(files.length, 1)
  return JSON.parse(fs.readFileSync(path.join(dist, files[0]), 'utf8'))
}

function compileCount(fixture) {
  const filename = path.join(fixture.root, 'bin', 'compile.log')
  if (!fs.existsSync(filename)) return 0
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).length
}

function supportsNativeProtocol(filename) {
  if (!fs.existsSync(filename)) return false
  const result = spawnSync(filename, ['--internal-node-v1'], {
    input: Buffer.alloc(0),
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  return result.error === undefined && !/unknown option:[^\n]*--internal-node-v1/i.test(result.stderr)
}

function nativeProtocolAvailable(filename, required, probe = supportsNativeProtocol) {
  if (probe(filename)) return true
  if (required) {
    throw new Error('configured ZIGCSS_PARCEL_NATIVE_BINARY does not support the current Node protocol')
  }
  return false
}

test('Parcel integration stays a relative local plugin because public plugin names are closed', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const config = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'examples', 'parcel', '.parcelrc'), 'utf8'))
  const readme = fs.readFileSync(path.join(repositoryRoot, 'examples', 'parcel', 'README.md'), 'utf8')
  assert.deepEqual(
    config.transformers['*.{scss,sass,less,styl,stylus}'],
    ['./parcel-transformer-zigcss.cjs'],
  )
  assert.equal(Object.hasOwn(manifest.exports, './parcel'), false)
  assert.equal(manifest.devDependencies.parcel, '2.16.4')
  assert.equal(manifest.devDependencies['@parcel/plugin'], '2.16.4')
  assert.equal(manifest.devDependencies['@parcel/diagnostic'], '2.16.4')
  assert.equal(manifest.devDependencies['@parcel/source-map'], '2.1.1')
  assert.deepEqual(manifest.dependencies, {})
  assert.match(readme, /Parcel 2\.16\.4/)
  assert.match(readme, /Zig 0\.15\.2 and Node 22\.22\.0/)
  assert.match(readme, /manifest stays\s+dependency-free and script-free/)
  assert.match(readme, /zig build -Doptimize=ReleaseFast/)
  assert.match(readme, /npm ci --ignore-scripts/)
  assert.match(readme, /ZIGCSS_PARCEL_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:parcel-example/)
  assert.match(readme, /not a published `zigcss\/parcel` export/)
  assert.equal(nativeProtocolAvailable('unused', false, () => false), false)
  assert.throws(
    () => nativeProtocolAvailable('unused', true, () => false),
    /configured ZIGCSS_PARCEL_NATIVE_BINARY does not support the current Node protocol/,
  )
})

test('Parcel 2.16.4 rejects a zigcss/parcel transformer package subpath', t => {
  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
  fs.writeFileSync(path.join(fixture.example, '.parcelrc'), JSON.stringify({
    extends: '@parcel/config-default',
    transformers: { '*.scss': ['zigcss/parcel'] },
  }))
  const result = runParcel(fixture, 'invalid package-subpath Parcel build')
  assert.equal(result.signal, null)
  assert.notEqual(result.status, 0)
  assert.match(
    `${result.stdout}\n${result.stderr}`,
    /Parcel transformer packages must be named according to\s+"parcel-transformer-\{name\}"/,
  )
})

test('real Parcel build carries maps diagnostics and imported-file invalidation', t => {
  if (process.platform === 'win32') {
    t.skip('the deterministic protocol fixture uses a POSIX executable script')
    return
  }
  const fixture = createFixture()
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))

  const first = runParcel(fixture, 'initial Parcel build')
  assert.equal(first.signal, null)
  assert.equal(first.status, 0, first.stderr || first.stdout)
  assert.match(`${first.stdout}\n${first.stderr}`, /PARCEL_EXAMPLE_WARNING/)
  assert.match(outputCss(fixture.example), /--parcel-accent:\s*"rebeccapurple"/)
  const map = outputMap(fixture.example)
  assert.equal(map.version, 3)
  assert.equal(map.sources.some(source => source.endsWith('styles.scss')), true)
  const initialCompiles = compileCount(fixture)
  assert.equal(initialCompiles >= 1, true)

  fs.writeFileSync(path.join(fixture.example, '_tokens.scss'), '$accent: mediumseagreen;\n')
  const changed = runParcel(fixture, 'dependency-invalidated Parcel build')
  assert.equal(changed.signal, null)
  assert.equal(changed.status, 0, changed.stderr || changed.stdout)
  assert.match(outputCss(fixture.example), /--parcel-accent:\s*"mediumseagreen"/)
  const changedCompiles = compileCount(fixture)
  assert.equal(changedCompiles > initialCompiles, true)

  const unchanged = runParcel(fixture, 'cached Parcel build')
  assert.equal(unchanged.signal, null)
  assert.equal(unchanged.status, 0, unchanged.stderr || unchanged.stdout)
  assert.equal(compileCount(fixture), changedCompiles)

  fs.appendFileSync(path.join(fixture.example, 'styles.scss'), '\n__error__\n')
  const failed = runParcel(fixture, 'diagnostic Parcel build')
  assert.equal(failed.signal, null)
  assert.notEqual(failed.status, 0)
  assert.match(`${failed.stdout}\n${failed.stderr}`, /PARCEL_EXAMPLE_ERROR/)
  assert.match(`${failed.stdout}\n${failed.stderr}`, /fixture compilation\s+failed/)
})

test('current native ZigCSS binary completes the local Parcel pipeline', t => {
  if (!nativeProtocolAvailable(nativeBinary, configuredNativeBinary !== undefined)) {
    t.skip('native ZigCSS binary with Node protocol is not built on this host')
    return
  }
  const fixture = createFixture(nativeBinary)
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))
  const result = runParcel(fixture, 'native ZigCSS Parcel build')
  assert.equal(result.signal, null)
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.match(outputCss(fixture.example), /(?:rebeccapurple|#639)/)
  const map = outputMap(fixture.example)
  assert.equal(map.version, 3)
  assert.equal(map.sources.some(source => source.endsWith('styles.scss')), true)
})
