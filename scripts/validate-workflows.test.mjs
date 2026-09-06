import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  actionPins,
  buildThroughputPolicy,
  buildSystemCiPolicy,
  documentationBuildCiPolicy,
  documentationContainerCiPolicy,
  developmentContainerCiPolicy,
  publicDeliveryCiPolicy,
  readWorkflowSources,
  terminalWorkflowTimeoutPolicy,
  validateActionRuntimeMigration,
  validateAstroWorkflowContract,
  validateBuildThroughput,
  validateBuildSystemWorkflowContract,
  validateBuildTestGraph,
  validateDocumentationBuildCoverage,
  validateNativeIntegrityWorkflowContract,
  validateNextWebpackWorkflowContract,
  validateNixFlakeWorkflowContract,
  validateNuxtWorkflowContract,
  validatePackageManagerWorkflowContract,
  validatePublicDeliveryWorkflowContract,
  validateReleaseBuildEvidenceWorkflowContract,
  validateImmutableReleaseWorkflowContract,
  validateSetupZigAction,
  validateSetupZigWorkflowContract,
  validateSveltekitWorkflowContract,
  validateTurbopackWorkflowContract,
  validateTerminalWorkflowTimeouts,
  validateNativeCorpusCheckoutAttributes,
  workflowDisplayNames,
  validateWorkflowSources,
  validateWorkflows,
  validateZigTestSuiteRunner,
} from './validate-workflows.mjs'

function cloneSources() {
  return new Map(readWorkflowSources())
}

function replaceWorkflowJobText(source, jobName, current, replacement) {
  const marker = `  ${jobName}:\n`
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `missing workflow job ${jobName}`)
  const nextJob = source.slice(start + marker.length).search(/^  [a-zA-Z0-9_-]+:\n/m)
  const end = nextJob === -1 ? source.length : start + marker.length + nextJob
  const job = source.slice(start, end)
  assert.ok(job.includes(current), `${jobName} does not contain ${current}`)
  return `${source.slice(0, start)}${job.replace(current, replacement)}${source.slice(end)}`
}

test('all workflow jobs use explicit least privilege and immutable reviewed actions', () => {
  assert.deepEqual(validateWorkflows(), { workflows: 4, jobs: 12, actions: 47 })
  assert.deepEqual(validateZigTestSuiteRunner(), {
    failureHeadBytes: 3 * 1024,
    modes: ['Debug', 'ReleaseSafe'],
  })
})

test('build-system CI makes every advertised toolchain mandatory', () => {
  const sources = cloneSources()
  assert.deepEqual(validateBuildSystemWorkflowContract(sources.get('build.yml')), buildSystemCiPolicy)

  for (const [current, replacement] of [
    ["ZIGCSS_REQUIRE_BUILD_SYSTEMS: '1'", "ZIGCSS_REQUIRE_BUILD_SYSTEMS: '0'"],
    ['ZIGCSS_REAL_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss', 'ZIGCSS_REAL_BINARY: zigcss'],
    ['run: npm run test:build-systems', 'run: true'],
  ]) {
    const changed = sources.get('build.yml').replace(current, replacement)
    assert.notEqual(changed, sources.get('build.yml'))
    assert.throws(
      () => validateBuildSystemWorkflowContract(changed),
      /require all four toolchains|mandatory-toolchain/,
    )
  }
  const ambientPublishRegistry = sources.get('release.yml').replace(
    ' --registry=https://registry.npmjs.org/ --provenance; then',
    ' --provenance; then',
  )
  assert.notEqual(ambientPublishRegistry, sources.get('release.yml'))
  assert.throws(
    () => validateReleaseBuildEvidenceWorkflowContract(ambientPublishRegistry),
    /bind the canonical registry, channel, provenance, and hard timeout/,
  )
})

test('workflow display names remain exact and unique', () => {
  assert.deepEqual(workflowDisplayNames, {
    'benchmarks.yml': 'Benchmarks',
    'build.yml': 'Build',
    'docs.yml': 'Documentation',
    'release.yml': 'Release',
  })
  assert.equal(new Set(Object.values(workflowDisplayNames)).size, Object.keys(workflowDisplayNames).length)

  for (const [filename, name] of Object.entries(workflowDisplayNames)) {
    const renamed = cloneSources()
    renamed.set(filename, renamed.get(filename).replace(`name: ${name}`, 'name: Build impostor'))
    assert.throws(
      () => validateWorkflowSources(renamed),
      new RegExp(`${filename.replace('.', '\\.')} top-level workflow name`),
    )
  }
})

test('Windows checkout preserves the finite native conformance text-fixture surface as LF', () => {
  const attributes = fs.readFileSync('.gitattributes', 'utf8')
  assert.deepEqual(validateNativeCorpusCheckoutAttributes(attributes), {
    patterns: 13,
    patternsByLanguage: {
      sass: 5,
      less: 4,
      stylus: 4,
    },
  })

  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace('VERSION text eol=lf\n', '')),
    /canonical release checkout attribute changed/,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace('native-integrity.json text eol=lf\n', '')),
    /canonical release checkout attribute changed/,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace(
      'tests/preprocessors/sass/corpus/cases/**/*.scss text eol=lf\n',
      '',
    )),
    /native corpus checkout attributes changed/i,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace(
      'tests/preprocessors/less/corpus/files/**/*.less text eol=lf',
      'tests/preprocessors/less/corpus/files/**/*.less text',
    )),
    /native corpus checkout attributes changed/i,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace(
      'tests/preprocessors/stylus/corpus/files/**/*.styl text eol=lf\n',
      '',
    )),
    /native corpus checkout attributes changed/i,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace(
      'tests/preprocessors/stylus/corpus/files/**/*.css text eol=lf',
      'tests/preprocessors/stylus/corpus/files/**/*.css text',
    )),
    /native corpus checkout attributes changed/i,
  )
  assert.throws(
    () => validateNativeCorpusCheckoutAttributes(attributes.replace(
      'tests/preprocessors/stylus/corpus/files/**/*.json text eol=lf',
      'tests/preprocessors/stylus/corpus/files/** text eol=lf',
    )),
    /native corpus checkout attributes changed/i,
  )
})

test('the hosted action runtime migration has a finite reviewed terminal', () => {
  assert.deepEqual(validateActionRuntimeMigration(), {
    actions: 9,
    node24Actions: [
      'actions/checkout',
      'actions/setup-node',
      'actions/upload-artifact',
      'actions/download-artifact',
      'actions/upload-pages-artifact',
      'actions/deploy-pages',
      'oven-sh/setup-bun',
      'softprops/action-gh-release',
    ],
    replacedActions: ['mlugg/setup-zig'],
    pendingActions: [],
  })
})

