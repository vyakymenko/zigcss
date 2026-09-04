import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { readBoundedDirectory, readStableRegularFile } from './bounded-filesystem.mjs'
import { collectLessSource } from './vendor-less-corpus.mjs'
import { collectStylusTree } from './vendor-stylus-corpus.mjs'
import {
  canonicalProviderMetadata,
  directProductionDependencies,
  discoverRuntimeSourceClosure,
  expectedPackedFiles,
  manifestPackageFiles,
  minimumNodeVersion,
  nativePackageTargets,
  packageBins,
  packageExports,
  packageManagerMatrixPolicy,
  packageTypesVersions,
  parcelExampleDevelopmentDependencies,
  productionDependencyClosure,
  referenceDevelopmentDependencies,
  renderPreprocessorSbom,
  renderThirdPartyNotices,
  repositoryRoot,
  runtimeSourceFiles,
  validateLinkedDocumentationConsumer,
  validateManifestPolicy,
  validatePackageManagerMatrixSource,
  validatePackageDescription,
  validatePreprocessorPackage,
  validatePreprocessorPackagingWorkflows,
  writeGeneratedFileAtomically,
} from './validate-preprocessor-package.mjs'

function sources() {
  return {
    manifest: JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8')),
    lock: JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8')),
  }
}

function replaceWorkflowJobText(source, jobName, current, replacement) {
  const header = `\n  ${jobName}:\n`
  const start = source.indexOf(header)
  assert.notEqual(start, -1, `missing workflow job ${jobName}`)
  assert.equal(source.indexOf(header, start + header.length), -1, `duplicate workflow job ${jobName}`)
  const bodyStart = start + header.length
  const relativeEnd = source.slice(bodyStart).search(/\n  [A-Za-z][A-Za-z0-9_-]*:\n/)
  const end = relativeEnd === -1 ? source.length : bodyStart + relativeEnd
  const body = source.slice(bodyStart, end)
  const changed = body.replace(current, replacement)
  assert.notEqual(changed, body, `workflow job ${jobName} does not contain the requested mutation`)
  return source.slice(0, bodyStart) + changed + source.slice(end)
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
      ['less', 'sass', 'stylus']
        .map(name => [name, manifest.devDependencies[name]]),
    ),
    {
      less: '4.9.0',
      sass: '1.101.0',
      stylus: '0.64.0',
    },
  )
  assert.deepEqual(
    Object.fromEntries(Object.keys(parcelExampleDevelopmentDependencies).map(name => [
      name,
      manifest.devDependencies[name],
    ])),
    parcelExampleDevelopmentDependencies,
  )
})

test('native npm archive includes only the bounded runtime declaration metadata and trust inventory', () => {
  const { manifest } = sources()
  assert.deepEqual(manifest.bin, packageBins)
  assert.deepEqual(manifest.exports, packageExports)
  assert.deepEqual(manifest.typesVersions, packageTypesVersions)
  for (const relativePath of [...manifest.files, ...expectedPackedFiles]) {
    assert.doesNotMatch(relativePath, /^preprocessor(?:\/|$)/)
  }
  assert.deepEqual(discoverRuntimeSourceClosure(), {
    files: runtimeSourceFiles,
    external: [],
  })
})

