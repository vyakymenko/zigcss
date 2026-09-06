#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { nativeTargetContract } from './native-target-contract.mjs'
import { inspectNpmPackageArchive } from './npm-package-artifact.mjs'
import {
  expectedPackedFiles,
  validatePackageDescription,
} from './validate-preprocessor-package.mjs'
import { validateNativeIntegritySources } from './validate-native-integrity.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'
import { assertArtifactMatchesTarget } from './verify-artifact-target.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const maximumArchiveBytes = 512 * 1024 * 1024
const maximumBinaryBytes = 256 * 1024 * 1024
const maximumOutputBytes = 1024 * 1024
const maximumInstalledBytes = 128 * 1024 * 1024
const maximumInstalledEntries = 20_000
const maximumRuntimeTraceBytes = 64 * 1024
const childTimeoutMs = 60 * 1000
const posixArchivePolicies = Object.freeze({
  darwin: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar']),
    resolved: Object.freeze(['/usr/bin/tar', '/usr/bin/bsdtar']),
  }),
  linux: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar', '/bin/tar']),
    resolved: Object.freeze([
      '/usr/bin/tar',
      '/bin/tar',
      '/usr/bin/bsdtar',
      '/bin/bsdtar',
      '/usr/bin/gtar',
      '/bin/gtar',
      '/usr/bin/busybox',
      '/bin/busybox',
    ]),
  }),
})
const posixArchiveEnvironment = Object.freeze({
  LANG: 'C',
  LC_ALL: 'C',
  PATH: '/usr/bin:/bin',
})
const runtimeTraceLauncher = [
  "const { spawn } = require('node:child_process')",
  "const child = spawn(process.argv[1], process.argv.slice(2), { stdio: 'inherit', cwd: process.cwd() })",
  "child.on('error', error => { throw error })",
  "child.on('exit', (code, signal) => { if (signal) process.kill(process.pid, signal); else process.exitCode = code ?? 1 })",
].join('\n')

export const nativeSmokeTargets = Object.freeze(nativeTargetContract.map(target => Object.freeze({
  target: target.target,
  runner: target.runner,
  nodePlatform: target.nodePlatform,
  nodeArch: target.nodeArch,
  binaryName: target.binaryName,
})))

export const nativePreprocessorSmokeCases = Object.freeze([
  Object.freeze({
    extension: 'scss',
    syntax: 'scss',
    source: '$color: red;\n.scss { color: $color; }\n',
    expected: '.scss {\n  color: red;\n}\n',
  }),
  Object.freeze({
    extension: 'sass',
    syntax: 'sass',
    source: '$color: red\n.sass\n  color: $color\n',
    expected: '.sass {\n  color: red;\n}\n',
  }),
  Object.freeze({
    extension: 'less',
    syntax: 'less',
    source: '@color: red;\n.less { color: @color; }\n',
    expected: '.less {\n  color: red;\n}\n',
  }),
  Object.freeze({
    extension: 'styl',
    syntax: 'stylus',
    source: '.styl\n  color red\n',
    expected: '.styl {\n  color: #f00;\n}\n',
  }),
])

const nativeTargetLanguages = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus'])
const packagedNodeApiModules = Object.freeze(['commonjs', 'esm'])
const nativeTargetEvidenceDirectory = 'native-target-evidence'

function fail(message) {
  throw new Error(`release smoke integrity: ${message}`)
}

export function compilerWarningForVersion(version) {
  const parsed = parseReleaseVersion(version, 'release smoke version')
  return parsed.prerelease === null
    ? ''
    : `Warning: ZigCSS ${parsed.value} is an experimental release candidate; do not use it for production CSS.\n`
}

function trustedPosixArchiveExecutable(platform, fileSystem = fs) {
  const policy = posixArchivePolicies[platform]
  if (policy === undefined) fail(`unsupported archive platform ${platform}`)
  for (const candidate of policy.candidates) {
    let descriptor
    try {
      const resolved = fileSystem.realpathSync(candidate)
      if (!path.posix.isAbsolute(resolved) || !policy.resolved.includes(resolved)) continue
      descriptor = fileSystem.openSync(
        resolved,
        fs.constants.O_RDONLY |
          (fs.constants.O_NOFOLLOW ?? 0) |
          (fs.constants.O_NONBLOCK ?? 0) |
          (fs.constants.O_CLOEXEC ?? 0),
      )
      const opened = fileSystem.fstatSync(descriptor)
      const after = fileSystem.lstatSync(resolved)
      const resolvedAfter = fileSystem.realpathSync(candidate)
      if (
        resolvedAfter !== resolved
        || !trustedPosixExecutableStat(opened)
        || !trustedPosixExecutableStat(after)
        || !samePosixExecutableIdentity(opened, after)
      ) {
        continue
      }
      return candidate
    } catch {
      // Try only the next finite system candidate; never consult PATH.
    } finally {
      if (descriptor !== undefined) fileSystem.closeSync(descriptor)
    }
  }
  fail(`no trusted system tar executable is available for ${platform}`)
}

function trustedPosixExecutableStat(stat) {
  return stat.isFile()
    && !stat.isSymbolicLink()
    && stat.uid === 0
    && (stat.mode & 0o022) === 0
    && (stat.mode & 0o111) !== 0
}

function samePosixExecutableIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.mode === right.mode
    && left.uid === right.uid
    && left.size === right.size
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs
}

const maximumSystemExecutableBytes = 256 * 1024 * 1024

function normalizedWindowsPathKey(input) {
  if (typeof input !== 'string') return null
  const withoutNamespace = /^\\\\\?\\[A-Za-z]:\\/.test(input) ? input.slice(4) : input
  let normalized = path.win32.normalize(withoutNamespace)
  const root = path.win32.parse(normalized).root
  while (normalized.length > root.length && /[\\/]$/.test(normalized)) {
    normalized = normalized.slice(0, -1)
  }
  return normalized.toLowerCase()
}

function sameWindowsPath(left, right) {
  const leftKey = normalizedWindowsPathKey(left)
  return leftKey !== null && leftKey === normalizedWindowsPathKey(right)
}

function canonicalWindowsPath(fileSystem, candidate) {
  const nativeRealpath = fileSystem.realpathSync?.native
  const resolver = typeof nativeRealpath === 'function' ? nativeRealpath : fileSystem.realpathSync
  if (typeof resolver !== 'function') throw new Error('canonical path resolution is unavailable')
  return Reflect.apply(resolver, fileSystem, [candidate])
}

function trustedWindowsDirectoryStat(stat) {
  return stat !== null && typeof stat === 'object'
    && typeof stat.isDirectory === 'function' && stat.isDirectory()
    && typeof stat.isSymbolicLink === 'function' && !stat.isSymbolicLink()
}

