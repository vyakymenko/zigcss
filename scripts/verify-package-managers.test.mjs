import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, before, test } from 'node:test'
import {
  inspectNpmPackageArchive,
  validatePackDescription,
} from './npm-package-artifact.mjs'
import { createReleaseArchive } from './create-release-archive.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const rootManifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
const repositoryInstaller = createRequire(import.meta.url)(path.join(repositoryRoot, 'install.js'))
const releasePreload = path.join(repositoryRoot, 'scripts', 'release-smoke-preload.cjs')
const typescriptManifestPath = createRequire(import.meta.url).resolve('typescript/package.json')
const typescriptManifest = JSON.parse(fs.readFileSync(typescriptManifestPath, 'utf8'))
const typescriptCli = path.resolve(path.dirname(typescriptManifestPath), typescriptManifest.bin.tsc)
const repositoryRequire = createRequire(import.meta.url)
const repositoryTypeRoots = Object.freeze([
  path.dirname(path.dirname(repositoryRequire.resolve('@types/node/package.json'))),
])
const hostTypeSpecifiers = Object.freeze(['@rspack/core', 'esbuild', 'rollup', 'vite', 'webpack'])
const hostTypePaths = Object.freeze(Object.fromEntries(hostTypeSpecifiers.map(specifier => {
  const manifestPath = repositoryRequire.resolve(`${specifier}/package.json`)
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const declaration = manifest.types ?? manifest.typings
  let target = declaration === undefined
    ? repositoryRequire.resolve(specifier)
    : path.resolve(path.dirname(manifestPath), declaration)
  if (declaration === undefined) {
    const adjacentDeclaration = target.replace(/\.js$/, '.d.ts')
    if (adjacentDeclaration !== target && fs.existsSync(adjacentDeclaration)) {
      target = adjacentDeclaration
    }
  }
  return [specifier, [target]]
})))
const commandTimeoutMs = 30_000
const versionTimeoutMs = 5_000
const maximumCommandOutputBytes = 512 * 1024
const maximumPackOutputBytes = 4 * 1024 * 1024
const maximumShimBytes = 64 * 1024
const maximumToolchainBytes = 256 * 1024 * 1024
const maximumToolchainEntries = 10_000
const toolchainRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-toolchain-'))
const corepackHome = path.join(toolchainRoot, 'corepack')
fs.mkdirSync(corepackHome, { mode: 0o700 })
const toolchainOfflineEnvironment = Object.freeze({
  ...process.env,
  CI: '1',
  COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
  COREPACK_ENABLE_NETWORK: '0',
  COREPACK_HOME: corepackHome,
})
const toolchainDetectionEnvironment = Object.freeze({
  ...toolchainOfflineEnvironment,
  COREPACK_ENABLE_NETWORK: '1',
})
export const packageManagerVersions = Object.freeze({
  pnpm: '11.25.0',
  yarnClassic: '1.22.22',
  yarnModern: '4.9.4',
  bun: '1.4.0',
})
const adapterExportNames = Object.freeze([
  './adapters',
  './bun',
  './esbuild',
  './rollup',
  './rspack',
  './vite',
  './webpack',
])
const missingBinaryStderr = [
  'zigcss binary is missing or not executable. Lifecycle scripts may have been disabled.',
  "Run zigcss-install, allow this package's install script, or build ZigCSS from source.",
  '',
].join('\n')

function executable(name) {
  if (process.platform !== 'win32') return name
  return name === 'bun' ? 'bun.exe' : `${name}.cmd`
}

function invoke(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repositoryRoot,
    encoding: 'utf8',
    env: options.env ?? process.env,
    maxBuffer: options.maxBuffer ?? maximumCommandOutputBytes,
    timeout: options.timeout ?? commandTimeoutMs,
    windowsHide: true,
  })
  if (result.error !== undefined) {
    throw new Error(`${options.label ?? command} failed to start: ${result.error.message}`)
  }
  return result
}

function successful(command, args, options = {}) {
  const result = invoke(command, args, options)
  if (result.signal !== null || result.status !== 0) {
    throw new Error(
      `${options.label ?? command} failed with ${result.signal ?? `exit ${result.status}`}: ${result.stderr || result.stdout}`,
    )
  }
  return result
}

function detectCli(name, commandPrefix = [], environment = toolchainOfflineEnvironment) {
  const command = executable(name)
  const result = spawnSync(command, [...commandPrefix, '--version'], {
    cwd: toolchainRoot,
    encoding: 'utf8',
    env: environment,
    maxBuffer: 64 * 1024,
    timeout: commandPrefix.length === 0 ? versionTimeoutMs : commandTimeoutMs,
    windowsHide: true,
  })
  if (result.error?.code === 'ENOENT') {
    return Object.freeze({ command, commandPrefix: Object.freeze([...commandPrefix]), missing: true })
  }
  if (result.error !== undefined) {
    return Object.freeze({
      command,
      commandPrefix: Object.freeze([...commandPrefix]),
      missing: false,
      error: result.error.message,
    })
  }
  const version = result.stdout.trim()
  if (result.signal !== null || result.status !== 0 || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    return Object.freeze({
      command,
      commandPrefix: Object.freeze([...commandPrefix]),
      missing: false,
      error: `${[name, ...commandPrefix].join(' ')} --version returned ${result.signal ?? `exit ${result.status}`} and ${JSON.stringify(version)}`,
    })
  }
  return Object.freeze({
    command,
    commandPrefix: Object.freeze([...commandPrefix]),
    missing: false,
    version,
  })
}

function detectExactCli(name, expectedVersion) {
  const direct = detectCli(name, [], toolchainOfflineEnvironment)
  if (!direct.missing && direct.error === undefined && direct.version === expectedVersion) {
    return Object.freeze({ ...direct, expectedVersion, provider: 'direct' })
  }

  const corepack = detectCli(
    'corepack',
    [`${name}@${expectedVersion}`],
    toolchainDetectionEnvironment,
  )
  if (!corepack.missing && corepack.error === undefined && corepack.version !== expectedVersion) {
    return Object.freeze({
      ...corepack,
      error: `Corepack selected ${name} ${corepack.version}; expected ${expectedVersion}`,
      expectedVersion,
      provider: 'corepack',
    })
  }
  if (corepack.missing && !direct.missing) {
    return Object.freeze({
      ...corepack,
      error: `${name} ${direct.version ?? 'unknown'} is not the required ${expectedVersion}, and Corepack is unavailable`,
      expectedVersion,
      provider: 'corepack',
    })
  }
  return Object.freeze({ ...corepack, expectedVersion, provider: 'corepack' })
}

