import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const exampleRoot = path.join(repositoryRoot, 'examples', 'next-turbopack')
const preload = path.join(repositoryRoot, 'scripts', 'turbopack-offline-preload.cjs')
const require = createRequire(import.meta.url)
const expectedFiles = Object.freeze([
  'README.md',
  'app/_tokens.scss',
  'app/layout.js',
  'app/page.js',
  'app/styles.scss',
  'next.config.js',
  'package-lock.json',
  'package.json',
])
const expectedHostVersions = Object.freeze({
  next: '16.3.4',
  react: '19.2.4',
  'react-dom': '19.2.4',
  sass: '1.101.0',
})
const expectedScripts = Object.freeze({
  build: 'next build --turbopack',
  'build:webpack': 'next build --webpack',
})
const initialEntry = '@use "tokens";\n\n.zigcss-current-native {\n  color: tokens.$accent;\n}\n'
const initialDependency = '$accent: rebeccapurple;\n'
const changedDependency = '$accent: chartreuse;\n'

function readJson(filename) {
  return JSON.parse(fs.readFileSync(filename, 'utf8'))
}

const activePackageVersion = readJson(path.join(repositoryRoot, 'package.json')).version

function collectRegularFiles(root, directory = root) {
  const files = []
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name)
    assert.equal(entry.isSymbolicLink(), false, `example entry must not be a symlink: ${absolute}`)
    if (entry.isDirectory()) files.push(...collectRegularFiles(root, absolute))
    else {
      assert.equal(entry.isFile(), true, `example entry must be a regular file: ${absolute}`)
      files.push(path.relative(root, absolute).split(path.sep).join('/'))
    }
  }
  return files.sort()
}

function loadExampleContract() {
  delete require.cache[require.resolve(path.join(exampleRoot, 'next.config.js'))]
  return {
    files: collectRegularFiles(exampleRoot),
    rootManifest: readJson(path.join(repositoryRoot, 'package.json')),
    rootLock: readJson(path.join(repositoryRoot, 'package-lock.json')),
    manifest: readJson(path.join(exampleRoot, 'package.json')),
    lock: readJson(path.join(exampleRoot, 'package-lock.json')),
    config: require(path.join(exampleRoot, 'next.config.js')),
    readme: fs.readFileSync(path.join(exampleRoot, 'README.md'), 'utf8'),
    entry: fs.readFileSync(path.join(exampleRoot, 'app', 'styles.scss'), 'utf8'),
    dependency: fs.readFileSync(path.join(exampleRoot, 'app', '_tokens.scss'), 'utf8'),
    preload: fs.readFileSync(preload, 'utf8'),
  }
}

