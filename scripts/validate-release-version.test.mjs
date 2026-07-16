import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  parseReleaseVersion,
  readReleaseSources,
  releaseSourcePaths,
  repositoryRoot,
  validateReleaseSources,
  validateReleaseTag,
  validateReleaseVersion,
} from './validate-release-version.mjs'

function cloneSources() {
  return new Map(readReleaseSources())
}

function replace(sources, filename, current, replacement) {
  const source = sources.get(filename)
  const updated = source.replace(current, replacement)
  assert.notEqual(updated, source, `fixture replacement was not found in ${filename}`)
  sources.set(filename, updated)
}

test('all release, package, runtime, editor, container, formula, and documentation versions agree', () => {
  assert.deepEqual(validateReleaseVersion(), {
    version: '0.4.0-rc.3',
    vscodeVersion: '0.4.0',
    surfaces: 28,
  })
})

test('canonical versions and release tags fail closed', () => {
  assert.deepEqual(parseReleaseVersion('0.4.0-rc.3'), {
    value: '0.4.0-rc.3',
    base: '0.4.0',
    prerelease: 'rc.3',
    build: null,
  })
  for (const invalid of ['v0.4.0', '0.4', '00.4.0', '0.4.0-01', '0.4.0-']) {
    assert.throws(() => parseReleaseVersion(invalid), /not canonical Semantic Versioning/)
  }
  assert.equal(validateReleaseTag('0.4.0-rc.3', 'v0.4.0-rc.3'), true)
  assert.throws(() => validateReleaseTag('0.4.0-rc.3', 'v0.4.0'), /release tag must be v0\.4\.0-rc\.3/)

  const plan = cloneSources()
  replace(plan, 'DEVELOPMENT_PLAN.md', 'Target: `0.4.0-rc.3`', 'Target: `0.4.0-rc.4`')
  assert.throws(() => validateReleaseSources(plan), /VERSION must be 0\.4\.0-rc\.4, received "0\.4\.0-rc\.3"/)
})