const managers = Object.freeze([
  Object.freeze({
    id: 'npm',
    family: 'npm',
    label: 'npm',
    mandatory: true,
    mandatoryInGitHubActions: true,
    testName: 'npm installs the exact local tgz with lifecycle scripts disabled',
    cli: detectCli('npm'),
  }),
  Object.freeze({
    id: 'pnpm',
    family: 'pnpm',
    label: 'pnpm',
    mandatory: false,
    mandatoryInGitHubActions: true,
    testName: 'pnpm installs the exact local tgz with lifecycle scripts disabled',
    cli: detectExactCli('pnpm', packageManagerVersions.pnpm),
  }),
  Object.freeze({
    id: 'yarn-classic',
    family: 'yarn',
    variant: 'classic',
    label: `Yarn Classic ${packageManagerVersions.yarnClassic}`,
    mandatory: false,
    mandatoryInGitHubActions: true,
    testName: `Yarn installs the exact local tgz with lifecycle scripts disabled (Classic ${packageManagerVersions.yarnClassic})`,
    cli: detectExactCli('yarn', packageManagerVersions.yarnClassic),
  }),
  Object.freeze({
    id: 'yarn-modern',
    family: 'yarn',
    variant: 'modern',
    nodeLinker: 'node-modules',
    label: `Yarn Modern ${packageManagerVersions.yarnModern} node-modules`,
    mandatory: false,
    mandatoryInGitHubActions: true,
    testName: `Yarn installs the exact local tgz with lifecycle scripts disabled (Modern ${packageManagerVersions.yarnModern} node-modules)`,
    cli: detectExactCli('yarn', packageManagerVersions.yarnModern),
  }),
  Object.freeze({
    id: 'yarn-modern-pnp',
    family: 'yarn',
    variant: 'modern',
    pnp: true,
    label: `Yarn Modern ${packageManagerVersions.yarnModern} default PnP`,
    mandatory: false,
    mandatoryInGitHubActions: true,
    testName: `Yarn installs the exact local tgz with lifecycle scripts disabled (Modern ${packageManagerVersions.yarnModern} default PnP)`,
    cli: detectExactCli('yarn', packageManagerVersions.yarnModern),
  }),
  Object.freeze({
    id: 'bun',
    family: 'bun',
    label: 'Bun',
    mandatory: false,
    mandatoryInGitHubActions: true,
    testName: 'Bun installs the exact local tgz with lifecycle scripts disabled',
    cli: detectCli('bun'),
    expectedCiVersion: packageManagerVersions.bun,
  }),
])

let matrixRoot
let packageArchive
let packageArchiveDigest
let preloadedRelease
let pnpTypescriptPackageRoot

function confinedTemporaryDirectory(relative) {
  const candidate = path.join(matrixRoot, relative)
  const confined = path.relative(matrixRoot, candidate)
  assert.equal(path.isAbsolute(confined), false)
  assert.doesNotMatch(confined, /^\.\.(?:[/\\]|$)/)
  fs.mkdirSync(candidate, { mode: 0o700 })
  return candidate
}

function inspectBoundedToolchainRoot() {
  const rootStat = fs.lstatSync(toolchainRoot)
  assert.equal(rootStat.isDirectory(), true, 'package-manager toolchain root must be a directory')
  assert.equal(rootStat.isSymbolicLink(), false, 'package-manager toolchain root must not be a symlink')
  const canonicalRoot = fs.realpathSync(toolchainRoot)
  const pending = [canonicalRoot]
  let bytes = 0
  let entries = 0
  while (pending.length > 0) {
    const directory = pending.pop()
    for (const name of fs.readdirSync(directory)) {
      entries += 1
      assert.equal(entries <= maximumToolchainEntries, true, 'Corepack toolchain entry count must be bounded')
      const filename = path.join(directory, name)
      const stat = fs.lstatSync(filename)
      assert.equal(stat.isSymbolicLink(), false, 'Corepack toolchain must not contain symlinks')
      const canonical = fs.realpathSync(filename)
      const relative = path.relative(canonicalRoot, canonical)
      assert.equal(path.isAbsolute(relative), false)
      assert.doesNotMatch(relative, /^\.\.(?:[/\\]|$)/)
      if (stat.isDirectory()) {
        pending.push(canonical)
      } else {
        assert.equal(stat.isFile(), true, 'Corepack toolchain entries must be regular files or directories')
        bytes += stat.size
        assert.equal(bytes <= maximumToolchainBytes, true, 'Corepack toolchain byte size must be bounded')
      }
    }
  }
  return Object.freeze({ bytes, entries })
}

function offlineEnvironment(managerRoot, manager = {}) {
  const cache = path.join(managerRoot, 'cache')
  fs.mkdirSync(cache, { mode: 0o700 })
  const unavailableProxy = 'http://127.0.0.1:9'
  const environment = {
    ...process.env,
    ALL_PROXY: unavailableProxy,
    BUN_CONFIG_REGISTRY: `${unavailableProxy}/`,
    BUN_INSTALL_CACHE_DIR: path.join(cache, 'bun'),
    CI: '1',
    COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
    COREPACK_ENABLE_NETWORK: '0',
    COREPACK_HOME: corepackHome,
    HTTP_PROXY: unavailableProxy,
    HTTPS_PROXY: unavailableProxy,
    NO_PROXY: '',
    YARN_CACHE_FOLDER: path.join(cache, 'yarn'),
    YARN_ENABLE_NETWORK: 'false',
    YARN_ENABLE_SCRIPTS: 'false',
    http_proxy: unavailableProxy,
    https_proxy: unavailableProxy,
    npm_config_audit: 'false',
    npm_config_cache: path.join(cache, 'npm'),
    npm_config_fund: 'false',
    npm_config_offline: 'true',
    npm_config_proxy: unavailableProxy,
    npm_config_https_proxy: unavailableProxy,
    npm_config_registry: `${unavailableProxy}/`,
    npm_config_update_notifier: 'false',
  }
  for (const key of [
    'NODE_AUTH_TOKEN',
    'NODE_OPTIONS',
    'NPM_TOKEN',
    'YARN_NPM_AUTH_TOKEN',
    'YARN_ENABLE_COLORS',
    'YARN_ENABLE_GLOBAL_CACHE',
    'YARN_GLOBAL_FOLDER',
    'YARN_NODE_LINKER',
    'npm_config__auth',
    'npm_config__authToken',
  ]) {
    delete environment[key]
  }
  if (manager.family === 'yarn' && manager.variant === 'modern') {
    environment.YARN_ENABLE_COLORS = 'false'
    environment.YARN_ENABLE_GLOBAL_CACHE = 'false'
    environment.YARN_GLOBAL_FOLDER = path.join(cache, 'yarn-global')
  }
  if (manager.nodeLinker !== undefined) environment.YARN_NODE_LINKER = manager.nodeLinker
  return environment
}