function trustedWindowsExecutableStat(stat) {
  if (
    stat === null || typeof stat !== 'object' ||
    typeof stat.isFile !== 'function' || !stat.isFile() ||
    typeof stat.isSymbolicLink !== 'function' || stat.isSymbolicLink()
  ) return false
  const size = stat.size
  return typeof size === 'bigint'
    ? size > 0n && size <= BigInt(maximumSystemExecutableBytes)
    : Number.isSafeInteger(size) && size > 0 && size <= maximumSystemExecutableBytes
}

function sameWindowsStatFields(left, right, fields) {
  return fields.every(name => left[name] !== undefined && right[name] !== undefined && left[name] === right[name])
}

function sameWindowsDirectoryIdentity(left, right) {
  return sameWindowsStatFields(left, right, ['dev', 'ino', 'mode'])
}

function sameWindowsExecutableIdentity(left, right) {
  return sameWindowsStatFields(left, right, [
    'dev',
    'ino',
    'mode',
    'nlink',
    'size',
    'mtimeNs',
    'ctimeNs',
  ])
}

function validatedWindowsSystemRoot(systemRoot) {
  if (
    typeof systemRoot !== 'string' || systemRoot.length === 0 || systemRoot.length > 32_767 ||
    /[\0-\x1f"]/.test(systemRoot) || !/^[A-Za-z]:[\\/]/.test(systemRoot) ||
    !path.win32.isAbsolute(systemRoot) || systemRoot.slice(2).includes(':')
  ) fail('Windows system root must be an absolute local drive path')
  const normalized = path.win32.normalize(systemRoot).replace(/[\\/]$/, '').toLowerCase()
  switch (normalized) {
    case 'a:\\windows': return 'A:\\Windows'
    case 'b:\\windows': return 'B:\\Windows'
    case 'c:\\windows': return 'C:\\Windows'
    case 'd:\\windows': return 'D:\\Windows'
    case 'e:\\windows': return 'E:\\Windows'
    case 'f:\\windows': return 'F:\\Windows'
    case 'g:\\windows': return 'G:\\Windows'
    case 'h:\\windows': return 'H:\\Windows'
    case 'i:\\windows': return 'I:\\Windows'
    case 'j:\\windows': return 'J:\\Windows'
    case 'k:\\windows': return 'K:\\Windows'
    case 'l:\\windows': return 'L:\\Windows'
    case 'm:\\windows': return 'M:\\Windows'
    case 'n:\\windows': return 'N:\\Windows'
    case 'o:\\windows': return 'O:\\Windows'
    case 'p:\\windows': return 'P:\\Windows'
    case 'q:\\windows': return 'Q:\\Windows'
    case 'r:\\windows': return 'R:\\Windows'
    case 's:\\windows': return 'S:\\Windows'
    case 't:\\windows': return 'T:\\Windows'
    case 'u:\\windows': return 'U:\\Windows'
    case 'v:\\windows': return 'V:\\Windows'
    case 'w:\\windows': return 'W:\\Windows'
    case 'x:\\windows': return 'X:\\Windows'
    case 'y:\\windows': return 'Y:\\Windows'
    case 'z:\\windows': return 'Z:\\Windows'
    default: fail('Windows system root must identify the Windows directory')
  }
}

function trustedWindowsSystemExecutable(systemRoot, executableName, fileSystem = fs) {
  const normalizedRoot = validatedWindowsSystemRoot(systemRoot)
  const system32Candidate = path.win32.join(normalizedRoot, 'System32')
  const executableCandidate = path.win32.join(system32Candidate, executableName)
  let descriptor
  try {
    const resolvedRoot = canonicalWindowsPath(fileSystem, normalizedRoot)
    if (!sameWindowsPath(resolvedRoot, normalizedRoot)) throw new Error('system root is redirected')
    const rootBefore = fileSystem.lstatSync(resolvedRoot, { bigint: true })
    if (!trustedWindowsDirectoryStat(rootBefore)) throw new Error('system root is not a regular directory')

    const resolvedSystem32 = canonicalWindowsPath(fileSystem, system32Candidate)
    if (
      !sameWindowsPath(resolvedSystem32, system32Candidate) ||
      !sameWindowsPath(path.win32.dirname(resolvedSystem32), resolvedRoot)
    ) throw new Error('System32 is redirected or is not a direct system-root child')
    const system32Before = fileSystem.lstatSync(resolvedSystem32, { bigint: true })
    if (!trustedWindowsDirectoryStat(system32Before)) throw new Error('System32 is not a regular directory')

    const resolvedExecutable = canonicalWindowsPath(fileSystem, executableCandidate)
    if (
      !sameWindowsPath(resolvedExecutable, executableCandidate) ||
      !sameWindowsPath(path.win32.dirname(resolvedExecutable), resolvedSystem32)
    ) throw new Error(`${executableName} is redirected or is not a direct System32 child`)
    descriptor = fileSystem.openSync(
      resolvedExecutable,
      fs.constants.O_RDONLY |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
    )
    const opened = fileSystem.fstatSync(descriptor, { bigint: true })
    const after = fileSystem.lstatSync(resolvedExecutable, { bigint: true })
    const system32After = fileSystem.lstatSync(resolvedSystem32, { bigint: true })
    const rootAfter = fileSystem.lstatSync(resolvedRoot, { bigint: true })
    if (
      !trustedWindowsExecutableStat(opened) || !trustedWindowsExecutableStat(after) ||
      !sameWindowsExecutableIdentity(opened, after) ||
      !trustedWindowsDirectoryStat(system32After) ||
      !sameWindowsDirectoryIdentity(system32Before, system32After) ||
      !trustedWindowsDirectoryStat(rootAfter) ||
      !sameWindowsDirectoryIdentity(rootBefore, rootAfter) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, normalizedRoot), resolvedRoot) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, system32Candidate), resolvedSystem32) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, executableCandidate), resolvedExecutable)
    ) throw new Error(`${executableName} or its system directory changed identity`)
    return executableCandidate
  } catch (error) {
    fail(`trusted Windows system ${executableName} is unavailable: ${error.message}`)
  } finally {
    if (descriptor !== undefined) fileSystem.closeSync(descriptor)
  }
}

export function archiveExecutable(
  platform = process.platform,
  systemRoot = process.env.SystemRoot,
  fileSystem = fs,
) {
  if (platform === 'linux' || platform === 'darwin') {
    return trustedPosixArchiveExecutable(platform, fileSystem)
  }
  if (platform !== 'win32') fail(`unsupported archive platform ${platform}`)
  // Git Bash can shadow Windows' ZIP-capable bsdtar with GNU tar.
  return trustedWindowsSystemExecutable(systemRoot, 'tar.exe', fileSystem)
}

