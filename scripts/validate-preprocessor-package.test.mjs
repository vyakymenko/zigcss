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
  referenceDevelopmentDependencies,
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

test('native npm package has zero production and optional dependencies', () => {
  const { manifest, lock } = sources()
  assert.deepEqual(manifest.dependencies, {})
  assert.equal(Object.hasOwn(manifest, 'optionalDependencies'), false)
  assert.deepEqual(lock.packages[''].dependencies, undefined)
  assert.deepEqual(lock.packages[''].optionalDependencies, undefined)
  assert.deepEqual(productionDependencyClosure(lock), [])
  assert.deepEqual(
    Object.fromEntries(
      ['image-size', 'less', 'sass', 'stylus']
        .map(name => [name, manifest.devDependencies[name]]),
    ),
    {
      'image-size': '0.5.5',
      less: '4.6.7',
      sass: '1.101.0',
      stylus: '0.64.0',
    },
  )
})

test('native npm archive excludes provider host and JavaScript API bytes', () => {
  const { manifest } = sources()
  assert.deepEqual(manifest.exports, {
    '.': './index.js',
    './package.json': './package.json',
  })
  for (const relativePath of [...manifest.files, ...expectedPackedFiles]) {
    assert.doesNotMatch(relativePath, /^(?:api\.mjs|preprocessor(?:\/|$))/)
  }
  assert.deepEqual(discoverRuntimeSourceClosure(), {
    files: ['index.js', 'install.js'],
    external: [],
  })
})

test('owns one exact installable native binary-wrapper package surface', () => {
  const result = validatePreprocessorPackage(repositoryRoot, { pack: false })
  assert.deepEqual(result, {
    dependencies: 0,
    externalImports: 0,
    nativeTargets: 5,
    packageFiles: 7,
    runtimeSources: 2,
  })
  assert.deepEqual(discoverRuntimeSourceClosure(), {
    files: runtimeSourceFiles,
    external: [],
  })
})

test('binds zero runtime dependencies, development oracles, Node, exports, files, and non-Cartesian targets', () => {
  const { manifest, lock } = sources()
  assert.deepEqual(manifest.dependencies, directProductionDependencies)
  assert.deepEqual(
    Object.fromEntries(Object.keys(referenceDevelopmentDependencies).map(name => [
      name,
      manifest.devDependencies[name],
    ])),
    referenceDevelopmentDependencies,
  )
  assert.deepEqual(manifest.zigcss.canonicalProviders, canonicalProviderMetadata)
  assert.deepEqual(manifest.zigcss.nativeTargets, nativePackageTargets)
  assert.equal(manifest.engines.node, minimumNodeVersion)
  assert.equal(Object.hasOwn(manifest, 'os'), false)
  assert.equal(Object.hasOwn(manifest, 'cpu'), false)
  assert.deepEqual(manifest.files, manifestPackageFiles)
  assert.deepEqual(productionDependencyClosure(lock).length, 0)

  const invalidNode = structuredClone(manifest)
  invalidNode.engines.node = '>=18'
  assert.throws(() => validateManifestPolicy(invalidNode, lock), /Node policy/)

  const cartesian = structuredClone(manifest)
  cartesian.os = ['linux', 'win32']
  cartesian.cpu = ['x64', 'arm64']
  assert.throws(() => validateManifestPolicy(cartesian, lock), /non-Cartesian/)

  const ranged = structuredClone(manifest)
  ranged.devDependencies.sass = '^1.101.0'
  assert.throws(() => validateManifestPolicy(ranged, lock), /development-only canonical reference/)

  const productionProvider = structuredClone(manifest)
  productionProvider.dependencies.sass = '1.101.0'
  assert.throws(() => validateManifestPolicy(productionProvider, lock), /zero production dependencies/)

  const optionalProvider = structuredClone(manifest)
  optionalProvider.optionalDependencies = { sass: '1.101.0' }
  assert.throws(() => validateManifestPolicy(optionalProvider, lock), /zero optional dependencies/)

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

test('generates an exact zero-dependency SPDX document and runtime notice', () => {
  const { manifest, lock } = sources()
  const closure = validateManifestPolicy(manifest, lock)
  assert.equal(closure.length, 0)

  const sbom = renderPreprocessorSbom(manifest, lock, closure)
  const parsed = JSON.parse(sbom)
  assert.equal(parsed.spdxVersion, 'SPDX-2.3')
  assert.equal(parsed.packages.length, 1)
  assert.equal(parsed.packages[0].name, 'zigcss')
  assert.deepEqual(parsed.relationships, [{
    spdxElementId: 'SPDXRef-DOCUMENT',
    relationshipType: 'DESCRIBES',
    relatedSpdxElement: 'SPDXRef-Package-zigcss',
  }])
  assert.match(parsed.documentNamespace, /^https:\/\/github\.com\/vyakymenko\/zigcss\/spdx\/npm\//)
  assert.equal(
    fs.readFileSync(path.join(repositoryRoot, 'PREPROCESSOR-SBOM.spdx.json'), 'utf8'),
    sbom,
  )
  assert.equal(
    fs.readFileSync(path.join(repositoryRoot, 'THIRD_PARTY_NOTICES.md'), 'utf8'),
    renderThirdPartyNotices(lock, closure),
  )

  assert.match(renderThirdPartyNotices(lock, closure), /zero production dependencies/i)
  assert.match(renderThirdPartyNotices(lock, closure), /development-only reference oracles/i)
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
      release,
      docs.replace("node-version: '22.22.0'", "node-version: '22'"),
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
