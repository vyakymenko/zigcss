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
    version: '0.5.0-rc.1',
    vscodeVersion: '0.5.0',
    surfaces: 28,
  })
})

test('canonical versions and release tags fail closed', () => {
  assert.deepEqual(parseReleaseVersion('0.5.0-rc.1'), {
    value: '0.5.0-rc.1',
    base: '0.5.0',
    prerelease: 'rc.1',
    build: null,
  })
  for (const invalid of ['v0.5.0', '0.5', '00.5.0', '0.5.0-01', '0.5.0-']) {
    assert.throws(() => parseReleaseVersion(invalid), /not canonical Semantic Versioning/)
  }
  assert.equal(validateReleaseTag('0.5.0-rc.1', 'v0.5.0-rc.1'), true)
  assert.throws(() => validateReleaseTag('0.5.0-rc.1', 'v0.5.0'), /release tag must be v0\.5\.0-rc\.1/)

  const plan = cloneSources()
  replace(plan, 'DEVELOPMENT_PLAN.md', 'Candidate: `0.5.0-rc.1`', 'Candidate: `0.5.0-rc.2`')
  assert.throws(() => validateReleaseSources(plan), /VERSION must be 0\.5\.0-rc\.2, received "0\.5\.0-rc\.1"/)
})

test('manifest, lockfile, Zig, CLI, and Marketplace mapping drift fails closed', () => {
  const rootLock = cloneSources()
  replace(rootLock, 'package-lock.json', '"version": "0.5.0-rc.1"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(rootLock), /root npm lock version/)

  const docsLock = cloneSources()
  replace(docsLock, 'docs/package-lock.json', '"version": "0.5.0-rc.1"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(docsLock), /documentation linked ZigCSS version/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/package.json', '"version": "0.5.0"', '"version": "0.5.0-rc.1"')
  assert.throws(() => validateReleaseSources(vscode), /VS Code Marketplace package version/)

  const zig = cloneSources()
  replace(zig, 'build.zig.zon', '.version = "0.5.0-rc.1"', '.version = "9.9.9"')
  assert.throws(() => validateReleaseSources(zig), /Zig package version/)

  const cli = cloneSources()
  replace(cli, 'src/main.zig', 'const version = "0.5.0-rc.1";', 'const version = "9.9.9";')
  assert.throws(() => validateReleaseSources(cli), /CLI version constant/)
})

test('Homebrew, Docker, changelog, and public claim drift fails closed', () => {
  const formula = cloneSources()
  replace(formula, 'Formula/zigcss.rb', 'version "0.5.0-rc.1"', 'version "0.5.0"')
  assert.throws(() => validateReleaseSources(formula), /Homebrew formula version/)

  const formulaCommit = cloneSources()
  replace(formulaCommit, 'Formula/zigcss.rb', '526002807edc856eb2dc391551ac3d5c1b77da00', '0'.repeat(40))
  assert.throws(() => validateReleaseSources(formulaCommit), /Homebrew source commit/)

  const formulaHash = cloneSources()
  replace(formulaHash, 'Formula/zigcss.rb', 'dbab9f777b795742716841354e0bfe30555cc1d54b21f2a446fdc7dc523e26b1', '0'.repeat(64))
  assert.throws(() => validateReleaseSources(formulaHash), /Homebrew source SHA-256/)

  const formulaToolchain = cloneSources()
  replace(formulaToolchain, 'Formula/zigcss.rb', 'depends_on "zig@0.15"', 'depends_on "zig"')
  assert.throws(() => validateReleaseSources(formulaToolchain), /Homebrew Zig dependency/)

  const docker = cloneSources()
  replace(docker, 'Dockerfile.docs', 'ARG ZIGCSS_VERSION=0.5.0-rc.1', 'ARG ZIGCSS_VERSION=0.5.0')
  assert.throws(() => validateReleaseSources(docker), /Dockerfile\.docs product version/)

  const releaseDocker = cloneSources()
  replace(releaseDocker, 'Dockerfile.release', 'ARG ZIGCSS_VERSION=0.5.0-rc.1', 'ARG ZIGCSS_VERSION=0.5.0')
  assert.throws(() => validateReleaseSources(releaseDocker), /Dockerfile\.release product version/)

  const changelog = cloneSources()
  replace(changelog, 'CHANGELOG.md', 'Target release: `0.5.0-rc.1`', 'Target release: `0.5.0`')
  assert.throws(() => validateReleaseSources(changelog), /unreleased changelog target/)

  const docs = cloneSources()
  replace(docs, 'README.md', 'Source candidate: 0.5.0-rc.1', 'Source candidate: 9.9.9')
  assert.throws(() => validateReleaseSources(docs), /README release claims/)

  const npmGuide = cloneSources()
  replace(npmGuide, 'NPM_PUBLISH.md', '0.5.0-rc.1', '9.9.9')
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
  inventory.set('unowned-version.txt', '0.5.0-rc.1\n')
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
      version: '0.5.0-rc.1',
      vscodeVersion: '0.5.0',
      surfaces: 28,
    })

    fs.writeFileSync(path.join(temporary, 'VERSION'), '0.5.0-rc.1\r')
    assert.throws(
      () => readReleaseSources(temporary),
      /VERSION contains an unsupported bare carriage return/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
