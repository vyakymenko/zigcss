#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import {
  expectedPackedFiles,
  validatePackageDescription,
} from './validate-preprocessor-package.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'
import { assertArtifactMatchesTarget } from './verify-artifact-target.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const maximumArchiveBytes = 512 * 1024 * 1024
const maximumBinaryBytes = 256 * 1024 * 1024
const maximumOutputBytes = 1024 * 1024
const maximumInstalledBytes = 128 * 1024 * 1024
const maximumInstalledEntries = 20_000
const childTimeoutMs = 60 * 1000

export const nativeSmokeTargets = Object.freeze([
  Object.freeze({ target: 'x86_64-linux', runner: 'ubuntu-latest', nodePlatform: 'linux', nodeArch: 'x64', binaryName: 'zigcss' }),
  Object.freeze({ target: 'aarch64-linux', runner: 'ubuntu-24.04-arm', nodePlatform: 'linux', nodeArch: 'arm64', binaryName: 'zigcss' }),
  Object.freeze({ target: 'x86_64-macos', runner: 'macos-15-intel', nodePlatform: 'darwin', nodeArch: 'x64', binaryName: 'zigcss' }),
  Object.freeze({ target: 'aarch64-macos', runner: 'macos-15', nodePlatform: 'darwin', nodeArch: 'arm64', binaryName: 'zigcss' }),
  Object.freeze({ target: 'x86_64-windows', runner: 'windows-latest', nodePlatform: 'win32', nodeArch: 'x64', binaryName: 'zigcss.exe' }),
])

function fail(message) {
  throw new Error(`release smoke integrity: ${message}`)
}

