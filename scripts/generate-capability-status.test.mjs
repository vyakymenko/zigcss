import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  endMarker,
  expectedTargets,
  generatedTargets,
  loadMetadata,
  renderTable,
  repositoryRoot,
  replaceGeneratedTable,
  startMarker,
  validateMetadata,
} from './generate-capability-status.mjs'

test('capability metadata is closed, unique, and anchored to executable evidence', () => {
  const metadata = validateMetadata(loadMetadata())

  assert.equal(metadata.capabilities.length, 30)
  assert.equal(Object.keys(metadata.gates).length, 36)
  assert.deepEqual(metadata.statusKinds, ['experimental', 'verified', 'unavailable', 'disabled'])
  assert.equal(new Set(metadata.capabilities.map(capability => capability.id)).size, 30)
  assert.ok(metadata.capabilities.every(capability => capability.evidence.length > 0))
})

test('metadata validation fails closed on duplicate rows and unknown evidence', () => {
  const duplicate = structuredClone(loadMetadata())
  duplicate.capabilities.push(structuredClone(duplicate.capabilities[0]))
  assert.throws(() => validateMetadata(duplicate), /duplicate capability id/)

  const unknown = structuredClone(loadMetadata())
  unknown.capabilities[0].evidence = ['invented-gate']
  assert.throws(() => validateMetadata(unknown), /unknown gate/)

  const inventedStep = structuredClone(loadMetadata())
  inventedStep.gates['public-api'].command = 'zig build invented --summary all'
  assert.throws(() => validateMetadata(inventedStep), /no Zig build step/)

  const malformedMarkup = structuredClone(loadMetadata())
  malformedMarkup.capabilities[0].behavior = 'An `unterminated code span.'
  assert.throws(() => validateMetadata(malformedMarkup), /invalid inline code markup/)
})

