// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const read = (relativePath: string) =>
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

describe('experimental VS Code extension package', () => {
  test('pins synchronized identity and every direct dependency', () => {
    const root = JSON.parse(read('package.json'))
    const extension = JSON.parse(read('vscode-extension/package.json'))
    const lock = JSON.parse(read('vscode-extension/package-lock.json'))

    expect(extension.version).toBe(root.version.split('-')[0])
    expect(extension.preview).toBe(true)
    expect(root.scripts['test:vscode']).toContain('vscode-extension')
    expect(read('build.zig.zon')).toContain(`.version = "${root.version}"`)
    expect(lock.packages[''].version).toBe(extension.version)
    expect(extension.engines.vscode).toBe('^1.91.0')
    for (const [name, version] of Object.entries({
      ...extension.dependencies,
      ...extension.devDependencies,
    })) {
      expect(version).not.toMatch(/^[~^]/)
      expect(lock.packages[`node_modules/${name}`].version).toBe(version)
      expect(lock.packages[`node_modules/${name}`].integrity).toMatch(/^sha512-/)
    }
  })

  test('keeps activation, trust, and binary discovery fail-closed', () => {
    const manifest = JSON.parse(read('vscode-extension/package.json'))
    const extension = read('vscode-extension/src/extension.ts')
    const discovery = read('vscode-extension/src/binaryDiscovery.ts')
    const tests = read('vscode-extension/test/binaryDiscovery.test.cjs')

    expect(manifest.activationEvents).toEqual(['onLanguage:css'])
    expect(manifest.extensionKind).toEqual(['workspace'])
    expect(manifest.capabilities.untrustedWorkspaces.supported).toBe(false)
    expect(manifest.capabilities.virtualWorkspaces.supported).toBe(false)
    expect(extension).not.toContain('createFileSystemWatcher')
    expect(extension).toContain("{ scheme: 'file', language: 'css' }")
    expect(discovery).toContain("paths.isAbsolute(directory)")
    expect(discovery).toContain('fs.constants.X_OK')
    expect(discovery).not.toContain('workspaceFolders')
    expect(tests).toContain('real POSIX discovery requires a regular executable file')
    expect(tests).toContain('Windows discovery honors Path, PATHEXT')
  })

  test('builds and verifies one minimal temporary pre-release VSIX', () => {
    const manifest = JSON.parse(read('vscode-extension/package.json'))
    const verifier = read('vscode-extension/scripts/verify-package.mjs')
    const ignored = read('vscode-extension/.vscodeignore')

    expect(manifest.main).toBe('./dist/extension.js')
    expect(manifest.scripts.bundle).toContain('--external:vscode')
    expect(manifest.scripts['package:check']).toContain('verify-package.mjs')
    expect(verifier).toContain("'package.json'")
    expect(verifier).toContain("'README.md'")
    expect(verifier).toContain("'LICENSE'")
    expect(verifier).toContain("'THIRD_PARTY_NOTICES.md'")
    expect(verifier).toContain("'dist/extension.js'")
    expect(verifier).toContain("'--pre-release'")
    expect(verifier).toContain('2 * 1024 * 1024')
    expect(verifier).toContain('fs.rmSync(temporary')
    expect(ignored).toContain('node_modules/**')
    expect(ignored).toContain('!dist/extension.js')
  })

  test('runs reproducible tests and packaging in CI without publication', () => {
    const workflow = read('.github/workflows/build.yml')
    const release = read('.github/workflows/release.yml')
    const status = read('docs/src/content/docs/guide/status.md')
    const readme = read('vscode-extension/README.md')

    expect(workflow).toContain('node-version: 22')
    expect(workflow).toContain('vscode-extension/package-lock.json')
    expect(workflow).toContain('working-directory: vscode-extension')
    expect(workflow).toContain('npm test && npm run package:check')
    expect(release).not.toContain('vsce publish')
    expect(status).toContain('Thirteen cross-platform discovery')
    expect(status).toContain('No native binary enters the VSIX')
    expect(readme).toContain('It never publishes')
  })
})
