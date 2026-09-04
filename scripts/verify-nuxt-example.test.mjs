import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const exampleRoot = path.join(repositoryRoot, 'examples', 'nuxt')
const preload = path.join(repositoryRoot, 'scripts', 'nuxt-offline-preload.cjs')
const expectedFiles = Object.freeze([
  'README.md',
  'app/app.vue',
  'app/assets/_tokens.scss',
  'app/assets/badge.svg',
  'app/assets/card.module.scss',
  'nuxt.config.ts',
  'package-lock.json',
  'package.json',
])
const expectedHostVersions = Object.freeze({
  cac: '6.7.14',
  commander: '15.0.0',
  nuxt: '4.5.2',
  vue: '3.5.42',
  'vue-router': '5.3.0',
})
const expectedNodeEngine = '^22.19.0 || ^24.11.0 || >=26.0.0'
const expectedEsbuildVersion = '0.28.2'
const expectedConfig = `import zigcss from 'zigcss/vite'

export default defineNuxtConfig({
  compatibilityDate: '2026-08-01',
  devtools: { enabled: false },
  nitro: {
    prerender: {
      routes: ['/'],
    },
  },
  sourcemap: {
    client: true,
    server: true,
  },
  telemetry: false,
  vite: {
    plugins: [zigcss({ maxWorkers: 2, sourceMap: true })],
    build: {
      assetsInlineLimit: 0,
      sourcemap: true,
    },
  },
})
`
const expectedApp = `<script setup>
import styles from './assets/card.module.scss'
</script>

<template>
  <main :class="styles.hero">
    Nuxt ZigCSS
  </main>
</template>
`
const expectedEntry = '@use "tokens";\n\n.hero {\n  color: tokens.$accent;\n  background-image: url("./badge.svg");\n}\n'
const expectedDependency = '$accent: rebeccapurple;\n'

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
    config: fs.readFileSync(path.join(exampleRoot, 'nuxt.config.ts'), 'utf8'),
    readme: fs.readFileSync(path.join(exampleRoot, 'README.md'), 'utf8'),
    app: fs.readFileSync(path.join(exampleRoot, 'app', 'app.vue'), 'utf8'),
    entry: fs.readFileSync(path.join(exampleRoot, 'app', 'assets', 'card.module.scss'), 'utf8'),
    dependency: fs.readFileSync(path.join(exampleRoot, 'app', 'assets', '_tokens.scss'), 'utf8'),
    badge: fs.readFileSync(path.join(exampleRoot, 'app', 'assets', 'badge.svg'), 'utf8'),
    preload: fs.readFileSync(preload, 'utf8'),
  }
}