test('package-manager evidence anchors bounded Corepack, exact PnP, and recovery boundaries', () => {
  const metadata = validateMetadata(loadMetadata())
  const gate = metadata.gates['package-managers']
  const managerAnchor = gate.anchors.find(anchor => anchor.path === 'scripts/verify-package-managers.test.mjs')
  const packageAnchor = gate.anchors.find(anchor => anchor.path === 'package.json')

  assert.notEqual(managerAnchor, undefined)
  assert.notEqual(packageAnchor, undefined)
  for (const needle of [
    "const toolchainRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-toolchain-'))",
    'const maximumToolchainBytes = 256 * 1024 * 1024',
    'const maximumToolchainEntries = 10_000',
    'COREPACK_HOME: corepackHome',
    "COREPACK_ENABLE_NETWORK: '0'",
    "COREPACK_ENABLE_NETWORK: '1'",
    'function inspectBoundedToolchainRoot()',
    'Corepack exact toolchain state is bounded, confined, and reused offline',
    "id: 'yarn-modern-pnp'",
    'assert.equal(manifest.preferUnplugged, true)',
    'Yarn must unpack zigcss into its project-local writable PnP area',
    'default Yarn PnP must not create node_modules',
    "assert.equal(pnpStat.isFile(), true, 'default Yarn PnP must create .pnp.cjs')",
    '/^\\.yarn[/\\\\]unplugged[/\\\\][^/\\\\]+[/\\\\]node_modules[/\\\\]zigcss[/\\\\]package\\.json$/',
    'PnP CommonJS export resolution',
    'PnP ESM export resolution',
    'PnP TypeScript 7 no-paths package resolution boundary',
    'error TS2307: Cannot find module',
    'PnP strict TypeScript ${mode} declaration bytes',
    'assert.equal(missing.status, 1)',
    'assert.equal(missing.stderr, missingBinaryStderr)',
    "const recovered = successfulManagerCommand(manager, ['zigcss-install'], {",
    'trustLocalFixtureInInstalledCopy(installedRoot, preloadedRelease)',
    'local recovery trust must not mutate the exact packed package archive',
    'PnP recovery must not create node_modules',
    'fs.rmSync(toolchainRoot, { recursive: true, force: true })',
  ]) assert.ok(managerAnchor.contains.includes(needle), needle)
  assert.ok(packageAnchor.contains.includes('"preferUnplugged": true'))

  const nodeApi = metadata.capabilities.find(capability => capability.id === 'node-api')
  for (const needle of [
    "Yarn's loader for CommonJS and ESM export resolution",
    'exact import/require declaration bytes',
    'condition-specific strict compile',
    'exact unpatched TypeScript 7.0.2 without a Yarn SDK or patch',
    '`TS2307` for no-paths PnP package resolution',
    'native TypeScript PnP resolution is not claimed',
    'confined Yarn and Corepack state',
    "[Yarn's official SDK guidance](https://yarnpkg.com/getting-started/editor-sdks)",
    'controlled release-independent local-fixture recovery',
  ]) assert.match(nodeApi.behavior, new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
})

test('Nix flake capability stays repository-local and bounded to configured evidence', () => {
  const metadata = validateMetadata(loadMetadata())
  const gate = metadata.gates['nix-flake']
  const workflowAnchor = gate.anchors.find(anchor => anchor.path === '.github/workflows/build.yml')
  const capability = metadata.capabilities.find(item => item.id === 'nix-flake')

  assert.equal(gate.command, 'npm run test:nix-flake')
  assert.notEqual(workflowAnchor, undefined)
  for (const needle of [
    'cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31',
    'install_url: https://releases.nixos.org/nix/nix-2.35.2/install',
    'enable_kvm: false',
    'set_as_trusted_user: false',
    'sandbox = true',
    '--no-update-lock-file',
    '--no-write-lock-file',
    '--no-use-registries',
  ]) assert.ok(workflowAnchor.contains.includes(needle), needle)

  assert.equal(capability.statusKind, 'experimental')
  for (const system of ['x86_64-linux', 'aarch64-linux', 'x86_64-darwin', 'aarch64-darwin']) {
    assert.match(capability.behavior, new RegExp(system))
  }
  for (const boundary of [
    'configured',
    'require network access',
    'installer script itself is not content-addressed',
    'runner images',
    'experimental flake CLI',
    'repository-local source-build evidence only',
    'no nixpkgs or registry publication',
    'binary cache',
    'offline install',
    'Windows output',
  ]) assert.match(capability.behavior, new RegExp(boundary))
})

test('evidence anchors cannot escape through a symlink', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-capability-root-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-capability-outside-'))
  try {
    fs.mkdirSync(path.join(root, 'docs'))
    fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts: { evidence: 'true' } }))
    fs.writeFileSync(path.join(root, 'docs', 'package.json'), JSON.stringify({ scripts: { test: 'true' } }))
    fs.writeFileSync(path.join(outside, 'evidence.txt'), 'verified')
    fs.symlinkSync(outside, path.join(root, 'evidence-link'), process.platform === 'win32' ? 'junction' : 'dir')

    const metadata = {
      schemaVersion: 1,
      statusKinds: ['experimental', 'verified', 'unavailable', 'disabled'],
      gates: {
        evidence: {
          command: 'npm run evidence',
          anchors: [{ path: 'evidence-link/evidence.txt', contains: ['verified'] }],
        },
      },
      capabilities: [{
        id: 'example',
        surface: 'Example',
        status: 'Verified',
        statusKind: 'verified',
        behavior: 'Example behavior.',
        evidence: ['evidence'],
      }],
    }

    assert.throws(() => validateMetadata(metadata, root), /anchor escapes the repository/)

    fs.rmSync(path.join(root, 'evidence-link'), { recursive: true })
    const evidence = path.join(root, 'evidence.txt')
    const evidenceLink = path.join(root, 'evidence-link.txt')
    fs.writeFileSync(evidence, 'verified')
    metadata.gates.evidence.anchors[0].path = 'evidence-link.txt'
    if (process.platform !== 'win32') {
      fs.symlinkSync(evidence, evidenceLink)
      assert.throws(() => validateMetadata(metadata, root), /regular non-symlink file/)
      fs.rmSync(evidenceLink)
    }
    fs.writeFileSync(evidenceLink, Buffer.alloc((2 * 1024 * 1024) + 1))
    assert.throws(() => validateMetadata(metadata, root), /must contain 1 through 2097152 bytes/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  }
})

