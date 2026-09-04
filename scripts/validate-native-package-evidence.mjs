#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  nativeSmokeTargets,
  validateNativeTargetEvidence,
} from './smoke-release-artifact.mjs'
import { releaseAssetsFor } from './generate-release-metadata.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'
import { actionPins } from './validate-workflows.mjs'
import {
  hashStableRegularFile,
  readBoundedDirectory,
  readStableRegularFile,
} from './bounded-filesystem.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const artifactsDirectory = 'native-target-artifacts'
const outputFilename = 'native-package-evidence.json'
const languages = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus'])
const distributionForms = Object.freeze([
  'direct-archive',
  'offline-installed-package',
])
const maximumReceiptBytes = 64 * 1024
const maximumAggregateBytes = 128 * 1024
const maximumBinaryBytes = 256 * 1024 * 1024
const maximumInstalledBytes = 128 * 1024 * 1024
const maximumInstalledEntries = 20_000

function fail(message) {
  throw new Error(`native package evidence integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(record, expected, label) {
  if (record === null || typeof record !== 'object' || Array.isArray(record)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(record).sort()
  const wanted = [...expected].sort()
  if (!same(actual, wanted)) fail(`${label} keys changed`)
}

function canonicalRoot(root) {
  try {
    return fs.realpathSync(root)
  } catch (error) {
    fail(`root is unavailable: ${error.message}`)
  }
}

function confinedPath(root, relativePath, label) {
  if (
    typeof relativePath !== 'string'
    || relativePath.length === 0
    || relativePath.includes('\0')
    || path.isAbsolute(relativePath)
  ) {
    fail(`${label} must be a nonempty relative path`)
  }
  const candidate = path.resolve(root, relativePath)
  const relative = path.relative(root, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the root`)
  }
  return candidate
}

function regularDirectory(root, relativePath, label) {
  const candidate = confinedPath(root, relativePath, label)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail(`${label} must be a regular non-symlink directory`)
  }
  const canonical = fs.realpathSync(candidate)
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the root`)
  }
  return canonical
}

function regularFile(root, relativePath, label, maximumBytes) {
  const candidate = confinedPath(root, relativePath, label)
  let canonical
  try {
    canonical = fs.realpathSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the root`)
  }
  return {
    filename: candidate,
    options: { label, maximumBytes, reject: fail },
  }
}

function exactDirectoryEntries(directory, expected, label) {
  const wanted = [...expected].sort()
  const entries = readBoundedDirectory(directory, {
    label: `${label} inventory`,
    maximumEntries: wanted.length + 1,
    reject: fail,
  }).map(entry => entry.name).sort()
  if (!same(entries, wanted)) {
    fail(`${label} inventory must contain exactly ${wanted.join(', ')}`)
  }
}

function hashBytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function validateSha256(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value)) {
    fail(`${label} must be a lowercase SHA-256 digest`)
  }
}

