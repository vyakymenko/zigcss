import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const exampleRoot = path.join(repositoryRoot, 'examples', 'astro')
const preload = path.join(repositoryRoot, 'scripts', 'astro-offline-preload.cjs')
const expectedFiles = Object.freeze([
  'README.md',
  'astro.config.mjs',
  'package-lock.json',
  'package.json',
  'src/pages/index.astro',
  'src/styles/_tokens.scss',
  'src/styles/card.module.scss',
  'src/styles/spark.svg',
])
const expectedHostVersions = Object.freeze({ astro: '7.2.10' })
const expectedEsbuildVersion = '0.28.2'
const expectedNodeEngine = '>=22.12.0'
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
const expectedConfig = `import { defineConfig } from 'astro/config'
import zigcss from 'zigcss/vite'

export default defineConfig({
  output: 'static',
  vite: {
    plugins: [zigcss({ maxWorkers: 2, sourceMap: true })],
    build: {
      assetsInlineLimit: 0,
      sourcemap: true,
    },
  },
})
`
const expectedPage = `---
import styles from '../styles/card.module.scss'
---

<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width" />
    <title>Astro ZigCSS</title>
  </head>
  <body>
    <main class={styles.hero}>
      <h1>Astro ZigCSS</h1>
    </main>
  </body>
</html>

<script>
  import styles from '../styles/card.module.scss'
  document.documentElement.dataset.zigcssClass = styles.hero
</script>
`
const expectedEntry = '@use "tokens";\n\n.hero {\n  color: tokens.$accent;\n  background-image: url("./spark.svg");\n}\n'
const expectedDependency = '$accent: rebeccapurple;\n'
const expectedAsset = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">\n  <path fill="#663399" d="M16 0l3.9 11.1L32 16l-12.1 4.9L16 32l-3.9-11.1L0 16l12.1-4.9z"/>\n</svg>\n'

function readJson(filename) {
  return JSON.parse(fs.readFileSync(filename, 'utf8'))
}

function collectRegularFiles(root, directory = root) {
  const files = []
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name)
    assert.equal(entry.isSymbolicLink(), false, `entry must not be a symlink: ${absolute}`)
    if (entry.isDirectory()) files.push(...collectRegularFiles(root, absolute))
    else {
      assert.equal(entry.isFile(), true, `entry must be a regular file: ${absolute}`)
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
    config: fs.readFileSync(path.join(exampleRoot, 'astro.config.mjs'), 'utf8'),
    readme: fs.readFileSync(path.join(exampleRoot, 'README.md'), 'utf8'),
    page: fs.readFileSync(path.join(exampleRoot, 'src', 'pages', 'index.astro'), 'utf8'),
    entry: fs.readFileSync(path.join(exampleRoot, 'src', 'styles', 'card.module.scss'), 'utf8'),
    dependency: fs.readFileSync(path.join(exampleRoot, 'src', 'styles', '_tokens.scss'), 'utf8'),
    asset: fs.readFileSync(path.join(exampleRoot, 'src', 'styles', 'spark.svg'), 'utf8'),
    preload: fs.readFileSync(preload, 'utf8'),
  }
}

