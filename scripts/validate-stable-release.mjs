import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion, validateReleaseTag } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const stableReleaseSourcePaths = Object.freeze([
  '.github/workflows/release.yml',
  'BENCHMARK_REPORT.md',
  'DEVELOPMENT_PLAN.md',
  'README.md',
  'VERSION',
  'benchmarks/publication.json',
  'docs/adr/ADR-015-stable-promotion-and-performance-claims.md',
  'docs/index.html',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Home.tsx',
  'package.json',
  'release/stable-promotion.json',
  'tests/preprocessors/native/contract.json',
])

const expectedSyntaxes = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus'])
const expectedTargets = Object.freeze([
  'x86_64-linux',
  'aarch64-linux',
  'x86_64-macos',
  'aarch64-macos',
  'x86_64-windows',
])
const expectedPreTagSurfaces = Object.freeze([
  'authority-contract',
  'immutable-candidate',
  'native-prerelease-evidence',
  'release-channel-policy',
  'benchmark-claims-policy',
  'local-validation',
  'documentation-pages-validation',
  'hosted-validation',
  'origin-main-integration',
])
const expectedPostTagSurfaces = Object.freeze(['tag-workflow-publication'])
const initialVerifiedGates = new Set(expectedPreTagSurfaces.slice(0, 5))
const canonicalCommit = /^[0-9a-f]{40}$/
const expectedPublicationEvidence = Object.freeze({
  tagCommit: '6786655d66ca65c5a06421c8ed70d84183722dce',
  workflowRunId: 32130950531,
  workflowAttempt: 1,
  workflowConclusion: 'success',
  workflowCompletedAt: '2026-08-18T11:23:31Z',
  githubReleaseId: 372291445,
  githubReleaseUrl: 'https://github.com/vyakymenko/zigcss/releases/tag/v0.6.0',
  githubPrerelease: false,
  githubDraft: false,
  githubPublishedAt: '2026-08-18T11:23:10Z',
  githubAssetCount: 25,
  githubAssetBytes: 16374807,
  githubAssetInventorySha256: '65292d754cc559d064f776f0934d399333ba66e1dd2a3b34ec4aac395595dd9b',
  assetsPerTarget: 5,
  npmVersion: '0.6.0',
  npmDistTag: 'latest',
  npmLatest: '0.6.0',
  npmNext: '0.6.0-rc.2',
  npmFileCount: 7,
  npmUnpackedSize: 47454,
  npmIntegrity: 'sha512-qJp3h+wO7dM6bU96DJLbUyQ5jNsTCNh1J6TUoxb0wCljpUF+nSXoLW7x2geXznvqCWss1xwK2ISYmT+B/cNcuQ==',
  npmShasum: '9bd280f31c5ca1a45a892b76edeb904cf855d461',
  npmProvenancePredicateType: 'https://slsa.dev/provenance/v1',
  anonymousInstall: 'verified-five-syntaxes',
})

function fail(message) {
  throw new Error(`stable release promotion: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (!same(actual, expected)) {
    fail(`${label} keys must be ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label} must be ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
}

function requireText(source, fragment, label) {
  if (typeof source !== 'string' || !source.includes(fragment)) {
    fail(`${label} is missing ${JSON.stringify(fragment)}`)
  }
}

function expectLiteralCount(source, fragment, expected, label) {
  const actual = source.split(fragment).length - 1
  if (actual !== expected) {
    fail(`${label} must contain ${JSON.stringify(fragment)} ${expected} times, received ${actual}`)
  }
}