function validateAggregateEvidence(evidence) {
  exactKeys(
    evidence,
    [
      'schemaVersion',
      'commit',
      'version',
      'languages',
      'distributionForms',
      'terminalCounts',
      'targets',
    ],
    'aggregate evidence',
  )
  if (evidence.schemaVersion !== 1) fail('aggregate evidence schema changed')
  if (!/^[0-9a-f]{40}$/.test(evidence.commit)) fail('aggregate commit is invalid')
  const version = parseReleaseVersion(evidence.version, 'native package evidence version').value
  if (!same(evidence.languages, languages)) fail('aggregate language inventory changed')
  if (!same(evidence.distributionForms, distributionForms)) {
    fail('aggregate distribution-form inventory changed')
  }
  const expectedCounts = {
    targets: nativeSmokeTargets.length,
    languages: languages.length,
    distributionForms: distributionForms.length,
    stylesheetCompilations: nativeSmokeTargets.length * languages.length * distributionForms.length,
    tracedInvocations: nativeSmokeTargets.length * (languages.length + 1) * distributionForms.length,
    nativeSpawns: nativeSmokeTargets.length * (languages.length + 1) * distributionForms.length,
    networkAttempts: 0,
    deniedProcessAttempts: 0,
  }
  if (!same(evidence.terminalCounts, expectedCounts)) fail('aggregate terminal counts changed')
  if (!Array.isArray(evidence.targets) || evidence.targets.length !== nativeSmokeTargets.length) {
    fail('aggregate target inventory changed')
  }

  const receiptDigests = new Set()
  for (const [index, target] of evidence.targets.entries()) {
    const policy = nativeSmokeTargets[index]
    exactKeys(
      target,
      [
        'target',
        'runner',
        'host',
        'receipt',
        'receiptSha256',
        'artifacts',
        'installedPackage',
      ],
      `aggregate target ${index}`,
    )
    if (target.target !== policy.target || target.runner !== policy.runner) {
      fail(`aggregate target ${index} identity changed`)
    }
    if (!same(target.host, { platform: policy.nodePlatform, arch: policy.nodeArch })) {
      fail(`aggregate target ${policy.target} host changed`)
    }
    if (
      target.receipt
      !== `zigcss-${policy.target}/native-target-evidence/${policy.target}.json`
    ) {
      fail(`aggregate target ${policy.target} receipt path changed`)
    }
    validateSha256(target.receiptSha256, `aggregate target ${policy.target} receipt`)
    receiptDigests.add(target.receiptSha256)

    exactKeys(
      target.artifacts,
      [
        'archive',
        'archiveSha256',
        'binary',
        'binarySha256',
        'checksums',
        'checksumsSha256',
        'npmPackage',
      ],
      `aggregate target ${policy.target} artifacts`,
    )
    for (const [digest, label] of [
      [target.artifacts.archiveSha256, 'archive'],
      [target.artifacts.binarySha256, 'binary'],
      [target.artifacts.checksumsSha256, 'checksums'],
    ]) {
      validateSha256(digest, `aggregate target ${policy.target} ${label}`)
    }
    const assets = releaseAssetsFor(version, policy.target)
    if (
      target.artifacts.archive !== assets.archive
      || target.artifacts.binary !== policy.binaryName
      || target.artifacts.checksums !== assets.checksums
      || target.artifacts.npmPackage !== `zigcss-${version}.tgz`
    ) {
      fail(`aggregate target ${policy.target} artifact identity changed`)
    }

    exactKeys(target.installedPackage, ['entries', 'bytes'], `aggregate target ${policy.target} installed package`)
    if (
      !Number.isSafeInteger(target.installedPackage.entries)
      || target.installedPackage.entries <= 0
      || target.installedPackage.entries > maximumInstalledEntries
      || !Number.isSafeInteger(target.installedPackage.bytes)
      || target.installedPackage.bytes <= 0
      || target.installedPackage.bytes > maximumInstalledBytes
    ) {
      fail(`aggregate target ${policy.target} installed package is outside its terminal bounds`)
    }
  }
  if (receiptDigests.size !== nativeSmokeTargets.length) {
    fail('aggregate receipt identities are not unique')
  }
  return evidence
}