export function validateExampleContract(contract) {
  assert.deepEqual(contract.files, [...expectedFiles])
  assert.equal(contract.manifest.name, 'zigcss-next-turbopack-example')
  assert.equal(contract.manifest.private, true)
  assert.deepEqual(contract.manifest.scripts, expectedScripts)
  assert.deepEqual(contract.manifest.devDependencies, expectedHostVersions)
  assert.equal(Object.hasOwn(contract.manifest, 'dependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'peerDependencies'), false)

  assert.equal(contract.lock.lockfileVersion, 3)
  assert.deepEqual(contract.lock.packages[''].devDependencies, expectedHostVersions)
  for (const [name, version] of Object.entries(expectedHostVersions)) {
    const locked = contract.lock.packages[`node_modules/${name}`]
    assert.equal(locked.version, version)
    assert.equal(locked.dev, true)
    assert.equal(contract.rootManifest.devDependencies[name], version)
    assert.equal(contract.rootLock.packages[`node_modules/${name}`].version, version)
    assert.equal(contract.rootLock.packages[`node_modules/${name}`].dev, true)
  }
  for (const [location, locked] of Object.entries(contract.lock.packages)) {
    if (location !== '') assert.equal(locked.dev, true, `${location} must remain development-only`)
  }
  assert.deepEqual(contract.rootManifest.dependencies, {})
  assert.equal(Object.hasOwn(contract.rootManifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './turbopack'), false)

  assert.equal(contract.config.productionBrowserSourceMaps, true)
  assert.deepEqual(contract.config.experimental, {
    turbopackFileSystemCacheForBuild: true,
    turbopackUseBuiltinSass: false,
  })
  assert.equal(contract.config.turbopack.root, exampleRoot)
  assert.deepEqual(Object.keys(contract.config.turbopack.rules), ['*.scss'])
  assert.deepEqual(contract.config.turbopack.rules['*.scss'], {
    condition: { path: /(?:^|[\\/])app[\\/]styles\.scss$/ },
    loaders: [{
      loader: 'zigcss/webpack',
      options: { maxWorkers: 2, sourceMap: true },
    }],
    type: 'css',
  })
  assert.doesNotMatch(JSON.stringify(contract.config), /postcss|css-module|\.module\.|\.less|\.styl(?:us)?/i)

  assert.equal(contract.entry, initialEntry)
  assert.equal(contract.dependency, initialDependency)
  assert.match(contract.readme, /source-checkout example reuses the existing `zigcss\/webpack` raw loader/)
  assert.match(contract.readme, /Next\.js added configurable loader output\s+module types in 16\.2/)
  assert.match(contract.readme, /pinned to Next\.js 16\.3\.4 with\s+React and ReactDOM 19\.2\.4/)
  assert.match(contract.readme, /published `zigcss@0\.6\.0` binary predates the current `zigcss-node-v1` protocol/)
  assert.match(contract.readme, /exact root lock with Node 22\.22\.0/)
  assert.match(contract.readme, /zig build -Doptimize=ReleaseFast/)
  assert.match(contract.readme, /npm ci --ignore-scripts/)
  assert.match(contract.readme, /npm install --ignore-scripts --no-save --install-links=false \.\.\/\.\./)
  assert.match(contract.readme, /ZIGCSS_TURBOPACK_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:turbopack-example/)
  assert.match(contract.readme, /does not claim CSS Modules, Sass-indented, Less, Stylus, arbitrary\s+SCSS entry globs, a `zigcss\/turbopack` export, a general Turbopack plugin, or\s+framework support beyond the pinned Next\.js host gate/)
  assert.match(contract.readme, /nextjs\.org\/docs\/app\/api-reference\/config\/next-config-js\/turbopack#module-types/)
  for (const anchor of [
    "ZIGCSS_TURBOPACK_OFFLINE !== '1'",
    'captureAllowedBinary(process.env.ZIGCSS_TURBOPACK_ALLOWED_BINARY)',
    "immutable(workerThreads, 'Worker'",
    "immutable(cluster, 'fork'",
    "immutable(process, '_linkedBinding'",
    "immutable(net.Server.prototype, '_listen2'",
    "immutable(dgram, 'Socket'",
    'for (const name of Object.keys(dns))',
    "Object.defineProperty(globalThis, 'fetch'",
    "record('runtime-start')",
    "record('runtime-summary')",
  ]) assert.match(contract.preload, new RegExp(anchor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  return true
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: options.timeout ?? 120_000,
    windowsHide: true,
  })
  if (result.error !== undefined) {
    throw new Error(`${command} failed to start: ${result.error.message}`)
  }
  return result
}

function requireSuccess(result, label) {
  assert.equal(result.signal, null, `${label} terminated by ${result.signal}`)
  assert.equal(result.status, 0, [label, result.stdout, result.stderr].filter(Boolean).join('\n'))
}

function validateNativeBinary(input) {
  assert.equal(path.isAbsolute(input), true, 'ZIGCSS_TURBOPACK_NATIVE_BINARY must be absolute')
  assert.equal(path.resolve(input), input, 'ZIGCSS_TURBOPACK_NATIVE_BINARY must be normalized')
  const stat = fs.lstatSync(input)
  assert.equal(stat.isFile(), true, 'Turbopack native binary must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'Turbopack native binary must not be a symlink')
  assert.equal(fs.realpathSync(input), input, 'Turbopack native binary must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'Turbopack native binary must be executable')
  const version = run(input, ['--version'], { timeout: 5_000 })
  requireSuccess(version, 'current native ZigCSS version probe')
  assert.equal(version.stdout, `zigcss ${activePackageVersion}\n`)
  return input
}

function offlineEnvironment(root, trace, allowedBinary) {
  return {
    ...process.env,
    CI: '1',
    NEXT_TELEMETRY_DISABLED: '1',
    NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
    NO_COLOR: '1',
    ZIGCSS_TURBOPACK_OFFLINE: '1',
    ZIGCSS_TURBOPACK_TRACE: trace,
    ZIGCSS_TURBOPACK_TRACE_ROOT: root,
    ...(allowedBinary === undefined ? {} : { ZIGCSS_TURBOPACK_ALLOWED_BINARY: allowedBinary }),
    npm_config_audit: 'false',
    npm_config_fund: 'false',
    npm_config_ignore_scripts: 'true',
    npm_config_offline: 'true',
    npm_config_update_notifier: 'false',
  }
}

function stageCurrentPackage(project, binary) {
  const target = path.join(project, 'node_modules', 'zigcss')
  fs.mkdirSync(path.join(target, 'adapters'), { recursive: true })
  fs.mkdirSync(path.join(target, 'bin'))
  for (const filename of ['package.json', 'api.cjs']) {
    fs.copyFileSync(path.join(repositoryRoot, filename), path.join(target, filename))
  }
  for (const filename of ['core.cjs', 'webpack.cjs']) {
    fs.copyFileSync(path.join(repositoryRoot, 'adapters', filename), path.join(target, 'adapters', filename))
  }
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const installedBinary = path.join(target, 'bin', binaryName)
  fs.copyFileSync(binary, installedBinary)
  if (process.platform !== 'win32') fs.chmodSync(installedBinary, 0o755)

  for (const filename of collectRegularFiles(target)) {
    const absolute = path.join(target, filename)
    assert.equal(fs.lstatSync(absolute).isFile(), true)
    assert.equal(fs.lstatSync(absolute).isSymbolicLink(), false)
  }
  return target
}

function findFiles(root, suffix) {
  if (!fs.existsSync(root)) return []
  return collectRegularFiles(root)
    .filter(filename => filename.endsWith(suffix))
    .map(filename => path.join(root, filename))
}

function readCssAndMap(project) {
  const staticRoot = path.join(project, '.next', 'static')
  const cssFiles = findFiles(staticRoot, '.css')
  assert.equal(
    cssFiles.length,
    1,
    `expected one emitted CSS file, received ${cssFiles.length}: ${collectRegularFiles(path.join(project, '.next')).join(', ')}`,
  )
  const css = fs.readFileSync(cssFiles[0], 'utf8')
  const reference = css.match(/\/\*# sourceMappingURL=([^*]+)\*\//)
  assert.notEqual(reference, null, 'emitted CSS must own an external source map')
  const mapPath = path.resolve(path.dirname(cssFiles[0]), reference[1].trim())
  const map = readJson(mapPath)
  const body = css.replace(/\s*\/\*# sourceMappingURL=[^*]+\*\/\s*$/, '')
  return { body, map }
}

function normalizedMapSource(source) {
  const marker = '[project]/'
  const index = source.lastIndexOf(marker)
  assert.notEqual(index, -1, `Turbopack source must identify [project]: ${source}`)
  return source.slice(index + marker.length)
}

function requireMap(project, expectedDependencySource) {
  const output = readCssAndMap(project)
  assert.equal(output.map.version, 3)
  assert.deepEqual(output.map.names, [])
  assert.notEqual(output.map.mappings, '')
  assert.deepEqual(output.map.sources.map(normalizedMapSource), [
    'app/styles.scss',
    'app/_tokens.scss',
  ])
  assert.deepEqual(output.map.sourcesContent, [initialEntry, expectedDependencySource])
  return output.body
}

function digestFiles(root, files) {
  return Object.fromEntries(files.map(filename => [
    filename,
    crypto.createHash('sha256').update(fs.readFileSync(path.join(root, filename))).digest('hex'),
  ]))
}

function changedFiles(before, after) {
  return Object.keys(before).filter(filename => before[filename] !== after[filename]).sort()
}

function parseTrace(filename) {
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
}

test('Next 16.3.4 Turbopack example is a global-SCSS-only reuse of zigcss/webpack', () => {
  assert.equal(validateExampleContract(loadExampleContract()), true)
})

test('documented local package install overrides a hostile npm install-links setting', t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-next-local-install-')))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  fs.writeFileSync(path.join(temporary, 'package.json'), '{"name":"zigcss-local-install-proof","private":true}\n')

  const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const install = run(npmCommand, [
    'install',
    '--ignore-scripts',
    '--no-save',
    '--install-links=false',
    repositoryRoot,
  ], {
    cwd: temporary,
    env: {
      ...process.env,
      npm_config_audit: 'false',
      npm_config_fund: 'false',
      npm_config_ignore_scripts: 'true',
      npm_config_install_links: 'true',
      npm_config_offline: 'true',
      npm_config_update_notifier: 'false',
    },
  })
  requireSuccess(install, 'documented hostile-config local package install')

  const installed = path.join(temporary, 'node_modules', 'zigcss')
  assert.equal(fs.lstatSync(installed).isSymbolicLink(), true)
  assert.equal(fs.realpathSync(installed), fs.realpathSync(repositoryRoot))
})

test('Turbopack example contract rejects aliases modules syntaxes PostCSS and mutable host versions', () => {
  const mutations = [
    contract => { contract.manifest.devDependencies.next = '^16.3.4' },
    contract => { contract.rootManifest.devDependencies.react = '19.2.3' },
    contract => { contract.config.turbopack.rules['*.scss'].loaders[0].loader = 'zigcss/turbopack' },
    contract => { delete contract.config.turbopack.rules['*.scss'].condition },
    contract => { contract.config.turbopack.rules['*.scss'].type = 'css-module' },
    contract => { contract.config.turbopack.rules['*.scss'].loaders[0].options.sourceMap = false },
    contract => { contract.config.experimental.turbopackUseBuiltinSass = true },
    contract => { contract.config.experimental.turbopackFileSystemCacheForBuild = false },
    contract => { contract.config.turbopack.rules['*.scss'].loaders.push({ loader: 'postcss-loader' }) },
    contract => { contract.files.push('app/styles.less') },
    contract => { contract.preload = contract.preload.replace("immutable(workerThreads, 'Worker'", "immutable(workerThreads, 'UnsafeWorker'") },
  ]
  for (const mutate of mutations) {
    const changed = loadExampleContract()
    mutate(changed)
    assert.throws(() => validateExampleContract(changed))
  }

  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-turbopack-network-')))
  const trace = path.join(temporary, 'offline-trace.jsonl')
  try {
    fs.writeFileSync(trace, '')
    const denied = run(process.execPath, ['-e', "require('node:https').get('https://example.com')"], {
      env: offlineEnvironment(temporary, trace),
      timeout: 5_000,
    })
    assert.equal(denied.signal, null)
    assert.equal(denied.status, 1)
    assert.match(denied.stderr, /Turbopack offline test blocked https\.get/)
    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'network-denied:https.get'), true)
    assert.equal(records.at(-1).networkAttempts, 1)

    fs.writeFileSync(trace, '')
    const wildcard = run(process.execPath, ['-e', [
      "const net = require('node:net')",
      "net.createServer().listen({ port: 0, host: '0.0.0.0' })",
    ].join('\n')], {
      env: offlineEnvironment(temporary, trace),
      timeout: 5_000,
    })
    assert.equal(wildcard.signal, null)
    assert.equal(wildcard.status, 1)
    assert.match(wildcard.stderr, /Turbopack offline test blocked net\.Server\.listen/)
    const wildcardRecords = parseTrace(trace)
    assert.equal(
      wildcardRecords.some(record => record.event === 'network-denied:net.Server.listen'),
      true,
    )
    assert.equal(wildcardRecords.at(-1).networkAttempts, 1)

    fs.writeFileSync(trace, '')
    const loopback = run(process.execPath, ['-e', [
      "const net = require('node:net')",
      'const server = net.createServer()',
      "server.listen({ port: 0 }, () => { process.stdout.write(JSON.stringify(server.address())); server.close() })",
    ].join('\n')], {
      env: offlineEnvironment(temporary, trace),
      timeout: 5_000,
    })
    assert.equal(loopback.signal, null)
    assert.equal(loopback.status, 0, loopback.stderr)
    assert.equal(JSON.parse(loopback.stdout).address, '127.0.0.1')
    const loopbackRecords = parseTrace(trace)
    assert.equal(
      loopbackRecords.some(record => record.event === 'local-ipc-allowed:net.Server.listen'),
      true,
    )
    assert.equal(loopbackRecords.every(record => record.networkAttempts === 0), true)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false)
})

test('Turbopack preload denies and traces worker process and alternate network escapes', t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-turbopack-boundary-')))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const binary = path.join(
    temporary,
    'project',
    'node_modules',
    'zigcss',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  )
  fs.mkdirSync(path.dirname(binary), { recursive: true })
  fs.copyFileSync(process.execPath, binary, fs.constants.COPYFILE_EXCL)
  if (process.platform !== 'win32') fs.chmodSync(binary, 0o755)
  const trace = path.join(temporary, 'trace.jsonl')
  fs.writeFileSync(trace, '')
  const env = offlineEnvironment(temporary, trace, binary)
  const probe = run(process.execPath, ['-e', [
    "const cp = require('node:child_process')",
    "const cluster = require('node:cluster')",
    "const dgram = require('node:dgram')",
    "const dns = require('node:dns')",
    "const http = require('node:http')",
    "const https = require('node:https')",
    "const inspector = require('node:inspector')",
    "const net = require('node:net')",
    "const tls = require('node:tls')",
    "const workers = require('node:worker_threads')",
    'const operations = {',
    "  https: () => https.get('https://example.com'),",
    "  dnsDynamic: () => dns.resolve4('example.com', () => {}),",
    "  dnsServers: () => dns.setServers(['127.0.0.1']),",
    "  inspector: () => inspector.open(0, '127.0.0.1', false),",
    "  netHandle: () => net._createServerHandle('127.0.0.1', 0, 4, 0),",
    "  netListen2: () => new net.Server()._listen2('0.0.0.0', 0, 4, 511),",
    "  httpListen: () => new http.Server().listen(0, '127.0.0.1'),",
    "  httpAgent: () => new http.Agent().createConnection({ host: '127.0.0.1', port: 9 }),",
    "  tlsConnect: () => tls.connect({ host: '127.0.0.1', port: 9 }),",
    "  tlsListen: () => new tls.Server({}).listen(0, '127.0.0.1'),",
    "  dgramHandle: () => dgram._createSocketHandle('udp4'),",
    "  dgramSocket: () => new dgram.Socket({ type: 'udp4' }),",
    "  spawnSync: () => cp.spawnSync(process.execPath, ['--version']),",
    "  childPrototype: () => new cp.ChildProcess().spawn({ file: process.execPath, args: [process.execPath] }),",
    "  wrongSpawn: () => cp.spawn(process.argv[1], ['--version'], { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }),",
    "  fork: () => cp.fork(process.argv[1], [], {}),",
    "  cluster: () => cluster.fork(),",
    "  worker: () => new workers.Worker('0', { eval: true, execArgv: [], env: {} }),",
    "  bindingProcess: () => process.binding('spawn_sync'),",
    "  bindingNetwork: () => process.binding('tcp_wrap'),",
    "  linkedBinding: () => process._linkedBinding('tcp_wrap'),",
    "  kill: () => process.kill(process.pid, 0),",
    "  fetchAssignment: () => { globalThis.fetch = async () => ({ ok: true }) },",
    '}',
    "if (typeof process.execve === 'function') operations.execve = () => process.execve(process.execPath, [process.execPath], process.env)",
    "if (typeof process._debugProcess === 'function') operations.debug = () => process._debugProcess(process.pid)",
    "if (typeof process._kill === 'function') operations.privateKill = () => process._kill(process.pid, 0)",
    "if (typeof http.WebSocket === 'function') operations.websocket = () => new http.WebSocket('ws://127.0.0.1:9')",
    'const results = {}',
    'for (const [name, operation] of Object.entries(operations)) {',
    "  try { operation(); results[name] = 'allowed' } catch (error) { results[name] = error.code }",
    '}',
    "results.workerImmutable = `${Object.getOwnPropertyDescriptor(workers, 'Worker').configurable}:${Object.getOwnPropertyDescriptor(workers, 'Worker').writable}`",
    "results.spawnImmutable = `${Object.getOwnPropertyDescriptor(cp, 'spawn').configurable}:${Object.getOwnPropertyDescriptor(cp, 'spawn').writable}`",
    'process.stdout.write(JSON.stringify(results))',
  ].join('\n'), binary], { env, timeout: 5_000 })
  requireSuccess(probe, 'Turbopack boundary probes')
  const results = JSON.parse(probe.stdout)
  assert.equal(results.worker, 'ZIGCSS_PROCESS_DISABLED')
  assert.equal(results.workerImmutable, 'false:false')
  assert.equal(results.spawnImmutable, 'false:false')
  for (const [name, code] of Object.entries(results)) {
    if (name.endsWith('Immutable')) continue
    assert.match(code, /^ZIGCSS_(?:PROCESS|NETWORK)_DISABLED$/, `${name} must be denied`)
  }
  const records = parseTrace(trace)
  for (const event of [
    'process-denied:worker_threads.Worker',
    'process-denied:cluster.fork',
    'process-denied:child_process.spawnSync',
    'process-denied:child_process.ChildProcess.prototype.spawn',
    'process-denied:child_process.spawn',
    'process-denied:child_process.fork:module',
    'process-denied:process.binding:spawn_sync',
    'process-denied:process._linkedBinding',
    'process-denied:process.kill',
    'network-denied:https.get',
    'network-denied:dns.resolve4',
    'network-denied:dns.setServers',
    'network-denied:inspector.open',
    'network-denied:net._createServerHandle',
    'network-denied:net.Server._listen2',
    'network-denied:http.Server.listen',
    'network-denied:http.Agent.createConnection',
    'network-denied:tls.connect',
    'network-denied:tls.Server.listen',
    'network-denied:dgram._createSocketHandle',
    'network-denied:dgram.Socket',
    'network-denied:process.binding:tcp_wrap',
    'network-denied:globalThis.fetch-assignment',
  ]) assert.equal(records.some(record => record.event === event), true, `${event} must be traced`)
  if (typeof process.execve === 'function') {
    assert.equal(records.some(record => record.event === 'process-denied:process.execve'), true)
  }
  if (typeof process._debugProcess === 'function') {
    assert.equal(records.some(record => record.event === 'process-denied:process._debugProcess'), true)
  }
  if (typeof process._kill === 'function') {
    assert.equal(records.some(record => record.event === 'process-denied:process._kill'), true)
  }
  if (typeof http.WebSocket === 'function') {
    assert.equal(records.some(record => record.event === 'network-denied:WebSocket'), true)
  }
  assert.equal(records.some(record => record.event === 'native-spawn'), false)
})

test('current native ZigCSS completes offline Next 16.3.4 Turbopack maps cache invalidation and diagnostics', t => {
  const binaryInput = process.env.ZIGCSS_TURBOPACK_NATIVE_BINARY
  if (binaryInput === undefined) {
    t.skip('set exact absolute ZIGCSS_TURBOPACK_NATIVE_BINARY after building the current checkout')
    return
  }
  const binary = validateNativeBinary(binaryInput)
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-turbopack-')))
  const project = path.join(temporary, 'project')
  const trace = path.join(temporary, 'offline-trace.jsonl')
  try {
    fs.cpSync(exampleRoot, project, { recursive: true })
    fs.writeFileSync(trace, '')
    const installEnv = offlineEnvironment(temporary, trace)
    const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm'
    const install = run(npmCommand, ['ci', '--offline', '--ignore-scripts', '--no-audit', '--no-fund'], {
      cwd: project,
      env: installEnv,
    })
    requireSuccess(install, 'offline pinned Next.js installation')

    const installedPackage = stageCurrentPackage(project, binary)
    const installedBinary = path.join(
      installedPackage,
      'bin',
      process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
    )
    const env = offlineEnvironment(temporary, trace, installedBinary)
    const resolution = run(process.execPath, ['-e', "process.stdout.write(require.resolve('zigcss/webpack'))"], {
      cwd: project,
      env,
    })
    requireSuccess(resolution, 'zigcss/webpack package-subpath resolution')
    assert.equal(resolution.stdout, path.join(installedPackage, 'adapters', 'webpack.cjs'))
    for (const [name, version] of Object.entries(expectedHostVersions)) {
      assert.equal(readJson(path.join(project, 'node_modules', name, 'package.json')).version, version)
    }

    const nextCli = path.join(project, 'node_modules', 'next', 'dist', 'bin', 'next')
    const build = () => run(process.execPath, [nextCli, 'build', '--turbopack'], { cwd: project, env })
    const first = build()
    requireSuccess(first, 'initial offline Next.js Turbopack build')
    assert.equal(requireMap(project, initialDependency), '.zigcss-current-native{color:#639}')

    const ownedSources = [
      'README.md',
      'app/_tokens.scss',
      'app/layout.js',
      'app/page.js',
      'app/styles.scss',
      'next.config.js',
      'package-lock.json',
      'package.json',
    ]
    const before = digestFiles(project, ownedSources)
    fs.writeFileSync(path.join(project, 'app', '_tokens.scss'), changedDependency)
    const after = digestFiles(project, ownedSources)
    assert.deepEqual(changedFiles(before, after), ['app/_tokens.scss'])
    assert.equal(fs.existsSync(path.join(project, '.next')), true, 'persistent cache must remain for the warm build')

    const second = build()
    requireSuccess(second, 'dependency-only warm Next.js Turbopack rebuild')
    assert.equal(requireMap(project, changedDependency), '.zigcss-current-native{color:#7fff00}')

    fs.writeFileSync(
      path.join(project, 'app', 'styles.scss'),
      initialEntry.replace('tokens.$accent', 'tokens.$missing'),
    )
    const diagnostic = build()
    assert.equal(diagnostic.signal, null)
    assert.equal(diagnostic.status, 1, `${diagnostic.stdout}\n${diagnostic.stderr}`)
    const failure = `${diagnostic.stdout}\n${diagnostic.stderr}`
    assert.match(failure, /ZigCssLoaderError/)
    assert.match(failure, /\[NATIVE0002\] undefined native Sass module variable/)
    assert.match(failure, /\.\/app\/styles\.scss/)

    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'runtime-start'), true)
    assert.equal(records.some(record => record.event === 'runtime-summary'), true)
    assert.equal(records.some(record => record.event === 'native-spawn'), true)
    assert.equal(records.some(record => record.event === 'next-turbopack-worker'), true)
    assert.equal(records.some(record => record.event === 'next-node-fork'), true)
    assert.equal(records.some(record => record.event === 'next-fetch-wrapper-allowed'), true)
    assert.equal(records.some(record => record.event.startsWith('network-denied:')), false)
    assert.equal(records.some(record => record.event.startsWith('process-denied:')), false)
    assert.equal(records.every(record => record.networkAttempts === 0), true)
    assert.equal(records.every(record => record.deniedProcessAttempts === 0), true)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'Turbopack temp root must be fully removed')
})