test('package-manager matrix pins Corepack generations and exact CI Bun fail-closed', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'scripts/verify-package-managers.test.mjs'), 'utf8')
  assert.deepEqual(validatePackageManagerMatrixSource(source), {
    bun: '1.4.0',
    managers: 6,
    pnpm: '11.25.0',
    yarnClassic: '1.22.22',
    yarnModern: '4.9.4',
  })
  assert.deepEqual(packageManagerMatrixPolicy, {
    bun: '1.4.0',
    managers: 6,
    pnpm: '11.25.0',
    yarnClassic: '1.22.22',
    yarnModern: '4.9.4',
  })
  for (const [current, replacement] of [
    ["const toolchainRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-toolchain-'))", 'const toolchainRoot = os.homedir()'],
    ["const corepackHome = path.join(toolchainRoot, 'corepack')", "const corepackHome = path.join(os.homedir(), '.cache/node/corepack')"],
    ['const maximumToolchainBytes = 256 * 1024 * 1024', 'const maximumToolchainBytes = Number.MAX_SAFE_INTEGER'],
    ['const maximumToolchainEntries = 10_000', 'const maximumToolchainEntries = Number.MAX_SAFE_INTEGER'],
    ['function detectCli(name, commandPrefix = [], environment = toolchainOfflineEnvironment) {', 'function detectCli(name, commandPrefix = [], environment = process.env) {'],
    ["const result = spawnSync(command, [...commandPrefix, '--version'], {\n    cwd: toolchainRoot,\n    encoding: 'utf8',\n    env: environment,", "const result = spawnSync(command, [...commandPrefix, '--version'], {\n    cwd: toolchainRoot,\n    encoding: 'utf8',\n    env: process.env,"],
    ['    cwd: toolchainRoot,\n    encoding:', '    cwd: repositoryRoot,\n    encoding:'],
    ['const direct = detectCli(name, [], toolchainOfflineEnvironment)', 'const direct = detectCli(name, [], process.env)'],
    ['    toolchainDetectionEnvironment,\n  )', '    process.env,\n  )'],
    ['COREPACK_HOME: corepackHome,', 'COREPACK_HOME: process.env.COREPACK_HOME,'],
    ["COREPACK_ENABLE_NETWORK: '1'", "COREPACK_ENABLE_NETWORK: '0'"],
    ['function inspectBoundedToolchainRoot() {', 'function skipToolchainInspection() {'],
    ['      inspectBoundedToolchainRoot()', '      // skipped final Corepack inspection'],
    ["fs.rmSync(toolchainRoot, { recursive: true, force: true })", '// retained global Corepack cache'],
    ['assert.equal(environment.COREPACK_HOME, corepackHome)', 'assert.equal(environment.COREPACK_HOME, process.env.COREPACK_HOME)'],
    ["  yarnModern: '4.9.4',", "  yarnModern: '4.9.3',"],
    ["COREPACK_ENABLE_NETWORK: '0'", "COREPACK_ENABLE_NETWORK: '1'"],
    ["return ['add', packageArchive, '--exact', '--mode=skip-build']", "return ['add', packageArchive, '--exact']"],
    ['return [...(manager.cli.commandPrefix ?? []), ...args]', 'return args'],
    ['verifyGitHubActionsToolchain(managers)', '// removed CI toolchain gate'],
    ["environment.YARN_ENABLE_COLORS = 'false'", "environment.YARN_ENABLE_COLORS = 'true'"],
    ["environment.YARN_ENABLE_GLOBAL_CACHE = 'false'", "environment.YARN_ENABLE_GLOBAL_CACHE = 'true'"],
    ["environment.YARN_GLOBAL_FOLDER = path.join(cache, 'yarn-global')", "environment.YARN_GLOBAL_FOLDER = process.cwd()"],
    ["assert.equal(Object.hasOwn(environment, 'YARN_NODE_LINKER'), false)", "assert.equal(environment.YARN_NODE_LINKER, 'node-modules')"],
    ['const pnpStat = fs.lstatSync(pnpLoader)', 'const pnpStat = fs.statSync(pnpLoader)'],
    ["assert.equal(pnpStat.isFile(), true, 'default Yarn PnP must create .pnp.cjs')", "assert.equal(pnpStat.isFile(), false, 'default Yarn PnP must create .pnp.cjs')"],
    ["assert.equal(pnpStat.isSymbolicLink(), false, 'default Yarn PnP loader must not be a symlink')", "assert.equal(pnpStat.isSymbolicLink(), true, 'default Yarn PnP loader must not be a symlink')"],
    ["assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'default Yarn PnP must not create node_modules')", '// removed PnP install node_modules check'],
    ['PnP TypeScript no-paths boundary must not create node_modules', 'PnP TypeScript boundary may create node_modules'],
    ['PnP declaration-byte compilation must not create node_modules', 'PnP declaration compilation may create node_modules'],
    ["assert.equal(fs.existsSync(path.join(consumer, 'node_modules')), false, 'PnP recovery must not create node_modules')", '// removed PnP recovery node_modules check'],
    ['fs.accessSync(installedRoot, fs.constants.R_OK | fs.constants.W_OK)', 'fs.accessSync(installedRoot, fs.constants.R_OK)'],
    ['Yarn must unpack zigcss into its project-local writable PnP area', 'Yarn may use any writable package location'],
    ['assert.equal(path.isAbsolute(relativeManifest), false)', 'assert.equal(path.isAbsolute(relativeManifest), true)'],
    ["assert.doesNotMatch(relativeManifest, /^\\.\\.(?:[/\\\\]|$)/)", '// removed installed manifest confinement'],
    ['/^\\.yarn[/\\\\]unplugged[/\\\\][^/\\\\]+[/\\\\]node_modules[/\\\\]zigcss[/\\\\]package\\.json$/', '/package\\.json$/'],
    ['assert.equal(manifest.preferUnplugged, true)', 'assert.equal(manifest.preferUnplugged, false)'],
    ['assert.equal(missing.signal, null)', 'assert.equal(missing.signal, undefined)'],
    ['assert.equal(missing.status, 1)', 'assert.equal(missing.status, 0)'],
    ["assert.equal(missing.stdout, '')", "assert.equal(missing.stdout, 'ignored')"],
    ['assert.equal(missing.stderr, missingBinaryStderr)', "assert.equal(missing.stderr, '')"],
    ["const recovered = successfulManagerCommand(manager, ['zigcss-install'], {", "const recovered = successfulManagerCommand(manager, ['zigcss'], {"],
    ['NODE_OPTIONS: `--require=${JSON.stringify(releasePreload)}`', "NODE_OPTIONS: ''"],
    ['createReleaseArchive({', 'missingCreateReleaseArchive({'],
    ['selected.sha256 = fixture.fixtureDigest', 'selected.sha256 = selected.sha256'],
    ['trustLocalFixtureInInstalledCopy(installedRoot, preloadedRelease)', '// removed isolated fixture trust'],
    ['PnP CommonJS export resolution', 'ordinary CommonJS export resolution'],
    ['PnP ESM export resolution', 'ordinary ESM export resolution'],
    ['assert.equal(nativeManifest.name, nativeSpecifier)', "assert.equal(nativeManifest.name, 'typescript')"],
    ["successfulManagerCommand(manager, ['tsc', '--version'], {", "successfulManagerCommand(manager, ['tsc'], {"],
    ['assert.equal(Object.hasOwn(baseConfig.compilerOptions.paths, specifier), false)', 'assert.equal(Object.hasOwn(baseConfig.compilerOptions.paths, specifier), true)'],
    ['PnP TypeScript 7 no-paths package resolution boundary', 'PnP TypeScript path-mapped resolution'],
    ["const noPaths = exactManagerCommand(manager, ['tsc', '-p', baseConfigPath], {", "const noPaths = successfulManagerCommand(manager, ['tsc', '-p', baseConfigPath], {"],
    ['assert.equal(noPaths.status, 1)', 'assert.equal(noPaths.status, 0)'],
    ["noPaths.stdout.includes(`error TS2307: Cannot find module '${specifier}' or its corresponding type declarations.`)", 'noPaths.stdout.includes(specifier)'],
    ['path.join(installedRoot, manifest.exports[exportName][mode].types.slice(2))', 'path.join(repositoryRoot, manifest.exports[exportName][mode].types.slice(2))'],
    ["successfulManagerCommand(manager, ['tsc', '-p', configPath], {", "successfulManagerCommand(manager, ['node', configPath], {"],
    ['assert.equal(executed.stdout, `${process.version}\\n`)', "assert.equal(executed.stdout, '')"],
    ['assert.equal(path.isAbsolute(relativeCache), false)', 'assert.equal(path.isAbsolute(relativeCache), true)'],
    ["assert.doesNotMatch(relativeCache, /^\\.\\.(?:[/\\\\]|$)/)", '// removed cache confinement'],
  ]) {
    const mutated = source.replace(current, replacement)
    assert.notEqual(mutated, source)
    assert.throws(() => validatePackageManagerMatrixSource(mutated), /package-manager matrix changed exact contract/)
  }
  const optionalCiManager = source.replace('mandatoryInGitHubActions: true,', 'mandatoryInGitHubActions: false,')
  assert.notEqual(optionalCiManager, source)
  assert.throws(
    () => validatePackageManagerMatrixSource(optionalCiManager),
    /must make npm mandatory in GitHub Actions/,
  )
  const nodeModulesOnly = source.replace(
    "    pnp: true,\n    label: `Yarn Modern ${packageManagerVersions.yarnModern} default PnP`,",
    "    nodeLinker: 'node-modules',\n    label: `Yarn Modern ${packageManagerVersions.yarnModern} default PnP`,",
  )
  assert.notEqual(nodeModulesOnly, source)
  assert.throws(
    () => validatePackageManagerMatrixSource(nodeModulesOnly),
    /default Yarn Modern PnP branch without a nodeLinker override/,
  )
  const liveReleaseFixture = `${source}\nrepositoryInstaller.boundedDownload(descriptor.archiveUrl)\n`
  assert.throws(
    () => validatePackageManagerMatrixSource(liveReleaseFixture),
    /local PnP fixture must not fetch live release assets/,
  )
})