export function archiveExecutable(platform = process.platform, systemRoot = process.env.SystemRoot) {
  if (platform !== 'win32') return 'tar'
  // Git Bash can shadow Windows' ZIP-capable bsdtar with GNU tar.
  if (
    typeof systemRoot !== 'string'
    || systemRoot.includes('\0')
    || !/^[A-Za-z]:[\\/]/.test(systemRoot)
    || !path.win32.isAbsolute(systemRoot)
  ) {
    fail('Windows system root must be an absolute local drive path')
  }
  return path.win32.join(systemRoot, 'System32', 'tar.exe')
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function expectLiteralCount(source, literal, count, label) {
  let actual = 0
  let cursor = 0
  while (true) {
    const index = source.indexOf(literal, cursor)
    if (index === -1) break
    actual += 1
    cursor = index + literal.length
  }
  if (actual !== count) fail(`${label} must occur ${count} times, received ${actual}`)
}

function expectOrdered(source, labels, label) {
  let cursor = -1
  for (const item of labels) {
    const index = source.indexOf(item, cursor + 1)
    if (index === -1 || index <= cursor) fail(`${label} is missing or reorders ${item}`)
    cursor = index
  }
}

function namedStep(source, name, label) {
  const marker = `      - name: ${name}`
  const start = source.indexOf(marker)
  if (start === -1 || source.indexOf(marker, start + marker.length) !== -1) fail(`${label} must occur exactly once`)
  const end = source.indexOf('\n      - name:', start + marker.length)
  return source.slice(start, end === -1 ? source.length : end)
}

function buildWorkflowTargets(source) {
  const expression = /          - os: ([^\n]+)\n            arch: ([^\n]+)\n            target: ([^\n]+)\n            archive-extension: ([^\n]+)\n            zig-version: ([^\n]+)\n            binary-name: ([^\n]+)/g
  return [...source.matchAll(expression)].map(match => ({
    runner: match[1],
    arch: match[2],
    target: match[3],
    archiveExtension: match[4],
    zigVersion: match[5],
    binaryName: match[6],
  }))
}

function releaseWorkflowTargets(source) {
  return buildWorkflowTargets(source)
}

function expectedWorkflowTargets() {
  return nativeSmokeTargets.map(smoke => {
    const release = releaseTargets.find(candidate => candidate.target === smoke.target)
    if (release === undefined) fail(`native smoke target ${smoke.target} has no release target`)
    return {
      runner: smoke.runner,
      arch: release.arch,
      target: release.target,
      archiveExtension: release.archiveExtension,
      zigVersion: '0.15.2',
      binaryName: release.binaryName,
    }
  })
}

export function validateReleaseSmokeWorkflowSources(buildSource, releaseSource) {
  for (const [name, source] of [['build', buildSource], ['release', releaseSource]]) {
    if (typeof source !== 'string' || Buffer.byteLength(source) > 256 * 1024) fail(`${name} workflow is missing or oversized`)
    if (source.includes('continue-on-error')) fail(`${name} workflow must fail closed without continue-on-error`)
  }

  const expected = expectedWorkflowTargets()
  const build = buildWorkflowTargets(buildSource)
  const release = releaseWorkflowTargets(releaseSource)
  if (!same(build, expected)) fail('build native runner matrix does not match the five-target release contract')
  if (!same(release, expected)) fail('release native runner matrix does not match the five-target release contract')

  const smokeStep = '- name: Smoke Native Archive and npm Installation'
  const smokeCommand = 'node scripts/smoke-release-artifact.mjs \\'
  expectLiteralCount(buildSource, smokeStep, 1, 'build native smoke step')
  expectLiteralCount(releaseSource, smokeStep, 1, 'release native smoke step')
  const smokeSteps = [
    namedStep(buildSource, 'Smoke Native Archive and npm Installation', 'build native smoke step'),
    namedStep(releaseSource, 'Smoke Native Archive and npm Installation', 'release native smoke step'),
  ]
  for (const source of smokeSteps) {
    expectLiteralCount(source, smokeCommand, 1, 'native smoke command')
    expectLiteralCount(source, '--archive "release-assets/$RELEASE_ARCHIVE" \\', 1, 'smoke archive argument')
    expectLiteralCount(source, '--binary "zig-out/bin/${{ matrix.binary-name }}" \\', 1, 'smoke binary argument')
    expectLiteralCount(source, '--target "${{ matrix.target }}" \\', 1, 'smoke target argument')
    expectLiteralCount(source, '--version "$RELEASE_VERSION"', 1, 'smoke version argument')
  }

  expectOrdered(buildSource, [
    '- name: Setup Node.js',
    '- name: Run Native Tests',
    '- name: Build Target Binary',
    '- name: Verify Target Architecture',
    '- name: Plan Native Smoke Assets',
    '- name: Create Native Smoke Archive',
    '- name: Generate Native Smoke Metadata',
    smokeStep,
    '- name: Upload Artifact',
  ], 'build native smoke pipeline')
  expectOrdered(releaseSource, [
    '- name: Verify Release Metadata',
    smokeStep,
    '- name: Attest Release Provenance',
    '- name: Upload Release Assets',
    '  create-release:',
  ], 'release native smoke pipeline')

  return { buildTargets: build.length, releaseTargets: release.length, smokeCommands: 2 }
}

export function parseSmokeArguments(args) {
  if (!Array.isArray(args) || args.length !== 8) fail('expected exactly four named smoke arguments')
  const allowed = new Set(['--archive', '--binary', '--target', '--version'])
  const values = {}
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!allowed.has(name)) fail(`unknown smoke argument ${JSON.stringify(name)}`)
    if (Object.hasOwn(values, name)) fail(`duplicate smoke argument ${name}`)
    if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) fail(`${name} has an invalid value`)
    values[name] = value
  }
  for (const name of allowed) if (!Object.hasOwn(values, name)) fail(`missing smoke argument ${name}`)
  try {
    parseReleaseVersion(values['--version'], 'release smoke version')
  } catch (error) {
    fail(error.message)
  }
  if (!nativeSmokeTargets.some(item => item.target === values['--target'])) {
    fail(`unsupported release smoke target ${JSON.stringify(values['--target'])}`)
  }
  return {
    archive: values['--archive'],
    binary: values['--binary'],
    target: values['--target'],
    version: values['--version'],
  }
}

function canonicalRoot(root) {
  try {
    return fs.realpathSync(root)
  } catch (error) {
    fail(`repository root is unavailable: ${error.message}`)
  }
}