export function lifecycleShellExecutable(
  platform = process.platform,
  systemRoot = process.env.SystemRoot,
  fileSystem = fs,
) {
  if (platform === 'linux' || platform === 'darwin') {
    const candidate = '/bin/sh'
    let descriptor
    try {
      const resolved = fileSystem.realpathSync(candidate)
      if (!path.posix.isAbsolute(resolved)) {
        fail('trusted lifecycle shell is unavailable')
      }
      descriptor = fileSystem.openSync(
        resolved,
        fs.constants.O_RDONLY |
          (fs.constants.O_NOFOLLOW ?? 0) |
          (fs.constants.O_NONBLOCK ?? 0) |
          (fs.constants.O_CLOEXEC ?? 0),
      )
      const opened = fileSystem.fstatSync(descriptor)
      const after = fileSystem.lstatSync(resolved)
      if (
        !trustedPosixExecutableStat(opened) || !trustedPosixExecutableStat(after) ||
        !samePosixExecutableIdentity(opened, after) ||
        fileSystem.realpathSync(candidate) !== resolved
      ) fail('trusted lifecycle shell changed identity')
      return candidate
    } catch (error) {
      if (error.message.startsWith('release smoke integrity:')) throw error
      fail(`trusted lifecycle shell is unavailable: ${error.message}`)
    } finally {
      if (descriptor !== undefined) fileSystem.closeSync(descriptor)
    }
  }
  if (platform !== 'win32') fail(`unsupported lifecycle shell platform ${platform}`)
  return trustedWindowsSystemExecutable(systemRoot, 'cmd.exe', fileSystem)
}

function archiveProcessEnvironment(platform = process.platform) {
  return platform === 'linux' || platform === 'darwin'
    ? posixArchiveEnvironment
    : process.env
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
    {
      kind: 'build',
      source: namedStep(buildSource, 'Smoke Native Archive and npm Installation', 'build native smoke step'),
    },
    {
      kind: 'release',
      source: namedStep(releaseSource, 'Smoke Native Archive and npm Installation', 'release native smoke step'),
    },
  ]
  for (const { kind, source } of smokeSteps) {
    expectLiteralCount(source, smokeCommand, 1, 'native smoke command')
    expectLiteralCount(source, '--archive "release-assets/$RELEASE_ARCHIVE" \\', 1, 'smoke archive argument')
    expectLiteralCount(source, '--binary "zig-out/bin/${{ matrix.binary-name }}" \\', 1, 'smoke binary argument')
    expectLiteralCount(source, '--target "${{ matrix.target }}" \\', 1, 'smoke target argument')
    if (kind === 'build') {
      expectLiteralCount(source, '--version "$RELEASE_VERSION" \\', 1, 'build smoke version argument')
      expectLiteralCount(source, '--commit "$GITHUB_SHA" \\', 1, 'native target evidence commit')
      expectLiteralCount(
        source,
        '--evidence "native-target-evidence/${{ matrix.target }}.json"',
        1,
        'native target evidence receipt',
      )
    } else {
      expectLiteralCount(source, '--version "$RELEASE_VERSION" \\', 1, 'release smoke version argument')
      expectLiteralCount(source, '--npm-package "$NPM_PACKAGE_ARCHIVE"', 1, 'release exact npm package argument')
      expectLiteralCount(
        source,
        '          NPM_PACKAGE_ARCHIVE: ${{ runner.temp }}/zigcss-npm-publication/${{ needs.npm-preflight.outputs.npm-package-archive }}',
        1,
        'release exact npm package environment',
      )
      if (source.includes('--commit') || source.includes('--evidence')) {
        fail('release smoke must not create unsigned native target evidence')
      }
    }
  }

  const nodeApiStep = 'Verify packaged Node API'
  const nodeApiCommand = 'npm run test:node-api'
  const buildNodeApi = namedStep(buildSource, nodeApiStep, 'build packaged Node API gate')
  const releaseNodeApi = namedStep(releaseSource, nodeApiStep, 'release packaged Node API gate')
  expectLiteralCount(buildSource, nodeApiCommand, 1, 'build packaged Node API command')
  expectLiteralCount(releaseSource, nodeApiCommand, 1, 'release packaged Node API command')
  expectLiteralCount(buildNodeApi, `        run: ${nodeApiCommand}`, 1, 'build packaged Node API gate')
  expectLiteralCount(releaseNodeApi, `        run: ${nodeApiCommand}`, 1, 'release packaged Node API gate')

  const buildUpload = namedStep(buildSource, 'Upload Artifact', 'build native receipt upload')
  expectLiteralCount(
    buildUpload,
    '          path: |\n            zig-out/bin/${{ matrix.binary-name }}\n            native-target-evidence/${{ matrix.target }}.json',
    1,
    'native target evidence receipt upload',
  )

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
    '- name: Pack exact npm package',
    '- name: Upload exact npm package',
    '  release:',
    '- name: Download exact npm package for smoke',
    '- name: Verify Release Metadata',
    smokeStep,
    '- name: Attest Release Provenance',
    '- name: Upload Release Assets',
    '  create-release:',
  ], 'release native smoke pipeline')

  return {
    buildTargets: build.length,
    releaseTargets: release.length,
    smokeCommands: 2,
    buildTargetReceipts: build.length,
    nodeApiCommands: 2,
  }
}

export function parseSmokeArguments(args) {
  if (!Array.isArray(args) || ![8, 10, 12, 14].includes(args.length)) {
    fail('expected four smoke inputs with optional npm-package and commit/evidence inputs')
  }
  const required = ['--archive', '--binary', '--target', '--version']
  const allowed = new Set([...required, '--npm-package', '--commit', '--evidence'])
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!allowed.has(name)) fail(`unknown smoke argument ${JSON.stringify(name)}`)
    if (values.has(name)) fail(`duplicate smoke argument ${name}`)
    if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) fail(`${name} has an invalid value`)
    values.set(name, value)
  }
  for (const name of required) if (!values.has(name)) fail(`missing smoke argument ${name}`)
  const version = values.get('--version')
  const target = values.get('--target')
  try {
    parseReleaseVersion(version, 'release smoke version')
  } catch (error) {
    fail(error.message)
  }
  if (!nativeSmokeTargets.some(item => item.target === target)) {
    fail(`unsupported release smoke target ${JSON.stringify(target)}`)
  }
  const hasNpmPackage = values.has('--npm-package')
  const npmPackage = values.get('--npm-package')
  if (
    hasNpmPackage
    && (
      !path.isAbsolute(npmPackage)
      || path.basename(npmPackage) !== `zigcss-${version}.tgz`
    )
  ) {
    fail('npm package smoke input must be the absolute versioned zigcss archive path')
  }
  const hasCommit = values.has('--commit')
  const hasEvidence = values.has('--evidence')
  const commit = values.get('--commit')
  const evidence = values.get('--evidence')
  if (hasCommit !== hasEvidence) fail('commit and evidence arguments must be supplied together')
  if (hasCommit && !/^[0-9a-f]{40}$/.test(commit)) {
    fail('native target evidence commit must be a lowercase 40-character object ID')
  }
  const expectedEvidence = `${nativeTargetEvidenceDirectory}/${target}.json`
  if (hasEvidence && evidence !== expectedEvidence) {
    fail(`native target evidence path must be ${expectedEvidence}`)
  }
  const options = {
    archive: values.get('--archive'),
    binary: values.get('--binary'),
    target,
    version,
  }
  if (hasNpmPackage) options.npmPackage = npmPackage
  if (hasCommit) {
    options.commit = commit
    options.evidence = evidence
  }
  return options
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