function installArguments(manager, managerRoot) {
  if (manager.family === 'npm') {
    return [
      'install',
      packageArchive,
      '--ignore-scripts',
      '--offline',
      '--no-audit',
      '--no-fund',
      '--package-lock=false',
      '--loglevel=error',
    ]
  }
  if (manager.family === 'pnpm') {
    return [
      'add',
      packageArchive,
      '--ignore-scripts',
      '--offline',
      '--save-exact',
      '--reporter=silent',
      '--store-dir', path.join(managerRoot, 'pnpm-store'),
    ]
  }
  if (manager.family === 'bun') {
    return ['add', packageArchive, '--ignore-scripts', '--offline', '--exact']
  }
  if (manager.family === 'yarn' && manager.variant === 'classic') {
    return ['add', packageArchive, '--ignore-scripts', '--offline', '--exact', '--non-interactive']
  }
  if (manager.family === 'yarn' && manager.variant === 'modern') {
    return ['add', packageArchive, '--exact', '--mode=skip-build']
  }
  throw new Error(`unsupported package-manager policy ${manager.family ?? manager.id}`)
}

function managerCommandArguments(manager, args) {
  return [...(manager.cli.commandPrefix ?? []), ...args]
}

function verifyGitHubActionsToolchain(candidates, enabled = process.env.GITHUB_ACTIONS === 'true') {
  if (!enabled) return
  for (const manager of candidates.filter(candidate => candidate.mandatoryInGitHubActions)) {
    assert.equal(manager.cli.missing, false, `${manager.label} is mandatory in GitHub Actions`)
    assert.equal(manager.cli.error, undefined, `${manager.label} CLI is unusable: ${manager.cli.error}`)
    const expectedVersion = manager.cli.expectedVersion ?? manager.expectedCiVersion
    if (expectedVersion !== undefined) {
      assert.equal(
        manager.cli.version,
        expectedVersion,
        `${manager.label} must use exact version ${expectedVersion} in GitHub Actions`,
      )
    }
  }
}

function regularFile(filename, label, maximumBytes) {
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    assert.fail(`${label} is unavailable: ${error.message}`)
  }
  assert.equal(stat.isFile() || stat.isSymbolicLink(), true, `${label} must be a file or file symlink`)
  assert.equal(stat.size > 0 && stat.size <= maximumBytes, true, `${label} size must be bounded`)
  assert.equal(fs.statSync(filename).isFile(), true, `${label} must resolve to a file`)
  return filename
}

function verifyShim(consumer, installedRoot, name, target) {
  const basename = path.join(consumer, 'node_modules', '.bin', name)
  const filename = process.platform === 'win32' ? `${basename}.cmd` : basename
  regularFile(filename, `${name} bin shim`, maximumShimBytes)
  const stat = fs.lstatSync(filename)
  const expected = fs.realpathSync(path.join(installedRoot, target))
  if (stat.isSymbolicLink()) {
    assert.equal(fs.realpathSync(filename), expected, `${name} bin shim target changed`)
  } else {
    const source = fs.readFileSync(filename, 'utf8')
    assert.equal(source.includes(target), true, `${name} bin shim does not reference ${target}`)
  }
}

function verifyResolvedTarget(resolved, installedRoot, target, label) {
  const expected = fs.realpathSync(path.join(installedRoot, target))
  assert.equal(fs.realpathSync(resolved), expected, `${label} resolved outside the installed package`)
  regularFile(resolved, label, maximumCommandOutputBytes)
}

function verifyAdapterResolution(consumer, installedRoot, manifest, environment) {
  const actualNames = Object.keys(manifest.exports)
    .filter(name => name !== '.' && name !== './package.json')
    .sort()
  assert.deepEqual(actualNames, [...adapterExportNames])
  const requireFromConsumer = createRequire(path.join(consumer, 'package.json'))
  const importSpecifiers = []
  for (const exportName of adapterExportNames) {
    const contract = manifest.exports[exportName]
    assert.deepEqual(Object.keys(contract).sort(), ['import', 'require'])
    assert.deepEqual(Object.keys(contract.import), ['types', 'default'])
    assert.deepEqual(Object.keys(contract.require), ['types', 'default'])
    const specifier = `zigcss/${exportName.slice(2)}`
    verifyResolvedTarget(
      requireFromConsumer.resolve(specifier),
      installedRoot,
      contract.require.default.slice(2),
      `${specifier} CommonJS export`,
    )
    for (const mode of ['import', 'require']) {
      regularFile(
        path.join(installedRoot, contract[mode].types.slice(2)),
        `${specifier} ${mode} declaration export`,
        maximumCommandOutputBytes,
      )
    }
    importSpecifiers.push(specifier)
  }

  const program = [
    `const specifiers = ${JSON.stringify(importSpecifiers)}`,
    'process.stdout.write(JSON.stringify(specifiers.map(specifier => import.meta.resolve(specifier))))',
  ].join('\n')
  const resolvedImports = successful(process.execPath, ['--input-type=module', '--eval', program], {
    cwd: consumer,
    env: environment,
    label: 'installed ESM adapter resolution',
  })
  assert.equal(resolvedImports.stderr, '')
  const parsed = JSON.parse(resolvedImports.stdout)
  assert.equal(parsed.length, adapterExportNames.length)
  for (let index = 0; index < adapterExportNames.length; index += 1) {
    const exportName = adapterExportNames[index]
    const target = manifest.exports[exportName].import.default.slice(2)
    verifyResolvedTarget(
      fileURLToPath(parsed[index]),
      installedRoot,
      target,
      `zigcss/${exportName.slice(2)} ESM export`,
    )
  }
}