function confinedRegularFile(root, relativePath, label, maximumBytes) {
  if (typeof relativePath !== 'string' || path.isAbsolute(relativePath) || relativePath.includes('\0')) fail(`${label} must be a relative path`)
  let canonicalRootValue
  try {
    canonicalRootValue = fs.realpathSync(root)
  } catch (error) {
    fail(`${label} root is unavailable: ${error.message}`)
  }
  const candidate = path.resolve(canonicalRootValue, relativePath)
  const relative = path.relative(canonicalRootValue, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) fail(`${label} escapes the repository`)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size <= 0 || stat.size > maximumBytes) fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  const canonical = fs.realpathSync(candidate)
  const canonicalRelative = path.relative(canonicalRootValue, canonical)
  if (canonicalRelative === '..' || canonicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(canonicalRelative)) fail(`${label} escapes the repository`)
  return canonical
}

function hashFile(filename) {
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(filename, 'r')
  const buffer = Buffer.allocUnsafe(64 * 1024)
  try {
    while (true) {
      const length = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (length === 0) break
      hash.update(buffer.subarray(0, length))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return hash.digest('hex')
}

function child(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    encoding: 'utf8',
    input: options.input,
    maxBuffer: maximumOutputBytes,
    timeout: childTimeoutMs,
    windowsHide: true,
  })
  if (result.error !== undefined) fail(`${options.label ?? command} failed to start: ${result.error.message}`)
  if (result.status !== 0 || result.signal !== null) {
    fail(`${options.label ?? command} failed: ${result.stderr || result.stdout || result.signal || `exit ${result.status}`}`)
  }
  return result
}

function npmCliPath() {
  const executableDirectory = path.dirname(process.execPath)
  const candidates = [
    process.env.npm_execpath,
    path.resolve(executableDirectory, '../lib/node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, '../node_modules/npm/bin/npm-cli.js'),
    path.resolve(executableDirectory, 'node_modules/npm/bin/npm-cli.js'),
  ].filter(candidate => typeof candidate === 'string' && candidate.length > 0)
  for (const candidate of candidates) {
    try {
      const stat = fs.lstatSync(candidate)
      if ((stat.isFile() || stat.isSymbolicLink()) && fs.statSync(candidate).isFile()) return fs.realpathSync(candidate)
    } catch {
      // Try the next deterministic Node installation layout.
    }
  }
  fail('npm CLI could not be resolved beside the active Node executable')
}

function runNpm(args, options = {}) {
  return child(process.execPath, [npmCliPath(), ...args], { ...options, label: options.label ?? 'npm' })
}

function checkCompiler(command, argsPrefix, working, version, label) {
  const versionResult = child(command, [...argsPrefix, '--version'], { cwd: working, label: `${label} version smoke` })
  if (versionResult.stdout !== `zigcss ${version}\n` || versionResult.stderr !== '') fail(`${label} returned an unexpected version contract`)

  const input = path.join(working, `${label.replace(/[^a-z]+/g, '-')}.css`)
  fs.writeFileSync(input, '.smoke { color: red; }\n')
  const compile = child(command, [...argsPrefix, input, '--minify'], { cwd: working, label: `${label} compile smoke` })
  const warning = `Warning: ZigCSS ${version} is an experimental release candidate; do not use it for production CSS.\n`
  if (compile.stdout !== '.smoke{color:red}' || compile.stderr !== warning) fail(`${label} returned an unexpected compiler contract`)
}

function validatePackageInventory(packResult, version) {
  let parsed
  try {
    parsed = JSON.parse(packResult.stdout)
  } catch (error) {
    fail(`npm pack did not return JSON: ${error.message}`)
  }
  if (!Array.isArray(parsed) || parsed.length !== 1) fail('npm pack must return exactly one package description')
  try {
    return validatePackageDescription(parsed[0], version)
  } catch (error) {
    fail(error.message)
  }
}

function treeInventory(root, relative = '') {
  const directory = path.join(root, relative)
  const rows = []
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryRelative = path.join(relative, entry.name)
    const filename = path.join(root, entryRelative)
    const stat = fs.lstatSync(filename)
    if (entry.isDirectory()) {
      if (stat.isSymbolicLink()) fail('installed tree contains a directory symlink')
      rows.push(...treeInventory(root, entryRelative))
    } else if (entry.isFile() || entry.isSymbolicLink()) {
      rows.push({
        path: entryRelative.split(path.sep).join('/'),
        bytes: stat.size,
      })
    } else {
      fail('installed tree contains a special file')
    }
    if (rows.length > maximumInstalledEntries) fail('installed tree exceeds its entry limit')
  }
  return rows
}