export function stageDevelopmentPackage(root, destination, target, archiveSha256) {
  const canonical = canonicalRoot(root)
  if (!nativeSmokeTargets.some(item => item.target === target)) {
    fail(`unsupported development package target ${JSON.stringify(target)}`)
  }
  if (typeof archiveSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(archiveSha256)) {
    fail('development package archive digest must contain 64 lowercase hexadecimal characters')
  }
  if (typeof destination !== 'string' || destination.length === 0 || destination.includes('\0')) {
    fail('development package destination must be a nonempty path')
  }
  const parent = canonicalRoot(path.dirname(destination))
  const candidate = path.resolve(parent, path.basename(destination))
  if (path.dirname(candidate) !== parent || fs.existsSync(candidate)) {
    fail('development package destination must be a new direct child directory')
  }

  const packageManifestPath = confinedRegularFile(canonical, 'package.json', 'development package manifest', 256 * 1024)
  const integrityPath = confinedRegularFile(canonical, 'native-integrity.json', 'development native integrity manifest', 64 * 1024)
  let integrity
  try {
    integrity = JSON.parse(fs.readFileSync(integrityPath, 'utf8'))
  } catch (error) {
    fail(`development native integrity manifest is not valid JSON: ${error.message}`)
  }
  const entry = Array.isArray(integrity.archives)
    ? integrity.archives.find(item => item?.target === target)
    : undefined
  if (entry === undefined) fail(`development native integrity manifest has no ${target} entry`)
  entry.sha256 = archiveSha256
  const integritySource = `${JSON.stringify(integrity, null, 2)}\n`
  validateNativeIntegritySources({
    manifest: integritySource,
    packageManifest: fs.readFileSync(packageManifestPath, 'utf8'),
    version: `${integrity.version}\n`,
  })

  fs.mkdirSync(candidate, { mode: 0o700 })
  try {
    for (const relativePath of expectedPackedFiles) {
      const source = confinedRegularFile(canonical, relativePath, `development package ${relativePath}`, 2 * 1024 * 1024)
      const output = path.join(candidate, relativePath)
      fs.mkdirSync(path.dirname(output), { recursive: true, mode: 0o700 })
      if (relativePath === 'native-integrity.json') {
        fs.writeFileSync(output, integritySource, { encoding: 'utf8', flag: 'wx', mode: 0o600 })
      } else {
        fs.copyFileSync(source, output, fs.constants.COPYFILE_EXCL)
        fs.chmodSync(output, fs.statSync(source).mode & 0o777)
      }
    }
  } catch (error) {
    fs.rmSync(candidate, { recursive: true, force: true })
    throw error
  }
  return candidate
}

function child(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    encoding: 'utf8',
    input: options.input,
    killSignal: options.killSignal,
    maxBuffer: maximumOutputBytes,
    timeout: childTimeoutMs,
    windowsHide: true,
  })
  if (result.error !== undefined) fail(`${options.label ?? command} failed to start: ${result.error.message}`)
  if (result.status !== 0 || result.signal !== null) {
    const termination = result.signal === null ? `exit ${result.status}` : `signal ${result.signal}`
    const output = [result.stderr, result.stdout]
      .filter(value => typeof value === 'string' && value.trim().length > 0)
      .join('\n')
    fail(`${options.label ?? command} failed (${termination}): ${output || 'no child output'}`)
  }
  return result
}

