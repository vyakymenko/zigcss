import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test, { after, before } from 'node:test'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const require = createRequire(import.meta.url)
const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
const configuredNativeBinary = process.env.ZIGCSS_ADAPTER_NATIVE_BINARY ?? null
const windowsSkip = process.platform === 'win32'
  ? 'the protocol fixture uses a POSIX shebang; release consumers cover zigcss.exe'
  : false

let fixtureRoot
let workspace
let core
let adapters
let vite
let rollup
let esbuild
let bun
let webpackLoader
let rspackLoader

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
  const source = request.source
  const log = path.join(__dirname, '..', 'spawn.log')
  const respond = value => {
    const body = Buffer.from(JSON.stringify(value))
    const output = Buffer.allocUnsafe(body.length + 4)
    output.writeUInt32BE(body.length)
    body.copy(output, 4)
    process.stdout.write(output)
  }
  const diagnosticSourceMatch = source.match(/^__diagnostic_source__=(.+)$/m)
  const diagnosticSourcePath = diagnosticSourceMatch?.[1] ?? request.sourcePath
  const diagnostic = {
    severity: 'warning',
    code: 'ADAPTER_NOTE',
    message: 'fixture warning',
    sourceUrl: pathToFileURL(diagnosticSourcePath).href,
    line: 1,
    column: source.startsWith('é🙂') ? 3 : 2,
  }
  const dependency = path.join(path.dirname(request.sourcePath), '_dependency.scss')
  const finish = () => {
    if (source.includes('__error__')) {
      respond({
        protocol: request.protocol,
        requestId: request.requestId,
        ok: false,
        error: {
          code: 'ADAPTER_COMPILE',
          message: 'fixture compilation failed',
          diagnostics: [{ ...diagnostic, severity: 'error', code: 'ADAPTER_ERROR' }],
        },
      })
      return
    }
    const css = source.includes('__url__')
      ? '.asset{background:url("./pixel.png")}'
      : '.compiled{--syntax:' + request.options.syntax + '}'
    const dependencies = request.options.syntax === 'css'
      ? [{
          kind: 'css-import',
          specifier: './theme.css',
          sourceUrl: pathToFileURL(request.sourcePath).href,
          start: 0,
          end: 10,
        }]
      : [{ kind: 'use', url: pathToFileURL(dependency).href }]
    respond({
      protocol: request.protocol,
      requestId: request.requestId,
      ok: true,
      result: {
        css,
        sourceMap: request.options.sourceMap ? JSON.stringify({
          version: 3,
          sources: [request.sourcePath],
          sourcesContent: [source],
          names: [],
          mappings: '',
        }) : null,
        diagnostics: source.includes('__warning__') ? [diagnostic] : [],
        dependencies,
      },
    })
  }
  if (source.includes('__slow__')) {
    fs.appendFileSync(log, 'start ' + request.requestId + '\\n')
    setTimeout(() => {
      fs.appendFileSync(log, 'end ' + request.requestId + '\\n')
      finish()
    }, 60)
  } else {
    finish()
  }
})
`
}

function stripQuery(value) {
  const boundary = value.search(/[?#]/)
  return boundary === -1 ? value : value.slice(0, boundary)
}

async function importHostPackage(name) {
  try {
    return await import(name)
  } catch (error) {
    if (error?.code !== 'ERR_MODULE_NOT_FOUND') throw error
    const docsRequire = createRequire(path.join(repositoryRoot, 'docs', 'package.json'))
    return import(pathToFileURL(docsRequire.resolve(name)).href)
  }
}

before(async () => {
  if (windowsSkip) return
  fixtureRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-adapters-')))
  workspace = path.join(fixtureRoot, 'workspace')
  fs.mkdirSync(workspace)
  fs.mkdirSync(path.join(fixtureRoot, 'bin'))
  fs.cpSync(path.join(repositoryRoot, 'adapters'), path.join(fixtureRoot, 'adapters'), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, 'api.cjs'), path.join(fixtureRoot, 'api.cjs'))
  const binary = path.join(fixtureRoot, 'bin', binaryName)
  fs.writeFileSync(binary, fakeBinarySource(), { mode: 0o755 })
  fs.chmodSync(binary, 0o755)
  for (const [name, source] of [
    ['entry.css', '@import "./theme.css"; .a { color: red; }'],
    ['entry.scss', '@use "dependency"; .a { color: red; }'],
    ['entry.sass', '.a\n  color: red\n'],
    ['entry.less', '.a { color: red; }'],
    ['entry.styl', '.a\n  color red\n'],
    ['entry.stylus', '.a\n  color red\n'],
    ['card.module.scss', '.card { color: red; }'],
    ['unicode-warning.scss', 'é🙂__warning__'],
    ['unicode-error.scss', 'é🙂__error__'],
    ['_dependency.scss', '$color: red;'],
    ['theme.css', '.theme { color: blue; }'],
  ]) fs.writeFileSync(path.join(workspace, name), source)

  core = require(path.join(fixtureRoot, 'adapters', 'core.cjs'))
  adapters = require(path.join(fixtureRoot, 'adapters', 'index.cjs'))
  vite = require(path.join(fixtureRoot, 'adapters', 'vite.cjs'))
  rollup = require(path.join(fixtureRoot, 'adapters', 'rollup.cjs'))
  esbuild = require(path.join(fixtureRoot, 'adapters', 'esbuild.cjs'))
  bun = require(path.join(fixtureRoot, 'adapters', 'bun.cjs'))
  webpackLoader = require(path.join(fixtureRoot, 'adapters', 'webpack.cjs'))
  rspackLoader = require(path.join(fixtureRoot, 'adapters', 'rspack.cjs'))
})

after(() => {
  if (fixtureRoot) fs.rmSync(fixtureRoot, { recursive: true, force: true })
})

function rollupContext(watchFiles = [], warnings = []) {
  return {
    async resolve(source, importer) {
      assert.equal(source, stripQuery(source), 'ZigCSS must resolve the clean physical path')
      return { id: path.resolve(importer ? path.dirname(importer) : workspace, source) }
    },
    addWatchFile(filename) {
      watchFiles.push(filename)
    },
    warn(warning) {
      warnings.push(warning)
    },
    error(error) {
      const failure = new Error(error.message)
      Object.assign(failure, error)
      throw failure
    },
  }
}

async function resolveAndLoad(plugin, source, importer = path.join(workspace, 'app.js')) {
  const watched = []
  const warnings = []
  const context = rollupContext(watched, warnings)
  const resolved = await plugin.resolveId.call(context, source, importer, {})
  assert.ok(resolved && typeof resolved === 'object')
  const loaded = await plugin.load.call(context, resolved.id)
  return { resolved, loaded, watched, warnings }
}

test('adapter package exposes matching frozen CJS and ESM factory surfaces', { skip: windowsSkip }, async () => {
  assert.deepEqual(Object.keys(adapters), [
    'createBunPlugin',
    'createEsbuildPlugin',
    'createRollupPlugin',
    'createVitePlugin',
    'ZigCssAdapterError',
  ])
  assert.equal(Object.isFrozen(adapters), true)
  const esm = await import(`${pathToFileURL(path.join(fixtureRoot, 'adapters', 'index.mjs')).href}?surface=1`)
  for (const name of Object.keys(adapters)) assert.equal(esm[name], adapters[name])
  assert.equal(esm.default, adapters)
  assert.equal(vite, adapters.createVitePlugin)
  assert.equal(rollup, adapters.createRollupPlugin)
  assert.equal(esbuild, adapters.createEsbuildPlugin)
  assert.equal(bun, adapters.createBunPlugin)
  assert.equal(webpackLoader, rspackLoader)
  assert.equal(webpackLoader.raw, true)
})

test('package self-reference resolves every public adapter subpath in CJS and ESM', async () => {
  const packaged = await import('zigcss/adapters')
  assert.equal(packaged.createVitePlugin, (await import('zigcss/vite')).default)
  assert.equal(packaged.createRollupPlugin, (await import('zigcss/rollup')).default)
  assert.equal(packaged.createEsbuildPlugin, (await import('zigcss/esbuild')).default)
  assert.equal(packaged.createBunPlugin, (await import('zigcss/bun')).default)
  assert.equal(require('zigcss/vite'), packaged.createVitePlugin)
  assert.equal(require('zigcss/rollup'), packaged.createRollupPlugin)
  assert.equal(require('zigcss/esbuild'), packaged.createEsbuildPlugin)
  assert.equal(require('zigcss/bun'), packaged.createBunPlugin)
  assert.equal(require('zigcss/webpack'), require('zigcss/rspack'))
  assert.equal((await import('zigcss/webpack')).default, require('zigcss/webpack'))
  assert.equal((await import('zigcss/rspack')).default, require('zigcss/rspack'))
})

test('adapter options are exact bounded and reject incompatible maps before host hooks', { skip: windowsSkip }, () => {
  assert.throws(() => vite({ unknown: true }), error => error.code === 'ADAPTER_OPTIONS')
  assert.throws(() => esbuild({ maxWorkers: 0 }), error => error.code === 'ADAPTER_OPTIONS')
  assert.throws(() => bun({ browsers: 'x'.repeat(4097) }), error => error.code === 'ADAPTER_OPTIONS')
  assert.throws(
    () => vite({ rootPaths: [workspace, path.join(workspace, '.')] }),
    error => error.code === 'ADAPTER_OPTIONS',
  )
  assert.throws(
    () => vite({ rootPaths: [path.join(workspace, 'missing')] }),
    error => error.code === 'ADAPTER_OPTIONS',
  )
  assert.throws(
    () => rollup({ optimize: true, sourceMap: true }),
    error => error.code === 'ADAPTER_OPTIONS',
  )
  const normalized = core.normalizeOptions({ optimize: true, maxWorkers: 2 })
  assert.equal(normalized.sourceMap, false)
  assert.equal(normalized.optimize, true)
  assert.equal(Object.isFrozen(normalized), true)
  assert.deepEqual(core.normalizeOptions({ rootPaths: [workspace] }).rootPaths, [fs.realpathSync(workspace)])
})

test('Vite and Rollup adapters resolve clean paths and restore exact query and fragment identity while isolating mutable host maps', { skip: windowsSkip }, async () => {
  for (const factory of [vite, rollup]) {
    const plugin = factory({ maxWorkers: 2 })
    const result = await resolveAndLoad(plugin, './card.module.scss?inline#theme')
    const cleanGenerated = stripQuery(result.resolved.id)
    assert.equal(path.dirname(cleanGenerated), workspace)
    assert.match(path.basename(cleanGenerated), /^\0zigcss-[0-9a-f]{64}\.module\.css$/)
    assert.equal(result.resolved.id.endsWith('?inline#theme'), true)
    assert.equal(result.resolved.moduleSideEffects, true)
    assert.equal(result.loaded.code, '.compiled{--syntax:scss}')
    assert.equal(result.loaded.map.version, 3)
    assert.equal(Object.isFrozen(result.loaded.map), false)
    assert.equal(Object.isFrozen(result.loaded.map.sources), false)
    assert.equal(Object.isFrozen(result.loaded.map.names), false)
    assert.equal(result.loaded.moduleSideEffects, true)
    assert.deepEqual(result.watched, [
      fs.realpathSync(path.join(workspace, 'card.module.scss')),
      fs.realpathSync(path.join(workspace, '_dependency.scss')),
    ])
    const originalSource = result.loaded.map.sources[0]
    result.loaded.map.sources[0] = 'host-mutated.scss'
    result.loaded.map.names.push('host-mutated')
    const repeated = await resolveAndLoad(plugin, './card.module.scss?inline#theme')
    assert.equal(repeated.loaded.map.sources[0], originalSource)
    assert.deepEqual(repeated.loaded.map.names, [])
  }
})

test('Rollup-style and esbuild diagnostics preserve their host-specific Unicode columns', {
  skip: windowsSkip,
}, async () => {
  for (const factory of [vite, rollup]) {
    const warning = await resolveAndLoad(factory({ sourceMap: false }), './unicode-warning.scss')
    assert.equal(warning.warnings.length, 1)
    assert.equal(warning.warnings[0].loc.line, 1)
    assert.equal(warning.warnings[0].loc.column, 3)

    await assert.rejects(
      resolveAndLoad(factory({ sourceMap: false }), './unicode-error.scss'),
      error => error.loc?.line === 1 && error.loc?.column === 3,
    )
  }

  let onLoad
  esbuild({ sourceMap: false }).setup({
    onLoad(_options, callback) {
      onLoad = callback
    },
  })
  const warning = await onLoad({
    path: path.join(workspace, 'unicode-warning.scss'),
    namespace: 'file',
  })
  assert.equal(warning.warnings[0].location.line, 1)
  assert.equal(warning.warnings[0].location.column, 6)
  assert.equal(warning.warnings[0].location.lineText, 'é🙂__warning__')

  const failure = await onLoad({
    path: path.join(workspace, 'unicode-error.scss'),
    namespace: 'file',
  })
  assert.equal(failure.errors[0].location.line, 1)
  assert.equal(failure.errors[0].location.column, 6)
  assert.equal(failure.errors[0].location.lineText, 'é🙂__error__')
})

test('diagnostic locations reject unsafe files without exposing partial source text', {
  skip: windowsSkip,
}, async t => {
  let onLoad
  esbuild({ sourceMap: false }).setup({
    onLoad(_options, callback) {
      onLoad = callback
    },
  })

  const entry = path.join(workspace, 'diagnostic-safety.scss')
  const locationFor = async target => {
    fs.writeFileSync(entry, `__diagnostic_source__=${target}\n__warning__`)
    const result = await onLoad({ path: entry, namespace: 'file' })
    assert.equal(result.errors, undefined)
    assert.equal(result.warnings.length, 1)
    assert.equal(result.warnings[0].text, '[ADAPTER_NOTE] fixture warning')
    return result.warnings[0].location
  }

  const oversized = path.join(workspace, 'diagnostic-oversized.scss')
  fs.writeFileSync(oversized, Buffer.alloc((10 * 1024 * 1024) + 1, 0x61))
  assert.equal(await locationFor(oversized), null)

  const invalidUtf8 = path.join(workspace, 'diagnostic-invalid-utf8.scss')
  fs.writeFileSync(invalidUtf8, Buffer.from([0xc3, 0x28]))
  assert.equal(await locationFor(invalidUtf8), null)

  const outside = path.join(fixtureRoot, 'diagnostic-outside.scss')
  const linkedOutside = path.join(workspace, 'diagnostic-linked-outside.scss')
  fs.writeFileSync(outside, 'outside secret must not become a diagnostic line')
  fs.symlinkSync(outside, linkedOutside)
  assert.equal(await locationFor(linkedOutside), null)

  const directory = path.join(workspace, 'diagnostic-directory.scss')
  fs.mkdirSync(directory)
  assert.equal(await locationFor(directory), null)

  const fifo = path.join(workspace, 'diagnostic-fifo.scss')
  const mkfifo = spawnSync('mkfifo', [fifo], { encoding: 'utf8', timeout: 5_000 })
  if (mkfifo.status === 0) {
    assert.equal(await locationFor(fifo), null)
  } else {
    t.diagnostic('mkfifo is unavailable; the portable non-regular directory branch remains covered')
  }

  const raced = path.join(workspace, 'diagnostic-raced.scss')
  const replacement = path.join(workspace, 'diagnostic-replacement.scss')
  const displaced = path.join(workspace, 'diagnostic-displaced.scss')
  fs.writeFileSync(raced, 'original diagnostic line')
  fs.writeFileSync(replacement, 'replacement diagnostic line')
  const originalOpenSync = fs.openSync
  let swapped = false
  fs.openSync = function hardenedDiagnosticRace(filename, ...args) {
    const descriptor = originalOpenSync.call(this, filename, ...args)
    if (!swapped && filename === raced) {
      swapped = true
      fs.renameSync(raced, displaced)
      fs.renameSync(replacement, raced)
    }
    return descriptor
  }
  try {
    assert.equal(await locationFor(raced), null)
    assert.equal(swapped, true)
  } finally {
    fs.openSync = originalOpenSync
  }
})

test('CSS authored imports stay with the downstream CSS layer instead of becoming guessed watch paths', { skip: windowsSkip }, async () => {
  const result = await resolveAndLoad(vite(), './entry.css')
  assert.deepEqual(result.watched, [fs.realpathSync(path.join(workspace, 'entry.css'))])
  assert.equal(result.loaded.code, '.compiled{--syntax:css}')
})

test('Rollup-style resolution ignores remote virtual and unsupported inputs', { skip: windowsSkip }, async () => {
  const plugin = rollup()
  const context = rollupContext()
  for (const source of ['https://example.com/a.scss', '\0foreign.scss', './entry.txt']) {
    assert.equal(await plugin.resolveId.call(context, source, path.join(workspace, 'app.js'), {}), null)
  }
})

test('esbuild adapter returns CSS loaders inline maps watch files warnings and structured failures', { skip: windowsSkip }, async () => {
  let onLoad
  esbuild({ maxWorkers: 2 }).setup({
    onLoad(options, callback) {
      assert.equal(options.namespace, 'file')
      assert.equal(options.filter.test('entry.scss'), true)
      onLoad = callback
    },
  })
  const source = path.join(workspace, 'entry.scss')
  fs.writeFileSync(source, '__warning__')
  const success = await onLoad({ path: source, namespace: 'file' })
  assert.equal(success.loader, 'css')
  assert.equal(success.resolveDir, workspace)
  assert.match(success.contents, /sourceMappingURL=data:application\/json/)
  assert.deepEqual(success.watchFiles, [source, path.join(workspace, '_dependency.scss')])
  assert.equal(success.warnings.length, 1)
  assert.equal(success.warnings[0].text, '[ADAPTER_NOTE] fixture warning')

  const moduleResult = await onLoad({ path: path.join(workspace, 'card.module.scss'), namespace: 'file' })
  assert.equal(moduleResult.loader, 'local-css')
  fs.writeFileSync(source, '__error__')
  const failure = await onLoad({ path: source, namespace: 'file' })
  assert.equal(failure.errors.length, 1)
  assert.equal(failure.errors[0].text, '[ADAPTER_ERROR] fixture warning')
  assert.equal(failure.errors[0].location.line, 1)
})

test('Bun adapter registers the closed file loader without leaking host-specific fields', { skip: windowsSkip }, async () => {
  let onLoad
  bun({ sourceMap: false }).setup({
    onLoad(options, callback) {
      assert.equal(options.namespace, 'file')
      onLoad = callback
    },
  })
  fs.writeFileSync(path.join(workspace, 'entry.less'), '.a { color: red; }')
  const result = await onLoad({ path: path.join(workspace, 'entry.less'), namespace: 'file' })
  assert.deepEqual(Object.keys(result), ['contents', 'loader'])
  assert.equal(result.loader, 'css')
  assert.equal(result.contents, '.compiled{--syntax:less}')
})

function runLoader(loader, source, options = {}, incomingMap = null) {
  return new Promise(resolve => {
    const dependencies = []
    const warnings = []
    const context = {
      resourcePath: path.join(workspace, 'entry.scss'),
      sourceMap: true,
      getOptions: () => options,
      cacheable(value) {
        assert.equal(value, true)
      },
      addDependency(filename) {
        dependencies.push(filename)
      },
      emitWarning(warning) {
        warnings.push(warning)
      },
      async() {
        return (error, code, map, meta) => resolve({ error, code, map, meta, dependencies, warnings })
      },
    }
    loader.call(context, Buffer.from(source), incomingMap)
  })
}

function runHostCompiler(createCompiler, configuration) {
  return new Promise((resolve, reject) => {
    let compiler
    try {
      compiler = createCompiler(configuration)
    } catch (error) {
      reject(error)
      return
    }
    compiler.run((error, stats) => {
      const finish = completion => {
        if (typeof compiler.close === 'function') {
          compiler.close(closeError => completion(closeError))
        } else {
          completion(null)
        }
      }
      if (error || !stats) {
        finish(closeError => reject(error ?? closeError ?? new Error('builder returned no stats')))
        return
      }
      const details = stats.toJson({ all: false, assets: true, errors: true, warnings: true })
      const dependencies = [...stats.compilation.fileDependencies]
      finish(closeError => {
        if (closeError) reject(closeError)
        else resolve({ details, dependencies })
      })
    })
  })
}

test('Webpack and Rspack share one async raw loader with maps dependency invalidation and metadata through mutable host maps', { skip: windowsSkip }, async () => {
  for (const loader of [webpackLoader, rspackLoader]) {
    const result = await runLoader(loader, '__warning__', { maxWorkers: 2 })
    assert.equal(result.error, null)
    assert.equal(result.code, '.compiled{--syntax:scss}')
    assert.equal(result.map.version, 3)
    assert.equal(Object.isFrozen(result.map), false)
    assert.equal(Object.isFrozen(result.map.sources), false)
    assert.equal(Object.isFrozen(result.map.names), false)
    assert.deepEqual(result.dependencies, [path.join(workspace, '_dependency.scss')])
    assert.equal(result.warnings.length, 1)
    assert.equal(result.meta.zigcss.dependencies[0].kind, 'use')
    const originalSource = result.map.sources[0]
    result.map.sources[0] = 'host-mutated.scss'
    result.map.names.push('host-mutated')
    const repeated = await runLoader(loader, '__warning__', { maxWorkers: 2 })
    assert.equal(repeated.map.sources[0], originalSource)
    assert.deepEqual(repeated.map.names, [])
  }
})

test('Webpack-style loader rejects incoming maps and compilation failures without partial CSS', { skip: windowsSkip }, async () => {
  const incoming = await runLoader(webpackLoader, '.a{}', {}, { version: 3, mappings: '' })
  assert.equal(incoming.error.code, 'ADAPTER_INPUT_MAP')
  assert.equal(incoming.code, undefined)
  const failed = await runLoader(webpackLoader, '__error__')
  assert.equal(failed.error.name, 'ZigCssLoaderError')
  assert.equal(failed.error.code, 'ADAPTER_COMPILE')
  assert.equal(failed.code, undefined)
})

test('real Webpack and Rspack execute the shared raw loader and register native dependencies', {
  skip: windowsSkip,
}, async () => {
  const webpack = require('webpack')
  const rspackModule = require('@rspack/core')
  const entry = path.join(workspace, 'loader-host-entry.js')
  const stylesheet = path.join(workspace, 'loader-host-entry.scss')
  fs.writeFileSync(entry, 'import css from "./loader-host-entry.scss"; console.log(css);')
  fs.writeFileSync(stylesheet, '__warning__')

  for (const [name, createCompiler, loader] of [
    ['webpack', webpack, path.join(fixtureRoot, 'adapters', 'webpack.cjs')],
    ['rspack', rspackModule.rspack ?? rspackModule, path.join(fixtureRoot, 'adapters', 'rspack.cjs')],
  ]) {
    const outputPath = path.join(workspace, `${name}-out`)
    const result = await runHostCompiler(createCompiler, {
      context: workspace,
      mode: 'development',
      devtool: 'source-map',
      cache: false,
      entry,
      output: { path: outputPath, filename: 'bundle.js' },
      module: {
        rules: [{
          test: /\.scss$/,
          type: 'asset/source',
          use: [{ loader, options: { sourceMap: true, maxWorkers: 2 } }],
        }],
      },
      infrastructureLogging: { level: 'none' },
    })
    assert.deepEqual(result.details.errors, [])
    assert.equal(JSON.stringify(result.details.warnings).includes('[ADAPTER_NOTE] fixture warning'), true)
    assert.ok(result.dependencies.includes(fs.realpathSync(path.join(workspace, '_dependency.scss'))))
    assert.match(fs.readFileSync(path.join(outputPath, 'bundle.js'), 'utf8'), /\.compiled\{--syntax:scss\}/)
  }
})

test('shared scheduler caps concurrent native processes without caching build results', { skip: windowsSkip }, async () => {
  const log = path.join(fixtureRoot, 'spawn.log')
  fs.rmSync(log, { force: true })
  const scheduler = core.createScheduler(2)
  const options = core.normalizeOptions({ sourceMap: false, maxWorkers: 2 })
  await Promise.all(Array.from({ length: 6 }, (_, index) => core.compileSourceAsset(
    `__slow__${index}`,
    path.join(workspace, `slow-${index}.scss`),
    options,
    scheduler,
  )))
  const events = fs.readFileSync(log, 'utf8').trim().split('\n')
  let active = 0
  let maximum = 0
  for (const event of events) {
    if (event.startsWith('start ')) active += 1
    else if (event.startsWith('end ')) active -= 1
    maximum = Math.max(maximum, active)
    assert.ok(active >= 0)
  }
  assert.equal(active, 0)
  assert.equal(maximum, 2)
  assert.equal(events.filter(event => event.startsWith('start ')).length, 6)
})

test('real esbuild bundles generated CSS assets and CSS Modules', { skip: windowsSkip }, async () => {
  const { build } = await importHostPackage('esbuild')
  const entry = path.join(workspace, 'esbuild-entry.js')
  fs.writeFileSync(path.join(workspace, 'asset.scss'), '__url__')
  fs.writeFileSync(path.join(workspace, 'pixel.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47]))
  fs.writeFileSync(entry, [
    'import styles from "./card.module.scss"',
    'import "./asset.scss"',
    'console.log(styles.compiled)',
  ].join('\n'))

  const result = await build({
    entryPoints: [entry],
    bundle: true,
    format: 'esm',
    outdir: path.join(workspace, 'esbuild-out'),
    write: false,
    metafile: true,
    assetNames: 'assets/[name]-[hash]',
    loader: { '.png': 'file' },
    plugins: [esbuild({ sourceMap: false })],
    logLevel: 'silent',
  })

  const css = result.outputFiles.find(file => file.path.endsWith('.css'))
  const image = result.outputFiles.find(file => file.path.endsWith('.png'))
  assert.ok(css)
  assert.ok(image)
  assert.match(css.text, /background:\s*url\(["']?\.\/assets\/pixel-[A-Z0-9]+\.png["']?\)/)
  assert.match(css.text, /\.card_module_compiled|\.compiled/)
  assert.ok(Object.keys(result.metafile.inputs).some(filename => filename.endsWith('card.module.scss')))
  assert.ok(Object.keys(result.metafile.inputs).some(filename => filename.endsWith('asset.scss')))
})

test('real Rollup resolves queried styles through ZigCSS before a downstream CSS consumer', { skip: windowsSkip }, async () => {
  const { rollup: createBundle } = await importHostPackage('rollup')
  const entry = path.join(workspace, 'rollup-entry.js')
  const stylesheet = path.join(workspace, 'rollup-entry.scss')
  fs.writeFileSync(entry, 'import css from "./rollup-entry.scss?inline#asset"; export default css;')
  fs.writeFileSync(stylesheet, '__warning__')
  const consumed = []
  const warnings = []
  const cssConsumer = {
    name: 'test-css-consumer',
    transform(code, id) {
      const clean = stripQuery(id)
      if (!clean.includes('\0zigcss-') || !clean.endsWith('.css')) return null
      consumed.push({ code, id })
      return { code: `export default ${JSON.stringify(code)};`, map: null }
    },
  }

  const bundle = await createBundle({
    input: entry,
    plugins: [rollup({ sourceMap: true }), cssConsumer],
    onwarn(warning) {
      warnings.push(warning)
    },
  })
  try {
    const generated = await bundle.generate({ format: 'es', sourcemap: true })
    assert.equal(consumed.length, 1)
    assert.equal(consumed[0].code, '.compiled{--syntax:scss}')
    assert.equal(consumed[0].id.endsWith('?inline#asset'), true)
    assert.match(generated.output[0].code, /\.compiled\{--syntax:scss\}/)
    assert.ok(generated.output[0].map)
    assert.ok(bundle.watchFiles.includes(fs.realpathSync(stylesheet)))
    assert.ok(bundle.watchFiles.includes(fs.realpathSync(path.join(workspace, '_dependency.scss'))))
    assert.equal(warnings.some(warning => warning.message.includes('[ADAPTER_NOTE] fixture warning')), true)
  } finally {
    await bundle.close()
  }
})

test('real Vite builds generated sibling CSS with rebased assets', { skip: windowsSkip }, async () => {
  const { build } = await importHostPackage('vite')
  const entry = path.join(workspace, 'vite-entry.js')
  fs.writeFileSync(entry, 'import "./vite-entry.scss";')
  fs.writeFileSync(path.join(workspace, 'vite-entry.scss'), '__url__')
  fs.writeFileSync(path.join(workspace, 'pixel.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47]))

  const result = await build({
    root: workspace,
    configFile: false,
    logLevel: 'silent',
    plugins: [vite({ sourceMap: true })],
    build: {
      write: false,
      assetsInlineLimit: 0,
      sourcemap: true,
      rollupOptions: { input: entry },
    },
  })
  assert.equal(Array.isArray(result), false)
  const css = result.output.find(output => output.type === 'asset' && output.fileName.endsWith('.css'))
  const image = result.output.find(output => output.type === 'asset' && output.fileName.endsWith('.png'))
  assert.ok(css)
  assert.ok(image)
  assert.match(String(css.source), /background:url\(\/assets\/pixel-[A-Za-z0-9_-]+\.png\)/)
})

test('real Bun smoke runs when the Bun host is available', { skip: windowsSkip }, t => {
  const probe = spawnSync('bun', ['--version'], { encoding: 'utf8' })
  if (probe.error?.code === 'ENOENT') {
    t.skip('Bun is not installed on this host; the host-independent Bun contract remains covered')
    return
  }
  assert.equal(probe.status, 0, probe.stderr)

  const entry = path.join(workspace, 'bun-entry.js')
  const stylesheet = path.join(workspace, 'bun-entry.scss')
  const outputDirectory = path.join(workspace, 'bun-out')
  const runner = path.join(workspace, 'bun-runner.mjs')
  fs.writeFileSync(entry, 'import "./bun-entry.scss";')
  fs.writeFileSync(stylesheet, '.entry { color: red; }')
  fs.writeFileSync(runner, [
    `import zigcss from ${JSON.stringify(pathToFileURL(path.join(fixtureRoot, 'adapters', 'bun.mjs')).href)}`,
    `const result = await Bun.build({ entrypoints: [${JSON.stringify(entry)}], outdir: ${JSON.stringify(outputDirectory)}, plugins: [zigcss({ sourceMap: false })] })`,
    'if (!result.success) { console.error(result.logs); process.exit(1) }',
    'console.log(JSON.stringify(result.outputs.map(output => output.path)))',
  ].join('\n'))

  const run = spawnSync('bun', [runner], { encoding: 'utf8', timeout: 30_000 })
  assert.equal(run.status, 0, run.stderr || run.stdout)
  const outputs = JSON.parse(run.stdout.trim())
  const cssPath = outputs.find(filename => filename.endsWith('.css'))
  assert.ok(cssPath)
  assert.match(fs.readFileSync(cssPath, 'utf8'), /\.compiled\s*\{\s*--syntax:\s*scss/)
})

function nativeCss(source, label) {
  assert.match(source, /(?:rebeccapurple|#639)/i, `${label} did not emit current native ZigCSS output`)
}

function createNativeAdapterFixture(binary) {
  assert.equal(path.isAbsolute(binary), true, 'ZIGCSS_ADAPTER_NATIVE_BINARY must be absolute')
  const sourceStat = fs.lstatSync(binary)
  assert.equal(sourceStat.isFile(), true, 'current native ZigCSS binary must be a regular file')
  assert.equal(sourceStat.isSymbolicLink(), false, 'current native ZigCSS binary cannot be a symlink')
  if (process.platform !== 'win32') {
    assert.notEqual(sourceStat.mode & 0o111, 0, 'current native ZigCSS binary must be executable')
  }
  const version = spawnSync(binary, ['--version'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  assert.equal(version.error, undefined, version.error?.message)
  assert.equal(version.signal, null)
  assert.equal(version.status, 0, version.stderr || version.stdout)
  assert.match(version.stdout, /^zigcss \d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\n$/)
  assert.equal(version.stderr, '')

  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-native-adapters-')))
  const nativeWorkspace = path.join(root, 'workspace')
  fs.mkdirSync(nativeWorkspace)
  fs.mkdirSync(path.join(root, 'bin'))
  fs.cpSync(path.join(repositoryRoot, 'adapters'), path.join(root, 'adapters'), {
    errorOnExist: true,
    force: false,
    recursive: true,
  })
  fs.copyFileSync(path.join(repositoryRoot, 'api.cjs'), path.join(root, 'api.cjs'), fs.constants.COPYFILE_EXCL)
  const installedBinary = path.join(root, 'bin', binaryName)
  fs.copyFileSync(binary, installedBinary, fs.constants.COPYFILE_EXCL)
  if (process.platform !== 'win32') fs.chmodSync(installedBinary, 0o755)
  fs.writeFileSync(path.join(nativeWorkspace, '_tokens.scss'), '$accent: rebeccapurple;\n')
  const nativeRequire = createRequire(path.join(root, 'package.json'))
  return Object.freeze({
    root,
    workspace: nativeWorkspace,
    bun: nativeRequire(path.join(root, 'adapters', 'bun.cjs')),
    esbuild: nativeRequire(path.join(root, 'adapters', 'esbuild.cjs')),
    rollup: nativeRequire(path.join(root, 'adapters', 'rollup.cjs')),
    rspackLoader: path.join(root, 'adapters', 'rspack.cjs'),
    vite: nativeRequire(path.join(root, 'adapters', 'vite.cjs')),
    webpackLoader: path.join(root, 'adapters', 'webpack.cjs'),
  })
}

function nativeStylesheet(nativeWorkspace, name) {
  const filename = path.join(nativeWorkspace, `${name}.scss`)
  fs.writeFileSync(filename, '@use "tokens";\n.native { color: tokens.$accent; }\n')
  return filename
}

test('current native ZigCSS completes real Vite Rollup esbuild Webpack Rspack and available Bun builds', {
  skip: configuredNativeBinary === null
    ? 'ZIGCSS_ADAPTER_NATIVE_BINARY is not configured; CI supplies the freshly built binary'
    : windowsSkip,
}, async t => {
  const fixture = createNativeAdapterFixture(configuredNativeBinary)
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }))

  const esbuildEntry = path.join(fixture.workspace, 'native-esbuild-entry.js')
  nativeStylesheet(fixture.workspace, 'native-esbuild')
  fs.writeFileSync(esbuildEntry, 'import "./native-esbuild.scss";')
  const { build: esbuildBuild } = await importHostPackage('esbuild')
  const esbuildResult = await esbuildBuild({
    entryPoints: [esbuildEntry],
    bundle: true,
    outdir: path.join(fixture.workspace, 'native-esbuild-out'),
    write: false,
    plugins: [fixture.esbuild({ sourceMap: false })],
    logLevel: 'silent',
  })
  const esbuildCss = esbuildResult.outputFiles.find(file => file.path.endsWith('.css'))
  assert.ok(esbuildCss)
  nativeCss(esbuildCss.text, 'esbuild')

  const rollupEntry = path.join(fixture.workspace, 'native-rollup-entry.js')
  const rollupStyle = nativeStylesheet(fixture.workspace, 'native-rollup')
  fs.writeFileSync(rollupEntry, 'import css from "./native-rollup.scss"; export default css;')
  const { rollup: createRollupBundle } = await importHostPackage('rollup')
  const rollupConsumer = {
    name: 'native-zigcss-css-consumer',
    transform(code, id) {
      const clean = stripQuery(id)
      if (!clean.includes('\0zigcss-') || !clean.endsWith('.css')) return null
      return { code: `export default ${JSON.stringify(code)};`, map: null }
    },
  }
  const rollupBundle = await createRollupBundle({
    input: rollupEntry,
    plugins: [fixture.rollup({ sourceMap: true }), rollupConsumer],
  })
  try {
    const generated = await rollupBundle.generate({ format: 'es', sourcemap: true })
    nativeCss(generated.output[0].code, 'Rollup')
    assert.ok(generated.output[0].map)
    assert.ok(rollupBundle.watchFiles.includes(fs.realpathSync(rollupStyle)))
    assert.ok(rollupBundle.watchFiles.includes(fs.realpathSync(path.join(fixture.workspace, '_tokens.scss'))))
  } finally {
    await rollupBundle.close()
  }

  const viteEntry = path.join(fixture.workspace, 'native-vite-entry.js')
  nativeStylesheet(fixture.workspace, 'native-vite')
  fs.writeFileSync(viteEntry, 'import "./native-vite.scss";')
  const { build: viteBuild } = await importHostPackage('vite')
  const viteResult = await viteBuild({
    root: fixture.workspace,
    configFile: false,
    logLevel: 'silent',
    plugins: [fixture.vite({ sourceMap: true })],
    build: {
      write: false,
      sourcemap: true,
      rollupOptions: { input: viteEntry },
    },
  })
  assert.equal(Array.isArray(viteResult), false)
  const viteCss = viteResult.output.find(output => output.type === 'asset' && output.fileName.endsWith('.css'))
  assert.ok(viteCss)
  nativeCss(String(viteCss.source), 'Vite')

  const webpack = require('webpack')
  const rspackModule = require('@rspack/core')
  for (const [name, createCompiler, loader] of [
    ['webpack', webpack, fixture.webpackLoader],
    ['rspack', rspackModule.rspack ?? rspackModule, fixture.rspackLoader],
  ]) {
    const entry = path.join(fixture.workspace, `native-${name}-entry.js`)
    const stylesheet = nativeStylesheet(fixture.workspace, `native-${name}`)
    fs.writeFileSync(entry, `import css from "./${path.basename(stylesheet)}"; console.log(css);`)
    const outputPath = path.join(fixture.workspace, `native-${name}-out`)
    const result = await runHostCompiler(createCompiler, {
      context: fixture.workspace,
      mode: 'development',
      devtool: false,
      cache: false,
      entry,
      output: { path: outputPath, filename: 'bundle.js' },
      module: {
        rules: [{
          test: /\.scss$/,
          type: 'asset/source',
          use: [{ loader, options: { sourceMap: false, maxWorkers: 2 } }],
        }],
      },
      infrastructureLogging: { level: 'none' },
    })
    assert.deepEqual(result.details.errors, [])
    nativeCss(fs.readFileSync(path.join(outputPath, 'bundle.js'), 'utf8'), name)
    assert.ok(result.dependencies.includes(fs.realpathSync(path.join(fixture.workspace, '_tokens.scss'))))
  }

  const bunProbe = spawnSync('bun', ['--version'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  if (bunProbe.error?.code === 'ENOENT') {
    t.diagnostic('Bun is not installed on this host; the pinned CI host runs this native branch')
    return
  }
  assert.equal(bunProbe.error, undefined, bunProbe.error?.message)
  assert.equal(bunProbe.status, 0, bunProbe.stderr)
  const bunEntry = path.join(fixture.workspace, 'native-bun-entry.js')
  nativeStylesheet(fixture.workspace, 'native-bun')
  fs.writeFileSync(bunEntry, 'import "./native-bun.scss";')
  const bunOutput = path.join(fixture.workspace, 'native-bun-out')
  const bunRunner = path.join(fixture.workspace, 'native-bun-runner.mjs')
  fs.writeFileSync(bunRunner, [
    `import zigcss from ${JSON.stringify(pathToFileURL(path.join(fixture.root, 'adapters', 'bun.mjs')).href)}`,
    `const result = await Bun.build({ entrypoints: [${JSON.stringify(bunEntry)}], outdir: ${JSON.stringify(bunOutput)}, plugins: [zigcss({ sourceMap: false })] })`,
    'if (!result.success) { console.error(result.logs); process.exit(1) }',
    'console.log(JSON.stringify(result.outputs.map(output => output.path)))',
  ].join('\n'))
  const bunRun = spawnSync('bun', [bunRunner], {
    encoding: 'utf8',
    maxBuffer: 2 * 1024 * 1024,
    timeout: 30_000,
    windowsHide: true,
  })
  assert.equal(bunRun.error, undefined, bunRun.error?.message)
  assert.equal(bunRun.status, 0, bunRun.stderr || bunRun.stdout)
  const bunFiles = JSON.parse(bunRun.stdout.trim())
  const bunCss = bunFiles.find(filename => filename.endsWith('.css'))
  assert.ok(bunCss)
  nativeCss(fs.readFileSync(bunCss, 'utf8'), 'Bun')
})
