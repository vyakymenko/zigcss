// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import capabilityMetadata from './data/capabilities.json'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const startMarker = '<!-- capability-status:start -->'
const endMarker = '<!-- capability-status:end -->'
const read = (relativePath: string) =>
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

function generatedTable(content: string): string {
  const start = content.indexOf(startMarker)
  const end = content.indexOf(endMarker)
  expect(start).toBeGreaterThanOrEqual(0)
  expect(end).toBeGreaterThan(start)
  return content.slice(start + startMarker.length, end).trim()
}

describe('evidence-linked capability status metadata', () => {
  test('defines one closed row and status vocabulary', () => {
    expect(capabilityMetadata.schemaVersion).toBe(1)
    expect(capabilityMetadata.statusKinds).toEqual([
      'experimental',
      'verified',
      'unavailable',
      'disabled',
    ])
    expect(capabilityMetadata.capabilities).toHaveLength(30)
    expect(new Set(capabilityMetadata.capabilities.map(item => item.id)).size).toBe(30)
    expect(new Set(capabilityMetadata.capabilities.map(item => item.surface)).size).toBe(30)
  })

  test('anchors every row to a declared executable gate and real source text', () => {
    const used = new Set<string>()
    for (const capability of capabilityMetadata.capabilities) {
      expect(capability.evidence.length).toBeGreaterThan(0)
      for (const gateId of capability.evidence) {
        used.add(gateId)
        const gate = capabilityMetadata.gates[gateId as keyof typeof capabilityMetadata.gates]
        expect(gate).toBeDefined()
        expect(gate.command).toMatch(/^(npm|zig) /)
        for (const anchor of gate.anchors) {
          const content = read(anchor.path)
          for (const needle of anchor.contains) expect(content).toContain(needle)
        }
      }
    }
    expect([...used].sort()).toEqual(Object.keys(capabilityMetadata.gates).sort())
  })

  test('publishes the canonical generated table in the detailed status guide', () => {
    const docsTable = generatedTable(read('docs/src/content/docs/guide/status.md'))

    expect(read('README.md')).not.toContain(startMarker)
    expect(read('README.md')).not.toContain(endMarker)
    expect(docsTable.match(/^\| /gm)).toHaveLength(capabilityMetadata.capabilities.length + 1)
    for (const capability of capabilityMetadata.capabilities) {
      expect(docsTable).toContain(`| ${capability.surface} | ${capability.status} |`)
    }
  })

  test('documents the Nix route as configured repository-local evidence only', () => {
    const readme = read('README.md')
    const changelog = read('CHANGELOG.md')
    const buildGuide = read('docs/src/content/docs/guide/build-from-source.md')
    const statusGuide = read('docs/src/content/docs/guide/status.md')

    expect(readme).toContain('repository-local Nix flake')
    expect(readme).toContain('version Nix installer script is not itself content-addressed')
    expect(readme).toContain('No nixpkgs or registry publication, binary cache, offline installation')
    expect(changelog).toContain('GitHub Actions is configured to fail closed')
    expect(changelog).toContain('versioned installer script is not content-addressed')
    expect(buildGuide).toContain('nix flake check --all-systems --no-build')
    expect(buildGuide).toContain('--no-update-lock-file --no-write-lock-file --no-use-registries')
    expect(buildGuide).toContain('does not cross-compile them')
    expect(buildGuide).toContain('not the complete Zig test suite')
    expect(buildGuide).toContain('does not publish ZigCSS to nixpkgs or a registry')
    expect(statusGuide).toContain('This describes configured CI, not a claim that a new hosted run has already completed')
    expect(statusGuide).toContain('installer, input, and substitute acquisition require network access')
    expect(statusGuide).toContain('GitHub-hosted runner images are mutable')
    expect(statusGuide).toContain('flakes remain an experimental Nix interface')
    expect(statusGuide).toContain('not nixpkgs or registry publication, a binary cache, an offline installer')
  })

  test('anchors bounded Corepack and the exact default-PnP capability boundary', () => {
    const gate = capabilityMetadata.gates['package-managers']
    const managerAnchor = gate.anchors.find(
      anchor => anchor.path === 'scripts/verify-package-managers.test.mjs',
    )
    const packageAnchor = gate.anchors.find(anchor => anchor.path === 'package.json')

    expect(managerAnchor).toBeDefined()
    expect(packageAnchor).toBeDefined()
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
    ]) expect(managerAnchor?.contains).toContain(needle)
    expect(packageAnchor?.contains).toContain('"preferUnplugged": true')

    const nodeApi = capabilityMetadata.capabilities.find(item => item.id === 'node-api')
    expect(nodeApi?.behavior).toContain("Yarn's loader for CommonJS and ESM export resolution")
    expect(nodeApi?.behavior).toContain('exact import/require declaration bytes')
    expect(nodeApi?.behavior).toContain('condition-specific strict compile')
    expect(nodeApi?.behavior).toContain('exact unpatched TypeScript 7.0.2 without a Yarn SDK or patch')
    expect(nodeApi?.behavior).toContain('`TS2307` for no-paths PnP package resolution')
    expect(nodeApi?.behavior).toContain('native TypeScript PnP resolution is not claimed')
    expect(nodeApi?.behavior).toContain('confined Yarn and Corepack state')
    expect(nodeApi?.behavior).toContain("[Yarn's official SDK guidance](https://yarnpkg.com/getting-started/editor-sdks)")
  })

  test('keeps final editor and disabled-service boundaries current', () => {
    const byId = new Map(capabilityMetadata.capabilities.map(item => [item.id, item]))

    expect(byId.get('lsp')?.behavior).toContain('pull diagnostics')
    expect(byId.get('lsp')?.behavior).not.toMatch(/remain later|parser migration/i)
    expect(byId.get('vscode')?.behavior).toContain('no binary is bundled or published')
    expect(byId.get('neovim')?.behavior).toContain('0.11.7 and 0.12.4')
    expect(byId.get('release-artifacts')?.behavior).toContain('one GitHub prerelease')
    expect(byId.get('release-artifacts')?.behavior).toContain('25 exact assets')
    expect(byId.get('benchmark-report')?.statusKind).toBe('unavailable')
    expect(byId.get('benchmark-report')?.behavior).toContain('machine-attested Linux x64 bare metal')
    expect(byId.get('benchmark-report')?.behavior).toContain('no archive is selected')
    expect(byId.get('public-compile')?.statusKind).toBe('disabled')
    expect(byId.get('public-compile')?.behavior).toContain('HTTP 503')
    expect(byId.get('optimizer')?.statusKind).toBe('experimental')
    expect(byId.get('optimizer')?.behavior).toContain('CSS, SCSS, indented Sass, Less, and Stylus')
    expect(byId.get('optimizer')?.behavior).toContain('bounded byte-stable fixed point')
    expect(byId.get('optimizer')?.behavior).toContain('source maps remain incompatible')
    expect(byId.get('optimizer')?.evidence).toContain('preprocessor-product')
    expect(byId.get('node-api')?.status).toContain('package-tested')
    expect(byId.get('node-api')?.behavior).toContain('CommonJS and ESM')
    expect(byId.get('node-api')?.behavior).toContain('all five syntaxes')
    expect(byId.get('node-api')?.behavior).toContain('AbortSignal')
    expect(byId.get('node-api')?.evidence).toContain('node-api')
    expect(byId.get('target-prefix')?.status).toContain('all-syntax CLI/API verified')
    expect(byId.get('target-prefix')?.behavior).toContain('CSS, SCSS, Sass, Less, and Stylus')
    expect(byId.get('target-prefix')?.behavior).toContain('not a general autoprefixer')
    expect(byId.get('target-prefix')?.evidence).toContain('preprocessor-product')
    expect(byId.get('browser-targets')?.status).toContain('all-syntax CLI/API verified')
    expect(byId.get('browser-targets')?.behavior).toContain('strict explicit-minimum grammar')
    expect(byId.get('browser-targets')?.behavior).toContain('no defaults')
    for (const id of ['output-planning', 'optimizer', 'target-prefix', 'source-maps', 'browser-targets']) {
      expect(byId.get(id)?.status).toMatch(/Unreleased/i)
      expect(byId.get(id)?.behavior).toMatch(/current Unreleased/i)
      expect(byId.get(id)?.behavior).toMatch(/Published stable 0\.6\.0/i)
    }
    expect(byId.get('scss')?.behavior).toContain('Dart Sass 1.101.0 development oracle')
    expect(byId.get('sass')?.behavior).toContain('Dart Sass 1.101.0 development oracle')
    expect(byId.get('less')?.behavior).toContain('Less 4.9.0 development oracle over frozen 4.6.7 baseline')
    expect(byId.get('less')?.behavior).toContain('shared bounded PNG/GIF/JPEG/SVG dimension parser')
    expect(byId.get('less')?.behavior).toContain('no direct `image-size` dependency')
    expect(byId.get('stylus')?.behavior).toContain('Stylus 0.64.0 development oracle')
    for (const id of ['scss', 'sass', 'less', 'stylus']) {
      expect(byId.get(id)?.statusKind).toBe('verified')
      expect(byId.get(id)?.status).toMatch(/native graduated verified/i)
      expect(byId.get(id)?.behavior).toMatch(/does not run during compilation/i)
    }
    expect(byId.get('alternate-ecosystem-formats')?.statusKind).toBe('experimental')
    expect(byId.get('alternate-ecosystem-formats')?.status).toContain('adapter-tested')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('Vite, Rollup, esbuild, and Bun plugins')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('Webpack/Rspack raw loader')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('real Vite, Rollup, esbuild, pinned Bun 1.4.0, Webpack 5.110.2, and Rspack 2.2.2 builds all compile SCSS through that exact current-checkout binary')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('Bun deliberately makes no native-import watch claim')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('real Parcel 2.16.4 local-transformer example')
    expect(byId.get('alternate-ecosystem-formats')?.evidence).toContain('bundler-adapters')
    expect(byId.get('alternate-ecosystem-formats')?.evidence).toContain('turbopack-example')
    expect(byId.get('alternate-ecosystem-formats')?.evidence).toContain('sveltekit-example')
    expect(byId.get('alternate-ecosystem-formats')?.evidence).toContain('parcel-example')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('pinned Next.js 16.3.4 Turbopack build reuses only `zigcss/webpack`')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('Next.js 16.2+ module types are required')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('does not claim CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS globs')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('a `zigcss/turbopack` export, a general Turbopack plugin, or wider framework support')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('pinned SvelteKit 2.70.3, Svelte 5.57.0, and Vite 8.2.2 source-checkout gate')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('external `.module.scss` file through `zigcss/vite`')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('does not claim embedded `<style lang="scss">` blocks, Svelte preprocessors, framework HMR or watch invalidation')
    expect(byId.get('alternate-ecosystem-formats')?.behavior).toContain('Exact Next.js Webpack, Astro, and Nuxt host proofs are tracked as separate current-source capability rows')
    expect(byId.get('next-webpack-host-example')?.statusKind).toBe('experimental')
    expect(byId.get('next-webpack-host-example')?.status).toContain('pinned host-tested')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('Next.js 16.3.4 current-source Webpack gate')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('blocking public Node network entry points')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('unchanged persistent-cache hit with zero native invocations')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('dependency-only warm rebuild')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('not an OS sandbox')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('source-map delivery is not claimed')
    expect(byId.get('next-webpack-host-example')?.behavior).toContain('not stable 0.6.0 adapter delivery')
    expect(byId.get('next-webpack-host-example')?.evidence).toContain('next-webpack-example')
    expect(byId.get('astro-host-example')?.statusKind).toBe('experimental')
    expect(byId.get('astro-host-example')?.status).toContain('pinned host-tested')
    expect(byId.get('astro-host-example')?.behavior).toContain('Astro 7.2.10 current-source gate')
    expect(byId.get('astro-host-example')?.behavior).toContain('cached-offline, deny-network static production build')
    expect(byId.get('astro-host-example')?.behavior).toContain('not stable 0.6.0 adapter delivery')
    expect(byId.get('astro-host-example')?.evidence).toContain('astro-example')
    expect(byId.get('nuxt-host-example')?.statusKind).toBe('experimental')
    expect(byId.get('nuxt-host-example')?.status).toContain('pinned host-tested')
    expect(byId.get('nuxt-host-example')?.behavior).toContain('Nuxt 4.5.2 current-source gate')
    expect(byId.get('nuxt-host-example')?.behavior).toContain('client bundle, Nitro server bundle, and prerender output')
    expect(byId.get('nuxt-host-example')?.behavior).toContain('no public production CSS map or runtime SSR request is claimed')
    expect(byId.get('nuxt-host-example')?.behavior).toContain('not stable 0.6.0 adapter delivery')
    expect(byId.get('nuxt-host-example')?.evidence).toContain('nuxt-example')
    expect(byId.get('nix-flake')?.statusKind).toBe('experimental')
    expect(byId.get('nix-flake')?.status).toContain('repository-local gated')
    for (const system of ['x86_64-linux', 'aarch64-linux', 'x86_64-darwin', 'aarch64-darwin']) {
      expect(byId.get('nix-flake')?.behavior).toContain(system)
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
    ]) expect(byId.get('nix-flake')?.behavior).toContain(boundary)
  })
})