test('Nix flake CI owns an exact fail-closed native Unix contract', () => {
  const sources = cloneSources()
  assert.deepEqual(validateNixFlakeWorkflowContract(sources.get('build.yml')), {
    action: 'cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24',
    installUrl: 'https://releases.nixos.org/nix/nix-2.35.2/install',
    nixVersion: '2.35.2',
    staticGate: 'npm run test:nix-flake && npm run check:nix-flake',
  })

  const mutableAction = cloneSources()
  mutableAction.set('build.yml', mutableAction.get('build.yml').replace(
    'cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31',
    'cachix/install-nix-action@v31',
  ))
  assert.throws(() => validateWorkflowSources(mutableAction), /full lowercase commit SHA/)

  for (const [current, replacement] of [
    ['run: node scripts/validate-nix-flake.mjs --check', 'run: true'],
    ['nix/nix-2.35.2/install', 'nix/nix-2.35.1/install'],
    ['enable_kvm: false', 'enable_kvm: true'],
    ['set_as_trusted_user: false', 'set_as_trusted_user: true'],
    ['sandbox = true', 'sandbox = relaxed'],
    ["if: runner.os != 'Windows'", "if: runner.os == 'Windows'"],
    [
      '          extra_nix_config: |\n            sandbox = true',
      "          extra_nix_config: |\n            sandbox = true\n          github_access_token: ''",
    ],
    ['nix (Nix) 2.35.2', 'nix (Nix) 2.35.1'],
    ['            --no-link \\\n', ''],
    ['            --no-update-lock-file \\\n', ''],
    ['            --no-write-lock-file \\\n', ''],
    ['            --no-use-registries \\\n', ''],
    ['git diff --exit-code -- flake.nix flake.lock', 'git diff --exit-code -- flake.nix'],
    ['npm run test:nix-flake && npm run check:nix-flake', 'npm run check:nix-flake'],
  ]) {
    const mutated = cloneSources()
    const source = mutated.get('build.yml')
    assert.notEqual(source.replace(current, replacement), source, current)
    mutated.set('build.yml', source.replace(current, replacement))
    assert.throws(() => validateWorkflowSources(mutated), /Nix flake/)
  }

  const preflightStep = [
    '      - name: Validate Nix flake contract',
    "        if: runner.os != 'Windows'",
    '        run: node scripts/validate-nix-flake.mjs --check',
  ].join('\n')
  const installStep = [
    '      - name: Install exact Nix',
    "        if: runner.os != 'Windows'",
    '        uses: cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31',
    '        with:',
    '          install_url: https://releases.nixos.org/nix/nix-2.35.2/install',
    '          enable_kvm: false',
    '          set_as_trusted_user: false',
    '          extra_nix_config: |',
    '            sandbox = true',
  ].join('\n')
  const reordered = cloneSources()
  const reorderedSource = reordered.get('build.yml').replace(
    `${preflightStep}\n\n${installStep}`,
    `${installStep}\n\n${preflightStep}`,
  )
  assert.notEqual(reorderedSource, reordered.get('build.yml'))
  reordered.set('build.yml', reorderedSource)
  assert.throws(
    () => validateWorkflowSources(reordered),
    /Nix flake steps must be adjacent|statically validate, install, and verify Nix|fail closed before the installer/,
  )
})

test('package-manager CI owns one immutable setup-bun action and exact stable Bun release', () => {
  const sources = cloneSources()
  assert.deepEqual(validatePackageManagerWorkflowContract(sources.get('build.yml')), {
    action: 'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6',
    bunVersion: '1.4.0',
    gate: 'npm run test:package-managers',
  })

  const staleVersion = cloneSources()
  staleVersion.set('build.yml', staleVersion.get('build.yml').replace("bun-version: '1.4.0'", "bun-version: '1.3.14'"))
  assert.throws(
    () => validateWorkflowSources(staleVersion),
    /exact reviewed Bun release|exact Bun 1\.4\.0/,
  )

  const mutableAction = cloneSources()
  mutableAction.set('build.yml', mutableAction.get('build.yml').replace(
    'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0',
    'oven-sh/setup-bun@v2',
  ))
  assert.throws(() => validateWorkflowSources(mutableAction), /full lowercase commit SHA/)

  const setupStep = [
    '      - name: Setup Bun for package-manager matrix',
    '        uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0',
    '        with:',
    "          bun-version: '1.4.0'",
    '',
  ].join('\n')
  const missingSetup = cloneSources()
  missingSetup.set('build.yml', missingSetup.get('build.yml').replace(setupStep, ''))
  assert.throws(
    () => validateWorkflowSources(missingSetup),
    /action inventory|exact reviewed Bun release/,
  )
})

test('Next.js Turbopack CI owns one post-Debug current-native host gate', () => {
  const sources = cloneSources()
  assert.deepEqual(validateTurbopackWorkflowContract(sources.get('build.yml')), {
    gate: 'npm run test:turbopack-example',
    host: 'Next.js 16.3.4',
    nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  })

  const relativeBinary = cloneSources()
  relativeBinary.set('build.yml', relativeBinary.get('build.yml').replace(
    'ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    'ZIGCSS_TURBOPACK_NATIVE_BINARY: zig-out/bin/zigcss',
  ))
  assert.throws(
    () => validateWorkflowSources(relativeBinary),
    /exact absolute current-checkout native binary|native binary environment changed/,
  )

  const removedGate = cloneSources()
  removedGate.set('build.yml', removedGate.get('build.yml').replace(
    'run: npm run test:turbopack-example',
    'run: npm run removed-turbopack-example',
  ))
  assert.throws(() => validateWorkflowSources(removedGate), /Next\.js Turbopack gate/)

  const gateBlock = [
    '      - name: Verify Next.js Turbopack global SCSS integration',
    '        env:',
    '          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:turbopack-example',
    '',
  ].join('\n')
  const beforeDebug = cloneSources()
  beforeDebug.set('build.yml', beforeDebug.get('build.yml')
    .replace(gateBlock, '')
    .replace('      - name: Run Tests\n', `${gateBlock}      - name: Run Tests\n`))
  assert.throws(
    () => validateWorkflowSources(beforeDebug),
    /must run after the native Debug suite/,
  )
})

test('Next.js Webpack CI owns one exact post-Turbopack pre-SvelteKit current-native host gate', () => {
  const sources = cloneSources()
  assert.deepEqual(validateNextWebpackWorkflowContract(sources.get('build.yml')), {
    gate: 'npm run test:next-webpack-example',
    host: 'Next.js 16.3.4 with Webpack 5.110.2',
    nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
    nodeVersion: '24.20.0',
  })

  const missingGate = cloneSources()
  missingGate.set('build.yml', missingGate.get('build.yml').replace(
    'run: npm run test:next-webpack-example',
    'run: npm run removed-next-webpack-example',
  ))
  assert.throws(() => validateWorkflowSources(missingGate), /Next\.js Webpack gate/)

  const relativeBinary = cloneSources()
  relativeBinary.set('build.yml', relativeBinary.get('build.yml').replace(
    'ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    'ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: zig-out/bin/zigcss',
  ))
  assert.throws(
    () => validateWorkflowSources(relativeBinary),
    /exact absolute current-checkout native binary|native binary environment changed/,
  )

  const mutableNode = cloneSources()
  mutableNode.set('build.yml', replaceWorkflowJobText(
    mutableNode.get('build.yml'),
    'test',
    "node-version: '24.20.0'",
    'node-version: 24',
  ))
  assert.throws(
    () => validateNextWebpackWorkflowContract(mutableNode.get('build.yml')),
    /Next\.js Webpack gate must run on exact Node 24\.20\.0/,
  )

  const gateBlock = [
    '      - name: Verify Next.js Webpack global SCSS integration',
    '        env:',
    '          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:next-webpack-example',
    '',
  ].join('\n')
  const beforeTurbopack = cloneSources()
  beforeTurbopack.set('build.yml', beforeTurbopack.get('build.yml')
    .replace(gateBlock, '')
    .replace('      - name: Verify Next.js Turbopack global SCSS integration\n', `${gateBlock}      - name: Verify Next.js Turbopack global SCSS integration\n`))
  assert.throws(
    () => validateWorkflowSources(beforeTurbopack),
    /after the locked install, native Debug suite, and Turbopack gate, and before SvelteKit/,
  )

  const afterSveltekit = cloneSources()
  afterSveltekit.set('build.yml', afterSveltekit.get('build.yml')
    .replace(gateBlock, '')
    .replace(
      '        run: npm run test:sveltekit-example\n',
      `        run: npm run test:sveltekit-example\n\n${gateBlock}`,
    ))
  assert.throws(
    () => validateWorkflowSources(afterSveltekit),
    /after the locked install, native Debug suite, and Turbopack gate, and before SvelteKit/,
  )
})

