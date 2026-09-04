import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const homebrewStableSourceSha256 = '059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010'

export const releaseSourcePaths = Object.freeze([
  '.github/workflows/build.yml',
  '.github/workflows/release.yml',
  'CHANGELOG.md',
  'Dockerfile',
  'Dockerfile.docs',
  'Dockerfile.release',
  'Formula/zigcss.rb',
  'homebrew-install.md',
  'NPM_PUBLISH.md',
  'README.md',
  'VERSION',
  'build.zig.zon',
  'docs/index.html',
  'docs/package-lock.json',
  'docs/package.json',
  'docs/scripts/generate-seo-pages.mjs',
  'docs/src/app/components/BootSequence.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Home.tsx',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/build-from-source.md',
  'docs/src/content/docs/guide/css-compatibility.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/content/docs/guide/status.md',
  'docs/src/data/capabilities.json',
  'docs/src/data/seo-routes.mjs',
  'examples/build-systems/README.md',
  'examples/astro/README.md',
  'examples/next-turbopack/README.md',
  'examples/nuxt/README.md',
  'examples/parcel/README.md',
  'examples/sveltekit/README.md',
  'install.js',
  'neovim-config/README.md',
  'package-lock.json',
  'package.json',
  'release/next-release.json',
  'release/stable-promotion.json',
  'src/main.zig',
  'tests/preprocessors/native/contract.json',
  'tests/regressions/audit.zig',
  'vscode-extension/package-lock.json',
  'vscode-extension/package.json',
  'vscode-extension/scripts/verify-package.mjs',
])

const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/

function fail(message) {
  throw new Error(`release version integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function normalizeCheckoutText(source, relativePath) {
  const normalized = source.replaceAll('\r\n', '\n')
  if (normalized.includes('\r')) fail(`${relativePath} contains an unsupported bare carriage return`)
  return normalized
}

export function parseReleaseVersion(value, label = 'version') {
  if (typeof value !== 'string') fail(`${label} must be a string`)
  const match = value.match(semverPattern)
  if (match === null) fail(`${label} is not canonical Semantic Versioning: ${JSON.stringify(value)}`)
  return {
    value,
    base: `${match[1]}.${match[2]}.${match[3]}`,
    prerelease: match[4] ?? null,
    build: match[5] ?? null,
  }
}

function comparePrerelease(left, right) {
  if (left === right) return 0
  if (left === null) return 1
  if (right === null) return -1
  const leftParts = left.split('.')
  const rightParts = right.split('.')
  const length = Math.max(leftParts.length, rightParts.length)
  for (let index = 0; index < length; index += 1) {
    const leftPart = leftParts[index]
    const rightPart = rightParts[index]
    if (leftPart === undefined) return -1
    if (rightPart === undefined) return 1
    if (leftPart === rightPart) continue
    const leftNumeric = /^\d+$/.test(leftPart)
    const rightNumeric = /^\d+$/.test(rightPart)
    if (leftNumeric && rightNumeric) {
      const leftNumber = BigInt(leftPart)
      const rightNumber = BigInt(rightPart)
      if (leftNumber !== rightNumber) return leftNumber < rightNumber ? -1 : 1
      continue
    }
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
    return leftPart < rightPart ? -1 : 1
  }
  return 0
}

export function compareReleaseVersionPrecedence(leftValue, rightValue) {
  const left = parseReleaseVersion(leftValue, 'left release version')
  const right = parseReleaseVersion(rightValue, 'right release version')
  const leftBase = left.base.split('.').map(BigInt)
  const rightBase = right.base.split('.').map(BigInt)
  for (let index = 0; index < leftBase.length; index += 1) {
    if (leftBase[index] !== rightBase[index]) return leftBase[index] < rightBase[index] ? -1 : 1
  }
  return comparePrerelease(left.prerelease, right.prerelease)
}

export function validateReleaseTag(version, tag) {
  const expected = `v${version}`
  if (tag !== expected) fail(`release tag must be ${expected}, received ${JSON.stringify(tag)}`)
  return true
}

function parseJson(sources, filename) {
  try {
    return JSON.parse(sources.get(filename))
  } catch (error) {
    fail(`${filename} is not valid JSON: ${error.message}`)
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label} must be ${expected}, received ${JSON.stringify(actual)}`)
}

function expectContains(source, fragment, label) {
  if (!source.includes(fragment)) fail(`${label} is missing ${JSON.stringify(fragment)}`)
}