test('status guide contains the exact generated table', () => {
  const metadata = validateMetadata(loadMetadata())
  const table = renderTable(metadata)
  const targets = expectedTargets(metadata)

  assert.equal(targets.length, 1)
  for (const { target, content } of targets) {
    assert.equal(content, fs.readFileSync(target, 'utf8'), path.relative(repositoryRoot, target))
    assert.equal(content.split(startMarker).length, 2)
    assert.equal(content.split(endMarker).length, 2)
    assert.ok(content.includes(table))
  }

  assert.doesNotMatch(
    fs.readFileSync(path.join(repositoryRoot, 'README.md'), 'utf8'),
    /<!-- capability-status:(?:start|end) -->/,
  )
})

test('generator check is deterministic and the site consumes metadata directly', () => {
  const result = spawnSync(process.execPath, ['scripts/generate-capability-status.mjs', '--check'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /30 rows, 36 executable evidence gates, 1 Markdown table/)

  const features = fs.readFileSync(path.join(repositoryRoot, 'docs/src/app/components/Features.tsx'), 'utf8')
  assert.match(features, /data\/capabilities\.json/)
  assert.match(features, /capabilities\.map/)
  assert.doesNotMatch(features, /const capabilities = \[/)
})

test('generated replacement rejects missing or duplicate marker authority', () => {
  assert.throws(() => replaceGeneratedTable('no markers', 'table'), /missing ordered markers/)
  assert.throws(
    () => replaceGeneratedTable(`${startMarker}\n${startMarker}\n${endMarker}`, 'table'),
    /duplicate markers/,
  )
})

test('public disabled and final LSP/editor boundaries cannot regress to stale claims', () => {
  const metadata = validateMetadata(loadMetadata())
  const capabilities = metadata.capabilities
  const byId = new Map(capabilities.map(capability => [capability.id, capability]))

  assert.equal(byId.get('public-compile').statusKind, 'disabled')
  assert.match(byId.get('public-compile').behavior, /HTTP 503/)
  assert.match(byId.get('lsp').behavior, /pull diagnostics/)
  assert.match(byId.get('lsp').behavior, /editor-integration gates/)
  assert.doesNotMatch(byId.get('lsp').behavior, /remain later|parser migration/i)
  assert.match(byId.get('vscode').behavior, /no binary is bundled or published/)
  assert.match(byId.get('neovim').behavior, /0\.11\.7 and 0\.12\.4/)
  assert.equal(byId.get('benchmark-report').statusKind, 'unavailable')
  assert.match(byId.get('benchmark-report').behavior, /no archive is selected/i)
  assert.match(byId.get('benchmark-report').behavior, /no timing, ranking, or ratio claim/i)
  for (const [id, version] of [
    ['scss', 'Dart Sass 1.101.0'],
    ['sass', 'Dart Sass 1.101.0'],
    ['less', 'Less 4.9.0'],
    ['stylus', 'Stylus 0.64.0'],
  ]) {
    assert.equal(byId.get(id).statusKind, 'verified')
    assert.match(byId.get(id).status, /native graduated verified/i)
    assert.ok(byId.get(id).evidence.includes('release-version'))
    assert.match(byId.get(id).behavior, new RegExp(version.replaceAll('.', '\\.')))
    assert.match(byId.get(id).behavior, /plugin|custom function|project code/i)
    assert.match(byId.get(id).behavior, /development oracle/)
    assert.match(byId.get(id).behavior, /does not run during compilation/)
  }
  assert.match(byId.get('less').behavior, /frozen 4\.6\.7 baseline/i)
  assert.match(byId.get('less').behavior, /no direct `image-size` dependency/i)
  assert.equal(byId.get('alternate-ecosystem-formats').statusKind, 'experimental')
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Vite, Rollup, esbuild, and Bun plugins/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Webpack\/Rspack raw loader/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Deterministic protocol-fixture tests/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /real Vite, Rollup, esbuild, pinned Bun 1\.4\.0, Webpack 5\.110\.2, and Rspack 2\.2\.2 builds all compile SCSS through that exact current-checkout binary/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Bun deliberately makes no native-import watch claim/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /real Parcel 2\.16\.4 local-transformer example/i)
  assert.ok(byId.get('alternate-ecosystem-formats').evidence.includes('bundler-adapters'))
  assert.ok(byId.get('alternate-ecosystem-formats').evidence.includes('turbopack-example'))
  assert.ok(byId.get('alternate-ecosystem-formats').evidence.includes('sveltekit-example'))
  assert.ok(byId.get('alternate-ecosystem-formats').evidence.includes('parcel-example'))
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /pinned Next\.js 16\.3\.4 Turbopack build reuses only `zigcss\/webpack`/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Next\.js 16\.2\+ module types are required/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /does not claim CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS globs/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /a `zigcss\/turbopack` export, a general Turbopack plugin, or wider framework support/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /pinned SvelteKit 2\.70\.3, Svelte 5\.57\.0, and Vite 8\.2\.2 source-checkout gate/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /external `\.module\.scss` file through `zigcss\/vite`/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /does not claim embedded `<style lang="scss">` blocks, Svelte preprocessors, framework HMR or watch invalidation/i)
  assert.match(byId.get('alternate-ecosystem-formats').behavior, /Exact Next\.js Webpack, Astro, and Nuxt host proofs are tracked as separate current-source capability rows/i)
  assert.equal(byId.get('next-webpack-host-example').statusKind, 'experimental')
  assert.match(byId.get('next-webpack-host-example').status, /pinned host-tested/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /Next\.js 16\.3\.4 current-source Webpack gate/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /blocking public Node network entry points/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /unchanged persistent-cache hit with zero native invocations/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /dependency-only warm rebuild/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /not an OS sandbox/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /source-map delivery is not claimed/i)
  assert.match(byId.get('next-webpack-host-example').behavior, /not stable 0\.6\.0 adapter delivery/i)
  assert.ok(byId.get('next-webpack-host-example').evidence.includes('next-webpack-example'))
  assert.equal(metadata.gates['next-webpack-example'].command, 'npm run test:next-webpack-example')
  assert.equal(byId.get('astro-host-example').statusKind, 'experimental')
  assert.match(byId.get('astro-host-example').status, /pinned host-tested/i)
  assert.match(byId.get('astro-host-example').behavior, /Astro 7\.2\.10 current-source gate/i)
  assert.match(byId.get('astro-host-example').behavior, /cached-offline, deny-network static production build/i)
  assert.match(byId.get('astro-host-example').behavior, /not stable 0\.6\.0 adapter delivery/i)
  assert.ok(byId.get('astro-host-example').evidence.includes('astro-example'))
  assert.equal(byId.get('nuxt-host-example').statusKind, 'experimental')
  assert.match(byId.get('nuxt-host-example').status, /pinned host-tested/i)
  assert.match(byId.get('nuxt-host-example').behavior, /Nuxt 4\.5\.2 current-source gate/i)
  assert.match(byId.get('nuxt-host-example').behavior, /client bundle, Nitro server bundle, and prerender output/i)
  assert.match(byId.get('nuxt-host-example').behavior, /no public production CSS map or runtime SSR request is claimed/i)
  assert.match(byId.get('nuxt-host-example').behavior, /not stable 0\.6\.0 adapter delivery/i)
  assert.ok(byId.get('nuxt-host-example').evidence.includes('nuxt-example'))
  assert.match(byId.get('node-api').status, /package-tested/i)
  assert.match(byId.get('node-api').behavior, /CommonJS and ESM/)
  assert.match(byId.get('node-api').behavior, /AbortSignal/)
})
