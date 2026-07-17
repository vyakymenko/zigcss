#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const contractPath = path.join(
  repositoryRoot,
  'tests/preprocessors/native/contract.json',
)

const expectedBoundary = Object.freeze({
  compilerImplementation: 'single-zig-binary-and-library',
  packageDependencies: 0,
  packageOptionalDependencies: 0,
  externalLanguageEngines: 0,
  compileChildProcesses: 0,
  compileNetworkAccess: false,
  runtimeDownloads: false,
  nonSystemDynamicLanguageLibraries: 0,
  allowedSystemBoundary: 'zig-standard-library-and-host-operating-system-abi',
})

const expectedReferenceOracles = Object.freeze([
  Object.freeze({
    id: 'dart-sass',
    package: 'sass',
    version: '1.101.0',
    license: 'MIT',
    adapters: Object.freeze(['scss', 'sass']),
    currentReferencePackage: true,
    productionInNativeTarget: false,
  }),
  Object.freeze({
    id: 'less',
    package: 'less',
    version: '4.6.7',
    license: 'Apache-2.0',
    adapters: Object.freeze(['less']),
    currentReferencePackage: true,
    productionInNativeTarget: false,
  }),
  Object.freeze({
    id: 'stylus',
    package: 'stylus',
    version: '0.64.0',
    license: 'MIT',
    adapters: Object.freeze(['stylus']),
    currentReferencePackage: true,
    productionInNativeTarget: false,
  }),
])

const expectedCurrentDependencies = Object.freeze({
  'image-size': '0.5.5',
  less: '4.6.7',
  sass: '1.101.0',
  stylus: '0.64.0',
})

const expectedAdapterIds = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus'])
const expectedFoundations = Object.freeze([
  Object.freeze({
    id: 'shared-lossless-lexer',
    current: 'native-foundation',
    ownerPackage: 'NATIVE-002',
    nativeSources: Object.freeze([
      'src/preprocessor.zig',
      'src/preprocessor/lexer.zig',
    ]),
    testSources: Object.freeze(['tests/native-preprocessor/lexer.zig']),
    testStep: 'test-native-preprocessor',
  }),
  Object.freeze({
    id: 'shared-semantic-primitives',
    current: 'native-foundation',
    ownerPackage: 'NATIVE-003',
    nativeSources: Object.freeze([
      'src/preprocessor/source.zig',
      'src/preprocessor/syntax.zig',
      'src/preprocessor/value.zig',
      'src/preprocessor/environment.zig',
      'src/preprocessor/budget.zig',
      'src/preprocessor/diagnostics.zig',
      'src/preprocessor/sourcemap.zig',
    ]),
    testSources: Object.freeze(['tests/native-preprocessor/foundation.zig']),
    testStep: 'test-native-preprocessor',
  }),
])
const nativeOwnerPrefixes = Object.freeze([
  'NATIVE-',
  'NSASS-',
  'NLESS-',
  'NSTYLUS-',
])