function npmCliPath() {
  const executableDirectory = path.dirname(process.execPath)
  const candidates = [
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

function checkCompiler(command, argsPrefix, working, environment, version, label) {
  const versionResult = child(command, [...argsPrefix, '--version'], {
    cwd: working,
    env: environment,
    label: `${label} version smoke`,
  })
  if (versionResult.stdout !== `zigcss ${version}\n` || versionResult.stderr !== '') fail(`${label} returned an unexpected version contract`)

  const input = path.join(working, `${label.replace(/[^a-z]+/g, '-')}.css`)
  fs.writeFileSync(input, '.smoke { color: red; }\n')
  const compile = child(command, [...argsPrefix, input, '--minify'], {
    cwd: working,
    env: environment,
    label: `${label} compile smoke`,
  })
  const warning = compilerWarningForVersion(version)
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

function checkNativePreprocessors(command, argsPrefix, working, environment, version, label) {
  for (const item of nativePreprocessorSmokeCases) {
    const input = path.join(
      working,
      `${label.replace(/[^a-z]+/g, '-')}-native.${item.extension}`,
    )
    fs.writeFileSync(input, item.source)
    const result = child(command, [
      ...argsPrefix,
      input,
      '--experimental-native',
      '--syntax',
      item.syntax,
    ], {
      cwd: working,
      env: environment,
      label: `${label} ${item.extension} native compile smoke`,
    })
    const warning = compilerWarningForVersion(version)
    if (result.stdout !== item.expected || result.stderr !== warning) {
      fail(`${label} ${item.extension} returned an unexpected native compiler contract`)
    }
  }
  return nativePreprocessorSmokeCases.length
}

function checkInstalledNodeApis(working, environment) {
  const cjsProgram = [
    "const path = require('node:path')",
    "const zigcss = require('zigcss')",
    "const source = '.empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}'",
    "const expected = '.a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}'",
    'zigcss.compile(source, {',
    "  syntax: 'scss',",
    "  sourcePath: path.join(process.cwd(), 'release-cjs.scss'),",
    "  format: 'minified',",
    '  optimize: true,',
    "  browsers: 'safari >= 7, ie >= 11',",
    '}).then(result => {',
    "  if (result.css !== expected) throw new Error('CommonJS CSS mismatch')",
    "  if (result.sourceMap !== null) throw new Error('CommonJS source map mismatch')",
    "  if (result.diagnostics.length !== 0 || result.dependencies.length !== 0) throw new Error('CommonJS result facts mismatch')",
    "  if (!Object.isFrozen(result) || !Object.isFrozen(result.diagnostics) || !Object.isFrozen(result.dependencies)) throw new Error('CommonJS ownership mismatch')",
    "  process.stdout.write('cjs-node-api-ok\\n')",
    '}).catch(error => { process.stderr.write(`${error.stack || error.message}\\n`); process.exitCode = 1 })',
  ].join('\n')
  const cjs = child(process.execPath, ['-e', cjsProgram], {
    cwd: working,
    env: environment,
    label: 'offline installed CommonJS API smoke',
  })
  if (cjs.stdout !== 'cjs-node-api-ok\n' || cjs.stderr !== '') {
    fail('offline installed CommonJS API returned an unexpected contract')
  }

  const invalidBrowsersProgram = [
    "const path = require('node:path')",
    "const zigcss = require('zigcss')",
    "zigcss.compile('.invalid { color: red; }', {",
    "  syntax: 'css',",
    "  sourcePath: path.join(process.cwd(), 'release-invalid-browsers.css'),",
    "  browsers: 'defaults',",
    '}).then(',
    "  () => { throw new Error('invalid browser target unexpectedly compiled') },",
    '  error => {',
    "    if (!(error instanceof zigcss.ZigCssCompileError)) throw new Error('invalid browser target returned the wrong error type')",
    "    if (error.code !== 'NODE_OPTIONS') throw new Error(`invalid browser target returned ${error.code}`)",
    "    if ('css' in error || 'result' in error) throw new Error('invalid browser target exposed partial output')",
    "    if (!Array.isArray(error.diagnostics) || error.diagnostics.length !== 0 || !Object.isFrozen(error.diagnostics)) throw new Error('invalid browser target diagnostics changed')",
    "    process.stdout.write('cjs-node-api-options-ok\\n')",
    '  },',
    ').catch(error => { process.stderr.write(`${error.stack || error.message}\n`); process.exitCode = 1 })',
  ].join('\n')
  const invalidBrowsers = child(process.execPath, ['-e', invalidBrowsersProgram], {
    cwd: working,
    env: environment,
    label: 'offline installed CommonJS API invalid browser target smoke',
  })
  if (invalidBrowsers.stdout !== 'cjs-node-api-options-ok\n' || invalidBrowsers.stderr !== '') {
    fail('offline installed CommonJS API invalid browser target returned an unexpected contract')
  }

  const dependency = path.join(working, 'release-esm-tokens.less')
  const entry = path.join(working, 'release-esm.less')
  fs.writeFileSync(dependency, '@color: red;\n')
  fs.writeFileSync(entry, '@import "release-esm-tokens.less"; .esm { color: @color; }\n')
  const esmProgram = [
    "import path from 'node:path'",
    "import { pathToFileURL } from 'node:url'",
    "import zigcss, { compileFile } from 'zigcss'",
    "if (zigcss.compileFile !== compileFile) throw new Error('ESM root exports diverged')",
    "const entry = path.join(process.cwd(), 'release-esm.less')",
    "const dependency = path.join(process.cwd(), 'release-esm-tokens.less')",
    "const result = await compileFile(entry, { format: 'minified', sourceMap: true })",
    "if (result.css !== '.esm{color:red}') throw new Error('ESM CSS mismatch')",
    "if (result.sourceMap === null || !result.sourceMap.sources.includes(pathToFileURL(entry).href)) throw new Error('ESM source map mismatch')",
    "if (result.diagnostics.length !== 0 || result.dependencies.length !== 1) throw new Error('ESM result facts mismatch')",
    "if (result.dependencies[0].kind !== 'import' || result.dependencies[0].url !== pathToFileURL(dependency).href) throw new Error('ESM dependency mismatch')",
    "if (!Object.isFrozen(result) || !Object.isFrozen(result.sourceMap) || !Object.isFrozen(result.dependencies) || !Object.isFrozen(result.dependencies[0])) throw new Error('ESM ownership mismatch')",
    "process.stdout.write('esm-node-api-ok\\n')",
  ].join('\n')
  const esm = child(process.execPath, ['--input-type=module', '-e', esmProgram], {
    cwd: working,
    env: environment,
    label: 'offline installed ESM API smoke',
  })
  if (esm.stdout !== 'esm-node-api-ok\n' || esm.stderr !== '') {
    fail('offline installed ESM API returned an unexpected contract')
  }
  return Object.freeze({
    compilations: packagedNodeApiModules.length,
    optionRejections: 1,
    invocations: packagedNodeApiModules.length + 1,
  })
}

function nodeOptionsRequire(filename) {
  if (filename.includes('\0') || filename.includes('"')) fail('preload path cannot be represented safely in NODE_OPTIONS')
  return `--require="${filename.replaceAll('\\', '/')}"`
}

function createRuntimeTrace(root, label) {
  if (typeof label !== 'string' || !/^[a-z][a-z-]*$/.test(label)) fail('runtime trace label is invalid')
  const filename = path.join(root, `${label}.jsonl`)
  fs.writeFileSync(filename, '', { encoding: 'utf8', flag: 'wx', mode: 0o600 })
  return filename
}

function runtimeTraceEnvironment(environment, preload, traceRoot, trace, binary) {
  return {
    ...environment,
    NODE_OPTIONS: nodeOptionsRequire(preload),
    ZIGCSS_RELEASE_SMOKE_RUNTIME: '1',
    ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY: binary,
    ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE: trace,
    ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT: traceRoot,
  }
}

function exactRecordKeys(record, expected, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)) fail(`${label} is not an object`)
  if (!same(Object.keys(record).sort(), [...expected].sort())) fail(`${label} fields changed`)
}

export function validateRuntimeTrace(filename, expectedInvocations, label = 'runtime trace') {
  if (!Number.isSafeInteger(expectedInvocations) || expectedInvocations <= 0) fail(`${label} expected invocation count is invalid`)
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > maximumRuntimeTraceBytes) {
    fail(`${label} must be a nonempty bounded regular file`)
  }
  const text = fs.readFileSync(filename, 'utf8')
  if (text.includes('\0') || text.includes('\r') || !text.endsWith('\n')) fail(`${label} is not canonical JSONL`)
  const lines = text.slice(0, -1).split('\n')
  if (lines.length !== expectedInvocations * 3) fail(`${label} must contain exactly three records per invocation`)
  const records = lines.map((line, index) => {
    try {
      return JSON.parse(line)
    } catch (error) {
      fail(`${label} record ${index + 1} is invalid JSON: ${error.message}`)
    }
  })

  for (let index = 0; index < expectedInvocations; index += 1) {
    const start = records[index * 3]
    const spawn = records[index * 3 + 1]
    const summary = records[index * 3 + 2]
    exactRecordKeys(start, ['event', 'pid'], `${label} start record`)
    exactRecordKeys(spawn, ['event', 'pid'], `${label} spawn record`)
    exactRecordKeys(
      summary,
      ['event', 'pid', 'nativeSpawns', 'networkAttempts', 'deniedProcessAttempts'],
      `${label} summary record`,
    )
    if (
      start.event !== 'runtime-start'
      || spawn.event !== 'native-spawn'
      || summary.event !== 'runtime-summary'
      || !Number.isSafeInteger(start.pid)
      || start.pid <= 0
      || spawn.pid !== start.pid
      || summary.pid !== start.pid
      || summary.nativeSpawns !== 1
      || summary.networkAttempts !== 0
      || summary.deniedProcessAttempts !== 0
    ) {
      fail(`${label} recorded an unexpected process or network boundary`)
    }
  }
  return {
    invocations: expectedInvocations,
    nativeSpawns: expectedInvocations,
    networkAttempts: 0,
    deniedProcessAttempts: 0,
  }
}

