import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  compareReleaseVersionPrecedence,
  parseReleaseVersion,
  readReleaseSources,
  releaseSourcePaths,
  repositoryRoot,
  unreleasedSectionHasMaterialChanges,
  validateReleaseSources,
  validateReleaseTag,
  validateReleaseVersion,
} from './validate-release-version.mjs'

const activeVersion = '0.7.0-rc.1'
const activeBaseVersion = '0.7.0'
const publishedStableVersion = '0.6.0'
const synchronizedSurfaceCount = 45

function cloneSources() {
  return new Map(readReleaseSources())
}

function replace(sources, filename, current, replacement) {
  const source = sources.get(filename)
  const updated = source.replace(current, replacement)
  assert.notEqual(updated, source, `fixture replacement was not found in ${filename}`)
  sources.set(filename, updated)
}

function mutateJson(sources, filename, mutate) {
  const value = JSON.parse(sources.get(filename))
  mutate(value)
  sources.set(filename, `${JSON.stringify(value, null, 2)}\n`)
}

function setActiveSourceVersion(sources, version) {
  const previousVersion = sources.get('VERSION').trim()
  const previousBaseVersion = parseReleaseVersion(previousVersion).base
  const baseVersion = parseReleaseVersion(version).base
  sources.set('VERSION', `${version}\n`)

  mutateJson(sources, 'package.json', manifest => { manifest.version = version })
  mutateJson(sources, 'package-lock.json', lock => {
    lock.version = version
    lock.packages[''].version = version
  })
  mutateJson(sources, 'docs/package-lock.json', lock => { lock.packages['..'].version = version })
  mutateJson(sources, 'vscode-extension/package.json', manifest => { manifest.version = baseVersion })
  mutateJson(sources, 'vscode-extension/package-lock.json', lock => {
    lock.version = baseVersion
    lock.packages[''].version = baseVersion
  })
  mutateJson(sources, 'docs/src/data/capabilities.json', metadata => {
    const zigPackage = metadata.capabilities.find(capability => capability.id === 'zig-package')
    const vscode = metadata.capabilities.find(capability => capability.id === 'vscode')
    assert.ok(zigPackage)
    assert.ok(vscode)
    zigPackage.behavior = zigPackage.behavior.replace(
      `Package \`zigcss\` ${previousVersion}`,
      `Package \`zigcss\` ${version}`,
    )
    vscode.behavior = vscode.behavior.replace(
      `current source extension is Marketplace-compatible package version ${previousBaseVersion} mapped to core ${previousVersion}`,
      `current source extension is Marketplace-compatible package version ${baseVersion} mapped to core ${version}`,
    )
  })

  replace(sources, 'build.zig.zon', `.version = "${previousVersion}"`, `.version = "${version}"`)
  const main = sources.get('src/main.zig').replaceAll(previousVersion, version)
  sources.set(
    'src/main.zig',
    parseReleaseVersion(version).prerelease === null
      ? main.replace('experimental release candidate', 'source build')
      : main,
  )
  const audit = sources.get('tests/regressions/audit.zig')
  sources.set('tests/regressions/audit.zig', audit.replaceAll(previousVersion, version))
  for (const filename of ['Dockerfile', 'Dockerfile.docs', 'Dockerfile.release']) {
    replace(sources, filename, `ARG ZIGCSS_VERSION=${previousVersion}`, `ARG ZIGCSS_VERSION=${version}`)
  }
  replace(
    sources,
    'docs/src/content/docs/guide/build-from-source.md',
    `package \`zigcss\` ${previousVersion}`,
    `package \`zigcss\` ${version}`,
  )
  const neovim = sources.get('neovim-config/README.md')
  sources.set('neovim-config/README.md', neovim.replaceAll(`ZigCSS ${previousVersion}`, `ZigCSS ${version}`))
  replace(
    sources,
    'README.md',
    `> **Active source candidate: ${previousVersion} — unpublished.**`,
    `> **Active source candidate: ${version} — unpublished.**`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    `Active source candidate ${previousVersion} is selected`,
    `Active source candidate ${version} is selected`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/builder-integrations.md',
    `The current unpublished ${previousVersion} source checkout has`,
    `The current unpublished ${version} source checkout has`,
  )
  replace(
    sources,
    'docs/src/app/components/Home.tsx',
    `${previousVersion} · unpublished source proofs`,
    `${version} · unpublished source proofs`,
  )
}

