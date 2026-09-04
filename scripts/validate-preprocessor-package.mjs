#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { builtinModules, createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { nativeTargetContract } from './native-target-contract.mjs'
import {
  releaseConsumerSteps,
  validateNixFlakeWorkflowContract,
  validatePackageManagerWorkflowContract,
  validateReleaseConsumerSteps,
} from './validate-workflows.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const minimumNodeVersion = '>=20.19.0'
export const directProductionDependencies = Object.freeze({})
export const referenceDevelopmentDependencies = Object.freeze({
  less: '4.9.0',
  sass: '1.101.0',
  stylus: '0.64.0',
})
export const parcelExampleDevelopmentDependencies = Object.freeze({
  '@parcel/diagnostic': '2.16.4',
  '@parcel/plugin': '2.16.4',
  '@parcel/source-map': '2.1.1',
  parcel: '2.16.4',
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
    version: '4.9.0',
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
  'adapters/bun.cjs',
  'adapters/bun.mjs',
  'adapters/core.cjs',
  'adapters/esbuild.cjs',
  'adapters/esbuild.mjs',
  'adapters/index.cjs',
  'adapters/index.mjs',
  'adapters/rollup.cjs',
  'adapters/rollup.mjs',
  'adapters/rspack.cjs',
  'adapters/vite.cjs',
  'adapters/vite.mjs',
  'adapters/webpack.cjs',
  'api.cjs',
  'api.mjs',
  'index.js',
  'install.js',
].sort())

export const declarationPackageFiles = Object.freeze([
  'adapters/bun.d.cts',
  'adapters/bun.d.mts',
  'adapters/bun.d.ts',
  'adapters/esbuild.d.cts',
  'adapters/esbuild.d.mts',
  'adapters/esbuild.d.ts',
  'adapters/index.d.cts',
  'adapters/index.d.mts',
  'adapters/index.d.ts',
  'adapters/rollup.d.cts',
  'adapters/rollup.d.mts',
  'adapters/rollup.d.ts',
  'adapters/rspack.d.cts',
  'adapters/rspack.d.mts',
  'adapters/rspack.d.ts',
  'adapters/vite.d.cts',
  'adapters/vite.d.mts',
  'adapters/vite.d.ts',
  'adapters/webpack-types.d.ts',
  'adapters/webpack.d.cts',
  'adapters/webpack.d.mts',
  'adapters/webpack.d.ts',
  'api.d.cts',
  'api.d.mts',
  'api.d.ts',
].sort())

export const packageBins = Object.freeze({
  zigcss: 'index.js',
  'zigcss-install': 'install.js',
})

export const packageExports = Object.freeze({
  '.': Object.freeze({
    import: Object.freeze({
      types: './api.d.mts',
      default: './api.mjs',
    }),
    require: Object.freeze({
      types: './api.d.cts',
      default: './api.cjs',
    }),
  }),
  './adapters': Object.freeze({
    import: Object.freeze({
      types: './adapters/index.d.mts',
      default: './adapters/index.mjs',
    }),
    require: Object.freeze({
      types: './adapters/index.d.cts',
      default: './adapters/index.cjs',
    }),
  }),
  './vite': Object.freeze({
    import: Object.freeze({
      types: './adapters/vite.d.mts',
      default: './adapters/vite.mjs',
    }),
    require: Object.freeze({
      types: './adapters/vite.d.cts',
      default: './adapters/vite.cjs',
    }),
  }),
  './rollup': Object.freeze({
    import: Object.freeze({
      types: './adapters/rollup.d.mts',
      default: './adapters/rollup.mjs',
    }),
    require: Object.freeze({
      types: './adapters/rollup.d.cts',
      default: './adapters/rollup.cjs',
    }),
  }),
  './esbuild': Object.freeze({
    import: Object.freeze({
      types: './adapters/esbuild.d.mts',
      default: './adapters/esbuild.mjs',
    }),
    require: Object.freeze({
      types: './adapters/esbuild.d.cts',
      default: './adapters/esbuild.cjs',
    }),
  }),
  './bun': Object.freeze({
    import: Object.freeze({
      types: './adapters/bun.d.mts',
      default: './adapters/bun.mjs',
    }),
    require: Object.freeze({
      types: './adapters/bun.d.cts',
      default: './adapters/bun.cjs',
    }),
  }),
  './webpack': Object.freeze({
    import: Object.freeze({
      types: './adapters/webpack.d.mts',
      default: './adapters/webpack.cjs',
    }),
    require: Object.freeze({
      types: './adapters/webpack.d.cts',
      default: './adapters/webpack.cjs',
    }),
  }),
  './rspack': Object.freeze({
    import: Object.freeze({
      types: './adapters/rspack.d.mts',
      default: './adapters/rspack.cjs',
    }),
    require: Object.freeze({
      types: './adapters/rspack.d.cts',
      default: './adapters/rspack.cjs',
    }),
  }),
  './package.json': './package.json',
})

