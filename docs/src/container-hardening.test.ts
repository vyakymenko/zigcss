// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const dockerfilePath = path.resolve(import.meta.dirname, '../../Dockerfile.docs')
const dockerfile = fs.readFileSync(dockerfilePath, 'utf8')
const dockerignore = fs.readFileSync(path.resolve(import.meta.dirname, '../../.dockerignore'), 'utf8')
const developmentDockerignore = fs.readFileSync(path.resolve(import.meta.dirname, '../../Dockerfile.dockerignore'), 'utf8')
const documentationDockerignore = fs.readFileSync(path.resolve(import.meta.dirname, '../../Dockerfile.docs.dockerignore'), 'utf8')
const releaseDockerignore = fs.readFileSync(path.resolve(import.meta.dirname, '../../Dockerfile.release.dockerignore'), 'utf8')
const developmentDockerfile = fs.readFileSync(path.resolve(import.meta.dirname, '../../Dockerfile'), 'utf8')
const zigSetup = fs.readFileSync(path.resolve(import.meta.dirname, '../../.github/actions/setup-zig/setup-zig.mjs'), 'utf8')
const nodeImage = 'node:22.22.0-alpine@sha256:e4bf2a82ad0a4037d28035ae71529873c069b13eb0455466ae0bc13363826e34'
const dockerfileFrontend = '# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e'

function runtimeStage(): string {
  const marker = `FROM ${nodeImage} AS runtime`
  const start = dockerfile.indexOf(marker)
  expect(start).toBeGreaterThan(-1)
  return dockerfile.slice(start)
}

describe('documentation runtime container', () => {
  test('pins the Dockerfile frontend by digest across every public image', () => {
    expect(dockerfile.split('\n', 1)[0]).toBe(dockerfileFrontend)
    expect(developmentDockerfile.split('\n', 1)[0]).toBe(dockerfileFrontend)
    expect(fs.readFileSync(path.resolve(import.meta.dirname, '../../Dockerfile.release'), 'utf8').split('\n', 1)[0]).toBe(dockerfileFrontend)
  })

  test('pins both stages to the reviewed exact Node image', () => {
    expect(dockerfile.match(/^FROM .+$/gm)).toEqual([
      `FROM ${nodeImage} AS builder`,
      `FROM ${nodeImage} AS runtime`,
    ])
  })

  test('runs the server as the unprivileged node user on a high port', () => {
    const runtime = runtimeStage()

    expect(runtime).toContain('ENV PORT=8080')
    expect(runtime).toContain('EXPOSE 8080')
    expect(runtime.indexOf('USER node')).toBeGreaterThan(-1)
    expect(runtime.indexOf('USER node')).toBeLessThan(runtime.indexOf('CMD ["node", "server.js"]'))
  })

  test('contains only the built site and static server from the repository', () => {
    const runtime = runtimeStage()
    const packageManifest = JSON.parse(fs.readFileSync(path.resolve(import.meta.dirname, '../../package.json'), 'utf8'))
    const packageSubpaths = ['zigcss', 'zigcss/adapters', 'zigcss/vite', 'zigcss/rollup', 'zigcss/esbuild', 'zigcss/bun', 'zigcss/webpack', 'zigcss/rspack']

    expect(runtime).toContain('COPY --from=builder /repo/docs/dist ./dist')
    expect(runtime).toContain('COPY --from=builder /repo/docs/server.js ./server.js')
    expect(runtime).not.toContain('COPY . .')
    expect(runtime).not.toContain('/usr/local/bin/zigcss')
    expect(dockerfile).not.toContain('curl -fSL')
    expect(dockerfile).not.toContain('zigcss-bin')
    expect(dockerfile).toContain('complete published runtime, declaration, and trust closure')
    expect(dockerfile).toContain(`for (const id of [${packageSubpaths.map(id => `"${id}"`).join(', ')}]) require(id)`)
    expect(dockerfile).toContain(`for (const id of [${packageSubpaths.map(id => `"${id}"`).join(', ')}]) await import(id)`)
    for (const file of packageManifest.files.filter((file: string) => !file.startsWith('adapters/'))) {
      expect(dockerfile).toContain(file)
      expect(documentationDockerignore).toContain(`!${file}`)
    }
    const declaredAdapters = packageManifest.files.filter((file: string) => file.startsWith('adapters/')).sort()
    const actualAdapters = fs.readdirSync(path.resolve(import.meta.dirname, '../../adapters'), { withFileTypes: true })
      .map(entry => `adapters/${entry.name}`)
      .sort()
    expect(actualAdapters).toEqual(declaredAdapters)
  })

  test('keeps repository state and generated files out of the build context', () => {
    expect(dockerfile).not.toContain('COPY . .')
    const entries = dockerignore.split(/\r?\n/).filter(Boolean)
    expect(new Set(entries).size).toBe(entries.length)
    expect(entries).toEqual([
      '.git',
      '.idea',
      '.vscode',
      '**/.idea',
      '**/.vscode',
      '.npmrc',
      '**/.npmrc',
      '**/.env',
      '**/.env.*',
      '**/.DS_Store',
      '**/*.log',
      '.zig-cache',
      'zig-cache',
      'zig-out',
      '**/.zig-cache',
      '**/zig-cache',
      '**/zig-out',
      'node_modules',
      '**/node_modules',
      '!tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules/',
      '!tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules/**',
      'docs/dist',
      '**/dist',
      '**/coverage',
      '**/.nyc_output',
      '**/.vite',
      '**/.astro',
      '**/.next',
      '**/.nuxt',
      '**/.output',
      '**/.svelte-kit',
      '**/.parcel-cache',
      '**/.turbo',
      'examples/**/.vercel',
      'examples/**/build',
      'examples/**/out',
      'examples/build-systems/.ninja_deps',
      'examples/build-systems/.ninja_log',
      'examples/build-systems/cmake-build',
      'examples/build-systems/meson-build',
      'examples/build-systems/styles.css',
      'examples/build-systems/styles.css.d',
      'vscode-extension/out',
      'vscode-extension/*.vsix',
      'release-assets',
      'native-target-evidence',
      'zigcss-*.tgz',
      'bin',
    ])
    expect(developmentDockerignore).toBe(dockerignore)
    expect(documentationDockerignore.split(/\r?\n/).filter(Boolean)).toEqual([
      '**',
      '!Dockerfile.docs',
      '!package.json',
      '!index.js',
      '!install.js',
      '!api.cjs',
      '!api.mjs',
      '!api.d.cts',
      '!api.d.mts',
      '!api.d.ts',
      '!native-integrity.json',
      '!PREPROCESSOR-SBOM.spdx.json',
      '!THIRD_PARTY_NOTICES.md',
      '!README.md',
      '!LICENSE',
      '!adapters',
      '!adapters/**',
      '!docs',
      '!docs/**',
      'docs/node_modules',
      'docs/dist',
      'docs/**/.npmrc',
      'docs/**/.env',
      'docs/**/.env.*',
      'docs/**/.DS_Store',
      'docs/**/*.log',
      'docs/**/coverage',
      'docs/**/.nyc_output',
      'docs/**/.vite',
    ])
    expect(releaseDockerignore.split(/\r?\n/).filter(Boolean)).toEqual([
      '**',
      '!Dockerfile.release',
      '!package.json',
      '!install.js',
      '!native-integrity.json',
      '!scripts',
      '!scripts/prepare-release-container.mjs',
      '!release-assets',
      '!release-assets/**',
    ])
  })

  test('retains only the tracked Stylus node_modules resolution corpus', () => {
    const fixtureRoot = path.resolve(
      import.meta.dirname,
      '../../tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules',
    )
    expect([
      'lookup-b/package.json',
      'lookup-b/test.styl',
      'lookup-c.styl/index.styl',
    ].map(file => fs.statSync(path.join(fixtureRoot, file)).isFile())).toEqual([true, true, true])
    expect(dockerignore).toContain('!tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules/**')
    expect(developmentDockerignore).toContain('!tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules/**')
  })
})