function fail(message) {
  throw new Error(`native contract: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (!same(actual, wanted)) {
    fail(`${label} keys must be ${JSON.stringify(wanted)}, found ${JSON.stringify(actual)}`)
  }
}

function repositoryFile(relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath)) {
    fail(`invalid repository file path: ${JSON.stringify(relativePath)}`)
  }
  const resolved = path.resolve(repositoryRoot, relativePath)
  if (!resolved.startsWith(`${repositoryRoot}${path.sep}`)) {
    fail(`repository file escapes root: ${relativePath}`)
  }
  const stat = fs.lstatSync(resolved)
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`repository file must be a regular non-symlink: ${relativePath}`)
  }
  return resolved
}

function loadJson(relativePath) {
  return JSON.parse(fs.readFileSync(repositoryFile(relativePath), 'utf8'))
}

export function loadContract() {
  return loadJson('tests/preprocessors/native/contract.json')
}

function requireText(source, needle, label) {
  if (!source.includes(needle)) fail(`${label} is missing ${JSON.stringify(needle)}`)
}

function validateAdapter(adapter, index, plan) {
  const label = `adapters[${index}]`
  exactKeys(adapter, ['id', 'current', 'target', 'ownerPackages', 'nativeSources'], label)
  if (adapter.id !== expectedAdapterIds[index]) {
    fail(`${label}.id must be ${expectedAdapterIds[index]}, found ${JSON.stringify(adapter.id)}`)
  }
  if (adapter.target !== 'native-graduated') {
    fail(`${label}.target must be native-graduated`)
  }
  if (!Array.isArray(adapter.ownerPackages) || adapter.ownerPackages.length === 0) {
    fail(`${label}.ownerPackages must be a non-empty array`)
  }
  if (!Array.isArray(adapter.nativeSources)) fail(`${label}.nativeSources must be an array`)

  for (const owner of adapter.ownerPackages) {
    if (typeof owner !== 'string' || owner.length === 0) fail(`${label} has an invalid owner package`)
    if (adapter.id !== 'css' && !nativeOwnerPrefixes.some(prefix => owner.startsWith(prefix))) {
      fail(`${label} owner is outside the native roadmap: ${owner}`)
    }
    requireText(plan, `\`${owner}\``, 'DEVELOPMENT_PLAN.md')
  }

  for (const source of adapter.nativeSources) repositoryFile(source)

  if (adapter.id === 'css') {
    if (adapter.current !== 'native-graduated') fail('CSS must remain native-graduated')
    if (!same(adapter.nativeSources, ['src/tokenizer.zig', 'src/css.zig'])) {
      fail('CSS native source inventory drifted')
    }
  } else {
    if (adapter.current !== 'reference-only') {
      fail(`${adapter.id} must remain reference-only until its native graduation package`)
    }
    if (adapter.nativeSources.length !== 0) {
      fail(`${adapter.id} cannot claim native sources before native graduation`)
    }
  }
}

function validateFoundation(foundation, index, plan) {
  const label = `foundations[${index}]`
  exactKeys(
    foundation,
    ['id', 'current', 'ownerPackage', 'nativeSources', 'testSources', 'testStep'],
    label,
  )
  if (!same(foundation, expectedFoundations[index])) {
    fail(`${label} inventory drifted`)
  }
  requireText(plan, `\`${foundation.ownerPackage}\``, 'DEVELOPMENT_PLAN.md')
  for (const source of foundation.nativeSources) repositoryFile(source)
  for (const source of foundation.testSources) repositoryFile(source)
}