function expectNotContains(source, fragment, label) {
  if (source.includes(fragment)) fail(`${label} contains ${JSON.stringify(fragment)}`)
}

function expectLiteralCount(source, literal, expected, label) {
  const actual = source.split(literal).length - 1
  if (actual !== expected) fail(`${label} must contain ${JSON.stringify(literal)} ${expected} times, received ${actual}`)
}

function singleCapture(source, expression, label) {
  const matches = [...source.matchAll(expression)]
  if (matches.length !== 1) fail(`${label} must occur exactly once, received ${matches.length}`)
  return matches[0][1]
}

const emptyUnreleasedMarkers = new Set([
  'No later stable identity is selected.',
  'No changes yet.',
  'Nothing yet.',
])

export function unreleasedSectionHasMaterialChanges(changelog) {
  if (typeof changelog !== 'string') fail('CHANGELOG.md must be text')
  const headings = [...changelog.matchAll(/^## \[Unreleased\][ \t]*$/gm)]
  if (headings.length !== 1) {
    fail(`CHANGELOG.md must contain exactly one [Unreleased] section, received ${headings.length}`)
  }

  const remainder = changelog.slice(headings[0].index + headings[0][0].length)
  const nextReleaseHeading = remainder.search(/^## (?!#)/m)
  const section = (nextReleaseHeading === -1 ? remainder : remainder.slice(0, nextReleaseHeading))
    .replace(/<!--[\s\S]*?-->/g, '')

  return section.split('\n').some(line => {
    const normalized = line.trim()
    if (normalized === '' || /^###(?:\s|$)/.test(normalized)) return false
    return !emptyUnreleasedMarkers.has(normalized)
  })
}

export function validateReleaseSources(sources) {
  const actualPaths = [...sources.keys()].sort()
  const expectedPaths = [...releaseSourcePaths].sort()
  if (!same(actualPaths, expectedPaths)) {
    fail(`release surface inventory changed: expected ${JSON.stringify(expectedPaths)}, received ${JSON.stringify(actualPaths)}`)
  }

  const canonicalText = sources.get('VERSION')
  if (!canonicalText.endsWith('\n') || canonicalText.trim() + '\n' !== canonicalText) {
    fail('VERSION must contain exactly one canonical version and a final newline')
  }
  const parsed = parseReleaseVersion(canonicalText.trim(), 'VERSION')
  const version = parsed.value
  const vscodeVersion = parsed.base

  const rootManifest = parseJson(sources, 'package.json')
  const rootLock = parseJson(sources, 'package-lock.json')
  const docsManifest = parseJson(sources, 'docs/package.json')
  const docsLock = parseJson(sources, 'docs/package-lock.json')
  const vscodeManifest = parseJson(sources, 'vscode-extension/package.json')
  const vscodeLock = parseJson(sources, 'vscode-extension/package-lock.json')
  const nativeContract = parseJson(sources, 'tests/preprocessors/native/contract.json')
  const nextRelease = parseJson(sources, 'release/next-release.json')
  const stablePromotion = parseJson(sources, 'release/stable-promotion.json')
  const historicalCandidate = nativeContract.releaseGraduation?.candidateVersion
  parseReleaseVersion(historicalCandidate, 'native historical candidate')
  const publishedStable = parseReleaseVersion(
    stablePromotion.candidateVersion,
    'published stable version',
  )
  const publishedStableVersion = publishedStable.value
  const publishedMarketplaceVersion = publishedStable.base
  const plannedCandidate = parseReleaseVersion(
    nextRelease.candidateVersion,
    'planned release candidate version',
  )

  expectEqual(rootManifest.name, 'zigcss', 'root npm package name')
  expectEqual(rootManifest.version, version, 'root npm package version')
  expectEqual(rootLock.version, version, 'root npm lock version')
  expectEqual(rootLock.packages?.['']?.version, version, 'root npm lock package version')
  expectEqual(docsManifest.dependencies?.zigcss, 'file:..', 'documentation ZigCSS dependency')
  expectEqual(docsLock.packages?.['..']?.version, version, 'documentation linked ZigCSS version')
  expectEqual(vscodeManifest.version, vscodeVersion, 'VS Code Marketplace package version')
  expectEqual(vscodeManifest.preview, true, 'VS Code preview marker')
  expectEqual(vscodeLock.version, vscodeVersion, 'VS Code lock version')
  expectEqual(vscodeLock.packages?.['']?.version, vscodeVersion, 'VS Code lock package version')
  expectEqual(nativeContract.referenceCandidate, '0.5.0-rc.1', 'native reference candidate')
  expectEqual(stablePromotion.previousPrerelease?.version, historicalCandidate, 'native historical candidate version')
  expectEqual(nativeContract.releaseGraduation?.candidateTag, `v${historicalCandidate}`, 'native historical candidate tag')
  expectEqual(
    nativeContract.releaseGraduation?.gates?.find(gate => gate.id === 'immutable-candidate')?.state,
    'verified',
    'native immutable candidate gate',
  )
  expectEqual(
    nativeContract.releaseGraduation?.gates?.find(gate => gate.id === 'local-validation')?.state,
    'verified',
    'native local validation gate',
  )
  expectEqual(nativeContract.state, 'native-graduated', 'native migration state')
  expectEqual(nativeContract.nativeReleaseReady, true, 'native release interlock')
  expectEqual(nativeContract.nativeReleaseVersion, historicalCandidate, 'graduated native release version')
  expectEqual(nativeContract.releaseGraduation?.state, 'closed', 'native release candidate state')
  expectEqual(nativeContract.releaseGraduation?.packageState, 'verified', 'native publication state')
  if (publishedStable.prerelease !== null || publishedStable.build !== null) {
    fail('published stable version must not contain prerelease or build metadata')
  }
  expectEqual(stablePromotion.ownerPackage, 'REL-010', 'published stable owner package')
  expectEqual(stablePromotion.releaseGapFamily, 'stable-release-promotion', 'published stable release family')
  expectEqual(stablePromotion.state, 'closed', 'published stable promotion state')
  expectEqual(stablePromotion.packageState, 'verified', 'published stable package state')
  expectEqual(stablePromotion.candidateTag, `v${publishedStableVersion}`, 'published stable tag')
  expectEqual(stablePromotion.publicationEvidence?.npmVersion, publishedStableVersion, 'published stable npm version')
  expectEqual(stablePromotion.publicationEvidence?.npmLatest, publishedStableVersion, 'published stable npm latest')
  if (!/^[0-9a-f]{40}$/.test(stablePromotion.publicationEvidence?.tagCommit ?? '')) {
    fail('published stable tag commit must be one canonical lowercase SHA-1 identity')
  }
  if (compareReleaseVersionPrecedence(version, publishedStableVersion) < 0) {
    fail(`active source version ${version} is older than published stable ${publishedStableVersion}`)
  }
  expectEqual(nextRelease.ownerPackage, 'REL-011', 'planned release owner package')
  expectEqual(nextRelease.releaseGapFamily, 'next-release-candidate', 'planned release family')
  expectEqual(nextRelease.candidateVersion, '0.7.0-rc.1', 'planned release candidate version')
  expectEqual(nextRelease.candidateTag, `v${plannedCandidate.value}`, 'planned release candidate tag')
  if (plannedCandidate.prerelease === null || plannedCandidate.build !== null) {
    fail('planned release candidate must be a prerelease without build metadata')
  }
  if (compareReleaseVersionPrecedence(plannedCandidate.value, publishedStableVersion) <= 0) {
    fail('planned release candidate must be newer than published stable')
  }
  if (nextRelease.candidateReady === true) {
    expectEqual(version, plannedCandidate.value, 'publication-ready active source version')
  }
  expectEqual(nativeContract.adapters?.length, 5, 'native adapter inventory')
  for (const adapter of nativeContract.adapters ?? []) {
    expectEqual(adapter.current, 'native-graduated', `${adapter.id} native adapter state`)
  }
  expectEqual(
    nativeContract.releaseGraduation?.gates?.find(gate => gate.id === 'tag-workflow-publication')?.state,
    'verified',
    'native tag workflow publication gate',
  )

  expectEqual(
    rootManifest.scripts?.['check:version'],
    'node scripts/validate-release-version.mjs --check',
    'version check script',
  )
  expectEqual(
    rootManifest.scripts?.['test:version'],
    'node --test scripts/validate-release-version.test.mjs',
    'version test script',
  )
  expectEqual(
    rootManifest.scripts?.['test:npm-publication'],
    'node --test scripts/check-npm-version-availability.test.mjs scripts/npm-package-artifact.test.mjs scripts/smoke-public-delivery.test.mjs scripts/verify-npm-publication.test.mjs',
    'npm publication policy test script',
  )
  expectEqual(
    rootManifest.scripts?.['test:release-metadata'],
    'node --test scripts/create-release-archive.test.mjs scripts/generate-release-metadata.test.mjs',
    'release archive and metadata policy test script',
  )
  expectEqual(
    rootManifest.scripts?.['check:stable-release'],
    'node scripts/validate-stable-release.mjs --check',
    'stable release check script',
  )
  expectEqual(
    rootManifest.scripts?.['test:stable-release'],
    'node --test scripts/validate-stable-release.test.mjs',
    'stable release test script',
  )

  const zon = sources.get('build.zig.zon')
  const zigVersion = singleCapture(zon, /^\s*\.version\s*=\s*"([^"]+)",$/gm, 'Zig package version')
  expectEqual(zigVersion, version, 'Zig package version')
  const minimumZigVersion = singleCapture(zon, /^\s*\.minimum_zig_version\s*=\s*"([^"]+)",$/gm, 'minimum Zig version')
  expectEqual(minimumZigVersion, '0.15.2', 'minimum Zig version')

  const main = sources.get('src/main.zig')
  const cliVersion = singleCapture(main, /^const version = "([^"]+)";$/gm, 'CLI version constant')
  expectEqual(cliVersion, version, 'CLI version constant')
  if (parsed.prerelease === null) {
    expectNotContains(main, 'experimental release candidate', 'stable CLI')
    expectContains(main, 'std.fmt.comptimePrint("ZigCSS {s} native stylesheet compiler', 'stable CLI help')
  } else {
    expectContains(main, '"Warning: ZigCSS {s} is an experimental release candidate', 'CLI warning')
  }
  expectContains(sources.get('tests/regressions/audit.zig'), `"zigcss ${version}\\n"`, 'CLI version regression')
  expectContains(sources.get('install.js'), "const VERSION = require('./package.json').version", 'npm installer')

  const formula = sources.get('Formula/zigcss.rb')
  const formulaCommit = singleCapture(
    formula,
    /url "https:\/\/github\.com\/vyakymenko\/zigcss\/archive\/([0-9a-f]{40})\.tar\.gz"/g,
    'Homebrew source commit',
  )
  const formulaVersion = singleCapture(formula, /^\s*version "([^"]+)"$/gm, 'Homebrew formula version')
  const formulaSha256 = singleCapture(formula, /^\s*sha256 "([0-9a-f]{64})"$/gm, 'Homebrew source SHA-256')
  expectEqual(formulaCommit, stablePromotion.publicationEvidence.tagCommit, 'Homebrew published stable source commit')
  expectEqual(formulaVersion, publishedStableVersion, 'Homebrew published stable version')
  expectEqual(formulaSha256, homebrewStableSourceSha256, 'Homebrew published stable source SHA-256')
  expectLiteralCount(formula, '  depends_on "zig@0.15" => :build', 1, 'Homebrew Zig dependency')
  expectLiteralCount(
    formula,
    '    system formula_opt_bin("zig@0.15")/"zig", "build", "-Doptimize=ReleaseFast"',
    1,
    'Homebrew build command',
  )
  expectContains(formula, 'assert_equal "zigcss #{version}\\n", shell_output("#{bin}/zigcss --version")', 'Homebrew version test')
  expectContains(formula, 'assert_equal ".test{color:red}", shell_output("#{bin}/zigcss test.css --minify")', 'Homebrew compile test')
  if (/^\s*head\s/m.test(formula)) fail('Homebrew formula must not expose an unverified head build')

  for (const filename of ['Dockerfile', 'Dockerfile.docs', 'Dockerfile.release']) {
    const dockerfile = sources.get(filename)
    const dockerVersion = singleCapture(dockerfile, /^ARG ZIGCSS_VERSION=(\S+)$/gm, `${filename} product version`)
    expectEqual(dockerVersion, version, `${filename} product version`)
    expectContains(dockerfile, 'org.opencontainers.image.version="${ZIGCSS_VERSION}"', `${filename} OCI label`)
  }

  const capabilityMetadata = parseJson(sources, 'docs/src/data/capabilities.json')
  const capabilityById = new Map(capabilityMetadata.capabilities.map(capability => [capability.id, capability]))
  expectContains(capabilityById.get('zig-package')?.behavior ?? '', `Package \`zigcss\` ${version}`, 'Zig package capability')
  const vscodeBehavior = capabilityById.get('vscode')?.behavior ?? ''
  expectContains(vscodeBehavior, `Marketplace-compatible package version ${publishedMarketplaceVersion}`, 'published VS Code capability')
  expectContains(vscodeBehavior, `core ${historicalCandidate}`, 'VS Code capability')
  expectContains(vscodeBehavior, `current source extension is Marketplace-compatible package version ${vscodeVersion}`, 'active VS Code capability')
  expectContains(vscodeBehavior, `core ${version}`, 'active VS Code core mapping')
  expectContains(vscodeBehavior, 'pre-release marker', 'VS Code capability')
  expectEqual(capabilityMetadata.gates?.['release-version']?.command, 'npm run check:version', 'release-version evidence gate')

  const readme = sources.get('README.md')
  const status = sources.get('docs/src/content/docs/guide/status.md')
  expectContains(
    readme,
    `> **Stable package identity: ${publishedStableVersion} — published.**`,
    'README published stable identity header',
  )
  expectContains(readme, `> **Active source candidate: ${version} — unpublished.**`, 'README active source identity header')
  expectContains(readme, '`candidateReady: false`', 'README planned candidate interlock')
  expectContains(
    readme,
    'Active source versioning is independent of immutable published-stable evidence',
    'README active versus published version boundary',
  )
  const npmPublishGuide = sources.get('NPM_PUBLISH.md')
  expectContains(npmPublishGuide, `Stable \`zigcss@${publishedStableVersion}\` is published on npm \`latest\``, 'npm publishing guide stable identity')
  expectContains(
    npmPublishGuide,
    'Every future tag-triggered publication must first prove, through the bounded GitHub Actions API preflight, that the exact tagged commit has a successful same-repository `main` push run of the exact `Build` workflow at `.github/workflows/build.yml`.',
    'npm publishing guide exact-SHA Build preflight',
  )
  expectContains(status, `ZigCSS ${publishedStableVersion} is the published stable release`, 'status guide published stable identity')
  expectContains(status, `Active source candidate ${version} is selected`, 'status guide active source identity')
  expectContains(status, '`candidateReady` interlock remains `false` until all seven pre-tag gates pass', 'status guide planned candidate interlock')
  const verifiedCandidateGates = nextRelease.gates?.filter(gate => gate.state === 'verified').length
  const totalCandidateGates = nextRelease.gates?.length
  expectContains(
    status,
    `${verifiedCandidateGates} of ${totalCandidateGates} admission gates now carry recorded evidence`,
    'status guide candidate gate progress',
  )
  expectContains(
    sources.get('docs/src/app/components/Home.tsx'),
    `${verifiedCandidateGates}/${totalCandidateGates} admission gates verified`,
    'home candidate gate progress',
  )
  expectContains(
    status,
    'The active source version may advance without rewriting that immutable publication record or the verified Homebrew formula',
    'status guide active versus published version boundary',
  )
  expectContains(sources.get('docs/src/content/docs/guide/build-from-source.md'), `package \`zigcss\` ${version}`, 'build guide stable identity')
  const builderGuide = sources.get('docs/src/content/docs/guide/builder-integrations.md')
  expectContains(builderGuide, `The current unpublished ${version} source checkout has`, 'builder guide current-source boundary')
  expectContains(builderGuide, `immutable published \`zigcss@${publishedStableVersion}\` binary predates`, 'builder guide published stable identity')
  const builderExamples = [
    ['examples/build-systems/README.md', `Published stable ZigCSS ${publishedStableVersion} has no \`--depfile\` option`, 'current `Unreleased` checkout only'],
    ['examples/next-turbopack/README.md', `published \`zigcss@${publishedStableVersion}\` binary predates`, 'source-checkout example'],
    ['examples/sveltekit/README.md', `Published ZigCSS ${publishedStableVersion} also predates`, 'current-source-checkout proof only'],
    ['examples/astro/README.md', `published \`zigcss@${publishedStableVersion}\` binary predates`, 'current-source-checkout proof only'],
    ['examples/nuxt/README.md', `Published ZigCSS ${publishedStableVersion} also predates`, 'current-source-checkout proof only'],
    ['examples/parcel/README.md', `stable ZigCSS ${publishedStableVersion}`, 'source-checkout example'],
  ]
  for (const [filename, stableBoundary, sourceBoundary] of builderExamples) {
    const source = sources.get(filename)
    expectContains(source, stableBoundary, `${filename} published stable identity`)
    expectContains(source, sourceBoundary, `${filename} current-source boundary`)
    expectContains(source.replace(/\s+/g, ' '), `Zig ${minimumZigVersion}`, `${filename} minimum Zig version`)
  }
  expectContains(builderGuide.replace(/\s+/g, ' '), `Zig ${minimumZigVersion}`, 'builder guide minimum Zig version')
  expectContains(sources.get('docs/src/content/docs/guide/css-compatibility.md'), `Published stable ${publishedStableVersion} predates this parser contract`, 'CSS guide published stable boundary')
  expectContains(sources.get('docs/src/content/docs/guide/format-compatibility.md'), `Stable ${publishedStableVersion} contains`, 'format guide published stable identity')
  expectContains(sources.get('docs/src/content/docs/guide/recovery-cli.md'), `Stable ${publishedStableVersion} contains`, 'CLI guide published stable identity')
  const homebrewGuide = sources.get('homebrew-install.md')
  expectContains(homebrewGuide, `stable ZigCSS \`${publishedStableVersion}\``, 'Homebrew guide published stable identity')
  expectContains(homebrewGuide, 'brew install --formula ./Formula/zigcss.rb', 'Homebrew guide checkout install command')
  expectContains(homebrewGuide, 'not a claim that a public Homebrew tap exists', 'Homebrew guide tap boundary')
  expectContains(sources.get('docs/src/app/components/GettingStarted.tsx'), `ZigCSS ${publishedStableVersion} is published on npm latest`, 'getting-started published stable identity')
  expectContains(sources.get('docs/src/app/components/Home.tsx'), `Stable ${publishedStableVersion} is published from one immutable release workflow`, 'homepage published stable identity')
  expectContains(sources.get('docs/src/app/components/Home.tsx'), `${version} · unpublished source proofs`, 'homepage active source identity')
  expectContains(sources.get('docs/src/app/components/BootSequence.tsx'), `zigcss ${publishedStableVersion} ·`, 'boot published stable identity')
  expectContains(sources.get('docs/index.html'), `"version": "${publishedStableVersion}"`, 'published structured software version')
  expectContains(sources.get('docs/src/data/seo-routes.mjs'), `Install and run ZigCSS ${publishedStableVersion}`, 'published static route identity')
  expectContains(sources.get('neovim-config/README.md'), `ZigCSS ${version}`, 'Neovim stable identity')
  expectContains(readme, `Marketplace-compatible package version ${publishedMarketplaceVersion}`, 'README published VS Code mapping')
  expectContains(status, `Marketplace-compatible package version ${publishedMarketplaceVersion}`, 'status published VS Code mapping')
  expectContains(
    status,
    'Every future tag-triggered publication is gated before npm identity, packing, artifacts, attestations, or publication authority by a bounded GitHub Actions API proof that the exact tagged commit has a successful same-repository `main` push run of the exact `Build` workflow at `.github/workflows/build.yml`.',
    'status exact-SHA Build preflight',
  )

  const changelog = sources.get('CHANGELOG.md')
  const unreleasedHasMaterialChanges = unreleasedSectionHasMaterialChanges(changelog)
  if (
    unreleasedHasMaterialChanges &&
    compareReleaseVersionPrecedence(version, publishedStableVersion) === 0
  ) {
    fail(
      `active source version ${version} must advance beyond published stable ${publishedStableVersion} because [Unreleased] contains material changes`,
    )
  }
  if (unreleasedHasMaterialChanges) {
    expectContains(changelog, `Planned prerelease target \`${plannedCandidate.value}\` is selected`, 'planned candidate changelog target')
    expectContains(changelog, '`candidateReady: false` until all seven pre-tag gates pass', 'planned candidate changelog interlock')
  }
  expectContains(changelog, `## [${publishedStableVersion}] - 2026-08-18`, 'published stable changelog target')
  expectContains(changelog, `\`zigcss@${publishedStableVersion}\` on npm \`latest\` with provenance`, 'published stable changelog channel')
  if (/ZigCSS 0\.3 (?:is|and)/.test(changelog)) fail('changelog recovery note still claims the 0.3 line is current')

  const buildWorkflow = sources.get('.github/workflows/build.yml')
  const workflowGate = buildWorkflow.indexOf('npm run test:workflows && npm run check:workflows')
  const versionStep = buildWorkflow.indexOf('- name: Verify release version policy', workflowGate)
  const versionGate = buildWorkflow.indexOf('npm run test:version && npm run check:version', versionStep)
  const install = buildWorkflow.indexOf('- name: Install independent validator', versionGate)
  if (workflowGate === -1 || versionStep <= workflowGate || versionGate <= versionStep || install <= versionGate) {
    fail('build workflow must validate the release version after workflow policy and before npm installation')
  }

  const releaseWorkflow = sources.get('.github/workflows/release.yml')
  const releaseTagCheck = 'npm run check:version -- --tag "$GITHUB_REF_NAME"'
  if (releaseWorkflow.split(releaseTagCheck).length - 1 !== 2) {
    fail('release workflow must reject a mismatched tag before building any release artifact')
  }
  const npmPreflight = releaseWorkflow.indexOf('\n  npm-preflight:\n')
  const releaseJob = releaseWorkflow.indexOf('\n  release:\n', npmPreflight + 1)
  const preflightSetup = releaseWorkflow.indexOf('- name: Setup Node.js', npmPreflight)
  const preflightGate = releaseWorkflow.indexOf(
    releaseTagCheck,
    preflightSetup,
  )
  const npmAuthority = releaseWorkflow.indexOf('- name: Verify npm publication authority', preflightGate)
  const releaseSetup = releaseWorkflow.indexOf('- name: Setup Node.js', releaseJob)
  const releaseGate = releaseWorkflow.indexOf(
    releaseTagCheck,
    releaseSetup,
  )
  const releaseBuild = releaseWorkflow.indexOf('- name: Build Release Binary', releaseGate)
  if (
    npmPreflight === -1 ||
    releaseJob <= npmPreflight ||
    preflightSetup <= npmPreflight ||
    preflightGate <= preflightSetup ||
    npmAuthority <= preflightGate ||
    npmAuthority >= releaseJob ||
    releaseSetup <= releaseJob ||
    releaseGate <= releaseSetup ||
    releaseBuild <= releaseGate
  ) {
    fail('release workflow must reject a mismatched tag before building any release artifact')
  }
  if (/ZigCSS 0\.\d/.test(releaseWorkflow)) fail('release workflow body must use its computed version instead of a hard-coded product line')

  const vscodeVerifier = sources.get('vscode-extension/scripts/verify-package.mjs')
  expectContains(vscodeVerifier, "'--pre-release'", 'VS Code package verifier')

  return {
    version,
    vscodeVersion,
    publishedStableVersion,
    surfaces: releaseSourcePaths.length,
  }
}