function prepareTypedPackageSurface(consumer) {
  for (const filename of ['consumer.ts', 'consumer.mts', 'consumer.cts', 'tsconfig.json']) {
    fs.copyFileSync(
      path.join(repositoryRoot, 'tests', 'typescript', filename),
      path.join(consumer, filename),
      fs.constants.COPYFILE_EXCL,
    )
  }
  const configPath = path.join(consumer, 'tsconfig.json')
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
  config.compilerOptions.lib = ['ESNext', 'DOM']
  config.compilerOptions.paths = hostTypePaths
  config.compilerOptions.typeRoots = repositoryTypeRoots
  config.compilerOptions.types = ['node']
  fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`)
  return configPath
}

function verifyTypedPackageSurface(consumer, environment, managerLabel) {
  regularFile(typescriptCli, 'TypeScript compiler', maximumCommandOutputBytes)
  const configPath = prepareTypedPackageSurface(consumer)
  const checked = successful(process.execPath, [typescriptCli, '-p', configPath], {
    cwd: consumer,
    env: environment,
    label: `${managerLabel} installed TypeScript package surface`,
  })
  assert.equal(checked.stdout, '')
  assert.equal(checked.stderr, '')
}

function verifyNativeIntegritySurface(installedRoot, manifest) {
  const filename = regularFile(
    path.join(installedRoot, 'native-integrity.json'),
    'installed native integrity manifest',
    maximumCommandOutputBytes,
  )
  const source = fs.readFileSync(filename, 'utf8')
  const installedInstaller = repositoryRequire(path.join(installedRoot, 'install.js'))
  for (const target of manifest.zigcss.nativeTargets) {
    const descriptor = installedInstaller.releaseDescriptor(
      manifest.version,
      target.platform,
      target.arch,
    )
    assert.equal(descriptor.target, target.target)
    assert.match(installedInstaller.parseNativeIntegrityManifest(source, descriptor), /^[0-9a-f]{64}$/)
  }
}

function hashFileSha256(filename, maximumBytes) {
  const stat = fs.lstatSync(filename)
  assert.equal(stat.isFile(), true, 'preloaded release archive must be a regular file')
  assert.equal(stat.isSymbolicLink(), false, 'preloaded release archive must not be a symlink')
  assert.equal(stat.size > 0 && stat.size <= maximumBytes, true, 'preloaded release archive size must be bounded')
  const digest = crypto.createHash('sha256')
  const descriptor = fs.openSync(filename, 'r')
  const chunk = Buffer.allocUnsafe(64 * 1024)
  try {
    while (true) {
      const length = fs.readSync(descriptor, chunk, 0, chunk.length, null)
      if (length === 0) break
      digest.update(chunk.subarray(0, length))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return digest.digest('hex')
}

function createLocalReleaseFixture() {
  const releaseRoot = confinedTemporaryDirectory('preloaded-release')
  const descriptor = repositoryInstaller.releaseDescriptor(
    rootManifest.version,
    process.platform,
    process.arch,
  )
  const integritySource = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'native-integrity.json'), 'utf8'),
  )
  const binaryRoot = path.join(releaseRoot, 'binary')
  fs.mkdirSync(binaryRoot, { mode: 0o700 })
  const fixtureBinary = path.join(binaryRoot, descriptor.binaryName)
  fs.copyFileSync(process.execPath, fixtureBinary, fs.constants.COPYFILE_EXCL)
  if (process.platform !== 'win32') fs.chmodSync(fixtureBinary, 0o755)
  repositoryInstaller.assertBinaryMatchesTarget(fixtureBinary, descriptor.target)
  const archive = path.join(releaseRoot, descriptor.assets.archive)
  const checksums = path.join(releaseRoot, descriptor.assets.checksums)
  createReleaseArchive({
    archive,
    binary: fixtureBinary,
    sourceDateEpoch: integritySource.sourceDateEpoch,
  })
  const fixtureDigest = hashFileSha256(
    archive,
    repositoryInstaller.installLimits.maximumArchiveBytes,
  )
  const fixtureSbomDigest = crypto.createHash('sha256')
    .update('zigcss package-manager local fixture SBOM\n')
    .digest('hex')
  const checksumSource = [
    `${fixtureDigest}  ${descriptor.assets.archive}`,
    `${fixtureSbomDigest}  ${descriptor.assets.sbom}`,
    '',
  ].join('\n')
  fs.writeFileSync(checksums, checksumSource, { encoding: 'utf8', flag: 'wx', mode: 0o600 })
  assert.equal(
    repositoryInstaller.parseChecksumManifest(
      fs.readFileSync(checksums, 'utf8'),
      descriptor.assets.archive,
      descriptor.assets.sbom,
    ),
    fixtureDigest,
  )
  return Object.freeze({ descriptor, fixtureDigest, releaseRoot })
}

function yarnFileSpecifier(filename) {
  const resolved = fs.realpathSync(filename).split(path.sep).join('/')
  return `file:${process.platform === 'win32' ? `/${resolved}` : resolved}`
}

function createLocalPnpTypescriptFixture() {
  const fixtureRoot = confinedTemporaryDirectory('pnp-typescript')
  const packageRoot = path.join(fixtureRoot, 'typescript')
  const availableNativePackages = Object.keys(typescriptManifest.optionalDependencies ?? {})
    .flatMap(specifier => {
      try {
        return [[specifier, path.dirname(repositoryRequire.resolve(`${specifier}/package.json`))]]
      } catch {
        return []
      }
    })
  assert.equal(availableNativePackages.length, 1, 'exactly one host TypeScript native package must be installed')
  const [nativeSpecifier, nativeRoot] = availableNativePackages[0]
  const nativeManifest = JSON.parse(fs.readFileSync(path.join(nativeRoot, 'package.json'), 'utf8'))
  assert.equal(nativeManifest.name, nativeSpecifier)
  assert.equal(nativeManifest.version, typescriptManifest.version)
  assert.equal(typescriptManifest.optionalDependencies[nativeSpecifier], typescriptManifest.version)
  fs.cpSync(nativeRoot, packageRoot, {
    dereference: false,
    errorOnExist: true,
    force: false,
    recursive: true,
  })
  const nativeCompiler = process.platform === 'win32' ? 'tsc.exe' : 'tsc'
  regularFile(
    path.join(packageRoot, 'lib', nativeCompiler),
    'local PnP TypeScript compiler fixture',
    repositoryInstaller.installLimits.maximumBinaryBytes,
  )
  const fixtureManifestPath = path.join(packageRoot, 'package.json')
  const fixtureManifest = {
    name: 'zigcss-typescript-fixture',
    version: typescriptManifest.version,
    private: true,
    type: 'module',
    preferUnplugged: true,
    bin: { tsc: `lib/${nativeCompiler}` },
    dependencies: {},
  }
  fs.writeFileSync(
    fixtureManifestPath,
    `${JSON.stringify(fixtureManifest, null, 2)}\n`,
    { encoding: 'utf8', flag: 'w' },
  )
  return packageRoot
}

function verifyInstalledPackage(manager) {
  assert.equal(manager.cli.error, undefined, `${manager.label} CLI is unusable: ${manager.cli.error}`)
  const managerRoot = confinedTemporaryDirectory(manager.id)
  try {
    const consumer = path.join(managerRoot, 'consumer')
    fs.mkdirSync(consumer, { mode: 0o700 })
    fs.writeFileSync(
      path.join(consumer, 'package.json'),
      `${JSON.stringify({ name: `zigcss-${manager.id}-matrix`, private: true, version: '1.0.0' }, null, 2)}\n`,
      { encoding: 'utf8', flag: 'wx', mode: 0o600 },
    )
    const environment = offlineEnvironment(managerRoot, manager)
    const installed = successful(
      manager.cli.command,
      managerCommandArguments(manager, installArguments(manager, managerRoot)),
      {
        cwd: consumer,
        env: environment,
        label: `${manager.label} lifecycle-disabled local-tarball install`,
      },
    )
    assert.equal(Buffer.byteLength(installed.stdout) <= maximumCommandOutputBytes, true)
    assert.equal(Buffer.byteLength(installed.stderr) <= maximumCommandOutputBytes, true)

    const packageLink = path.join(consumer, 'node_modules', 'zigcss')
    assert.equal(fs.statSync(packageLink).isDirectory(), true, 'installed zigcss must resolve to a directory')
    const installedRoot = fs.realpathSync(packageLink)
    const manifest = JSON.parse(fs.readFileSync(path.join(installedRoot, 'package.json'), 'utf8'))
    assert.equal(manifest.name, 'zigcss')
    assert.equal(manifest.version, rootManifest.version)
    assert.deepEqual(manifest.dependencies ?? {}, {})
    assert.deepEqual(manifest.optionalDependencies ?? {}, {})
    assert.deepEqual(manifest.bin, { zigcss: 'index.js', 'zigcss-install': 'install.js' })
    verifyNativeIntegritySurface(installedRoot, manifest)
    const nestedModules = path.join(installedRoot, 'node_modules')
    if (fs.existsSync(nestedModules)) {
      assert.equal(fs.statSync(nestedModules).isDirectory(), true)
      assert.deepEqual(fs.readdirSync(nestedModules).filter(entry => entry !== '.bin'), [])
    }
    assert.equal(fs.existsSync(path.join(installedRoot, 'bin')), false)

    verifyShim(consumer, installedRoot, 'zigcss', 'index.js')
    verifyShim(consumer, installedRoot, 'zigcss-install', 'install.js')

    const recovery = invoke(process.execPath, [path.join(installedRoot, 'index.js'), '--version'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} lifecycle-disabled recovery failure`,
    })
    assert.equal(recovery.signal, null)
    assert.equal(recovery.status, 1)
    assert.equal(recovery.stdout, '')
    assert.equal(recovery.stderr, missingBinaryStderr)

    verifyAdapterResolution(consumer, installedRoot, manifest, environment)
    verifyTypedPackageSurface(consumer, environment, manager.label)
  } finally {
    fs.rmSync(managerRoot, { recursive: true, force: true })
  }
}

