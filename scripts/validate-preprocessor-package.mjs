#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { builtinModules, createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { nativeTargetContract } from './native-target-contract.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const minimumNodeVersion = '>=20.19.0'
export const directProductionDependencies = Object.freeze({})
export const referenceDevelopmentDependencies = Object.freeze({
  'image-size': '0.5.5',
  less: '4.6.7',
  sass: '1.101.0',
  stylus: '0.64.0',
})
export const canonicalProviderMetadata = Object.freeze({
  'dart-sass': Object.freeze({
    package: 'sass',
    version: '1.101.0',
    license: 'MIT',
    syntaxes: Object.freeze(['scss', 'sass']),
  }),
  less: Object.freeze({
    package: 'less',
    version: '4.6.7',
    license: 'Apache-2.0',
    syntaxes: Object.freeze(['less']),
  }),
  stylus: Object.freeze({
    package: 'stylus',
    version: '0.64.0',
    license: 'MIT',
    syntaxes: Object.freeze(['stylus']),
  }),
})
export const nativePackageTargets = Object.freeze(nativeTargetContract.map(target => Object.freeze({
  target: target.target,
  platform: target.nodePlatform,
  arch: target.nodeArch,
})))

export const runtimeSourceFiles = Object.freeze([
  'index.js',
  'install.js',
])

export const generatedPackageFiles = Object.freeze([
  'PREPROCESSOR-SBOM.spdx.json',
  'THIRD_PARTY_NOTICES.md',
])

export const manifestPackageFiles = Object.freeze([
  'LICENSE',
  'README.md',
  ...generatedPackageFiles,
  ...runtimeSourceFiles,
].sort())

export const expectedPackedFiles = Object.freeze([
  ...manifestPackageFiles,
  'package.json',
].sort())

const maximumPackageArchiveBytes = 2 * 1024 * 1024
const maximumPackageUnpackedBytes = 4 * 1024 * 1024
const maximumGeneratedBytes = 2 * 1024 * 1024
const reviewedLicenses = new Set(['Apache-2.0', 'BSD-3-Clause', 'BlueOak-1.0.0', 'ISC', 'MIT'])
const builtinNames = new Set(builtinModules.flatMap(name => [name, `node:${name}`]))

function fail(message) {
  throw new Error(`preprocessor package integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function sortedObject(value) {
  return Object.fromEntries(Object.entries(value ?? {}).sort(([left], [right]) => left.localeCompare(right, 'en')))
}

function readJson(filename, label) {
  try {
    return JSON.parse(fs.readFileSync(filename, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function regularFile(root, relativePath, label, maximumBytes = maximumGeneratedBytes) {
  const candidate = path.resolve(root, relativePath)
  const relative = path.relative(root, candidate)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the repository`)
  }
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size <= 0 || stat.size > maximumBytes) fail(`${label} has an invalid byte size`)
  return candidate
}

function packageNameFromPath(packagePath) {
  const marker = '/node_modules/'
  const tail = packagePath.includes(marker)
    ? packagePath.slice(packagePath.lastIndexOf(marker) + marker.length)
    : packagePath.slice('node_modules/'.length)
  const parts = tail.split('/')
  return tail.startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0]
}

function packageBase(specifier) {
  if (specifier.startsWith('@')) return specifier.split('/').slice(0, 2).join('/')
  return specifier.split('/')[0]
}

function resolveLockedDependency(lock, parent, name) {
  let cursor = parent
  while (true) {
    const nested = `${cursor}/node_modules/${name}`
    if (Object.hasOwn(lock.packages, nested)) return nested
    const boundary = cursor.lastIndexOf('/node_modules/')
    if (boundary === -1) break
    cursor = cursor.slice(0, boundary)
  }
  const topLevel = `node_modules/${name}`
  if (Object.hasOwn(lock.packages, topLevel)) return topLevel
  fail(`${parent} cannot resolve locked dependency ${name}`)
}

function dependencyNames(entry) {
  return Object.keys({
    ...(entry.dependencies ?? {}),
    ...(entry.optionalDependencies ?? {}),
  }).sort()
}