function measureInstalledTree(root) {
  const rows = treeInventory(root)
  const bytes = rows.reduce((total, row) => total + row.bytes, 0)
  if (bytes <= 0 || bytes > maximumInstalledBytes) fail('installed tree exceeds its byte limit')
  return { entries: rows.length, bytes }
}

function validateInstalledPackageFiles(installedRoot, binaryName) {
  const rows = treeInventory(installedRoot)
    .map(row => row.path)
    .filter(relative => relative !== `bin/${binaryName}`)
    .sort()
  if (!same(rows, expectedPackedFiles)) fail('installed ZigCSS package file inventory changed')
}

function checkCanonicalPreprocessors(wrapper, working, environment) {
  const cases = [
    {
      extension: 'scss',
      source: '$color: red;\n.scss { color: $color; }\n',
      expected: '.scss {\n  color: red;\n}\n',
    },
    {
      extension: 'sass',
      source: '$color: red\n.sass\n  color: $color\n',
      expected: '.sass {\n  color: red;\n}\n',
    },
    {
      extension: 'less',
      source: '@color: red;\n.less { color: @color; }\n',
      expected: '.less {\n  color: red;\n}\n',
    },
    {
      extension: 'styl',
      source: '.styl\n  color red\n',
      expected: '.styl {\n  color: #f00;\n}\n',
    },
  ]
  for (const item of cases) {
    const input = path.join(working, `canonical.${item.extension}`)
    fs.writeFileSync(input, item.source)
    const result = child(process.execPath, [wrapper, input], {
      cwd: working,
      env: environment,
      label: `${item.extension} offline compile smoke`,
    })
    if (result.stdout !== item.expected || result.stderr !== '') {
      fail(`${item.extension} returned an unexpected offline compiler contract`)
    }
  }
  return cases.length
}

function checkCanonicalApi(consumer, environment) {
  const script = path.join(consumer, 'api-smoke.mjs')
  fs.writeFileSync(script, [
    "import { SUPPORTED_SYNTAXES, compileString } from 'zigcss/api'",
    "const result = await compileString('$color: red; .api { color: $color; }', { syntax: 'scss' })",
    "process.stdout.write(JSON.stringify({ syntaxes: SUPPORTED_SYNTAXES, css: result.css }))",
    '',
  ].join('\n'))
  const result = child(process.execPath, [script], {
    cwd: consumer,
    env: environment,
    label: 'npm API offline compile smoke',
  })
  const expected = JSON.stringify({
    syntaxes: ['css', 'scss', 'sass', 'less', 'stylus'],
    css: '.api {\n  color: red;\n}\n',
  })
  if (result.stdout !== expected || result.stderr !== '') fail('npm API returned an unexpected offline compiler contract')
}

function nodeOptionsRequire(filename) {
  if (filename.includes('\0') || filename.includes('"')) fail('preload path cannot be represented safely in NODE_OPTIONS')
  return `--require="${filename.replaceAll('\\', '/')}"`
}

function confinedExecutableShim(root, relativePath, expectedTarget) {
  const candidate = path.resolve(root, relativePath)
  const relative = path.relative(root, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) fail('npm executable shim escapes the consumer root')
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`npm executable shim is unavailable: ${error.message}`)
  }
  if (process.platform === 'win32') {
    if (!stat.isFile() || stat.isSymbolicLink()) fail('npm executable shim must be a regular Windows command file')
    if (stat.size <= 0 || stat.size > 64 * 1024) fail('npm executable shim size is invalid')
    return
  }
  if (!stat.isSymbolicLink()) fail('npm executable shim must be a symlink on POSIX')
  if (fs.realpathSync(candidate) !== fs.realpathSync(expectedTarget)) fail('npm executable shim does not resolve to the packaged wrapper')
}