test('owns one exact installable native binary and Node API package surface', () => {
  const result = validatePreprocessorPackage(repositoryRoot, { pack: false })
  assert.deepEqual(result, {
    dependencies: 0,
    externalImports: 0,
    nativeTargets: 5,
    packageFiles: 48,
    runtimeSources: 17,
  })
  assert.deepEqual(discoverRuntimeSourceClosure(), {
    files: runtimeSourceFiles,
    external: [],
  })
})

test('generated package metadata writes only bounded allowlisted non-symlink targets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-metadata-'))
  try {
    assert.throws(
      () => writeGeneratedFileAtomically(root, '../outside.txt', 'unsafe\n'),
      /output path is not allowlisted/,
    )
    writeGeneratedFileAtomically(root, 'THIRD_PARTY_NOTICES.md', 'exact\n')
    writeGeneratedFileAtomically(root, 'THIRD_PARTY_NOTICES.md', 'exact\n')
    assert.equal(fs.readFileSync(path.join(root, 'THIRD_PARTY_NOTICES.md'), 'utf8'), 'exact\n')

    if (process.platform !== 'win32') {
      const outside = path.join(root, 'outside.txt')
      const output = path.join(root, 'PREPROCESSOR-SBOM.spdx.json')
      fs.writeFileSync(outside, 'do not replace\n')
      fs.symlinkSync(outside, output)
      assert.throws(
        () => writeGeneratedFileAtomically(root, 'PREPROCESSOR-SBOM.spdx.json', '{}\n'),
        /regular non-symlink file/,
      )
      assert.equal(fs.readFileSync(outside, 'utf8'), 'do not replace\n')
    }
    assert.throws(
      () => writeGeneratedFileAtomically(root, 'THIRD_PARTY_NOTICES.md', 'x'.repeat((2 * 1024 * 1024) + 1)),
      /outside the allowed range/,
    )
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('bounded filesystem primitives reject symlinks, oversized files, and oversized inventories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-bounded-filesystem-'))
  try {
    const file = path.join(root, 'file.txt')
    fs.writeFileSync(file, 'safe')
    assert.equal(readStableRegularFile(file, { maximumBytes: 4 }).toString(), 'safe')
    assert.throws(
      () => readStableRegularFile(file, { maximumBytes: 3 }),
      /must contain 1 through 3 bytes/,
    )

    fs.mkdirSync(path.join(root, 'inventory'))
    fs.writeFileSync(path.join(root, 'inventory', 'one'), '1')
    fs.writeFileSync(path.join(root, 'inventory', 'two'), '2')
    assert.throws(
      () => readBoundedDirectory(path.join(root, 'inventory'), { maximumEntries: 1 }),
      /exceeds 1 entries/,
    )

    if (process.platform !== 'win32') {
      const link = path.join(root, 'link.txt')
      fs.symlinkSync(file, link)
      assert.throws(
        () => readStableRegularFile(link, { maximumBytes: 4 }),
        /regular non-symlink|is a symlink/,
      )
      const directoryLink = path.join(root, 'inventory-link')
      fs.symlinkSync(path.join(root, 'inventory'), directoryLink, 'dir')
      assert.throws(
        () => readBoundedDirectory(directoryLink, { maximumEntries: 2 }),
        /regular non-symlink directory/,
      )
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('Less and Stylus corpus collectors enforce file, symlink, and traversal bounds', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-corpus-collector-'))
  try {
    const lessDirectory = path.join(root, 'packages', 'test-data', 'safe')
    fs.mkdirSync(lessDirectory, { recursive: true })
    fs.writeFileSync(path.join(lessDirectory, 'entry.less'), '.safe { color: green; }\n')
    const lessFiles = new Map()
    collectLessSource(root, 'packages/test-data/safe', lessFiles)
    assert.equal(lessFiles.get('safe/entry.less').bytes.toString(), '.safe { color: green; }\n')

    const stylusDirectory = path.join(root, 'test', 'images')
    fs.mkdirSync(stylusDirectory, { recursive: true })
    fs.writeFileSync(path.join(stylusDirectory, 'pixel.bin'), 'pixel')
    fs.writeFileSync(path.join(stylusDirectory, 'ignored.js'), 'throw new Error()')
    const stylusFiles = new Map()
    collectStylusTree(root, 'test/images', 'upstream/images', stylusFiles)
    assert.equal(stylusFiles.get('upstream/images/pixel.bin').bytes.toString(), 'pixel')
    assert.equal(stylusFiles.has('upstream/images/ignored.js'), false)

    const largeLess = path.join(root, 'packages', 'test-data', 'oversized.less')
    fs.writeFileSync(largeLess, '')
    fs.truncateSync(largeLess, (16 * 1024 * 1024) + 1)
    assert.throws(
      () => collectLessSource(root, 'packages/test-data/oversized.less', new Map()),
      /must contain 1 through 16777216 bytes/,
    )

    const largeStylus = path.join(root, 'test', 'oversized.styl')
    fs.writeFileSync(largeStylus, '')
    fs.truncateSync(largeStylus, (16 * 1024 * 1024) + 1)
    assert.throws(
      () => collectStylusTree(root, 'test/oversized.styl', 'upstream/oversized.styl', new Map()),
      /must contain 1 through 16777216 bytes/,
    )

    let deepDirectory = path.join(root, 'packages', 'test-data', 'deep')
    fs.mkdirSync(deepDirectory, { recursive: true })
    for (let index = 0; index < 33; index += 1) {
      deepDirectory = path.join(deepDirectory, `d${index}`)
      fs.mkdirSync(deepDirectory)
    }
    assert.throws(
      () => collectLessSource(root, 'packages/test-data/deep', new Map()),
      /source traversal exceeds depth 32/,
    )

    if (process.platform !== 'win32') {
      const lessLink = path.join(root, 'packages', 'test-data', 'linked.less')
      fs.symlinkSync(path.join(lessDirectory, 'entry.less'), lessLink)
      assert.throws(
        () => collectLessSource(root, 'packages/test-data/linked.less', new Map()),
        /regular non-symlink|is a symlink/,
      )
      const stylusLink = path.join(root, 'test', 'linked.styl')
      fs.symlinkSync(path.join(stylusDirectory, 'pixel.bin'), stylusLink)
      assert.throws(
        () => collectStylusTree(root, 'test/linked.styl', 'upstream/linked.styl', new Map()),
        /regular non-symlink|is a symlink/,
      )
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
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
  assert.equal(manifest.preferUnplugged, true)
  assert.equal(Object.hasOwn(manifest, 'os'), false)
  assert.equal(Object.hasOwn(manifest, 'cpu'), false)
  assert.deepEqual(manifest.files, manifestPackageFiles)
  assert.deepEqual(productionDependencyClosure(lock).length, 0)

  const invalidNode = structuredClone(manifest)
  invalidNode.engines.node = '>=18'
  assert.throws(() => validateManifestPolicy(invalidNode, lock), /Node policy/)

  const zippedPnpPackage = structuredClone(manifest)
  delete zippedPnpPackage.preferUnplugged
  assert.throws(() => validateManifestPolicy(zippedPnpPackage, lock), /Yarn Plug'n'Play/)

  const cartesian = structuredClone(manifest)
  cartesian.os = ['linux', 'win32']
  cartesian.cpu = ['x64', 'arm64']
  assert.throws(() => validateManifestPolicy(cartesian, lock), /non-Cartesian/)

  const ranged = structuredClone(manifest)
  ranged.devDependencies.sass = '^1.101.0'
  assert.throws(() => validateManifestPolicy(ranged, lock), /development-only canonical reference/)

  const rangedParcel = structuredClone(manifest)
  rangedParcel.devDependencies.parcel = '^2.16.4'
  assert.throws(() => validateManifestPolicy(rangedParcel, lock), /Parcel integration dependency graph/)

  const productionProvider = structuredClone(manifest)
  productionProvider.dependencies.sass = '1.101.0'
  assert.throws(() => validateManifestPolicy(productionProvider, lock), /zero production dependencies/)

  const optionalProvider = structuredClone(manifest)
  optionalProvider.optionalDependencies = { sass: '1.101.0' }
  assert.throws(() => validateManifestPolicy(optionalProvider, lock), /zero optional dependencies/)

  const extraFile = structuredClone(manifest)
  extraFile.files.push('tests')
  assert.throws(() => validateManifestPolicy(extraFile, lock), /runtime allowlist/)

  const staleMain = structuredClone(manifest)
  staleMain.main = 'index.js'
  assert.throws(() => validateManifestPolicy(staleMain, lock), /programmatic Node API/)

  const staleTypes = structuredClone(manifest)
  staleTypes.types = 'missing.d.ts'
  assert.throws(() => validateManifestPolicy(staleTypes, lock), /programmatic Node API/)

  const staleExports = structuredClone(manifest)
  staleExports.exports['.'].import = './index.js'
  assert.throws(() => validateManifestPolicy(staleExports, lock), /builder-adapter contract/)

  const staleTypesVersions = structuredClone(manifest)
  staleTypesVersions.typesVersions['*'].vite = ['missing.d.ts']
  assert.throws(() => validateManifestPolicy(staleTypesVersions, lock), /builder-adapter contract/)

  const missingRecoveryBin = structuredClone(manifest)
  delete missingRecoveryBin.bin['zigcss-install']
  assert.throws(() => validateManifestPolicy(missingRecoveryBin, lock), /lifecycle recovery/)

  const staleBuildSystemsScript = structuredClone(manifest)
  staleBuildSystemsScript.scripts['test:build-systems'] = 'node scripts/verify-build-system-examples.test.mjs'
  assert.throws(() => validateManifestPolicy(staleBuildSystemsScript, lock), /build-system test script/)

  const staleTypesScript = structuredClone(manifest)
  staleTypesScript.scripts['test:types'] = 'tsc tests/typescript/consumer.ts'
  assert.throws(() => validateManifestPolicy(staleTypesScript, lock), /TypeScript package-surface test script/)

  const stalePackageManagersScript = structuredClone(manifest)
  stalePackageManagersScript.scripts['test:package-managers'] = 'node scripts/verify-package-managers.test.mjs'
  assert.throws(() => validateManifestPolicy(stalePackageManagersScript, lock), /package-manager recovery test script/)

  const staleParcelScript = structuredClone(manifest)
  staleParcelScript.scripts['test:parcel-example'] = 'parcel build examples/parcel/index.html'
  assert.throws(() => validateManifestPolicy(staleParcelScript, lock), /Parcel local-plugin test script/)

  const staleTurbopackScript = structuredClone(manifest)
  staleTurbopackScript.scripts['test:turbopack-example'] = 'next build examples/next-turbopack'
  assert.throws(() => validateManifestPolicy(staleTurbopackScript, lock), /Turbopack example test script/)

  const staleNextWebpackScript = structuredClone(manifest)
  staleNextWebpackScript.scripts['test:next-webpack-example'] = 'next build examples/next-webpack'
  assert.throws(() => validateManifestPolicy(staleNextWebpackScript, lock), /Next\.js Webpack example test script/)

  const staleSveltekitScript = structuredClone(manifest)
  staleSveltekitScript.scripts['test:sveltekit-example'] = 'vite build examples/sveltekit'
  assert.throws(() => validateManifestPolicy(staleSveltekitScript, lock), /SvelteKit example test script/)

  const staleAstroScript = structuredClone(manifest)
  staleAstroScript.scripts['test:astro-example'] = 'astro build examples/astro'
  assert.throws(() => validateManifestPolicy(staleAstroScript, lock), /Astro example test script/)

  const staleNuxtScript = structuredClone(manifest)
  staleNuxtScript.scripts['test:nuxt-example'] = 'nuxt build examples/nuxt'
  assert.throws(() => validateManifestPolicy(staleNuxtScript, lock), /Nuxt example test script/)

  const staleNixCheckScript = structuredClone(manifest)
  staleNixCheckScript.scripts['check:nix-flake'] = 'nix flake check'
  assert.throws(() => validateManifestPolicy(staleNixCheckScript, lock), /Nix flake check script/)

  const staleNixTestScript = structuredClone(manifest)
  staleNixTestScript.scripts['test:nix-flake'] = 'node scripts/validate-nix-flake.test.mjs'
  assert.throws(() => validateManifestPolicy(staleNixTestScript, lock), /Nix flake policy test script/)
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
      build.replace('        run: npm run test:node-api', '        run: node scripts/verify-node-api.test.mjs'),
      release,
      docs,
    ),
    /packaged Node API gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build,
      release.replace('        run: npm run test:node-api', '        run: npm run test:node-wrapper'),
      docs,
    ),
    /packaged Node API gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:bundler-adapters', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /builder adapter gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:parcel-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /Parcel local-plugin gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:turbopack-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /Turbopack example gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:next-webpack-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /Next\.js Webpack example gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:sveltekit-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /SvelteKit example gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:astro-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /Astro example gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:nuxt-example', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /Nuxt example gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:build-systems', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /build-system gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_REAL_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_REAL_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_REAL_BINARY and mandatory-toolchain env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace("          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '1'", "          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '0'"),
      release,
      docs,
    ),
    /mandatory-toolchain env/,
  )
  const runTestsStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  const adapterStep = [
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
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_ADAPTER_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_ADAPTER_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_ADAPTER_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_TURBOPACK_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_TURBOPACK_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_SVELTEKIT_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_SVELTEKIT_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_ASTRO_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_ASTRO_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_NUXT_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_NUXT_NATIVE_BINARY env/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '          ZIGCSS_PARCEL_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
        '          ZIGCSS_PARCEL_NATIVE_BINARY: zig-out/bin/zigcss',
      ),
      release,
      docs,
    ),
    /ZIGCSS_PARCEL_NATIVE_BINARY env/,
  )
  const orderedBuildSteps = `${runTestsStep}\n\n${adapterStep}\n\n${turbopackStep}\n\n${nextWebpackStep}\n\n${sveltekitStep}\n\n${astroStep}\n\n${nuxtStep}\n\n${parcelStep}\n\n${buildSystemsStep}`
  const reorderedBuild = build.replace(
    orderedBuildSteps,
    `${adapterStep}\n\n${runTestsStep}\n\n${turbopackStep}\n\n${nextWebpackStep}\n\n${sveltekitStep}\n\n${astroStep}\n\n${nuxtStep}\n\n${parcelStep}\n\n${buildSystemsStep}`,
  )
  assert.notEqual(reorderedBuild, build)
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(reorderedBuild, release, docs),
    /native adapter, Turbopack, Next\.js Webpack, SvelteKit, Astro, Nuxt, Parcel, and dependency-file build-system gates must run after Run Tests/,
  )
  const nextWebpackAfterSveltekit = build.replace(
    `${turbopackStep}\n\n${nextWebpackStep}\n\n${sveltekitStep}`,
    `${turbopackStep}\n\n${sveltekitStep}\n\n${nextWebpackStep}`,
  )
  assert.notEqual(nextWebpackAfterSveltekit, build)
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(nextWebpackAfterSveltekit, release, docs),
    /native adapter, Turbopack, Next\.js Webpack, SvelteKit, Astro, Nuxt, Parcel, and dependency-file build-system gates must run after Run Tests/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:types', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /TypeScript package-surface gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '        run: npm run test:nix-flake && npm run check:nix-flake',
        '        run: npm run check:nix-flake',
      ),
      release,
      docs,
    ),
    /Nix flake CI contract.*both exact Nix flake static gates/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('nix/nix-2.35.2/install', 'nix/nix-2.35.1/install'),
      release,
      docs,
    ),
    /Nix flake CI contract.*exact immutable action and Nix 2\.35\.2 policy/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace('        run: npm run test:package-managers', '        run: npm run test:formats'),
      release,
      docs,
    ),
    /package-manager recovery gate/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace("bun-version: '1.4.0'", "bun-version: '1.3.14'"),
      release,
      docs,
    ),
    /package-manager CI contract.*exact reviewed Bun release|package-manager CI contract.*exact Bun 1\.4\.0/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0',
        'oven-sh/setup-bun@0000000000000000000000000000000000000000 # v2.2.0',
      ),
      release,
      docs,
    ),
    /package-manager CI contract.*exact reviewed Bun release/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build.replace(
        '      - name: Test release smoke\n        run: npm run test:release-smoke\n\n'
          + '      - name: Test release consumers\n        run: npm run test:release-consumers',
        '      - name: Test release consumer paths\n'
          + '        run: npm run test:release-smoke && npm run test:release-consumers',
      ),
      release,
      docs,
    ),
    /release consumer.*attributable/i,
  )
  for (const jobName of ['build', 'native-provenance-evidence', 'native-package-evidence']) {
    assert.throws(
      () => validatePreprocessorPackagingWorkflows(
        replaceWorkflowJobText(
          build,
          jobName,
          "node-version: '24.20.0'",
          "node-version: '24'",
        ),
        release,
        docs,
      ),
      /exact Node/,
    )
  }
  for (const jobName of ['npm-preflight', 'release', 'publish-npm', 'anonymous-public-delivery']) {
    assert.throws(
      () => validatePreprocessorPackagingWorkflows(
        build,
        replaceWorkflowJobText(
          release,
          jobName,
          "node-version: '24.20.0'",
          "node-version: '24'",
        ),
        docs,
      ),
      /all release npm surfaces must use exact Node 24\.20\.0 LTS/,
    )
  }
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      replaceWorkflowJobText(
        build,
        'test',
        "node-version: '24.20.0'",
        'node-version: 24',
      ),
      release,
      docs,
    ),
    /job test must use exact Node 24\.20\.0 LTS/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      replaceWorkflowJobText(
        build,
        'native-provenance-evidence',
        "node-version: '24.20.0'",
        "node-version: '24.20.0'\n          node-version: '24.20.0'",
      ),
      release,
      docs,
    ),
    /exact Node/,
  )
  assert.equal(
    validatePreprocessorPackagingWorkflows(
      build.replace('name: Build\n', "name: Build\n# node-version: '24.20.0'\n"),
      release,
      docs,
    ),
    true,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build,
      release,
      docs.replace("node-version: '24.20.0'", "node-version: '24'"),
    ),
    /exact Node/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build,
      release.replace(
        'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --registry=https://registry.npmjs.org/ --provenance',
        'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --provenance',
      ),
      docs,
    ),
    /provenance/,
  )
  assert.throws(
    () => validatePreprocessorPackagingWorkflows(
      build,
      release.replace(
        'RELEASE_CHANNEL: ${{ needs.npm-preflight.outputs.release-channel }}',
        'RELEASE_CHANNEL: next',
      ),
      docs,
    ),
    /SemVer-selected channel/,
  )
})