export function productionDependencyClosure(lock) {
  if (lock?.lockfileVersion !== 3 || lock.packages?.[''] === undefined) {
    fail('package-lock.json must use lockfileVersion 3 with a root package')
  }
  const pending = Object.keys(directProductionDependencies)
    .sort()
    .map(name => `node_modules/${name}`)
  const seen = new Set()
  while (pending.length !== 0) {
    const packagePath = pending.shift()
    if (seen.has(packagePath)) continue
    const entry = lock.packages[packagePath]
    if (entry === undefined) fail(`lockfile is missing ${packagePath}`)
    seen.add(packagePath)
    for (const name of dependencyNames(entry)) {
      pending.push(resolveLockedDependency(lock, packagePath, name))
    }
  }
  return [...seen].sort()
}

function validateLockedRecord(packagePath, entry) {
  const name = packageNameFromPath(packagePath)
  if (typeof entry.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(entry.version)) {
    fail(`${packagePath} has a non-canonical version`)
  }
  let resolved
  try {
    resolved = new URL(entry.resolved)
  } catch {
    fail(`${packagePath} has an invalid registry URL`)
  }
  if (
    resolved.protocol !== 'https:' ||
    resolved.hostname !== 'registry.npmjs.org' ||
    resolved.username !== '' ||
    resolved.password !== '' ||
    resolved.search !== '' ||
    resolved.hash !== ''
  ) {
    fail(`${packagePath} is not locked to the canonical npm registry`)
  }
  if (typeof entry.integrity !== 'string' || !/^sha512-[A-Za-z0-9+/]+=*$/.test(entry.integrity)) {
    fail(`${packagePath} is not locked with SHA-512 integrity`)
  }
  const digest = Buffer.from(entry.integrity.slice('sha512-'.length), 'base64')
  if (digest.length !== 64) fail(`${packagePath} has malformed SHA-512 integrity`)
  if (!reviewedLicenses.has(entry.license)) fail(`${packagePath} has unreviewed license ${entry.license}`)
  if (name.length === 0) fail(`${packagePath} has an invalid package identity`)
}

export function validateManifestPolicy(manifest, lock) {
  if (manifest?.name !== 'zigcss' || typeof manifest.version !== 'string') {
    fail('package identity is invalid')
  }
  if (!same(sortedObject(manifest.dependencies), directProductionDependencies)) {
    fail('native npm package must have zero production dependencies')
  }
  if (Object.keys(manifest.optionalDependencies ?? {}).length !== 0) {
    fail('native npm package must have zero optional dependencies')
  }
  const actualReferenceDependencies = Object.fromEntries(
    Object.keys(referenceDevelopmentDependencies).map(name => [name, manifest.devDependencies?.[name]]),
  )
  if (!same(actualReferenceDependencies, referenceDevelopmentDependencies)) {
    fail('development-only canonical reference dependency graph drifted')
  }
  if (manifest.engines?.node !== minimumNodeVersion) {
    fail(`Node policy must be ${minimumNodeVersion}`)
  }
  if (Object.hasOwn(manifest, 'os') || Object.hasOwn(manifest, 'cpu')) {
    fail('npm os/cpu fields cannot represent the exact non-Cartesian native target matrix')
  }
  if (!same(manifest.files, manifestPackageFiles)) fail('package files do not match the exact runtime allowlist')
  if (!same(manifest.exports, {
    '.': './index.js',
    './package.json': './package.json',
  })) {
    fail('package exports do not match the native binary-wrapper contract')
  }
  if (!same(manifest.zigcss?.canonicalProviders, canonicalProviderMetadata)) {
    fail('canonical provider package metadata drifted')
  }
  if (!same(manifest.zigcss?.nativeTargets, nativePackageTargets)) {
    fail('native package target metadata drifted')
  }
  if (manifest.scripts?.['check:preprocessor-package'] !== 'node scripts/validate-preprocessor-package.mjs --check') {
    fail('package check script is missing')
  }
  if (manifest.scripts?.['generate:preprocessor-package'] !== 'node scripts/validate-preprocessor-package.mjs --write') {
    fail('package generation script is missing')
  }
  if (manifest.scripts?.['test:preprocessor-package'] !== 'node --test scripts/validate-preprocessor-package.test.mjs') {
    fail('package policy test script is missing')
  }

  const root = lock?.packages?.['']
  if (
    lock?.name !== manifest.name ||
    lock?.version !== manifest.version ||
    root?.name !== manifest.name ||
    root?.version !== manifest.version ||
    !same(sortedObject(root.dependencies), directProductionDependencies) ||
    Object.keys(root.optionalDependencies ?? {}).length !== 0 ||
    !same(sortedObject(root.devDependencies), sortedObject(manifest.devDependencies)) ||
    root.engines?.node !== minimumNodeVersion ||
    Object.hasOwn(root, 'os') ||
    Object.hasOwn(root, 'cpu')
  ) {
    fail('manifest and lockfile production policy diverge')
  }

  const closure = productionDependencyClosure(lock)
  for (const packagePath of closure) validateLockedRecord(packagePath, lock.packages[packagePath])
  const deprecated = closure.filter(packagePath => lock.packages[packagePath].deprecated !== undefined)
  if (!same(deprecated, [])) {
    fail(`deprecated dependency inventory drifted: ${JSON.stringify(deprecated)}`)
  }
  const lifecycle = closure.filter(packagePath => lock.packages[packagePath].hasInstallScript === true)
  if (!same(lifecycle, [])) {
    fail(`dependency lifecycle inventory drifted: ${JSON.stringify(lifecycle)}`)
  }
  return closure
}