export function smokeReleaseArtifact(options) {
  const root = canonicalRoot(options.root ?? repositoryRoot)
  const version = parseReleaseVersion(options.version, 'release smoke version').value
  const policy = nativeSmokeTargets.find(item => item.target === options.target)
  if (policy === undefined) fail(`unsupported release smoke target ${JSON.stringify(options.target)}`)
  if (process.platform !== policy.nodePlatform || process.arch !== policy.nodeArch) {
    fail(`target ${policy.target} requires native host ${policy.nodePlatform}/${policy.nodeArch}, received ${process.platform}/${process.arch}`)
  }

  const assets = releaseAssetsFor(version, policy.target)
  const expectedArchive = `release-assets/${assets.archive}`
  const expectedBinary = `zig-out/bin/${policy.binaryName}`
  if (options.archive !== expectedArchive) fail(`release archive path must be ${expectedArchive}`)
  if (options.binary !== expectedBinary) fail(`release binary path must be ${expectedBinary}`)
  const archive = confinedRegularFile(root, options.archive, 'release archive', maximumArchiveBytes)
  const binary = confinedRegularFile(root, options.binary, 'release binary', maximumBinaryBytes)
  const checksums = confinedRegularFile(root, `release-assets/${assets.checksums}`, 'release checksum manifest', 64 * 1024)
  confinedRegularFile(root, `release-assets/${assets.sbom}`, 'release SPDX SBOM', 16 * 1024 * 1024)
  const assetRoot = path.join(root, 'release-assets')
  const inventory = fs.readdirSync(assetRoot).sort()
  if (!same(inventory, [assets.archive, assets.checksums, assets.sbom].sort())) fail('pre-attestation release asset inventory must contain exactly archive, checksums, and SBOM')
  assertArtifactMatchesTarget(fs.readFileSync(binary), policy.target)

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-native-release-smoke-'))
  try {
    const archiveReader = archiveExecutable()
    const listing = child(archiveReader, ['-tf', archive], { cwd: temporary, label: 'release archive listing' })
    if (listing.stdout.replaceAll('\r\n', '\n') !== `${policy.binaryName}\n` || listing.stderr !== '') {
      fail(`release archive must contain exactly ${policy.binaryName}`)
    }
    const directDirectory = path.join(temporary, 'direct')
    fs.mkdirSync(directDirectory)
    child(archiveReader, ['-xf', archive, '-C', directDirectory], { cwd: temporary, label: 'release archive extraction' })
    const directBinary = confinedRegularFile(directDirectory, policy.binaryName, 'direct archive binary', maximumBinaryBytes)
    if (hashFile(directBinary) !== hashFile(binary)) fail('direct archive binary differs from the release binary')
    if (process.platform !== 'win32') fs.chmodSync(directBinary, 0o755)
    checkCompiler(directBinary, [], temporary, version, 'direct archive binary')

    const packDirectory = path.join(temporary, 'pack')
    fs.mkdirSync(packDirectory)
    const npmEnvironment = {
      ...process.env,
      npm_config_audit: 'false',
      npm_config_cache: path.join(temporary, 'npm-cache'),
      npm_config_fund: 'false',
      npm_config_update_notifier: 'false',
    }
    const packed = runNpm([
      'pack', root,
      '--ignore-scripts',
      '--json',
      '--pack-destination', packDirectory,
    ], { cwd: temporary, env: npmEnvironment, label: 'npm pack smoke' })
    const packageName = validatePackageInventory(packed, version)
    const packageArchive = path.join(packDirectory, packageName)
    confinedRegularFile(packDirectory, packageName, 'npm package archive', 2 * 1024 * 1024)

    const warmConsumer = path.join(temporary, 'lifecycle-disabled-consumer')
    fs.mkdirSync(warmConsumer)
    fs.writeFileSync(path.join(warmConsumer, 'package.json'), '{"name":"zigcss-lifecycle-disabled-smoke","private":true,"version":"1.0.0"}\n')
    runNpm([
      'install', packageArchive,
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
    ], { cwd: warmConsumer, env: npmEnvironment, label: 'npm lifecycle-disabled clean install smoke' })
    const warmInstalledRoot = path.join(warmConsumer, 'node_modules', 'zigcss')
    confinedRegularFile(warmInstalledRoot, 'api.mjs', 'lifecycle-disabled npm API', 64 * 1024)
    if (fs.existsSync(path.join(warmInstalledRoot, 'bin'))) {
      fail('lifecycle-disabled installation unexpectedly created a native binary directory')
    }
    measureInstalledTree(path.join(warmConsumer, 'node_modules'))
    fs.rmSync(warmConsumer, { recursive: true, force: true })

    const consumer = path.join(temporary, 'consumer')
    fs.mkdirSync(consumer)
    fs.writeFileSync(path.join(consumer, 'package.json'), '{"name":"zigcss-release-smoke","private":true,"version":"1.0.0"}\n')
    const preload = confinedRegularFile(root, 'scripts/release-smoke-preload.cjs', 'release smoke preload', 64 * 1024)
    const installEnvironment = {
      ...npmEnvironment,
      NODE_OPTIONS: nodeOptionsRequire(preload),
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: assets.archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: assetRoot,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: assets.checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: version,
    }
    runNpm([
      'install', packageArchive,
      '--offline',
      '--no-audit',
      '--no-fund',
      '--foreground-scripts',
    ], { cwd: consumer, env: installEnvironment, label: 'npm postinstall smoke' })

    const installedRoot = path.join(consumer, 'node_modules', 'zigcss')
    const installedBinary = confinedRegularFile(installedRoot, `bin/${policy.binaryName}`, 'npm-installed binary', maximumBinaryBytes)
    if (hashFile(installedBinary) !== hashFile(binary)) fail('npm-installed binary differs from the release binary')
    const shimName = process.platform === 'win32' ? 'zigcss.cmd' : 'zigcss'
    const wrapper = confinedRegularFile(installedRoot, 'index.js', 'npm wrapper', 64 * 1024)
    confinedExecutableShim(consumer, `node_modules/.bin/${shimName}`, wrapper)
    checkCompiler(process.execPath, [wrapper], temporary, version, 'npm wrapper')
    validateInstalledPackageFiles(installedRoot, policy.binaryName)

    const installedEntries = fs.readdirSync(path.join(installedRoot, 'bin')).sort()
    if (!same(installedEntries, [policy.binaryName])) fail('npm binary directory contains unexpected files')
    if (fs.readdirSync(path.join(installedRoot, 'bin')).some(name => name.startsWith('.install-'))) fail('npm installer left temporary files')

    fs.rmSync(npmEnvironment.npm_config_cache, { recursive: true, force: true })
    const offlineEnvironment = {
      ...installEnvironment,
      npm_config_offline: 'true',
      ZIGCSS_RELEASE_SMOKE_RUNTIME: '1',
    }
    const providerSmokes = checkCanonicalPreprocessors(wrapper, temporary, offlineEnvironment)
    checkCanonicalApi(consumer, offlineEnvironment)
    const installed = measureInstalledTree(path.join(consumer, 'node_modules'))

    return {
      target: policy.target,
      archiveSha256: hashFile(archive),
      checksumsSha256: hashFile(checksums),
      installedBytes: installed.bytes,
      installedEntries: installed.entries,
      npmPackage: packageName,
      providerSmokes,
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function main() {
  try {
    const options = parseSmokeArguments(process.argv.slice(2))
    const result = smokeReleaseArtifact(options)
    process.stdout.write(
      `Native release smoke passed for ${result.target}: direct archive, lifecycle-disabled clean install, offline postinstall, ${result.providerSmokes} canonical provider compiles, API, and ${result.installedEntries} installed entries/${result.installedBytes} bytes.\n`,
    )
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}

if (process.argv[1] !== undefined && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) main()