export function validateExampleContract(contract) {
  assert.deepEqual(contract.files, [...expectedFiles])
  assert.equal(contract.manifest.name, 'zigcss-nuxt-example')
  assert.equal(contract.manifest.private, true)
  assert.equal(contract.manifest.type, 'module')
  assert.deepEqual(contract.manifest.engines, { node: expectedNodeEngine })
  assert.deepEqual(contract.manifest.scripts, { build: 'nuxt build' })
  assert.deepEqual(contract.manifest.devDependencies, expectedHostVersions)
  assert.equal(Object.hasOwn(contract.manifest, 'dependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.manifest, 'peerDependencies'), false)

  assert.equal(contract.lock.name, contract.manifest.name)
  assert.equal(contract.lock.lockfileVersion, 3)
  assert.equal(contract.lock.requires, true)
  assert.deepEqual(contract.lock.packages[''].engines, { node: expectedNodeEngine })
  assert.deepEqual(contract.lock.packages[''].devDependencies, expectedHostVersions)
  assert.equal(Object.hasOwn(contract.lock.packages, 'node_modules/zigcss'), false)
  assert.equal(contract.lock.packages['node_modules/esbuild'].version, expectedEsbuildVersion)
  assert.equal(contract.lock.packages['node_modules/esbuild'].dev, true)
  for (const [name, version] of Object.entries(expectedHostVersions)) {
    const locked = contract.lock.packages[`node_modules/${name}`]
    assert.equal(locked.version, version)
    assert.equal(locked.dev, true)
  }
  for (const [location, locked] of Object.entries(contract.lock.packages)) {
    if (location === '') continue
    assert.equal(locked.dev, true, `${location} must remain development-only`)
    if (locked.inBundle === true) {
      assert.equal(location, 'node_modules/@parcel/watcher-wasm/node_modules/napi-wasm')
      assert.equal(locked.version, '1.1.0')
      assert.equal(Object.hasOwn(locked, 'resolved'), false)
      assert.equal(Object.hasOwn(locked, 'integrity'), false)
    } else {
      assert.match(locked.resolved, /^https:\/\/registry\.npmjs\.org\//)
      assert.match(locked.integrity, /^sha512-[A-Za-z0-9+/]+={0,2}$/)
    }
  }

  assert.deepEqual(contract.rootManifest.dependencies, {})
  assert.equal(Object.hasOwn(contract.rootManifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './nuxt'), false)
  assert.equal(contract.config, expectedConfig)
  assert.equal(
    contract.config.indexOf('zigcss({ maxWorkers: 2, sourceMap: true })'),
    contract.config.lastIndexOf('zigcss({ maxWorkers: 2, sourceMap: true })'),
  )
  assert.match(contract.config, /sourcemap:\s*\{\s*client: true,\s*server: true,/)
  assert.match(contract.config, /assetsInlineLimit: 0/)
  assert.doesNotMatch(contract.config, /webpack|postcss|css\.preprocessor|hmr|watch/i)

  assert.equal(contract.app, expectedApp)
  assert.equal(contract.entry, expectedEntry)
  assert.equal(contract.dependency, expectedDependency)
  assert.match(contract.badge, /<svg[^>]+viewBox="0 0 16 16"/)
  assert.doesNotMatch(contract.app, /<style|lang=["'](?:scss|sass|less|stylus?)/i)
  assert.match(contract.readme, /one deliberately narrow integration/)
  assert.match(contract.readme, /zig build -Doptimize=ReleaseFast/)
  assert.match(contract.readme, /npm ci --ignore-scripts/)
  assert.match(contract.readme, /ZIGCSS_NUXT_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:nuxt-example/)
  assert.match(contract.readme, /external `card\.module\.scss`/)
  assert.match(contract.readme, /production client, Nitro SSR, and prerender builds with source maps enabled/)
  assert.match(contract.readme, /rebases a local SVG asset/)
  assert.match(contract.readme, /denies all socket and DNS access during the host build/)
  assert.match(contract.readme, /full lock audit and the empty production graph both report zero vulnerabilities/)
  assert.match(contract.readme, /direct `cac` and `commander` pins satisfy optional Nuxt CLI peer edges/)
  assert.match(contract.readme, /Nuxt 4\.5\.2 requires Node `\^22\.19\.0 \|\| \^24\.11\.0 \|\| >=26\.0\.0`/)
  assert.match(contract.readme, /warms a private npm cache, repeats `npm ci` in strict offline mode/)
  assert.match(contract.readme, /resolves the rebased asset URL to the exact emitted file/)
  assert.match(contract.readme, /child-process allowlist contains only the exact staged ZigCSS `--internal-node-v1` compiler invocation and Nitro's exact lock-pinned esbuild 0\.28\.2 service invocation/)
  assert.match(contract.readme, /blocks Worker and cluster process escapes, direct unsafe Node bindings, inspector activation, and public or internal network entry points/)
  assert.match(contract.readme, /JavaScript host-proof boundary, not an operating-system sandbox/)
  assert.match(contract.readme, /does not claim support for embedded `<style lang="scss">` blocks, Nuxt modules, framework-specific HMR or watch invalidation/)
  assert.match(contract.readme, /current-source-checkout proof only/)
  assert.match(contract.readme, /native SCSS map chain is retained in Nuxt's intermediate Vite SSR output under `\.nuxt`/)
  assert.match(contract.readme, /does not claim a public production CSS map from Nuxt/)
  assert.match(contract.readme, /nuxt\.com\/docs\/4\.x\/getting-started\/styling/)
  assert.match(contract.readme, /nuxt\.com\/docs\/4\.x\/api\/nuxt-config/)

  for (const anchor of [
    "ZIGCSS_NUXT_OFFLINE !== '1'",
    'function immutable(target, name, value)',
    'enumerable: descriptor?.enumerable ?? true',
    'writable: false',
    "immutable(http, 'request', deny('http.request'))",
    "immutable(http, 'ClientRequest', class DisabledClientRequest",
    "immutable(http.Agent.prototype, 'createConnection', deny('http.Agent.createConnection'))",
    "immutable(https.Agent.prototype, 'createConnection', deny('https.Agent.createConnection'))",
    "immutable(http, '_connectionListener', deny('http._connectionListener'))",
    "immutable(http2, 'performServerHandshake', deny('http2.performServerHandshake'))",
    "immutable(net.Server.prototype, 'listen', deny('net.Server.listen'))",
    "immutable(workerThreads, 'Worker', class DisabledWorker",
    "return denyProcess('worker_threads.Worker')",
    "return denyProcess('cluster.fork')",
    "return denyProcess('process.kill')",
    "const blockedProcessBindings = new Set(['process_wrap', 'spawn_sync'])",
    "if (typeof name !== 'string') return denyProcess('process.binding:invalid')",
    "return denyProcess('process._linkedBinding')",
    "immutable(inspector, 'open', deny('inspector.open'))",
    "immutable(net, '_createServerHandle', deny('net._createServerHandle'))",
    "immutable(net.Server.prototype, '_listen2', deny('net.Server._listen2'))",
    "immutable(dgram, '_createSocketHandle', deny('dgram._createSocketHandle'))",
    "immutable(dgram, 'Socket', class DisabledDatagramSocket",
    "const allowedDnsConfigurationFunctions = new Set([",
    "const allowedDnsPromisesConfigurationFunctions = new Set([",
    "dns.setDefaultResultOrder('verbatim')",
    "immutable(http, 'WebSocket', DisabledWebSocket)",
    "immutable(dnsPromises, name, reject(`dns.promises.${name}`))",
    "immutable(globalThis, 'fetch', reject('globalThis.fetch'))",
    "immutable(childProcess, 'spawn', function guardedNativeSpawn",
    "immutable(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn",
    "for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild'])",
    "record('native-spawn')",
    "record('esbuild-spawn')",
    "exactDataArray(args, ['--service=0.28.2', '--ping'])",
    "ESBUILD_BINARY_PATH must equal the reviewed esbuild binary",
    "const esbuildAdmitted = esbuildSpawns === 0",
    "record('runtime-start')",
    "process.on('exit', () => {",
    "fs.closeSync(traceFd)",
  ]) assert.match(contract.preload, new RegExp(anchor.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  return true
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    timeout: options.timeout ?? 180_000,
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

function encodeProbe(sourcePath) {
  const body = Buffer.from(JSON.stringify({
    protocol: 'zigcss-node-v1',
    requestId: 'nuxt-native-probe',
    operation: 'compile',
    source: '$accent: red;.probe{color:$accent}',
    sourcePath,
    rootPaths: [path.dirname(sourcePath)],
    options: {
      syntax: 'scss',
      format: 'minified',
      sourceMap: false,
      optimize: false,
      browsers: null,
    },
  }))
  const frame = Buffer.allocUnsafe(body.length + 4)
  frame.writeUInt32BE(body.length)
  body.copy(frame, 4)
  return frame
}

function validateNativeProtocol(input) {
  const result = spawnSync(input, ['--internal-node-v1'], {
    input: encodeProbe(path.join(repositoryRoot, '.zigcss-nuxt-native-probe.scss')),
    maxBuffer: 1024 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  assert.equal(result.error, undefined, `Nuxt native protocol probe failed to start: ${result.error?.message}`)
  assert.equal(result.signal, null, `Nuxt native protocol probe terminated by ${result.signal}`)
  assert.equal(result.status, 0, Buffer.from(result.stderr ?? '').toString('utf8'))
  assert.equal(result.stderr.length, 0)
  assert.equal(result.stdout.length >= 5, true)
  assert.equal(result.stdout.readUInt32BE(0), result.stdout.length - 4)
  const response = JSON.parse(result.stdout.subarray(4).toString('utf8'))
  assert.deepEqual(Object.keys(response).sort(), ['ok', 'protocol', 'requestId', 'result'])
  assert.equal(response.protocol, 'zigcss-node-v1')
  assert.equal(response.requestId, 'nuxt-native-probe')
  assert.equal(response.ok, true)
  assert.equal(response.result.css, '.probe{color:red}')
  assert.equal(response.result.sourceMap, null)
}

function validateNativeBinary(input) {
  assert.equal(path.isAbsolute(input), true, 'ZIGCSS_NUXT_NATIVE_BINARY must be absolute')
  assert.equal(path.resolve(input), input, 'ZIGCSS_NUXT_NATIVE_BINARY must be normalized')
  const stat = fs.lstatSync(input)
  assert.equal(stat.isFile(), true, 'Nuxt native binary must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'Nuxt native binary must not be a symlink')
  assert.equal(fs.realpathSync(input), input, 'Nuxt native binary must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'Nuxt native binary must be executable')
  const expectedVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  const version = run(input, ['--version'], { timeout: 5_000 })
  requireSuccess(version, 'current native ZigCSS version probe')
  assert.equal(version.stdout.trim(), `zigcss ${expectedVersion}`)
  assert.equal(version.stderr, '')
  validateNativeProtocol(input)
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
    npm_config_prefer_offline: 'true',
    npm_config_update_notifier: 'false',
    npm_config_userconfig: userConfig,
  }
}

function offlineEnvironment(
  installEnv,
  temporary,
  trace,
  allowedBinary = undefined,
  allowedEsbuildBinary = undefined,
) {
  return {
    ...installEnv,
    NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
    NUXT_TELEMETRY_DISABLED: '1',
    ...(allowedEsbuildBinary === undefined ? {} : { ESBUILD_BINARY_PATH: allowedEsbuildBinary }),
    ZIGCSS_NUXT_OFFLINE: '1',
    ZIGCSS_NUXT_TRACE: trace,
    ZIGCSS_NUXT_TRACE_ROOT: temporary,
    ...(allowedBinary === undefined ? {} : { ZIGCSS_NUXT_ALLOWED_BINARY: allowedBinary }),
    ...(allowedEsbuildBinary === undefined ? {} : {
      ZIGCSS_NUXT_ALLOWED_ESBUILD_BINARY: allowedEsbuildBinary,
    }),
    npm_config_offline: 'true',
  }
}

const esbuildPlatformPackages = Object.freeze({
  'aix-ppc64-BE': '@esbuild/aix-ppc64',
  'darwin-arm64-LE': '@esbuild/darwin-arm64',
  'darwin-x64-LE': '@esbuild/darwin-x64',
  'freebsd-arm64-LE': '@esbuild/freebsd-arm64',
  'freebsd-x64-LE': '@esbuild/freebsd-x64',
  'linux-arm-LE': '@esbuild/linux-arm',
  'linux-arm64-LE': '@esbuild/linux-arm64',
  'linux-ia32-LE': '@esbuild/linux-ia32',
  'linux-loong64-LE': '@esbuild/linux-loong64',
  'linux-mips64el-LE': '@esbuild/linux-mips64el',
  'linux-ppc64-LE': '@esbuild/linux-ppc64',
  'linux-riscv64-LE': '@esbuild/linux-riscv64',
  'linux-s390x-BE': '@esbuild/linux-s390x',
  'linux-x64-LE': '@esbuild/linux-x64',
  'netbsd-arm64-LE': '@esbuild/netbsd-arm64',
  'netbsd-x64-LE': '@esbuild/netbsd-x64',
  'openbsd-arm64-LE': '@esbuild/openbsd-arm64',
  'openbsd-x64-LE': '@esbuild/openbsd-x64',
  'sunos-x64-LE': '@esbuild/sunos-x64',
  'win32-arm64-LE': '@esbuild/win32-arm64',
  'win32-ia32-LE': '@esbuild/win32-ia32',
  'win32-x64-LE': '@esbuild/win32-x64',
})

function resolveEsbuildBinary(project) {
  const packageName = esbuildPlatformPackages[`${process.platform}-${process.arch}-${os.endianness()}`]
  assert.notEqual(packageName, undefined, 'current platform must have a reviewed native esbuild package')
  const packageRoot = path.join(project, 'node_modules', ...packageName.split('/'))
  const manifest = readJson(path.join(packageRoot, 'package.json'))
  assert.equal(manifest.name, packageName)
  assert.equal(manifest.version, expectedEsbuildVersion)
  const binary = path.join(packageRoot, process.platform === 'win32' ? 'esbuild.exe' : path.join('bin', 'esbuild'))
  const stat = fs.lstatSync(binary)
  assert.equal(stat.isFile(), true, 'platform esbuild must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'platform esbuild must not be a symlink')
  assert.equal(fs.realpathSync(binary), binary, 'platform esbuild must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'platform esbuild must be executable')
  const version = run(binary, ['--version'], { timeout: 5_000 })
  requireSuccess(version, 'lock-installed esbuild version probe')
  assert.equal(version.stdout.trim(), expectedEsbuildVersion)
  assert.equal(version.stderr, '')
  return binary
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
  return { installedBinary, target }
}

function findRegularFiles(root, suffix) {
  if (!fs.existsSync(root)) return []
  return collectRegularFiles(root)
    .filter(filename => filename.endsWith(suffix))
    .map(filename => path.join(root, filename))
}

function requireSingleContaining(files, pattern, label) {
  const matches = files.filter(filename => pattern.test(fs.readFileSync(filename, 'utf8')))
  assert.equal(matches.length, 1, `${label} expected one matching file, received ${matches.length}`)
  return { filename: matches[0], source: fs.readFileSync(matches[0], 'utf8') }
}

function mapSourceRecords(map) {
  if (Array.isArray(map.sections)) {
    return map.sections.flatMap(section => mapSourceRecords(section.map))
  }
  if (!Array.isArray(map.sources)) return []
  return map.sources.map((source, index) => ({
    content: Array.isArray(map.sourcesContent) ? map.sourcesContent[index] : undefined,
    source: source.replaceAll('\\', '/'),
  }))
}

function validateSourceMapPayload(map, label) {
  assert.equal(map.version, 3, `${label} must use source map version 3`)
  if (Array.isArray(map.sections)) {
    assert.notEqual(map.sections.length, 0, `${label} indexed map must contain sections`)
    for (const [index, section] of map.sections.entries()) {
      assert.equal(typeof section, 'object')
      validateSourceMapPayload(section.map, `${label} section ${index}`)
    }
    return
  }
  assert.equal(Array.isArray(map.names), true, `${label} names must be an array`)
  assert.equal(Array.isArray(map.sources), true, `${label} sources must be an array`)
  assert.equal(typeof map.mappings, 'string', `${label} mappings must be a string`)
  assert.notEqual(map.mappings, '', `${label} mappings must not be empty`)
  assert.equal(Array.isArray(map.sourcesContent), true, `${label} must retain sourcesContent`)
  assert.equal(map.sourcesContent.length, map.sources.length)
}

function sourceMapHasMappings(map) {
  if (Array.isArray(map.sections)) return map.sections.some(section => sourceMapHasMappings(section.map))
  return typeof map.mappings === 'string' && map.mappings.length !== 0
}

function requireNativeSourceMap(root, label) {
  const inspected = findRegularFiles(root, '.map').map(filename => {
    try {
      const map = readJson(filename)
      const records = mapSourceRecords(map)
      return { filename, map, records }
    } catch {
      return null
    }
  })
  const candidates = inspected.filter(candidate => candidate !== null && sourceMapHasMappings(candidate.map) && (
    candidate.records.some(record => record.source.endsWith('/card.module.scss')) &&
    candidate.records.some(record => record.source.endsWith('/_tokens.scss'))
  ))
  const evidence = inspected.filter(candidate => candidate !== null).map(candidate => ({
    file: path.relative(root, candidate.filename),
    hasMappings: sourceMapHasMappings(candidate.map),
    sources: candidate.records.map(record => record.source),
  }))
  assert.notEqual(
    candidates.length,
    0,
    `${label} must retain a native ZigCSS map chain; inspected ${JSON.stringify(evidence)}`,
  )
  for (const { map, records } of candidates) {
    validateSourceMapPayload(map, label)
    const entry = records.filter(record => record.source.endsWith('/card.module.scss'))
    const dependency = records.filter(record => record.source.endsWith('/_tokens.scss'))
    assert.equal(entry.length, 1)
    assert.equal(dependency.length, 1)
    assert.equal(entry[0].content, expectedEntry)
    assert.equal(dependency[0].content, expectedDependency)
  }
  return candidates.map(candidate => candidate.filename)
}

function requireSourceMapSource(root, basename, expectedContent, label) {
  const candidates = findRegularFiles(root, '.map').flatMap(filename => {
    try {
      const map = readJson(filename)
      validateSourceMapPayload(map, `${label} ${path.relative(root, filename)}`)
      return mapSourceRecords(map)
        .filter(record => record.source.endsWith(`/${basename}`))
        .map(record => ({ filename, record }))
    } catch {
      return []
    }
  })
  assert.equal(candidates.length, 1, `${label} must contain exactly one ${basename} source-map record`)
  assert.equal(candidates[0].record.content, expectedContent)
  return candidates[0].filename
}

function parseTrace(filename) {
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
}

test('Nuxt 4.5.2 example is an external CSS Module current-checkout contract', () => {
  assert.equal(validateExampleContract(loadExampleContract()), true)
})

test('Nuxt example rejects mutable hosts, embedded preprocessors, other builders, and generalized claims', () => {
  const mutations = [
    contract => { contract.manifest.devDependencies.nuxt = '^4.5.2' },
    contract => { contract.manifest.engines.node = '>=22' },
    contract => { contract.manifest.dependencies = { zigcss: '0.6.0' } },
    contract => { contract.lock.packages['node_modules/nuxt'].dev = false },
    contract => { contract.lock.packages[''].devDependencies.vue = '^3.5.42' },
    contract => { contract.config = contract.config.replace('sourceMap: true', 'sourceMap: false') },
    contract => { contract.config = contract.config.replace('client: true', 'client: false') },
    contract => { contract.config += '\nexport const webpack = true\n' },
    contract => { contract.app += '\n<style lang="scss">.leak { color: red; }</style>\n' },
    contract => { contract.entry = contract.entry.replace('@use "tokens";\n\n', '') },
    contract => { contract.readme = contract.readme.replace('framework-specific HMR or watch invalidation', 'complete HMR and watch invalidation') },
    contract => { contract.preload = contract.preload.replace("immutable(globalThis, 'fetch', reject('globalThis.fetch'))", '') },
    contract => { contract.preload = contract.preload.replace("immutable(net.Server.prototype, 'listen', deny('net.Server.listen'))", '') },
    contract => { contract.preload = contract.preload.replace("return denyProcess('worker_threads.Worker')", "return Reflect.construct(workerThreads.Worker, arguments)") },
    contract => { contract.preload = contract.preload.replace('writable: false', 'writable: true') },
    contract => { contract.rootManifest.exports['./nuxt'] = './adapters/vite.mjs' },
    contract => { contract.files.push('app/assets/embedded.scss') },
  ]
  for (const mutate of mutations) {
    const changed = structuredClone(loadExampleContract())
    mutate(changed)
    assert.throws(() => validateExampleContract(changed))
  }
})

test('an explicitly configured incompatible Nuxt native binary fails closed', { skip: process.platform === 'win32' }, t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-nuxt-incompatible-')))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const missing = path.join(temporary, 'missing-zigcss')
  assert.throws(() => validateNativeBinary(missing))
  const incompatible = path.join(temporary, 'zigcss')
  const version = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  fs.writeFileSync(
    incompatible,
    `#!/bin/sh\nif [ "$1" = "--version" ]; then echo "zigcss ${version}"; exit 0; fi\necho "unknown option: $1" >&2\nexit 1\n`,
    { mode: 0o755 },
  )
  assert.throws(() => validateNativeBinary(incompatible))
})

test('Nuxt offline preload blocks external and local sockets', () => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-nuxt-network-')))
  const trace = path.join(temporary, 'offline-trace.jsonl')
  const userConfig = path.join(temporary, 'npmrc')
  try {
    fs.writeFileSync(trace, '')
    fs.writeFileSync(userConfig, 'audit=false\nfund=false\nignore-scripts=true\nupdate-notifier=false\n', { mode: 0o600 })
    const env = offlineEnvironment(installEnvironment(temporary, userConfig), temporary, trace)
    const denied = run(process.execPath, ['-e', "require('node:https').get('https://example.com')"], {
      env,
      timeout: 5_000,
    })
    assert.equal(denied.signal, null)
    assert.equal(denied.status, 1)
    assert.match(denied.stderr, /Nuxt offline test blocked https\.get/)

    const endpoint = process.platform === 'win32'
      ? `\\\\.\\pipe\\zigcss-nuxt-${process.pid}`
      : path.join(temporary, 'probe.sock')
    const deniedIpc = run(process.execPath, ['-e', [
      "const net = require('node:net')",
      'net.createServer().listen(process.argv[1])',
    ].join('\n'), endpoint], { env, timeout: 5_000 })
    assert.equal(deniedIpc.signal, null)
    assert.equal(deniedIpc.status, 1)
    assert.match(deniedIpc.stderr, /Nuxt offline test blocked net\.Server\.listen/)

    const deniedChild = run(process.execPath, ['-e', [
      "const childProcess = require('node:child_process')",
      "childProcess.spawnSync(process.execPath, ['-e', 'process.exit(0)'], { env: { ...process.env, NODE_OPTIONS: '' } })",
    ].join('\n')], { env, timeout: 5_000 })
    assert.equal(deniedChild.signal, null)
    assert.equal(deniedChild.status, 1)
    assert.match(deniedChild.stderr, /Nuxt offline test blocked child_process\.spawnSync/)

    const deniedSpawn = run(process.execPath, ['-e', [
      "const childProcess = require('node:child_process')",
      "childProcess.spawn(process.execPath, ['-e', 'process.exit(0)'], { env: { ...process.env, NODE_OPTIONS: '' } })",
    ].join('\n')], { env, timeout: 5_000 })
    assert.equal(deniedSpawn.signal, null)
    assert.equal(deniedSpawn.status, 1)
    assert.match(deniedSpawn.stderr, /Nuxt offline test blocked child_process\.spawn/)

    const forbiddenWorkerOutput = path.join(temporary, 'worker-escaped')
    const deniedBoundary = run(process.execPath, ['-e', [
      "'use strict'",
      "const childProcess = require('node:child_process')",
      "const cluster = require('node:cluster')",
      "const dgram = require('node:dgram')",
      "const dns = require('node:dns')",
      "const dnsPromises = require('node:dns/promises')",
      "const http = require('node:http')",
      "const http2 = require('node:http2')",
      "const https = require('node:https')",
      "const inspector = require('node:inspector')",
      "const net = require('node:net')",
      "const tls = require('node:tls')",
      "const workers = require('node:worker_threads')",
      'const guardedProperties = [',
      "  ['child_process.ChildProcess.prototype.spawn', childProcess.ChildProcess.prototype, 'spawn'],",
      "  ...['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild'].map(name => [`child_process.${name}`, childProcess, name]),",
      "  ['cluster.fork', cluster, 'fork'],",
      "  ['worker_threads.Worker', workers, 'Worker'],",
      "  ...['kill', 'binding', '_linkedBinding'].map(name => [`process.${name}`, process, name]),",
      "  ...['execve', '_debugProcess', '_kill'].filter(name => typeof process[name] === 'function').map(name => [`process.${name}`, process, name]),",
      "  ...['request', 'get', 'ClientRequest', 'createServer', '_connectionListener'].map(name => [`http.${name}`, http, name]),",
      "  ['http.Agent.createConnection', http.Agent.prototype, 'createConnection'],",
      "  ...['request', 'get', 'createServer'].map(name => [`https.${name}`, https, name]),",
      "  ['https.Agent.createConnection', https.Agent.prototype, 'createConnection'],",
      "  ...['connect', 'createServer', 'createSecureServer'].map(name => [`http2.${name}`, http2, name]),",
      "  ...(typeof http2.performServerHandshake === 'function' ? [['http2.performServerHandshake', http2, 'performServerHandshake']] : []),",
      "  ['inspector.open', inspector, 'open'],",
      "  ...['connect', 'createConnection', '_createServerHandle'].map(name => [`net.${name}`, net, name]),",
      "  ['net.Socket.connect', net.Socket.prototype, 'connect'],",
      "  ['net.Server.listen', net.Server.prototype, 'listen'],",
      "  ['net.Server._listen2', net.Server.prototype, '_listen2'],",
      "  ...['connect', 'createServer'].map(name => [`tls.${name}`, tls, name]),",
      "  ...['createSocket', '_createSocketHandle', 'Socket'].map(name => [`dgram.${name}`, dgram, name]),",
      "  ['globalThis.fetch', globalThis, 'fetch'],",
      "  ...(typeof http.WebSocket === 'function' ? [['http.WebSocket', http, 'WebSocket']] : []),",
      "  ...(typeof globalThis.WebSocket === 'function' ? [['globalThis.WebSocket', globalThis, 'WebSocket']] : []),",
      ']',
      "const allowedDnsConfiguration = new Set(['getDefaultResultOrder', 'getServers', 'setDefaultResultOrder'])",
      "for (const name of Object.keys(dns)) if (name !== 'Resolver' && !allowedDnsConfiguration.has(name) && typeof dns[name] === 'function') guardedProperties.push([`dns.${name}`, dns, name])",
      "guardedProperties.push(['dns.Resolver', dns, 'Resolver'])",
      "for (const name of Object.keys(dnsPromises)) if (name !== 'Resolver' && name !== 'lookup' && !allowedDnsConfiguration.has(name) && typeof dnsPromises[name] === 'function') guardedProperties.push([`dns.promises.${name}`, dnsPromises, name])",
      "guardedProperties.push(['dns.promises.lookup', dnsPromises, 'lookup'], ['dns.promises.Resolver', dnsPromises, 'Resolver'])",
      'for (const [label, target, name] of guardedProperties) {',
      '  const descriptor = Object.getOwnPropertyDescriptor(target, name)',
      "  if (descriptor === undefined || descriptor.configurable !== false || descriptor.writable !== false) throw new Error(`mutable guard descriptor: ${label}`)",
      '  const installed = descriptor.value',
      '  let assignmentBlocked = false',
      "  try { target[name] = function restoredBoundary() {} } catch (error) { assignmentBlocked = error instanceof TypeError }",
      "  if (!assignmentBlocked || target[name] !== installed) throw new Error(`replaceable guard descriptor: ${label}`)",
      '  let redefinitionBlocked = false',
      "  try { Object.defineProperty(target, name, { configurable: true, value: function restoredBoundary() {} }) } catch (error) { redefinitionBlocked = error instanceof TypeError }",
      "  if (!redefinitionBlocked || target[name] !== installed) throw new Error(`redefinable guard descriptor: ${label}`)",
      '  let deletionBlocked = false',
      '  try { delete target[name] } catch (error) { deletionBlocked = error instanceof TypeError }',
      "  if (!deletionBlocked || target[name] !== installed) throw new Error(`deletable guard descriptor: ${label}`)",
      '}',
      'let bindingCoercions = 0',
      "const coercingBinding = { [Symbol.toPrimitive]() { bindingCoercions += 1; return 'spawn_sync' }, toString() { bindingCoercions += 1; return 'spawn_sync' }, valueOf() { bindingCoercions += 1; return 'spawn_sync' } }",
      'const probes = [',
      "  ['worker_threads.Worker', () => new workers.Worker(`require('node:fs').writeFileSync(${JSON.stringify(process.argv[1])}, 'escaped')`, { eval: true, execArgv: [], env: {} })],",
      "  ['cluster.fork', () => cluster.fork({})],",
      "  ['process.kill', () => process.kill(process.pid, 0)],",
      "  ['process.binding:process_wrap', () => process.binding('process_wrap')],",
      "  ['process.binding:tcp_wrap', () => process.binding('tcp_wrap')],",
      "  ['process.binding:boxed', () => process.binding(new String('spawn_sync'))],",
      "  ['process.binding:coercing', () => process.binding(coercingBinding)],",
      "  ['process._linkedBinding', () => process._linkedBinding('tcp_wrap')],",
      "  ['inspector.open', () => inspector.open(0, '127.0.0.1', false)],",
      "  ['http.ClientRequest', () => new http.ClientRequest('http://127.0.0.1')],",
      "  ['http.Agent.createConnection', () => new http.Agent().createConnection({ host: '127.0.0.1', port: 80 })],",
      "  ['http._connectionListener', () => http._connectionListener({})],",
      "  ['net._createServerHandle', () => net._createServerHandle('127.0.0.1', 0, 4, -1, 0)],",
      "  ['net.Server._listen2', () => net.createServer()._listen2('127.0.0.1', 0, 4, -1, 0)],",
      "  ['dgram._createSocketHandle', () => dgram._createSocketHandle('127.0.0.1', 0, 'udp4', -1, 0)],",
      "  ['dgram.Socket', () => new dgram.Socket({ type: 'udp4', lookup() {} })],",
      "  ['dns.lookup', () => dns.lookup('example.com', () => {})],",
      "  ['ChildProcess.prototype.spawn', () => new childProcess.ChildProcess().spawn({ file: process.execPath, args: [process.execPath, '-e', 'process.exit(0)'] })],",
      "  ...(typeof process.execve === 'function' ? [['process.execve', () => process.execve(process.execPath, [process.execPath], {})]] : []),",
      "  ...(typeof process._debugProcess === 'function' ? [['process._debugProcess', () => process._debugProcess(process.pid)]] : []),",
      "  ...(typeof process._kill === 'function' ? [['process._kill', () => process._kill(process.pid, 0)]] : []),",
      "  ...(typeof http.WebSocket === 'function' ? [['http.WebSocket', () => new http.WebSocket('ws://127.0.0.1')]] : []),",
      "  ...(typeof http2.performServerHandshake === 'function' ? [['http2.performServerHandshake', () => http2.performServerHandshake({})]] : []),",
      "  ...(typeof globalThis.WebSocket === 'function' ? [['globalThis.WebSocket', () => new globalThis.WebSocket('ws://127.0.0.1')]] : []),",
      ']',
      'const results = probes.map(([name, probe]) => {',
      "  try { probe(); return `${name}:allowed` } catch (error) { return `${name}:${error.code}` }",
      '})',
      ';(async () => {',
      "  try { await dnsPromises.lookup('example.com'); results.push('dns.promises.lookup:allowed') }",
      "  catch (error) { results.push(`dns.promises.lookup:${error.code}`) }",
      "  const invalid = results.filter(result => !result.endsWith(':ZIGCSS_PROCESS_DISABLED') && !result.endsWith(':ZIGCSS_NETWORK_DISABLED'))",
      "  if (invalid.length !== 0) throw new Error(JSON.stringify(results))",
      "  if (bindingCoercions !== 0) throw new Error(`process.binding coerced an invalid input ${bindingCoercions} times`)",
      "  process.stdout.write(JSON.stringify(results))",
      '})().catch(error => { console.error(error); process.exitCode = 1 })',
    ].join('\n'), forbiddenWorkerOutput], { env, timeout: 5_000 })
    requireSuccess(deniedBoundary, 'Nuxt process and network boundary probes')
    assert.equal(fs.existsSync(forbiddenWorkerOutput), false)
    const boundaryResults = JSON.parse(deniedBoundary.stdout)
    assert.equal(boundaryResults.some(result => result === 'worker_threads.Worker:ZIGCSS_PROCESS_DISABLED'), true)
    assert.equal(boundaryResults.some(result => result === 'cluster.fork:ZIGCSS_PROCESS_DISABLED'), true)
    assert.equal(boundaryResults.some(result => result === 'process.binding:tcp_wrap:ZIGCSS_NETWORK_DISABLED'), true)
    assert.equal(boundaryResults.some(result => result === 'process.binding:boxed:ZIGCSS_PROCESS_DISABLED'), true)
    assert.equal(boundaryResults.some(result => result === 'process.binding:coercing:ZIGCSS_PROCESS_DISABLED'), true)
    assert.equal(boundaryResults.some(result => result === 'dns.promises.lookup:ZIGCSS_NETWORK_DISABLED'), true)

    const curlCandidates = process.platform === 'win32'
      ? [path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'curl.exe')]
      : ['/usr/bin/curl', '/usr/local/bin/curl']
    const curl = curlCandidates.find(filename => {
      try {
        return fs.lstatSync(filename).isFile() && !fs.lstatSync(filename).isSymbolicLink()
      } catch {
        return false
      }
    })
    if (curl !== undefined) {
      const deniedCurl = run(process.execPath, ['-e', [
        "const childProcess = require('node:child_process')",
        "childProcess.spawnSync(process.argv[1], ['--max-time', '1', '--silent', '--show-error', '--output', process.platform === 'win32' ? 'NUL' : '/dev/null', 'https://example.com'], { env: { ...process.env, NODE_OPTIONS: '' }, timeout: 2000 })",
      ].join('\n'), curl], { env, timeout: 5_000 })
      assert.equal(deniedCurl.signal, null)
      assert.equal(deniedCurl.status, 1)
      assert.match(deniedCurl.stderr, /Nuxt offline test blocked child_process\.spawnSync/)
    }

    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'network-denied:https.get'), true)
    assert.equal(records.some(record => record.event === 'network-denied:net.Server.listen'), true)
    assert.equal(records.filter(record => record.event.startsWith('network-denied:')).length >= 2, true)
    assert.equal(records.some(record => record.event === 'process-denied:child_process.spawnSync'), true)
    assert.equal(records.some(record => record.event === 'process-denied:child_process.spawn'), true)
    for (const event of [
      'process-denied:worker_threads.Worker',
      'process-denied:cluster.fork',
      'process-denied:process.kill',
      'process-denied:process.binding:process_wrap',
      'process-denied:process.binding:invalid',
      'process-denied:process._linkedBinding',
      'process-denied:child_process.ChildProcess.prototype.spawn',
      'network-denied:process.binding:tcp_wrap',
      'network-denied:inspector.open',
      'network-denied:http.ClientRequest',
      'network-denied:http.Agent.createConnection',
      'network-denied:http._connectionListener',
      'network-denied:net._createServerHandle',
      'network-denied:net.Server._listen2',
      'network-denied:dgram._createSocketHandle',
      'network-denied:dgram.Socket',
      'network-denied:dns.lookup',
      'network-denied:dns.promises.lookup',
    ]) assert.equal(records.some(record => record.event === event), true, `missing trace event ${event}`)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false)
})

test('current native ZigCSS completes deny-network Nuxt client Nitro prerender asset and source-map smoke', t => {
  const binaryInput = process.env.ZIGCSS_NUXT_NATIVE_BINARY
  if (binaryInput === undefined) {
    t.skip('set exact absolute ZIGCSS_NUXT_NATIVE_BINARY after building the current checkout')
    return
  }
  const binary = validateNativeBinary(binaryInput)
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-nuxt-')))
  const project = path.join(temporary, 'project')
  const trace = path.join(temporary, 'offline-trace.jsonl')
  const userConfig = path.join(temporary, 'npmrc')
  try {
    fs.cpSync(exampleRoot, project, { recursive: true, errorOnExist: true, force: false })
    assert.deepEqual(collectRegularFiles(project), [...expectedFiles])
    fs.writeFileSync(trace, '')
    fs.writeFileSync(userConfig, 'audit=false\nfund=false\nignore-scripts=true\nprefer-offline=true\nupdate-notifier=false\n', { mode: 0o600 })
    const installEnv = installEnvironment(temporary, userConfig)
    const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm'
    const warmInstall = run(npmCommand, ['ci', '--ignore-scripts', '--prefer-offline', '--no-audit', '--no-fund'], {
      cwd: project,
      env: installEnv,
    })
    requireSuccess(warmInstall, 'isolated pinned Nuxt cache warmup')
    fs.rmSync(path.join(project, 'node_modules'), { recursive: true, force: true })
    const offlineInstall = run(npmCommand, ['ci', '--ignore-scripts', '--offline', '--no-audit', '--no-fund'], {
      cwd: project,
      env: { ...installEnv, npm_config_offline: 'true' },
    })
    requireSuccess(offlineInstall, 'cached-offline pinned Nuxt installation')

    const stagedPackage = stageCurrentPackage(project, binary)
    const esbuildBinary = resolveEsbuildBinary(project)
    for (const [name, version] of Object.entries(expectedHostVersions)) {
      assert.equal(readJson(path.join(project, 'node_modules', name, 'package.json')).version, version)
    }
    const env = offlineEnvironment(
      installEnv,
      temporary,
      trace,
      stagedPackage.installedBinary,
      esbuildBinary,
    )
    const resolution = run(process.execPath, ['-e', "process.stdout.write(require.resolve('zigcss/vite'))"], {
      cwd: project,
      env,
    })
    requireSuccess(resolution, 'zigcss/vite package-subpath resolution')
    assert.equal(resolution.stdout, path.join(stagedPackage.target, 'adapters', 'vite.cjs'))
    fs.writeFileSync(trace, '')

    const nuxtCli = path.join(project, 'node_modules', 'nuxt', 'bin', 'nuxt.mjs')
    const build = run(process.execPath, [nuxtCli, 'build'], { cwd: project, env })
    requireSuccess(build, 'deny-network Nuxt production build')

    const clientRoot = path.join(project, '.output', 'public')
    const serverRoot = path.join(project, '.output', 'server')
    const intermediateSsrRoot = path.join(project, '.nuxt', 'dist', 'server')
    const clientCss = requireSingleContaining(
      findRegularFiles(clientRoot, '.css'),
      /color:\s*(?:#639|rebeccapurple)/i,
      'Nuxt client CSS',
    )
    const classMatch = clientCss.source.match(/\.([A-Za-z0-9_-]*hero[A-Za-z0-9_-]*)\s*\{[^}]*color:\s*(?:#639|rebeccapurple)/i)
    assert.notEqual(classMatch, null)
    const className = classMatch[1]

    const emittedBadges = findRegularFiles(clientRoot, '.svg')
      .filter(filename => fs.readFileSync(filename, 'utf8') === loadExampleContract().badge)
    assert.equal(emittedBadges.length, 1, 'Nuxt client output must emit the exact local badge asset once')
    const badgeBasename = path.basename(emittedBadges[0])
    const badgeReference = clientCss.source.match(/url\((?:["'])?([^"')]+\.svg)(?:["'])?\)/i)
    assert.notEqual(badgeReference, null, 'Nuxt client CSS must contain one rebased SVG URL')
    assert.equal(path.basename(badgeReference[1]), badgeBasename)
    const referencedBadge = badgeReference[1].startsWith('/')
      ? path.resolve(clientRoot, badgeReference[1].slice(1))
      : path.resolve(path.dirname(clientCss.filename), badgeReference[1])
    assert.equal(referencedBadge, emittedBadges[0], 'rebased CSS URL must resolve to the exact emitted badge')

    const prerendered = fs.readFileSync(path.join(clientRoot, 'index.html'), 'utf8')
    assert.match(prerendered, /Nuxt ZigCSS/)
    assert.match(prerendered, new RegExp(`class=["'][^"']*${className.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^"']*["']`))

    requireSingleContaining(
      findRegularFiles(clientRoot, '.js'),
      new RegExp(`${className}.*Nuxt ZigCSS|Nuxt ZigCSS.*${className}`),
      'Nuxt client CSS Module JavaScript',
    )
    const serverJavaScriptFiles = findRegularFiles(serverRoot, '.mjs')
    assert.notEqual(serverJavaScriptFiles.length, 0, 'Nitro output must contain server JavaScript')
    const serverJavaScript = serverJavaScriptFiles.map(filename => fs.readFileSync(filename, 'utf8')).join('\n')
    assert.match(serverJavaScript, new RegExp(className), 'Nitro JavaScript must retain the CSS Module binding')
    assert.match(serverJavaScript, /Nuxt ZigCSS/, 'Nitro JavaScript must retain the rendered component')
    assert.equal(fs.existsSync(path.join(serverRoot, 'index.mjs')), true, 'Nitro server entry must be emitted')
    requireNativeSourceMap(intermediateSsrRoot, 'Nuxt intermediate Vite SSR output')
    requireSourceMapSource(clientRoot, 'app.vue', expectedApp, 'Nuxt public client JavaScript maps')
    assert.notEqual(findRegularFiles(serverRoot, '.map').length, 0, 'Nitro server output must retain source maps')

    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'runtime-start'), true)
    assert.equal(records.some(record => record.event === 'runtime-summary'), true)
    assert.equal(records.some(record => record.event.startsWith('network-denied:')), false)
    assert.equal(records.every(record => record.networkAttempts === 0), true)
    assert.equal(records.some(record => record.event.startsWith('process-denied:')), false)
    assert.equal(records.every(record => record.deniedProcessAttempts === 0), true)
    const nativePids = new Set(records.filter(record => record.event === 'native-spawn').map(record => record.pid))
    assert.equal(nativePids.size, 1, 'the preload-active Nuxt process must own every native compiler spawn')
    const [nativePid] = nativePids
    assert.equal(records.some(record => record.pid === nativePid && record.event === 'runtime-start'), true)
    assert.equal(records.some(record => record.pid === nativePid && record.event === 'runtime-summary'), true)
    assert.equal(records.filter(record => record.pid === nativePid && record.event === 'native-spawn').length >= 2, true)
    assert.equal(records.filter(record => record.pid === nativePid && record.event === 'esbuild-spawn').length, 1)
    const summary = records.find(record => record.pid === nativePid && record.event === 'runtime-summary')
    assert.equal(summary.nativeSpawns, records.filter(record => record.event === 'native-spawn').length)
    assert.equal(summary.esbuildSpawns, 1)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'Nuxt temp root must be fully removed')
})
