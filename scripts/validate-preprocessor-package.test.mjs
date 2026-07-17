import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import {
  canonicalProviderMetadata,
  directProductionDependencies,
  discoverRuntimeSourceClosure,
  expectedPackedFiles,
  manifestPackageFiles,
  minimumNodeVersion,
  nativePackageTargets,
  productionDependencyClosure,
  renderPreprocessorSbom,
  renderThirdPartyNotices,
  repositoryRoot,
  runtimeSourceFiles,
  validateLinkedDocumentationConsumer,
  validateManifestPolicy,
  validatePackageDescription,
  validatePreprocessorPackage,
  validatePreprocessorPackagingWorkflows,
} from './validate-preprocessor-package.mjs'

function sources() {
  return {
    manifest: JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8')),
    lock: JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8')),
  }
}

test('owns one exact installable canonical preprocessor package surface', () => {
  const result = validatePreprocessorPackage(repositoryRoot, { pack: false })
  assert.deepEqual(result, {
    dependencies: 86,
    externalImports: 5,
    nativeTargets: 5,
    packageFiles: 28,
    runtimeSources: 22,
  })
  assert.deepEqual(discoverRuntimeSourceClosure(), {
    files: runtimeSourceFiles,
    external: ['glob', 'image-size', 'less', 'sass', 'stylus'],
  })
})

test('binds direct dependencies, providers, Node, exports, files, and non-Cartesian targets', () => {
  const { manifest, lock } = sources()
  assert.deepEqual(manifest.dependencies, directProductionDependencies)
  assert.deepEqual(manifest.zigcss.canonicalProviders, canonicalProviderMetadata)
  assert.deepEqual(manifest.zigcss.nativeTargets, nativePackageTargets)
  assert.equal(manifest.engines.node, minimumNodeVersion)
  assert.equal(Object.hasOwn(manifest, 'os'), false)
  assert.equal(Object.hasOwn(manifest, 'cpu'), false)
  assert.deepEqual(manifest.files, manifestPackageFiles)
  assert.deepEqual(productionDependencyClosure(lock).length, 86)

  const invalidNode = structuredClone(manifest)
  invalidNode.engines.node = '>=18'
  assert.throws(() => validateManifestPolicy(invalidNode, lock), /Node policy/)

  const cartesian = structuredClone(manifest)
  cartesian.os = ['linux', 'win32']
  cartesian.cpu = ['x64', 'arm64']
  assert.throws(() => validateManifestPolicy(cartesian, lock), /non-Cartesian/)

  const ranged = structuredClone(manifest)
  ranged.dependencies.sass = '^1.101.0'
  assert.throws(() => validateManifestPolicy(ranged, lock), /exact canonical provider graph/)

  const extraFile = structuredClone(manifest)
  extraFile.files.push('tests')
  assert.throws(() => validateManifestPolicy(extraFile, lock), /runtime allowlist/)
})

test('keeps the documentation package consumer lock synchronized with the shipped runtime', () => {
  const { manifest } = sources()
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'docs/package-lock.json'), 'utf8'))
  assert.equal(validateLinkedDocumentationConsumer(manifest, lock), true)

  const stale = structuredClone(lock)
  stale.packages['..'].engines.node = '>=14.0.0'
  assert.throws(
    () => validateLinkedDocumentationConsumer(manifest, stale),
    /linked-consumer lock metadata diverges/,
  )
})

test('locks the complete reviewed runtime graph and generated SPDX/notices bytes', () => {
  const { manifest, lock } = sources()
  const closure = validateManifestPolicy(manifest, lock)
  assert.equal(closure.length, 86)
  assert.deepEqual(
    [...new Set(closure.map(packagePath => lock.packages[packagePath].license))].sort(),
    ['Apache-2.0', 'BSD-3-Clause', 'BlueOak-1.0.0', 'ISC', 'MIT'],
  )
  assert.deepEqual(
    closure.filter(packagePath => lock.packages[packagePath].hasInstallScript === true),
    ['node_modules/@parcel/watcher'],
  )
  assert.deepEqual(
    closure.filter(packagePath => lock.packages[packagePath].deprecated !== undefined),
    ['node_modules/glob'],
  )

  const sbom = renderPreprocessorSbom(manifest, lock, closure)
  const parsed = JSON.parse(sbom)
  assert.equal(parsed.spdxVersion, 'SPDX-2.3')
  assert.equal(parsed.packages.length, 87)
  assert.equal(parsed.packages[0].name, 'zigcss')
  assert.match(parsed.documentNamespace, /^https:\/\/github\.com\/vyakymenko\/zigcss\/spdx\/npm\//)
  assert.equal(
    fs.readFileSync(path.join(repositoryRoot, 'PREPROCESSOR-SBOM.spdx.json'), 'utf8'),
    sbom,
  )
  assert.equal(
    fs.readFileSync(path.join(repositoryRoot, 'THIRD_PARTY_NOTICES.md'), 'utf8'),
    renderThirdPartyNotices(lock, closure),
  )

  const changedLicense = structuredClone(lock)
  changedLicense.packages['node_modules/sass'].license = 'UNKNOWN'
  assert.throws(() => validateManifestPolicy(manifest, changedLicense), /unreviewed license/)

  const changedIntegrity = structuredClone(lock)
  changedIntegrity.packages['node_modules/sass'].integrity = 'sha256-invalid'
  assert.throws(() => validateManifestPolicy(manifest, changedIntegrity), /SHA-512 integrity/)

  const changedLifecycle = structuredClone(lock)
  changedLifecycle.packages['node_modules/sass'].hasInstallScript = true
  assert.throws(() => validateManifestPolicy(manifest, changedLifecycle), /lifecycle inventory/)

  const changedDeprecation = structuredClone(lock)
  changedDeprecation.packages['node_modules/glob'].deprecated = 'different warning'
  assert.throws(() => validateManifestPolicy(manifest, changedDeprecation), /deprecation identity/)
})

test('npm pack description permits only the exact bounded runtime archive', () => {
  const { manifest } = sources()
  const description = {
    id: `zigcss@${manifest.version}`,
    filename: `zigcss-${manifest.version}.tgz`,
    size: 100_000,
    unpackedSize: 500_000,
    entryCount: expectedPackedFiles.length,
    files: expectedPackedFiles.map(file => ({ path: file })),
  }
  assert.equal(validatePackageDescription(description, manifest.version), description.filename)

  assert.throws(
    () => validatePackageDescription({ ...description, files: description.files.slice(1) }, manifest.version),
    /exact runtime inventory/,
  )
  assert.throws(
    () => validatePackageDescription({ ...description, unpackedSize: 5 * 1024 * 1024 }, manifest.version),
    /unpacked size/,
  )
  assert.throws(
    () => validatePackageDescription({ ...description, entryCount: description.entryCount + 1 }, manifest.version),
    /entry count/,
  )
})

test('CI and release workflows own exact Node, package, audit, and provenance gates', () => {
  const build = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/build.yml'), 'utf8')
  const release = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/release.yml'), 'utf8')
  const docs = fs.readFileSync(path.join(repositoryRoot, '.github/workflows/docs.yml'), 'utf8')
  assert.equal(validatePreprocessorPackagingWorkflows(build, release, docs), true)
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace("node-version: '20.19.0'", "node-version: '20'"),
      release,
      docs,
    ),
    /exact Node/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build,
      release.replace('npm publish --tag next --provenance', 'npm publish --tag next'),
      docs,
    ),
    /provenance/,
  )
})