export function validateLinkedDocumentationConsumer(manifest, lock) {
  const linked = lock?.packages?.['..']
  if (
    lock?.lockfileVersion !== 3 ||
    linked?.version !== manifest.version ||
    linked?.hasInstallScript !== true ||
    linked?.license !== manifest.license ||
    !same(sortedObject(linked.dependencies), directProductionDependencies) ||
    Object.keys(linked.optionalDependencies ?? {}).length !== 0 ||
    !same(sortedObject(linked.devDependencies), sortedObject(manifest.devDependencies)) ||
    !same(linked.bin, manifest.bin) ||
    linked.engines?.node !== minimumNodeVersion ||
    Object.hasOwn(linked, 'os') ||
    Object.hasOwn(linked, 'cpu') ||
    !same(lock.packages?.['node_modules/zigcss'], { resolved: '..', link: true })
  ) {
    fail('documentation linked-consumer lock metadata diverges from the npm package')
  }
  return true
}

function sourceReferences(source) {
  const references = []
  for (const expression of [
    /\bfrom\s+['"]([^'"]+)['"]/g,
    /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /\b(?:require|stylusRequire)(?:\.resolve)?\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /\bnew URL\s*\(\s*['"]([^'"]+)['"]\s*,\s*import\.meta\.url\s*\)/g,
  ]) {
    for (const match of source.matchAll(expression)) references.push(match[1])
  }
  return references
}

export function discoverRuntimeSourceClosure(root = repositoryRoot) {
  const pending = [...runtimeSourceFiles]
  const seen = new Set()
  const external = new Set()
  while (pending.length !== 0) {
    const relativePath = pending.shift()
    if (seen.has(relativePath)) continue
    const filename = regularFile(root, relativePath, `runtime source ${relativePath}`)
    const source = fs.readFileSync(filename, 'utf8')
    seen.add(relativePath)
    for (const reference of sourceReferences(source)) {
      if (reference.startsWith('.')) {
        const target = path.relative(root, path.resolve(path.dirname(filename), reference)).split(path.sep).join('/')
        if (target === '..' || target.startsWith('../')) fail(`${relativePath} imports outside the package`)
        if (target === 'package.json') {
          regularFile(root, target, 'runtime package metadata')
          continue
        }
        pending.push(target)
      } else if (!builtinNames.has(reference)) {
        external.add(packageBase(reference))
      }
    }
  }
  const files = [...seen].sort()
  if (!same(files, [...runtimeSourceFiles])) {
    fail(`runtime import closure drifted: ${JSON.stringify(files)}`)
  }
  const allowedExternal = []
  if (!same([...external].sort(), allowedExternal)) {
    fail(`runtime external import closure drifted: ${JSON.stringify([...external].sort())}`)
  }
  return { files, external: [...external].sort() }
}

function closureIdentity(lock, closure) {
  const rows = closure.map(packagePath => {
    const entry = lock.packages[packagePath]
    return `${packagePath}\t${entry.version}\t${entry.license}\t${entry.integrity}`
  })
  return crypto.createHash('sha256').update(`${rows.join('\n')}\n`).digest('hex')
}

function spdxId(packagePath) {
  return `SPDXRef-Package-${crypto.createHash('sha256').update(packagePath).digest('hex').slice(0, 24)}`
}

