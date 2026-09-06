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
  'docs/src/app/components/Features.tsx',
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

function expectNotMatch(source, expression, label) {
  const match = source.match(expression)
  if (match !== null) fail(`${label} contains stale release copy ${JSON.stringify(match[0])}`)
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

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function utcDateFromTimestamp(value, label) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) {
    fail(`${label} must be a canonical UTC timestamp`)
  }
  const parsed = Date.parse(value)
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString().replace('.000Z', 'Z') !== value) {
    fail(`${label} must be a real canonical UTC timestamp`)
  }
  return value.slice(0, 10)
}

const emptyUnreleasedMarkers = new Set([
  'No later stable identity is selected.',
  'No changes yet.',
  'Nothing yet.',
])
const nextReleaseGateIds = Object.freeze([
  'candidate-selection',
  'version-synchronization',
  'native-integrity',
  'local-validation',
  'documentation-validation',
  'hosted-validation',
  'origin-main-integration',
  'tag-workflow-publication',
])
const closedPublicReleasePaths = Object.freeze([
  'README.md',
  'NPM_PUBLISH.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/build-from-source.md',
  'docs/src/content/docs/guide/css-compatibility.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Home.tsx',
  'examples/build-systems/README.md',
  'examples/next-turbopack/README.md',
  'examples/sveltekit/README.md',
  'examples/astro/README.md',
  'examples/nuxt/README.md',
  'examples/parcel/README.md',
])
const closedNoUnreleasedPaths = Object.freeze([
  'README.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'examples/build-systems/README.md',
])
const closedNoUnpublishedPaths = Object.freeze([
  'NPM_PUBLISH.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/css-compatibility.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'examples/build-systems/README.md',
])

function validateNextReleasePhase(contract) {
  if (!Array.isArray(contract.gates) || contract.gates.length !== nextReleaseGateIds.length) {
    fail(`next release gates must contain exactly ${nextReleaseGateIds.length} entries`)
  }
  const gateStates = new Map()
  for (const [index, id] of nextReleaseGateIds.entries()) {
    const gate = contract.gates[index]
    expectEqual(gate?.id, id, `next release gate ${index}`)
    if (!['pending', 'verified', 'failed'].includes(gate?.state)) fail(`next release gate ${id} state is invalid`)
    gateStates.set(id, gate.state)
  }
  const verifiedGates = [...gateStates.values()].filter(state => state === 'verified').length
  const publicationState = gateStates.get('tag-workflow-publication')
  if (contract.state === 'planned') {
    expectEqual(contract.schemaVersion, 1, 'planned next release schemaVersion')
    expectEqual(contract.candidateReady, false, 'planned next release candidateReady')
    expectEqual(verifiedGates, 5, 'planned next release verified gates')
    expectEqual(publicationState, 'pending', 'planned next release publication gate')
    for (const id of nextReleaseGateIds.slice(0, 5)) {
      expectEqual(gateStates.get(id), 'verified', `planned next release ${id}`)
    }
    for (const id of nextReleaseGateIds.slice(5)) {
      expectEqual(gateStates.get(id), 'pending', `planned next release ${id}`)
    }
  } else if (contract.state === 'candidate-ready') {
    expectEqual(contract.schemaVersion, 1, 'candidate-ready next release schemaVersion')
    expectEqual(contract.candidateReady, true, 'candidate-ready next release candidateReady')
    expectEqual(verifiedGates, 7, 'candidate-ready next release verified gates')
    expectEqual(publicationState, 'pending', 'candidate-ready next release publication gate')
    for (const id of nextReleaseGateIds.slice(0, -1)) {
      expectEqual(gateStates.get(id), 'verified', `candidate-ready next release ${id}`)
    }
  } else if (contract.state === 'closed') {
    expectEqual(contract.schemaVersion, 2, 'closed next release schemaVersion')
    expectEqual(contract.candidateReady, false, 'closed next release candidateReady')
    expectEqual(verifiedGates, 8, 'closed next release verified gates')
    expectEqual(publicationState, 'verified', 'closed next release publication gate')
    for (const id of nextReleaseGateIds) {
      expectEqual(gateStates.get(id), 'verified', `closed next release ${id}`)
    }
    if (contract.publicationEvidence === null || typeof contract.publicationEvidence !== 'object' || Array.isArray(contract.publicationEvidence)) {
      fail('closed next release publication evidence is missing')
    }
  } else if (contract.state === 'publication-failed') {
    expectEqual(contract.schemaVersion, 3, 'publication-failed next release schemaVersion')
    expectEqual(contract.candidateReady, false, 'publication-failed next release candidateReady')
    expectEqual(publicationState, 'failed', 'publication-failed next release publication gate')
    for (const id of nextReleaseGateIds.slice(0, 5)) {
      expectEqual(gateStates.get(id), 'verified', `publication-failed next release ${id}`)
    }
    let pendingSeen = false
    for (const id of nextReleaseGateIds.slice(0, -1)) {
      const state = gateStates.get(id)
      if (state === 'pending') {
        pendingSeen = true
      } else if (state !== 'verified') {
        fail(`publication-failed next release ${id} must be verified or pending`)
      } else if (pendingSeen) {
        fail(`publication-failed next release pre-tag gates are out of order at ${id}`)
      }
    }
    const failure = contract.publicationFailureEvidence
    if (failure === null || typeof failure !== 'object' || Array.isArray(failure)) {
      fail('publication-failed next release evidence is missing')
    }
    if (!['absent', 'draft', 'immutable-published'].includes(failure.githubSurface?.state)) {
      fail('publication-failed GitHub surface state is invalid')
    }
    if (!['absent', 'published-exact'].includes(failure.npmSurface?.state)) {
      fail('publication-failed npm surface state is invalid')
    }
  } else {
    fail(`next release state is invalid: ${JSON.stringify(contract.state)}`)
  }
  return Object.freeze({
    state: contract.state,
    verifiedGates,
    totalGates: contract.gates.length,
    githubState: contract.publicationFailureEvidence?.githubSurface?.state ?? null,
    npmState: contract.publicationFailureEvidence?.npmSurface?.state ?? null,
  })
}