describe('development container supply chain', () => {
  test('pins the exact multi-architecture Node base and Zig archives', () => {
    expect(developmentDockerfile.match(/^FROM node:.+$/gm)).toEqual([
      `FROM ${nodeImage} AS zig-amd64`,
      `FROM ${nodeImage} AS zig-arm64`,
    ])
    expect(developmentDockerfile).toContain('FROM zig-${TARGETARCH} AS development')

    for (const artifact of [
      {
        target: 'x86_64-linux',
        size: '53733924',
        sha256: '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239',
      },
      {
        target: 'aarch64-linux',
        size: '49471996',
        sha256: '958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f',
      },
    ]) {
      expect(developmentDockerfile).toContain(
        `ADD --checksum=sha256:${artifact.sha256} https://ziglang.org/download/0.15.2/zig-${artifact.target}-0.15.2.tar.xz /tmp/zig.tar.xz`,
      )
      expect(developmentDockerfile).toContain(`test "$(wc -c < /tmp/zig.tar.xz)" -eq ${artifact.size}`)
      expect(zigSetup).toContain(`size: ${Number(artifact.size).toLocaleString('en-US').replaceAll(',', '_')}`)
      expect(zigSetup).toContain(`sha256: '${artifact.sha256}'`)
    }
    expect(developmentDockerfile).not.toMatch(/apt-get|\bcurl\b|\bwget\b/)
    expect(developmentDockerfile).toContain('test "$(/usr/local/zig/zig version)" = "${ZIG_VERSION}"')
  })

  test('installs the exact documentation graph without lifecycle scripts as an unprivileged user', () => {
    expect(developmentDockerfile).toContain('npm ci --ignore-scripts')
    expect(developmentDockerfile).toContain('node_modules/.zigcss-docs-inputs.sha256')
    expect(developmentDockerfile).toContain('USER node')
    expect(developmentDockerfile.indexOf('USER node')).toBeLessThan(
      developmentDockerfile.indexOf('npm ci --ignore-scripts'),
    )
  })
})