function validateSha256(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) {
    fail(`${label} must be a lowercase SHA-256 digest`)
  }
}

export function validateNativeTargetEvidence(evidence) {
  exactRecordKeys(
    evidence,
    [
      'schemaVersion',
      'commit',
      'version',
      'target',
      'runner',
      'host',
      'languages',
      'artifacts',
      'directArchive',
      'offlineInstalledPackage',
    ],
    'native target evidence',
  )
  if (evidence.schemaVersion !== 2) fail('native target evidence schema changed')
  if (!/^[0-9a-f]{40}$/.test(evidence.commit)) fail('native target evidence commit is invalid')
  const version = parseReleaseVersion(evidence.version, 'native target evidence version').value
  const policy = nativeSmokeTargets.find(item => item.target === evidence.target)
  if (policy === undefined || evidence.runner !== policy.runner) {
    fail('native target evidence does not identify one matching runner')
  }
  exactRecordKeys(evidence.host, ['platform', 'arch'], 'native target evidence host')
  if (evidence.host.platform !== policy.nodePlatform || evidence.host.arch !== policy.nodeArch) {
    fail('native target evidence does not identify one matching runner')
  }
  if (!same(evidence.languages, nativeTargetLanguages)) {
    fail('native target evidence does not own the finite five-language inventory')
  }

  const assets = releaseAssetsFor(version, policy.target)
  exactRecordKeys(
    evidence.artifacts,
    [
      'archive',
      'archiveSha256',
      'binary',
      'binarySha256',
      'checksums',
      'checksumsSha256',
      'npmPackage',
    ],
    'native target evidence artifacts',
  )
  if (
    evidence.artifacts.archive !== assets.archive
    || evidence.artifacts.binary !== policy.binaryName
    || evidence.artifacts.checksums !== assets.checksums
    || evidence.artifacts.npmPackage !== `zigcss-${version}.tgz`
  ) {
    fail('native target evidence artifact identity changed')
  }
  validateSha256(evidence.artifacts.archiveSha256, 'native target archive')
  validateSha256(evidence.artifacts.binarySha256, 'native target binary')
  validateSha256(evidence.artifacts.checksumsSha256, 'native target checksum manifest')

  exactRecordKeys(
    evidence.directArchive,
    [
      'stylesheetCompilations',
      'tracedInvocations',
      'nativeSpawns',
      'networkAttempts',
      'deniedProcessAttempts',
    ],
    'native target direct archive evidence',
  )
  if (!same(evidence.directArchive, {
    stylesheetCompilations: nativeTargetLanguages.length,
    tracedInvocations: nativeTargetLanguages.length + 1,
    nativeSpawns: nativeTargetLanguages.length + 1,
    networkAttempts: 0,
    deniedProcessAttempts: 0,
  })) {
    fail('native target direct archive evidence is incomplete')
  }

  exactRecordKeys(
    evidence.offlineInstalledPackage,
    [
      'stylesheetCompilations',
      'tracedInvocations',
      'nativeSpawns',
      'networkAttempts',
      'deniedProcessAttempts',
      'nodeApi',
      'entries',
      'bytes',
    ],
    'native target offline package evidence',
  )
  exactRecordKeys(
    evidence.offlineInstalledPackage.nodeApi,
    [
      'modules',
      'compilations',
      'optionRejections',
      'tracedInvocations',
      'nativeSpawns',
      'networkAttempts',
      'deniedProcessAttempts',
    ],
    'native target offline package Node API evidence',
  )
  if (
    evidence.offlineInstalledPackage.stylesheetCompilations !== nativeTargetLanguages.length
    || evidence.offlineInstalledPackage.tracedInvocations !== nativeTargetLanguages.length + 1
    || evidence.offlineInstalledPackage.nativeSpawns !== nativeTargetLanguages.length + 1
    || evidence.offlineInstalledPackage.networkAttempts !== 0
    || evidence.offlineInstalledPackage.deniedProcessAttempts !== 0
    || !same(evidence.offlineInstalledPackage.nodeApi, {
      modules: packagedNodeApiModules,
      compilations: packagedNodeApiModules.length,
      optionRejections: 1,
      tracedInvocations: packagedNodeApiModules.length + 1,
      nativeSpawns: packagedNodeApiModules.length + 1,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    })
    || !Number.isSafeInteger(evidence.offlineInstalledPackage.entries)
    || evidence.offlineInstalledPackage.entries <= 0
    || evidence.offlineInstalledPackage.entries > maximumInstalledEntries
    || !Number.isSafeInteger(evidence.offlineInstalledPackage.bytes)
    || evidence.offlineInstalledPackage.bytes <= 0
    || evidence.offlineInstalledPackage.bytes > maximumInstalledBytes
  ) {
    fail('native target offline package evidence is incomplete')
  }
  return evidence
}

export function nativeTargetEvidence(result, options = {}) {
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    fail('native target result is not an object')
  }
  const policy = nativeSmokeTargets.find(item => item.target === result.target)
  if (
    policy === undefined
    || options.platform !== policy.nodePlatform
    || options.arch !== policy.nodeArch
  ) {
    fail('native target evidence requires one matching runner')
  }
  if (!/^[0-9a-f]{40}$/.test(options.commit)) {
    fail('native target evidence commit must be a lowercase 40-character object ID')
  }
  const version = parseReleaseVersion(options.version, 'native target evidence version').value
  if (
    result.directStylesheetSmokes !== nativeTargetLanguages.length
    || result.offlinePackageStylesheetSmokes !== nativeTargetLanguages.length
  ) {
    fail('native target evidence requires the complete five-language distribution smoke')
  }
  const expectedRuntimeTrace = {
    invocations: nativeTargetLanguages.length + 1,
    nativeSpawns: nativeTargetLanguages.length + 1,
    networkAttempts: 0,
    deniedProcessAttempts: 0,
  }
  const expectedNodeApiTrace = {
    invocations: packagedNodeApiModules.length + 1,
    nativeSpawns: packagedNodeApiModules.length + 1,
    networkAttempts: 0,
    deniedProcessAttempts: 0,
  }
  if (
    !same(result.directRuntimeTrace, expectedRuntimeTrace)
    || !same(result.offlinePackageRuntimeTrace, expectedRuntimeTrace)
    || result.offlineNodeApiSmokes !== packagedNodeApiModules.length
    || result.offlineNodeApiOptionRejections !== 1
    || !same(result.offlineNodeApiRuntimeTrace, expectedNodeApiTrace)
  ) {
    fail('native target evidence requires the complete process/network trace')
  }
  for (const [value, label] of [
    [result.archiveSha256, 'native target archive'],
    [result.binarySha256, 'native target binary'],
    [result.checksumsSha256, 'native target checksum manifest'],
  ]) {
    validateSha256(value, label)
  }
  const assets = releaseAssetsFor(version, policy.target)
  return validateNativeTargetEvidence({
    schemaVersion: 2,
    commit: options.commit,
    version,
    target: policy.target,
    runner: policy.runner,
    host: {
      platform: options.platform,
      arch: options.arch,
    },
    languages: [...nativeTargetLanguages],
    artifacts: {
      archive: assets.archive,
      archiveSha256: result.archiveSha256,
      binary: policy.binaryName,
      binarySha256: result.binarySha256,
      checksums: assets.checksums,
      checksumsSha256: result.checksumsSha256,
      npmPackage: result.npmPackage,
    },
    directArchive: {
      stylesheetCompilations: result.directStylesheetSmokes,
      tracedInvocations: result.directRuntimeTrace.invocations,
      nativeSpawns: result.directRuntimeTrace.nativeSpawns,
      networkAttempts: result.directRuntimeTrace.networkAttempts,
      deniedProcessAttempts: result.directRuntimeTrace.deniedProcessAttempts,
    },
    offlineInstalledPackage: {
      stylesheetCompilations: result.offlinePackageStylesheetSmokes,
      tracedInvocations: result.offlinePackageRuntimeTrace.invocations,
      nativeSpawns: result.offlinePackageRuntimeTrace.nativeSpawns,
      networkAttempts: result.offlinePackageRuntimeTrace.networkAttempts,
      deniedProcessAttempts: result.offlinePackageRuntimeTrace.deniedProcessAttempts,
      nodeApi: {
        modules: [...packagedNodeApiModules],
        compilations: result.offlineNodeApiSmokes,
        optionRejections: result.offlineNodeApiOptionRejections,
        tracedInvocations: result.offlineNodeApiRuntimeTrace.invocations,
        nativeSpawns: result.offlineNodeApiRuntimeTrace.nativeSpawns,
        networkAttempts: result.offlineNodeApiRuntimeTrace.networkAttempts,
        deniedProcessAttempts: result.offlineNodeApiRuntimeTrace.deniedProcessAttempts,
      },
      entries: result.installedEntries,
      bytes: result.installedBytes,
    },
  })
}