export function validateNativePackageEvidence(options = {}) {
  const root = canonicalRoot(options.root)
  if (options.artifacts !== artifactsDirectory) {
    fail(`artifacts directory must be ${artifactsDirectory}`)
  }
  if (!/^[0-9a-f]{40}$/.test(options.commit ?? '')) fail('commit is invalid')
  const version = parseReleaseVersion(options.version, 'native package evidence version').value
  const artifacts = regularDirectory(root, artifactsDirectory, 'artifact root')
  exactDirectoryEntries(
    artifacts,
    nativeSmokeTargets.map(policy => `zigcss-${policy.target}`),
    'artifact root',
  )

  const targets = nativeSmokeTargets.map(policy => {
    const artifactRelative = `${artifactsDirectory}/zigcss-${policy.target}`
    const artifact = regularDirectory(root, artifactRelative, `artifact ${policy.target}`)
    exactDirectoryEntries(
      artifact,
      ['native-target-evidence', 'zig-out'],
      `artifact ${policy.target}`,
    )
    const receiptsRelative = `${artifactRelative}/native-target-evidence`
    const receipts = regularDirectory(root, receiptsRelative, `receipt directory ${policy.target}`)
    exactDirectoryEntries(receipts, [`${policy.target}.json`], `receipt directory ${policy.target}`)

    const receiptRelative = `${receiptsRelative}/${policy.target}.json`
    const receipt = regularFile(root, receiptRelative, `receipt ${policy.target}`, maximumReceiptBytes)
    const receiptBytes = readStableRegularFile(receipt.filename, receipt.options)
    let parsed
    try {
      parsed = JSON.parse(receiptBytes.toString('utf8'))
    } catch (error) {
      fail(`receipt ${policy.target} is not JSON: ${error.message}`)
    }
    if (`${JSON.stringify(parsed, null, 2)}\n` !== receiptBytes.toString('utf8')) {
      fail(`receipt ${policy.target} is not canonical JSON`)
    }
    let evidence
    try {
      evidence = validateNativeTargetEvidence(parsed)
    } catch (error) {
      fail(`receipt ${policy.target} is invalid: ${error.message}`)
    }
    if (
      evidence.target !== policy.target
      || evidence.commit !== options.commit
      || evidence.version !== version
    ) {
      fail(`receipt ${policy.target} does not match the aggregate identity`)
    }

    const zigOutputRelative = `${artifactRelative}/zig-out`
    const zigOutput = regularDirectory(root, zigOutputRelative, `Zig output ${policy.target}`)
    exactDirectoryEntries(zigOutput, ['bin'], `Zig output ${policy.target}`)
    const binaryDirectoryRelative = `${zigOutputRelative}/bin`
    const binaryDirectory = regularDirectory(
      root,
      binaryDirectoryRelative,
      `binary directory ${policy.target}`,
    )
    exactDirectoryEntries(binaryDirectory, [policy.binaryName], `binary directory ${policy.target}`)
    const binaryRelative = `${binaryDirectoryRelative}/${policy.binaryName}`
    const binary = regularFile(root, binaryRelative, `binary ${policy.target}`, maximumBinaryBytes)
    if (hashStableRegularFile(binary.filename, binary.options) !== evidence.artifacts.binarySha256) {
      fail(`binary ${policy.target} does not match its receipt`)
    }
    return {
      target: policy.target,
      runner: policy.runner,
      host: {
        platform: policy.nodePlatform,
        arch: policy.nodeArch,
      },
      receipt: `zigcss-${policy.target}/native-target-evidence/${policy.target}.json`,
      receiptSha256: hashBytes(receiptBytes),
      artifacts: evidence.artifacts,
      installedPackage: {
        entries: evidence.offlineInstalledPackage.entries,
        bytes: evidence.offlineInstalledPackage.bytes,
      },
    }
  })

  return validateAggregateEvidence({
    schemaVersion: 1,
    commit: options.commit,
    version,
    languages: [...languages],
    distributionForms: [...distributionForms],
    terminalCounts: {
      targets: nativeSmokeTargets.length,
      languages: languages.length,
      distributionForms: distributionForms.length,
      stylesheetCompilations: nativeSmokeTargets.length * languages.length * distributionForms.length,
      tracedInvocations: nativeSmokeTargets.length * (languages.length + 1) * distributionForms.length,
      nativeSpawns: nativeSmokeTargets.length * (languages.length + 1) * distributionForms.length,
      networkAttempts: 0,
      deniedProcessAttempts: 0,
    },
    targets,
  })
}

export function writeNativePackageEvidence(rootInput, relativePath, evidenceInput) {
  const root = canonicalRoot(rootInput)
  if (relativePath !== outputFilename) fail(`output path must be ${outputFilename}`)
  const evidence = validateAggregateEvidence(evidenceInput)
  const output = confinedPath(root, relativePath, 'output path')
  const bytes = `${JSON.stringify(evidence, null, 2)}\n`
  const buffer = Buffer.from(bytes)
  if (buffer.length > maximumAggregateBytes) fail('aggregate evidence exceeds its byte limit')
  let descriptor
  try {
    descriptor = fs.openSync(
      output,
      fs.constants.O_CREAT
        | fs.constants.O_EXCL
        | fs.constants.O_RDWR
        | (fs.constants.O_NOFOLLOW ?? 0)
        | (fs.constants.O_CLOEXEC ?? 0),
      0o600,
    )
  } catch (error) {
    if (error.code === 'EEXIST') fail('output already exists')
    fail(`output write failed: ${error.message}`)
  }
  try {
    let offset = 0
    while (offset < buffer.length) {
      const count = fs.writeSync(descriptor, buffer, offset, buffer.length - offset, offset)
      if (count === 0) fail('output write ended before all bytes were written')
      offset += count
    }
    fs.fsyncSync(descriptor)
    const written = fs.fstatSync(descriptor, { bigint: true })
    if (!written.isFile() || written.size !== BigInt(buffer.length)) {
      fail('output write was not byte-exact')
    }
    const readback = Buffer.allocUnsafe(buffer.length)
    offset = 0
    while (offset < readback.length) {
      const count = fs.readSync(descriptor, readback, offset, readback.length - offset, offset)
      if (count === 0) fail('output readback ended before all bytes were read')
      offset += count
    }
    const after = fs.fstatSync(descriptor, { bigint: true })
    if (
      !readback.equals(buffer)
      || after.dev !== written.dev
      || after.ino !== written.ino
      || after.size !== written.size
      || after.mtimeNs !== written.mtimeNs
      || after.ctimeNs !== written.ctimeNs
    ) {
      fail('output write was not byte-exact')
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return relativePath
}

export function parseNativePackageEvidenceArguments(args) {
  if (!Array.isArray(args) || args.length !== 8) fail('expected exactly four inputs')
  const required = ['--artifacts', '--commit', '--version', '--output']
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!required.includes(name)) fail(`unknown argument ${JSON.stringify(name)}`)
    if (values.has(name)) fail(`duplicate argument ${name}`)
    if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
      fail(`${name} has an invalid value`)
    }
    values.set(name, value)
  }
  for (const name of required) if (!values.has(name)) fail(`missing argument ${name}`)
  if (values.get('--artifacts') !== artifactsDirectory) {
    fail(`artifacts directory must be ${artifactsDirectory}`)
  }
  if (!/^[0-9a-f]{40}$/.test(values.get('--commit'))) fail('commit is invalid')
  try {
    parseReleaseVersion(values.get('--version'), 'native package evidence version')
  } catch (error) {
    fail(error.message)
  }
  if (values.get('--output') !== outputFilename) fail(`output path must be ${outputFilename}`)
  return {
    artifacts: values.get('--artifacts'),
    commit: values.get('--commit'),
    version: values.get('--version'),
    output: values.get('--output'),
  }
}

