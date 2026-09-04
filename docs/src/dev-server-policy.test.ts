// @vitest-environment node

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { resolveZigBinaryDirectory } from '../vite.config'

const repoRoot = path.resolve(import.meta.dirname, '..', '..')
const read = (file: string) => fs.readFileSync(path.join(repoRoot, file), 'utf8')

function executable(filename: string, source: string) {
  fs.writeFileSync(filename, source, { mode: 0o755 })
  fs.chmodSync(filename, 0o755)
}

function developmentFixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-dev-lifecycle-')))
  fs.mkdirSync(path.join(root, 'docs'))
  fs.mkdirSync(path.join(root, 'src'))
  fs.mkdirSync(path.join(root, 'commands'))
  fs.copyFileSync(path.join(repoRoot, 'dev.js'), path.join(root, 'dev.js'))
  return root
}

function runDevelopmentFixture(root: string, args: string[] = []) {
  return spawnSync(process.execPath, [path.join(root, 'dev.js'), ...args], {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${path.join(root, 'commands')}${path.delimiter}${process.env.PATH ?? ''}`,
      ZIGCSS_TEST_NPM_MARKER: path.join(root, 'npm-launched'),
    },
    timeout: 10_000,
  })
}

describe('documentation development server policy', () => {
  it('allows only the repository and Docker binary directories', () => {
    expect(resolveZigBinaryDirectory(undefined)).toBe(path.join(repoRoot, 'bin'))
    expect(resolveZigBinaryDirectory(path.join(repoRoot, 'bin'))).toBe(path.join(repoRoot, 'bin'))
    expect(resolveZigBinaryDirectory('/app/bin')).toBe('/app/bin')
    expect(() => resolveZigBinaryDirectory('/tmp/untrusted-bin')).toThrow(/repository bin directory/)
    expect(() => resolveZigBinaryDirectory('../bin')).toThrow(/repository bin directory/)
  })

  it('has no compiler HTTP middleware and binds to loopback by default', () => {
    const config = read('docs/vite.config.ts')

    expect(config).not.toContain('compile-api-plugin')
    expect(config).not.toContain('zigcssCompilePlugin')
    expect(config).not.toContain('allowedHosts: true')
    expect(config).toContain("name: 'zigcss-local-development-csp'")
    expect(config).toContain("apply: 'serve'")
    expect(config).toContain("connect-src 'self' ws://127.0.0.1:* ws://localhost:*")
    expect(config).toContain("style-src 'self' 'unsafe-inline'")
    expect(read('docs/index.html')).toContain('<link rel="icon" href="/favicon.svg" type="image/svg+xml" />')
    expect(read('docs/index.html')).not.toContain('/zigcss/zigcss/favicon.svg')
    expect(config).toContain("host: externalDevServer ? '0.0.0.0' : '127.0.0.1'")
    expect(config).toContain("allowedHosts: ['localhost', '127.0.0.1']")
    expect(fs.existsSync(path.join(repoRoot, 'docs/scripts/compile-api-plugin.js'))).toBe(false)
  })

  it('keeps the Docker development port on the host loopback interface', () => {
    const compose = read('docker-compose.dev.yml')

    expect(compose).toContain('"127.0.0.1:5173:5173"')
    expect(compose).not.toContain('playgrounds.expose')
    expect(compose).not.toContain('playgrounds.subdomain')
    expect(compose).toContain('test -f /app/bin/.zigcss-dev-ready')
    expect(compose).toContain('/app/bin/zigcss --version')
  })

  it('binds live source read-only and isolates every writable build product', () => {
    const compose = read('docker-compose.dev.yml')
    const entrypoint = read('entrypoint.sh')

    expect(compose).toContain('source: "${ZIGCSS_DEV_SOURCE_DIRECTORY:-.}"')
    expect(compose).toContain('target: /workspace')
    expect(compose).toContain('read_only: true')
    expect(compose).toContain('ZIGCSS_DEV_BIN_DIRECTORY=/app/bin')
    expect(compose).toContain('target: /app/docs/vite.config.ts')
    for (const mount of [
      'docs-node-modules:/app/docs/node_modules',
      'zig-bin:/app/bin',
      'zig-cache:/app/zig-cache',
      'zig-out:/app/zig-out',
      'dot-zig-cache:/app/.zig-cache',
      'zig-global-cache:/home/node/.cache/zig',
    ]) {
      expect(compose).toContain(mount)
    }
    expect(compose).not.toContain('/deps/')
    expect(compose).not.toContain('target: /app\n')
    expect(entrypoint).toContain('never link /workspace/docs over')
    expect(entrypoint.match(/link_live_directory [^\n]+/g)).toEqual([
      'link_live_directory src',
      'link_live_directory docs/public',
      'link_live_directory docs/src',
    ])
    expect(entrypoint.match(/link_live_file [^\n]+/g)).toEqual([
      'link_live_file build.zig',
      'link_live_file build.zig.zon',
      'link_live_file build_helpers.zig',
      'link_live_file docs/index.html',
      'link_live_file docs/package.json',
      'link_live_file docs/package-lock.json',
    ])
    expect(entrypoint).toContain('ln -s "$source" "$target"')
    const smoke = read('scripts/smoke-development-container.mjs')
    expect(smoke).toContain("fs.appendFileSync(path.join(liveWorkspace, 'build.zig')")
    expect(smoke).toContain("logs.includes('Changed: build.zig')")
    expect(smoke).toContain('rebuilds.length >= 2')
    expect(smoke).toContain("process.once('SIGINT', handleSigint)")
    expect(smoke).toContain("process.once('SIGTERM', handleSigterm)")
  })

  it('refreshes a persistent dependency volume whenever its package inputs change', () => {
    const dockerfile = read('Dockerfile')
    const entrypoint = read('entrypoint.sh')

    expect(dockerfile).toContain('sha256sum package.json package-lock.json | sha256sum')
    expect(entrypoint).toContain('sha256sum package.json package-lock.json | sha256sum')
    expect(entrypoint).toContain('npm ci --ignore-scripts')
    expect(entrypoint).toContain('if [ "$actual" != "$expected" ]')
    expect(entrypoint).toContain('mv -f "$temporary" "$marker"')
  })

  it('starts Vite only after the initial Zig binary is built and published', () => {
    const source = read('dev.js')

    expect(source.indexOf('const initialBuild = await rebuildZig()')).toBeLessThan(
      source.indexOf('viteProcess = startVite()'),
    )
    expect(source).toContain("const READY_PATH = path.join(ROOT, 'bin', '.zigcss-dev-ready')")
    expect(source).toContain("const BINARY_NAME = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'")
    expect(source).toContain('removeReadyMarker();')
    expect(source).toContain('fs.rmSync(READY_PATH, { force: true })')
    expect(source).toContain('removeReadyMarkerForShutdown();')
    expect(source).toContain('publishBuiltBinary();')
    expect(source).toContain("for (const filename of ['build.zig', 'build.zig.zon', 'build_helpers.zig'])")
    expect(source).toContain("fs.watchFile(inputPath, { interval: 500, persistent: true }, listener)")
    expect(source).toContain('fs.unwatchFile(inputPath, listener)')
    const vite = read('docs/vite.config.ts')
    expect(vite).toContain("const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'")
    expect(vite).toContain('if (configured === dockerBinDirectory) return dockerBinDirectory')
    expect(vite).toContain('ZIGCSS_DEV_BIN_DIRECTORY must be ${dockerBinDirectory} or the repository bin directory')
    expect(vite).not.toContain('fs.watch(configuredBinDirectory')
    expect(vite).toContain('preserveSymlinks: true')
    expect(vite).toContain("error.code === 'ENOENT') return")
    expect(vite).toContain('zigcss binary directory must be a real directory')
    expect(vite).toContain('zigcss binary watcher failed to start')
    expect(vite).toContain('fs.watch(binDirectory')
    expect(vite).toContain('void server.close()')
  })

  it.skipIf(process.platform === 'win32')('propagates a nonzero Vite exit instead of reporting success', () => {
    const root = developmentFixture()
    try {
      executable(path.join(root, 'commands', 'npm'), '#!/bin/sh\nexit 23\n')
      const result = runDevelopmentFixture(root, ['--no-zig'])

      expect(result.error).toBeUndefined()
      expect(result.signal).toBeNull()
      expect(result.status).toBe(23)
      expect(`${result.stdout}\n${result.stderr}`).toContain('Vite exited with code 23')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  it.skipIf(process.platform === 'win32')('clears stale compiler readiness in explicit website-only mode', () => {
    const root = developmentFixture()
    try {
      fs.mkdirSync(path.join(root, 'bin'))
      fs.writeFileSync(path.join(root, 'bin', '.zigcss-dev-ready'), 'stale\n')
      executable(path.join(root, 'commands', 'npm'), [
        '#!/bin/sh',
        'test ! -e ../bin/.zigcss-dev-ready || exit 44',
        'printf clean > "$ZIGCSS_TEST_NPM_MARKER"',
        'exit 0',
        '',
      ].join('\n'))
      const result = runDevelopmentFixture(root, ['--no-zig'])

      expect(result.error).toBeUndefined()
      expect(result.signal).toBeNull()
      expect(result.status).toBe(0)
      expect(fs.readFileSync(path.join(root, 'npm-launched'), 'utf8')).toBe('clean')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  it.skipIf(process.platform === 'win32')('does not start Vite after a failed initial Zig build', () => {
    const root = developmentFixture()
    try {
      executable(path.join(root, 'commands', 'zig'), '#!/bin/sh\nexit 19\n')
      executable(path.join(root, 'commands', 'npm'), '#!/bin/sh\nprintf launched > "$ZIGCSS_TEST_NPM_MARKER"\nexit 0\n')
      const result = runDevelopmentFixture(root)

      expect(result.error).toBeUndefined()
      expect(result.signal).toBeNull()
      expect(result.status).toBe(19)
      expect(fs.existsSync(path.join(root, 'npm-launched'))).toBe(false)
      expect(`${result.stdout}\n${result.stderr}`).toContain('docs server was not started')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  it.skipIf(process.platform === 'win32')('fails closed when a stale readiness marker cannot be removed', () => {
    const root = developmentFixture()
    const bin = path.join(root, 'bin')
    try {
      fs.mkdirSync(bin)
      fs.mkdirSync(path.join(bin, '.zigcss-dev-ready'))
      executable(path.join(root, 'commands', 'zig'), '#!/bin/sh\nexit 0\n')
      executable(path.join(root, 'commands', 'npm'), '#!/bin/sh\nprintf launched > "$ZIGCSS_TEST_NPM_MARKER"\nexit 0\n')
      const result = runDevelopmentFixture(root)

      expect(result.error).toBeUndefined()
      expect(result.signal).toBeNull()
      expect(result.status).toBe(1)
      expect(fs.existsSync(path.join(root, 'npm-launched'))).toBe(false)
      expect(`${result.stdout}\n${result.stderr}`).toMatch(/directory|EISDIR|EPERM/i)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  it.skipIf(process.platform === 'win32')('publishes compiler readiness before launching Vite', () => {
    const root = developmentFixture()
    try {
      executable(path.join(root, 'commands', 'zig'), [
        '#!/bin/sh',
        'mkdir -p zig-out/bin',
        "printf '#!/bin/sh\\nexit 0\\n' > zig-out/bin/zigcss",
        'chmod 755 zig-out/bin/zigcss',
        'exit 0',
        '',
      ].join('\n'))
      executable(path.join(root, 'commands', 'npm'), [
        '#!/bin/sh',
        'test -f ../bin/.zigcss-dev-ready || exit 41',
        'test -x ../bin/zigcss || exit 42',
        'printf launched > "$ZIGCSS_TEST_NPM_MARKER"',
        'exit 0',
        '',
      ].join('\n'))
      const result = runDevelopmentFixture(root)

      expect(result.error).toBeUndefined()
      expect(result.signal).toBeNull()
      expect(result.status).toBe(0)
      expect(fs.readFileSync(path.join(root, 'npm-launched'), 'utf8')).toBe('launched')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })
})