function exactManagerCommand(manager, args, options = {}) {
  return invoke(manager.cli.command, managerCommandArguments(manager, args), options)
}

function successfulManagerCommand(manager, args, options = {}) {
  return successful(manager.cli.command, managerCommandArguments(manager, args), options)
}

function trustLocalFixtureInInstalledCopy(installedRoot, fixture) {
  const repositoryIntegrityPath = path.join(repositoryRoot, 'native-integrity.json')
  const installedIntegrityPath = path.join(installedRoot, 'native-integrity.json')
  const repositoryIntegritySource = fs.readFileSync(repositoryIntegrityPath, 'utf8')
  assert.equal(fs.readFileSync(installedIntegrityPath, 'utf8'), repositoryIntegritySource)
  const synthesized = JSON.parse(repositoryIntegritySource)
  const selected = synthesized.archives.find(archive => archive.target === fixture.descriptor.target)
  assert.notEqual(selected, undefined, 'local fixture target must exist in installed trust inventory')
  selected.sha256 = fixture.fixtureDigest
  const synthesizedSource = `${JSON.stringify(synthesized, null, 2)}\n`
  fs.writeFileSync(installedIntegrityPath, synthesizedSource, { encoding: 'utf8', flag: 'w' })
  assert.equal(
    repositoryInstaller.parseNativeIntegrityManifest(synthesizedSource, fixture.descriptor),
    fixture.fixtureDigest,
  )
  assert.equal(fs.readFileSync(repositoryIntegrityPath, 'utf8'), repositoryIntegritySource)
  assert.equal(
    hashFileSha256(packageArchive, maximumPackOutputBytes),
    packageArchiveDigest,
    'local recovery trust must not mutate the exact packed package archive',
  )
}

