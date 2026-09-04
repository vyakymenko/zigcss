// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { packageManagerMatrixPolicy } from '../../scripts/validate-preprocessor-package.mjs'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const read = (relativePath: string) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
const exactMetaContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"

describe('consumer package website', () => {
  test('keeps local framework build artifacts out of the repository', () => {
    const ignored = read('.gitignore').split(/\r?\n/).filter(Boolean)
    expect(new Set(ignored).size).toBe(ignored.length)
    expect(ignored).toEqual(expect.arrayContaining([
      'examples/**/.astro/',
      'examples/**/.next/',
      'examples/**/.nuxt/',
      'examples/**/.output/',
      'examples/**/.parcel-cache/',
      'examples/**/.svelte-kit/',
      'examples/**/.vercel/',
      'examples/**/build/',
      'examples/**/dist/',
      'examples/**/out/',
      'examples/build-systems/.ninja_deps',
      'examples/build-systems/.ninja_log',
      'examples/build-systems/cmake-build/',
      'examples/build-systems/meson-build/',
      'examples/build-systems/styles.css',
      'examples/build-systems/styles.css.d',
      'vscode-extension/dist/',
      'vscode-extension/out/',
      'vscode-extension/*.vsix',
      'release-assets/',
      'native-target-evidence/',
      'zigcss-*.tgz',
    ]))
  })

  test('publishes package metadata at the canonical Pages URL', () => {
    const manifest = JSON.parse(read('package.json'))
    const html = read('docs/index.html')

    expect(manifest.homepage).toBe('https://vyakymenko.github.io/zigcss/')
    expect(manifest.description).toMatch(/self-contained native CSS, SCSS, Sass, Less, and Stylus compiler/i)
    expect(manifest.description).not.toMatch(/experimental/i)
    expect(html).toContain('<title>ZigCSS — Native CSS, SCSS, Sass, Less &amp; Stylus compiler</title>')
    expect(html).toContain('https://vyakymenko.github.io/zigcss/')
    expect(html).toContain('og:image')

    const socialCard = fs.readFileSync(path.join(repoRoot, 'docs/public/og.png'))
    expect(socialCard.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
    expect(socialCard.readUInt32BE(16)).toBe(1200)
    expect(socialCard.readUInt32BE(20)).toBe(630)
    expect(socialCard.byteLength).toBeGreaterThan(50_000)
    expect(socialCard.byteLength).toBeLessThan(1_000_000)
  })

  test('builds for the project path and recovers direct SPA routes', () => {
    expect(read('docs/vite.config.ts')).toMatch(/base:\s*['"]\/zigcss\/['"]/)
    expect(read('docs/public/404.html')).toContain('/zigcss/redirect-github-pages-route.js')
    expect(read('docs/public/redirect-github-pages-route.js')).toContain("pathSegmentsToKeep = 1")
    expect(read('docs/src/main.tsx')).toContain('import "./restore-github-pages-route.ts"')
    expect(read('docs/src/restore-github-pages-route.ts')).toContain("window.history.replaceState")
    expect(read('docs/public/404.html')).toContain('error: route not found — exit 2')
  })

  test('embeds the exact GitHub Pages-compatible CSP before every page resource', () => {
    for (const relativePath of ['docs/index.html', 'docs/public/404.html']) {
      const html = read(relativePath)
      const policy = `<meta http-equiv="Content-Security-Policy" content="${exactMetaContentSecurityPolicy}" />`
      expect(html.split(policy)).toHaveLength(2)
      expect(html.indexOf(policy)).toBeLessThan(html.search(/<(?:link|script)\b/i))
      expect(policy).not.toContain('frame-ancestors')
    }
  })

  test('ships a readable no-script fallback and self-hosted terminal typography', () => {
    const html = read('docs/index.html')
    const theme = read('docs/src/styles/theme.css')

    expect(html).toContain('<noscript>')
    expect(html).toContain('Exact in. Deterministic out. Denied by default.')
    expect(html).not.toMatch(/\sstyle=/)
    expect(theme).toMatch(/font-display:\s*swap/)
    for (const file of [
      'docs/src/assets/fonts/archivo-latin-variable.woff2',
      'docs/src/assets/fonts/jetbrains-mono-latin-variable.woff2',
    ]) {
      expect(fs.readFileSync(path.join(repoRoot, file)).subarray(0, 4).toString()).toBe('wOF2')
    }
    expect(read('docs/public/favicon.svg')).toMatch(/caret.*animation|animation.*caret/s)
  })

  test('keeps the landing JavaScript budget executable and fail-closed', () => {
    const manifest = JSON.parse(read('docs/package.json'))
    const gate = read('docs/scripts/check-bundle-budget.mjs')

    expect(manifest.scripts.build).toContain('check:bundle')
    expect(read('docs/vite.config.ts')).toMatch(/manifest:\s*true/)
    expect(gate).toMatch(/160 \* 1024/)
    expect(gate).toMatch(/src\/app\/components\/Home\.tsx/)
    expect(gate).toMatch(/gzipSync/)
  })

  test('makes the README a visual front door to the package website', () => {
    const readme = read('README.md')
    const installHeading = readme.indexOf('## Install')

    expect(readme).toContain(
      '[![ZigCSS — Native by design. Correct by contract.](https://vyakymenko.github.io/zigcss/og.png)](https://vyakymenko.github.io/zigcss/)',
    )
    expect(readme).toContain('**Compile CSS. Keep the meaning.**')
    expect(readme).toContain('**Five languages in. One deterministic compiler out.**')
    expect(readme).toContain('**Native by design. Fast on purpose. Correct by contract.**')
    expect(readme).toContain('[Website](https://vyakymenko.github.io/zigcss/)')
    expect(readme).toContain('[npm](https://www.npmjs.com/package/zigcss)')
    expect(readme).toMatch(/npm `latest` serves `zigcss@0\.6\.0`/i)
    expect(readme).toContain('npm install --save-dev zigcss')
    expect(readme.indexOf('[Website]')).toBeLessThan(installHeading)
  })

  test('documents the fail-closed compiler-aware development container on package and site surfaces', () => {
    const readme = read('README.md')
    const buildGuide = read('docs/src/content/docs/guide/build-from-source.md')
    const docsReadme = read('docs/README.md')

    for (const source of [readme, buildGuide, docsReadme]) {
      expect(source).toContain('npm run dev:docker')
      expect(source).toContain('http://127.0.0.1:5173/zigcss/')
      expect(source).toContain('docker compose -f docker-compose.dev.yml down')
      expect(source).toMatch(/read-only/i)
      expect(source).toMatch(/development/i)
      expect(source).toMatch(/no compiler HTTP|does not expose the compiler over HTTP/i)
    }
    expect(buildGuide).toContain('docker compose -f docker-compose.dev.yml down --volumes')
    expect(buildGuide).toMatch(/Vite starts only after a successful\s+initial Zig build/i)
    expect(buildGuide).toMatch(/failed rebuild makes the service unhealthy/i)
  })

  test('presents the benchmark program without inventing speed results', () => {
    const readme = read('README.md')

    expect(readme).toContain('## Benchmarks')
    expect(readme).toMatch(/43 ordered series/i)
    expect(readme).toMatch(/860 raw observations/i)
    expect(readme).toMatch(/Linux x64 bare metal/i)
    expect(readme).toMatch(/systemd-detect-virt/i)
    expect(readme).toMatch(/numbers remain unpublished/i)
    expect(readme).not.toMatch(/world.?s fastest|\d+x faster/i)
  })

  test('states the exact five-language boundary on package surfaces', () => {
    for (const relativePath of [
      'README.md',
      'docs/src/app/components/GettingStarted.tsx',
    ]) {
      const content = read(relativePath)
      expect(content).toMatch(/CSS/i)
      expect(content).toMatch(/SCSS/i)
      expect(content).toMatch(/Sass/i)
      expect(content).toMatch(/Less/i)
      expect(content).toMatch(/Stylus/i)
      expect(content).toMatch(/1\.101\.0/)
      expect(content).toMatch(/4\.6\.7/)
      expect(content).toMatch(/0\.64\.0/)
      expect(content).toMatch(/plugin|project code/i)
    }

    expect(read('docs/src/app/components/Home.tsx')).toMatch(/<FormatShowcase\s*\/>/)
    expect(read('docs/src/app/components/GettingStarted.tsx')).toContain('Stable CLI imports stay confined to the entry directory')
    expect(read('docs/src/app/components/Features.tsx')).toContain('REL-010 promotes only the stable 0.6.0 rows')
    expect(read('docs/src/content/docs/guide/css-compatibility.md')).toContain('Published stable 0.6.0 predates this parser contract')
    const showcase = read('docs/src/app/components/FormatShowcase.tsx')
    const examples = JSON.parse(read('docs/src/data/format-examples.json'))
    expect(examples.map((example: { label: string }) => example.label)).toEqual(['CSS', 'SCSS', 'Sass', 'Less', 'Stylus'])
    expect(examples.slice(1).map((example: { frontend: string }) => example.frontend)).toEqual([
      'Native Sass frontend',
      'Native Sass frontend',
      'Native Less frontend',
      'Native Stylus frontend',
    ])
    expect(showcase).toMatch(/selected\.frontend/)
    expect(showcase).not.toMatch(/selected\.provider/)
    expect(showcase).toMatch(/recorded compiler output/i)
    expect(showcase).toMatch(/format-examples\.json/)
  })

  test('publishes the verified Node API and evidence-calibrated experimental build-tool adapters', () => {
    const manifest = JSON.parse(read('package.json'))
    const readme = read('README.md')
    const status = read('docs/src/content/docs/guide/status.md')
    const declarations = read('api.d.ts')
    const nodeApiTests = read('scripts/verify-node-api.test.mjs')
    const typeConsumer = read('tests/typescript/consumer.ts')
    const builderGuide = read('docs/src/content/docs/guide/builder-integrations.md')

    expect(manifest.main).toBe('api.cjs')
    expect(manifest.types).toBe('api.d.ts')
    expect(manifest.exports).toEqual({
      '.': {
        import: { types: './api.d.mts', default: './api.mjs' },
        require: { types: './api.d.cts', default: './api.cjs' },
      },
      './adapters': {
        import: { types: './adapters/index.d.mts', default: './adapters/index.mjs' },
        require: { types: './adapters/index.d.cts', default: './adapters/index.cjs' },
      },
      './vite': {
        import: { types: './adapters/vite.d.mts', default: './adapters/vite.mjs' },
        require: { types: './adapters/vite.d.cts', default: './adapters/vite.cjs' },
      },
      './rollup': {
        import: { types: './adapters/rollup.d.mts', default: './adapters/rollup.mjs' },
        require: { types: './adapters/rollup.d.cts', default: './adapters/rollup.cjs' },
      },
      './esbuild': {
        import: { types: './adapters/esbuild.d.mts', default: './adapters/esbuild.mjs' },
        require: { types: './adapters/esbuild.d.cts', default: './adapters/esbuild.cjs' },
      },
      './bun': {
        import: { types: './adapters/bun.d.mts', default: './adapters/bun.mjs' },
        require: { types: './adapters/bun.d.cts', default: './adapters/bun.cjs' },
      },
      './webpack': {
        import: { types: './adapters/webpack.d.mts', default: './adapters/webpack.cjs' },
        require: { types: './adapters/webpack.d.cts', default: './adapters/webpack.cjs' },
      },
      './rspack': {
        import: { types: './adapters/rspack.d.mts', default: './adapters/rspack.cjs' },
        require: { types: './adapters/rspack.d.cts', default: './adapters/rspack.cjs' },
      },
      './package.json': './package.json',
    })
    expect(manifest.typesVersions).toEqual({
      '*': {
        adapters: ['adapters/index.d.ts'],
        vite: ['adapters/vite.d.ts'],
        rollup: ['adapters/rollup.d.ts'],
        esbuild: ['adapters/esbuild.d.ts'],
        bun: ['adapters/bun.d.ts'],
        webpack: ['adapters/webpack.d.ts'],
        rspack: ['adapters/rspack.d.ts'],
      },
    })
    for (const file of ['api.cjs', 'api.mjs', 'api.d.ts', 'api.d.mts', 'api.d.cts']) {
      expect(fs.existsSync(path.join(repoRoot, file))).toBe(true)
      expect(manifest.files).toContain(file)
    }
    for (const exportName of [
      'compile',
      'compileSync',
      'compileFile',
      'compileFileSync',
      'detectSyntax',
      'ZigCssCompileError',
    ]) {
      expect(declarations).toContain(`export ${exportName === 'ZigCssCompileError' ? 'class' : 'function'} ${exportName}`)
    }
    expect(nodeApiTests).toContain('string API routes all five syntaxes through one exact framed request')
    expect(nodeApiTests).toContain('request normalization carries maps, dependencies, optimizer, prefix query, and roots')
    expect(nodeApiTests).toContain('source parents and explicit roots are canonical across directory symlinks')
    expect(nodeApiTests).toContain('async API enforces timeout and AbortSignal termination')
    expect(readme).toMatch(/typed programmatic Node\.js API/i)
    expect(status).toMatch(/Programmatic Node\.js API boundary/)
    for (const tool of ['Webpack', 'Rspack', 'Rollup', 'Vite', 'esbuild', 'Bun', 'Turbopack', 'Next.js', 'SvelteKit', 'Astro', 'Nuxt', 'Nx', 'Parcel', 'Bazel']) {
      expect(readme).toContain(tool)
      expect(status).toContain(tool)
      expect(builderGuide).toContain(tool)
    }
    for (const command of [
      'test:bundler-adapters',
      'test:turbopack-example',
      'test:next-webpack-example',
      'test:sveltekit-example',
      'test:astro-example',
      'test:nuxt-example',
      'test:parcel-example',
      'test:build-systems',
      'test:package-managers',
      'test:types',
    ]) expect(builderGuide).toContain(command)
    expect(builderGuide).toContain('npm ci --ignore-scripts')
    expect(builderGuide).toContain('exact Node.js 24.20.0 LTS')
    expect(builderGuide).toMatch(/published `zigcss@0\.6\.0` binary predates/i)
    expect(builderGuide.replace(/\s+/g, ' ')).toContain('This build-system primitive is implemented only in the current `Unreleased` checkout')
    expect(builderGuide).not.toContain('build-system primitive currently shipped')
    const rootManifest = JSON.parse(read('package.json'))
    const nextManifest = JSON.parse(read('examples/next-turbopack/package.json'))
    const sveltekitManifest = JSON.parse(read('examples/sveltekit/package.json'))
    const astroManifest = JSON.parse(read('examples/astro/package.json'))
    const nuxtManifest = JSON.parse(read('examples/nuxt/package.json'))
    const normalizedBuilderGuide = builderGuide.replace(/\s+/g, ' ')
    for (const [label, version] of [
      ['Vite', rootManifest.devDependencies.vite],
      ['Rollup', rootManifest.devDependencies.rollup],
      ['esbuild', rootManifest.devDependencies.esbuild],
      ['Webpack', rootManifest.devDependencies.webpack],
      ['Rspack', rootManifest.devDependencies['@rspack/core']],
      ['Next.js', nextManifest.devDependencies.next],
      ['SvelteKit', sveltekitManifest.devDependencies['@sveltejs/kit']],
      ['Astro', astroManifest.devDependencies.astro],
      ['Nuxt', nuxtManifest.devDependencies.nuxt],
      ['Parcel', rootManifest.devDependencies.parcel],
      ['TypeScript', rootManifest.devDependencies.typescript],
    ]) expect(normalizedBuilderGuide).toContain(`${label} ${version}`)
    expect(nextManifest.devDependencies.next).toBe(rootManifest.devDependencies.next)
    for (const [label, version] of [
      ['Bun', packageManagerMatrixPolicy.bun],
      ['pnpm', packageManagerMatrixPolicy.pnpm],
      ['Yarn Classic', packageManagerMatrixPolicy.yarnClassic],
      ['Yarn Modern', packageManagerMatrixPolicy.yarnModern],
    ]) expect(normalizedBuilderGuide).toContain(`${label} ${version}`)
    for (const subpath of ['zigcss/vite', 'zigcss/rollup', 'zigcss/esbuild', 'zigcss/bun', 'zigcss/webpack', 'zigcss/rspack']) {
      expect(readme).toContain(subpath)
      expect(status).toContain(subpath)
    }
    for (const file of [
      'adapters/core.cjs',
      'adapters/index.cjs',
      'adapters/index.mjs',
      'adapters/index.d.cts',
      'adapters/index.d.mts',
      'adapters/index.d.ts',
      'adapters/vite.cjs',
      'adapters/vite.mjs',
      'adapters/vite.d.cts',
      'adapters/vite.d.mts',
      'adapters/vite.d.ts',
      'adapters/rollup.cjs',
      'adapters/rollup.mjs',
      'adapters/rollup.d.cts',
      'adapters/rollup.d.mts',
      'adapters/rollup.d.ts',
      'adapters/esbuild.cjs',
      'adapters/esbuild.mjs',
      'adapters/esbuild.d.cts',
      'adapters/esbuild.d.mts',
      'adapters/esbuild.d.ts',
      'adapters/bun.cjs',
      'adapters/bun.mjs',
      'adapters/bun.d.cts',
      'adapters/bun.d.mts',
      'adapters/bun.d.ts',
      'adapters/webpack.cjs',
      'adapters/webpack.d.cts',
      'adapters/webpack.d.mts',
      'adapters/webpack.d.ts',
      'adapters/webpack-types.d.ts',
      'adapters/rspack.cjs',
      'adapters/rspack.d.cts',
      'adapters/rspack.d.mts',
      'adapters/rspack.d.ts',
    ]) expect(manifest.files).toContain(file)
    expect(readme).toMatch(/real current-native Bun 1\.4\.0 build on the pinned CI host/i)
    expect(readme).toMatch(/real Rollup host build.*current-native SCSS build/i)
    expect(readme).toMatch(/real esbuild host coverage.*current-native SCSS/i)
    expect(readme).toMatch(/freshly built current-checkout binary through real Vite, Rollup, esbuild, Webpack, Rspack, pinned Bun 1\.4\.0, pinned Next\.js 16\.3\.4 Turbopack and Webpack builds, a pinned SvelteKit 2\.70\.3\/Vite 8\.2\.2 build, a pinned Astro 7\.2\.10 static build, a pinned Nuxt 4\.5\.2 client\/Nitro\/prerender build, and a local Parcel build/i)
    expect(readme).toMatch(/Real builds with pinned Webpack 5\.110\.2 and Rspack 2\.2\.2/i)
    expect(status).toMatch(/real Vite, Rollup, esbuild, pinned Bun 1\.4\.0, Webpack 5\.110\.2, and Rspack 2\.2\.2 builds all compile SCSS through that exact current-checkout binary/i)
    expect(status).toMatch(/Bun deliberately makes no native-import watch claim/i)
    expect(manifest.devDependencies.typescript).toBe('7.0.2')
    for (const subpath of ['zigcss', 'zigcss/adapters', 'zigcss/vite', 'zigcss/rollup', 'zigcss/esbuild', 'zigcss/bun', 'zigcss/webpack', 'zigcss/rspack']) {
      expect(typeConsumer).toContain(`from '${subpath}'`)
    }
    expect(typeConsumer).toContain('@ts-expect-error the adapter option surface is closed')
    expect(readme).toMatch(/real Parcel 2\.16\.4 local transformer integration/i)
    expect(readme).toMatch(/Next\.js 16\.3\.4 Turbopack and Webpack/i)
    expect(readme).toMatch(/`next build --webpack` proof uses one path-confined/i)
    expect(readme).toMatch(/unchanged zero-invocation cache hit/i)
    expect(readme).toMatch(/Next\.js\/Webpack does not preserve the original ZigCSS source-map chain/i)
    expect(readme).toMatch(/SvelteKit[^\n]*external `card\.module\.scss`/i)
    expect(readme).toMatch(/does not claim embedded `<style lang="scss">` blocks, Svelte preprocessors, framework HMR or watch invalidation/i)
    expect(readme).toMatch(/Astro[^\n]*external `card\.module\.scss`/i)
    expect(readme).toMatch(/exact Astro 7\.2\.10 gate warms an isolated npm cache, repeats the lockfile install offline, and denies network access during the static production build/i)
    expect(readme).toMatch(/same scoped binding in rendered HTML and emitted client JavaScript/i)
    expect(readme).toMatch(/Embedded Astro styles, HMR\/watch invalidation, SSR adapters, every renderer, framework aliases, `zigcss\/astro`, and stable 0\.6\.0 delivery are not claimed/i)
    expect(readme).toMatch(/Nuxt[^\n]*external `card\.module\.scss`/i)
    expect(readme).toMatch(/exact Nuxt 4\.5\.2 deny-network production gate proves one scoped binding across the client, Nitro SSR bundle, and prerendered HTML/i)
    expect(readme).toMatch(/native CSS map chain only in the `\.nuxt` intermediate output/i)
    expect(readme).toMatch(/Runtime SSR requests, embedded Nuxt styles, modules, HMR\/watch invalidation, other builders or presets, `zigcss\/nuxt`, and stable 0\.6\.0 delivery are not claimed/i)
    expect(status).toMatch(/condition-confined global SCSS entry/i)
    expect(status).toMatch(/does not claim CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS glob/i)
    expect(status).toMatch(/No PostCSS adapter is shipped/i)
    expect(Object.hasOwn(manifest.exports, './turbopack')).toBe(false)
    expect(Object.hasOwn(manifest.exports, './sveltekit')).toBe(false)
    expect(Object.hasOwn(manifest.exports, './astro')).toBe(false)
    expect(Object.hasOwn(manifest.exports, './nuxt')).toBe(false)
    expect(Object.hasOwn(manifest.exports, './parcel')).toBe(false)
  })

  test('documents package-manager-neutral lifecycle recovery without claiming offline downloads', () => {
    const manifest = JSON.parse(read('package.json'))
    const readme = read('README.md')
    const recovery = read('docs/src/content/docs/guide/recovery-cli.md')
    const status = read('docs/src/content/docs/guide/status.md')
    const wrapperTests = read('scripts/verify-node-wrapper.test.mjs')
    const managerTests = read('scripts/verify-package-managers.test.mjs')

    expect(manifest.bin).toEqual({ zigcss: 'index.js', 'zigcss-install': 'install.js' })
    expect(wrapperTests).toContain('npm wrapper gives package-manager-neutral recovery when lifecycle scripts are disabled')
    for (const surface of [readme, recovery, status]) {
      for (const manager of ['npm', 'pnpm', 'Yarn', 'Bun']) expect(surface).toContain(manager)
      expect(surface).toContain('zigcss-install')
      expect(surface).toMatch(/install script|install lifecycle/i)
      expect(surface).toMatch(/not an offline|not a promise.*offline/i)
    }
    expect(recovery).toMatch(/requires HTTPS access/i)
    expect(readme).toContain('Stable 0.6.0 does not expose a `zigcss-install` command')
    expect(readme).toContain('No published npm version currently exposes this new recovery command or integrity inventory')
    expect(recovery).toContain('This page documents the current `Unreleased` checkout')
    expect(recovery).toContain('Stable 0.6.0 users must approve its normal install lifecycle and reinstall instead')
    expect(status).toContain('No published npm version currently exposes the new recovery command')
    expect(managerTests).toContain('npm is mandatory for the package-manager matrix')
    for (const manager of ['npm', 'pnpm', 'Yarn', 'Bun']) {
      expect(managerTests).toContain(`${manager} installs the exact local tgz with lifecycle scripts disabled`)
    }
    for (const exact of ['pnpm 11.25.0', 'Yarn Classic 1.22.22', 'Yarn Modern 4.9.4', 'Bun 1.4.0']) {
      expect(readme).toContain(exact)
      expect(recovery).toContain(exact)
      expect(status).toContain(exact)
    }
    for (const surface of [readme, recovery, status]) {
      expect(surface).toMatch(/six execution variants/i)
      expect(surface).toContain('preferUnplugged')
      expect(surface).toContain('.yarn/unplugged')
      expect(surface).toMatch(/no `node_modules`/i)
      expect(surface).toMatch(/locally generated|local-fixture/i)
    }
    expect(manifest.preferUnplugged).toBe(true)
    expect(managerTests).toContain("id: 'yarn-modern-pnp'")
    expect(managerTests).toContain("YARN_ENABLE_GLOBAL_CACHE = 'false'")
    expect(managerTests).toContain("const toolchainRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-package-manager-toolchain-'))")
    expect(managerTests).toContain('COREPACK_HOME: corepackHome')
    expect(managerTests).toContain('Corepack exact toolchain state is bounded, confined, and reused offline')
    expect(managerTests).toContain('PnP CommonJS export resolution')
    expect(managerTests).toContain('PnP ESM export resolution')
    expect(managerTests).toContain('PnP TypeScript 7 no-paths package resolution boundary')
    expect(managerTests).toContain('error TS2307: Cannot find module')
    expect(managerTests).toContain('PnP strict TypeScript ${mode} declaration bytes')
    for (const surface of [readme, recovery, status]) {
      expect(surface).toMatch(/Yarn(?:'s)? loader/i)
      expect(surface).toMatch(/exact (?:import\/require )?declaration bytes/i)
      expect(surface).toMatch(/TypeScript 7\.0\.2 without a Yarn SDK or patch/i)
      expect(surface).toMatch(/TS2307.*no-paths PnP package resolution/i)
      expect(surface).toMatch(/native TypeScript PnP resolution (?:is not claimed|does not claim)/i)
      expect(surface).toMatch(/Corepack.*(?:disposable|confined|temporary)|(?:disposable|confined|temporary).*Corepack/i)
      expect(surface).toContain('https://yarnpkg.com/getting-started/editor-sdks')
    }
    expect(readme).toContain('native-integrity.json')
    expect(recovery).toContain('independently npm-published digest')
    expect(status).toMatch(/release smokes serve the exact selected release assets/i)
    expect(status).toMatch(/default-PnP matrix generates a local host fixture/i)
    expect(recovery).toMatch(/Two isolated CI harnesses/i)
  })
})