test('SvelteKit CI owns one post-Debug current-native host gate', () => {
  const sources = cloneSources()
  assert.deepEqual(validateSveltekitWorkflowContract(sources.get('build.yml')), {
    gate: 'npm run test:sveltekit-example',
    host: 'SvelteKit 2.70.3 with Vite 8.2.2',
    nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  })

  const relativeBinary = cloneSources()
  relativeBinary.set('build.yml', relativeBinary.get('build.yml').replace(
    'ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    'ZIGCSS_SVELTEKIT_NATIVE_BINARY: zig-out/bin/zigcss',
  ))
  assert.throws(
    () => validateWorkflowSources(relativeBinary),
    /SvelteKit gate must use the exact absolute current-checkout native binary|SvelteKit native binary environment changed/,
  )

  const removedGate = cloneSources()
  removedGate.set('build.yml', removedGate.get('build.yml').replace(
    'run: npm run test:sveltekit-example',
    'run: npm run removed-sveltekit-example',
  ))
  assert.throws(() => validateWorkflowSources(removedGate), /SvelteKit gate/)

  const gateBlock = [
    '      - name: Verify SvelteKit external CSS Module integration',
    '        env:',
    '          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:sveltekit-example',
    '',
  ].join('\n')
  const beforeDebug = cloneSources()
  beforeDebug.set('build.yml', beforeDebug.get('build.yml')
    .replace(gateBlock, '')
    .replace('      - name: Run Tests\n', `${gateBlock}      - name: Run Tests\n`))
  assert.throws(
    () => validateWorkflowSources(beforeDebug),
    /SvelteKit gate must run after the native Debug suite/,
  )
})

test('Astro CI owns one post-Debug current-native host gate', () => {
  const sources = cloneSources()
  assert.deepEqual(validateAstroWorkflowContract(sources.get('build.yml')), {
    gate: 'npm run test:astro-example',
    host: 'Astro 7.2.10',
    nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  })

  const relativeBinary = cloneSources()
  relativeBinary.set('build.yml', relativeBinary.get('build.yml').replace(
    'ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    'ZIGCSS_ASTRO_NATIVE_BINARY: zig-out/bin/zigcss',
  ))
  assert.throws(
    () => validateWorkflowSources(relativeBinary),
    /Astro gate must use the exact absolute current-checkout native binary|Astro native binary environment changed/,
  )

  const mutableNode = cloneSources()
  mutableNode.set('build.yml', replaceWorkflowJobText(
    mutableNode.get('build.yml'),
    'test',
    "node-version: '24.20.0'",
    'node-version: 24',
  ))
  assert.throws(() => validateWorkflowSources(mutableNode), /Astro gate must run on exact Node 24\.20\.0/)

  const removedGate = cloneSources()
  removedGate.set('build.yml', removedGate.get('build.yml').replace(
    'run: npm run test:astro-example',
    'run: npm run removed-astro-example',
  ))
  assert.throws(() => validateWorkflowSources(removedGate), /Astro gate/)

  const gateBlock = [
    '      - name: Verify Astro external CSS Module integration',
    '        env:',
    '          ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:astro-example',
    '',
  ].join('\n')
  const beforeDebug = cloneSources()
  beforeDebug.set('build.yml', beforeDebug.get('build.yml')
    .replace(gateBlock, '')
    .replace('      - name: Run Tests\n', `${gateBlock}      - name: Run Tests\n`))
  assert.throws(
    () => validateWorkflowSources(beforeDebug),
    /Astro gate must run after the native Debug suite/,
  )
})

test('Nuxt CI owns one post-Debug current-native host gate', () => {
  const sources = cloneSources()
  assert.deepEqual(validateNuxtWorkflowContract(sources.get('build.yml')), {
    gate: 'npm run test:nuxt-example',
    host: 'Nuxt 4.5.2',
    nativeBinary: '${{ github.workspace }}/zig-out/bin/zigcss',
  })

  const relativeBinary = cloneSources()
  relativeBinary.set('build.yml', relativeBinary.get('build.yml').replace(
    'ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    'ZIGCSS_NUXT_NATIVE_BINARY: zig-out/bin/zigcss',
  ))
  assert.throws(
    () => validateWorkflowSources(relativeBinary),
    /Nuxt gate must use the exact absolute current-checkout native binary|Nuxt native binary environment changed/,
  )

  const unsupportedNode = cloneSources()
  unsupportedNode.set('build.yml', replaceWorkflowJobText(
    unsupportedNode.get('build.yml'),
    'test',
    "node-version: '24.20.0'",
    "node-version: '20.19.0'",
  ))
  assert.throws(
    () => validateNuxtWorkflowContract(unsupportedNode.get('build.yml')),
    /Nuxt gate must run on exact Node 24\.20\.0/,
  )

  const removedGate = cloneSources()
  removedGate.set('build.yml', removedGate.get('build.yml').replace(
    'run: npm run test:nuxt-example',
    'run: npm run removed-nuxt-example',
  ))
  assert.throws(() => validateWorkflowSources(removedGate), /Nuxt gate/)

  const gateBlock = [
    '      - name: Verify Nuxt external CSS Module integration',
    '        env:',
    '          ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:nuxt-example',
    '',
  ].join('\n')
  const beforeDebug = cloneSources()
  beforeDebug.set('build.yml', beforeDebug.get('build.yml')
    .replace(gateBlock, '')
    .replace('      - name: Run Tests\n', `${gateBlock}      - name: Run Tests\n`))
  assert.throws(
    () => validateWorkflowSources(beforeDebug),
    /Nuxt gate must run after the native Debug suite/,
  )
})

test('all four Zig setup placements use the repository-owned terminal and retain bounded cache cleanup', t => {
  const sources = cloneSources()
  const workflowText = [...sources.values()].join('\n')
  assert.equal(workflowText.split('uses: ./.github/actions/setup-zig').length - 1, 4)
  assert.equal(
    workflowText.split('node .github/actions/setup-zig/setup-zig.mjs --prune-cache').length - 1,
    4,
  )
  assert.doesNotMatch(workflowText, /mlugg\/setup-zig/)
  assert.deepEqual(validateSetupZigWorkflowContract(sources), {
    placements: 4,
    pruners: 4,
    version: '0.15.2',
  })
  assert.deepEqual(validateSetupZigAction(), {
    cacheActions: 2,
    cacheRuntime: 'node24',
    files: 2,
    hosts: 5,
    maximumArchiveEntries: 25_000,
    maximumCacheBytes: 2 * 1024 * 1024 * 1024,
    version: '0.15.2',
  })

  const stale = cloneSources()
  stale.set('build.yml', stale.get('build.yml').replace(
    'uses: ./.github/actions/setup-zig',
    'uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1',
  ))
  assert.throws(() => validateWorkflowSources(stale), /unreviewed action|action inventory|repository-owned Zig/)

  const unbounded = cloneSources()
  unbounded.set('release.yml', unbounded.get('release.yml').replace(
    '      - name: Bound Zig cache\n        if: always()\n        run: node .github/actions/setup-zig/setup-zig.mjs --prune-cache\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(unbounded), /terminal always step/)

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-workflow-policy-'))
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }))
  const actionDirectory = path.join(temporary, '.github', 'actions', 'setup-zig')
  fs.mkdirSync(actionDirectory, { recursive: true })
  for (const filename of ['action.yml', 'setup-zig.mjs']) {
    fs.copyFileSync(path.join('.github', 'actions', 'setup-zig', filename), path.join(actionDirectory, filename))
  }
  const actionManifest = path.join(actionDirectory, 'action.yml')
  fs.writeFileSync(actionManifest, fs.readFileSync(actionManifest, 'utf8').replace(
    actionPins['actions/cache'].sha,
    '0000000000000000000000000000000000000000',
  ))
  assert.throws(() => validateSetupZigAction(temporary), /exactly two immutable reviewed cache actions/)

  fs.copyFileSync(path.join('.github', 'actions', 'setup-zig', 'action.yml'), actionManifest)
  const actionImplementation = path.join(actionDirectory, 'setup-zig.mjs')
  fs.writeFileSync(actionImplementation, fs.readFileSync(actionImplementation, 'utf8').replace(
    "redirect: 'error'",
    "redirect: 'follow'",
  ))
  assert.throws(() => validateSetupZigAction(temporary), /missing integrity contract/)
})