function verifyYarnPnpTypedPackageSurface(manager, consumer, installedRoot, manifest, environment) {
  const baseConfigPath = prepareTypedPackageSurface(consumer)
  const baseConfig = JSON.parse(fs.readFileSync(baseConfigPath, 'utf8'))
  const compilerVersion = successfulManagerCommand(manager, ['tsc', '--version'], {
    cwd: consumer,
    env: environment,
    label: `${manager.label} exact local PnP TypeScript compiler`,
  })
  assert.equal(compilerVersion.stdout, `Version ${typescriptManifest.version}\n`)
  assert.equal(compilerVersion.stderr, '')
  for (const specifier of ['zigcss', ...adapterExportNames.map(name => `zigcss/${name.slice(2)}`)]) {
    assert.equal(Object.hasOwn(baseConfig.compilerOptions.paths, specifier), false)
  }
  const noPaths = exactManagerCommand(manager, ['tsc', '-p', baseConfigPath], {
    cwd: consumer,
    env: environment,
    label: `${manager.label} PnP TypeScript 7 no-paths package resolution boundary`,
  })
  assert.equal(noPaths.signal, null)
  assert.equal(noPaths.status, 1)
  assert.equal(noPaths.stderr, '')
  assert.equal(Buffer.byteLength(noPaths.stdout) <= maximumCommandOutputBytes, true)
  for (const specifier of ['zigcss', ...adapterExportNames.map(name => `zigcss/${name.slice(2)}`)]) {
    assert.equal(
      noPaths.stdout.includes(`error TS2307: Cannot find module '${specifier}' or its corresponding type declarations.`),
      true,
      `unpatched TypeScript ${typescriptManifest.version} unexpectedly resolved ${specifier} through PnP`,
    )
  }
  for (const specifier of hostTypeSpecifiers) {
    assert.equal(noPaths.stdout.includes(`Cannot find module '${specifier}'`), false)
  }
  assert.equal(
    fs.existsSync(path.join(consumer, 'node_modules')),
    false,
    'PnP TypeScript no-paths boundary must not create node_modules',
  )
  const modes = [
    ['consumer.ts', 'require'],
    ['consumer.mts', 'import'],
    ['consumer.cts', 'require'],
  ]
  const exportNames = ['.', ...adapterExportNames]
  for (const [filename, mode] of modes) {
    const config = structuredClone(baseConfig)
    config.files = [filename]
    for (const exportName of exportNames) {
      const specifier = exportName === '.' ? 'zigcss' : `zigcss/${exportName.slice(2)}`
      config.compilerOptions.paths[specifier] = [
        path.join(installedRoot, manifest.exports[exportName][mode].types.slice(2)),
      ]
    }
    const configPath = path.join(consumer, `tsconfig.pnp-${path.extname(filename).slice(1)}.json`)
    fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    })
    const typed = successfulManagerCommand(manager, ['tsc', '-p', configPath], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} PnP strict TypeScript ${mode} declaration bytes`,
    })
    assert.equal(typed.stdout, '')
    assert.equal(typed.stderr, '')
    assert.equal(
      fs.existsSync(path.join(consumer, 'node_modules')),
      false,
      'PnP declaration-byte compilation must not create node_modules',
    )
  }
}

function verifyYarnPnpPackageSurface(manager, consumer, installedRoot, manifest, environment) {
  const exportNames = ['.', ...adapterExportNames]
  const specifiers = exportNames.map(exportName => exportName === '.' ? 'zigcss' : `zigcss/${exportName.slice(2)}`)
  for (const exportName of exportNames) {
    const contract = manifest.exports[exportName]
    assert.deepEqual(Object.keys(contract).sort(), ['import', 'require'])
    assert.deepEqual(Object.keys(contract.import), ['types', 'default'])
    assert.deepEqual(Object.keys(contract.require), ['types', 'default'])
    for (const mode of ['import', 'require']) {
      regularFile(
        path.join(installedRoot, contract[mode].types.slice(2)),
        `${exportName} ${mode} PnP declaration export`,
        maximumCommandOutputBytes,
      )
    }
  }

  const commonJsProgram = [
    `const specifiers = ${JSON.stringify(specifiers)}`,
    'process.stdout.write(JSON.stringify(specifiers.map(specifier => require.resolve(specifier))))',
  ].join('\n')
  const commonJs = successfulManagerCommand(manager, ['node', '--eval', commonJsProgram], {
    cwd: consumer,
    env: environment,
    label: `${manager.label} PnP CommonJS export resolution`,
  })
  assert.equal(commonJs.stderr, '')
  const commonJsPaths = JSON.parse(commonJs.stdout)
  assert.equal(commonJsPaths.length, exportNames.length)
  for (let index = 0; index < exportNames.length; index += 1) {
    const exportName = exportNames[index]
    verifyResolvedTarget(
      commonJsPaths[index],
      installedRoot,
      manifest.exports[exportName].require.default.slice(2),
      `${specifiers[index]} PnP CommonJS export`,
    )
  }

  const esmProgram = [
    `const specifiers = ${JSON.stringify(specifiers)}`,
    'process.stdout.write(JSON.stringify(specifiers.map(specifier => import.meta.resolve(specifier))))',
  ].join('\n')
  const esm = successfulManagerCommand(manager, ['node', '--input-type=module', '--eval', esmProgram], {
    cwd: consumer,
    env: environment,
    label: `${manager.label} PnP ESM export resolution`,
  })
  assert.equal(esm.stderr, '')
  const esmUrls = JSON.parse(esm.stdout)
  assert.equal(esmUrls.length, exportNames.length)
  for (let index = 0; index < exportNames.length; index += 1) {
    const exportName = exportNames[index]
    verifyResolvedTarget(
      fileURLToPath(esmUrls[index]),
      installedRoot,
      manifest.exports[exportName].import.default.slice(2),
      `${specifiers[index]} PnP ESM export`,
    )
  }

  verifyYarnPnpTypedPackageSurface(manager, consumer, installedRoot, manifest, environment)
}

function verifyYarnPnpPackage(manager) {
  assert.equal(manager.cli.error, undefined, `${manager.label} CLI is unusable: ${manager.cli.error}`)
  assert.equal(manager.pnp, true)
  assert.equal(manager.nodeLinker, undefined)
  assert.notEqual(preloadedRelease, undefined, 'verified local release fixture must be preloaded')
  const managerRoot = confinedTemporaryDirectory(manager.id)
  try {
    const consumer = path.join(managerRoot, 'consumer')
    fs.mkdirSync(consumer, { mode: 0o700 })
    assert.notEqual(pnpTypescriptPackageRoot, undefined, 'local PnP TypeScript fixture must exist')
    const typescriptFileSpecifier = yarnFileSpecifier(pnpTypescriptPackageRoot)
    fs.writeFileSync(
      path.join(consumer, 'package.json'),
      `${JSON.stringify({
        name: 'zigcss-yarn-modern-pnp-matrix',
        private: true,
        version: '1.0.0',
        devDependencies: { 'zigcss-typescript-fixture': typescriptFileSpecifier },
      }, null, 2)}\n`,
      { encoding: 'utf8', flag: 'wx', mode: 0o600 },
    )
    const environment = offlineEnvironment(managerRoot, manager)
    assert.equal(Object.hasOwn(environment, 'YARN_NODE_LINKER'), false)
    const installed = successfulManagerCommand(manager, installArguments(manager, managerRoot), {
      cwd: consumer,
      env: environment,
      label: `${manager.label} lifecycle-disabled local-tarball install`,
    })
    assert.equal(Buffer.byteLength(installed.stdout) <= maximumCommandOutputBytes, true)
    assert.equal(Buffer.byteLength(installed.stderr) <= maximumCommandOutputBytes, true)

    assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'default Yarn PnP must not create node_modules')
    const pnpLoader = path.join(consumer, '.pnp.cjs')
    const pnpStat = fs.lstatSync(pnpLoader)
    assert.equal(pnpStat.isFile(), true, 'default Yarn PnP must create .pnp.cjs')
    assert.equal(pnpStat.isSymbolicLink(), false, 'default Yarn PnP loader must not be a symlink')
    const linker = successfulManagerCommand(manager, ['config', 'get', 'nodeLinker'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} default nodeLinker inspection`,
    })
    assert.equal(linker.stdout, 'pnp\n')
    assert.equal(linker.stderr, '')
    const globalCache = successfulManagerCommand(manager, ['config', 'get', 'enableGlobalCache'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} global cache policy inspection`,
    })
    assert.equal(globalCache.stdout, 'false\n')
    assert.equal(globalCache.stderr, '')
    const cacheFolder = successfulManagerCommand(manager, ['config', 'get', 'cacheFolder'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} confined cache inspection`,
    })
    assert.equal(cacheFolder.stderr, '')
    const cacheRoot = fs.realpathSync(cacheFolder.stdout.trim())
    const relativeCache = path.relative(fs.realpathSync(managerRoot), cacheRoot)
    assert.equal(path.isAbsolute(relativeCache), false)
    assert.doesNotMatch(relativeCache, /^\.\.(?:[/\\]|$)/)

    const resolvedManifest = successfulManagerCommand(manager, [
      'node',
      '--eval',
      "process.stdout.write(require.resolve('zigcss/package.json'))",
    ], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} PnP package resolution`,
    })
    assert.equal(resolvedManifest.stderr, '')
    const manifestPath = fs.realpathSync(resolvedManifest.stdout)
    const relativeManifest = path.relative(fs.realpathSync(consumer), manifestPath)
    assert.equal(path.isAbsolute(relativeManifest), false)
    assert.doesNotMatch(relativeManifest, /^\.\.(?:[/\\]|$)/)
    assert.match(
      relativeManifest,
      /^\.yarn[/\\]unplugged[/\\][^/\\]+[/\\]node_modules[/\\]zigcss[/\\]package\.json$/,
      'Yarn must unpack zigcss into its project-local writable PnP area',
    )
    const installedRoot = path.dirname(manifestPath)
    const installedStat = fs.lstatSync(installedRoot)
    assert.equal(installedStat.isDirectory(), true)
    assert.equal(installedStat.isSymbolicLink(), false)
    fs.accessSync(installedRoot, fs.constants.R_OK | fs.constants.W_OK)
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
    assert.equal(manifest.name, 'zigcss')
    assert.equal(manifest.version, rootManifest.version)
    assert.equal(manifest.preferUnplugged, true)
    assert.deepEqual(manifest.dependencies ?? {}, {})
    assert.deepEqual(manifest.optionalDependencies ?? {}, {})
    assert.deepEqual(manifest.bin, { zigcss: 'index.js', 'zigcss-install': 'install.js' })
    verifyNativeIntegritySurface(installedRoot, manifest)
    assert.equal(fs.existsSync(path.join(installedRoot, 'bin')), false)
    verifyYarnPnpPackageSurface(manager, consumer, installedRoot, manifest, environment)

    const missing = exactManagerCommand(manager, ['zigcss', '--version'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} lifecycle-disabled recovery diagnostic`,
    })
    assert.equal(missing.signal, null)
    assert.equal(missing.status, 1)
    assert.equal(missing.stdout, '')
    assert.equal(missing.stderr, missingBinaryStderr)

    const { descriptor, releaseRoot } = preloadedRelease
    trustLocalFixtureInInstalledCopy(installedRoot, preloadedRelease)
    const recoveryEnvironment = {
      ...environment,
      NODE_OPTIONS: `--require=${JSON.stringify(releasePreload)}`,
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: descriptor.assets.archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: releaseRoot,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: descriptor.assets.checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: descriptor.version,
    }
    const recovered = successfulManagerCommand(manager, ['zigcss-install'], {
      cwd: consumer,
      env: recoveryEnvironment,
      label: `${manager.label} controlled offline recovery`,
    })
    assert.equal(
      recovered.stdout,
      [
        `Downloading and verifying zigcss ${descriptor.version} for ${descriptor.target}...`,
        `Verified and installed zigcss ${descriptor.version} for ${descriptor.target}`,
        '',
      ].join('\n'),
    )
    assert.equal(recovered.stderr, '')
    const installedBinary = path.join(installedRoot, 'bin', descriptor.binaryName)
    regularFile(
      installedBinary,
      'PnP-recovered native binary',
      repositoryInstaller.installLimits.maximumBinaryBytes,
    )
    if (process.platform !== 'win32') fs.accessSync(installedBinary, fs.constants.X_OK)

    const executed = successfulManagerCommand(manager, ['zigcss', '--version'], {
      cwd: consumer,
      env: environment,
      label: `${manager.label} recovered native binary execution`,
    })
    assert.equal(executed.stdout, `${process.version}\n`)
    assert.equal(executed.stderr, '')
    assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'PnP recovery must not create node_modules')
  } finally {
    fs.rmSync(managerRoot, { recursive: true, force: true })
  }
}