function parseJson(source, label) {
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function validatePublicationEvidence(evidence) {
  exactKeys(evidence, Object.keys(expectedPublicationEvidence), 'publicationEvidence')
  for (const [key, expected] of Object.entries(expectedPublicationEvidence)) {
    expectEqual(evidence[key], expected, `publicationEvidence.${key}`)
  }
}

function validateContractShape(contract) {
  exactKeys(contract, [
    'schemaVersion',
    'ownerPackage',
    'releaseGapFamily',
    'state',
    'packageState',
    'stableReleaseReady',
    'candidateVersion',
    'candidateTag',
    'previousPrerelease',
    'candidateSelection',
    'claimsPolicy',
    'terminalContract',
    'gates',
    'publicationEvidence',
  ], 'stable promotion contract')
  expectEqual(contract.schemaVersion, 1, 'schemaVersion')
  expectEqual(contract.ownerPackage, 'REL-010', 'ownerPackage')
  expectEqual(contract.releaseGapFamily, 'stable-release-promotion', 'releaseGapFamily')
  if (!['in-progress', 'candidate-ready', 'closed'].includes(contract.state)) fail('state is invalid')
  if (!['in-progress', 'verified'].includes(contract.packageState)) fail('packageState is invalid')
  if (typeof contract.stableReleaseReady !== 'boolean') fail('stableReleaseReady must be boolean')
  expectEqual(contract.candidateVersion, '0.6.0', 'candidateVersion')
  parseReleaseVersion(contract.candidateVersion, 'stable candidate version')
  expectEqual(contract.candidateTag, 'v0.6.0', 'candidateTag')
  validateReleaseTag(contract.candidateVersion, contract.candidateTag)

  exactKeys(contract.previousPrerelease, [
    'version', 'tag', 'commit', 'githubReleaseId', 'npmDistTag',
  ], 'previousPrerelease')
  expectEqual(contract.previousPrerelease.version, '0.6.0-rc.2', 'previous prerelease version')
  expectEqual(contract.previousPrerelease.tag, 'v0.6.0-rc.2', 'previous prerelease tag')
  expectEqual(contract.previousPrerelease.commit, 'b63e190f7edeccd829abe34bfb96d9e1a8a320e2', 'previous prerelease commit')
  expectEqual(contract.previousPrerelease.githubReleaseId, 369856953, 'previous prerelease GitHub release')
  expectEqual(contract.previousPrerelease.npmDistTag, 'next', 'previous prerelease npm tag')

  exactKeys(contract.candidateSelection, [
    'selectedOn',
    'selectedFromCommit',
    'githubRepository',
    'githubTagStateAtSelection',
    'githubReleaseStateAtSelection',
    'npmPackage',
    'npmVersionStateAtSelection',
    'observedPublishedNpmVersions',
  ], 'candidateSelection')
  expectEqual(contract.candidateSelection.selectedOn, '2026-08-18', 'candidate selection date')
  expectEqual(contract.candidateSelection.selectedFromCommit, 'a956145a92a0461d5baca07bb132e7c3ff9185ba', 'candidate selection commit')
  expectEqual(contract.candidateSelection.githubRepository, 'vyakymenko/zigcss', 'candidate repository')
  expectEqual(contract.candidateSelection.githubTagStateAtSelection, 'absent', 'candidate tag selection state')
  expectEqual(contract.candidateSelection.githubReleaseStateAtSelection, 'absent', 'candidate release selection state')
  expectEqual(contract.candidateSelection.npmPackage, 'zigcss', 'candidate npm package')
  expectEqual(contract.candidateSelection.npmVersionStateAtSelection, 'absent', 'candidate npm version selection state')
  const expectedPublished = ['0.2.0', '0.2.1', '0.3.0', '0.4.0-rc.3', '0.6.0-rc.2']
  if (!same(contract.candidateSelection.observedPublishedNpmVersions, expectedPublished)) {
    fail('published npm inventory at candidate selection drifted')
  }

  exactKeys(contract.claimsPolicy, [
    'benchmarkPublicationStatus',
    'comparativeClaimsAllowed',
    'requiredRunner',
    'prohibitedUnverifiedClaim',
  ], 'claimsPolicy')
  expectEqual(contract.claimsPolicy.benchmarkPublicationStatus, 'withdrawn', 'benchmark publication status')
  expectEqual(contract.claimsPolicy.comparativeClaimsAllowed, false, 'comparative claims authority')
  expectEqual(contract.claimsPolicy.requiredRunner, 'controlled non-emulated Linux x64', 'benchmark runner boundary')
  expectEqual(contract.claimsPolicy.prohibitedUnverifiedClaim, "world's fastest", 'prohibited unverified claim')

  exactKeys(contract.terminalContract, [
    'syntaxes',
    'targets',
    'assetsPerTarget',
    'preTagSurfaces',
    'postTagSurfaces',
    'publicationChannels',
    'npmDistTag',
    'githubPrerelease',
    'preservedNpmDistTags',
  ], 'terminalContract')
  if (!same(contract.terminalContract.syntaxes, expectedSyntaxes)) fail('stable syntax inventory drifted')
  if (!same(contract.terminalContract.targets, expectedTargets)) fail('stable target inventory drifted')
  expectEqual(contract.terminalContract.assetsPerTarget, 5, 'assetsPerTarget')
  if (!same(contract.terminalContract.preTagSurfaces, expectedPreTagSurfaces)) fail('pre-tag surface inventory drifted')
  if (!same(contract.terminalContract.postTagSurfaces, expectedPostTagSurfaces)) fail('post-tag surface inventory drifted')
  if (!same(contract.terminalContract.publicationChannels, ['github-stable-release', 'npm-latest', 'github-pages'])) {
    fail('stable publication channel inventory drifted')
  }
  expectEqual(contract.terminalContract.npmDistTag, 'latest', 'stable npm channel')
  expectEqual(contract.terminalContract.githubPrerelease, false, 'stable GitHub prerelease state')
  if (!same(contract.terminalContract.preservedNpmDistTags, { next: '0.6.0-rc.2' })) {
    fail('preserved npm distribution tags drifted')
  }

  if (!Array.isArray(contract.gates) || contract.gates.length !== 10) fail('stable promotion must own exactly ten gates')
  const expectedGateOrder = [...expectedPreTagSurfaces, ...expectedPostTagSurfaces]
  const seen = new Set()
  for (const [index, gate] of contract.gates.entries()) {
    exactKeys(gate, ['id', 'state', 'evidence'], `gates[${index}]`)
    expectEqual(gate.id, expectedGateOrder[index], `gates[${index}].id`)
    if (seen.has(gate.id)) fail(`duplicate stable gate ${gate.id}`)
    seen.add(gate.id)
    if (!['pending', 'verified'].includes(gate.state)) fail(`${gate.id} state is invalid`)
    if (!Array.isArray(gate.evidence)) fail(`${gate.id} evidence must be an array`)
    if (gate.state === 'verified' && gate.evidence.length === 0) fail(`${gate.id} verified without evidence`)
    if (gate.state === 'pending' && gate.evidence.length !== 0) fail(`${gate.id} pending with evidence`)
  }
  return new Map(contract.gates.map(gate => [gate.id, gate]))
}

function validateState(contract, gates) {
  for (const id of initialVerifiedGates) {
    if (gates.get(id)?.state !== 'verified') fail(`foundational stable gate ${id} is not verified`)
  }
  const verifiedPreTag = expectedPreTagSurfaces.every(id => gates.get(id)?.state === 'verified')
  const publicationVerified = gates.get('tag-workflow-publication')?.state === 'verified'
  if (contract.state === 'in-progress') {
    expectEqual(contract.stableReleaseReady, false, 'in-progress stableReleaseReady')
    expectEqual(contract.packageState, 'in-progress', 'in-progress packageState')
    if (verifiedPreTag || publicationVerified || contract.publicationEvidence !== null) {
      fail('in-progress stable promotion has terminal evidence')
    }
  } else if (contract.state === 'candidate-ready') {
    expectEqual(contract.stableReleaseReady, true, 'candidate-ready stableReleaseReady')
    expectEqual(contract.packageState, 'in-progress', 'candidate-ready packageState')
    if (!verifiedPreTag || publicationVerified || contract.publicationEvidence !== null) {
      fail('candidate-ready stable promotion gate state is invalid')
    }
  } else {
    expectEqual(contract.stableReleaseReady, false, 'closed stableReleaseReady')
    expectEqual(contract.packageState, 'verified', 'closed packageState')
    if (!verifiedPreTag || !publicationVerified || contract.publicationEvidence === null) {
      fail('closed stable promotion lacks terminal evidence')
    }
    validatePublicationEvidence(contract.publicationEvidence)
  }
}

function validateSources(contract, gates, sources) {
  const actualPaths = [...sources.keys()].sort()
  const expectedPaths = [...stableReleaseSourcePaths].sort()
  if (!same(actualPaths, expectedPaths)) fail('stable release source inventory drifted')

  const plan = sources.get('DEVELOPMENT_PLAN.md')
  const adr = sources.get('docs/adr/ADR-015-stable-promotion-and-performance-claims.md')
  requireText(plan, 'Plan version: 1.9', 'development plan')
  requireText(plan, '## 18. First stable-promotion and public-evidence sequence', 'development plan')
  requireText(plan, 'one unused immutable `v0.6.0`', 'development plan')
  requireText(adr, '- Status: Accepted', 'ADR-015')
  requireText(adr, 'must not move, delete, or recreate `v0.6.0-rc.2`', 'ADR-015')
  requireText(adr, 'controlled non-emulated Linux x64', 'ADR-015')

  const native = parseJson(sources.get('tests/preprocessors/native/contract.json'), 'native contract')
  expectEqual(native.state, 'native-graduated', 'native contract state')
  expectEqual(native.nativeReleaseReady, true, 'native release evidence')
  expectEqual(native.nativeReleaseVersion, contract.previousPrerelease.version, 'native release version')
  expectEqual(native.releaseGraduation?.state, 'closed', 'native prerelease state')
  expectEqual(native.releaseGraduation?.packageState, 'verified', 'native prerelease package state')
  expectEqual(native.releaseGraduation?.candidateTag, contract.previousPrerelease.tag, 'native prerelease tag')
  expectEqual(native.releaseGraduation?.publicationEvidence?.githubReleaseId, contract.previousPrerelease.githubReleaseId, 'native GitHub release evidence')
  if ((native.adapters ?? []).length !== 5 || native.adapters.some(adapter => adapter.current !== 'native-graduated')) {
    fail('all five native rows must remain graduated')
  }

  const manifest = parseJson(sources.get('package.json'), 'package.json')
  const localGate = gates.get('local-validation')?.state
  const expectedSourceVersion = localGate === 'verified' ? contract.candidateVersion : contract.previousPrerelease.version
  expectEqual(sources.get('VERSION'), `${expectedSourceVersion}\n`, 'current source VERSION')
  expectEqual(manifest.version, expectedSourceVersion, 'current package version')
  if (!same(manifest.dependencies ?? {}, {}) || !same(manifest.optionalDependencies ?? {}, {})) {
    fail('stable package must retain zero production and optional dependencies')
  }
  expectEqual(manifest.scripts?.['test:stable-release'], 'node --test scripts/validate-stable-release.test.mjs', 'stable release test script')
  expectEqual(manifest.scripts?.['check:stable-release'], 'node scripts/validate-stable-release.mjs --check', 'stable release check script')

  const publication = parseJson(sources.get('benchmarks/publication.json'), 'benchmark publication')
  expectEqual(publication.status, contract.claimsPolicy.benchmarkPublicationStatus, 'benchmark publication source status')
  expectEqual(publication.output, 'BENCHMARK_REPORT.md', 'benchmark report output')
  expectEqual(publication.archiveDirectory, null, 'benchmark archive selection')
  expectEqual(publication.artifactUrl, null, 'benchmark artifact selection')
  const benchmarkReport = sources.get('BENCHMARK_REPORT.md')
  requireText(benchmarkReport, 'Performance claims are withdrawn', 'benchmark report')
  requireText(benchmarkReport, 'No controlled scheduled archive has been selected', 'benchmark report')

  const publicSources = [
    ['README.md', sources.get('README.md')],
    ['docs/index.html', sources.get('docs/index.html')],
    ['GettingStarted.tsx', sources.get('docs/src/app/components/GettingStarted.tsx')],
    ['Home.tsx', sources.get('docs/src/app/components/Home.tsx')],
    ['BENCHMARK_REPORT.md', benchmarkReport],
  ]
  const unsupportedClaim = /world(?:'s|’s)[ -]fastest|\b\d+(?:\.\d+)?x faster\b/i
  for (const [label, source] of publicSources) {
    if (unsupportedClaim.test(source)) fail(`${label} contains an unverified comparative claim`)
  }
  if (contract.state === 'closed') {
    requireText(sources.get('README.md'), 'npm `latest` serves `zigcss@0.6.0`', 'README stable publication')
    requireText(sources.get('README.md'), 'npm install --save-dev zigcss', 'README stable install')
    requireText(sources.get('docs/index.html'), 'ZIGCSS 0.6.0 · STABLE RELEASE', 'site stable publication')
    requireText(sources.get('docs/src/app/components/GettingStarted.tsx'), 'ZigCSS 0.6.0 is published on npm latest', 'getting-started stable publication')
    requireText(sources.get('docs/src/app/components/Home.tsx'), '0.6.0 · STABLE RELEASE · ZERO RUNTIME DEPENDENCIES', 'home stable publication')
  }

  const workflow = sources.get('.github/workflows/release.yml')
  requireText(workflow, 'npm run check:stable-release -- \\', 'stable release workflow gate')
  requireText(workflow, '--release-tag "$GITHUB_REF_NAME"', 'stable release tag gate')
  requireText(workflow, '--github-output "$GITHUB_OUTPUT"', 'release channel output gate')
  requireText(workflow, 'release-channel: ${{ steps.npm-policy.outputs.channel }}', 'release channel job output')
  requireText(workflow, 'github-prerelease: ${{ steps.npm-policy.outputs.github_prerelease }}', 'GitHub prerelease job output')
  expectLiteralCount(workflow, 'npm publish --tag "$RELEASE_CHANNEL" --provenance', 1, 'channel-aware npm publication')
  requireText(workflow, 'prerelease: ${{ needs.npm-preflight.outputs.github-prerelease }}', 'channel-aware GitHub release')
  requireText(workflow, '- name: Verify npm publication', 'generic npm publication readback')
}

function validateReleaseAttempt(contract, gates, options) {
  if (options === undefined) return
  const keys = Object.keys(options).sort()
  if (!same(keys, ['candidateCommit', 'originMainCommit', 'releaseTag'])) fail('release attempt options are incomplete')
  if (contract.state !== 'candidate-ready' || contract.stableReleaseReady !== true) {
    fail('stable candidate is not release-ready')
  }
  for (const id of expectedPreTagSurfaces) {
    if (gates.get(id)?.state !== 'verified') fail(`pre-tag gate ${id} is not verified`)
  }
  if (gates.get('tag-workflow-publication')?.state !== 'pending') fail('stable publication gate is not pending')
  validateReleaseTag(contract.candidateVersion, options.releaseTag)
  if (!canonicalCommit.test(options.candidateCommit) || !canonicalCommit.test(options.originMainCommit)) {
    fail('candidate and origin main commits must be canonical lowercase SHA-1 identities')
  }
  if (options.candidateCommit !== options.originMainCommit) fail('candidate commit must equal origin main commit')
}

export function validateStableReleaseContract(contract, sources, options) {
  const gates = validateContractShape(contract)
  validateState(contract, gates)
  validateSources(contract, gates, sources)
  validateReleaseAttempt(contract, gates, options)
  return {
    version: contract.candidateVersion,
    tag: contract.candidateTag,
    state: contract.state,
    verifiedGates: contract.gates.filter(gate => gate.state === 'verified').length,
    totalGates: contract.gates.length,
  }
}

function confinedRegularFile(root, relativePath) {
  const candidate = path.resolve(root, relativePath)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${relativePath} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) {
    fail(`${relativePath} must be a bounded regular non-symlink file`)
  }
  const canonical = fs.realpathSync(candidate)
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${relativePath} escapes the repository`)
  }
  return canonical
}

export function readStableReleaseSources(root = repositoryRoot) {
  const canonicalRoot = fs.realpathSync(root)
  return new Map(stableReleaseSourcePaths.map(relativePath => [
    relativePath,
    fs.readFileSync(confinedRegularFile(canonicalRoot, relativePath), 'utf8').replaceAll('\r\n', '\n'),
  ]))
}

export function readStableReleaseContract(root = repositoryRoot) {
  const canonicalRoot = fs.realpathSync(root)
  return parseJson(
    fs.readFileSync(confinedRegularFile(canonicalRoot, 'release/stable-promotion.json'), 'utf8'),
    'stable promotion contract',
  )
}

function parseArgs(args) {
  if (args.length === 1 && args[0] === '--check') return undefined
  if (args.length !== 7 || args[0] !== '--check') {
    fail('usage: --check [--release-tag vX.Y.Z --candidate-commit sha --origin-main-commit sha]')
  }
  const values = {}
  for (let index = 1; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!['--release-tag', '--candidate-commit', '--origin-main-commit'].includes(name) || value === undefined || Object.hasOwn(values, name)) {
      fail('usage: --check [--release-tag vX.Y.Z --candidate-commit sha --origin-main-commit sha]')
    }
    values[name] = value
  }
  return {
    releaseTag: values['--release-tag'],
    candidateCommit: values['--candidate-commit'],
    originMainCommit: values['--origin-main-commit'],
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2))
  const result = validateStableReleaseContract(
    readStableReleaseContract(),
    readStableReleaseSources(),
    options,
  )
  process.stdout.write(
    `Stable release promotion verified: ${result.version} (${result.state}), ${result.verifiedGates}/${result.totalGates} gates.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
