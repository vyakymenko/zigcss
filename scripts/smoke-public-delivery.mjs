#!/usr/bin/env node

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)

export const publicDeliveryPolicy = Object.freeze({
  registry: 'https://registry.npmjs.org/',
  packageName: 'zigcss',
  installTimeoutMs: 5 * 60 * 1000,
  commandTimeoutMs: 45 * 1000,
  totalTimeoutMs: 10 * 60 * 1000,
  installOutputBytes: 2 * 1024 * 1024,
  commandOutputBytes: 512 * 1024,
  installedEntries: 4096,
  installedBytes: 384 * 1024 * 1024,
})

export const publicDeliveryStylesheets = Object.freeze([
  Object.freeze({
    id: 'css',
    extension: 'css',
    syntax: 'css',
    format: 'minified',
    source: '.smoke { color: red; }\n',
    expected: '.smoke{color:red}',
  }),
  Object.freeze({
    id: 'scss',
    extension: 'scss',
    syntax: 'scss',
    format: 'pretty',
    source: '$color: red;\n.scss { color: $color; }\n',
    expected: '.scss {\n  color: red;\n}\n',
  }),
  Object.freeze({
    id: 'sass',
    extension: 'sass',
    syntax: 'sass',
    format: 'pretty',
    source: '$color: red\n.sass\n  color: $color\n',
    expected: '.sass {\n  color: red;\n}\n',
  }),
  Object.freeze({
    id: 'less',
    extension: 'less',
    syntax: 'less',
    format: 'pretty',
    source: '@color: red;\n.less { color: @color; }\n',
    expected: '.less {\n  color: red;\n}\n',
  }),
  Object.freeze({
    id: 'stylus',
    extension: 'styl',
    syntax: 'stylus',
    format: 'pretty',
    source: '.styl\n  color red\n',
    expected: '.styl {\n  color: #f00;\n}\n',
  }),
])

export const publicDeliveryTargets = Object.freeze([
  Object.freeze({ target: 'x86_64-linux', extension: 'tar.gz' }),
  Object.freeze({ target: 'aarch64-linux', extension: 'tar.gz' }),
  Object.freeze({ target: 'x86_64-macos', extension: 'tar.gz' }),
  Object.freeze({ target: 'aarch64-macos', extension: 'tar.gz' }),
  Object.freeze({ target: 'x86_64-windows', extension: 'zip' }),
])

const forbiddenEnvironmentNames = new Set([
  'GH_TOKEN',
  'GITHUB_TOKEN',
  'NODE_AUTH_TOKEN',
  'NODE_OPTIONS',
  'NODE_PATH',
  'NPM_AUTH_TOKEN',
  'NPM_TOKEN',
  'YARN_AUTH_TOKEN',
  'YARN_NPM_AUTH_TOKEN',
])

function fail(message) {
  throw new Error(`public delivery smoke: ${message}`)
}