export function validateExampleContract(contract) {
  assert.deepEqual(contract.files, [...expectedFiles])
  assert.equal(contract.manifest.name, 'zigcss-astro-example')
  assert.equal(contract.manifest.private, true)
  assert.equal(contract.manifest.type, 'module')
  assert.deepEqual(contract.manifest.engines, { node: expectedNodeEngine })
  assert.deepEqual(contract.manifest.scripts, { build: 'astro build' })
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
  for (const [name, version] of Object.entries(expectedHostVersions)) {
    const locked = contract.lock.packages[`node_modules/${name}`]
    assert.equal(locked.version, version)
    assert.equal(locked.dev, true)
  }
  const esbuild = contract.lock.packages['node_modules/esbuild']
  assert.equal(esbuild.version, expectedEsbuildVersion)
  assert.equal(esbuild.dev, true)
  const esbuildPlatformPackage = esbuildPlatformPackages[`${process.platform}-${process.arch}-${os.endianness()}`]
  assert.notEqual(esbuildPlatformPackage, undefined, 'current platform must have a reviewed native esbuild package')
  const esbuildPlatform = contract.lock.packages[`node_modules/${esbuildPlatformPackage}`]
  assert.equal(esbuildPlatform.version, expectedEsbuildVersion)
  assert.equal(esbuildPlatform.dev, true)
  assert.equal(esbuildPlatform.optional, true)
  assert.deepEqual(esbuildPlatform.os, [process.platform])
  assert.deepEqual(esbuildPlatform.cpu, [process.arch])
  for (const [location, locked] of Object.entries(contract.lock.packages)) {
    if (location === '') continue
    assert.equal(locked.dev, true, `${location} must remain development-only`)
    assert.match(locked.resolved, /^https:\/\/registry\.npmjs\.org\//)
    assert.match(locked.integrity, /^sha512-[A-Za-z0-9+/]+={0,2}$/)
  }

  assert.deepEqual(contract.rootManifest.dependencies, {})
  assert.equal(Object.hasOwn(contract.rootManifest, 'optionalDependencies'), false)
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './astro'), false)
  assert.equal(contract.config, expectedConfig)
  assert.equal(contract.config.indexOf("zigcss({ maxWorkers: 2, sourceMap: true })"), contract.config.lastIndexOf("zigcss({ maxWorkers: 2, sourceMap: true })"))
  assert.match(contract.config, /output: 'static'/)
  assert.match(contract.config, /assetsInlineLimit: 0/)
  assert.doesNotMatch(contract.config, /adapter|server|ssr|hmr|watch/i)

  assert.equal(contract.page, expectedPage)
  assert.equal(contract.entry, expectedEntry)
  assert.equal(contract.dependency, expectedDependency)
  assert.equal(contract.asset, expectedAsset)
  assert.doesNotMatch(contract.page, /<style|lang=["'](?:scss|sass|less|stylus?)/i)
  assert.match(contract.readme, /one deliberately narrow integration proof/)
  assert.match(contract.readme, /zig build -Doptimize=ReleaseFast/)
  assert.match(contract.readme, /npm ci --ignore-scripts/)
  assert.match(contract.readme, /ZIGCSS_ASTRO_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:astro-example/)
  assert.match(contract.readme, /pins Astro 7\.2\.10 exactly/)
  assert.match(contract.readme, /Astro 7\.2\.10 requires Node `>=22\.12\.0`/)
  assert.match(contract.readme, /CI host is pinned to Node 24\.20\.0 LTS/)
  assert.match(contract.readme, /external `card\.module\.scss`/)
  assert.match(contract.readme, /same CSS Module binding in rendered static HTML and emitted JavaScript/)
  assert.match(contract.readme, /fingerprinted SVG asset/)
  assert.match(contract.readme, /repeats `npm ci` from an isolated cache in offline mode/)
  assert.match(contract.readme, /denies every socket and DNS operation during `astro build`/)
  assert.match(contract.readme, /child-process allowlist contains only the exact canonical staged ZigCSS `--internal-node-v1` invocation and Astro's exact lock-pinned esbuild 0\.28\.2 platform service/)
  assert.match(contract.readme, /fixed arguments, project working directory, and standard streams/)
  assert.match(contract.readme, /blocks Worker and cluster process escapes, direct unsafe Node bindings, inspector activation, and public or internal network entry points/)
  assert.match(contract.readme, /JavaScript host-proof boundary, not an operating-system sandbox/)
  assert.match(contract.readme, /final trace is cleared after package resolution and bound to the actual Astro build PID/)
  assert.match(contract.readme, /current-source-checkout proof only/)
  assert.match(contract.readme, /does not claim embedded Astro `<style lang="scss">` preprocessing, dev-server HMR or watch invalidation/)
  assert.match(contract.readme, /docs\.astro\.build\/en\/reference\/configuration-reference\/#vite/)

  for (const anchor of [
    "ZIGCSS_ASTRO_OFFLINE !== '1'",
    "^zigcss-astro-(?:boundary-)?[A-Za-z0-9]{6}$",
    'const traceRoot = fs.realpathSync(__dirname)',
    'function openBoundedRegularFile(',
    'function withTraceLock(action)',
    'const count = fs.readSync(opened.descriptor, content, offset, bytes - offset, offset)',
    'if (input !== expected) fail(`${label} must equal its exact staged path`)',
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
    "record('runtime-start')",
    "process.on('exit', () => {",
    "record('runtime-summary')",
  ]) assert.ok(contract.preload.includes(anchor), `offline preload must retain ${anchor}`)
  return true
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
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
    requestId: 'astro-native-probe',
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
    input: encodeProbe(path.join(repositoryRoot, '.zigcss-astro-native-probe.scss')),
    maxBuffer: 1024 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  assert.equal(result.error, undefined, `Astro native protocol probe failed to start: ${result.error?.message}`)
  assert.equal(result.signal, null, `Astro native protocol probe terminated by ${result.signal}`)
  assert.equal(result.status, 0, Buffer.from(result.stderr ?? '').toString('utf8'))
  assert.equal(result.stderr.length, 0)
  assert.equal(result.stdout.length >= 5, true)
  assert.equal(result.stdout.readUInt32BE(0), result.stdout.length - 4)
  const response = JSON.parse(result.stdout.subarray(4).toString('utf8'))
  assert.deepEqual(Object.keys(response).sort(), ['ok', 'protocol', 'requestId', 'result'])
  assert.equal(response.protocol, 'zigcss-node-v1')
  assert.equal(response.requestId, 'astro-native-probe')
  assert.equal(response.ok, true)
  assert.equal(response.result.css, '.probe{color:red}')
  assert.equal(response.result.sourceMap, null)
}

function validateNativeBinary(input) {
  assert.equal(path.isAbsolute(input), true, 'ZIGCSS_ASTRO_NATIVE_BINARY must be absolute')
  assert.equal(path.resolve(input), input, 'ZIGCSS_ASTRO_NATIVE_BINARY must be normalized')
  const stat = fs.lstatSync(input)
  assert.equal(stat.isFile(), true, 'Astro native binary must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'Astro native binary must not be a symlink')
  assert.equal(fs.realpathSync(input), input, 'Astro native binary must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'Astro native binary must be executable')
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
  const stagedPreload = path.join(temporary, path.basename(preload))
  fs.copyFileSync(preload, stagedPreload)
  const env = {
    ...installEnv,
    ASTRO_TELEMETRY_DISABLED: '1',
    ESBUILD_BINARY_PATH: allowedEsbuildBinary ?? '',
    NODE_OPTIONS: `--require=${JSON.stringify(fs.realpathSync(stagedPreload))}`,
    ZIGCSS_ASTRO_OFFLINE: '1',
    ZIGCSS_ASTRO_TRACE: trace,
    ZIGCSS_ASTRO_TRACE_ROOT: temporary,
    npm_config_offline: 'true',
  }
  delete env.ZIGCSS_ASTRO_ALLOWED_BINARY
  delete env.ZIGCSS_ASTRO_ALLOWED_ESBUILD_BINARY
  if (allowedBinary !== undefined) env.ZIGCSS_ASTRO_ALLOWED_BINARY = allowedBinary
  if (allowedEsbuildBinary !== undefined) {
    env.ZIGCSS_ASTRO_ALLOWED_ESBUILD_BINARY = allowedEsbuildBinary
  }
  return env
}

function clearRegularTrace(trace) {
  const descriptor = fs.openSync(
    trace,
    fs.constants.O_WRONLY | (fs.constants.O_CLOEXEC ?? 0) |
      (fs.constants.O_NOFOLLOW ?? 0) | (fs.constants.O_NONBLOCK ?? 0),
  )
  try {
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const bound = fs.lstatSync(trace, { bigint: true })
    assert.equal(opened.isFile(), true)
    assert.equal(bound.isFile(), true)
    assert.equal(bound.isSymbolicLink(), false)
    assert.equal(opened.nlink, 1n)
    assert.equal(bound.nlink, 1n)
    assert.equal(opened.dev, bound.dev)
    assert.equal(opened.ino, bound.ino)
    fs.ftruncateSync(descriptor, 0)
    const cleared = fs.fstatSync(descriptor, { bigint: true })
    assert.equal(cleared.dev, opened.dev)
    assert.equal(cleared.ino, opened.ino)
    assert.equal(cleared.size, 0n)
  } finally {
    fs.closeSync(descriptor)
  }
}

function resolveEsbuildBinary(project) {
  const packageName = esbuildPlatformPackages[`${process.platform}-${process.arch}-${os.endianness()}`]
  assert.notEqual(packageName, undefined, 'current platform must have a reviewed native esbuild package')
  const packageRoot = path.join(project, 'node_modules', ...packageName.split('/'))
  const manifestFile = path.join(packageRoot, 'package.json')
  const manifestStat = fs.lstatSync(manifestFile)
  assert.equal(manifestStat.isFile(), true)
  assert.equal(manifestStat.isSymbolicLink(), false)
  assert.equal(fs.realpathSync(manifestFile), manifestFile)
  const manifest = readJson(manifestFile)
  assert.equal(manifest.name, packageName)
  assert.equal(manifest.version, expectedEsbuildVersion)
  assert.deepEqual(manifest.os, [process.platform])
  assert.deepEqual(manifest.cpu, [process.arch])
  const binary = path.join(packageRoot, process.platform === 'win32' ? 'esbuild.exe' : path.join('bin', 'esbuild'))
  const stat = fs.lstatSync(binary)
  assert.equal(stat.isFile(), true, 'platform esbuild must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'platform esbuild must not be a symlink')
  assert.equal(stat.nlink, 1, 'platform esbuild must have exactly one hard link')
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

function sourceIndex(map, basename) {
  const matches = map.sources
    .map((source, index) => ({ source: source.replaceAll('\\', '/'), index }))
    .filter(item => item.source.endsWith(`/${basename}`))
  assert.equal(matches.length, 1, `source map must contain one ${basename} source`)
  return matches[0].index
}

function requireNativeSourceMap(root) {
  const maps = findRegularFiles(root, '.map').map(filename => ({ filename, map: readJson(filename) }))
  const candidates = maps
    .filter(({ map }) => Array.isArray(map.sources) && (
      map.sources.some(source => source.replaceAll('\\', '/').endsWith('/card.module.scss')) &&
      map.sources.some(source => source.replaceAll('\\', '/').endsWith('/_tokens.scss'))
    ))
  assert.equal(candidates.length, 1, `Astro output must contain one native ZigCSS map chain: ${JSON.stringify(maps.map(({ filename, map }) => ({
    filename: path.relative(root, filename),
    sources: map.sources,
  })))}`)
  const { map } = candidates[0]
  assert.equal(map.version, 3)
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

test('Astro 7.2.10 example is a static external CSS Module current-checkout contract', () => {
  assert.equal(validateExampleContract(loadExampleContract()), true)
})

test('Astro example rejects mutable hosts embedded styles runtime dependencies and generalized claims', () => {
  const mutations = [
    contract => { contract.manifest.devDependencies.astro = '^7.2.10' },
    contract => { contract.manifest.engines.node = '>=22' },
    contract => { contract.manifest.dependencies = { astro: '7.2.10' } },
    contract => { contract.lock.packages['node_modules/astro'].dev = false },
    contract => { contract.lock.packages['node_modules/esbuild'].version = '0.28.1' },
    contract => { contract.lock.packages[''].devDependencies.astro = '^7.2.10' },
    contract => { contract.config = contract.config.replace('sourceMap: true', 'sourceMap: false') },
    contract => { contract.config = contract.config.replace('assetsInlineLimit: 0', 'assetsInlineLimit: 4096') },
    contract => { contract.config = contract.config.replace("output: 'static'", "output: 'server'") },
    contract => { contract.page += '\n<style lang="scss">.leak { color: red; }</style>\n' },
    contract => { contract.entry = contract.entry.replace('@use "tokens";\n\n', '') },
    contract => { contract.readme = contract.readme.replace('dev-server HMR or watch invalidation', 'complete HMR and watch invalidation') },
    contract => { contract.preload = contract.preload.replace("immutable(globalThis, 'fetch', reject('globalThis.fetch'))", '') },
    contract => { contract.preload = contract.preload.replace("immutable(net.Server.prototype, 'listen', deny('net.Server.listen'))", '') },
    contract => { contract.preload = contract.preload.replace("return denyProcess('worker_threads.Worker')", "return Reflect.construct(workerThreads.Worker, arguments)") },
    contract => { contract.preload = contract.preload.replace("immutable(childProcess, 'spawn', function guardedNativeSpawn", "immutable(childProcess, 'spawn', function unguardedSpawn") },
    contract => { contract.preload = contract.preload.replace('writable: false', 'writable: true') },
    contract => { contract.preload = contract.preload.replace("record('esbuild-spawn')", '') },
    contract => { contract.rootManifest.exports['./astro'] = './adapters/vite.mjs' },
    contract => { contract.files.push('src/pages/embedded.astro') },
  ]
  for (const mutate of mutations) {
    const changed = structuredClone(loadExampleContract())
    mutate(changed)
    assert.throws(() => validateExampleContract(changed))
  }
})

test('an explicitly configured incompatible Astro native binary fails closed', { skip: process.platform === 'win32' }, t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-astro-incompatible-')))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const missing = path.join(temporary, 'missing-zigcss')
  assert.throws(() => validateNativeBinary(missing))
  const incompatible = path.join(temporary, 'zigcss')
  fs.writeFileSync(incompatible, '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "zigcss 0.6.0"; exit 0; fi\necho "unknown option: $1" >&2\nexit 1\n', { mode: 0o755 })
  assert.throws(() => validateNativeBinary(incompatible))
})

test('Astro offline preload behaviorally blocks network sockets and child-process escapes', () => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-astro-boundary-')))
  const trace = path.join(temporary, 'offline-trace.jsonl')
  const userConfig = path.join(temporary, 'npmrc')
  try {
    fs.writeFileSync(trace, '', { mode: 0o600 })
    fs.writeFileSync(userConfig, 'audit=false\nfund=false\nignore-scripts=true\nupdate-notifier=false\n', { mode: 0o600 })
    const env = offlineEnvironment(installEnvironment(temporary, userConfig), temporary, trace)
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
    requireSuccess(raceProbe, 'concurrent Astro trace metadata mutation probe')

    const unadmittedTrace = path.join(temporary, 'unadmitted-trace.jsonl')
    fs.writeFileSync(unadmittedTrace, 'sentinel\n', { mode: 0o600 })
    const deniedTrace = run(process.execPath, ['-e', 'process.exit(0)'], {
      env: { ...env, ZIGCSS_ASTRO_TRACE: unadmittedTrace },
      timeout: 5_000,
    })
    assert.equal(deniedTrace.status, 1)
    assert.match(deniedTrace.stderr, /trace file must use the admitted fixed filename/)
    assert.equal(fs.readFileSync(unadmittedTrace, 'utf8'), 'sentinel\n')
    const linkedTrace = path.join(temporary, 'linked-trace.jsonl')
    fs.linkSync(trace, linkedTrace)
    const deniedLinkedTrace = run(process.execPath, ['-e', 'process.exit(0)'], { env, timeout: 5_000 })
    assert.equal(deniedLinkedTrace.status, 1)
    assert.match(deniedLinkedTrace.stderr, /bounded canonical singly-linked regular non-symlink file/)
    fs.unlinkSync(linkedTrace)

    const deniedHttps = run(process.execPath, ['-e', "require('node:https').get('https://example.com')"], {
      env,
      timeout: 5_000,
    })
    assert.equal(deniedHttps.signal, null)
    assert.equal(deniedHttps.status, 1)
    assert.match(deniedHttps.stderr, /Astro offline test blocked https\.get/)

    const endpoint = process.platform === 'win32'
      ? `\\\\.\\pipe\\zigcss-astro-${process.pid}`
      : path.join(temporary, 'probe.sock')
    const deniedSocket = run(process.execPath, ['-e', [
      "const net = require('node:net')",
      'net.createServer().listen(process.argv[1])',
    ].join('\n'), endpoint], { env, timeout: 5_000 })
    assert.equal(deniedSocket.signal, null)
    assert.equal(deniedSocket.status, 1)
    assert.match(deniedSocket.stderr, /Astro offline test blocked net\.Server\.listen/)
    if (process.platform !== 'win32') assert.equal(fs.existsSync(endpoint), false)

    const deniedChildren = run(process.execPath, ['-e', [
      "const childProcess = require('node:child_process')",
      "const cleared = { env: { ...process.env, NODE_OPTIONS: '' } }",
      'const probes = [',
      "  ['spawn', () => childProcess.spawn(process.execPath, ['-e', 'process.exit(0)'], cleared)],",
      "  ['spawnSync', () => childProcess.spawnSync(process.execPath, ['-e', 'process.exit(0)'], cleared)],",
      "  ['exec', () => childProcess.exec('exit 0', cleared)],",
      "  ['execSync', () => childProcess.execSync('exit 0', cleared)],",
      "  ['execFile', () => childProcess.execFile(process.execPath, ['-e', 'process.exit(0)'], cleared)],",
      "  ['execFileSync', () => childProcess.execFileSync(process.execPath, ['-e', 'process.exit(0)'], cleared)],",
      "  ['fork', () => childProcess.fork(process.argv[1], [], cleared)],",
      "  ['ChildProcess.prototype.spawn', () => new childProcess.ChildProcess().spawn({ file: process.execPath, args: [process.execPath, '-e', 'process.exit(0)'] })],",
      ']',
      'const results = probes.map(([name, probe]) => {',
      "  try { probe(); return `${name}:allowed` } catch (error) { return `${name}:${error.code}` }",
      '})',
      "if (results.some(result => !result.endsWith(':ZIGCSS_PROCESS_DISABLED'))) throw new Error(JSON.stringify(results))",
      "process.stdout.write(JSON.stringify(results.map(result => result.split(':')[0])))",
    ].join('\n'), path.join(temporary, 'never-run.mjs')], { env, timeout: 5_000 })
    requireSuccess(deniedChildren, 'child-process boundary probes')
    assert.deepEqual(JSON.parse(deniedChildren.stdout), [
      'spawn',
      'spawnSync',
      'exec',
      'execSync',
      'execFile',
      'execFileSync',
      'fork',
      'ChildProcess.prototype.spawn',
    ])

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
    requireSuccess(deniedBoundary, 'Astro process and network boundary probes')
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
        const stat = fs.lstatSync(filename)
        return stat.isFile() && !stat.isSymbolicLink()
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
      assert.match(deniedCurl.stderr, /Astro offline test blocked child_process\.spawnSync/)
    }

    const records = parseTrace(trace)
    assert.equal(records.some(record => record.event === 'network-denied:https.get'), true)
    assert.equal(records.some(record => record.event === 'network-denied:net.Server.listen'), true)
    assert.equal(records.filter(record => record.event.startsWith('network-denied:')).length >= 2, true)
    for (const event of [
      'process-denied:worker_threads.Worker',
      'process-denied:cluster.fork',
      'process-denied:process.kill',
      'process-denied:process.binding:process_wrap',
      'process-denied:process.binding:invalid',
      'process-denied:process._linkedBinding',
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
    for (const operation of [
      'spawn',
      'spawnSync',
      'exec',
      'execSync',
      'execFile',
      'execFileSync',
      'fork',
      'ChildProcess.prototype.spawn',
    ]) {
      assert.equal(records.some(record => record.event === `process-denied:child_process.${operation}`), true)
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'Astro boundary temp root must be fully removed')
})

test('current native ZigCSS completes cached-offline deny-network Astro production build', t => {
  const binaryInput = process.env.ZIGCSS_ASTRO_NATIVE_BINARY
  if (binaryInput === undefined) {
    t.skip('set exact absolute ZIGCSS_ASTRO_NATIVE_BINARY after building the current checkout')
    return
  }
  const binary = validateNativeBinary(binaryInput)
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-astro-')))
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
    const warmInstall = run(npmCommand, ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--prefer-offline'], {
      cwd: project,
      env: installEnv,
    })
    requireSuccess(warmInstall, 'isolated pinned Astro cache warmup')
    fs.rmSync(path.join(project, 'node_modules'), { recursive: true, force: true })
    const offlineInstall = run(npmCommand, ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--offline'], {
      cwd: project,
      env: { ...installEnv, npm_config_offline: 'true' },
    })
    requireSuccess(offlineInstall, 'cached-offline pinned Astro installation')

    const stagedPackage = stageCurrentPackage(project, binary)
    const esbuildBinary = resolveEsbuildBinary(project)
    assert.equal(readJson(path.join(project, 'node_modules', 'astro', 'package.json')).version, expectedHostVersions.astro)
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
    const resolutionRecords = parseTrace(trace)
    assert.equal(Number.isSafeInteger(resolution.pid) && resolution.pid > 0, true)
    assert.equal(resolutionRecords.every(record => record.pid === resolution.pid), true)
    assert.equal(resolutionRecords.filter(record => record.event === 'runtime-start').length, 1)
    assert.equal(resolutionRecords.filter(record => record.event === 'runtime-summary').length, 1)
    assert.equal(resolutionRecords.every(record => record.nativeSpawns === 0), true)
    clearRegularTrace(trace)

    const astroManifest = readJson(path.join(project, 'node_modules', 'astro', 'package.json'))
    assert.equal(typeof astroManifest.bin.astro, 'string')
    const astroCli = path.join(project, 'node_modules', 'astro', astroManifest.bin.astro)
    const build = run(process.execPath, [astroCli, 'build'], { cwd: project, env })
    requireSuccess(build, 'deny-network Astro static production build')

    const outputRoot = path.join(project, 'dist')
    const html = fs.readFileSync(path.join(outputRoot, 'index.html'), 'utf8')
    assert.match(html, /Astro ZigCSS/)
    const cssFiles = findRegularFiles(outputRoot, '.css')
    assert.equal(cssFiles.length, 1, `expected one Astro CSS asset, received ${cssFiles.length}`)
    const css = fs.readFileSync(cssFiles[0], 'utf8')
    assert.match(css, /color:\s*(?:#639|rebeccapurple)/i)
    const classMatch = css.match(/\.(_hero_[A-Za-z0-9_-]+)\s*\{/)
    assert.notEqual(classMatch, null, 'Astro CSS must contain a scoped CSS Module class')
    const escapedClassName = classMatch[1].replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    assert.match(html, new RegExp(`class=["']${escapedClassName}["']`))
    const clientModules = findRegularFiles(outputRoot, '.js')
      .map(filename => fs.readFileSync(filename, 'utf8'))
      .filter(source => source.includes(classMatch[1]) && source.includes('zigcssClass'))
    assert.equal(clientModules.length, 1, 'Astro client JavaScript must retain the same CSS Module binding')

    const urlMatch = css.match(/url\((?:["'])?([^"')]*spark[^"')]*\.svg)(?:["'])?\)/i)
    assert.notEqual(urlMatch, null, 'Astro CSS must retain a rebased fingerprinted SVG URL')
    assert.notEqual(urlMatch[1], './spark.svg')
    const assetPath = urlMatch[1].startsWith('/')
      ? path.join(outputRoot, urlMatch[1].slice(1))
      : path.resolve(path.dirname(cssFiles[0]), urlMatch[1])
    assert.equal(fs.readFileSync(assetPath, 'utf8'), expectedAsset)
    assert.match(path.basename(assetPath), /^spark\.[A-Za-z0-9_-]+\.svg$/)
    requireNativeSourceMap(outputRoot)

    const records = parseTrace(trace)
    assert.equal(Number.isSafeInteger(build.pid) && build.pid > 0, true)
    assert.equal(records.length > 0, true)
    assert.equal(records.every(record => record.pid === build.pid), true, 'final trace must belong only to the Astro build PID')
    assert.equal(records.filter(record => record.event === 'runtime-start').length, 1)
    assert.equal(records.filter(record => record.event === 'runtime-summary').length, 1)
    assert.equal(records.some(record => record.event.startsWith('network-denied:')), false)
    assert.equal(records.every(record => record.networkAttempts === 0), true)
    assert.equal(records.some(record => record.event.startsWith('process-denied:')), false)
    assert.equal(records.every(record => record.deniedProcessAttempts === 0), true)
    const nativeSpawnRecords = records.filter(record => record.event === 'native-spawn')
    assert.equal(nativeSpawnRecords.length >= 2, true, 'Astro build must invoke current native ZigCSS for server and client CSS Modules')
    const esbuildSpawnRecords = records.filter(record => record.event === 'esbuild-spawn')
    assert.equal(esbuildSpawnRecords.length, 1, 'Astro build must use exactly one lock-pinned esbuild service')
    const summary = records.find(record => record.event === 'runtime-summary')
    assert.equal(summary.nativeSpawns, nativeSpawnRecords.length)
    assert.equal(summary.esbuildSpawns, 1)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'Astro temp root must be fully removed')
})