test('all release, package, runtime, editor, container, formula, and documentation versions agree', () => {
  assert.deepEqual(validateReleaseVersion(), {
    version: activeVersion,
    vscodeVersion: activeBaseVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
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

test('Semantic Versioning precedence is exact across stable, prerelease, and large numeric identifiers', () => {
  assert.equal(compareReleaseVersionPrecedence('0.7.0-rc.1', '0.6.0'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0-rc.2', '0.6.0'), -1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0-rc.10', '0.6.0-rc.2'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0', '0.6.0-rc.999'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0+new-build', '0.6.0+old-build'), 0)
  assert.equal(
    compareReleaseVersionPrecedence('9007199254740993.0.0', '9007199254740992.999.999'),
    1,
  )
})

test('[Unreleased] material-change detection ignores headings, comments, and explicit empty markers', () => {
  assert.equal(unreleasedSectionHasMaterialChanges(`
## [Unreleased]

No later stable identity is selected.

### Added

<!-- reserved for the next release -->

## [0.6.0] - 2026-08-18
`), false)
  assert.equal(unreleasedSectionHasMaterialChanges(`
## [Unreleased]

### Changed

- Add one verified behavior.

## [0.6.0] - 2026-08-18
`), true)
  assert.throws(
    () => unreleasedSectionHasMaterialChanges('## [Unreleased]\n\n## [Unreleased]\n'),
    /exactly one \[Unreleased\] section/,
  )
})

test('material Unreleased changes require an active identity beyond published stable', () => {
  const equalStable = cloneSources()
  setActiveSourceVersion(equalStable, publishedStableVersion)
  assert.throws(
    () => validateReleaseSources(equalStable),
    /active source version 0\.6\.0 must advance beyond published stable 0\.6\.0 because \[Unreleased\] contains material changes/,
  )

  const equalPrecedence = cloneSources()
  setActiveSourceVersion(equalPrecedence, '0.6.0+local')
  assert.throws(
    () => validateReleaseSources(equalPrecedence),
    /must advance beyond published stable 0\.6\.0 because \[Unreleased\] contains material changes/,
  )

  const emptyUnreleased = cloneSources()
  setActiveSourceVersion(emptyUnreleased, publishedStableVersion)
  emptyUnreleased.set(
    'CHANGELOG.md',
    emptyUnreleased.get('CHANGELOG.md').replace(
      /## \[Unreleased\][\s\S]*?(?=## \[0\.6\.0\])/,
      '## [Unreleased]\n\nNo later stable identity is selected.\n\n',
    ),
  )
  assert.deepEqual(validateReleaseSources(emptyUnreleased), {
    version: publishedStableVersion,
    vscodeVersion: publishedStableVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  })
})

test('active source may advance without rewriting immutable published-stable evidence', () => {
  const future = cloneSources()
  setActiveSourceVersion(future, '0.8.0-rc.1')

  assert.deepEqual(validateReleaseSources(future), {
    version: '0.8.0-rc.1',
    vscodeVersion: '0.8.0',
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  })
  assert.match(future.get('release/stable-promotion.json'), /"candidateVersion": "0\.6\.0"/)
  assert.match(future.get('Formula/zigcss.rb'), /version "0\.6\.0"/)
  assert.match(future.get('README.md'), /Stable package identity: 0\.6\.0/)

  const rollback = cloneSources()
  setActiveSourceVersion(rollback, '0.5.9')
  assert.throws(
    () => validateReleaseSources(rollback),
    /active source version 0\.5\.9 is older than published stable 0\.6\.0/,
  )
})

test('active and published-stable documentation boundaries fail closed independently', () => {
  const missingReadmeBoundary = cloneSources()
  replace(
    missingReadmeBoundary,
    'README.md',
    'Active source versioning is independent of immutable published-stable evidence',
    'Source and stable versions are unrelated',
  )
  assert.throws(() => validateReleaseSources(missingReadmeBoundary), /README active versus published version boundary/)

  const missingStatusBoundary = cloneSources()
  replace(
    missingStatusBoundary,
    'docs/src/content/docs/guide/status.md',
    'The active source version may advance without rewriting that immutable publication record or the verified Homebrew formula',
    'The source can advance',
  )
  assert.throws(() => validateReleaseSources(missingStatusBoundary), /status guide active versus published version boundary/)

  const staleStatusGateProgress = cloneSources()
  replace(
    staleStatusGateProgress,
    'docs/src/content/docs/guide/status.md',
    '5 of 8 admission gates now carry recorded evidence',
    '4 of 8 admission gates now carry recorded evidence',
  )
  assert.throws(() => validateReleaseSources(staleStatusGateProgress), /status guide candidate gate progress/)

  const staleHomeGateProgress = cloneSources()
  replace(
    staleHomeGateProgress,
    'docs/src/app/components/Home.tsx',
    '5/8 admission gates verified',
    '4/8 admission gates verified',
  )
  assert.throws(() => validateReleaseSources(staleHomeGateProgress), /home candidate gate progress/)

  const missingCssStableBoundary = cloneSources()
  replace(
    missingCssStableBoundary,
    'docs/src/content/docs/guide/css-compatibility.md',
    'Published stable 0.6.0 predates this parser contract',
    'The published package has this parser contract',
  )
  assert.throws(() => validateReleaseSources(missingCssStableBoundary), /CSS guide published stable boundary/)

  const futurePublishedClaimDrift = cloneSources()
  setActiveSourceVersion(futurePublishedClaimDrift, '0.8.0-rc.1')
  replace(futurePublishedClaimDrift, 'README.md', 'Stable package identity: 0.6.0', 'Stable package identity: 0.7.0')
  assert.throws(() => validateReleaseSources(futurePublishedClaimDrift), /README published stable identity header/)

  const futureActiveClaimDrift = cloneSources()
  setActiveSourceVersion(futureActiveClaimDrift, '0.8.0-rc.1')
  replace(futureActiveClaimDrift, 'docs/src/content/docs/guide/build-from-source.md', 'package `zigcss` 0.8.0-rc.1', 'package `zigcss` 0.6.0')
  assert.throws(() => validateReleaseSources(futureActiveClaimDrift), /build guide stable identity/)

  for (const filename of [
    'docs/src/content/docs/guide/builder-integrations.md',
    'examples/build-systems/README.md',
    'examples/next-turbopack/README.md',
    'examples/sveltekit/README.md',
    'examples/astro/README.md',
    'examples/nuxt/README.md',
    'examples/parcel/README.md',
  ]) {
    const builderDrift = cloneSources()
    replace(builderDrift, filename, '0.6.0', '9.9.9')
    assert.throws(
      () => validateReleaseSources(builderDrift),
      /builder guide published stable identity|README\.md published stable identity/,
      `${filename} must remain bound to immutable published stable evidence`,
    )
  }

  for (const filename of [
    'docs/src/content/docs/guide/builder-integrations.md',
    'examples/build-systems/README.md',
    'examples/next-turbopack/README.md',
    'examples/sveltekit/README.md',
    'examples/astro/README.md',
    'examples/nuxt/README.md',
    'examples/parcel/README.md',
  ]) {
    const toolchainDrift = cloneSources()
    replace(toolchainDrift, filename, '0.15.2', '0.14.0')
    assert.throws(
      () => validateReleaseSources(toolchainDrift),
      /minimum Zig version/,
      `${filename} must remain bound to build.zig.zon minimum Zig`,
    )
  }
})

test('manifest, lockfile, Zig, CLI, and Marketplace mapping drift fails closed', () => {
  const rootLock = cloneSources()
  replace(rootLock, 'package-lock.json', `"version": "${activeVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(rootLock), /root npm lock version/)

  const docsLock = cloneSources()
  replace(docsLock, 'docs/package-lock.json', `"version": "${activeVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(docsLock), /documentation linked ZigCSS version/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/package.json', `"version": "${activeBaseVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(vscode), /VS Code Marketplace package version/)

  const zig = cloneSources()
  replace(zig, 'build.zig.zon', `.version = "${activeVersion}"`, '.version = "9.9.9"')
  assert.throws(() => validateReleaseSources(zig), /Zig package version/)

  const cli = cloneSources()
  replace(cli, 'src/main.zig', `const version = "${activeVersion}";`, 'const version = "9.9.9";')
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
  replace(formula, 'Formula/zigcss.rb', 'version "0.6.0"', 'version "0.6.0-rc.2"')
  assert.throws(() => validateReleaseSources(formula), /Homebrew published stable version/)

  const formulaCommit = cloneSources()
  replace(formulaCommit, 'Formula/zigcss.rb', '6786655d66ca65c5a06421c8ed70d84183722dce', '0'.repeat(40))
  assert.throws(() => validateReleaseSources(formulaCommit), /Homebrew published stable source commit/)

  const formulaHash = cloneSources()
  replace(formulaHash, 'Formula/zigcss.rb', '059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010', '0'.repeat(64))
  assert.throws(() => validateReleaseSources(formulaHash), /Homebrew published stable source SHA-256/)

  const formulaToolchain = cloneSources()
  replace(formulaToolchain, 'Formula/zigcss.rb', 'depends_on "zig@0.15"', 'depends_on "zig"')
  assert.throws(() => validateReleaseSources(formulaToolchain), /Homebrew Zig dependency/)

  const homebrewGuide = cloneSources()
  replace(homebrewGuide, 'homebrew-install.md', 'stable ZigCSS `0.6.0`', 'stable ZigCSS `9.9.9`')
  assert.throws(() => validateReleaseSources(homebrewGuide), /Homebrew guide published stable identity/)

  const homebrewTapBoundary = cloneSources()
  replace(homebrewTapBoundary, 'homebrew-install.md', 'not a claim that a public Homebrew tap exists', 'available from the public Homebrew tap')
  assert.throws(() => validateReleaseSources(homebrewTapBoundary), /Homebrew guide tap boundary/)

  const npmBuildPreflight = cloneSources()
  replace(npmBuildPreflight, 'NPM_PUBLISH.md', 'successful same-repository `main` push run', 'successful fork pull-request run')
  assert.throws(() => validateReleaseSources(npmBuildPreflight), /npm publishing guide exact-SHA Build preflight/)

  const statusBuildPreflight = cloneSources()
  replace(statusBuildPreflight, 'docs/src/content/docs/guide/status.md', 'successful same-repository `main` push run', 'successful fork pull-request run')
  assert.throws(() => validateReleaseSources(statusBuildPreflight), /status exact-SHA Build preflight/)

  const docker = cloneSources()
  replace(docker, 'Dockerfile.docs', `ARG ZIGCSS_VERSION=${activeVersion}`, 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(docker), /Dockerfile\.docs product version/)

  const releaseDocker = cloneSources()
  replace(releaseDocker, 'Dockerfile.release', `ARG ZIGCSS_VERSION=${activeVersion}`, 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(releaseDocker), /Dockerfile\.release product version/)

  const changelog = cloneSources()
  replace(changelog, 'CHANGELOG.md', '## [0.6.0] - 2026-08-18', '## [9.9.9] - 2026-08-18')
  assert.throws(() => validateReleaseSources(changelog), /stable changelog target/)

  const docs = cloneSources()
  docs.set('README.md', docs.get('README.md').replaceAll('Stable package identity: 0.6.0', 'Stable package identity: 9.9.9'))
  assert.throws(() => validateReleaseSources(docs), /README published stable identity header/)

  const npmGuide = cloneSources()
  replace(npmGuide, 'NPM_PUBLISH.md', 'Stable `zigcss@0.6.0` is published on npm `latest`', 'Stable `zigcss@9.9.9` is published on npm `latest`')
  assert.throws(() => validateReleaseSources(npmGuide), /npm publishing guide stable identity/)

  const staticRoute = cloneSources()
  replace(staticRoute, 'docs/src/data/seo-routes.mjs', 'Install and run ZigCSS 0.6.0', 'Install and run ZigCSS 9.9.9')
  assert.throws(() => validateReleaseSources(staticRoute), /published static route identity/)
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

  const archivePolicy = cloneSources()
  replace(archivePolicy, 'package.json', 'scripts/create-release-archive.test.mjs ', '')
  assert.throws(() => validateReleaseSources(archivePolicy), /release archive and metadata policy test script/)
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
      version: activeVersion,
      vscodeVersion: activeBaseVersion,
      publishedStableVersion,
      surfaces: synchronizedSurfaceCount,
    })

    fs.writeFileSync(path.join(temporary, 'VERSION'), `${activeVersion}\r`)
    assert.throws(
      () => readReleaseSources(temporary),
      /VERSION contains an unsupported bare carriage return/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