function confinedPath(root, candidate, label) {
  const resolved = path.resolve(candidate)
  const relative = path.relative(root, resolved)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the temporary consumer project`)
  }
  return resolved
}

function boundedRegularFile(root, relativePath, label, maximumBytes) {
  const candidate = confinedPath(root, path.join(root, relativePath), label)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (
    !stat.isFile()
    || stat.isSymbolicLink()
    || stat.size <= 0
    || stat.size > maximumBytes
    || fs.realpathSync(candidate) !== candidate
  ) {
    fail(`${label} must be one bounded regular non-symlink file`)
  }
  return { candidate, stat }
}

export function parsePublicDeliveryArguments(args) {
  if (!Array.isArray(args) || args.length !== 2 || args[0] !== '--version') {
    fail('usage: node scripts/smoke-public-delivery.mjs --version X.Y.Z[-prerelease]')
  }
  const parsed = parseReleaseVersion(args[1], 'public delivery version')
  if (parsed.build !== null) fail('published package version must not contain build metadata')
  return Object.freeze({ version: parsed.value })
}

export function assertAnonymousEnvironment(environment) {
  if (environment === null || typeof environment !== 'object' || Array.isArray(environment)) {
    fail('environment is unavailable')
  }
  for (const [name, value] of Object.entries(environment)) {
    const normalized = name.toUpperCase()
    if (
      forbiddenEnvironmentNames.has(normalized)
      || /^NPM_CONFIG_/i.test(name)
      || /^(?:NPM|YARN|PNPM|COREPACK)_[A-Z0-9_]*(?:AUTH|TOKEN|PASSWORD|REGISTRY)/i.test(normalized)
      || /^ZIGCSS_/i.test(name)
    ) {
      fail(`anonymous job contains forbidden environment variable ${name}`)
    }
    if (typeof value !== 'string' || value.includes('\0')) {
      fail(`environment variable ${name} is not a safe string`)
    }
  }
  const executablePath = environment.PATH
  if (typeof executablePath !== 'string' || executablePath.length === 0 || executablePath.length > 64 * 1024) {
    fail('anonymous job PATH is missing or oversized')
  }
  const pathEntries = executablePath.split(path.delimiter)
  if (
    pathEntries.length > 128
    || pathEntries.some(entry => entry.length === 0 || entry.length > 4096 || !path.isAbsolute(entry))
  ) {
    fail('anonymous job PATH must contain only bounded absolute entries')
  }
  return true
}

export function npmInstallArguments(versionInput, paths) {
  const version = parseReleaseVersion(versionInput, 'public delivery version')
  if (version.build !== null) fail('published package version must not contain build metadata')
  if (paths === null || typeof paths !== 'object' || Array.isArray(paths)) {
    fail('npm isolation paths are unavailable')
  }
  if (typeof paths.workspace !== 'string' || !path.isAbsolute(paths.workspace) || paths.workspace.includes('\0')) {
    fail('npm workspace must be one absolute path')
  }
  const workspace = path.resolve(paths.workspace)
  const requiredPath = (value, label) => {
    if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) {
      fail(`${label} must be one absolute path`)
    }
    const resolved = confinedPath(workspace, value, label)
    if (resolved === workspace) fail(`${label} must not replace the consumer project`)
    return resolved
  }
  const userConfig = requiredPath(paths.userConfig, 'npm user config')
  const globalConfig = requiredPath(paths.globalConfig, 'npm global config')
  const cache = requiredPath(paths.cache, 'npm cache')
  if (new Set([userConfig, globalConfig, cache]).size !== 3) {
    fail('npm user config, global config, and cache paths must be distinct')
  }
  return Object.freeze([
    'install',
    '--no-save',
    '--package-lock=false',
    '--omit=dev',
    '--omit=optional',
    '--ignore-scripts=false',
    '--foreground-scripts',
    '--audit=false',
    '--fund=false',
    '--prefer-online',
    `--registry=${publicDeliveryPolicy.registry}`,
    `--userconfig=${userConfig}`,
    `--globalconfig=${globalConfig}`,
    `--cache=${cache}`,
    `${publicDeliveryPolicy.packageName}@${version.value}`,
  ])
}

function resolveNpmCli() {
  const executableDirectory = path.dirname(process.execPath)
  const candidates = [
    path.resolve(executableDirectory, '../lib/node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, '../node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, 'node_modules/npm/bin/npm-cli.js'),
  ]
  for (const candidate of candidates) {
    try {
      const resolved = fs.realpathSync(candidate)
      const stat = fs.lstatSync(resolved)
      if (stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 && stat.size <= 4 * 1024 * 1024) {
        return resolved
      }
    } catch {
      // Try only the next deterministic Node installation layout.
    }
  }
  fail('npm CLI could not be resolved beside the active Node executable')
}

function childEnvironment(environment, isolation) {
  const executablePath = [...new Set([path.dirname(process.execPath), '/usr/bin', '/bin'])]
    .join(path.delimiter)
  return Object.freeze({
    PATH: executablePath,
    LANG: 'C.UTF-8',
    LC_ALL: 'C.UTF-8',
    CI: 'true',
    NO_COLOR: '1',
    NPM_CONFIG_REGISTRY: publicDeliveryPolicy.registry,
    NPM_CONFIG_USERCONFIG: isolation.userConfig,
    NPM_CONFIG_GLOBALCONFIG: isolation.globalConfig,
    NPM_CONFIG_CACHE: isolation.cache,
    NPM_CONFIG_AUDIT: 'false',
    NPM_CONFIG_FUND: 'false',
    NPM_CONFIG_UPDATE_NOTIFIER: 'false',
    NPM_CONFIG_PROGRESS: 'false',
    NPM_CONFIG_COLOR: 'false',
    NPM_CONFIG_LOGLEVEL: 'warn',
  })
}

function remainingTimeout(deadline, maximum, label) {
  const remaining = deadline - Date.now()
  if (remaining <= 0) fail(`${label} exceeded the total ${publicDeliveryPolicy.totalTimeoutMs} ms deadline`)
  return Math.max(1, Math.min(maximum, remaining))
}

function failureTail(result) {
  const source = `${result.stderr ?? ''}${result.stdout ?? ''}`
    .replaceAll('\r\n', '\n')
    .replace(/[\0\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '?')
  return source.length === 0 ? '' : `: ${source.slice(-4096)}`
}

export function runBoundedCommand(command, args, options) {
  if (typeof command !== 'string' || !path.isAbsolute(command) || command.includes('\0')) {
    fail('child executable must be one absolute path')
  }
  if (!Array.isArray(args) || args.length === 0 || args.length > 64 || args.some(arg => typeof arg !== 'string' || arg.includes('\0'))) {
    fail('child arguments are invalid or unbounded')
  }
  if (
    !Number.isSafeInteger(options.timeoutMs)
    || options.timeoutMs <= 0
    || options.timeoutMs > publicDeliveryPolicy.installTimeoutMs
    || !Number.isSafeInteger(options.maximumOutputBytes)
    || options.maximumOutputBytes <= 0
    || options.maximumOutputBytes > publicDeliveryPolicy.installOutputBytes
  ) {
    fail('child resource limits are invalid')
  }
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: 'utf8',
    input: options.input,
    maxBuffer: options.maximumOutputBytes,
    timeout: options.timeoutMs,
    killSignal: 'SIGKILL',
    windowsHide: true,
  })
  if (result.error !== undefined) {
    if (result.error.code === 'ETIMEDOUT') fail(`${options.label} timed out`)
    if (result.error.code === 'ENOBUFS') fail(`${options.label} exceeded its output limit`)
    fail(`${options.label} failed to start: ${result.error.message}`)
  }
  if (result.signal !== null || result.status !== 0) {
    fail(`${options.label} failed with ${result.signal ?? `exit ${result.status}`}${failureTail(result)}`)
  }
  if (
    Buffer.byteLength(result.stdout) > options.maximumOutputBytes
    || Buffer.byteLength(result.stderr) > options.maximumOutputBytes
  ) {
    fail(`${options.label} exceeded its output limit`)
  }
  return Object.freeze({ stdout: result.stdout, stderr: result.stderr })
}

function treeInventory(root, relative = '', limits = publicDeliveryPolicy, depth = 0) {
  if (depth > 32) fail('installed package exceeds its directory-depth limit')
  const rows = []
  const directory = path.join(root, relative)
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryRelative = path.join(relative, entry.name)
    const filename = path.join(root, entryRelative)
    const stat = fs.lstatSync(filename)
    if (entry.isDirectory()) {
      if (stat.isSymbolicLink()) fail('installed package contains a directory symlink')
      rows.push(...treeInventory(root, entryRelative, limits, depth + 1))
    } else if (entry.isFile()) {
      if (stat.isSymbolicLink()) fail('installed package contains a file symlink')
      rows.push(Object.freeze({ path: entryRelative.split(path.sep).join('/'), bytes: stat.size }))
    } else {
      fail('installed package contains a symlink or special file')
    }
    if (rows.length > limits.installedEntries) fail('installed package exceeds its entry limit')
  }
  return rows
}

export function measureInstalledPackage(root, limits = publicDeliveryPolicy) {
  const rows = treeInventory(root, '', limits)
  const bytes = rows.reduce((total, row) => total + row.bytes, 0)
  if (rows.length === 0 || bytes <= 0 || bytes > limits.installedBytes) {
    fail('installed package exceeds its byte limit')
  }
  return Object.freeze({ entries: rows.length, bytes })
}

function readJsonFile(root, relativePath, label, maximumBytes) {
  const { candidate } = boundedRegularFile(root, relativePath, label, maximumBytes)
  try {
    return JSON.parse(fs.readFileSync(candidate, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

export function validateInstalledPublicPackage(workspace, version) {
  const packageRoot = confinedPath(workspace, path.join(workspace, 'node_modules', 'zigcss'), 'installed package')
  let rootStat
  try {
    rootStat = fs.lstatSync(packageRoot)
  } catch (error) {
    fail(`installed package is unavailable: ${error.message}`)
  }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || fs.realpathSync(packageRoot) !== packageRoot) {
    fail('installed package root must be a regular non-symlink directory')
  }

  const manifest = readJsonFile(packageRoot, 'package.json', 'installed package manifest', 256 * 1024)
  if (
    manifest === null
    || typeof manifest !== 'object'
    || Array.isArray(manifest)
    || manifest.name !== 'zigcss'
    || manifest.version !== version
    || manifest.bin?.zigcss !== 'index.js'
    || Object.keys(manifest.dependencies ?? {}).length !== 0
    || Object.keys(manifest.optionalDependencies ?? {}).length !== 0
  ) {
    fail('installed package manifest identity or zero-dependency boundary changed')
  }
  const integrity = readJsonFile(packageRoot, 'native-integrity.json', 'installed native integrity inventory', 256 * 1024)
  if (
    integrity === null
    || typeof integrity !== 'object'
    || Array.isArray(integrity)
    || integrity.version !== version
    || !Array.isArray(integrity.archives)
    || integrity.archives.length !== publicDeliveryTargets.length
  ) {
    fail('installed native integrity inventory does not bind the exact five-target version')
  }
  for (const [index, expected] of publicDeliveryTargets.entries()) {
    const archive = integrity.archives[index]
    if (
      archive === null
      || typeof archive !== 'object'
      || Array.isArray(archive)
      || archive.target !== expected.target
      || archive.filename !== `zigcss-v${version}-${expected.target}.${expected.extension}`
      || typeof archive.sha256 !== 'string'
      || !/^[0-9a-f]{64}$/.test(archive.sha256)
    ) {
      fail(`installed native integrity archive ${index} changed identity or digest`)
    }
  }

  const wrapper = boundedRegularFile(packageRoot, 'index.js', 'installed CLI wrapper', 2 * 1024 * 1024).candidate
  boundedRegularFile(packageRoot, 'api.cjs', 'installed CommonJS API', 2 * 1024 * 1024)
  boundedRegularFile(packageRoot, 'api.mjs', 'installed ESM API', 2 * 1024 * 1024)
  const native = boundedRegularFile(packageRoot, 'bin/zigcss', 'installed native executable', 256 * 1024 * 1024)
  if ((native.stat.mode & 0o111) === 0) fail('installed native executable is not executable')
  const measured = measureInstalledPackage(packageRoot)
  return Object.freeze({ packageRoot, wrapper, ...measured })
}

function compilerWarning(version) {
  return parseReleaseVersion(version).prerelease === null
    ? ''
    : `Warning: ZigCSS ${version} is an experimental release candidate; do not use it for production CSS.\n`
}

function assertCompileResult(result, expected, warning, label) {
  if (result.stdout !== expected || result.stderr !== warning) {
    fail(`${label} returned an unexpected compiler contract`)
  }
}

function nodeApiProgram(moduleKind) {
  const fixtures = JSON.stringify(publicDeliveryStylesheets)
  const assertions = [
    `const cases = ${fixtures}`,
    "if (typeof compile !== 'function' || typeof compileSync !== 'function') throw new Error('compile exports unavailable')",
    'for (const item of cases) {',
    '  const results = [',
    '    compileSync(item.source, { syntax: item.syntax, format: item.format }),',
    '    await compile(item.source, { syntax: item.syntax, format: item.format }),',
    '  ]',
    '  for (const result of results) {',
    "    if (result.css !== item.expected) throw new Error(`${item.id} CSS mismatch`)",
    "    if (result.sourceMap !== null) throw new Error(`${item.id} source map mismatch`)",
    "    if (result.diagnostics.length !== 0 || result.dependencies.length !== 0) throw new Error(`${item.id} result facts mismatch`)",
    "    if (!Object.isFrozen(result) || !Object.isFrozen(result.diagnostics) || !Object.isFrozen(result.dependencies)) throw new Error(`${item.id} ownership mismatch`)",
    '  }',
    '}',
    `process.stdout.write('${moduleKind}-node-api-ok\\n')`,
  ]
  if (moduleKind === 'cjs') {
    return [
      "const api = require('zigcss')",
      'const { compile, compileSync } = api;',
      ';(async () => {',
      ...assertions.map(line => `  ${line}`),
      '})().catch(error => { process.stderr.write(`${error.stack || error.message}\\n`); process.exitCode = 1 })',
    ].join('\n')
  }
  return [
    "import zigcss, { compile, compileSync } from 'zigcss'",
    "if (zigcss.compile !== compile || zigcss.compileSync !== compileSync) throw new Error('ESM default and named exports diverged')",
    ...assertions,
  ].join('\n')
}

function defaultInstall(context) {
  const npmCli = resolveNpmCli()
  return runBoundedCommand(process.execPath, [npmCli, ...context.arguments], {
    cwd: context.workspace,
    env: context.environment,
    timeoutMs: remainingTimeout(context.deadline, publicDeliveryPolicy.installTimeoutMs, 'anonymous npm install'),
    maximumOutputBytes: publicDeliveryPolicy.installOutputBytes,
    label: 'anonymous npm install',
  })
}

export function smokePublicDelivery(versionInput, options = {}) {
  const parsed = parseReleaseVersion(versionInput, 'public delivery version')
  if (parsed.build !== null) fail('published package version must not contain build metadata')
  const version = parsed.value
  const platform = options.platform ?? process.platform
  if (platform !== 'linux') fail(`public delivery smoke requires Linux, received ${platform}`)
  const environment = options.environment ?? process.env
  assertAnonymousEnvironment(environment)
  const deadline = Date.now() + publicDeliveryPolicy.totalTimeoutMs
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-public-delivery-')))
  try {
    const manifestText = `${JSON.stringify({
      name: 'zigcss-public-delivery-smoke',
      version: '0.0.0',
      private: true,
    }, null, 2)}\n`
    fs.writeFileSync(path.join(temporary, 'package.json'), manifestText, { flag: 'wx', mode: 0o600 })
    const isolation = {
      workspace: temporary,
      userConfig: path.join(temporary, 'empty-user.npmrc'),
      globalConfig: path.join(temporary, 'empty-global.npmrc'),
      cache: path.join(temporary, 'npm-cache'),
    }
    fs.writeFileSync(isolation.userConfig, '', { flag: 'wx', mode: 0o600 })
    fs.writeFileSync(isolation.globalConfig, '', { flag: 'wx', mode: 0o600 })
    fs.mkdirSync(isolation.cache, { mode: 0o700 })
    const installArguments = npmInstallArguments(version, isolation)
    const isolatedEnvironment = childEnvironment(environment, isolation)
    const install = options.install ?? defaultInstall
    install(Object.freeze({
      version,
      workspace: temporary,
      isolation: Object.freeze({ ...isolation }),
      arguments: installArguments,
      environment: isolatedEnvironment,
      deadline,
    }))
    if (fs.readFileSync(path.join(temporary, 'package.json'), 'utf8') !== manifestText) {
      fail('anonymous npm install mutated the bounded consumer manifest')
    }
    if (fs.existsSync(path.join(temporary, 'package-lock.json'))) {
      fail('anonymous npm install created an unexpected lockfile')
    }

    const installed = validateInstalledPublicPackage(temporary, version)
    const versionResult = runBoundedCommand(process.execPath, [installed.wrapper, '--version'], {
      cwd: temporary,
      env: isolatedEnvironment,
      timeoutMs: remainingTimeout(deadline, publicDeliveryPolicy.commandTimeoutMs, 'installed CLI version'),
      maximumOutputBytes: publicDeliveryPolicy.commandOutputBytes,
      label: 'installed CLI version',
    })
    if (versionResult.stdout !== `zigcss ${version}\n` || versionResult.stderr !== '') {
      fail('installed CLI returned an unexpected version contract')
    }

    const warning = compilerWarning(version)
    for (const item of publicDeliveryStylesheets) {
      const input = path.join(temporary, `public-delivery.${item.extension}`)
      fs.writeFileSync(input, item.source, { flag: 'wx', mode: 0o600 })
      const args = [installed.wrapper, input, '--syntax', item.syntax]
      if (item.format === 'minified') args.push('--minify')
      const result = runBoundedCommand(process.execPath, args, {
        cwd: temporary,
        env: isolatedEnvironment,
        timeoutMs: remainingTimeout(deadline, publicDeliveryPolicy.commandTimeoutMs, `${item.id} CLI compilation`),
        maximumOutputBytes: publicDeliveryPolicy.commandOutputBytes,
        label: `${item.id} CLI compilation`,
      })
      assertCompileResult(result, item.expected, warning, `${item.id} CLI compilation`)
    }

    for (const moduleKind of ['cjs', 'esm']) {
      const args = moduleKind === 'esm'
        ? ['--input-type=module', '-e', nodeApiProgram(moduleKind)]
        : ['-e', nodeApiProgram(moduleKind)]
      const result = runBoundedCommand(process.execPath, args, {
        cwd: temporary,
        env: isolatedEnvironment,
        timeoutMs: remainingTimeout(deadline, publicDeliveryPolicy.commandTimeoutMs, `${moduleKind} Node API`),
        maximumOutputBytes: publicDeliveryPolicy.commandOutputBytes,
        label: `${moduleKind} Node API`,
      })
      if (result.stdout !== `${moduleKind}-node-api-ok\n` || result.stderr !== '') {
        fail(`${moduleKind} Node API returned an unexpected installed-package contract`)
      }
    }

    return Object.freeze({
      version,
      registry: publicDeliveryPolicy.registry,
      installedEntries: installed.entries,
      installedBytes: installed.bytes,
      cliCompilations: publicDeliveryStylesheets.length,
      nodeApiModules: Object.freeze(['cjs', 'esm']),
      nodeApiCompilations: publicDeliveryStylesheets.length * 4,
    })
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function main() {
  const { version } = parsePublicDeliveryArguments(process.argv.slice(2))
  const result = smokePublicDelivery(version)
  process.stdout.write(
    `Anonymous public delivery verified for zigcss@${result.version}: ${result.cliCompilations} CLI languages and ${result.nodeApiCompilations} CJS/ESM API compilations from ${result.registry}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