test('manifest, lockfile, Zig, CLI, and Marketplace mapping drift fails closed', () => {
  const rootLock = cloneSources()
  replace(rootLock, 'package-lock.json', '"version": "0.4.0-rc.3"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(rootLock), /root npm lock version/)

  const docsLock = cloneSources()
  replace(docsLock, 'docs/package-lock.json', '"version": "0.4.0-rc.3"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(docsLock), /documentation linked ZigCSS version/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/package.json', '"version": "0.4.0"', '"version": "0.4.0-rc.3"')
  assert.throws(() => validateReleaseSources(vscode), /VS Code Marketplace package version/)

  const zig = cloneSources()
  replace(zig, 'build.zig.zon', '.version = "0.4.0-rc.3"', '.version = "9.9.9"')
  assert.throws(() => validateReleaseSources(zig), /Zig package version/)

  const cli = cloneSources()
  replace(cli, 'src/main.zig', 'const version = "0.4.0-rc.3";', 'const version = "9.9.9";')
  assert.throws(() => validateReleaseSources(cli), /CLI version constant/)
})

test('Homebrew, Docker, changelog, and public claim drift fails closed', () => {
  const formula = cloneSources()
  replace(formula, 'Formula/zigcss.rb', 'version "0.4.0-rc.3"', 'version "0.4.0"')
  assert.throws(() => validateReleaseSources(formula), /Homebrew formula version/)

  const formulaCommit = cloneSources()
  replace(formulaCommit, 'Formula/zigcss.rb', '18deb7c34e5a2d13d57e07459138d925aed5a6e3', '0'.repeat(40))
  assert.throws(() => validateReleaseSources(formulaCommit), /Homebrew source commit/)

  const formulaHash = cloneSources()
  replace(formulaHash, 'Formula/zigcss.rb', 'f7dcb180bbe466f4f4269d699c56110889313c228723aedd1aed22b0c00a19b6', '0'.repeat(64))
  assert.throws(() => validateReleaseSources(formulaHash), /Homebrew source SHA-256/)

  const formulaToolchain = cloneSources()
  replace(formulaToolchain, 'Formula/zigcss.rb', 'depends_on "zig@0.15"', 'depends_on "zig"')
  assert.throws(() => validateReleaseSources(formulaToolchain), /Homebrew Zig dependency/)

  const docker = cloneSources()
  replace(docker, 'Dockerfile.docs', 'ARG ZIGCSS_VERSION=0.4.0-rc.3', 'ARG ZIGCSS_VERSION=0.4.0')
  assert.throws(() => validateReleaseSources(docker), /Dockerfile\.docs product version/)

  const releaseDocker = cloneSources()
  replace(releaseDocker, 'Dockerfile.release', 'ARG ZIGCSS_VERSION=0.4.0-rc.3', 'ARG ZIGCSS_VERSION=0.4.0')
  assert.throws(() => validateReleaseSources(releaseDocker), /Dockerfile\.release product version/)

  const changelog = cloneSources()
  replace(changelog, 'CHANGELOG.md', 'Target release: `0.4.0-rc.3`', 'Target release: `0.4.0`')
  assert.throws(() => validateReleaseSources(changelog), /unreleased changelog target/)

  const docs = cloneSources()
  replace(docs, 'README.md', 'ZigCSS 0.4.0-rc.3', 'ZigCSS 9.9.9')
  assert.throws(() => validateReleaseSources(docs), /README release claims/)

  const npmGuide = cloneSources()
  replace(npmGuide, 'NPM_PUBLISH.md', '0.4.0-rc.3', '9.9.9')
  assert.throws(() => validateReleaseSources(npmGuide), /npm publishing guide release claims/)
})

test('CI ordering, release-tag preflight, and VS Code prerelease packaging fail closed', () => {
  const build = cloneSources()
  replace(build, '.github/workflows/build.yml', '- name: Verify release version policy', '- name: Removed release version policy')
  assert.throws(() => validateReleaseSources(build), /before npm installation/)

  const release = cloneSources()
  replace(release, '.github/workflows/release.yml', 'npm run check:version -- --tag "$GITHUB_REF_NAME"', 'npm run check:version')
  assert.throws(() => validateReleaseSources(release), /before building any release artifact/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/scripts/verify-package.mjs', "    '--pre-release',\n", '')
  assert.throws(() => validateReleaseSources(vscode), /VS Code package verifier/)

  const inventory = cloneSources()
  inventory.set('unowned-version.txt', '0.4.0-rc.3\n')
  assert.throws(() => validateReleaseSources(inventory), /release surface inventory changed/)

  const npmPolicy = cloneSources()
  replace(npmPolicy, 'package.json', ' scripts/verify-npm-publication.test.mjs', '')
  assert.throws(() => validateReleaseSources(npmPolicy), /npm publication policy test script/)
})

test('release source inventory rejects symlink substitution', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-version-'))
  try {
    for (const relativePath of releaseSourcePaths) {
      const destination = path.join(temporary, relativePath)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      fs.copyFileSync(path.join(repositoryRoot, relativePath), destination)
    }

    const victim = path.join(temporary, 'VERSION')
    fs.rmSync(victim)
    fs.symlinkSync(path.join(repositoryRoot, 'VERSION'), victim)
    assert.throws(() => readReleaseSources(temporary), /VERSION must be a regular non-symlink file/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('release source inventory normalizes checkout CRLF and rejects bare carriage returns', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-version-crlf-'))
  try {
    for (const relativePath of releaseSourcePaths) {
      const destination = path.join(temporary, relativePath)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      const source = fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8')
      fs.writeFileSync(destination, source.replaceAll('\n', '\r\n'))
    }

    assert.deepEqual(validateReleaseVersion(temporary), {
      version: '0.4.0-rc.3',
      vscodeVersion: '0.4.0',
      surfaces: 28,
    })

    fs.writeFileSync(path.join(temporary, 'VERSION'), '0.4.0-rc.3\r')
    assert.throws(
      () => readReleaseSources(temporary),
      /VERSION contains an unsupported bare carriage return/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