export function writeNativeTargetEvidence(rootInput, relativePath, evidenceInput) {
  const evidence = validateNativeTargetEvidence(evidenceInput)
  const expected = `${nativeTargetEvidenceDirectory}/${evidence.target}.json`
  if (relativePath !== expected) fail(`native target evidence path must be ${expected}`)
  const root = canonicalRoot(rootInput)
  const directory = path.join(root, nativeTargetEvidenceDirectory)
  try {
    fs.mkdirSync(directory, { mode: 0o700 })
  } catch (error) {
    if (error.code !== 'EEXIST') fail(`native target evidence directory is unavailable: ${error.message}`)
  }
  let directoryStat
  try {
    directoryStat = fs.lstatSync(directory)
  } catch (error) {
    fail(`native target evidence directory is unavailable: ${error.message}`)
  }
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink() || fs.realpathSync(directory) !== directory) {
    fail('native target evidence directory must be a repository-confined regular directory')
  }

  const filename = path.join(root, ...relativePath.split('/'))
  const bytes = `${JSON.stringify(evidence, null, 2)}\n`
  if (Buffer.byteLength(bytes) > 64 * 1024) fail('native target evidence exceeds its byte limit')
  const expectedBytes = Buffer.from(bytes)
  let descriptor
  try {
    descriptor = fs.openSync(
      filename,
      fs.constants.O_CREAT |
        fs.constants.O_EXCL |
        fs.constants.O_RDWR |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
      0o600,
    )
    let offset = 0
    while (offset < expectedBytes.length) {
      const written = fs.writeSync(
        descriptor,
        expectedBytes,
        offset,
        expectedBytes.length - offset,
        offset,
      )
      if (written === 0) fail('native target evidence write made no progress')
      offset += written
    }
    fs.fsyncSync(descriptor)
    const writtenStat = fs.fstatSync(descriptor, { bigint: true })
    const actualBytes = Buffer.alloc(expectedBytes.length)
    let readOffset = 0
    while (readOffset < actualBytes.length) {
      const read = fs.readSync(
        descriptor,
        actualBytes,
        readOffset,
        actualBytes.length - readOffset,
        readOffset,
      )
      if (read === 0) break
      readOffset += read
    }
    const finalStat = fs.fstatSync(descriptor, { bigint: true })
    const pathStat = fs.lstatSync(filename, { bigint: true })
    if (
      !writtenStat.isFile() || !finalStat.isFile() || !pathStat.isFile() || pathStat.isSymbolicLink() ||
      writtenStat.dev !== finalStat.dev || writtenStat.ino !== finalStat.ino ||
      writtenStat.size !== finalStat.size || writtenStat.mtimeNs !== finalStat.mtimeNs ||
      writtenStat.ctimeNs !== finalStat.ctimeNs || finalStat.dev !== pathStat.dev ||
      finalStat.ino !== pathStat.ino || BigInt(readOffset) !== finalStat.size ||
      !actualBytes.equals(expectedBytes)
    ) fail('native target evidence write was not byte-exact')
  } catch (error) {
    if (error.code === 'EEXIST') fail('native target evidence already exists')
    if (error.message.startsWith('release smoke integrity:')) throw error
    fail(`native target evidence write failed: ${error.message}`)
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
  return relativePath
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
    const archiveEnvironment = archiveProcessEnvironment()
    const listing = child(archiveReader, ['-tf', archive], {
      cwd: temporary,
      env: archiveEnvironment,
      killSignal: 'SIGKILL',
      label: 'release archive listing',
    })
    if (listing.stdout.replaceAll('\r\n', '\n') !== `${policy.binaryName}\n` || listing.stderr !== '') {
      fail(`release archive must contain exactly ${policy.binaryName}`)
    }
    const directDirectory = path.join(temporary, 'direct')
    fs.mkdirSync(directDirectory)
    child(archiveReader, ['-xf', archive, '-C', directDirectory], {
      cwd: temporary,
      env: archiveEnvironment,
      killSignal: 'SIGKILL',
      label: 'release archive extraction',
    })
    const directBinary = confinedRegularFile(directDirectory, policy.binaryName, 'direct archive binary', maximumBinaryBytes)
    if (hashFile(directBinary) !== hashFile(binary)) fail('direct archive binary differs from the release binary')
    if (process.platform !== 'win32') fs.chmodSync(directBinary, 0o755)
    const preload = confinedRegularFile(root, 'scripts/release-smoke-preload.cjs', 'release smoke preload', 64 * 1024)
    const releaseSmokeEnvironment = {
      ...process.env,
      ZIGCSS_RELEASE_SMOKE: '1',
      ZIGCSS_RELEASE_SMOKE_ARCHIVE: assets.archive,
      ZIGCSS_RELEASE_SMOKE_ASSET_ROOT: assetRoot,
      ZIGCSS_RELEASE_SMOKE_CHECKSUMS: assets.checksums,
      ZIGCSS_RELEASE_SMOKE_VERSION: version,
    }
    const directRuntimeTrace = createRuntimeTrace(temporary, 'direct-runtime-trace')
    const directEnvironment = runtimeTraceEnvironment(
      releaseSmokeEnvironment,
      preload,
      temporary,
      directRuntimeTrace,
      directBinary,
    )
    const directArgs = ['-e', runtimeTraceLauncher, directBinary]
    checkCompiler(process.execPath, directArgs, temporary, directEnvironment, version, 'direct archive binary')
    const directNativeSmokes = checkNativePreprocessors(
      process.execPath,
      directArgs,
      temporary,
      directEnvironment,
      version,
      'direct archive binary',
    )
    const directTrace = validateRuntimeTrace(directRuntimeTrace, 6, 'direct archive runtime trace')

    const npmEnvironment = {
      ...process.env,
      npm_config_audit: 'false',
      npm_config_cache: path.join(temporary, 'npm-cache'),
      npm_config_fund: 'false',
      npm_config_update_notifier: 'false',
    }
    let packageName
    let packageArchive
    if (options.npmPackage === undefined) {
      const packDirectory = path.join(temporary, 'pack')
      fs.mkdirSync(packDirectory)
      const developmentPackage = stageDevelopmentPackage(
        root,
        path.join(temporary, 'development-package'),
        policy.target,
        hashFile(archive),
      )
      const packed = runNpm([
        'pack', developmentPackage,
        '--ignore-scripts',
        '--json',
        '--pack-destination', packDirectory,
      ], { cwd: temporary, env: npmEnvironment, label: 'npm pack smoke' })
      packageName = validatePackageInventory(packed, version)
      packageArchive = path.join(packDirectory, packageName)
      confinedRegularFile(packDirectory, packageName, 'npm package archive', 2 * 1024 * 1024)
    } else {
      const inspected = inspectNpmPackageArchive(
        options.npmPackage,
        version,
        path.join(root, 'package.json'),
      )
      packageName = inspected.filename
      packageArchive = options.npmPackage
    }

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
    confinedRegularFile(warmInstalledRoot, 'index.js', 'lifecycle-disabled npm wrapper', 64 * 1024)
    if (fs.existsSync(path.join(warmInstalledRoot, 'bin'))) {
      fail('lifecycle-disabled installation unexpectedly created a native binary directory')
    }
    measureInstalledTree(path.join(warmConsumer, 'node_modules'))
    fs.rmSync(warmConsumer, { recursive: true, force: true })

    const consumer = path.join(temporary, 'consumer')
    fs.mkdirSync(consumer)
    fs.writeFileSync(path.join(consumer, 'package.json'), '{"name":"zigcss-release-smoke","private":true,"version":"1.0.0"}\n')
    const installEnvironment = {
      ...releaseSmokeEnvironment,
      ...npmEnvironment,
      NODE_OPTIONS: nodeOptionsRequire(preload),
      npm_config_script_shell: lifecycleShellExecutable(),
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
    validateInstalledPackageFiles(installedRoot, policy.binaryName)

    const installedEntries = fs.readdirSync(path.join(installedRoot, 'bin')).sort()
    if (!same(installedEntries, [policy.binaryName])) fail('npm binary directory contains unexpected files')
    if (fs.readdirSync(path.join(installedRoot, 'bin')).some(name => name.startsWith('.install-'))) fail('npm installer left temporary files')

    fs.rmSync(npmEnvironment.npm_config_cache, { recursive: true, force: true })
    const offlineRuntimeTrace = createRuntimeTrace(temporary, 'offline-runtime-trace')
    const offlineEnvironment = runtimeTraceEnvironment({
      ...installEnvironment,
      npm_config_offline: 'true',
    }, preload, temporary, offlineRuntimeTrace, installedBinary)
    checkCompiler(
      process.execPath,
      [wrapper],
      temporary,
      offlineEnvironment,
      version,
      'offline npm wrapper',
    )
    const offlineNativeSmokes = checkNativePreprocessors(
      process.execPath,
      [wrapper],
      temporary,
      offlineEnvironment,
      version,
      'offline npm wrapper',
    )
    const offlineTrace = validateRuntimeTrace(offlineRuntimeTrace, 6, 'offline package runtime trace')
    const nodeApiRuntimeTrace = createRuntimeTrace(temporary, 'node-api-runtime-trace')
    const nodeApiEnvironment = runtimeTraceEnvironment({
      ...installEnvironment,
      npm_config_offline: 'true',
    }, preload, temporary, nodeApiRuntimeTrace, installedBinary)
    const nodeApiSmokes = checkInstalledNodeApis(consumer, nodeApiEnvironment)
    const nodeApiTrace = validateRuntimeTrace(
      nodeApiRuntimeTrace,
      nodeApiSmokes.invocations,
      'offline package Node API runtime trace',
    )
    const installed = measureInstalledTree(path.join(consumer, 'node_modules'))

    return {
      target: policy.target,
      archiveSha256: hashFile(archive),
      binarySha256: hashFile(binary),
      checksumsSha256: hashFile(checksums),
      installedBytes: installed.bytes,
      installedEntries: installed.entries,
      npmPackage: packageName,
      directStylesheetSmokes: 1 + directNativeSmokes,
      offlinePackageStylesheetSmokes: 1 + offlineNativeSmokes,
      directRuntimeTraces: directTrace.invocations,
      offlinePackageRuntimeTraces: offlineTrace.invocations,
      offlineNodeApiSmokes: nodeApiSmokes.compilations,
      offlineNodeApiOptionRejections: nodeApiSmokes.optionRejections,
      offlineNodeApiRuntimeTraces: nodeApiTrace.invocations,
      directRuntimeTrace: directTrace,
      offlinePackageRuntimeTrace: offlineTrace,
      offlineNodeApiRuntimeTrace: nodeApiTrace,
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function main() {
  try {
    const options = parseSmokeArguments(process.argv.slice(2))
    const result = smokeReleaseArtifact(options)
    if (options.evidence !== undefined) {
      const evidence = nativeTargetEvidence(result, {
        commit: options.commit,
        version: options.version,
        platform: process.platform,
        arch: process.arch,
      })
      writeNativeTargetEvidence(repositoryRoot, options.evidence, evidence)
    }
    process.stdout.write(
      `Native release smoke passed for ${result.target}: direct archive compiled ${result.directStylesheetSmokes} languages under ${result.directRuntimeTraces} process/network traces, lifecycle-disabled clean install, offline postinstall compiled ${result.offlinePackageStylesheetSmokes} languages under ${result.offlinePackageRuntimeTraces} process/network traces, packaged CommonJS/ESM APIs passed ${result.offlineNodeApiSmokes} compilations and ${result.offlineNodeApiOptionRejections} option rejection under ${result.offlineNodeApiRuntimeTraces} process/network traces, and ${result.installedEntries} installed entries/${result.installedBytes} bytes.\n`,
    )
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}

if (process.argv[1] !== undefined && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) main()
