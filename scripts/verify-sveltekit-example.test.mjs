import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const exampleRoot = path.join(repositoryRoot, 'examples', 'sveltekit')
const preload = path.join(repositoryRoot, 'scripts', 'sveltekit-offline-preload.cjs')
const expectedFiles = Object.freeze([
  'README.md',
  'package-lock.json',
  'package.json',
  'src/app.html',
  'src/routes/+page.js',
  'src/routes/+page.svelte',
  'src/routes/_tokens.scss',
  'src/routes/card.module.scss',
  'vite.config.js',
])
const expectedHostVersions = Object.freeze({
  '@sveltejs/adapter-static': '3.0.10',
  '@sveltejs/kit': '2.70.3',
  '@sveltejs/vite-plugin-svelte': '7.3.0',
  svelte: '5.57.0',
  vite: '8.2.2',
})
const expectedOverrides = Object.freeze({ cookie: '0.7.2' })
const expectedConfig = `import adapter from '@sveltejs/adapter-static'
import { sveltekit } from '@sveltejs/kit/vite'
import { defineConfig } from 'vite'
import zigcss from 'zigcss/vite'

export default defineConfig({
  plugins: [
    zigcss({ maxWorkers: 2, sourceMap: true }),
    sveltekit({ adapter: adapter() }),
  ],
  build: {
    sourcemap: true,
  },
})
`
const expectedEntry = '@use "tokens";\n\n.hero {\n  color: tokens.$accent;\n}\n'
const expectedDependency = '$accent: rebeccapurple;\n'
const expectedPage = `<script>
  import styles from './card.module.scss'
</script>

<svelte:head>
  <title>SvelteKit ZigCSS</title>
</svelte:head>

<main class={styles.hero}>SvelteKit ZigCSS</main>
`

function readJson(filename) {
  return JSON.parse(fs.readFileSync(filename, 'utf8'))
}

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
  return {
    files: collectRegularFiles(exampleRoot),
    rootManifest: readJson(path.join(repositoryRoot, 'package.json')),
    manifest: readJson(path.join(exampleRoot, 'package.json')),
    lock: readJson(path.join(exampleRoot, 'package-lock.json')),
    config: fs.readFileSync(path.join(exampleRoot, 'vite.config.js'), 'utf8'),
    readme: fs.readFileSync(path.join(exampleRoot, 'README.md'), 'utf8'),
    page: fs.readFileSync(path.join(exampleRoot, 'src', 'routes', '+page.svelte'), 'utf8'),
    pageOptions: fs.readFileSync(path.join(exampleRoot, 'src', 'routes', '+page.js'), 'utf8'),
    entry: fs.readFileSync(path.join(exampleRoot, 'src', 'routes', 'card.module.scss'), 'utf8'),
    dependency: fs.readFileSync(path.join(exampleRoot, 'src', 'routes', '_tokens.scss'), 'utf8'),
    preload: fs.readFileSync(preload, 'utf8'),
  }
}