function expectOnce(source, needle, label) {
  if (source.split(needle).length !== 2) fail(`${label} must occur exactly once`)
}

export function validateNativePackageEvidenceWorkflow(source) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > 256 * 1024) {
    fail('build workflow is missing or oversized')
  }
  const marker = '  native-package-evidence:\n'
  expectOnce(source, marker, 'aggregate job')
  const start = source.indexOf(marker)
  const next = source.indexOf('\n  test:\n', start)
  if (next === -1) fail('aggregate job must precede the test job')
  const job = source.slice(start, next)
  for (const policy of nativeSmokeTargets) {
    expectOnce(source, `            target: ${policy.target}`, `build target ${policy.target}`)
  }
  const ordered = [
    '    needs: build',
    '    runs-on: ubuntu-latest',
    '- name: Checkout code',
    '- name: Setup Node.js',
    '- name: Download Native Target Evidence',
    '- name: Validate Native Package Evidence',
    '- name: Upload Native Package Evidence',
  ]
  let cursor = -1
  for (const needle of ordered) {
    const index = job.indexOf(needle, cursor + 1)
    if (index === -1 || index <= cursor) fail(`aggregate job is missing or reorders ${needle}`)
    cursor = index
  }
  for (const [name, label] of [
    ['actions/checkout', 'checkout'],
    ['actions/setup-node', 'Node setup'],
    ['actions/download-artifact', 'artifact download'],
    ['actions/upload-artifact', 'aggregate upload'],
  ]) {
    const pin = actionPins[name]
    expectOnce(job, `uses: ${name}@${pin.sha} # ${pin.version}`, `aggregate ${label}`)
  }
  for (const [needle, label] of [
    ['    permissions:\n      contents: read', 'permissions'],
    ["          node-version: '24.20.0'", 'Node version'],
    ['          pattern: zigcss-*', 'artifact pattern'],
    ['          path: native-target-artifacts', 'artifact path'],
    ['          merge-multiple: false', 'artifact isolation'],
    ['          version="$(cat VERSION)"', 'version binding'],
    ['            --artifacts native-target-artifacts \\', 'artifact argument'],
    ['            --commit "$GITHUB_SHA" \\', 'commit binding'],
    ['            --version "$version" \\', 'version argument'],
    ['            --output native-package-evidence.json', 'output argument'],
    ['          name: zigcss-native-package-evidence', 'aggregate artifact name'],
    ['          path: native-package-evidence.json', 'aggregate upload path'],
    ['          if-no-files-found: error', 'closed missing-file behavior'],
    ['          retention-days: 7', 'bounded retention'],
  ]) {
    expectOnce(job, needle, `aggregate ${label}`)
  }
  return {
    targets: nativeSmokeTargets.length,
    downloadedArtifacts: nativeSmokeTargets.length,
    aggregateReceipts: nativeSmokeTargets.length,
  }
}

function main() {
  try {
    const options = parseNativePackageEvidenceArguments(process.argv.slice(2))
    const evidence = validateNativePackageEvidence({
      root: repositoryRoot,
      artifacts: options.artifacts,
      commit: options.commit,
      version: options.version,
    })
    writeNativePackageEvidence(repositoryRoot, options.output, evidence)
    process.stdout.write(
      `Native package evidence verified ${evidence.terminalCounts.targets} targets, ${evidence.terminalCounts.stylesheetCompilations} stylesheet compilations, and ${evidence.terminalCounts.tracedInvocations} process/network traces.\n`,
    )
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}

if (process.argv[1] !== undefined && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) main()