before(() => {
  const npm = managers.find(manager => manager.id === 'npm')
  assert.equal(npm.cli.missing, false, 'npm is mandatory for the package-manager matrix')
  assert.equal(npm.cli.error, undefined, `npm CLI is unusable: ${npm.cli.error}`)
  verifyGitHubActionsToolchain(managers)
  matrixRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-matrix-'))
  const archiveDirectory = confinedTemporaryDirectory('archive')
  const environment = offlineEnvironment(matrixRoot)
  const packed = successful(npm.cli.command, [
    'pack',
    '--ignore-scripts',
    '--json',
    '--pack-destination', archiveDirectory,
  ], {
    cwd: repositoryRoot,
    env: environment,
    label: 'single npm package-manager matrix pack',
    maxBuffer: maximumPackOutputBytes,
  })
  packageArchive = path.join(archiveDirectory, `zigcss-${rootManifest.version}.tgz`)
  packageArchiveDigest = hashFileSha256(packageArchive, maximumPackOutputBytes)
  const inspection = inspectNpmPackageArchive(packageArchive, rootManifest.version)
  validatePackDescription(packed.stdout, inspection)
  const pnpManager = managers.find(manager => manager.id === 'yarn-modern-pnp')
  if (pnpManager.cli.missing === false && pnpManager.cli.error === undefined) {
    preloadedRelease = createLocalReleaseFixture()
    pnpTypescriptPackageRoot = createLocalPnpTypescriptFixture()
  }
})

after(() => {
  try {
    if (matrixRoot !== undefined) {
      const relative = path.relative(os.tmpdir(), matrixRoot)
      assert.equal(path.isAbsolute(relative), false)
      assert.match(relative, /^zigcss-package-manager-matrix-[^/\\]+$/)
      fs.rmSync(matrixRoot, { recursive: true, force: true })
    }
  } finally {
    try {
      const relative = path.relative(os.tmpdir(), toolchainRoot)
      assert.equal(path.isAbsolute(relative), false)
      assert.match(relative, /^zigcss-package-manager-toolchain-[^/\\]+$/)
      inspectBoundedToolchainRoot()
    } finally {
      fs.rmSync(toolchainRoot, { recursive: true, force: true })
    }
    assert.equal(fs.existsSync(toolchainRoot), false, 'package-manager toolchain root must be removed')
  }
})