function integrityHex(integrity) {
  return Buffer.from(integrity.slice('sha512-'.length), 'base64').toString('hex')
}

function purl(name, version) {
  return `pkg:npm/${encodeURIComponent(name)}@${encodeURIComponent(version)}`
}

export function renderPreprocessorSbom(manifest, lock, closure = validateManifestPolicy(manifest, lock)) {
  const packageId = new Map(closure.map(packagePath => [packagePath, spdxId(packagePath)]))
  const packages = closure.map(packagePath => {
    const entry = lock.packages[packagePath]
    const name = packageNameFromPath(packagePath)
    return {
      SPDXID: packageId.get(packagePath),
      name,
      versionInfo: entry.version,
      supplier: 'NOASSERTION',
      downloadLocation: entry.resolved,
      filesAnalyzed: false,
      checksums: [{ algorithm: 'SHA512', checksumValue: integrityHex(entry.integrity) }],
      licenseConcluded: entry.license,
      licenseDeclared: entry.license,
      copyrightText: 'NOASSERTION',
      primaryPackagePurpose: 'LIBRARY',
      externalRefs: [{
        referenceCategory: 'PACKAGE-MANAGER',
        referenceType: 'purl',
        referenceLocator: purl(name, entry.version),
      }],
      comment: `npm lock path: ${packagePath}`,
    }
  })
  const relationships = [{
    spdxElementId: 'SPDXRef-DOCUMENT',
    relationshipType: 'DESCRIBES',
    relatedSpdxElement: 'SPDXRef-Package-zigcss',
  }]
  for (const name of Object.keys(directProductionDependencies).sort()) {
    relationships.push({
      spdxElementId: 'SPDXRef-Package-zigcss',
      relationshipType: 'DEPENDS_ON',
      relatedSpdxElement: packageId.get(`node_modules/${name}`),
    })
  }
  for (const packagePath of closure) {
    const entry = lock.packages[packagePath]
    const targets = new Set(dependencyNames(entry).map(name => (
      resolveLockedDependency(lock, packagePath, name)
    )))
    for (const target of [...targets].sort()) {
      relationships.push({
        spdxElementId: packageId.get(packagePath),
        relationshipType: 'DEPENDS_ON',
        relatedSpdxElement: packageId.get(target),
      })
    }
  }

  const sbom = {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: `zigcss-${manifest.version}-npm-runtime`,
    documentNamespace: `https://github.com/vyakymenko/zigcss/spdx/npm/${manifest.version}/${closureIdentity(lock, closure)}`,
    creationInfo: {
      created: '2026-08-11T00:00:00Z',
      creators: ['Tool: zigcss-native-package/1'],
    },
    documentDescribes: ['SPDXRef-Package-zigcss'],
    comment: 'Exact zero-dependency npm runtime graph for the self-contained ZigCSS native binary wrapper.',
    packages: [
      {
        SPDXID: 'SPDXRef-Package-zigcss',
        name: manifest.name,
        versionInfo: manifest.version,
        supplier: 'Person: Valentyn Yakymenko',
        downloadLocation: 'NOASSERTION',
        filesAnalyzed: false,
        licenseConcluded: manifest.license,
        licenseDeclared: manifest.license,
        copyrightText: 'NOASSERTION',
        primaryPackagePurpose: 'APPLICATION',
        externalRefs: [{
          referenceCategory: 'PACKAGE-MANAGER',
          referenceType: 'purl',
          referenceLocator: purl(manifest.name, manifest.version),
        }],
      },
      ...packages,
    ],
    relationships,
  }
  return `${JSON.stringify(sbom, null, 2)}\n`
}

export function renderThirdPartyNotices(lock, closure) {
  const lines = [
    '# ZigCSS npm runtime third-party notices',
    '',
    'The shipped npm runtime has zero production dependencies and zero optional dependencies. Exact canonical providers remain development-only reference oracles and are excluded from the package archive and installed production graph.',
  ]
  if (closure.length !== 0) fail('third-party notice rendering received a nonempty production closure')
  void lock
  lines.push('')
  return lines.join('\n')
}

function validateGenerated(root, relativePath, expected) {
  const filename = regularFile(root, relativePath, relativePath)
  const actual = fs.readFileSync(filename, 'utf8')
  if (actual !== expected) fail(`${relativePath} is stale; run npm run generate:preprocessor-package`)
}