export const packageTypesVersions = Object.freeze({
  '*': Object.freeze({
    adapters: Object.freeze(['adapters/index.d.ts']),
    vite: Object.freeze(['adapters/vite.d.ts']),
    rollup: Object.freeze(['adapters/rollup.d.ts']),
    esbuild: Object.freeze(['adapters/esbuild.d.ts']),
    bun: Object.freeze(['adapters/bun.d.ts']),
    webpack: Object.freeze(['adapters/webpack.d.ts']),
    rspack: Object.freeze(['adapters/rspack.d.ts']),
  }),
})

export const generatedPackageFiles = Object.freeze([
  'PREPROCESSOR-SBOM.spdx.json',
  'THIRD_PARTY_NOTICES.md',
])

export const manifestPackageFiles = Object.freeze([
  'LICENSE',
  'README.md',
  ...declarationPackageFiles,
  ...generatedPackageFiles,
  ...runtimeSourceFiles,
  'native-integrity.json',
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

export function resolveLockedDependency(lock, parent, name) {
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
  const actualParcelDependencies = Object.fromEntries(
    Object.keys(parcelExampleDevelopmentDependencies).map(name => [name, manifest.devDependencies?.[name]]),
  )
  if (!same(actualParcelDependencies, parcelExampleDevelopmentDependencies)) {
    fail('development-only Parcel integration dependency graph drifted')
  }
  if (manifest.engines?.node !== minimumNodeVersion) {
    fail(`Node policy must be ${minimumNodeVersion}`)
  }
  if (manifest.preferUnplugged !== true) {
    fail('Yarn Plug\'n\'Play must unpack the writable native binary installation surface')
  }
  if (Object.hasOwn(manifest, 'os') || Object.hasOwn(manifest, 'cpu')) {
    fail('npm os/cpu fields cannot represent the exact non-Cartesian native target matrix')
  }
  if (!same(manifest.files, manifestPackageFiles)) fail('package files do not match the exact runtime allowlist')
  if (!same(manifest.bin, packageBins)) fail('package binaries do not expose CLI and lifecycle recovery')
  if (manifest.main !== 'api.cjs' || manifest.types !== 'api.d.ts') {
    fail('package entrypoints do not expose the programmatic Node API')
  }
  if (!same(manifest.exports, packageExports) || !same(manifest.typesVersions, packageTypesVersions)) {
    fail('package exports do not match the native API and builder-adapter contract')
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
  if (manifest.scripts?.['test:node-api'] !== 'node --test scripts/verify-node-api.test.mjs') {
    fail('programmatic Node API test script is missing')
  }
  if (manifest.scripts?.['test:bundler-adapters'] !== 'node --test scripts/verify-bundler-adapters.test.mjs') {
    fail('builder adapter test script is missing')
  }
  if (manifest.scripts?.['test:turbopack-example'] !== 'node --test scripts/verify-turbopack-example.test.mjs') {
    fail('Turbopack example test script is missing')
  }
  if (manifest.scripts?.['test:next-webpack-example'] !== 'node --test scripts/verify-next-webpack-example.test.mjs') {
    fail('Next.js Webpack example test script is missing')
  }
  if (manifest.scripts?.['test:sveltekit-example'] !== 'node --test scripts/verify-sveltekit-example.test.mjs') {
    fail('SvelteKit example test script is missing')
  }
  if (manifest.scripts?.['test:astro-example'] !== 'node --test scripts/verify-astro-example.test.mjs') {
    fail('Astro example test script is missing')
  }
  if (manifest.scripts?.['test:nuxt-example'] !== 'node --test scripts/verify-nuxt-example.test.mjs') {
    fail('Nuxt example test script is missing')
  }
  if (manifest.scripts?.['test:parcel-example'] !== 'node --test scripts/verify-parcel-example.test.mjs') {
    fail('Parcel local-plugin test script is missing')
  }
  if (manifest.scripts?.['test:types'] !== 'tsc -p tests/typescript/tsconfig.json') {
    fail('TypeScript package-surface test script is missing')
  }
  if (manifest.scripts?.['test:build-systems'] !== 'node --test scripts/verify-build-system-examples.test.mjs') {
    fail('dependency-file build-system test script is missing')
  }
  if (manifest.scripts?.['test:package-managers'] !== 'node --test scripts/verify-package-managers.test.mjs') {
    fail('package-manager recovery test script is missing')
  }
  if (manifest.scripts?.['check:nix-flake'] !== 'node scripts/validate-nix-flake.mjs --check') {
    fail('Nix flake check script is missing')
  }
  if (manifest.scripts?.['test:nix-flake'] !== 'node --test scripts/validate-nix-flake.test.mjs') {
    fail('Nix flake policy test script is missing')
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
    !same(root.bin, packageBins) ||
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
    comment: 'Exact zero-dependency npm runtime graph for the self-contained ZigCSS native binary wrapper and programmatic Node API.',
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
  const packageManifest = readJson(path.join(root, 'package.json'), 'package.json')
  const nativeIntegrity = installer.readNativeIntegrityManifest(path.join(root, 'native-integrity.json'))
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
  for (const item of nativePackageTargets) {
    const descriptor = installer.releaseDescriptor(packageManifest.version, item.platform, item.arch)
    const digest = installer.parseNativeIntegrityManifest(nativeIntegrity, descriptor)
    if (!/^[0-9a-f]{64}$/.test(digest)) fail(`native integrity digest for ${item.target} is invalid`)
  }
}

function literalCount(source, literal) {
  return source.split(literal).length - 1
}

export const packageManagerMatrixPolicy = Object.freeze({
  bun: '1.4.0',
  managers: 6,
  pnpm: '11.25.0',
  yarnClassic: '1.22.22',
  yarnModern: '4.9.4',
})

export function validatePackageManagerMatrixSource(source) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > 64 * 1024 || source.includes('\r')) {
    fail('package-manager matrix source is missing, oversized, or not LF-normalized')
  }
  const versionBlock = [
    'export const packageManagerVersions = Object.freeze({',
    `  pnpm: '${packageManagerMatrixPolicy.pnpm}',`,
    `  yarnClassic: '${packageManagerMatrixPolicy.yarnClassic}',`,
    `  yarnModern: '${packageManagerMatrixPolicy.yarnModern}',`,
    `  bun: '${packageManagerMatrixPolicy.bun}',`,
    '})',
  ].join('\n')
  const requiredOnce = [
    versionBlock,
    "const toolchainRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-toolchain-'))",
    "const corepackHome = path.join(toolchainRoot, 'corepack')",
    'const maximumToolchainBytes = 256 * 1024 * 1024',
    'const maximumToolchainEntries = 10_000',
    'function detectCli(name, commandPrefix = [], environment = toolchainOfflineEnvironment) {',
    "const result = spawnSync(command, [...commandPrefix, '--version'], {\n    cwd: toolchainRoot,\n    encoding: 'utf8',\n    env: environment,",
    'const direct = detectCli(name, [], toolchainOfflineEnvironment)',
    "const corepack = detectCli(\n    'corepack',\n    [`${name}@${expectedVersion}`],\n    toolchainDetectionEnvironment,\n  )",
    "COREPACK_ENABLE_NETWORK: '1'",
    'function inspectBoundedToolchainRoot() {',
    'Corepack toolchain entry count must be bounded',
    'Corepack toolchain byte size must be bounded',
    "assert.match(relative, /^zigcss-package-manager-toolchain-[^/\\\\]+$/)\n      inspectBoundedToolchainRoot()",
    "fs.rmSync(toolchainRoot, { recursive: true, force: true })",
    "assert.equal(fs.existsSync(toolchainRoot), false, 'package-manager toolchain root must be removed')",
    "test('Corepack exact toolchain state is bounded, confined, and reused offline'",
    'assert.equal(environment.COREPACK_HOME, corepackHome)',
    "cli: detectExactCli('pnpm', packageManagerVersions.pnpm)",
    "cli: detectExactCli('yarn', packageManagerVersions.yarnClassic)",
    "YARN_ENABLE_NETWORK: 'false'",
    "YARN_ENABLE_SCRIPTS: 'false'",
    "    'YARN_ENABLE_COLORS',",
    "    'YARN_ENABLE_GLOBAL_CACHE',",
    "    'YARN_GLOBAL_FOLDER',",
    "    'YARN_NODE_LINKER',",
    "environment.YARN_ENABLE_COLORS = 'false'",
    "environment.YARN_ENABLE_GLOBAL_CACHE = 'false'",
    "environment.YARN_GLOBAL_FOLDER = path.join(cache, 'yarn-global')",
    'if (manager.nodeLinker !== undefined) environment.YARN_NODE_LINKER = manager.nodeLinker',
    'return [...(manager.cli.commandPrefix ?? []), ...args]',
    "return ['add', packageArchive, '--ignore-scripts', '--offline', '--exact', '--non-interactive']",
    "return ['add', packageArchive, '--exact', '--mode=skip-build']",
    "verifyGitHubActionsToolchain(candidates, enabled = process.env.GITHUB_ACTIONS === 'true')",
    'verifyGitHubActionsToolchain(managers)',
    "label: 'single npm package-manager matrix pack'",
    'function verifyYarnPnpPackage(manager) {',
    "const pnpLoader = path.join(consumer, '.pnp.cjs')",
    'const pnpStat = fs.lstatSync(pnpLoader)',
    "assert.equal(pnpStat.isFile(), true, 'default Yarn PnP must create .pnp.cjs')",
    "assert.equal(pnpStat.isSymbolicLink(), false, 'default Yarn PnP loader must not be a symlink')",
    "assert.equal(Object.hasOwn(environment, 'YARN_NODE_LINKER'), false)",
    "assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'default Yarn PnP must not create node_modules')",
    'PnP TypeScript no-paths boundary must not create node_modules',
    'PnP declaration-byte compilation must not create node_modules',
    "assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'PnP recovery must not create node_modules')",
    'fs.accessSync(installedRoot, fs.constants.R_OK | fs.constants.W_OK)',
    'const relativeManifest = path.relative(fs.realpathSync(consumer), manifestPath)',
    'assert.equal(path.isAbsolute(relativeManifest), false)',
    "assert.doesNotMatch(relativeManifest, /^\\.\\.(?:[/\\\\]|$)/)",
    '/^\\.yarn[/\\\\]unplugged[/\\\\][^/\\\\]+[/\\\\]node_modules[/\\\\]zigcss[/\\\\]package\\.json$/',
    'Yarn must unpack zigcss into its project-local writable PnP area',
    'assert.equal(manifest.preferUnplugged, true)',
    "const missing = exactManagerCommand(manager, ['zigcss', '--version'], {",
    'assert.equal(missing.signal, null)',
    'assert.equal(missing.status, 1)',
    "assert.equal(missing.stdout, '')",
    'assert.equal(missing.stderr, missingBinaryStderr)',
    "const recovered = successfulManagerCommand(manager, ['zigcss-install'], {",
    "const executed = successfulManagerCommand(manager, ['zigcss', '--version'], {",
    'NODE_OPTIONS: `--require=${JSON.stringify(releasePreload)}`',
    'preloadedRelease = createLocalReleaseFixture()',
    'createReleaseArchive({',
    'function trustLocalFixtureInInstalledCopy(installedRoot, fixture) {',
    'selected.sha256 = fixture.fixtureDigest',
    'trustLocalFixtureInInstalledCopy(installedRoot, preloadedRelease)',
    'local recovery trust must not mutate the exact packed package archive',
    'function verifyYarnPnpPackageSurface(manager, consumer, installedRoot, manifest, environment) {',
    'function verifyYarnPnpTypedPackageSurface(manager, consumer, installedRoot, manifest, environment) {',
    'assert.equal(nativeManifest.name, nativeSpecifier)',
    'assert.equal(nativeManifest.version, typescriptManifest.version)',
    'assert.equal(typescriptManifest.optionalDependencies[nativeSpecifier], typescriptManifest.version)',
    'PnP CommonJS export resolution',
    'PnP ESM export resolution',
    "successfulManagerCommand(manager, ['tsc', '--version'], {",
    'assert.equal(compilerVersion.stdout, `Version ${typescriptManifest.version}\\n`)',
    'assert.equal(Object.hasOwn(baseConfig.compilerOptions.paths, specifier), false)',
    'PnP TypeScript 7 no-paths package resolution boundary',
    "const noPaths = exactManagerCommand(manager, ['tsc', '-p', baseConfigPath], {",
    'assert.equal(noPaths.signal, null)',
    'assert.equal(noPaths.status, 1)',
    "assert.equal(noPaths.stderr, '')",
    "noPaths.stdout.includes(`error TS2307: Cannot find module '${specifier}' or its corresponding type declarations.`)",
    'unpatched TypeScript ${typescriptManifest.version} unexpectedly resolved ${specifier} through PnP',
    'path.join(installedRoot, manifest.exports[exportName][mode].types.slice(2))',
    "successfulManagerCommand(manager, ['tsc', '-p', configPath], {",
    'PnP strict TypeScript ${mode} declaration bytes',
    'assert.equal(executed.stdout, `${process.version}\\n`)',
    "const relativeCache = path.relative(fs.realpathSync(managerRoot), cacheRoot)",
    'assert.equal(path.isAbsolute(relativeCache), false)',
    "assert.doesNotMatch(relativeCache, /^\\.\\.(?:[/\\\\]|$)/)",
  ]
  for (const contract of requiredOnce) {
    if (literalCount(source, contract) !== 1) {
      fail(`package-manager matrix changed exact contract ${JSON.stringify(contract)}`)
    }
  }
  for (const liveReleaseContract of [
    'repositoryInstaller.boundedDownload(',
    'descriptor.archiveUrl',
    'descriptor.checksumsUrl',
  ]) {
    if (source.includes(liveReleaseContract)) {
      fail('package-manager matrix local PnP fixture must not fetch live release assets')
    }
  }
  if (literalCount(source, "cli: detectExactCli('yarn', packageManagerVersions.yarnModern)") !== 2) {
    fail('package-manager matrix must execute both Yarn Modern node-modules and default PnP')
  }
  if (literalCount(source, 'COREPACK_HOME: corepackHome,') !== 2) {
    fail('package-manager matrix changed exact contract for one confined Corepack detection/execution home')
  }
  if (literalCount(source, "COREPACK_ENABLE_NETWORK: '0'") !== 2) {
    fail('package-manager matrix changed exact contract for offline direct detection and package execution')
  }
  const managerIds = ['npm', 'pnpm', 'yarn-classic', 'yarn-modern', 'yarn-modern-pnp', 'bun']
  const managerStart = source.indexOf('const managers = Object.freeze([')
  const managerEnd = source.indexOf('\n])', managerStart)
  if (managerStart === -1 || managerEnd === -1) fail('package-manager matrix declaration is malformed')
  const managerDeclaration = source.slice(managerStart, managerEnd)
  const idMatches = [...managerDeclaration.matchAll(/^    id: '([^']+)',$/gm)].map(match => match[1])
  if (!same(idMatches, managerIds)) fail('package-manager matrix inventory changed')
  for (const [index, id] of managerIds.entries()) {
    if (literalCount(managerDeclaration, `    id: '${id}',`) !== 1) {
      fail(`package-manager matrix must own one ${id} entry`)
    }
    const entryStart = managerDeclaration.indexOf(`    id: '${id}',`)
    const nextStart = index + 1 === managerIds.length
      ? managerDeclaration.length
      : managerDeclaration.indexOf(`    id: '${managerIds[index + 1]}',`, entryStart)
    const entry = managerDeclaration.slice(entryStart, nextStart)
    if (literalCount(entry, 'mandatoryInGitHubActions: true,') !== 1) {
      fail(`package-manager matrix must make ${id} mandatory in GitHub Actions`)
    }
    const mandatory = id === 'npm' ? 'mandatory: true,' : 'mandatory: false,'
    if (literalCount(entry, mandatory) !== 1) {
      fail(`package-manager matrix local requirement changed for ${id}`)
    }
    if (id === 'yarn-modern' && literalCount(entry, "nodeLinker: 'node-modules',") !== 1) {
      fail('package-manager matrix must retain the Yarn Modern node-modules branch')
    }
    if (id === 'yarn-modern-pnp') {
      if (literalCount(entry, 'pnp: true,') !== 1 || entry.includes('nodeLinker:')) {
        fail('package-manager matrix must retain a default Yarn Modern PnP branch without a nodeLinker override')
      }
    }
  }
  return { ...packageManagerMatrixPolicy }
}

function workflowJob(source, jobName) {
  const header = `\n  ${jobName}:\n`
  if (literalCount(source, header) !== 1) {
    fail(`build workflow must contain exactly one ${jobName} job`)
  }
  const bodyStart = source.indexOf(header) + header.length
  const relativeEnd = source.slice(bodyStart).search(/\n  [A-Za-z][A-Za-z0-9_-]*:\n/)
  const bodyEnd = relativeEnd === -1 ? source.length : bodyStart + relativeEnd
  return source.slice(bodyStart, bodyEnd)
}

function validateBuildPackageNodeJobs(build) {
  const exactNodeLine = "          node-version: '20.19.0'"
  for (const jobName of ['build', 'native-provenance-evidence', 'native-package-evidence']) {
    const nodeVersionLines = workflowJob(build, jobName)
      .split('\n')
      .filter(line => /^\s+node-version:/.test(line))
    if (!same(nodeVersionLines, [exactNodeLine])) {
      fail(`build workflow job ${jobName} must use exact Node 20.19.0`)
    }
  }
  const testNodeVersionLines = workflowJob(build, 'test')
    .split('\n')
    .filter(line => /^\s+node-version:/.test(line))
  if (!same(testNodeVersionLines, ["          node-version: '22.22.0'"])) {
    fail('build workflow job test must use exact Node 22.22.0 for the pinned Next.js Webpack, Astro, and Nuxt host engines')
  }
}

function validateReleasePackageNodeJobs(release) {
  const exactNodeLine = "          node-version: '20.19.0'"
  for (const jobName of ['npm-preflight', 'release', 'publish-npm', 'anonymous-public-delivery']) {
    const nodeVersionLines = workflowJob(release, jobName)
      .split('\n')
      .filter(line => /^\s+node-version:/.test(line))
    if (!same(nodeVersionLines, [exactNodeLine])) {
      fail(`all release npm surfaces must use exact Node 20.19.0; job ${jobName} changed`)
    }
  }
}

export function validatePreprocessorPackagingWorkflows(build, release, docs) {
  const command = 'npm run test:preprocessor-package && npm run check:preprocessor-package'
  if (literalCount(build, command) !== 1 || literalCount(release, command) !== 1) {
    fail('build and release workflows must each own one exact native package gate')
  }
  const nodeApiCommand = 'run: npm run test:node-api'
  if (literalCount(build, nodeApiCommand) !== 1 || literalCount(release, nodeApiCommand) !== 1) {
    fail('build and release workflows must each own one exact packaged Node API gate')
  }
  if (literalCount(build, 'run: npm run test:bundler-adapters') !== 1) {
    fail('build workflow must own one exact builder adapter gate')
  }
  if (literalCount(build, 'run: npm run test:turbopack-example') !== 1) {
    fail('build workflow must own one exact Turbopack example gate')
  }
  if (literalCount(build, 'run: npm run test:next-webpack-example') !== 1) {
    fail('build workflow must own one exact Next.js Webpack example gate')
  }
  if (literalCount(build, 'run: npm run test:sveltekit-example') !== 1) {
    fail('build workflow must own one exact SvelteKit example gate')
  }
  if (literalCount(build, 'run: npm run test:astro-example') !== 1) {
    fail('build workflow must own one exact Astro example gate')
  }
  if (literalCount(build, 'run: npm run test:nuxt-example') !== 1) {
    fail('build workflow must own one exact Nuxt example gate')
  }
  if (literalCount(build, 'run: npm run test:parcel-example') !== 1) {
    fail('build workflow must own one exact Parcel local-plugin gate')
  }
  if (literalCount(build, 'run: npm run test:types') !== 1) {
    fail('build workflow must own one exact TypeScript package-surface gate')
  }
  if (literalCount(build, 'run: npm run test:build-systems') !== 1) {
    fail('build workflow must own one exact dependency-file build-system gate')
  }
  if (literalCount(build, 'run: npm run test:package-managers') !== 1) {
    fail('build workflow must own one exact package-manager recovery gate')
  }
  try {
    validatePackageManagerWorkflowContract(build)
  } catch (error) {
    fail(`build workflow package-manager CI contract changed: ${error.message}`)
  }
  try {
    validateNixFlakeWorkflowContract(build)
  } catch (error) {
    fail(`build workflow Nix flake CI contract changed: ${error.message}`)
  }
  const runTestsStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  if (literalCount(build, runTestsStep) !== 1) {
    fail('build workflow must own one exact Run Tests gate')
  }
  const adaptersStep = [
    '      - name: Verify build-tool adapters',
    '        env:',
    '          ZIGCSS_ADAPTER_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:bundler-adapters',
  ].join('\n')
  const buildSystemsStep = [
    '      - name: Verify dependency-file build-system integrations',
    '        env:',
    '          ZIGCSS_REAL_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    "          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '1'",
    '        run: npm run test:build-systems',
  ].join('\n')
  const turbopackStep = [
    '      - name: Verify Next.js Turbopack global SCSS integration',
    '        env:',
    '          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:turbopack-example',
  ].join('\n')
  const nextWebpackStep = [
    '      - name: Verify Next.js Webpack global SCSS integration',
    '        env:',
    '          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:next-webpack-example',
  ].join('\n')
  const sveltekitStep = [
    '      - name: Verify SvelteKit external CSS Module integration',
    '        env:',
    '          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:sveltekit-example',
  ].join('\n')
  const astroStep = [
    '      - name: Verify Astro external CSS Module integration',
    '        env:',
    '          ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:astro-example',
  ].join('\n')
  const nuxtStep = [
    '      - name: Verify Nuxt external CSS Module integration',
    '        env:',
    '          ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:nuxt-example',
  ].join('\n')
  const parcelStep = [
    '      - name: Verify Parcel local transformer integration',
    '        env:',
    '          ZIGCSS_PARCEL_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:parcel-example',
  ].join('\n')
  if (literalCount(build, turbopackStep) !== 1) {
    fail('build workflow Turbopack gate must own exact ZIGCSS_TURBOPACK_NATIVE_BINARY env')
  }
  if (literalCount(build, nextWebpackStep) !== 1) {
    fail('build workflow Next.js Webpack gate must own exact ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY env')
  }
  if (literalCount(build, sveltekitStep) !== 1) {
    fail('build workflow SvelteKit gate must own exact ZIGCSS_SVELTEKIT_NATIVE_BINARY env')
  }
  if (literalCount(build, astroStep) !== 1) {
    fail('build workflow Astro gate must own exact ZIGCSS_ASTRO_NATIVE_BINARY env')
  }
  if (literalCount(build, nuxtStep) !== 1) {
    fail('build workflow Nuxt gate must own exact ZIGCSS_NUXT_NATIVE_BINARY env')
  }
  if (literalCount(build, parcelStep) !== 1) {
    fail('build workflow Parcel gate must own exact ZIGCSS_PARCEL_NATIVE_BINARY env')
  }
  if (literalCount(build, adaptersStep) !== 1) {
    fail('build workflow adapter gate must own exact ZIGCSS_ADAPTER_NATIVE_BINARY env')
  }
  if (literalCount(build, buildSystemsStep) !== 1) {
    fail('build workflow build-system gate must own exact ZIGCSS_REAL_BINARY and mandatory-toolchain env')
  }
  const buildTestJob = build.slice(build.indexOf('\n  test:\n'))
  validateReleaseConsumerSteps(buildTestJob)
  const buildConsumer = build.indexOf(`- name: ${releaseConsumerSteps[0].name}`)
  const buildConsumerTerminal = build.indexOf(`- name: ${releaseConsumerSteps.at(-1).name}`, buildConsumer)
  const buildPackage = build.indexOf('- name: Verify native zero-dependency package', buildConsumerTerminal)
  const buildNodeApi = build.indexOf('- name: Verify packaged Node API', buildPackage)
  const buildInstall = build.indexOf('- name: Install independent validator', buildNodeApi)
  const buildAudit = build.indexOf('- name: Verify dependency policy and production audits', buildInstall)
  const buildPackageManagers = build.indexOf('- name: Verify package-manager lifecycle recovery', buildAudit)
  const buildTypes = build.indexOf('- name: Verify TypeScript package surfaces', buildPackageManagers)
  if (
    buildConsumer < 0
    || buildConsumerTerminal <= buildConsumer
    || buildPackage <= buildConsumerTerminal
    || buildNodeApi <= buildPackage
    || buildInstall <= buildNodeApi
    || buildAudit <= buildInstall
    || buildPackageManagers <= buildAudit
    || buildTypes <= buildPackageManagers
  ) {
    fail('build workflow native package gate is ordered incorrectly')
  }
  const buildRunTests = build.indexOf(runTestsStep, buildTypes)
  const buildAdapters = build.indexOf(adaptersStep, buildRunTests)
  const buildTurbopack = build.indexOf(turbopackStep, buildAdapters)
  const buildNextWebpack = build.indexOf(nextWebpackStep, buildTurbopack)
  const buildSveltekit = build.indexOf(sveltekitStep, buildNextWebpack)
  const buildAstro = build.indexOf(astroStep, buildSveltekit)
  const buildNuxt = build.indexOf(nuxtStep, buildAstro)
  const buildParcel = build.indexOf(parcelStep, buildNuxt)
  const buildSystems = build.indexOf(buildSystemsStep, buildParcel)
  if (
    buildRunTests <= buildTypes
    || buildAdapters <= buildRunTests
    || buildTurbopack <= buildAdapters
    || buildNextWebpack <= buildTurbopack
    || buildSveltekit <= buildNextWebpack
    || buildAstro <= buildSveltekit
    || buildNuxt <= buildAstro
    || buildParcel <= buildNuxt
    || buildSystems <= buildParcel
  ) {
    fail('build workflow native adapter, Turbopack, Next.js Webpack, SvelteKit, Astro, Nuxt, Parcel, and dependency-file build-system gates must run after Run Tests')
  }
  const releaseSetup = release.indexOf('- name: Setup Node.js')
  const releasePackage = release.indexOf('- name: Verify native zero-dependency package', releaseSetup)
  const releaseNodeApi = release.indexOf('- name: Verify packaged Node API', releasePackage)
  const releaseVersion = release.indexOf('- name: Verify synchronized release version for publication', releaseNodeApi)
  if (
    releaseSetup < 0 ||
    releasePackage <= releaseSetup ||
    releaseNodeApi <= releasePackage ||
    releaseVersion <= releaseNodeApi
  ) {
    fail('release preflight native package gate is ordered incorrectly')
  }
  validateBuildPackageNodeJobs(build)
  validateReleasePackageNodeJobs(release)
  if (literalCount(docs, "node-version: '22.22.0'") !== 1) {
    fail('documentation package consumer must use exact Node 22.22.0')
  }
  if (
    literalCount(release, 'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --provenance') !== 1
    || literalCount(release, 'RELEASE_CHANNEL: ${{ needs.npm-preflight.outputs.release-channel }}') !== 1
  ) {
    fail('npm publication must retain the exact tested archive, SemVer-selected channel, and provenance')
  }
  return true
}

export function validatePreprocessorPackage(root = repositoryRoot, { pack = true } = {}) {
  const manifest = readJson(path.join(root, 'package.json'), 'package.json')
  const lock = readJson(path.join(root, 'package-lock.json'), 'package-lock.json')
  const documentationLock = readJson(path.join(root, 'docs/package-lock.json'), 'docs/package-lock.json')
  const closure = validateManifestPolicy(manifest, lock)
  validatePackageManagerMatrixSource(
    fs.readFileSync(path.join(root, 'scripts/verify-package-managers.test.mjs'), 'utf8'),
  )
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