test('Corepack exact toolchain state is bounded, confined, and reused offline', () => {
  assert.equal(toolchainOfflineEnvironment.COREPACK_HOME, corepackHome)
  assert.equal(toolchainDetectionEnvironment.COREPACK_HOME, corepackHome)
  assert.equal(toolchainOfflineEnvironment.COREPACK_ENABLE_NETWORK, '0')
  assert.equal(toolchainDetectionEnvironment.COREPACK_ENABLE_NETWORK, '1')
  const relative = path.relative(fs.realpathSync(toolchainRoot), fs.realpathSync(corepackHome))
  assert.equal(path.isAbsolute(relative), false)
  assert.doesNotMatch(relative, /^\.\.(?:[/\\]|$)/)
  const inspection = inspectBoundedToolchainRoot()
  assert.equal(inspection.entries > 0, true)
  assert.equal(inspection.bytes <= maximumToolchainBytes, true)
})

test('package-manager command policy disables lifecycle scripts and registry access', () => {
  const managerRoot = path.join(matrixRoot, 'argument-policy')
  fs.mkdirSync(managerRoot, { mode: 0o700 })
  const npmArgs = installArguments({ family: 'npm' }, managerRoot)
  const pnpmArgs = installArguments({ family: 'pnpm' }, managerRoot)
  const bunArgs = installArguments({ family: 'bun' }, managerRoot)
  const yarnClassicArgs = installArguments({ family: 'yarn', variant: 'classic' }, managerRoot)
  const yarnModernArgs = installArguments({ family: 'yarn', variant: 'modern' }, managerRoot)
  assert.equal(npmArgs.includes('--ignore-scripts'), true)
  assert.equal(npmArgs.includes('--offline'), true)
  assert.equal(pnpmArgs.includes('--ignore-scripts'), true)
  assert.equal(pnpmArgs.includes('--offline'), true)
  assert.equal(bunArgs.includes('--ignore-scripts'), true)
  assert.equal(bunArgs.includes('--offline'), true)
  assert.equal(yarnClassicArgs.includes('--ignore-scripts'), true)
  assert.equal(yarnClassicArgs.includes('--offline'), true)
  assert.equal(yarnModernArgs.includes('--mode=skip-build'), true)
  assert.equal(yarnModernArgs.includes('--ignore-scripts'), false)
  assert.deepEqual(
    managerCommandArguments(
      { cli: { commandPrefix: [`yarn@${packageManagerVersions.yarnModern}`] } },
      yarnModernArgs,
    ).slice(0, 2),
    [`yarn@${packageManagerVersions.yarnModern}`, 'add'],
  )
  const nodeModulesRoot = path.join(managerRoot, 'node-modules-policy')
  const pnpRoot = path.join(managerRoot, 'pnp-policy')
  fs.mkdirSync(nodeModulesRoot, { mode: 0o700 })
  fs.mkdirSync(pnpRoot, { mode: 0o700 })
  const nodeModulesEnvironment = offlineEnvironment(nodeModulesRoot, {
    family: 'yarn',
    nodeLinker: 'node-modules',
    variant: 'modern',
  })
  const pnpEnvironment = offlineEnvironment(pnpRoot, {
    family: 'yarn',
    pnp: true,
    variant: 'modern',
  })
  for (const environment of [nodeModulesEnvironment, pnpEnvironment]) {
    assert.equal(environment.YARN_ENABLE_NETWORK, 'false')
    assert.equal(environment.YARN_ENABLE_SCRIPTS, 'false')
    assert.equal(environment.COREPACK_ENABLE_NETWORK, '0')
    assert.equal(environment.COREPACK_HOME, corepackHome)
    assert.equal(environment.npm_config_offline, 'true')
    assert.match(environment.npm_config_registry, /^http:\/\/127\.0\.0\.1:9\//)
  }
  assert.equal(nodeModulesEnvironment.YARN_NODE_LINKER, 'node-modules')
  assert.equal(Object.hasOwn(pnpEnvironment, 'YARN_NODE_LINKER'), false)
  for (const environment of [nodeModulesEnvironment, pnpEnvironment]) {
    assert.equal(environment.YARN_ENABLE_COLORS, 'false')
    assert.equal(environment.YARN_ENABLE_GLOBAL_CACHE, 'false')
    assert.match(environment.YARN_GLOBAL_FOLDER, /[/\\]cache[/\\]yarn-global$/)
  }
})

test('package-manager toolchain pins both Yarn generations and the CI Bun release', () => {
  assert.deepEqual(packageManagerVersions, {
    pnpm: '11.25.0',
    yarnClassic: '1.22.22',
    yarnModern: '4.9.4',
    bun: '1.4.0',
  })
  for (const manager of managers.filter(candidate => candidate.cli.expectedVersion !== undefined)) {
    if (manager.cli.missing) continue
    assert.equal(manager.cli.error, undefined, `${manager.label} CLI is unusable: ${manager.cli.error}`)
    assert.equal(manager.cli.version, manager.cli.expectedVersion)
    if (manager.cli.provider === 'corepack') {
      const corepackName = manager.family === 'yarn' ? 'yarn' : manager.family
      assert.deepEqual(manager.cli.commandPrefix, [`${corepackName}@${manager.cli.expectedVersion}`])
    } else {
      assert.equal(manager.cli.provider, 'direct')
      assert.deepEqual(manager.cli.commandPrefix, [])
    }
  }

  assert.doesNotThrow(() => verifyGitHubActionsToolchain([
    {
      label: 'Bun',
      mandatoryInGitHubActions: true,
      expectedCiVersion: packageManagerVersions.bun,
      cli: { missing: false, version: packageManagerVersions.bun },
    },
  ], true))
  assert.throws(() => verifyGitHubActionsToolchain([
    {
      label: 'Bun',
      mandatoryInGitHubActions: true,
      expectedCiVersion: packageManagerVersions.bun,
      cli: { missing: false, version: '1.3.14' },
    },
  ], true), /must use exact version 1\.4\.0/)
  assert.throws(() => verifyGitHubActionsToolchain([
    {
      label: `Yarn Modern ${packageManagerVersions.yarnModern}`,
      mandatoryInGitHubActions: true,
      cli: { missing: true, expectedVersion: packageManagerVersions.yarnModern },
    },
  ], true), /mandatory in GitHub Actions/)
})

for (const manager of managers) {
  const skip = !manager.mandatory && manager.cli.missing
    ? `${manager.label} CLI is not installed on PATH`
    : false
  test(manager.testName, { skip }, () => {
    if (manager.pnp) verifyYarnPnpPackage(manager)
    else verifyInstalledPackage(manager)
  })
}