function atomicWrite(filename, contents) {
  try {
    const stat = fs.lstatSync(filename)
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`${path.basename(filename)} must be a regular non-symlink file`)
    if (fs.readFileSync(filename, 'utf8') === contents) return
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  const temporary = `${filename}.tmp-${process.pid}-${crypto.randomBytes(8).toString('hex')}`
  try {
    fs.writeFileSync(temporary, contents, { encoding: 'utf8', flag: 'wx', mode: 0o644 })
    fs.renameSync(temporary, filename)
  } finally {
    try {
      fs.rmSync(temporary, { force: true })
    } catch {
      // Preserve the original generation result.
    }
  }
}

export function validatePackageDescription(item, version) {
  const actualFiles = Array.isArray(item?.files) ? item.files.map(file => file.path).sort() : []
  if (item?.id !== `zigcss@${version}` || !same(actualFiles, expectedPackedFiles)) {
    fail('npm package identity or exact runtime inventory changed')
  }
  if (!Number.isSafeInteger(item.size) || item.size <= 0 || item.size > maximumPackageArchiveBytes) {
    fail('npm package archive size is invalid')
  }
  if (
    !Number.isSafeInteger(item.unpackedSize) ||
    item.unpackedSize <= 0 ||
    item.unpackedSize > maximumPackageUnpackedBytes
  ) {
    fail('npm package unpacked size is invalid')
  }
  if (item.entryCount !== expectedPackedFiles.length) fail('npm package entry count changed')
  if (typeof item.filename !== 'string' || path.basename(item.filename) !== item.filename) {
    fail('npm package filename is invalid')
  }
  return item.filename
}

function npmPackDescription(root, version) {
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-cache-'))
  let result
  try {
    result = spawnSync('npm', ['pack', '--dry-run', '--ignore-scripts', '--json'], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env,
        npm_config_audit: 'false',
        npm_config_cache: cache,
        npm_config_fund: 'false',
        npm_config_update_notifier: 'false',
      },
      maxBuffer: 4 * 1024 * 1024,
      timeout: 60_000,
    })
  } finally {
    fs.rmSync(cache, { force: true, recursive: true })
  }
  if (result.error !== undefined) fail(`npm pack failed to start: ${result.error.message}`)
  if (result.status !== 0 || result.signal !== null) {
    fail(`npm pack failed: ${result.stderr || result.signal || `exit ${result.status}`}`)
  }
  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch (error) {
    fail(`npm pack did not return JSON: ${error.message}`)
  }
  if (!Array.isArray(parsed) || parsed.length !== 1) fail('npm pack must describe exactly one archive')
  return validatePackageDescription(parsed[0], version)
}

function validateInstallerTargets(root) {
  const require = createRequire(import.meta.url)
  const installer = require(path.join(root, 'install.js'))
  const actual = nativePackageTargets.map(item => {
    const descriptor = installer.releaseDescriptor('0.0.0-test.0', item.platform, item.arch)
    return { target: descriptor.target, platform: descriptor.platform, arch: descriptor.arch }
  })
  if (!same(actual, nativePackageTargets)) fail('installer native target matrix diverges from package metadata')
  for (const [platform, arch] of [['win32', 'arm64'], ['linux', 'ia32'], ['freebsd', 'x64']]) {
    try {
      installer.releaseDescriptor('0.0.0-test.0', platform, arch)
      fail(`installer unexpectedly accepts ${platform}/${arch}`)
    } catch (error) {
      if (!String(error.message).includes('Unsupported platform and architecture')) throw error
    }
  }
}

function literalCount(source, literal) {
  return source.split(literal).length - 1
}