test('native archives use one committed epoch and only tag releases enforce committed digests', () => {
  const sources = cloneSources()
  assert.deepEqual(validateNativeIntegrityWorkflowContract(sources), {
    buildEpochReads: 2,
    releaseArchiveGates: 1,
    releaseEpochReads: 1,
  })

  const missingBuildEpoch = cloneSources()
  missingBuildEpoch.set('build.yml', missingBuildEpoch.get('build.yml').replace(
    '          epoch="$(node scripts/validate-native-integrity.mjs --print-source-date-epoch --version "$version")"\n',
    '',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(missingBuildEpoch),
    /exactly two manifest-owned source date epochs/,
  )

  const mutableEpoch = cloneSources()
  mutableEpoch.set('release.yml', mutableEpoch.get('release.yml').replace(
    '          echo "SOURCE_DATE_EPOCH=$epoch" >> "$GITHUB_ENV"',
    '          echo "SOURCE_DATE_EPOCH=$(git show -s --format=%ct "$GITHUB_SHA")" >> "$GITHUB_ENV"',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(mutableEpoch),
    /manifest-owned source date epoch|mutable commit timestamp/,
  )

  const missingReleaseGate = cloneSources()
  missingReleaseGate.set('release.yml', missingReleaseGate.get('release.yml').replace(
    '      - name: Verify Committed Native Integrity',
    '      - name: Removed Committed Native Integrity',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(missingReleaseGate),
    /verify every tag archive against the committed native integrity manifest/,
  )

  const missingPrepackCheck = cloneSources()
  missingPrepackCheck.set('release.yml', missingPrepackCheck.get('release.yml').replace(
    'node scripts/validate-native-integrity.mjs --check',
    'node scripts/validate-native-integrity.mjs --removed-check',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(missingPrepackCheck),
    /native integrity command inventory|before packing npm/,
  )

  const developmentDigestGate = cloneSources()
  developmentDigestGate.set('build.yml', developmentDigestGate.get('build.yml').replace(
    '      - name: Generate Native Smoke Metadata',
    '      - name: Development digest comparison\n'
      + '        run: |\n'
      + '          node scripts/validate-native-integrity.mjs \\\n'
      + '            --archive "release-assets/$RELEASE_ARCHIVE"\n\n'
      + '      - name: Generate Native Smoke Metadata',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(developmentDigestGate),
    /must not compare unreleased development archives/,
  )

  const sameRunTrustData = cloneSources()
  sameRunTrustData.set('release.yml', sameRunTrustData.get('release.yml').replace(
    'node scripts/validate-native-integrity.mjs \\',
    'node scripts/validate-native-integrity.mjs --write \\',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(sameRunTrustData),
    /verify every tag archive|must never derive committed native integrity trust data/,
  )

  const missingCiGate = cloneSources()
  missingCiGate.set('build.yml', missingCiGate.get('build.yml').replace(
    'node --test scripts/validate-native-integrity.test.mjs',
    'node --test scripts/removed-native-integrity.test.mjs',
  ))
  assert.throws(
    () => validateNativeIntegrityWorkflowContract(missingCiGate),
    /test and check the native integrity policy exactly once/,
  )
})

test('mutable, malformed, unknown, and stale action references fail closed', () => {
  const mutable = cloneSources()
  mutable.set('build.yml', mutable.get('build.yml').replace(
    `@${actionPins['actions/checkout'].sha} # ${actionPins['actions/checkout'].version}`,
    '@v4',
  ))
  assert.throws(() => validateWorkflowSources(mutable), /full lowercase commit SHA/)

  const stale = cloneSources()
  stale.set('build.yml', stale.get('build.yml').replace(
    actionPins['actions/checkout'].sha,
    '0000000000000000000000000000000000000000',
  ))
  assert.throws(() => validateWorkflowSources(stale), /action actions\/checkout must use/)

  const unknown = cloneSources()
  unknown.set('build.yml', unknown.get('build.yml').replace(
    'actions/checkout',
    'unknown/checkout',
  ))
  assert.throws(() => validateWorkflowSources(unknown), /unreviewed action unknown\/checkout/)

  const anchored = cloneSources()
  anchored.set('build.yml', anchored.get('build.yml').replace(
    'uses: actions/checkout@',
    'uses: &checkout actions/checkout@',
  ))
  assert.throws(() => validateWorkflowSources(anchored), /must not use YAML anchors/)
})

test('workflow and job permission expansion fails closed', () => {
  const inherited = cloneSources()
  inherited.set('docs.yml', inherited.get('docs.yml').replace('permissions: {}', 'permissions:\n  contents: read'))
  assert.throws(() => validateWorkflowSources(inherited), /deny all workflow-level token permissions/)

  const expanded = cloneSources()
  expanded.set('release.yml', expanded.get('release.yml').replace(
    '    permissions:\n      attestations: write\n      contents: read\n      id-token: write',
    '    permissions:\n      attestations: write\n      contents: write\n      id-token: write',
  ))
  assert.throws(() => validateWorkflowSources(expanded), /job release permissions changed/)

  const packages = cloneSources()
  packages.set('release.yml', packages.get('release.yml').replace(
    '      id-token: write',
    '      id-token: write\n      packages: write',
  ))
  assert.throws(() => validateWorkflowSources(packages), /job release permissions changed/)

  const compilerOidc = cloneSources()
  compilerOidc.set('build.yml', compilerOidc.get('build.yml').replace(
    '    permissions:\n      contents: read\n    strategy:',
    '    permissions:\n      attestations: write\n      contents: read\n      id-token: write\n    strategy:',
  ))
  assert.throws(() => validateWorkflowSources(compilerOidc), /job build permissions changed/)
})

test('documentation deployment requires one successful same-repository main Build commit, complete audits, and the live container gate', () => {
  const development = cloneSources()
  development.set('docs.yml', development.get('docs.yml').replace(
    "github.event.workflow_run.head_branch == 'main'",
    "github.event.workflow_run.head_branch == 'development'",
  ))
  assert.throws(() => validateWorkflowSources(development), /reject untrusted workflow_run|exact successful same-repository main Build file and SHA/)

  const wrongWorkflowPath = cloneSources()
  wrongWorkflowPath.set('docs.yml', wrongWorkflowPath.get('docs.yml').replace(
    "github.event.workflow_run.path == '.github/workflows/build.yml'",
    "github.event.workflow_run.path == '.github/workflows/benchmarks.yml'",
  ))
  assert.throws(() => validateWorkflowSources(wrongWorkflowPath), /reject untrusted workflow_run|exact successful same-repository main Build file and SHA/)

  const missingWorkflowName = cloneSources()
  missingWorkflowName.set('docs.yml', missingWorkflowName.get('docs.yml').replace(
    "      github.event.workflow_run.name == 'Build' &&\n",
    '',
  ))
  assert.throws(() => validateWorkflowSources(missingWorkflowName), /reject untrusted workflow_run|exact successful same-repository main Build file and SHA/)

  const manual = cloneSources()
  manual.set('docs.yml', manual.get('docs.yml').replace(
    '  workflow_run:',
    '  workflow_dispatch:\n  workflow_run:',
  ))
  assert.throws(() => validateWorkflowSources(manual), /completed main Build workflow/)

  const wrongCommit = cloneSources()
  wrongCommit.set('docs.yml', wrongCommit.get('docs.yml').replace(
    "github.event.workflow_run.head_sha || github.sha",
    'github.sha',
  ))
  assert.throws(() => validateWorkflowSources(wrongCommit), /exact checked-out source SHA/)

  const credentialedCheckout = cloneSources()
  credentialedCheckout.set('docs.yml', credentialedCheckout.get('docs.yml').replace(
    '          persist-credentials: false',
    '          persist-credentials: true',
  ))
  assert.throws(() => validateWorkflowSources(credentialedCheckout), /must not persist repository credentials/)

  const dynamicCheckout = cloneSources()
  dynamicCheckout.set('docs.yml', dynamicCheckout.get('docs.yml').replace(
    '          persist-credentials: false\n',
    '          persist-credentials: false\n          ref: ${{ github.event.workflow_run.head_sha }}\n',
  ))
  assert.throws(
    () => validateWorkflowSources(dynamicCheckout),
    /without an untrusted dynamic ref/,
  )

  const missingRepositoryBoundary = cloneSources()
  missingRepositoryBoundary.set('docs.yml', missingRepositoryBoundary.get('docs.yml').replace(
    '      github.event.workflow_run.repository.full_name == github.repository &&\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(missingRepositoryBoundary), /reject untrusted workflow_run|exact successful same-repository main Build file and SHA/)

  const missingSourceIdentity = cloneSources()
  missingSourceIdentity.set('docs.yml', missingSourceIdentity.get('docs.yml').replace(
    '          test "$actual_source_sha" = "$EXPECTED_SOURCE_SHA"\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(missingSourceIdentity), /verify and export the exact checked-out source SHA/)

  const cancellableByFailure = cloneSources()
  cancellableByFailure.set('docs.yml', cancellableByFailure.get('docs.yml').replace(
    "  group: pages-${{ github.event_name == 'workflow_run' && github.event.workflow_run.conclusion == 'success' && 'deploy' || format('{0}-{1}', github.event_name, github.ref) }}",
    '  group: pages-${{ github.ref }}',
  ))
  assert.throws(() => validateWorkflowSources(cancellableByFailure), /prevent failed Build completions/)

  const missingDocsAudit = cloneSources()
  missingDocsAudit.set('docs.yml', missingDocsAudit.get('docs.yml').replace(
    'npm run audit:documentation',
    'npm run audit:production',
  ))
  assert.throws(() => validateWorkflowSources(missingDocsAudit), /complete documentation build graph/)

  const scopedDocsAudit = cloneSources()
  scopedDocsAudit.set('docs.yml', scopedDocsAudit.get('docs.yml').replace(
    '      - name: Audit complete documentation build graph\n        run: npm run audit:documentation\n',
    '      - name: Audit complete documentation build graph\n        run: npm run audit:documentation\n        working-directory: docs\n',
  ))
  assert.throws(() => validateWorkflowSources(scopedDocsAudit), /complete documentation build graph/)

  const missingBuildAudit = cloneSources()
  missingBuildAudit.set('build.yml', missingBuildAudit.get('build.yml').replace(
    ' && npm run audit:documentation && npm run audit:vscode',
    '',
  ))
  assert.throws(() => validateWorkflowSources(missingBuildAudit), /documentation, VS Code, and framework build graphs/)

  const containerStep = [
    '      - name: Build and smoke-test documentation container',
    '        run: node docs/scripts/smoke-docs-container.mjs',
    '',
  ].join('\n')
  const missingContainerSmoke = cloneSources()
  missingContainerSmoke.set('docs.yml', missingContainerSmoke.get('docs.yml').replace(containerStep, ''))
  assert.throws(() => validateWorkflowSources(missingContainerSmoke), /live-smoke Dockerfile\.docs/)

  const reorderedContainerSmoke = cloneSources()
  reorderedContainerSmoke.set('docs.yml', reorderedContainerSmoke.get('docs.yml')
    .replace(containerStep, '')
    .replace('      - name: Build documentation\n', `${containerStep}      - name: Build documentation\n`))
  assert.throws(() => validateWorkflowSources(reorderedContainerSmoke), /live-smoke Dockerfile\.docs/)

  const nonBlockingContainerSmoke = cloneSources()
  nonBlockingContainerSmoke.set('docs.yml', nonBlockingContainerSmoke.get('docs.yml').replace(
    '        run: node docs/scripts/smoke-docs-container.mjs',
    '        run: node docs/scripts/smoke-docs-container.mjs\n        continue-on-error: true',
  ))
  assert.throws(() => validateWorkflowSources(nonBlockingContainerSmoke), /live-smoke Dockerfile\.docs/)

  for (const input of documentationContainerCiPolicy.contextPaths) {
    const missingContextInput = cloneSources()
    missingContextInput.set('docs.yml', missingContextInput.get('docs.yml').replaceAll(
      `      - '${input}'\n`,
      '',
    ))
    assert.throws(
      () => validateWorkflowSources(missingContextInput),
      /exact documentation container context inputs/,
      input,
    )
  }
})

test('the unfiltered Build workflow owns the complete documentation test suite', () => {
  const sources = cloneSources()
  assert.deepEqual(validateDocumentationBuildCoverage(sources.get('build.yml')), {
    install: documentationBuildCiPolicy.installCommand,
    test: documentationBuildCiPolicy.testCommand,
    triggers: ['push', 'pull_request', 'workflow_dispatch'],
  })

  const missingDocsTest = cloneSources()
  missingDocsTest.set('build.yml', missingDocsTest.get('build.yml').replace(
    '      - name: Test documentation site\n        run: npm --prefix docs run test:run\n\n',
    '',
  ))
  assert.throws(
    () => validateWorkflowSources(missingDocsTest),
    /install locked documentation dependencies, run the complete docs suite, and live-smoke the development container exactly once/,
  )

  const duplicateDocsTest = cloneSources()
  duplicateDocsTest.set('build.yml', duplicateDocsTest.get('build.yml').replace(
    '      - name: Test documentation site\n        run: npm --prefix docs run test:run',
    '      - name: Test documentation site\n        run: npm --prefix docs run test:run && npm --prefix docs run test:run',
  ))
  assert.throws(
    () => validateWorkflowSources(duplicateDocsTest),
    /install locked documentation dependencies, run the complete docs suite, and live-smoke the development container exactly once/,
  )

  const nonBlockingDocsTest = cloneSources()
  nonBlockingDocsTest.set('build.yml', nonBlockingDocsTest.get('build.yml').replace(
    '      - name: Test documentation site\n        run: npm --prefix docs run test:run',
    '      - name: Test documentation site\n        continue-on-error: true\n        run: npm --prefix docs run test:run',
  ))
  assert.throws(
    () => validateWorkflowSources(nonBlockingDocsTest),
    /install locked documentation dependencies, run the complete docs suite, and live-smoke the development container exactly once/,
  )

  const missingDevelopmentContainer = cloneSources()
  missingDevelopmentContainer.set('build.yml', missingDevelopmentContainer.get('build.yml').replace(
    `\n\n      - name: Build and smoke-test development container\n        run: ${developmentContainerCiPolicy.command}`,
    '',
  ))
  assert.throws(
    () => validateWorkflowSources(missingDevelopmentContainer),
    /live-smoke the development container exactly once/,
  )

  const nonBlockingDevelopmentContainer = cloneSources()
  nonBlockingDevelopmentContainer.set('build.yml', nonBlockingDevelopmentContainer.get('build.yml').replace(
    `        run: ${developmentContainerCiPolicy.command}`,
    `        run: ${developmentContainerCiPolicy.command}\n        continue-on-error: true`,
  ))
  assert.throws(
    () => validateWorkflowSources(nonBlockingDevelopmentContainer),
    /live-smoke the development container exactly once/,
  )

  const pathFilteredBuild = cloneSources()
  pathFilteredBuild.set('build.yml', pathFilteredBuild.get('build.yml').replace(
    '  pull_request:\n    branches: [main, development]',
    '  pull_request:\n    branches: [main, development]\n    paths: [src/**]',
  ))
  assert.throws(
    () => validateWorkflowSources(pathFilteredBuild),
    /every main\/development push and pull request without path filters/,
  )
})

test('release publication requires one exact-SHA successful same-repository main Build run first', () => {
  const sources = cloneSources()
  assert.deepEqual(validateReleaseBuildEvidenceWorkflowContract(sources.get('release.yml')), {
    branch: 'main',
    codeScanningCategories: 3,
    event: 'push',
    permissions: ['actions: read', 'security-events: read'],
    workflow: 'Build',
  })

  for (const [current, replacement] of [
    ['timeout 30s npm whoami --registry=https://registry.npmjs.org/ >/dev/null 2>&1', 'timeout 30s npm whoami >/dev/null 2>&1'],
    ['timeout 30s npm view zigcss versions --json --registry=https://registry.npmjs.org/', 'timeout 30s npm view zigcss versions --json'],
    ['          for attempt in 1 2 3 4; do', '          for attempt in 1 2 3; do'],
    ['            sleep 5', '            sleep 30'],
    ['>/dev/null 2>&1', ''],
  ]) {
    const changed = sources.get('release.yml').replace(current, replacement)
    assert.notEqual(changed, sources.get('release.yml'), current)
    assert.throws(
      () => validateReleaseBuildEvidenceWorkflowContract(changed),
      /private-output credential proof and exact bounded registry retries/,
    )
  }

  const admissionStep = [
    '      - name: Verify release candidate admission',
    '        shell: bash',
    '        run: |',
    '          candidate_commit="$(git rev-parse "${GITHUB_SHA}^{commit}")"',
    '          origin_main_commit="$(',
    '            git ls-remote --exit-code --refs origin refs/heads/main |',
    '              cut -f1',
    '          )"',
    '          node scripts/validate-release-admission.mjs --check \\',
    '            --release-tag "$GITHUB_REF_NAME" \\',
    '            --candidate-commit "$candidate_commit" \\',
    '            --origin-main-commit "$origin_main_commit"',
    '',
  ].join('\n')
  assert.equal(sources.get('release.yml').includes(admissionStep), true)

  const missingAdmission = cloneSources()
  missingAdmission.set(
    'release.yml',
    missingAdmission.get('release.yml').replace(admissionStep, ''),
  )
  assert.throws(
    () => validateWorkflowSources(missingAdmission),
    /one exact fail-closed candidate admission gate/,
  )

  const stableOnlyAdmission = cloneSources()
  stableOnlyAdmission.set('release.yml', stableOnlyAdmission.get('release.yml').replace(
    'node scripts/validate-release-admission.mjs --check \\',
    'npm run check:stable-release -- \\',
  ))
  assert.throws(
    () => validateWorkflowSources(stableOnlyAdmission),
    /one exact fail-closed candidate admission gate/,
  )

  const admissionAfterAuthority = cloneSources()
  admissionAfterAuthority.set('release.yml', admissionAfterAuthority.get('release.yml')
    .replace(admissionStep, '')
    .replace('      - name: Pack exact npm package\n', `${admissionStep}      - name: Pack exact npm package\n`))
  assert.throws(
    () => validateWorkflowSources(admissionAfterAuthority),
    /must run before every publication authority/,
  )

  const missing = cloneSources()
  const step = [
    '      - name: Verify successful Build evidence for release commit',
    '        shell: bash',
    '        env:',
    '          GITHUB_TOKEN: ${{ github.token }}',
    '        run: |',
    '          candidate_commit="$(git rev-parse "${GITHUB_SHA}^{commit}")"',
    '          node scripts/verify-build-workflow-run.mjs \\',
    '            --repository "$GITHUB_REPOSITORY" \\',
    '            --commit "$candidate_commit"',
    '',
  ].join('\n')
  assert.equal(missing.get('release.yml').includes(step), true)
  missing.set('release.yml', missing.get('release.yml').replace(step, ''))
  assert.throws(
    () => validateWorkflowSources(missing),
    /must verify one exact-SHA successful Build run/,
  )

  const unpeeledTag = cloneSources()
  unpeeledTag.set('release.yml', unpeeledTag.get('release.yml').replace(
    '--commit "$candidate_commit"',
    '--commit "$GITHUB_SHA"',
  ))
  assert.throws(
    () => validateWorkflowSources(unpeeledTag),
    /must verify one exact-SHA successful Build run/,
  )

  const personalToken = cloneSources()
  personalToken.set('release.yml', personalToken.get('release.yml').replace(
    'GITHUB_TOKEN: ${{ github.token }}',
    'GITHUB_TOKEN: ${{ secrets.RELEASE_TOKEN }}',
  ))
  assert.throws(
    () => validateWorkflowSources(personalToken),
    /must verify one exact-SHA successful Build run/,
  )

  const afterAuthority = cloneSources()
  afterAuthority.set('release.yml', afterAuthority.get('release.yml')
    .replace(step, '')
    .replace('      - name: Pack exact npm package\n', `${step}      - name: Pack exact npm package\n`))
  assert.throws(
    () => validateWorkflowSources(afterAuthority),
    /must run before every publication authority/,
  )

  const noActionsRead = cloneSources()
  noActionsRead.set('release.yml', noActionsRead.get('release.yml').replace(
    '    permissions:\n      actions: read\n      contents: read\n      security-events: read',
    '    permissions:\n      contents: read\n      security-events: read',
  ))
  assert.throws(
    () => validateWorkflowSources(noActionsRead),
    /job npm-preflight permissions changed/,
  )

  const noSecurityEventsRead = cloneSources()
  noSecurityEventsRead.set('release.yml', noSecurityEventsRead.get('release.yml').replace(
    '    permissions:\n      actions: read\n      contents: read\n      security-events: read',
    '    permissions:\n      actions: read\n      contents: read',
  ))
  assert.throws(
    () => validateWorkflowSources(noSecurityEventsRead),
    /job npm-preflight permissions changed/,
  )
})

test('GitHub release publication is draft-first, exact-asset verified, and immutable', () => {
  const source = cloneSources().get('release.yml')
  assert.deepEqual(validateImmutableReleaseWorkflowContract(source), {
    assets: 25,
    approvalEnvironment: 'immutable-release',
    draftFirst: true,
    immutableReadback: true,
    lightweightTagBinding: true,
    resumable: true,
    releaseAttestation: true,
    attestedAssets: 25,
    stableLatestReadback: true,
    retryAttempts: 6,
  })

  for (const [current, replacement] of [
    ['    environment:\n      name: immutable-release', '    environment:\n      name: release'],
    ['    environment:\n      name: immutable-release', '    environment:\n      name: immutable-release\n    env:\n      ADMIN_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}'],
    ['          draft: true', '          draft: false'],
    ['          overwrite_files: true', '          overwrite_files: false'],
    ['          fail_on_unmatched_files: true', '          fail_on_unmatched_files: false'],
    ['          target_commitish: ${{ github.sha }}', '          target_commitish: main'],
    ['              -F draft=false \\', '              -F draft=true \\'],
    ['--phase published', '--phase draft'],
    ['--phase tag', '--phase draft'],
    ['--phase attestation', '--phase latest'],
    ["        if: needs.npm-preflight.outputs.github-make-latest == 'true'", "        if: needs.npm-preflight.outputs.github-make-latest == 'false'"],
    ['              "repos/$GITHUB_REPOSITORY/releases/latest" > "$release_latest" && \\', '              "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" > "$release_latest" && \\'],
    ["        if: steps.github-release-state.outputs.release-mode != 'published'", "        if: steps.github-release-state.outputs.release-mode == 'create'"],
    ['          timeout 60s gh api graphql \\', '          gh api graphql \\'],
    ['timeout 30s gh release verify', 'gh release verify'],
    ['          for attempt in 1 2 3 4 5 6; do', '          for attempt in 1 2 3; do'],
  ]) {
    const changed = source.replace(current, replacement)
    assert.notEqual(changed, source, current)
    assert.throws(
      () => validateImmutableReleaseWorkflowContract(changed),
      /draft|release|immutable|bounded|integrity|transition|point of no return/i,
    )
  }

  const reordered = source
    .replace('      - name: Verify immutable release readback', '      - name: TEMP immutable release readback')
    .replace('      - name: Verify immutable release attestation', '      - name: Verify immutable release readback')
    .replace('      - name: TEMP immutable release readback', '      - name: Verify immutable release attestation')
  assert.throws(
    () => validateImmutableReleaseWorkflowContract(reordered),
    /missing or reorders/,
  )
})

test('release ends with one bounded credential-free anonymous public delivery smoke', () => {
  const source = cloneSources().get('release.yml')
  assert.deepEqual(validatePublicDeliveryWorkflowContract(source), {
    job: publicDeliveryCiPolicy.job,
    needs: publicDeliveryCiPolicy.needs,
    nodeVersion: publicDeliveryCiPolicy.nodeVersion,
    registry: publicDeliveryCiPolicy.registry,
    runner: publicDeliveryCiPolicy.runner,
    timeoutMinutes: publicDeliveryCiPolicy.timeoutMinutes,
  })

  const marker = '\n  anonymous-public-delivery:'
  const start = source.indexOf(marker)
  assert.notEqual(start, -1)
  const withoutDelivery = source.slice(0, start)
  assert.throws(
    () => validatePublicDeliveryWorkflowContract(withoutDelivery),
    /anonymous public delivery job is unavailable/,
  )

  const mutateDelivery = mutation => source.slice(0, start) + mutation(source.slice(start))
  for (const [label, mutated, expected] of [
    [
      'dependency',
      mutateDelivery(job => job.replace('needs: publish-npm', 'needs: create-release')),
      /exact bounded credential-free terminal/,
    ],
    [
      'checkout credentials',
      mutateDelivery(job => job.replace('persist-credentials: false', 'persist-credentials: true')),
      /exact bounded credential-free terminal/,
    ],
    [
      'unpeeled tag',
      mutateDelivery(job => job.replace('"${GITHUB_REF_NAME#v}"', '"$GITHUB_REF_NAME"')),
      /exact bounded credential-free terminal/,
    ],
    [
      'npm token',
      mutateDelivery(job => job.replace(
        '        run: node scripts/smoke-public-delivery.mjs --version "${GITHUB_REF_NAME#v}"',
        '        run: node scripts/smoke-public-delivery.mjs --version "${GITHUB_REF_NAME#v}"\n        env:\n          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}',
      )),
      /must not receive npm, GitHub, OIDC, or registry credentials/,
    ],
    [
      'registry credential setup',
      mutateDelivery(job => job.replace(
        "          node-version: '24.20.0'",
        "          node-version: '24.20.0'\n          registry-url: 'https://registry.npmjs.org'",
      )),
      /must not receive npm, GitHub, OIDC, or registry credentials/,
    ],
    [
      'OIDC permission',
      mutateDelivery(job => job.replace(
        '      contents: read',
        '      contents: read\n      id-token: write',
      )),
      /must not receive npm, GitHub, OIDC, or registry credentials/,
    ],
    [
      'non-blocking smoke',
      mutateDelivery(job => job.replace(
        '      - name: Smoke anonymous canonical npm delivery',
        '      - name: Smoke anonymous canonical npm delivery\n        continue-on-error: true',
      )),
      /exact bounded credential-free terminal/,
    ],
  ]) {
    assert.notEqual(mutated, source, label)
    assert.throws(() => validatePublicDeliveryWorkflowContract(mutated), expected, label)
  }

  const publishStart = withoutDelivery.indexOf('\n  publish-npm:')
  assert.notEqual(publishStart, -1)
  const deliveryBlock = source.slice(start)
  const reordered = withoutDelivery.slice(0, publishStart)
    + deliveryBlock
    + '\n'
    + withoutDelivery.slice(publishStart)
  assert.throws(
    () => validatePublicDeliveryWorkflowContract(reordered),
    /must remain the final job/,
  )
})

test('documentation and release terminal jobs own finite hard timeouts', () => {
  const sources = cloneSources()
  assert.deepEqual(validateTerminalWorkflowTimeouts(sources), terminalWorkflowTimeoutPolicy)

  for (const [filename, jobs] of Object.entries(terminalWorkflowTimeoutPolicy)) {
    const workflow = sources.get(filename)
    for (const [job, timeoutMinutes] of Object.entries(jobs)) {
      const start = workflow.indexOf(`  ${job}:\n`)
      const laterJobs = Object.keys(jobs)
        .map(name => workflow.indexOf(`\n  ${name}:\n`, start + 1))
        .filter(position => position > start)
      const end = laterJobs.length === 0 ? workflow.length : Math.min(...laterJobs)
      const jobSource = workflow.slice(start, end)
      const timeout = `    timeout-minutes: ${timeoutMinutes}\n`
      assert.notEqual(start, -1)
      assert.equal(jobSource.split(timeout).length, 2)

      for (const replacement of ['', `    timeout-minutes: ${timeoutMinutes + 1}\n`, timeout + timeout]) {
        const mutated = cloneSources()
        mutated.set(filename, workflow.slice(0, start) + jobSource.replace(timeout, replacement) + workflow.slice(end))
        assert.throws(
          () => validateWorkflowSources(mutated),
          new RegExp(`${filename.replace('.', '\\.')} job ${job}.*hard timeout`),
        )
      }
    }
  }
})

test('new workflows, jobs, and action placements require an explicit policy update', () => {
  const workflow = cloneSources()
  workflow.set('unreviewed.yml', 'name: Unreviewed\n')
  assert.throws(() => validateWorkflowSources(workflow), /workflow inventory changed/)

  const job = cloneSources()
  job.set('build.yml', `${job.get('build.yml')}\n  unexpected:\n    permissions:\n      contents: read\n`)
  assert.throws(() => validateWorkflowSources(job), /job inventory changed/)

  const placement = cloneSources()
  placement.set('docs.yml', placement.get('docs.yml').replace(
    'actions/upload-pages-artifact',
    'actions/upload-artifact',
  ).replace(
    actionPins['actions/upload-pages-artifact'].sha,
    actionPins['actions/upload-artifact'].sha,
  ).replace(
    actionPins['actions/upload-pages-artifact'].version,
    actionPins['actions/upload-artifact'].version,
  ))
  assert.throws(() => validateWorkflowSources(placement), /action inventory changed/)
})

test('the workflow security gate runs before dependency installation', () => {
  const sources = cloneSources()
  sources.set('build.yml', sources.get('build.yml').replace('- name: Verify workflow security policy', '- name: Removed gate'))
  assert.throws(() => validateWorkflowSources(sources), /before npm installation/)
})

test('the build workflow preserves one complete aggregate suite within a bounded queue', () => {
  const sources = cloneSources()
  assert.deepEqual(validateWorkflowSources(sources), { workflows: 4, jobs: 12, actions: 47 })

  const unconstrained = cloneSources()
  unconstrained.set('build.yml', unconstrained.get('build.yml').replace(
    'concurrency:\n  group: build-${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: false\n\n',
    '',
  ))
  assert.throws(() => validateWorkflowSources(unconstrained), /bounded non-cancelling concurrency/)

  const duplicated = cloneSources()
  duplicated.set('build.yml', duplicated.get('build.yml').replace(
    '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
    '      - name: Verify native stylesheet frontend foundations\n        run: zig build test-native-preprocessor --summary all\n\n      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ))
  assert.throws(() => validateWorkflowSources(duplicated), /must not run the native suite twice/)

  const unoptimizedMatrix = cloneSources()
  unoptimizedMatrix.set('build.yml', unoptimizedMatrix.get('build.yml').replace(
    '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe',
    '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ))
  assert.throws(() => validateWorkflowSources(unoptimizedMatrix), /must not run the complete Zig graph in Debug/)
})

test('required build jobs declare finite hard timeout budgets', () => {
  const workflow = cloneSources().get('build.yml')
  assert.deepEqual(validateBuildThroughput(workflow), {
    artifactTargets: 5,
    hardTimeoutMinutes: {
      build: 240,
      'native-provenance-evidence': 30,
      'native-package-evidence': 60,
      test: 240,
    },
    interventionMinutes: {
      build: 180,
      'native-provenance-evidence': 22.5,
      'native-package-evidence': 45,
      test: 180,
    },
    releaseConsumerSteps: [
      'npm run test:release-smoke',
      'npm run test:release-consumers',
      'npm run test:release-container',
      'npm run test:release-homebrew',
    ],
    semanticGraphs: {
      build: 'ReleaseSafe',
      test: 'Debug',
    },
  })

  const jobs = Object.keys(buildThroughputPolicy.jobs)
  for (const [index, job] of jobs.entries()) {
    const nextJob = jobs[index + 1]
    const timeoutMinutes = buildThroughputPolicy.jobs[job].timeoutMinutes
    const start = workflow.indexOf(`  ${job}:\n`)
    const end = nextJob === undefined ? workflow.length : workflow.indexOf(`\n  ${nextJob}:\n`, start)
    assert.notEqual(start, -1)
    assert.notEqual(end, -1)
    assert.match(
      workflow.slice(start, end),
      new RegExp(`^    timeout-minutes: ${timeoutMinutes}$`, 'm'),
      `${job} must declare its ${timeoutMinutes}-minute hard timeout`,
    )

    const jobSource = workflow.slice(start, end)
    const timeout = `    timeout-minutes: ${timeoutMinutes}\n`
    const missing = cloneSources()
    missing.set('build.yml', workflow.slice(0, start) + jobSource.replace(timeout, '') + workflow.slice(end))
    assert.throws(() => validateWorkflowSources(missing), new RegExp(`job ${job}.*hard timeout`))

    const malformed = cloneSources()
    malformed.set(
      'build.yml',
      workflow.slice(0, start)
        + jobSource.replace(timeout, `    timeout-minutes: ${timeoutMinutes}.5\n`)
        + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(malformed), new RegExp(`job ${job}.*hard timeout`))

    const drifted = cloneSources()
    drifted.set(
      'build.yml',
      workflow.slice(0, start)
        + jobSource.replace(timeout, `    timeout-minutes: ${timeoutMinutes + 1}\n`)
        + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(drifted), new RegExp(`job ${job}.*hard timeout`))

    const duplicated = cloneSources()
    duplicated.set(
      'build.yml',
      workflow.slice(0, start) + jobSource.replace(timeout, timeout + timeout) + workflow.slice(end),
    )
    assert.throws(() => validateWorkflowSources(duplicated), new RegExp(`job ${job}.*hard timeout`))
  }

  const lowerTargets = cloneSources()
  lowerTargets.set('build.yml', workflow.replace('            target: x86_64-linux\n', ''))
  assert.throws(() => validateWorkflowSources(lowerTargets), /exactly 5 unique targets/)

  const duplicateTarget = cloneSources()
  duplicateTarget.set('build.yml', workflow.replace('            target: aarch64-linux', '            target: x86_64-linux'))
  assert.throws(() => validateWorkflowSources(duplicateTarget), /exactly 5 unique targets/)
})

test('throughput owns the exact finite five-target artifact matrix', () => {
  const workflow = cloneSources().get('build.yml')
  const substitutions = [
    ['ubuntu-latest', 'ubuntu-24.04'],
    ['            arch: x86_64\n            target: x86_64-linux', '            arch: aarch64\n            target: x86_64-linux'],
    ['x86_64-linux', 'x86_64-freebsd'],
    ['archive-extension: tar.gz', 'archive-extension: tgz'],
    ['zig-version: 0.15.2', 'zig-version: 0.15.3'],
    ['binary-name: zigcss\n', 'binary-name: zigcss.bin\n'],
  ]

  for (const [current, replacement] of substitutions) {
    assert.notEqual(workflow.replace(current, replacement), workflow)
    assert.throws(
      () => validateBuildThroughput(workflow.replace(current, replacement)),
      /exact five-target artifact matrix/,
    )
  }
})

test('the artifact matrix uses the optimized complete suite while the test job owns Debug', () => {
  const buildWorkflow = cloneSources().get('build.yml')
  const artifactJob = buildWorkflow.slice(
    buildWorkflow.indexOf('  build:'),
    buildWorkflow.indexOf('  native-provenance-evidence:'),
  )
  const testJob = buildWorkflow.slice(buildWorkflow.indexOf('  test:'))
  const debugArtifactSuite = '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug'
  const optimizedArtifactSuite = '      - name: Run Native Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe'
  const debugAggregate = '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode Debug'
  const optimizedAggregate = '      - name: Run Tests\n        run: node scripts/run-zig-test-suite.mjs --mode ReleaseSafe'
  assert.equal(artifactJob.includes(debugArtifactSuite), false)
  assert.equal(artifactJob.split(optimizedArtifactSuite).length, 2)
  assert.equal(testJob.split(debugAggregate).length, 2)
  assert.equal(testJob.includes(optimizedAggregate), false)
})

test('release consumer gates are finite, individually attributable, and run once', () => {
  const buildWorkflow = cloneSources().get('build.yml')
  assert.deepEqual(validateBuildThroughput(buildWorkflow).releaseConsumerSteps, [
    'npm run test:release-smoke',
    'npm run test:release-consumers',
    'npm run test:release-container',
    'npm run test:release-homebrew',
  ])

  const missing = buildWorkflow.replace(
    '      - name: Test release container\n        run: npm run test:release-container\n\n',
    '',
  )
  assert.notEqual(missing, buildWorkflow)
  assert.throws(() => validateBuildThroughput(missing), /release consumer.*attributable/i)

  const duplicated = buildWorkflow.replace(
    '      - name: Test release Homebrew\n        run: npm run test:release-homebrew',
    '      - name: Test release Homebrew\n        run: npm run test:release-homebrew\n\n'
      + '      - name: Test release Homebrew duplicate\n        run: npm run test:release-homebrew',
  )
  assert.notEqual(duplicated, buildWorkflow)
  assert.throws(() => validateBuildThroughput(duplicated), /release consumer.*attributable/i)

  const merged = buildWorkflow.replace(
    '      - name: Test release smoke\n        run: npm run test:release-smoke\n\n'
      + '      - name: Test release consumers\n        run: npm run test:release-consumers',
    '      - name: Test release consumer paths\n'
      + '        run: npm run test:release-smoke && npm run test:release-consumers',
  )
  assert.notEqual(merged, buildWorkflow)
  assert.throws(() => validateBuildThroughput(merged), /release consumer.*attributable/i)
})

test('the complete Zig test graph owns every native frontend runner', () => {
  const source = fs.readFileSync(new URL('../build.zig', import.meta.url), 'utf8')
  assert.deepEqual(validateBuildTestGraph(source), { nativeRunners: 19 })
  const weakened = source.replace(
    '    test_step.dependOn(&run_native_sass_evaluator_tests.step);',
    '    // removed native Sass evaluator coverage',
  )
  assert.throws(() => validateBuildTestGraph(weakened), /missing native runner run_native_sass_evaluator_tests/)
  const missingConformance = source.replace(
    '    test_step.dependOn(&run_native_sass_conformance_tests.step);',
    '    // removed native Sass conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingConformance),
    /missing native runner run_native_sass_conformance_tests/,
  )
  const missingLessConformance = source.replace(
    '    test_step.dependOn(&run_native_less_conformance_tests.step);',
    '    // removed native Less conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingLessConformance),
    /missing native runner run_native_less_conformance_tests/,
  )
  const missingStylusParser = source.replace(
    '    test_step.dependOn(&run_native_stylus_parser_tests.step);',
    '    // removed native Stylus parser coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusParser),
    /missing native runner run_native_stylus_parser_tests/,
  )
  const missingStylusEvaluator = source.replace(
    '    test_step.dependOn(&run_native_stylus_evaluator_tests.step);',
    '    // removed native Stylus evaluator coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusEvaluator),
    /missing native runner run_native_stylus_evaluator_tests/,
  )
  const missingStylusConformance = source.replace(
    '    test_step.dependOn(&run_native_stylus_conformance_tests.step);',
    '    // removed native Stylus conformance coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingStylusConformance),
    /missing native runner run_native_stylus_conformance_tests/,
  )
  const missingNativeCli = source.replace(
    '    test_step.dependOn(&run_native_cli_tests.step);',
    '    // removed native binary CLI coverage',
  )
  assert.throws(
    () => validateBuildTestGraph(missingNativeCli),
    /missing native runner run_native_cli_tests/,
  )
})