export function unreleasedSectionHasMaterialChanges(changelog) {
  if (typeof changelog !== 'string') fail('CHANGELOG.md must be text')
  const headings = [...changelog.matchAll(/^## \[Unreleased\][ \t]*$/gm)]
  if (headings.length !== 1) {
    fail(`CHANGELOG.md must contain exactly one [Unreleased] section, received ${headings.length}`)
  }

  const remainder = changelog.slice(headings[0].index + headings[0][0].length)
  const nextReleaseHeading = remainder.search(/^## (?!#)/m)
  const section = nextReleaseHeading === -1 ? remainder : remainder.slice(0, nextReleaseHeading)
  let insideComment = false
  const visibleLines = section.split('\n').map(line => {
    let visible = ''
    for (let index = 0; index < line.length;) {
      if (insideComment) {
        if (line.startsWith('-->', index)) {
          insideComment = false
          index += 3
        } else {
          index += 1
        }
      } else if (line.startsWith('<!--', index)) {
        insideComment = true
        index += 4
      } else {
        visible += line[index]
        index += 1
      }
    }
    return visible
  })
  if (insideComment) fail('CHANGELOG.md [Unreleased] contains an unterminated HTML comment')

  return visibleLines.some(line => {
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
  const nextReleasePhase = validateNextReleasePhase(nextRelease)
  if (nextReleasePhase.state !== 'planned') {
    expectEqual(version, plannedCandidate.value, `${nextReleasePhase.state} active source version`)
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
    'node --test scripts/check-npm-version-availability.test.mjs scripts/npm-package-artifact.test.mjs scripts/smoke-public-delivery.test.mjs scripts/verify-github-release-assets.test.mjs scripts/verify-npm-publication.test.mjs',
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
  const releaseArtifactBehavior = capabilityById.get('release-artifacts')?.behavior ?? ''
  for (const fragment of [
    'resumes only an authenticated exact-tag draft targeting the same commit',
    'confines overwrite to expected draft assets',
    "requires the published release to read back `immutable: true` and pass GitHub's cryptographic release attestation",
  ]) {
    expectContains(releaseArtifactBehavior, fragment, 'release-artifact draft reconciliation capability')
  }
  for (const fragment of [
    'same-commit Build and default-setup CodeQL for Actions, JavaScript/TypeScript, and Ruby',
    'clean error/warning status and zero open alerts under `security-events: read`',
  ]) {
    expectContains(releaseArtifactBehavior, fragment, 'release-artifact CodeQL admission capability')
  }
  for (const fragment of [
    'Repository ruleset 22261144 (`Protect release tags`)',
    'active for target `tag`, including `refs/tags/v*`, with exact `update` and `deletion` rules',
    'no bypass actors, and no current-user bypass',
  ]) {
    expectContains(releaseArtifactBehavior, fragment, 'release-artifact protected-tag capability')
  }
  for (const fragment of [
    'GitHub Release 372291445 also reads back `immutable: false`',
    'both published npm versions remain immutable',
    'GitHub Environment `immutable-release` (ID 21234930544)',
    'only deployment pattern `v*` of type `tag` (policy ID 59095548)',
    'no stored secrets',
    'required reviewer repeats both live readbacks immediately before approval',
    '`v0.7.0-rc.1` must be the first true immutable GitHub Release',
  ]) {
    expectContains(releaseArtifactBehavior, fragment, 'release-artifact immutable approval capability')
  }
  expectContains(
    releaseArtifactBehavior,
    'A terminal non-success tag workflow must transition to schema 3 `publication-failed`',
    'release-artifact failed-terminal capability',
  )
  expectEqual(capabilityMetadata.gates?.['release-version']?.command, 'npm run check:version', 'release-version evidence gate')

  const readme = sources.get('README.md')
  const status = sources.get('docs/src/content/docs/guide/status.md')
  const home = sources.get('docs/src/app/components/Home.tsx')
  const gettingStarted = sources.get('docs/src/app/components/GettingStarted.tsx')
  const builderGuide = sources.get('docs/src/content/docs/guide/builder-integrations.md')
  const npmPublishGuide = sources.get('NPM_PUBLISH.md')
  const zigPackageBehavior = capabilityById.get('zig-package')?.behavior ?? ''
  const publishedCandidatePackage = nextReleasePhase.state === 'closed'
    || nextReleasePhase.npmState === 'published-exact'
  expectContains(
    readme,
    `> **Stable package identity: ${publishedStableVersion} — published.**`,
    'README published stable identity header',
  )
  if (nextReleasePhase.state === 'planned') {
    expectContains(readme, `> **Active source candidate: ${version} — unpublished.**`, 'README planned candidate identity')
    expectContains(readme, '`candidateReady: false`', 'README planned candidate interlock')
    expectContains(status, `Active source candidate ${version} is selected`, 'status guide planned candidate identity')
    expectContains(status, '`candidateReady` interlock remains `false` until all seven pre-tag gates pass', 'status guide planned candidate interlock')
    expectContains(home, `${version} · unpublished source proofs`, 'homepage planned candidate identity')
    expectContains(gettingStarted, `unpublished ${version} candidate`, 'getting-started planned candidate identity')
    expectContains(builderGuide, `The current unpublished ${version} source checkout has`, 'builder guide planned candidate identity')
    expectContains(zigPackageBehavior, 'This active source candidate is unpublished', 'capability planned candidate identity')
    expectContains(
      npmPublishGuide,
      'It is currently `planned` with `candidateReady: false`',
      'npm guide planned candidate state',
    )
  } else if (nextReleasePhase.state === 'candidate-ready') {
    expectContains(readme, `> **Active source candidate: ${version} — unpublished.**`, 'README admitted candidate identity')
    expectContains(readme, '`candidateReady: true`', 'README admitted candidate interlock')
    expectContains(status, `Active source candidate ${version} is selected`, 'status guide admitted candidate identity')
    expectContains(
      status,
      '`candidateReady` interlock is `true` after all seven pre-tag gates passed',
      'status guide admitted candidate interlock',
    )
    expectContains(home, `${version} · unpublished source proofs`, 'homepage admitted candidate identity')
    expectContains(gettingStarted, `unpublished ${version} candidate`, 'getting-started admitted candidate identity')
    expectContains(builderGuide, `The current unpublished ${version} source checkout has`, 'builder guide admitted candidate identity')
    expectContains(zigPackageBehavior, 'This active source candidate is unpublished', 'capability admitted candidate identity')
    expectContains(
      npmPublishGuide,
      'It is currently `candidate-ready` with `candidateReady: true`',
      'npm guide admitted candidate state',
    )
  } else if (nextReleasePhase.state === 'closed') {
    expectContains(readme, `> **Published prerelease: ${version} — npm \`next\`.**`, 'README published prerelease identity')
    expectContains(readme, '`candidateReady: false` after immutable publication', 'README closed candidate interlock')
    expectContains(readme, `ZigCSS \`${version}\` is the published prerelease on npm \`next\``, 'README published prerelease introduction')
    expectContains(readme, `npm \`next\` serves \`zigcss@${version}\``, 'README current prerelease channel')
    expectContains(readme, `The published \`${version}\` prerelease package contract adds`, 'README published package integrity boundary')
    expectContains(readme, `The published \`${version}\` prerelease package exports`, 'README published Node API boundary')
    expectContains(readme, `The published \`${version}\` prerelease package adds explicit, typed adapter subpaths`, 'README published adapter boundary')
    expectContains(status, `ZigCSS ${version} is the published prerelease on npm \`next\``, 'status guide published prerelease identity')
    expectContains(
      status,
      '`candidateReady` interlock is `false` after immutable publication',
      'status guide closed candidate interlock',
    )
    expectContains(home, `${version} · published prerelease · npm next`, 'homepage published prerelease identity')
    expectContains(gettingStarted, `ZigCSS ${version} is published on npm next`, 'getting-started published prerelease identity')
    expectContains(gettingStarted, `published ${version} prerelease Node API`, 'getting-started published Node API boundary')
    expectContains(builderGuide, `The published ${version} prerelease and current source checkout have`, 'builder guide published prerelease identity')
    expectContains(builderGuide, `These capabilities ship in the published \`zigcss@${version}\` prerelease`, 'builder guide published package boundary')
    expectContains(
      zigPackageBehavior,
      'This prerelease is published on npm `next`; stable delivery remains',
      'capability published prerelease identity',
    )
    expectContains(
      npmPublishGuide,
      `Prerelease \`zigcss@${version}\` is published on npm \`next\``,
      'npm guide published prerelease identity',
    )
    expectContains(npmPublishGuide, `npm \`next\` serves \`zigcss@${version}\``, 'npm guide current prerelease channel')
    expectContains(npmPublishGuide, 'The 48-file npm package contains', 'npm guide exact package inventory')
    expectContains(npmPublishGuide, 'Install the published prerelease with `zigcss@next`', 'npm guide current prerelease install')
    expectNotContains(readme, `> **Active source candidate: ${version} — unpublished.**`, 'README stale unpublished candidate')
    expectNotContains(status, `Active source candidate ${version} is selected`, 'status stale unpublished candidate')
    expectNotContains(home, `${version} · unpublished source proofs`, 'homepage stale unpublished candidate')
    expectNotContains(builderGuide, `The current unpublished ${version} source checkout has`, 'builder guide stale unpublished candidate')

    const nodeApiBehavior = capabilityById.get('node-api')?.behavior ?? ''
    expectContains(nodeApiBehavior, `The published \`zigcss@${version}\` prerelease package root exposes`, 'published Node API capability')
    expectEqual(capabilityById.get('output-planning')?.status, 'Published prerelease, safety boundary verified', 'published output-planning capability status')
    expectContains(capabilityById.get('output-planning')?.behavior ?? '', `The published ${version} prerelease CLI`, 'published output-planning capability')
    expectEqual(capabilityById.get('optimizer')?.status, 'Experimental, published prerelease and acceptance-gated', 'published optimizer capability status')
    expectContains(capabilityById.get('optimizer')?.behavior ?? '', `In the published ${version} prerelease CLI`, 'published optimizer capability')
    for (const [id, label] of [
      ['target-prefix', 'target-prefix'],
      ['source-maps', 'source-map'],
      ['browser-targets', 'browser-target'],
    ]) {
      expectEqual(
        capabilityById.get(id)?.status,
        'Experimental, published prerelease all-syntax CLI/API verified',
        `published ${label} capability status`,
      )
      expectContains(
        capabilityById.get(id)?.behavior ?? '',
        `published ${version} prerelease`,
        `published ${label} capability`,
      )
    }
    expectContains(status, `The published \`zigcss@${version}\` prerelease package root exposes`, 'status published Node API row')
    expectContains(status, `The published ${version} prerelease CLI rejects output/depfile aliases`, 'status published output-planning row')
    expectContains(status, `## Published ${version} package installation recovery boundary`, 'status published recovery boundary')
    expectContains(status, `Published ${version} remains the immutable prerelease CLI-launcher package`, 'status published adapter boundary')
    expectContains(status, `This published ${version} prerelease compiler enables`, 'status published compiler boundary')

    expectContains(
      sources.get('docs/src/app/components/Features.tsx'),
      `That evidence ships in published prerelease ${version} on npm next`,
      'features published prerelease identity',
    )
    expectContains(
      sources.get('docs/src/content/docs/guide/build-from-source.md'),
      `published \`zigcss@${version}\` prerelease`,
      'build guide published prerelease boundary',
    )
    expectContains(
      sources.get('docs/src/content/docs/guide/css-compatibility.md'),
      `published \`${version}\` prerelease recovery compiler`,
      'CSS guide published prerelease boundary',
    )
    expectContains(
      sources.get('docs/src/content/docs/guide/format-compatibility.md'),
      `ZigCSS ${version} prerelease is published on npm \`next\``,
      'format guide published prerelease boundary',
    )
    expectContains(
      sources.get('docs/src/content/docs/guide/recovery-cli.md'),
      `ZigCSS ${version} prerelease is published on npm \`next\``,
      'recovery guide published prerelease boundary',
    )
    expectContains(
      sources.get('examples/build-systems/README.md'),
      `Published prerelease ZigCSS ${version} contains the verified \`--depfile\` contract`,
      'build-system examples published prerelease boundary',
    )
    for (const filename of [
      'examples/next-turbopack/README.md',
      'examples/sveltekit/README.md',
      'examples/astro/README.md',
      'examples/nuxt/README.md',
      'examples/parcel/README.md',
    ]) {
      expectContains(
        sources.get(filename),
        `Published \`zigcss@${version}\``,
        `${filename} published prerelease boundary`,
      )
    }

    const escapedCandidate = escapeRegExp(version)
    const staleCandidatePublication = new RegExp(
      `(?:${escapedCandidate}[^\\n]{0,200}\\b(?:unpublished|not published)\\b|\\b(?:unpublished|not published)\\b[^\\n]{0,200}${escapedCandidate})`,
      'i',
    )
    const staleHistoricalNext = /(?:0\.6\.0-rc\.2[^\n]{0,200}\bnext\b|\bnext\b[^\n]{0,200}0\.6\.0-rc\.2)/i
    for (const filename of closedPublicReleasePaths) {
      const source = sources.get(filename)
      expectNotMatch(source, staleCandidatePublication, `${filename} closed candidate publication`)
      expectNotMatch(source, staleHistoricalNext, `${filename} current npm next identity`)
    }
    for (const filename of closedNoUnreleasedPaths) {
      expectNotMatch(sources.get(filename), /\bunreleased\b/i, `${filename} closed release phase`)
    }
    for (const filename of closedNoUnpublishedPaths) {
      expectNotMatch(sources.get(filename), /\bunpublished\b/i, `${filename} closed release phase`)
    }
    const readmeBenchmarkBoundary = 'Timing, ranking, throughput, memory, and ratio numbers remain unpublished until that evidence lands.'
    expectContains(readme, readmeBenchmarkBoundary, 'README unpublished benchmark boundary')
    expectNotMatch(
      readme.replace(readmeBenchmarkBoundary, ''),
      /\bunpublished\b/i,
      'README closed release phase outside benchmark boundary',
    )
    const homeBenchmarkBoundary = 'Comparative rankings remain unpublished until the attested scheduled archive lands.'
    expectContains(home, homeBenchmarkBoundary, 'homepage unpublished benchmark boundary')
    expectNotMatch(
      home.replace(homeBenchmarkBoundary, ''),
      /\bunpublished\b/i,
      'homepage closed release phase outside benchmark boundary',
    )
  } else {
    const githubState = nextReleasePhase.githubState
    const npmState = nextReleasePhase.npmState
    const failureHeader = `> **Failed prerelease attempt: ${version} — identity permanently closed.**`
    const surfaceSummary = `GitHub surface: \`${githubState}\`; npm surface: \`${npmState}\`.`
    expectContains(readme, failureHeader, 'README failed publication identity')
    expectContains(readme, surfaceSummary, 'README failed publication surfaces')
    expectContains(readme, '`candidateReady: false` after failed publication', 'README failed publication interlock')
    expectContains(
      status,
      `ZigCSS ${version} release attempt failed and the exact identity is permanently closed.`,
      'status failed publication identity',
    )
    expectContains(status, surfaceSummary, 'status failed publication surfaces')
    expectContains(
      status,
      '`candidateReady` interlock is `false` after the failed publication attempt',
      'status failed publication interlock',
    )
    expectContains(home, `${version} · failed release identity · do not reuse`, 'homepage failed publication identity')
    expectContains(gettingStarted, `Release attempt ${version} failed`, 'getting-started failed publication identity')
    expectContains(builderGuide, `After the failed ${version} release attempt`, 'builder guide failed publication identity')
    expectContains(
      sources.get('docs/src/app/components/Features.tsx'),
      `Release attempt ${version} failed; GitHub ${githubState}; npm ${npmState}; exact identity permanently closed.`,
      'features failed publication identity',
    )
    expectContains(
      zigPackageBehavior,
      `Release attempt ${version} is publication-failed: GitHub ${githubState}; npm ${npmState}; exact identity permanently closed.`,
      'capability failed publication identity',
    )
    expectContains(
      npmPublishGuide,
      `Prerelease attempt \`zigcss@${version}\` failed and its exact identity is permanently closed. ${surfaceSummary}`,
      'npm guide failed publication identity',
    )
    expectContains(
      npmPublishGuide,
      `Select a new candidate version; never move, recreate, or reuse \`${nextRelease.candidateTag}\`.`,
      'npm guide failed publication operator transition',
    )
    expectNotContains(readme, '`candidateReady: true`', 'README failed publication success claim')
    expectNotContains(status, '`candidateReady` interlock is `true`', 'status failed publication success claim')
    expectNotContains(home, '8/8 admission gates verified', 'homepage failed publication success claim')
    expectNotContains(
      npmPublishGuide,
      'It is currently `candidate-ready` with `candidateReady: true`',
      'npm guide failed publication success claim',
    )
    expectNotContains(
      sources.get('CHANGELOG.md'),
      `Released from protected tag \`${nextRelease.candidateTag}\` as the first immutable GitHub Release and immutable \`zigcss@${version}\` on npm \`next\``,
      'failed publication changelog success claim',
    )
    const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const contradictorySuccessClaim = new RegExp(
      `(?:release|publication)[^\\n]{0,120}(?:succeeded|successful)[^\\n]{0,120}${escapedVersion}|`
        + `${escapedVersion}[^\\n]{0,120}(?:release|publication)[^\\n]{0,120}(?:succeeded|successful)|`
        + `(?:release|publication)[^\\n]{0,120}${escapedVersion}[^\\n]{0,120}(?:succeeded|successful)`,
      'i',
    )
    for (const [filename, source] of [
      ['README.md', readme],
      ['NPM_PUBLISH.md', npmPublishGuide],
      ['docs/src/content/docs/guide/status.md', status],
      ['docs/src/content/docs/guide/builder-integrations.md', builderGuide],
      ['docs/src/app/components/Home.tsx', home],
      ['docs/src/app/components/GettingStarted.tsx', gettingStarted],
      ['docs/src/app/components/Features.tsx', sources.get('docs/src/app/components/Features.tsx')],
      ['docs/src/data/capabilities.json', sources.get('docs/src/data/capabilities.json')],
    ]) {
      expectNotMatch(source, contradictorySuccessClaim, `${filename} failed publication success contradiction`)
    }
    if (npmState === 'absent') {
      expectContains(readme, `Active source package ${version} remains unavailable from npm`, 'README absent npm failure boundary')
      expectNotContains(readme, `> **Published prerelease: ${version}`, 'README absent npm success claim')
      expectContains(zigPackageBehavior, 'The npm package surface is absent; source-checkout use remains available.', 'capability absent npm failure boundary')
    } else {
      expectContains(readme, `npm \`next\` still serves \`zigcss@${version}\``, 'README published npm failure boundary')
      expectContains(zigPackageBehavior, 'The exact npm prerelease is published despite the failed workflow terminal.', 'capability published npm failure boundary')
    }
  }
  expectContains(
    readme,
    'Active source versioning is independent of closed published-stable evidence',
    'README active versus published version boundary',
  )
  expectContains(npmPublishGuide, `Stable \`zigcss@${publishedStableVersion}\` is published on npm \`latest\``, 'npm publishing guide stable identity')
  for (const fragment of [
    'an authenticated exact-tag draft targeting the same commit may be resumed',
    'Overwrite authority is confined to exact-tag draft reconciliation and never applies to an immutable published asset',
    '`publicationEvidence.finalBuildEvidence` must bind the exact `Build` name, tag commit, run ID, attempt, successful conclusion, and completion time',
    'same-commit default-setup CodeQL proof for Actions, JavaScript/TypeScript, and Ruby at a recorded pre-admission checkpoint',
    'The static candidate-ready evidence stores the Build run ID and observation times without a commit hash',
    'the tag workflow independently rechecks both services against its exact runtime commit',
    'GitHub Environment `immutable-release` (environment ID `21234930544`)',
    'only deployment policy is `v*` with type `tag` and policy ID `59095548`',
    'record exact `enabled=true`, `enforced_by_owner=false`',
    'required reviewer repeats both live readbacks immediately before approving it in GitHub',
    'repository ruleset 22261144 (`Protect release tags`) as active for target `tag`, including `refs/tags/v*`, with exact `update` and `deletion` rules, `bypass_actors: []`, and `current_user_can_bypass: never`',
    'Move the machine contract to schema 3 `publication-failed`, set `candidateReady: false`',
    'Never move, recreate, or reuse the failed tag/package identity',
  ]) {
    expectContains(npmPublishGuide, fragment, 'npm publishing guide draft reconciliation boundary')
  }
  expectContains(
    npmPublishGuide,
    'Every future tag-triggered publication must first prove, through the bounded GitHub Actions API preflight, that the exact tagged commit has a successful same-repository `main` push run of the exact `Build` workflow at `.github/workflows/build.yml`.',
    'npm publishing guide exact-SHA Build preflight',
  )
  expectContains(status, `ZigCSS ${publishedStableVersion} is the published stable release`, 'status guide published stable identity')
  expectContains(
    status,
    nextReleasePhase.state === 'publication-failed'
      ? `${nextReleasePhase.verifiedGates} of ${nextReleasePhase.totalGates} admission gates are verified; the publication terminal is failed and carries recorded failure evidence`
      : `${nextReleasePhase.verifiedGates} of ${nextReleasePhase.totalGates} admission gates now carry recorded evidence`,
    'status guide candidate gate progress',
  )
  expectContains(
    home,
    `${nextReleasePhase.verifiedGates}/${nextReleasePhase.totalGates} admission gates verified`,
    'home candidate gate progress',
  )
  expectContains(
    status,
    'The active source version may advance without rewriting that closed publication record or the verified Homebrew formula',
    'status guide active versus published version boundary',
  )
  expectContains(sources.get('docs/src/content/docs/guide/build-from-source.md'), `package \`zigcss\` ${version}`, 'build guide stable identity')
  expectContains(builderGuide, `immutable published \`zigcss@${publishedStableVersion}\` binary predates`, 'builder guide published stable identity')
  const builderExamples = [
    [
      'examples/build-systems/README.md',
      `Published stable ZigCSS ${publishedStableVersion} has no \`--depfile\` option`,
      publishedCandidatePackage
        ? 'these maintained integration proofs still run against the exact current checkout'
        : 'current `Unreleased` checkout only',
    ],
    [
      'examples/next-turbopack/README.md',
      publishedCandidatePackage
        ? `published \`zigcss@${publishedStableVersion}\` predates`
        : `published \`zigcss@${publishedStableVersion}\` binary predates`,
      'source-checkout example',
    ],
    [
      'examples/sveltekit/README.md',
      publishedCandidatePackage
        ? `Stable ZigCSS ${publishedStableVersion} predates`
        : `Published ZigCSS ${publishedStableVersion} also predates`,
      'current-source-checkout proof',
    ],
    [
      'examples/astro/README.md',
      publishedCandidatePackage
        ? `Stable \`zigcss@${publishedStableVersion}\` predates`
        : `published \`zigcss@${publishedStableVersion}\` binary predates`,
      'current-source-checkout proof',
    ],
    [
      'examples/nuxt/README.md',
      publishedCandidatePackage
        ? `Stable ZigCSS ${publishedStableVersion} predates`
        : `Published ZigCSS ${publishedStableVersion} also predates`,
      'current-source-checkout proof',
    ],
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
  expectContains(gettingStarted, `ZigCSS ${publishedStableVersion} is published on npm latest`, 'getting-started published stable identity')
  expectContains(home, `Stable ${publishedStableVersion} is published from one verified promotion workflow`, 'homepage published stable identity')
  expectContains(sources.get('docs/src/app/components/BootSequence.tsx'), `zigcss ${publishedStableVersion} ·`, 'boot published stable identity')
  expectContains(sources.get('docs/index.html'), `"version": "${publishedStableVersion}"`, 'published structured software version')
  expectContains(sources.get('docs/src/data/seo-routes.mjs'), `Install and run ZigCSS ${publishedStableVersion}`, 'published static route identity')
  expectContains(sources.get('neovim-config/README.md'), `ZigCSS ${version}`, 'Neovim stable identity')
  expectContains(readme, `Marketplace-compatible package version ${publishedMarketplaceVersion}`, 'README published VS Code mapping')
  expectContains(status, `Marketplace-compatible package version ${publishedMarketplaceVersion}`, 'status published VS Code mapping')
  expectContains(
    status,
    'Every future tag-triggered publication is gated before npm identity, packing, artifacts, attestations, or publication authority by bounded GitHub API proofs that the exact tagged commit has a successful same-repository `main` push run of the exact `Build` workflow at `.github/workflows/build.yml` and clean same-commit default-setup CodeQL analysis in the Actions, JavaScript/TypeScript, and Ruby categories, with no error or warning status and zero open CodeQL alerts under `security-events: read`.',
    'status exact-SHA Build preflight',
  )
  expectContains(
    status,
    'resumes only an authenticated exact-tag draft targeting the same commit, confines overwrite to expected draft assets',
    'status draft reconciliation boundary',
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
  if (nextReleasePhase.state === 'planned' && unreleasedHasMaterialChanges) {
    expectContains(changelog, `Planned prerelease target \`${plannedCandidate.value}\` is selected`, 'planned candidate changelog target')
    expectContains(changelog, '`candidateReady: false` until all seven pre-tag gates pass', 'planned candidate changelog interlock')
  } else if (nextReleasePhase.state === 'candidate-ready') {
    if (!unreleasedHasMaterialChanges) fail('candidate-ready changelog must retain the admitted prerelease changes')
    expectContains(
      changelog,
      `Prerelease target \`${plannedCandidate.value}\` is candidate-ready with \`candidateReady: true\``,
      'candidate-ready changelog state',
    )
  } else if (nextReleasePhase.state === 'closed') {
    if (unreleasedHasMaterialChanges) fail('closed prerelease changelog must move released changes out of [Unreleased]')
    const githubPublishedDate = utcDateFromTimestamp(
      nextRelease.publicationEvidence?.githubPublishedAt,
      'closed next release publicationEvidence.githubPublishedAt',
    )
    expectLiteralCount(
      changelog,
      `## [${plannedCandidate.value}] - ${githubPublishedDate}`,
      1,
      'published prerelease changelog target and UTC publication date',
    )
    expectContains(
      changelog,
      `Released from protected tag \`${nextRelease.candidateTag}\` as the first immutable GitHub Release and immutable \`zigcss@${plannedCandidate.value}\` on npm \`next\``,
      'published prerelease changelog evidence',
    )
  } else if (nextReleasePhase.state === 'publication-failed') {
    const githubState = nextReleasePhase.githubState
    const npmState = nextReleasePhase.npmState
    if (npmState === 'absent') {
      if (!unreleasedHasMaterialChanges) {
        fail('publication-failed changelog must retain unreleased changes while npm is absent')
      }
      expectContains(
        changelog,
        `Prerelease attempt \`${plannedCandidate.value}\` failed; exact identity is permanently closed. GitHub surface \`${githubState}\`; npm surface \`absent\`. Select a new candidate version before another release attempt.`,
        'publication-failed changelog absent-npm evidence',
      )
    } else {
      if (unreleasedHasMaterialChanges) {
        fail('publication-failed changelog must move publicly packaged changes out of [Unreleased]')
      }
      const githubPublishedDate = utcDateFromTimestamp(
        nextRelease.publicationFailureEvidence?.githubSurface?.publishedAt,
        'publication-failed GitHub surface publishedAt',
      )
      expectLiteralCount(
        changelog,
        `## [${plannedCandidate.value}] - ${githubPublishedDate}`,
        1,
        'publication-failed published-package changelog target and UTC publication date',
      )
      expectContains(
        changelog,
        `An immutable GitHub Release and exact npm surfaces exist for \`${plannedCandidate.value}\`, but the Release workflow failed; this identity is permanently closed.`,
        'publication-failed changelog published-package evidence',
      )
    }
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
