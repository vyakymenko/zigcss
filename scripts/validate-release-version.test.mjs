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
    version: '0.6.0',
    vscodeVersion: '0.6.0',
    surfaces: 34,
  })
})

test('canonical versions and release tags fail closed', () => {
  assert.deepEqual(parseReleaseVersion('0.6.0'), {
    value: '0.6.0',
    base: '0.6.0',
    prerelease: null,
    build: null,
  })
  assert.equal(parseReleaseVersion('0.6.0-rc.2').prerelease, 'rc.2')
  for (const invalid of ['v0.6.0', '0.6', '00.6.0', '0.6.0-01', '0.6.0-']) {
    assert.throws(() => parseReleaseVersion(invalid), /not canonical Semantic Versioning/)
  }
  assert.equal(validateReleaseTag('0.6.0', 'v0.6.0'), true)
  assert.throws(() => validateReleaseTag('0.6.0', 'v0.6.0-rc.2'), /release tag must be v0\.6\.0/)

})

test('manifest, lockfile, Zig, CLI, and Marketplace mapping drift fails closed', () => {
  const rootLock = cloneSources()
  replace(rootLock, 'package-lock.json', '"version": "0.6.0"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(rootLock), /root npm lock version/)

  const docsLock = cloneSources()
  replace(docsLock, 'docs/package-lock.json', '"version": "0.6.0"', '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(docsLock), /documentation linked ZigCSS version/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/package.json', '"version": "0.6.0"', '"version": "0.6.0-rc.2"')
  assert.throws(() => validateReleaseSources(vscode), /VS Code Marketplace package version/)

  const zig = cloneSources()
  replace(zig, 'build.zig.zon', '.version = "0.6.0"', '.version = "9.9.9"')
  assert.throws(() => validateReleaseSources(zig), /Zig package version/)

  const cli = cloneSources()
  replace(cli, 'src/main.zig', 'const version = "0.6.0";', 'const version = "9.9.9";')
  assert.throws(() => validateReleaseSources(cli), /CLI version constant/)

  const nativeCandidate = cloneSources()
  replace(nativeCandidate, 'tests/preprocessors/native/contract.json',
    '"candidateVersion": "0.6.0-rc.2"', '"candidateVersion": "0.6.0-rc.3"')
  assert.throws(() => validateReleaseSources(nativeCandidate), /native historical candidate version/)

  const closedInterlock = cloneSources()
  replace(closedInterlock, 'tests/preprocessors/native/contract.json',
    '"nativeReleaseReady": true', '"nativeReleaseReady": false')
  assert.throws(() => validateReleaseSources(closedInterlock), /native release interlock/)

  const missingGraduatedVersion = cloneSources()
  replace(missingGraduatedVersion, 'tests/preprocessors/native/contract.json',
    '"nativeReleaseVersion": "0.6.0-rc.2"', '"nativeReleaseVersion": null')
  assert.throws(() => validateReleaseSources(missingGraduatedVersion), /graduated native release version/)
})

test('Homebrew, Docker, changelog, and public claim drift fails closed', () => {
  const formula = cloneSources()
  replace(formula, 'Formula/zigcss.rb', 'version "0.5.0-rc.1"', 'version "0.6.0-rc.2"')
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
  replace(docker, 'Dockerfile.docs', 'ARG ZIGCSS_VERSION=0.6.0', 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(docker), /Dockerfile\.docs product version/)

  const releaseDocker = cloneSources()
  replace(releaseDocker, 'Dockerfile.release', 'ARG ZIGCSS_VERSION=0.6.0', 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(releaseDocker), /Dockerfile\.release product version/)

  const changelog = cloneSources()
  replace(changelog, 'CHANGELOG.md', '## [0.6.0] - 2026-08-18', '## [9.9.9] - 2026-08-18')
  assert.throws(() => validateReleaseSources(changelog), /stable changelog target/)

  const docs = cloneSources()
  docs.set('README.md', docs.get('README.md').replaceAll('Stable package identity: 0.6.0', 'Stable package identity: 9.9.9'))
  assert.throws(() => validateReleaseSources(docs), /README stable identity/)

  const npmGuide = cloneSources()
  replace(npmGuide, 'NPM_PUBLISH.md', 'Stable `zigcss@0.6.0` is published on npm `latest`', 'Stable `zigcss@9.9.9` is published on npm `latest`')
  assert.throws(() => validateReleaseSources(npmGuide), /npm publishing guide stable identity/)
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
  inventory.set('unowned-version.txt', '0.6.0\n')
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
      version: '0.6.0',
      vscodeVersion: '0.6.0',
      surfaces: 34,
    })

    fs.writeFileSync(path.join(temporary, 'VERSION'), '0.6.0\r')
    assert.throws(
      () => readReleaseSources(temporary),
      /VERSION contains an unsupported bare carriage return/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