export function validateExampleContract(contract) {
  assert.deepEqual(contract.files, [...expectedFiles])
  assert.equal(contract.manifest.name, 'zigcss-sveltekit-example')
  assert.equal(contract.manifest.private, true)
  assert.equal(contract.manifest.type, 'module')
  assert.deepEqual(contract.manifest.scripts, { build: 'vite build' })
  assert.deepEqual(contract.manifest.devDependencies, expectedHostVersions)
  assert.deepEqual(contract.manifest.overrides, expectedOverrides)
  assert.equal(Object.hasOwn(contract.manifest, 'dependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'peerDependencies'), false)

  assert.equal(contract.lock.name, contract.manifest.name)
  assert.equal(contract.lock.lockfileVersion, 3)
  assert.equal(contract.lock.requires, true)
  assert.deepEqual(contract.lock.packages[''].devDependencies, expectedHostVersions)
  assert.equal(contract.lock.packages['node_modules/cookie'].version, expectedOverrides.cookie)
  assert.equal(Object.hasOwn(contract.lock.packages, 'node_modules/zigcss'), false)
  for (const [name, version] of Object.entries(expectedHostVersions)) {
    const locked = contract.lock.packages[`node_modules/${name}`]
    assert.equal(locked.version, version)
    assert.equal(locked.dev, true)
  }
  for (const [location, locked] of Object.entries(contract.lock.packages)) {
    if (location === '') continue
    assert.equal(locked.dev, true, `${location} must remain development-only`)
    assert.match(locked.resolved, /^https:\/\/registry\.npmjs\.org\//)
    assert.match(locked.integrity, /^sha512-[A-Za-z0-9+/]+={0,2}$/)
  }

  assert.deepEqual(contract.rootManifest.dependencies, {})
  assert.equal(Object.hasOwn(contract.rootManifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './sveltekit'), false)
  assert.equal(contract.config, expectedConfig)
  assert.equal(contract.config.indexOf("zigcss({ maxWorkers: 2, sourceMap: true })"), contract.config.lastIndexOf("zigcss({ maxWorkers: 2, sourceMap: true })"))
  assert.ok(contract.config.indexOf('zigcss({') < contract.config.indexOf('sveltekit({'))
  assert.doesNotMatch(contract.config, /vitePreprocess|hmr|watch|embedded|lang=/i)

  assert.equal(contract.entry, expectedEntry)
  assert.equal(contract.dependency, expectedDependency)
  assert.equal(contract.page, expectedPage)
  assert.equal(contract.pageOptions, 'export const prerender = true\n')
  assert.doesNotMatch(contract.page, /<style|lang=["'](?:scss|sass|less|stylus?)/i)
  assert.match(contract.readme, /one deliberately narrow integration/)
  assert.match(contract.readme, /Zig 0\.15\.2 and Node 24\.20\.0 LTS/)
  assert.match(contract.readme, /zig build -Doptimize=ReleaseFast/)
  assert.match(contract.readme, /npm ci --ignore-scripts/)
  assert.match(contract.readme, /ZIGCSS_SVELTEKIT_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:sveltekit-example/)
  assert.match(contract.readme, /external `card\.module\.scss`/)
  assert.match(contract.readme, /client, SSR, and static-prerender builds with source maps enabled/)
  assert.match(contract.readme, /denies network access during the host build/)
  assert.match(contract.readme, /fail-closed JavaScript preload denies arbitrary workers/)
  assert.match(contract.readme, /three exact lock-pinned SvelteKit postbuild worker modules/)
  assert.match(contract.readme, /`eval` worker with empty `execArgv` and environment cannot shed the preload/)
  assert.match(contract.readme, /not an OS sandbox/)
  assert.match(contract.readme, /exact `cookie` 0\.7\.2 security override/)
  assert.match(contract.readme, /empty production graph both report zero vulnerabilities/)
  assert.match(contract.readme, /does not claim support for embedded `<style lang="scss">` blocks, Svelte preprocessors, framework-specific HMR or watch invalidation/)
  assert.match(contract.readme, /current-source-checkout proof only/)
  assert.match(contract.readme, /svelte\.dev\/docs\/kit\/adapters/)

  for (const anchor of [
    "ZIGCSS_SVELTEKIT_OFFLINE !== '1'",
    "^zigcss-sveltekit-(?:boundary-)?[A-Za-z0-9]{6}$",
    'const traceRoot = fs.realpathSync(__dirname)',
    'function openBoundedRegularFile(',
    'function withTraceLock(action)',
    'const count = fs.readSync(opened.descriptor, content, offset, bytes - offset, offset)',
    "if (input !== expected) fail('allowed ZigCSS binary must equal its exact staged path')",
    'captureAllowedBinary(process.env.ZIGCSS_SVELTEKIT_ALLOWED_BINARY)',
    "immutable(workerThreads, 'Worker'",
    "immutable(cluster, 'fork'",
    "immutable(process, '_linkedBinding'",
    "immutable(net.Server.prototype, '_listen2'",
    "immutable(dgram, 'Socket'",
    'for (const name of Object.keys(dns))',
    "immutable(globalThis, 'fetch'",
    "record('runtime-start')",
    "record('runtime-summary')",
  ]) assert.match(contract.preload, new RegExp(anchor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  return true
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
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
  assert.equal(path.isAbsolute(input), true, 'ZIGCSS_SVELTEKIT_NATIVE_BINARY must be absolute')
  assert.equal(path.resolve(input), input, 'ZIGCSS_SVELTEKIT_NATIVE_BINARY must be normalized')
  const stat = fs.lstatSync(input)
  assert.equal(stat.isFile(), true, 'SvelteKit native binary must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'SvelteKit native binary must not be a symlink')
  assert.equal(fs.realpathSync(input), input, 'SvelteKit native binary must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'SvelteKit native binary must be executable')
  const expectedVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  const version = run(input, ['--version'], { timeout: 5_000 })
  requireSuccess(version, 'current native ZigCSS version probe')
  assert.equal(version.stdout.trim(), `zigcss ${expectedVersion}`)
  assert.equal(version.stderr, '')
  return input
}

function installEnvironment(temporary, userConfig) {
  return {
    ...process.env,
    CI: '1',
    NO_COLOR: '1',
    npm_config_audit: 'false',
    npm_config_cache: path.join(temporary, 'npm-cache'),
    npm_config_fund: 'false',
    npm_config_ignore_scripts: 'true',
    npm_config_update_notifier: 'false',
    npm_config_userconfig: userConfig,
  }
}

function offlineEnvironment(installEnv, temporary, trace, allowedBinary) {
  const stagedPreload = path.join(temporary, path.basename(preload))
  fs.copyFileSync(preload, stagedPreload)
  return {
    ...installEnv,
    NODE_OPTIONS: `--require=${JSON.stringify(fs.realpathSync(stagedPreload))}`,
    ZIGCSS_SVELTEKIT_OFFLINE: '1',
    ZIGCSS_SVELTEKIT_TRACE: trace,
    ZIGCSS_SVELTEKIT_TRACE_ROOT: temporary,
    ...(allowedBinary === undefined ? {} : { ZIGCSS_SVELTEKIT_ALLOWED_BINARY: allowedBinary }),
    npm_config_offline: 'true',
  }
}

function stageCurrentPackage(project, binary) {
  const target = path.join(project, 'node_modules', 'zigcss')
  fs.mkdirSync(path.join(target, 'adapters'), { recursive: true })
  fs.mkdirSync(path.join(target, 'bin'))
  for (const filename of ['package.json', 'api.cjs']) {
    fs.copyFileSync(path.join(repositoryRoot, filename), path.join(target, filename))
  }
  for (const filename of ['core.cjs', 'vite.cjs', 'vite.mjs']) {
    fs.copyFileSync(path.join(repositoryRoot, 'adapters', filename), path.join(target, 'adapters', filename))
  }
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const installedBinary = path.join(target, 'bin', binaryName)
  fs.copyFileSync(binary, installedBinary)
  if (process.platform !== 'win32') fs.chmodSync(installedBinary, 0o755)
  assert.deepEqual(collectRegularFiles(target), [
    'adapters/core.cjs',
    'adapters/vite.cjs',
    'adapters/vite.mjs',
    'api.cjs',
    `bin/${binaryName}`,
    'package.json',
  ])
  return target
}

function findRegularFiles(root, suffix) {
  if (!fs.existsSync(root)) return []
  const files = []
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name)
      assert.equal(entry.isSymbolicLink(), false, `build output must not contain symlinks: ${absolute}`)
      if (entry.isDirectory()) visit(absolute)
      else {
        assert.equal(entry.isFile(), true, `build output must be regular: ${absolute}`)
        if (absolute.endsWith(suffix)) files.push(absolute)
      }
    }
  }
  visit(root)
  return files.sort()
}

function requireSingleContaining(files, pattern, label) {
  const matches = files.filter(filename => pattern.test(fs.readFileSync(filename, 'utf8')))
  assert.equal(matches.length, 1, `${label} expected one matching file, received ${matches.length}`)
  return { filename: matches[0], source: fs.readFileSync(matches[0], 'utf8') }
}

function sourceIndex(map, basename) {
  const matches = map.sources
    .map((source, index) => ({ source: source.replaceAll('\\', '/'), index }))
    .filter(item => item.source.endsWith(`/${basename}`))
  assert.equal(matches.length, 1, `source map must contain one ${basename} source`)
  return matches[0].index
}

function requireNativeSourceMap(root, label) {
  const candidates = findRegularFiles(root, '.map').map(filename => ({ filename, map: readJson(filename) }))
    .filter(({ map }) => Array.isArray(map.sources) && (
      map.sources.some(source => source.replaceAll('\\', '/').endsWith('/card.module.scss')) &&
      map.sources.some(source => source.replaceAll('\\', '/').endsWith('/_tokens.scss'))
    ))
  assert.equal(candidates.length, 1, `${label} must contain one native ZigCSS map chain`)
  const { map } = candidates[0]
  assert.equal(map.version, 3)
  assert.deepEqual(map.names, [])
  assert.notEqual(map.mappings, '')
  assert.equal(Array.isArray(map.sourcesContent), true)
  assert.equal(map.sourcesContent.length, map.sources.length)
  assert.equal(map.sourcesContent[sourceIndex(map, 'card.module.scss')], expectedEntry)
  assert.equal(map.sourcesContent[sourceIndex(map, '_tokens.scss')], expectedDependency)
  return candidates[0].filename
}

function parseTrace(filename) {
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
}

test('SvelteKit 2.70.3 example is an external CSS Module current-checkout contract', () => {
  assert.equal(validateExampleContract(loadExampleContract()), true)
})

test('SvelteKit example rejects mutable hosts, production dependencies, embedded styles, HMR, and generalized claims', () => {
  const mutations = [
    contract => { contract.manifest.devDependencies['@sveltejs/kit'] = '^2.70.3' },
    contract => { contract.manifest.overrides.cookie = '0.6.0' },
    contract => { contract.manifest.dependencies = { zigcss: '0.6.0' } },
    contract => { contract.lock.packages['node_modules/vite'].dev = false },
    contract => { contract.lock.packages[''].devDependencies.svelte = '^5.57.0' },
    contract => { contract.config = contract.config.replace('sourceMap: true', 'sourceMap: false') },
    contract => { contract.config = contract.config.replace('zigcss({ maxWorkers: 2, sourceMap: true }),\n    sveltekit', 'sveltekit({ adapter: adapter() }),\n    zigcss') },
    contract => { contract.page += '\n<style lang="scss">.leak { color: red; }</style>\n' },
    contract => { contract.entry = contract.entry.replace('@use "tokens";\n\n', '') },
    contract => { contract.readme = contract.readme.replace('framework-specific HMR or watch invalidation', 'complete HMR and watch invalidation') },
    contract => { contract.readme = contract.readme.replace('not an OS sandbox', 'a complete OS sandbox') },
    contract => { contract.preload = contract.preload.replace("immutable(globalThis, 'fetch'", "immutable(globalThis, 'unsafeFetch'") },
    contract => { contract.preload = contract.preload.replace("immutable(workerThreads, 'Worker'", "immutable(workerThreads, 'UnsafeWorker'") },
    contract => { contract.rootManifest.exports['./sveltekit'] = './adapters/vite.mjs' },
    contract => { contract.files.push('src/routes/embedded.svelte') },
  ]
  for (const mutate of mutations) {
    const changed = structuredClone(loadExampleContract())
    mutate(changed)
    assert.throws(() => validateExampleContract(changed))
  }
})

test('SvelteKit preload denies and traces worker process and network escape surfaces', t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-sveltekit-boundary-')))
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
  const env = offlineEnvironment(process.env, temporary, trace, binary)
  const raceProbeEnv = { ...env }
  delete raceProbeEnv.NODE_OPTIONS
  const raceProbe = run(process.execPath, ['-e', [
    "const fs = require('node:fs')",
    'const originalLstat = fs.lstatSync',
    'let appended = false',
    'fs.lstatSync = function injectedConcurrentAppend(filename, options) {',
    '  if (!appended && filename === process.argv[2]) { appended = true; fs.appendFileSync(filename, " ") }',
    '  return originalLstat(filename, options)',
    '}',
    "process.env.NODE_OPTIONS = '--require=' + JSON.stringify(process.argv[1])",
    'require(process.argv[1])',
  ].join('\n'), path.join(temporary, path.basename(preload)), trace], { env: raceProbeEnv, timeout: 5_000 })
  requireSuccess(raceProbe, 'concurrent SvelteKit trace metadata mutation probe')
  const unadmittedTrace = path.join(temporary, 'unadmitted-trace.jsonl')
  fs.writeFileSync(unadmittedTrace, 'sentinel\n')
  const deniedTrace = run(process.execPath, ['-e', 'process.exit(0)'], {
    env: { ...env, ZIGCSS_SVELTEKIT_TRACE: unadmittedTrace },
    timeout: 5_000,
  })
  assert.equal(deniedTrace.status, 1)
  assert.match(deniedTrace.stderr, /trace file must use an admitted fixed filename/)
  assert.equal(fs.readFileSync(unadmittedTrace, 'utf8'), 'sentinel\n')
  const linkedTrace = path.join(temporary, 'linked-trace.jsonl')
  fs.linkSync(trace, linkedTrace)
  const deniedLinkedTrace = run(process.execPath, ['-e', 'process.exit(0)'], { env, timeout: 5_000 })
  assert.equal(deniedLinkedTrace.status, 1)
  assert.match(deniedLinkedTrace.stderr, /bounded canonical singly-linked regular non-symlink file/)
  fs.unlinkSync(linkedTrace)
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
    "  netListen2: () => new net.Server()._listen2('127.0.0.1', 0, 4, 511),",
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
  requireSuccess(probe, 'SvelteKit boundary probes')
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
    'process-denied:child_process.fork',
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

test('current native ZigCSS completes deny-network SvelteKit client SSR prerender and source-map smoke', t => {
  const binaryInput = process.env.ZIGCSS_SVELTEKIT_NATIVE_BINARY
  if (binaryInput === undefined) {
    t.skip('set exact absolute ZIGCSS_SVELTEKIT_NATIVE_BINARY after building the current checkout')
    return
  }
  const binary = validateNativeBinary(binaryInput)
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-sveltekit-')))
  const project = path.join(temporary, 'project')
  const trace = path.join(temporary, 'offline-trace.jsonl')
  const userConfig = path.join(temporary, 'npmrc')
  try {
    fs.cpSync(exampleRoot, project, { recursive: true, errorOnExist: true, force: false })
    assert.deepEqual(collectRegularFiles(project), [...expectedFiles])
    fs.writeFileSync(trace, '')
    fs.writeFileSync(userConfig, 'audit=false\nfund=false\nignore-scripts=true\nupdate-notifier=false\n')
    const installEnv = installEnvironment(temporary, userConfig)
    const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm'
    const install = run(npmCommand, ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], {
      cwd: project,
      env: installEnv,
    })
    requireSuccess(install, 'isolated pinned SvelteKit installation')

    const installedPackage = stageCurrentPackage(project, binary)
    for (const [name, version] of Object.entries(expectedHostVersions)) {
      assert.equal(readJson(path.join(project, 'node_modules', name, 'package.json')).version, version)
    }
    const installedBinary = path.join(
      installedPackage,
      'bin',
      process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
    )
    const env = offlineEnvironment(installEnv, temporary, trace, installedBinary)
    const resolution = run(process.execPath, ['-e', "process.stdout.write(require.resolve('zigcss/vite'))"], {
      cwd: project,
      env,
    })
    requireSuccess(resolution, 'zigcss/vite package-subpath resolution')
    assert.equal(resolution.stdout, path.join(installedPackage, 'adapters', 'vite.cjs'))

    const viteCli = path.join(project, 'node_modules', 'vite', 'bin', 'vite.js')
    const build = run(process.execPath, [viteCli, 'build'], { cwd: project, env })
    requireSuccess(build, 'deny-network SvelteKit production build')

    const clientRoot = path.join(project, '.svelte-kit', 'output', 'client')
    const serverRoot = path.join(project, '.svelte-kit', 'output', 'server')
    const prerendered = path.join(project, '.svelte-kit', 'output', 'prerendered', 'pages', 'index.html')
    const staticPage = path.join(project, 'build', 'index.html')
    const clientCss = requireSingleContaining(
      findRegularFiles(clientRoot, '.css'),
      /color:\s*(?:#639|rebeccapurple)/i,
      'client CSS',
    )
    const classMatch = clientCss.source.match(/\.(_hero_[A-Za-z0-9_-]+)\s*\{[^}]*color:\s*(?:#639|rebeccapurple)/i)
    assert.notEqual(classMatch, null)
    const className = classMatch[1]
    const escapedClassName = className.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const serverCss = requireSingleContaining(
      findRegularFiles(serverRoot, '.css'),
      new RegExp(`\\.${escapedClassName}\\s*\\{[^}]*color:\\s*(?:#639|rebeccapurple)`, 'i'),
      'SSR CSS',
    )
    assert.notEqual(serverCss.filename, clientCss.filename)

    for (const filename of [prerendered, staticPage]) {
      const html = fs.readFileSync(filename, 'utf8')
      assert.match(html, /SvelteKit ZigCSS/)
      assert.match(html, new RegExp(`class=["']${escapedClassName}["']`))
    }
    requireSingleContaining(
      findRegularFiles(clientRoot, '.js'),
      new RegExp(`${escapedClassName}.*SvelteKit ZigCSS|SvelteKit ZigCSS.*${escapedClassName}`),
      'client CSS Module JavaScript',
    )
    const serverJavaScriptFiles = findRegularFiles(serverRoot, '.js')
    assert.notEqual(serverJavaScriptFiles.length, 0, 'SSR output must contain JavaScript')
    const serverJavaScript = serverJavaScriptFiles
      .map(filename => fs.readFileSync(filename, 'utf8'))
      .join('\n')
    assert.match(serverJavaScript, new RegExp(escapedClassName), 'SSR JavaScript must retain the CSS Module binding')
    assert.match(serverJavaScript, /SvelteKit ZigCSS/, 'SSR JavaScript must retain the rendered component')
    requireNativeSourceMap(clientRoot, 'client output')
    requireNativeSourceMap(serverRoot, 'SSR output')

    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'runtime-start'), true)
    assert.equal(records.some(record => record.event === 'runtime-summary'), true)
    assert.equal(records.some(record => record.event === 'native-spawn'), true)
    assert.equal(records.some(record => record.event === 'svelte-worker'), true)
    assert.equal(records.some(record => record.event.startsWith('network-denied:')), false)
    assert.equal(records.some(record => record.event.startsWith('process-denied:')), false)
    assert.equal(records.every(record => record.networkAttempts === 0), true)
    assert.equal(records.every(record => record.deniedProcessAttempts === 0), true)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'SvelteKit temp root must be fully removed')
})