export function readReleaseSources(root = repositoryRoot) {
  const canonicalRoot = fs.realpathSync(root)
  return new Map(releaseSourcePaths.map(relativePath => {
    const candidate = path.resolve(canonicalRoot, relativePath)
    let stat
    try {
      stat = fs.lstatSync(candidate)
    } catch (error) {
      fail(`${relativePath} is missing: ${error.message}`)
    }
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`${relativePath} must be a regular non-symlink file`)
    const canonical = fs.realpathSync(candidate)
    const confinement = path.relative(canonicalRoot, canonical)
    if (confinement === '..' || confinement.startsWith(`..${path.sep}`) || path.isAbsolute(confinement)) {
      fail(`${relativePath} escapes the repository`)
    }
    return [relativePath, normalizeCheckoutText(fs.readFileSync(canonical, 'utf8'), relativePath)]
  }))
}

export function validateReleaseVersion(root = repositoryRoot) {
  return validateReleaseSources(readReleaseSources(root))
}

function main() {
  const args = process.argv.slice(2)
  if (args[0] !== '--check' || (args.length !== 1 && (args.length !== 3 || args[1] !== '--tag'))) {
    throw new Error('usage: node scripts/validate-release-version.mjs --check [--tag vX.Y.Z]')
  }
  const result = validateReleaseVersion()
  if (args.length === 3) validateReleaseTag(result.version, args[2])
  process.stdout.write(
    `Release version verified: active core ${result.version}, source VS Code ${result.vscodeVersion}, published stable ${result.publishedStableVersion}, ${result.surfaces} synchronized surfaces${args.length === 3 ? `, tag ${args[2]}` : ''}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
