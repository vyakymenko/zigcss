import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import dns from 'node:dns'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const exampleRoot = path.join(repositoryRoot, 'examples', 'next-turbopack')
const preload = path.join(repositoryRoot, 'scripts', 'next-webpack-offline-preload.cjs')
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
    config: require(path.join(exampleRoot, 'next.config.js')),
    dependency: fs.readFileSync(path.join(exampleRoot, 'app', '_tokens.scss'), 'utf8'),
    entry: fs.readFileSync(path.join(exampleRoot, 'app', 'styles.scss'), 'utf8'),
    files: collectRegularFiles(exampleRoot),
    lock: readJson(path.join(exampleRoot, 'package-lock.json')),
    manifest: readJson(path.join(exampleRoot, 'package.json')),
    preload: fs.readFileSync(preload, 'utf8'),
    readme: fs.readFileSync(path.join(exampleRoot, 'README.md'), 'utf8'),
    rootManifest: readJson(path.join(repositoryRoot, 'package.json')),
  }
}

function configuredWebpackRule(config) {
  const hostConfig = { module: { rules: [] } }
  const returned = config.webpack(hostConfig, {
    buildId: 'contract',
    defaultLoaders: {},
    dev: false,
    isServer: false,
    nextRuntime: undefined,
    webpack: {},
  })
  assert.equal(returned, hostConfig, 'Next webpack callback must return the same host config')
  assert.equal(hostConfig.module.rules.length, 1, 'Next webpack callback must add exactly one rule')
  return hostConfig.module.rules[0]
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
  }
  for (const [location, locked] of Object.entries(contract.lock.packages)) {
    if (location !== '') assert.equal(locked.dev, true, `${location} must remain development-only`)
  }
  assert.deepEqual(contract.rootManifest.dependencies, {})
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './next'), false)
  assert.equal(Object.hasOwn(contract.rootManifest.exports, './next-webpack'), false)

  assert.equal(typeof contract.config.webpack, 'function')
  const rule = configuredWebpackRule(contract.config)
  assert.deepEqual(Object.keys(rule).sort(), ['enforce', 'test', 'use'])
  assert.equal(typeof rule.test, 'function')
  assert.equal(rule.enforce, 'pre')
  assert.deepEqual(rule.use, [{
    loader: 'zigcss/webpack',
    options: { maxWorkers: 2, sourceMap: true },
  }])
  assert.equal(rule.test(path.join(exampleRoot, 'app', 'styles.scss')), true)
  for (const rejected of [
    path.join(exampleRoot, 'app', 'other.scss'),
    path.join(exampleRoot, 'app', 'styles.sass'),
    path.join(exampleRoot, 'styles.scss'),
    path.join(exampleRoot, 'app', 'nested', 'styles.scss'),
    path.join(exampleRoot, 'node_modules', 'foreign', 'app', 'styles.scss'),
    path.join(path.dirname(exampleRoot), 'foreign', 'app', 'styles.scss'),
    '/tmp/foreign/app/styles.scss',
    'C:\\tmp\\foreign\\app\\styles.scss',
  ]) assert.equal(rule.test(rejected), false, `webpack rule must reject ${rejected}`)

  assert.equal(contract.entry, initialEntry)
  assert.equal(contract.dependency, initialDependency)
  assert.match(contract.readme, /explicit `next build --webpack` proof/)
  assert.match(contract.readme, /ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY="\$PWD\/zig-out\/bin\/zigcss" npm run test:next-webpack-example/)
  assert.match(contract.readme, /path-confined `enforce: 'pre'`\s+rule/)
  assert.match(contract.readme, /pins `sass` 1\.101\.0 only\s+as that downstream parser/)
  assert.match(contract.readme, /records the exact\s+staged ZigCSS child process and its `--internal-node-v1` argument/)
  assert.match(contract.readme, /unchanged warm\s+build to reuse the persistent cache with zero ZigCSS invocations/)
  assert.match(contract.readme, /change `_tokens\.scss` and require both changed CSS and a\s+new native invocation/)
  assert.match(contract.readme, /not an OS sandbox/)
  assert.match(contract.readme, /does not\s+cover custom Webpack configuration under semver/)
  assert.match(contract.readme, /does not claim\s+development HMR or watch invalidation, a `zigcss\/next` export, stable 0\.6\.0\s+delivery, or compatibility with other Next\.js or Webpack versions/)
  assert.match(contract.preload, /isExactNativeSpawn\(command, args, options\)/)
  assert.match(contract.preload, /exactDataArray\(args, \['--internal-node-v1'\]\)/)
  assert.match(contract.preload, /record\('native-spawn'/)
  assert.match(contract.preload, /if \(blockedProcessBindings\.has\(name\)\)/)
  assert.match(contract.preload, /workerThreads\.Worker/)
  assert.match(contract.preload, /immutable\(workerThreads, 'Worker', class DisabledWorker/)
  assert.match(contract.preload, /denyProcess\('process\.execve'\)/)
  assert.match(contract.preload, /networkError\('process\._debugProcess'\)/)
  assert.match(contract.preload, /networkError\('process\._kill'\)/)
  assert.match(contract.preload, /denyProcess\('process\.kill'\)/)
  assert.match(contract.preload, /function immutable\(target, name, value\)/)
  assert.match(contract.preload, /enumerable: descriptor\?\.enumerable \?\? true/)
  assert.match(contract.preload, /writable: false/)
  assert.match(contract.preload, /immutable\(net, 'createConnection', deny\('net\.createConnection'\)\)/)
  assert.match(contract.preload, /immutable\(net, '_createServerHandle', deny\('net\._createServerHandle'\)\)/)
  assert.match(contract.preload, /immutable\(net\.Server\.prototype, '_listen2', deny\('net\.Server\._listen2'\)\)/)
  assert.match(contract.preload, /immutable\(dgram, '_createSocketHandle', deny\('dgram\._createSocketHandle'\)\)/)
  assert.match(contract.preload, /throw networkError\('dgram\.Socket'\)/)
  assert.match(contract.preload, /immutable\(inspector, 'open', deny\('inspector\.open'\)\)/)
  assert.match(contract.preload, /immutable\(http, 'WebSocket', DisabledWebSocket\)/)
  assert.match(contract.preload, /Object\.defineProperty\(globalThis, 'fetch'/)
  assert.match(contract.preload, /admittedFetchAssignments === 0 && process\.env\.IS_NEXT_WORKER === 'true'/)
  assert.match(contract.preload, /value\.__nextPatched === true/)
  assert.match(contract.preload, /if \(typeof name !== 'string'\) return denyProcess\('process\.binding:invalid'\)/)
  assert.match(contract.preload, /allowedDnsConfigurationFunctions/)
  assert.match(contract.preload, /for \(const name of Object\.keys\(dns\)\)/)
  assert.match(contract.preload, /process-denied:/)
  assert.match(contract.preload, /network-denied:/)
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
  if (result.error !== undefined) throw new Error(`${command} failed to start: ${result.error.message}`)
  return result
}

function requireSuccess(result, label) {
  assert.equal(result.signal, null, `${label} terminated by ${result.signal}`)
  assert.equal(result.status, 0, [label, result.stdout, result.stderr].filter(Boolean).join('\n'))
}

function encodeProbe(sourcePath) {
  const payload = Buffer.from(JSON.stringify({
    protocol: 'zigcss-node-v1',
    requestId: 'next-webpack-native-probe',
    operation: 'compile',
    source: '$accent: red;.probe{color:$accent}',
    sourcePath,
    rootPaths: [path.dirname(sourcePath)],
    options: {
      browsers: null,
      format: 'minified',
      optimize: false,
      sourceMap: false,
      syntax: 'scss',
    },
  }))
  const frame = Buffer.allocUnsafe(4 + payload.length)
  frame.writeUInt32BE(payload.length, 0)
  payload.copy(frame, 4)
  return frame
}

function validateNativeProtocol(input) {
  const result = spawnSync(input, ['--internal-node-v1'], {
    input: encodeProbe(path.join(repositoryRoot, '.zigcss-next-webpack-native-probe.scss')),
    maxBuffer: 1024 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  assert.equal(result.error, undefined, `Next Webpack native protocol probe failed: ${result.error?.message}`)
  assert.equal(result.signal, null)
  assert.equal(result.status, 0, Buffer.from(result.stderr ?? '').toString('utf8'))
  assert.equal(result.stderr.length, 0)
  assert.equal(result.stdout.readUInt32BE(0), result.stdout.length - 4)
  const response = JSON.parse(result.stdout.subarray(4).toString('utf8'))
  assert.equal(response.protocol, 'zigcss-node-v1')
  assert.equal(response.requestId, 'next-webpack-native-probe')
  assert.equal(response.ok, true)
  assert.equal(response.result.css, '.probe{color:red}')
}

function validateNativeBinary(input) {
  assert.equal(path.isAbsolute(input), true, 'ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY must be absolute')
  assert.equal(path.resolve(input), input, 'ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY must be normalized')
  const stat = fs.lstatSync(input)
  assert.equal(stat.isFile(), true, 'Next Webpack native binary must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'Next Webpack native binary must not be a symlink')
  assert.equal(stat.nlink, 1, 'Next Webpack native binary must have exactly one hard link')
  assert.equal(fs.realpathSync(input), input, 'Next Webpack native binary must be canonical')
  if (process.platform !== 'win32') assert.notEqual(stat.mode & 0o111, 0, 'native binary must be executable')
  const expectedVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
  const version = run(input, ['--version'], { timeout: 5_000 })
  requireSuccess(version, 'current native ZigCSS version probe')
  assert.equal(version.stdout.trim(), `zigcss ${expectedVersion}`)
  assert.equal(version.stderr, '')
  validateNativeProtocol(input)
  return input
}

function installEnvironment(temporary, userConfig, inherited = process.env) {
  const env = {
    ...inherited,
  }
  for (const name of Object.keys(env)) {
    if (
      /^npm_config_/i.test(name) || /^next_/i.test(name) ||
      /^zigcss_next_webpack_/i.test(name) ||
      ['NODE_ENV', 'NODE_OPTIONS', 'SASS_PATH'].includes(name.toUpperCase())
    ) delete env[name]
  }
  Object.assign(env, {
    CI: '1',
    NEXT_TELEMETRY_DISABLED: '1',
    NO_COLOR: '1',
    npm_config_audit: 'false',
    npm_config_cache: path.join(temporary, 'npm-cache'),
    npm_config_fund: 'false',
    npm_config_ignore_scripts: 'true',
    npm_config_registry: 'https://registry.npmjs.org/',
    npm_config_update_notifier: 'false',
    npm_config_userconfig: userConfig,
  })
  return env
}

function buildEnvironment(installEnv, temporary, trace, allowedBinary, buildId) {
  return {
    ...installEnv,
    NODE_OPTIONS: `--require=${JSON.stringify(preload)}`,
    ZIGCSS_NEXT_WEBPACK_ALLOWED_BINARY: allowedBinary,
    ZIGCSS_NEXT_WEBPACK_BUILD_ID: buildId,
    ZIGCSS_NEXT_WEBPACK_OFFLINE: '1',
    ZIGCSS_NEXT_WEBPACK_TRACE: trace,
    ZIGCSS_NEXT_WEBPACK_TRACE_ROOT: temporary,
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
  for (const filename of ['core.cjs', 'webpack.cjs']) {
    fs.copyFileSync(path.join(repositoryRoot, 'adapters', filename), path.join(target, 'adapters', filename))
  }
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const installedBinary = path.join(target, 'bin', binaryName)
  fs.copyFileSync(binary, installedBinary, fs.constants.COPYFILE_EXCL)
  if (process.platform !== 'win32') fs.chmodSync(installedBinary, 0o755)
  assert.deepEqual(collectRegularFiles(target), [
    'adapters/core.cjs',
    'adapters/webpack.cjs',
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
    .filter(item => item.source.endsWith(`/${basename}`) || item.source === basename)
  assert.equal(matches.length, 1, `source map must contain one ${basename} source`)
  return matches[0].index
}

function readBuildEvidence(project, expectedDependency) {
  const nextRoot = path.join(project, '.next')
  const htmlFiles = findRegularFiles(path.join(nextRoot, 'server'), '.html')
  const matchingHtml = htmlFiles.filter(filename => {
    const html = fs.readFileSync(filename, 'utf8')
    return html.includes('zigcss-current-native') && html.includes('ZigCSS + Turbopack')
  })
  assert.equal(matchingHtml.length >= 1, true, 'prerendered HTML must retain the ZigCSS class and page')

  const cssFiles = findRegularFiles(path.join(nextRoot, 'static'), '.css')
  const matchingCss = cssFiles.filter(filename => fs.readFileSync(filename, 'utf8').includes('zigcss-current-native'))
  assert.equal(matchingCss.length, 1, `expected one emitted ZigCSS stylesheet, received ${matchingCss.length}`)
  const cssFile = matchingCss[0]
  const css = fs.readFileSync(cssFile, 'utf8')
  assert.doesNotMatch(css, /@use|tokens\.\$accent/)
  if (expectedDependency === initialDependency) {
    assert.match(css, /color:(?:#639|rebeccapurple)/i)
  } else {
    assert.match(css, /color:(?:#7fff00|chartreuse)/i)
  }

  const reference = css.match(/\/\*# sourceMappingURL=([^*]+)\*\//)
  if (reference === null) return { css, cssFile, mapRetained: false }
  const mapFile = path.resolve(path.dirname(cssFile), reference[1].trim())
  assert.equal(fs.existsSync(mapFile), true, 'emitted CSS source-map reference must resolve')
  const map = readJson(mapFile)
  assert.equal(map.version, 3)
  assert.equal(Array.isArray(map.sources), true)
  assert.equal(Array.isArray(map.sourcesContent), true)
  assert.equal(map.sourcesContent.length, map.sources.length)
  assert.notEqual(map.mappings, '')
  const entryIndex = sourceIndex(map, 'styles.scss')
  const dependencyIndexes = map.sources
    .map((source, index) => ({ source: source.replaceAll('\\', '/'), index }))
    .filter(item => item.source.endsWith('/_tokens.scss') || item.source === '_tokens.scss')
    .map(item => item.index)
  const originalMapRetained = map.sourcesContent[entryIndex] === initialEntry &&
    dependencyIndexes.length === 1 && map.sourcesContent[dependencyIndexes[0]] === expectedDependency
  return { css, cssFile, mapFile, mapRetained: originalMapRetained }
}

function parseTrace(filename) {
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
}

function requireBuildTrace(trace, buildId, buildPid, allowedBinary, requireNative = true) {
  const records = parseTrace(trace)
  assert.equal(records.length > 0, true, 'build trace must not be empty')
  assert.equal(records.every(record => record.buildId === buildId), true)
  const runtimePids = new Set(records.filter(record => record.event === 'runtime-start').map(record => record.pid))
  assert.equal(runtimePids.has(buildPid), true, 'trace must contain the exact root build process')
  const native = records.filter(record => record.event === 'native-spawn')
  if (requireNative) {
    assert.equal(native.length >= 1, true, 'build must spawn the staged native ZigCSS binary')
  }
  for (const record of native) {
    assert.equal(record.command, allowedBinary)
    assert.deepEqual(record.argv, ['--internal-node-v1'])
    assert.equal(runtimePids.has(record.pid), true)
  }
  assert.equal(records.some(record => record.event === 'runtime-summary' && record.pid === buildPid), true)
  assert.equal(records.some(record => record.event.startsWith('network-denied:')), false)
  assert.equal(records.some(record => record.event.startsWith('process-denied:')), false)
  assert.equal(records.every(record => record.networkAttempts === 0), true)
  assert.equal(records.every(record => record.deniedProcessAttempts === 0), true)
  return native.length
}

function clearTrace(trace) {
  const before = fs.lstatSync(trace, { bigint: true })
  fs.writeFileSync(trace, '')
  const after = fs.lstatSync(trace, { bigint: true })
  assert.equal(after.dev, before.dev)
  assert.equal(after.ino, before.ino)
  assert.equal(after.size, 0n)
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

test('Next 16.3.4 Webpack example is an exact global-SCSS reuse of zigcss/webpack', () => {
  assert.equal(validateExampleContract(loadExampleContract()), true)

  const isolated = installEnvironment('/tmp/zigcss-next-webpack', '/tmp/zigcss-next-webpack/npmrc', {
    HOME: '/preserved-home',
    NEXT_PRIVATE_TEST_PROXY: 'ambient-next-state',
    NODE_ENV: 'development',
    NODE_OPTIONS: '--inspect',
    NPM_CONFIG_OMIT: 'dev',
    SASS_PATH: '/ambient/sass',
    ZIGCSS_NEXT_WEBPACK_OFFLINE: 'ambient-proof-state',
    npm_config_include: 'optional',
    npm_config_offline: 'true',
    npm_config_registry: 'https://registry.invalid/',
  })
  assert.equal(isolated.HOME, '/preserved-home')
  assert.equal(isolated.NEXT_PRIVATE_TEST_PROXY, undefined)
  assert.equal(isolated.NODE_ENV, undefined)
  assert.equal(isolated.NODE_OPTIONS, undefined)
  assert.equal(isolated.NPM_CONFIG_OMIT, undefined)
  assert.equal(isolated.SASS_PATH, undefined)
  assert.equal(isolated.ZIGCSS_NEXT_WEBPACK_OFFLINE, undefined)
  assert.equal(isolated.npm_config_include, undefined)
  assert.equal(isolated.npm_config_offline, undefined)
  assert.equal(isolated.npm_config_registry, 'https://registry.npmjs.org/')
})

test('Next Webpack example rejects mutable hosts broad rules wrong loader order and generalized claims', () => {
  const mutations = [
    contract => { contract.manifest.devDependencies.sass = '^1.101.0' },
    contract => { contract.manifest.scripts['build:webpack'] = 'next build' },
    contract => { contract.lock.packages['node_modules/sass'].dev = false },
    contract => { contract.manifest.dependencies = { sass: '1.101.0' } },
    contract => { contract.config.webpack = config => { config.module.rules.push({ test: /\.scss$/, enforce: 'pre', use: [{ loader: 'zigcss/webpack', options: { maxWorkers: 2, sourceMap: true } }] }); return config } },
    contract => { contract.config.webpack = config => { config.module.rules.push({ test: resource => typeof resource === 'string' && path.resolve(resource) === path.join(exampleRoot, 'app', 'styles.scss'), use: [{ loader: 'zigcss/webpack', options: { maxWorkers: 2, sourceMap: true } }] }); return config } },
    contract => { contract.config.webpack = config => { config.module.rules.push({ test: resource => typeof resource === 'string' && path.resolve(resource) === path.join(exampleRoot, 'app', 'styles.scss'), enforce: 'pre', use: [{ loader: 'zigcss/next', options: { maxWorkers: 2, sourceMap: true } }] }); return config } },
    contract => { contract.config.webpack = config => { config.module.rules.push({ test: resource => typeof resource === 'string' && path.resolve(resource) === path.join(exampleRoot, 'app', 'styles.scss'), enforce: 'pre', use: [{ loader: 'zigcss/webpack', options: { maxWorkers: 2, sourceMap: false } }] }); return config } },
    contract => { contract.config.webpack = config => { config.module.rules.push({ test: resource => typeof resource === 'string' && /(?:^|[\\/])app[\\/]styles\.scss$/.test(resource), enforce: 'pre', use: [{ loader: 'zigcss/webpack', options: { maxWorkers: 2, sourceMap: true } }] }); return config } },
    contract => { contract.readme = contract.readme.replace('does not claim\ndevelopment HMR or watch invalidation', 'claims complete\ndevelopment HMR and watch invalidation') },
    contract => { contract.preload = contract.preload.replace("exactDataArray(args, ['--internal-node-v1'])", 'true') },
    contract => { contract.preload = contract.preload.replace("record('native-spawn'", "record('unverified-spawn'") },
    contract => { contract.preload = contract.preload.replace('if (blockedProcessBindings.has(name))', 'if (false)') },
    contract => { contract.preload = contract.preload.replace("immutable(net, 'createConnection', deny('net.createConnection'))", "immutable(net, 'createConnection', net.connect)") },
    contract => { contract.preload = contract.preload.replace("immutable(inspector, 'open', deny('inspector.open'))", "immutable(inspector, 'open', inspector.open)") },
    contract => { contract.preload = contract.preload.replace("networkError('process._kill')", "networkError('process._kill-unblocked')") },
    contract => { contract.preload = contract.preload.replace('for (const name of Object.keys(dns))', 'for (const name of [])') },
    contract => { contract.preload = contract.preload.replace("immutable(workerThreads, 'Worker', class DisabledWorker", "immutable(workerThreads, 'UnsafeWorker', class DisabledWorker") },
    contract => { contract.preload = contract.preload.replace("admittedFetchAssignments === 0 && process.env.IS_NEXT_WORKER === 'true'", 'true') },
    contract => { contract.preload = contract.preload.replace('writable: false', 'writable: true') },
  ]
  for (const [index, mutate] of mutations.entries()) {
    const changed = loadExampleContract()
    mutate(changed)
    assert.throws(() => validateExampleContract(changed), `mutation ${index} must fail closed`)
  }
})

test('Next Webpack preload blocks network child-process escapes and wrong native argv', { skip: process.platform === 'win32' }, t => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-next-webpack-boundary-')))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const binary = path.join(temporary, 'project', 'node_modules', 'zigcss', 'bin', 'zigcss')
  fs.mkdirSync(path.dirname(binary), { recursive: true })
  fs.copyFileSync(process.execPath, binary, fs.constants.COPYFILE_EXCL)
  fs.chmodSync(binary, 0o755)
  const trace = path.join(temporary, 'trace.jsonl')
  fs.writeFileSync(trace, '')
  const buildId = crypto.randomBytes(16).toString('hex')
  const env = buildEnvironment(installEnvironment(temporary, path.join(temporary, 'npmrc')), temporary, trace, binary, buildId)

  const network = run(process.execPath, ['-e', "require('node:https').get('https://example.com')"], { env, timeout: 5_000 })
  assert.equal(network.status, 1)
  assert.match(network.stderr, /Next Webpack offline test blocked https\.get/)

  if (typeof dns.resolveTlsa === 'function') {
    const tlsa = run(process.execPath, ['-e', "require('node:dns').resolveTlsa('example.com', () => {})"], { env, timeout: 5_000 })
    assert.equal(tlsa.status, 1)
    assert.match(tlsa.stderr, /Next Webpack offline test blocked dns\.resolveTlsa/)
  }

  const dnsServers = run(process.execPath, ['-e', "require('node:dns').setServers(['127.0.0.1'])"], { env, timeout: 5_000 })
  assert.equal(dnsServers.status, 1)
  assert.match(dnsServers.stderr, /Next Webpack offline test blocked dns\.setServers/)

  const loopback = run(process.execPath, ['-e', "require('node:net').createConnection({ host: '127.0.0.1', port: 9 })"], { env, timeout: 5_000 })
  assert.equal(loopback.status, 1)
  assert.match(loopback.stderr, /Next Webpack offline test blocked net\.createConnection/)

  const localSocket = run(process.execPath, ['-e', "require('node:net').createConnection(process.argv[1])", path.join(temporary, 'escape.sock')], { env, timeout: 5_000 })
  assert.equal(localSocket.status, 1)
  assert.match(localSocket.stderr, /Next Webpack offline test blocked net\.createConnection/)

  const listener = run(process.execPath, ['-e', "require('node:net').createServer().listen(0, '127.0.0.1')"], { env, timeout: 5_000 })
  assert.equal(listener.status, 1)
  assert.match(listener.stderr, /Next Webpack offline test blocked net\.Server\.listen/)

  const inspectorListener = run(process.execPath, ['-e', "require('node:inspector').open(0, '127.0.0.1', false)"], { env, timeout: 5_000 })
  assert.equal(inspectorListener.status, 1)
  assert.match(inspectorListener.stderr, /Next Webpack offline test blocked inspector\.open/)

  if (typeof process._debugProcess === 'function') {
    const debugListener = run(process.execPath, ['-e', 'process._debugProcess(process.pid)'], { env, timeout: 5_000 })
    assert.equal(debugListener.status, 1)
    assert.match(debugListener.stderr, /Next Webpack offline test blocked process\._debugProcess/)
  }

  if (typeof process._kill === 'function') {
    const privateSignalListener = run(process.execPath, ['-e', "process._kill(process.pid, require('node:os').constants.signals.SIGUSR1)"], { env, timeout: 5_000 })
    assert.equal(privateSignalListener.status, 1)
    assert.match(privateSignalListener.stderr, /Next Webpack offline test blocked process\._kill/)
  }

  const signalListener = run(process.execPath, ['-e', "process.kill(process.pid, 'SIGUSR1')"], { env, timeout: 5_000 })
  assert.equal(signalListener.status, 1)
  assert.match(signalListener.stderr, /Next Webpack offline test blocked process\.kill/)

  if (typeof http.WebSocket === 'function') {
    const websocketAlias = run(process.execPath, ['-e', "new (require('node:http').WebSocket)('ws://127.0.0.1:9')"], { env, timeout: 5_000 })
    assert.equal(websocketAlias.status, 1)
    assert.match(websocketAlias.stderr, /Next Webpack offline test blocked WebSocket/)
  }

  const internalListener = run(process.execPath, ['-e', "require('node:net')._createServerHandle('127.0.0.1', 0, 4, 0)"], { env, timeout: 5_000 })
  assert.equal(internalListener.status, 1)
  assert.match(internalListener.stderr, /Next Webpack offline test blocked net\._createServerHandle/)

  const legacyListener = run(process.execPath, ['-e', "new (require('node:net').Server)()._listen2('127.0.0.1', 0, 4, 511)"], { env, timeout: 5_000 })
  assert.equal(legacyListener.status, 1)
  assert.match(legacyListener.stderr, /Next Webpack offline test blocked net\.Server\._listen2/)

  const internalDatagram = run(process.execPath, ['-e', "require('node:dgram')._createSocketHandle('udp4')"], { env, timeout: 5_000 })
  assert.equal(internalDatagram.status, 1)
  assert.match(internalDatagram.stderr, /Next Webpack offline test blocked dgram\._createSocketHandle/)

  const datagramConstructor = run(process.execPath, ['-e', "new (require('node:dgram').Socket)({ type: 'udp4', lookup: (_host, _options, callback) => callback(null, '127.0.0.1', 4) })"], { env, timeout: 5_000 })
  assert.equal(datagramConstructor.status, 1)
  assert.match(datagramConstructor.stderr, /Next Webpack offline test blocked dgram\.Socket/)

  const processEscape = run(process.execPath, ['-e', "require('node:child_process').spawnSync('/usr/bin/env', ['true'])"], { env, timeout: 5_000 })
  assert.equal(processEscape.status, 1)
  assert.match(processEscape.stderr, /Next Webpack offline test blocked child_process\.spawnSync/)

  const bindingEscape = run(process.execPath, ['-e', "process.binding('spawn_sync')"], { env, timeout: 5_000 })
  assert.equal(bindingEscape.status, 1)
  assert.match(bindingEscape.stderr, /Next Webpack offline test blocked process\.binding:spawn_sync/)

  if (typeof process.execve === 'function') {
    const execveEscape = run(process.execPath, ['-e', "process.execve('/usr/bin/true', ['true'], process.env)"], { env, timeout: 5_000 })
    assert.equal(execveEscape.status, 1)
    assert.match(execveEscape.stderr, /Next Webpack offline test blocked process\.execve/)
  }

  const bindingNetwork = run(process.execPath, ['-e', "process.binding('tcp_wrap')"], { env, timeout: 5_000 })
  assert.equal(bindingNetwork.status, 1)
  assert.match(bindingNetwork.stderr, /Next Webpack offline test blocked process\.binding:tcp_wrap/)

  const bindingInspector = run(process.execPath, ['-e', "process.binding('inspector')"], { env, timeout: 5_000 })
  assert.equal(bindingInspector.status, 1)
  assert.match(bindingInspector.stderr, /Next Webpack offline test blocked process\.binding:inspector/)

  const boundaryIntegrity = run(process.execPath, ['-e', [
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
    "  ...['request', 'get', 'createServer'].map(name => [`http.${name}`, http, name]),",
    "  ...['request', 'get', 'createServer'].map(name => [`https.${name}`, https, name]),",
    "  ...['connect', 'createServer', 'createSecureServer'].map(name => [`http2.${name}`, http2, name]),",
    "  ['inspector.open', inspector, 'open'],",
    "  ...['connect', 'createConnection', '_createServerHandle'].map(name => [`net.${name}`, net, name]),",
    "  ['net.Socket.connect', net.Socket.prototype, 'connect'],",
    "  ['net.Server.listen', net.Server.prototype, 'listen'],",
    "  ['net.Server._listen2', net.Server.prototype, '_listen2'],",
    "  ...['connect', 'createServer'].map(name => [`tls.${name}`, tls, name]),",
    "  ...['createSocket', '_createSocketHandle', 'Socket'].map(name => [`dgram.${name}`, dgram, name]),",
    "  ...(typeof http.WebSocket === 'function' ? [['http.WebSocket', http, 'WebSocket']] : []),",
    "  ...(typeof globalThis.WebSocket === 'function' ? [['globalThis.WebSocket', globalThis, 'WebSocket']] : []),",
    ']',
    "const allowedDnsConfiguration = new Set(['getDefaultResultOrder', 'getServers', 'setDefaultResultOrder'])",
    "for (const name of Object.keys(dns)) if (name !== 'Resolver' && !allowedDnsConfiguration.has(name) && typeof dns[name] === 'function') guardedProperties.push([`dns.${name}`, dns, name])",
    "guardedProperties.push(['dns.Resolver', dns, 'Resolver'])",
    "for (const name of Object.keys(dnsPromises)) if (name !== 'Resolver' && name !== 'lookup' && typeof dnsPromises[name] === 'function') guardedProperties.push([`dns.promises.${name}`, dnsPromises, name])",
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
    "const fetchDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'fetch')",
    "if (fetchDescriptor === undefined || fetchDescriptor.configurable !== false || typeof fetchDescriptor.get !== 'function' || typeof fetchDescriptor.set !== 'function') throw new Error('mutable globalThis.fetch descriptor')",
    'const installedFetch = globalThis.fetch',
    "let fetchAssignment = 'allowed'",
    "try { globalThis.fetch = async function fetch() {} } catch (error) { fetchAssignment = error.code }",
    "if (globalThis.fetch !== installedFetch) throw new Error('replaceable globalThis.fetch descriptor')",
    "let fetchRedefinition = 'allowed'",
    "try { Object.defineProperty(globalThis, 'fetch', { configurable: true, value: async function fetch() {} }) } catch (error) { fetchRedefinition = error instanceof TypeError ? 'blocked' : error.code }",
    "if (fetchRedefinition !== 'blocked' || globalThis.fetch !== installedFetch) throw new Error('redefinable globalThis.fetch descriptor')",
    "let fetchDeletion = 'allowed'",
    "try { delete globalThis.fetch } catch (error) { fetchDeletion = error instanceof TypeError ? 'blocked' : error.code }",
    "if (fetchDeletion !== 'blocked' || globalThis.fetch !== installedFetch) throw new Error('deletable globalThis.fetch descriptor')",
    'let bindingCoercions = 0',
    "const coercingBinding = { [Symbol.toPrimitive]() { bindingCoercions += 1; return 'spawn_sync' }, toString() { bindingCoercions += 1; return 'spawn_sync' }, valueOf() { bindingCoercions += 1; return 'spawn_sync' } }",
    "let boxed = 'allowed'",
    "try { process.binding(new String('spawn_sync')) } catch (error) { boxed = error.code }",
    "let coercing = 'allowed'",
    "try { process.binding(coercingBinding) } catch (error) { coercing = error.code }",
    "process.stdout.write(JSON.stringify({ boxed, coercing, bindingCoercions, fetchAssignment, guards: guardedProperties.length }))",
  ].join('\n')], { env, timeout: 5_000 })
  requireSuccess(boundaryIntegrity, 'immutable Next Webpack boundary probes')
  const boundaryIntegrityResult = JSON.parse(boundaryIntegrity.stdout)
  assert.equal(boundaryIntegrityResult.boxed, 'ZIGCSS_PROCESS_DISABLED')
  assert.equal(boundaryIntegrityResult.coercing, 'ZIGCSS_PROCESS_DISABLED')
  assert.equal(boundaryIntegrityResult.bindingCoercions, 0)
  assert.equal(boundaryIntegrityResult.fetchAssignment, 'ZIGCSS_NETWORK_DISABLED')
  assert.equal(boundaryIntegrityResult.guards >= 50, true)

  const workerEscape = run(process.execPath, ['-e', "new (require('node:worker_threads').Worker)('0', { eval: true, execArgv: [] })"], { env, timeout: 5_000 })
  assert.equal(workerEscape.status, 1)
  assert.match(workerEscape.stderr, /Next Webpack offline test blocked worker_threads\.Worker/)

  const clusterEscape = run(process.execPath, ['-e', "require('node:cluster').fork()"], { env, timeout: 5_000 })
  assert.equal(clusterEscape.status, 1)
  assert.match(clusterEscape.stderr, /Next Webpack offline test blocked cluster\.fork/)

  const wrongArgv = run(process.execPath, ['-e', [
    "const childProcess = require('node:child_process')",
    "childProcess.spawn(process.argv[1], ['--version'], { shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })",
  ].join('\n'), binary], { env, timeout: 5_000 })
  assert.equal(wrongArgv.status, 1)
  assert.match(wrongArgv.stderr, /Next Webpack offline test blocked child_process\.spawn/)

  const otherNextModule = path.join(temporary, 'project', 'node_modules', 'next', 'other.js')
  fs.mkdirSync(path.dirname(otherNextModule), { recursive: true })
  fs.writeFileSync(otherNextModule, '')
  const wrongFork = run(process.execPath, ['-e', [
    "const childProcess = require('node:child_process')",
    "childProcess.fork(process.argv[1], [], { cwd: process.cwd(), env: { ...process.env }, execArgv: [], silent: true })",
  ].join('\n'), otherNextModule], { cwd: path.join(temporary, 'project'), env, timeout: 5_000 })
  assert.equal(wrongFork.status, 1)
  assert.match(wrongFork.stderr, /Next Webpack offline test blocked child_process\.fork:module/)

  const records = parseTrace(trace)
  assert.equal(records.every(record => record.buildId === buildId), true)
  assert.equal(records.some(record => record.event === 'network-denied:https.get'), true)
  if (typeof dns.resolveTlsa === 'function') {
    assert.equal(records.some(record => record.event === 'network-denied:dns.resolveTlsa'), true)
  }
  assert.equal(records.some(record => record.event === 'network-denied:dns.setServers'), true)
  assert.equal(records.some(record => record.event === 'network-denied:net.createConnection'), true)
  assert.equal(records.some(record => record.event === 'network-denied:net.Server.listen'), true)
  assert.equal(records.some(record => record.event === 'network-denied:inspector.open'), true)
  if (typeof process._debugProcess === 'function') {
    assert.equal(records.some(record => record.event === 'network-denied:process._debugProcess'), true)
  }
  if (typeof process._kill === 'function') {
    assert.equal(records.some(record => record.event === 'network-denied:process._kill'), true)
  }
  assert.equal(records.some(record => record.event === 'process-denied:process.kill'), true)
  if (typeof http.WebSocket === 'function') {
    assert.equal(records.some(record => record.event === 'network-denied:WebSocket'), true)
  }
  assert.equal(records.some(record => record.event === 'network-denied:net._createServerHandle'), true)
  assert.equal(records.some(record => record.event === 'network-denied:net.Server._listen2'), true)
  assert.equal(records.some(record => record.event === 'network-denied:dgram._createSocketHandle'), true)
  assert.equal(records.some(record => record.event === 'network-denied:dgram.Socket'), true)
  assert.equal(records.some(record => record.event === 'network-denied:process.binding:tcp_wrap'), true)
  assert.equal(records.some(record => record.event === 'network-denied:process.binding:inspector'), true)
  assert.equal(records.some(record => record.event === 'process-denied:child_process.spawnSync'), true)
  assert.equal(records.some(record => record.event === 'process-denied:process.binding:spawn_sync'), true)
  assert.equal(records.some(record => record.event === 'process-denied:process.binding:invalid'), true)
  assert.equal(records.some(record => record.event === 'network-denied:globalThis.fetch-assignment'), true)
  if (typeof process.execve === 'function') {
    assert.equal(records.some(record => record.event === 'process-denied:process.execve'), true)
  }
  assert.equal(records.some(record => record.event === 'process-denied:worker_threads.Worker'), true)
  assert.equal(records.some(record => record.event === 'process-denied:cluster.fork'), true)
  assert.equal(records.some(record => record.event === 'process-denied:child_process.spawn'), true)
  assert.equal(records.some(record => record.event === 'process-denied:child_process.fork:module'), true)
  assert.equal(records.some(record => record.event === 'native-spawn'), false)
})

test('current native ZigCSS completes offline Next Webpack cache hit and dependency invalidation', t => {
  const binaryInput = process.env.ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY
  if (binaryInput === undefined) {
    t.skip('set exact absolute ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY after building the current checkout')
    return
  }
  const binary = validateNativeBinary(binaryInput)
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-next-webpack-')))
  const project = path.join(temporary, 'project')
  const trace = path.join(temporary, 'build-trace.jsonl')
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
    requireSuccess(warmInstall, 'isolated pinned Next Webpack cache warmup')
    fs.rmSync(path.join(project, 'node_modules'), { recursive: true, force: true })
    const offlineInstall = run(npmCommand, ['ci', '--ignore-scripts', '--no-audit', '--no-fund', '--offline'], {
      cwd: project,
      env: { ...installEnv, npm_config_offline: 'true' },
    })
    requireSuccess(offlineInstall, 'cached-offline pinned Next Webpack installation')

    const staged = stageCurrentPackage(project, binary)
    for (const [name, version] of Object.entries(expectedHostVersions)) {
      assert.equal(readJson(path.join(project, 'node_modules', name, 'package.json')).version, version)
    }
    const resolution = run(process.execPath, ['-e', "process.stdout.write(require.resolve('zigcss/webpack'))"], {
      cwd: project,
      env: installEnv,
    })
    requireSuccess(resolution, 'zigcss/webpack package-subpath resolution')
    assert.equal(resolution.stdout, path.join(staged.target, 'adapters', 'webpack.cjs'))

    const nextManifest = readJson(path.join(project, 'node_modules', 'next', 'package.json'))
    assert.equal(typeof nextManifest.bin.next, 'string')
    const nextCli = path.join(project, 'node_modules', 'next', nextManifest.bin.next)
    const build = (expectedDependency, { requireNative = true } = {}) => {
      clearTrace(trace)
      const buildId = crypto.randomBytes(16).toString('hex')
      const env = buildEnvironment(installEnv, temporary, trace, staged.installedBinary, buildId)
      const result = run(process.execPath, [nextCli, 'build', '--webpack'], { cwd: project, env })
      requireSuccess(result, 'deny-network Next Webpack production build')
      const nativeSpawns = requireBuildTrace(
        trace,
        buildId,
        result.pid,
        staged.installedBinary,
        requireNative,
      )
      return { evidence: readBuildEvidence(project, expectedDependency), nativeSpawns }
    }

    const first = build(initialDependency)
    assert.equal(first.nativeSpawns >= 1, true)
    assert.equal(first.evidence.mapRetained, false, 'final Next Webpack CSS must not retain the ZigCSS source-map chain')
    assert.equal(fs.existsSync(path.join(project, '.next', 'cache')), true, 'Next Webpack cache must exist')

    const unchanged = build(initialDependency, { requireNative: false })
    assert.equal(unchanged.nativeSpawns, 0, 'unchanged warm build must reuse the persistent cache')
    assert.equal(unchanged.evidence.css, first.evidence.css, 'unchanged warm build must preserve exact CSS')
    assert.equal(unchanged.evidence.mapRetained, false)

    const ownedSources = [...expectedFiles]
    const before = digestFiles(project, ownedSources)
    fs.writeFileSync(path.join(project, 'app', '_tokens.scss'), changedDependency)
    const after = digestFiles(project, ownedSources)
    assert.deepEqual(changedFiles(before, after), ['app/_tokens.scss'])

    const second = build(changedDependency)
    assert.equal(second.nativeSpawns >= 1, true)
    assert.equal(first.evidence.css === second.evidence.css, false, 'dependency-only rebuild must change CSS')
    assert.equal(second.evidence.mapRetained, false)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  assert.equal(fs.existsSync(temporary), false, 'Next Webpack temp root must be fully removed')
})