export function validateContract(
  contract,
  {
    manifest = loadJson('package.json'),
    plan = fs.readFileSync(repositoryFile('DEVELOPMENT_PLAN.md'), 'utf8'),
    decision = fs.readFileSync(
      repositoryFile('docs/adr/ADR-013-self-contained-native-frontends.md'),
      'utf8',
    ),
    readme = fs.readFileSync(repositoryFile('README.md'), 'utf8'),
    buildWorkflow = fs.readFileSync(repositoryFile('.github/workflows/build.yml'), 'utf8'),
    releaseWorkflow = fs.readFileSync(repositoryFile('.github/workflows/release.yml'), 'utf8'),
  } = {},
) {
  exactKeys(
    contract,
    [
      'schemaVersion',
      'state',
      'nativeReleaseReady',
      'nativeReleaseVersion',
      'referenceCandidate',
      'targetRelease',
      'decision',
      'productionBoundary',
      'referenceOracles',
      'foundations',
      'adapters',
    ],
    'root',
  )
  if (contract.schemaVersion !== 2) fail('schemaVersion must be 2')
  if (contract.state !== 'native-foundation') fail('state must be native-foundation in NATIVE-002')
  if (contract.nativeReleaseReady !== false) fail('native release must remain fail-closed')
  if (contract.nativeReleaseVersion !== null) fail('nativeReleaseVersion must remain null while closed')
  if (contract.referenceCandidate !== '0.5.0-rc.1') fail('reference candidate drifted')
  if (contract.targetRelease !== '0.6.0') fail('targetRelease must be 0.6.0')
  if (contract.decision !== 'ADR-013') fail('decision must be ADR-013')
  if (!same(contract.productionBoundary, expectedBoundary)) fail('production boundary drifted')
  if (!same(contract.referenceOracles, expectedReferenceOracles)) fail('reference oracle inventory drifted')
  if (!Array.isArray(contract.foundations) || contract.foundations.length !== expectedFoundations.length) {
    fail(`foundation inventory must contain ${expectedFoundations.length} rows`)
  }
  if (!Array.isArray(contract.adapters) || contract.adapters.length !== expectedAdapterIds.length) {
    fail(`adapter inventory must contain ${expectedAdapterIds.length} rows`)
  }

  if (manifest.version !== contract.referenceCandidate) fail('package version is not the reference candidate')
  if (!same(manifest.dependencies, expectedCurrentDependencies)) {
    fail('current canonical reference dependency graph drifted before native replacement')
  }
  if (manifest.optionalDependencies !== undefined && Object.keys(manifest.optionalDependencies).length !== 0) {
    fail('current package has unexpected optionalDependencies')
  }
  if (manifest.scripts?.['check:native-contract'] !== 'node scripts/validate-native-contract.mjs --check') {
    fail('package script check:native-contract is missing or changed')
  }
  if (manifest.scripts?.['test:native-contract'] !== 'node --test scripts/validate-native-contract.test.mjs') {
    fail('package script test:native-contract is missing or changed')
  }

  for (const [index, foundation] of contract.foundations.entries()) {
    validateFoundation(foundation, index, plan)
  }
  for (const [index, adapter] of contract.adapters.entries()) validateAdapter(adapter, index, plan)

  requireText(plan, 'Plan version: 1.2', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## Milestone 10: Self-contained native stylesheet frontends', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## 17. First self-contained-native autonomous sequence', 'DEVELOPMENT_PLAN.md')
  requireText(decision, '- Status: Accepted', 'ADR-013')
  requireText(decision, 'zero `dependencies` and zero `optionalDependencies`', 'ADR-013')
  requireText(decision, 'All tag-triggered releases are fail-closed', 'ADR-013')
  requireText(readme, 'Native dependency-free migration', 'README.md')

  const buildGate = 'npm run test:native-contract && npm run check:native-contract'
  requireText(buildWorkflow, buildGate, 'build workflow')
  requireText(
    buildWorkflow,
    'zig build test-native-preprocessor --summary all',
    'build workflow',
  )
  const releaseGate = 'npm run check:native-contract -- --release-tag "$GITHUB_REF_NAME"'
  requireText(releaseWorkflow, releaseGate, 'release workflow')
  if (releaseWorkflow.indexOf(releaseGate) > releaseWorkflow.indexOf('npm whoami')) {
    fail('release interlock must run before npm authentication/publication preflight')
  }

  return contract
}

export function validateReleaseTag(contract, tag) {
  if (typeof tag !== 'string' || !/^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(tag)) {
    fail(`invalid release tag: ${JSON.stringify(tag)}`)
  }
  if (!contract.nativeReleaseReady) {
    fail(`release ${tag} rejected: native frontends are not graduated`)
  }
  if (contract.nativeReleaseVersion === null || tag !== `v${contract.nativeReleaseVersion}`) {
    fail(`release tag ${tag} does not match the graduated native version`)
  }
}

function main() {
  const [mode, value, extra] = process.argv.slice(2)
  if (extra !== undefined || (mode !== '--check' && mode !== '--release-tag')) {
    fail('usage: node scripts/validate-native-contract.mjs --check|--release-tag vX.Y.Z')
  }
  if (mode === '--release-tag' && value === undefined) {
    fail('--release-tag requires a tag')
  }
  if (mode === '--check' && value !== undefined) fail('--check accepts no value')

  const contract = validateContract(loadContract())
  if (mode === '--release-tag') validateReleaseTag(contract, value)
  process.stdout.write(
    `Native contract verified: ${contract.adapters.length} adapters, target ${contract.targetRelease}, release gate ${contract.nativeReleaseReady ? 'open' : 'closed'}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
