// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const matrix = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tests/formats/matrix.json'), 'utf8'))
const guide = fs.readFileSync(
  path.join(repoRoot, 'docs/src/content/docs/guide/format-compatibility.md'),
  'utf8',
)
const strategy = fs.readFileSync(
  path.join(repoRoot, 'docs/adr/ADR-005-preprocessor-strategy.md'),
  'utf8',
)
const canonicalStrategy = fs.readFileSync(
  path.join(repoRoot, 'docs/adr/ADR-012-canonical-preprocessor-host.md'),
  'utf8',
)
const nativeStrategy = fs.readFileSync(
  path.join(repoRoot, 'docs/adr/ADR-013-self-contained-native-frontends.md'),
  'utf8',
)
const packageMetadata = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const workflow = fs.readFileSync(path.join(repoRoot, '.github/workflows/build.yml'), 'utf8')
const sidebar = fs.readFileSync(
  path.join(repoRoot, 'docs/src/app/components/docs/DocsLayout.tsx'),
  'utf8',
)

describe('published version-pinned format matrix', () => {
  test('publishes every machine-readable adapter boundary and owner', () => {
    expect(matrix.adapters).toHaveLength(8)
    for (const adapter of matrix.adapters) {
      const row = guide.split('\n').find(line => line.startsWith(`| \`${adapter.id}\` |`))
      expect(row).toBeDefined()
      expect(row).toContain(`| ${adapter.availability} |`)
      expect(row).toContain(`| ${adapter.compatibility} |`)
      expect(row).toContain(`| ${adapter.implementation} |`)
      expect(row).toContain(`| \`${adapter.strategy}\` |`)
      for (const extension of adapter.extensions) expect(row).toContain(`\`${extension}\``)
      for (const owner of adapter.ownerPackages) expect(row).toContain(`\`${owner}\``)
    }
  })

  test('binds every adapter to the accepted ADR strategy', () => {
    expect(strategy).toContain('- Status: Accepted')
    expect(canonicalStrategy).toContain('- Status: Accepted')
    expect(nativeStrategy).toContain('- Status: Accepted')
    expect(strategy).toContain('structured diagnostic and no partial CSS')
    for (const adapter of matrix.adapters) {
      expect(`${strategy}\n${canonicalStrategy}\n${nativeStrategy}`).toContain(
        `| \`${adapter.id}\` | \`${adapter.strategy}\` |`,
      )
    }
  })

  test('publishes every native graduated row with exact development-only oracles', () => {
    expect(matrix.canonicalProviders).toEqual({
      'dart-sass': {
        package: 'sass',
        version: '1.101.0',
        license: 'MIT',
        adapters: ['scss', 'sass'],
      },
      less: {
        package: 'less',
        version: '4.9.0',
        license: 'Apache-2.0',
        adapters: ['less'],
      },
      stylus: {
        package: 'stylus',
        version: '0.64.0',
        license: 'MIT',
        adapters: ['stylus'],
      },
    })

    for (const id of ['scss', 'sass', 'less', 'stylus']) {
      const adapter = matrix.adapters.find(candidate => candidate.id === id)
      expect(adapter.strategy).toBe('native-reimplementation')
      expect(adapter.availability).toBe('NativeCliZigApi')
      expect(adapter.compatibility).toBe('NativeGraduated')
      expect(adapter.ownerPackages.at(-1)).toBe('NATIVE-009')
      expect(adapter.implementation).toBe('NativeFrontend')
      expect(adapter.referenceOracleId).toBeTypeOf('string')
      expect(adapter.nativeSyntax).toBe(id)
      expect(adapter.probeOutput).toMatch(/^\.[a-z]+\{color:/)
      expect(adapter.knownRisks.join(' ')).toMatch(/plugin|custom function|project code/i)
      expect(adapter.currentBoundary).toMatch(/native Zig/i)
    }
    expect(guide).toMatch(/development-only reference oracles/i)
    expect(guide).toMatch(/do not run during compilation/i)
    expect(guide).toMatch(/Less 4\.9\.0.*frozen 4\.6\.7 native conformance baseline/i)
    expect(guide).toContain('npm run audit:development')
    expect(guide).toMatch(/shared bounded PNG\/GIF\/JPEG\/SVG dimension parser/i)
  })

  test('keeps the executable matrix in package scripts and CI', () => {
    expect(packageMetadata.scripts['test:formats']).toBe(
      'node --test tests/formats/validate.test.mjs && node tests/formats/validate.mjs',
    )
    expect(workflow).toContain('npm run test:formats')
    expect(sidebar).toContain('Format compatibility')
    expect(sidebar).toContain('/docs/guide/format-compatibility')
  })

  test('separates language support from the explicit experimental builder subpaths', () => {
    for (const subpath of [
      'zigcss/vite',
      'zigcss/rollup',
      'zigcss/esbuild',
      'zigcss/bun',
      'zigcss/webpack',
      'zigcss/rspack',
    ]) expect(guide).toContain(subpath)

    expect(guide).toMatch(/do not add new source languages or imply a published Parcel transformer, framework-specific adapter, Nx executor, Bazel rule, Angular integration, or general framework compatibility/i)
    expect(guide).toMatch(/pinned Next\.js 16\.3\.4 Turbopack example reuses only `zigcss\/webpack`/i)
    expect(guide).toMatch(/Next\.js 16\.2\+ loader output module types are required/i)
    expect(guide).toMatch(/separate Webpack proof with Sass 1\.101\.0 only as the downstream parser/i)
    expect(guide).toMatch(/cached-offline `next build --webpack` production builds while blocking public Node network entry points/i)
    expect(guide).toMatch(/unchanged zero-native-invocation cache hit/i)
    expect(guide).toMatch(/not an OS sandbox/i)
    expect(guide).toMatch(/final Webpack stylesheet does not retain the original ZigCSS source-map chain/i)
    expect(guide).toMatch(/Both modes remain source-checkout-only and claim no CSS Modules/i)
    expect(guide).toMatch(/pinned SvelteKit 2\.70\.3\/Svelte 5\.57\.0\/Vite 8\.2\.2 example reuses `zigcss\/vite`/i)
    expect(guide).toMatch(/Embedded styles, Svelte preprocessors, framework HMR\/watch invalidation, arbitrary adapters\/targets, and general SvelteKit compatibility remain unclaimed/i)
    expect(guide).toMatch(/pinned Astro 7\.2\.10 static example registers `zigcss\/vite`/i)
    expect(guide).toMatch(/same CSS Module binding in rendered HTML and emitted client JavaScript/i)
    expect(guide).toMatch(/Embedded Astro styles, HMR\/watch invalidation, SSR adapters, every renderer, framework aliases, `zigcss\/astro`, and stable 0\.6\.0 delivery remain unclaimed/i)
    expect(guide).toMatch(/pinned Nuxt 4\.5\.2 example also registers `zigcss\/vite`/i)
    expect(guide).toMatch(/client bundle, Nitro SSR bundle, and prerendered page/i)
    expect(guide).toMatch(/exact native CSS map chain is present only in Nuxt's `\.nuxt` intermediate Vite output/i)
    expect(guide).toMatch(/no public production CSS map or runtime SSR request is claimed/i)
    expect(guide).toMatch(/Embedded Nuxt styles, modules, HMR\/watch invalidation, other builders or deployment presets, `zigcss\/nuxt`, and stable 0\.6\.0 delivery remain unclaimed/i)
    expect(guide).toMatch(/No PostCSS adapter is shipped/i)
    expect(guide).toContain('npm run test:bundler-adapters')
    expect(guide).toContain('npm run test:turbopack-example')
    expect(guide).toContain('npm run test:next-webpack-example')
    expect(guide).toContain('npm run test:sveltekit-example')
    expect(guide).toContain('npm run test:astro-example')
    expect(guide).toContain('npm run test:nuxt-example')
  })
})