export function validatePreprocessorPackagingWorkflows(build, release, docs) {
  const command = 'npm run test:preprocessor-package && npm run check:preprocessor-package'
  if (literalCount(build, command) !== 1 || literalCount(release, command) !== 1) {
    fail('build and release workflows must each own one exact native package gate')
  }
  const buildConsumer = build.indexOf('- name: Test release consumer paths')
  const buildPackage = build.indexOf('- name: Verify native zero-dependency package', buildConsumer)
  const buildInstall = build.indexOf('- name: Install independent validator', buildPackage)
  const buildAudit = build.indexOf('- name: Verify dependency policy and production audits', buildInstall)
  if (buildConsumer < 0 || buildPackage <= buildConsumer || buildInstall <= buildPackage || buildAudit <= buildInstall) {
    fail('build workflow native package gate is ordered incorrectly')
  }
  const releaseSetup = release.indexOf('- name: Setup Node.js')
  const releasePackage = release.indexOf('- name: Verify native zero-dependency package', releaseSetup)
  const releaseVersion = release.indexOf('- name: Verify synchronized release version for publication', releasePackage)
  if (releaseSetup < 0 || releasePackage <= releaseSetup || releaseVersion <= releasePackage) {
    fail('release preflight native package gate is ordered incorrectly')
  }
  if (literalCount(build, "node-version: '20.19.0'") !== 2) {
    fail('native package matrix and aggregate evidence must use exact Node 20.19.0')
  }
  if (literalCount(release, "node-version: '20.19.0'") !== 3) {
    fail('all release npm surfaces must use exact Node 20.19.0')
  }
  if (literalCount(docs, "node-version: '22.22.0'") !== 1) {
    fail('documentation package consumer must use exact Node 22.22.0')
  }
  if (literalCount(release, 'npm publish --tag next --provenance') !== 1) {
    fail('npm publication must retain provenance')
  }
  return true
}

export function validatePreprocessorPackage(root = repositoryRoot, { pack = true } = {}) {
  const manifest = readJson(path.join(root, 'package.json'), 'package.json')
  const lock = readJson(path.join(root, 'package-lock.json'), 'package-lock.json')
  const documentationLock = readJson(path.join(root, 'docs/package-lock.json'), 'docs/package-lock.json')
  const closure = validateManifestPolicy(manifest, lock)
  validateLinkedDocumentationConsumer(manifest, documentationLock)
  const source = discoverRuntimeSourceClosure(root)
  validateInstallerTargets(root)
  validatePreprocessorPackagingWorkflows(
    fs.readFileSync(path.join(root, '.github/workflows/build.yml'), 'utf8'),
    fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8'),
    fs.readFileSync(path.join(root, '.github/workflows/docs.yml'), 'utf8'),
  )
  validateGenerated(root, generatedPackageFiles[0], renderPreprocessorSbom(manifest, lock, closure))
  validateGenerated(root, generatedPackageFiles[1], renderThirdPartyNotices(lock, closure))
  if (pack) npmPackDescription(root, manifest.version)
  return {
    dependencies: closure.length,
    externalImports: source.external.length,
    nativeTargets: nativePackageTargets.length,
    packageFiles: expectedPackedFiles.length,
    runtimeSources: source.files.length,
  }
}

export function writePreprocessorPackageMetadata(root = repositoryRoot) {
  const manifest = readJson(path.join(root, 'package.json'), 'package.json')
  const lock = readJson(path.join(root, 'package-lock.json'), 'package-lock.json')
  const documentationLock = readJson(path.join(root, 'docs/package-lock.json'), 'docs/package-lock.json')
  const closure = validateManifestPolicy(manifest, lock)
  validateLinkedDocumentationConsumer(manifest, documentationLock)
  discoverRuntimeSourceClosure(root)
  validateInstallerTargets(root)
  validatePreprocessorPackagingWorkflows(
    fs.readFileSync(path.join(root, '.github/workflows/build.yml'), 'utf8'),
    fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8'),
    fs.readFileSync(path.join(root, '.github/workflows/docs.yml'), 'utf8'),
  )
  atomicWrite(path.join(root, generatedPackageFiles[0]), renderPreprocessorSbom(manifest, lock, closure))
  atomicWrite(path.join(root, generatedPackageFiles[1]), renderThirdPartyNotices(lock, closure))
  return validatePreprocessorPackage(root)
}

function main() {
  if (process.argv.length !== 3 || !['--check', '--write'].includes(process.argv[2])) {
    throw new Error('usage: node scripts/validate-preprocessor-package.mjs --check|--write')
  }
  const result = process.argv[2] === '--write'
    ? writePreprocessorPackageMetadata()
    : validatePreprocessorPackage()
  process.stdout.write(
    `Native package verified: ${result.runtimeSources} runtime sources, ${result.packageFiles} archive files, ${result.dependencies} production dependencies, ${result.nativeTargets} native targets.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
