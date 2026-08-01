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

const expectedPublicationAuthority = Object.freeze({
  authorized: true,
  authorizedOn: '2026-07-27',
  scope: 'first-fully-graduated-native-release',
  workflow: '.github/workflows/release.yml',
  channels: Object.freeze(['github-prerelease', 'npm-next']),
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
  Object.freeze({
    id: 'confined-local-resolver',
    current: 'native-foundation',
    ownerPackage: 'NATIVE-004',
    nativeSources: Object.freeze(['src/preprocessor/resolver.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/resolver.zig']),
    testStep: 'test-native-preprocessor',
  }),
  Object.freeze({
    id: 'transactional-core-validator',
    current: 'native-foundation',
    ownerPackage: 'NATIVE-005',
    nativeSources: Object.freeze(['src/preprocessor/evaluator.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/evaluator.zig']),
    testStep: 'test-native-preprocessor',
  }),
])
const expectedImplementations = Object.freeze([
  Object.freeze({
    id: 'native-sass-parser',
    current: 'native-internal',
    ownerPackage: 'NSASS-010',
    adapters: Object.freeze(['scss', 'sass']),
    capabilities: Object.freeze(['parsing']),
    nativeSources: Object.freeze(['src/preprocessor/sass.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/sass_parser.zig']),
    testStep: 'test-native-preprocessor',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-sass-semantic-core',
    current: 'native-internal',
    ownerPackage: 'NSASS-011',
    adapters: Object.freeze(['scss', 'sass']),
    capabilities: Object.freeze([
      'variables',
      'variable-modifiers',
      'local-use-single-module-loading-foundation',
      'local-use-callable-member-foundation',
      'local-use-callable-existence-foundation',
      'local-use-callable-reference-foundation',
      'local-use-function-reference-invocation-foundation',
      'local-use-mixin-reference-application-foundation',
      'local-use-mixin-content-inspection-foundation',
      'local-use-function-enumeration-foundation',
      'local-use-mixin-enumeration-foundation',
      'local-use-variable-enumeration-foundation',
      'local-use-callable-variable-ownership-foundation',
      'local-use-callable-argument-ownership-foundation',
      'local-use-callable-result-ownership-foundation',
      'local-use-configuration-foundation',
      'local-use-built-in-callable-configuration-ownership-foundation',
      'local-use-cross-module-callable-configuration-ownership-foundation',
      'local-use-configured-callable-reexport-ownership-foundation',
      'local-use-reexported-callable-configuration-ownership-foundation',
      'local-use-recursive-reexported-callable-configuration-ownership-foundation',
      'local-use-fifth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-sixth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-seventh-module-reexported-callable-configuration-ownership-foundation',
      'local-use-eighth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-ninth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-tenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-eleventh-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twelfth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-fourteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-fifteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-sixteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-seventeenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-eighteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-nineteenth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twentieth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-first-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-second-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-third-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-fourth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-fifth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-sixth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-seventh-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-eighth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-twenty-ninth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirtieth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-first-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-second-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-third-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-fourth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-fifth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-sixth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-seventh-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-eighth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-thirty-ninth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-fortieth-module-reexported-callable-configuration-ownership-foundation',
      'local-use-forty-first-module-reexported-callable-configuration-ownership-foundation',
      'local-use-forty-second-module-reexported-callable-configuration-ownership-foundation',
      'local-use-forty-third-module-reexported-callable-configuration-ownership-foundation',
      'numeric-arithmetic',
      'canonical-number-serialization',
      'unit-conversion',
      'compound-unit-algebra',
      'css-calculations',
      'legacy-color-core',
      'closed-named-colors',
      'color-space-equality',
      'color-channel-accessors',
      'legacy-color-manipulation',
      'keyword-color-transforms',
      'hwb-color-transforms',
      'keyword-argument-binding',
      'fixed-builtin-keyword-binding',
      'color-constructor-keyword-overloads',
      'variadic-map-get-binding',
      'modern-lab-color-constructors',
      'predefined-wide-gamut-colors',
      'cross-space-color-conversion',
      'modern-color-transforms',
      'built-in-color-transform-aliases',
      'built-in-meta-calculation-introspection',
      'built-in-meta-content-existence',
      'built-in-meta-existence-queries',
      'built-in-meta-inspection',
      'built-in-meta-keywords',
      'built-in-meta-mixin-references',
      'built-in-meta-sass-function-references',
      'built-in-meta-callable-inspection',
      'built-in-meta-user-function-invocation',
      'built-in-meta-list-function-invocation',
      'built-in-meta-map-query-function-invocation',
      'built-in-meta-map-mutation-function-invocation',
      'built-in-meta-inspection-function-invocation',
      'built-in-meta-keywords-function-invocation',
      'built-in-meta-content-existence-function-invocation',
      'built-in-meta-call-function-invocation',
      'built-in-meta-get-function-function-invocation',
      'built-in-meta-get-mixin-function-invocation',
      'built-in-meta-reflected-if-function-invocation',
      'built-in-meta-user-mixin-application',
      'built-in-meta-apply-mixin-application',
      'built-in-meta-module-functions-function-invocation',
      'built-in-meta-module-mixins-function-invocation',
      'built-in-meta-module-variables-function-invocation',
      'built-in-meta-content-acceptance-function-invocation',
      'built-in-meta-calculation-function-invocation',
      'built-in-meta-existence-function-invocation',
      'built-in-meta-math-unary-function-invocation',
      'built-in-meta-math-compatibility-function-invocation',
      'built-in-meta-math-unitless-function-invocation',
      'built-in-meta-math-unit-function-invocation',
      'built-in-meta-math-acos-function-invocation',
      'built-in-meta-math-asin-function-invocation',
      'built-in-meta-math-atan-function-invocation',
      'built-in-meta-math-atan2-function-invocation',
      'built-in-meta-math-sin-function-invocation',
      'built-in-meta-math-cos-function-invocation',
      'built-in-meta-math-tan-function-invocation',
      'built-in-meta-math-log-function-invocation',
      'built-in-meta-math-pow-function-invocation',
      'built-in-meta-math-sqrt-function-invocation',
      'built-in-meta-math-div-function-invocation',
      'built-in-meta-math-clamp-function-invocation',
      'built-in-meta-math-hypot-function-invocation',
      'built-in-meta-math-min-function-invocation',
      'built-in-meta-math-max-function-invocation',
      'built-in-meta-math-random-function-invocation',
      'built-in-meta-selector-parse-function-invocation',
      'built-in-meta-selector-simple-selectors-function-invocation',
      'built-in-meta-selector-is-superselector-function-invocation',
      'built-in-meta-selector-unify-function-invocation',
      'built-in-meta-selector-append-function-invocation',
      'built-in-meta-selector-nest-function-invocation',
      'built-in-meta-selector-extend-function-invocation',
      'built-in-meta-selector-replace-function-invocation',
      'built-in-meta-string-quote-function-invocation',
      'built-in-meta-string-unquote-function-invocation',
      'built-in-meta-string-length-function-invocation',
      'built-in-meta-string-index-function-invocation',
      'built-in-meta-string-slice-function-invocation',
      'built-in-meta-string-insert-function-invocation',
      'built-in-meta-string-upper-case-function-invocation',
      'built-in-meta-string-lower-case-function-invocation',
      'built-in-meta-string-split-function-invocation',
      'built-in-string-unique-id-deterministic-rejection',
      'built-in-string-split-direct-splat-expansion',
      'built-in-string-module-quote-direct-splat-expansion',
      'built-in-string-module-unquote-direct-splat-expansion',
      'built-in-string-legacy-quote-direct-splat-expansion',
      'built-in-string-legacy-unquote-direct-splat-expansion',
      'built-in-string-legacy-upper-case-direct-splat-expansion',
      'built-in-string-legacy-lower-case-direct-splat-expansion',
      'built-in-string-legacy-length-direct-splat-expansion',
      'built-in-string-legacy-index-direct-splat-expansion',
      'built-in-string-legacy-slice-direct-splat-expansion',
      'built-in-string-legacy-insert-direct-splat-expansion',
      'built-in-string-module-length-direct-splat-expansion',
      'built-in-string-module-index-direct-splat-expansion',
      'built-in-string-module-slice-direct-splat-expansion',
      'built-in-string-module-insert-direct-splat-expansion',
      'built-in-string-module-upper-case-direct-splat-expansion',
      'built-in-string-module-lower-case-direct-splat-expansion',
      'built-in-meta-color-adjust-function-invocation',
      'built-in-meta-color-change-function-invocation',
      'built-in-meta-color-scale-function-invocation',
      'built-in-meta-color-rgb-function-invocation',
      'built-in-meta-color-rgba-function-invocation',
      'built-in-meta-color-hsl-function-invocation',
      'built-in-meta-color-hsla-function-invocation',
      'built-in-meta-color-hwb-function-invocation',
      'built-in-meta-color-lab-function-invocation',
      'built-in-meta-color-lch-function-invocation',
      'built-in-meta-color-oklab-function-invocation',
      'built-in-meta-color-oklch-function-invocation',
      'built-in-meta-color-function-invocation',
      'built-in-meta-color-red-function-invocation',
      'built-in-meta-color-green-function-invocation',
      'built-in-meta-color-blue-function-invocation',
      'built-in-meta-color-alpha-function-invocation',
      'built-in-meta-color-opacity-function-invocation',
      'built-in-meta-color-hue-function-invocation',
      'built-in-meta-color-saturation-function-invocation',
      'built-in-meta-color-lightness-function-invocation',
      'built-in-meta-color-whiteness-function-invocation',
      'built-in-color-module-whiteness-direct-function-invocation',
      'built-in-meta-color-blackness-function-invocation',
      'built-in-color-module-blackness-direct-function-invocation',
      'built-in-meta-color-mix-function-invocation',
      'built-in-color-module-mix-direct-function-invocation',
      'built-in-color-legacy-mix-direct-splat-expansion',
      'built-in-meta-color-lighten-function-invocation',
      'built-in-color-legacy-lighten-direct-splat-expansion',
      'built-in-meta-color-darken-function-invocation',
      'built-in-color-legacy-darken-direct-splat-expansion',
      'built-in-meta-color-saturate-function-invocation',
      'built-in-color-legacy-saturate-direct-splat-expansion',
      'built-in-meta-color-desaturate-function-invocation',
      'built-in-color-legacy-desaturate-direct-splat-expansion',
      'built-in-meta-color-adjust-hue-function-invocation',
      'built-in-color-legacy-adjust-hue-direct-splat-expansion',
      'built-in-meta-color-complement-function-invocation',
      'built-in-color-module-complement-direct-splat-expansion',
      'built-in-color-legacy-complement-direct-splat-expansion',
      'built-in-meta-color-grayscale-function-invocation',
      'built-in-color-module-grayscale-direct-splat-expansion',
      'built-in-color-legacy-grayscale-direct-splat-expansion',
      'built-in-meta-color-invert-function-invocation',
      'built-in-color-module-invert-direct-splat-expansion',
      'built-in-color-legacy-invert-direct-splat-expansion',
      'built-in-meta-color-opacify-function-invocation',
      'built-in-color-legacy-opacify-direct-splat-expansion',
      'built-in-meta-color-fade-in-function-invocation',
      'built-in-color-legacy-fade-in-direct-splat-expansion',
      'built-in-meta-color-transparentize-function-invocation',
      'built-in-color-legacy-transparentize-direct-splat-expansion',
      'built-in-meta-color-fade-out-function-invocation',
      'built-in-color-legacy-fade-out-direct-splat-expansion',
      'built-in-color-legacy-alpha-missing-channel-semantics',
      'built-in-color-legacy-alpha-compound-unit-semantics',
      'built-in-color-legacy-alpha-modern-color-rejection-semantics',
      'built-in-meta-color-ie-hex-str-function-invocation',
      'built-in-meta-color-space-function-invocation',
      'built-in-meta-color-to-space-function-invocation',
      'built-in-meta-color-is-legacy-function-invocation',
      'built-in-meta-color-is-missing-function-invocation',
      'built-in-meta-color-is-in-gamut-function-invocation',
      'built-in-meta-color-to-gamut-function-invocation',
      'built-in-meta-color-channel-function-invocation',
      'built-in-meta-color-same-function-invocation',
      'built-in-meta-color-is-powerless-function-invocation',
      'built-in-meta-calc-function-reference-rejection',
      'built-in-meta-content-acceptance',
      'plain-css-function-argument-evaluation',
      'built-in-selector-parse-simple',
      'built-in-selector-composition',
      'built-in-selector-relations',
      'built-in-selector-extend-replace-compound',
      'built-in-selector-extend-replace-compound-lists',
      'built-in-selector-extend-replace-normalized-compounds',
      'built-in-selector-attribute-normalization',
      'built-in-selector-escape-normalization',
      'built-in-selector-simple-pseudo-normalization',
      'built-in-selector-list-functional-pseudo-normalization',
      'built-in-selector-list-functional-pseudo-relations',
      'built-in-selector-list-functional-pseudo-extend-replace',
      'built-in-selector-nth-function-grammar',
      'built-in-selector-lang-functional-pseudo-grammar',
      'built-in-selector-dir-functional-pseudo-grammar',
      'built-in-selector-unify-compound',
      'built-in-selector-unify-complex-strict',
      'built-in-selector-unify-complex-weave-disjoint',
      'built-in-selector-unify-complex-weave-shared-lcs',
      'built-in-selector-unify-complex-weave-shared-rigid',
      'built-in-selector-unify-complex-weave-terminal-siblings',
      'built-in-map-queries',
      'shallow-map-mutations',
      'nested-deep-map-mutations',
      'built-in-list-module-aliases',
      'built-in-list-queries',
      'built-in-list-transformations',
      'built-in-list-join',
      'built-in-list-zip',
      'built-in-list-slash',
      'built-in-math-constants-deterministic-random',
      'built-in-math-division',
      'built-in-math-extrema-hypotenuse',
      'built-in-math-powers-roots-logarithms',
      'built-in-math-trigonometry',
      'built-in-math-unit-predicates',
      'built-in-math-unit-serialization',
      'built-in-math-unary-numeric',
      'unicode-string-core',
      'legacy-string-builtins',
      'built-in-string-module-aliases',
      'typed-collections',
      'collection-accessors',
      'logical-comparison',
      'lazy-conditional-emission',
      'lazy-legacy-if-function',
      'legacy-if-final-splat-expansion',
      'legacy-if-single-misplaced-rest-expansion',
      'legacy-if-dual-splat-expansion',
      'diagnostic-deprecation-source-deduplication',
      'flow-control-variable-scope',
      'bounded-control-flow-loops',
      'bounded-user-functions',
      'bounded-user-mixins-content',
      'callable-rest-splat-content-parameters',
      'interpolation',
      'lexical-scope',
      'selector-nesting',
      'nested-properties',
      'transactional-css-staging',
    ]),
    nativeSources: Object.freeze([
      'src/preprocessor/sass_evaluator.zig',
      'src/preprocessor/sass_arguments.zig',
      'src/preprocessor/sass_numeric.zig',
      'src/preprocessor/sass_color.zig',
      'src/preprocessor/sass_string.zig',
      'src/preprocessor/sass_selector.zig',
    ]),
    testSources: Object.freeze([
      'tests/native-preprocessor/sass_evaluator.zig',
      'tests/native-preprocessor/sass_arguments.zig',
      'tests/native-preprocessor/sass_numeric.zig',
      'tests/native-preprocessor/sass_color.zig',
      'tests/native-preprocessor/sass_string.zig',
      'tests/native-preprocessor/sass_selector.zig',
    ]),
    testStep: 'test-native-preprocessor',
    publicAvailable: false,
    productionReachable: false,
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

export function loadProductionSources(relativeDirectory = 'src') {
  const files = []
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name)
      if (entry.isSymbolicLink()) fail(`production source inventory contains a symlink: ${absolute}`)
      if (entry.isDirectory()) {
        visit(absolute)
      } else if (entry.isFile() && entry.name.endsWith('.zig')) {
        const relative = path.relative(repositoryRoot, absolute).split(path.sep).join('/')
        files.push([relative, fs.readFileSync(absolute, 'utf8')])
      }
    }
  }
  visit(path.join(repositoryRoot, relativeDirectory))
  return files.sort(([left], [right]) => left.localeCompare(right))
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

function validateImplementation(implementation, index, contract, plan) {
  const label = `implementations[${index}]`
  exactKeys(
    implementation,
    [
      'id',
      'current',
      'ownerPackage',
      'adapters',
      'capabilities',
      'nativeSources',
      'testSources',
      'testStep',
      'publicAvailable',
      'productionReachable',
    ],
    label,
  )
  if (!same(implementation, expectedImplementations[index])) {
    fail(`${label} inventory drifted`)
  }
  requireText(plan, `\`${implementation.ownerPackage}\``, 'DEVELOPMENT_PLAN.md')
  for (const adapterId of implementation.adapters) {
    const adapter = contract.adapters.find(candidate => candidate.id === adapterId)
    if (adapter === undefined) fail(`${label} references unknown adapter ${adapterId}`)
    if (adapter.current !== 'reference-only') {
      fail(`${label} cannot coexist with a prematurely graduated ${adapterId} adapter`)
    }
  }
  for (const source of implementation.nativeSources) repositoryFile(source)
  for (const source of implementation.testSources) repositoryFile(source)
}

function validateInternalReachability(implementations, buildFile, productionSources) {
  requireText(buildFile, 'root_source_file = b.path("src/preprocessor.zig")', 'build.zig')
  for (const implementation of implementations) {
    for (const testSource of implementation.testSources) {
      requireText(
        buildFile,
        `root_source_file = b.path("${testSource}")`,
        `${implementation.id} test wiring`,
      )
    }
  }
  const forbiddenImports = [
    '@import("preprocessor.zig")',
    '@import("preprocessor/',
    '@import("native_preprocessor")',
  ]
  for (const [relativePath, source] of productionSources) {
    if (relativePath === 'src/preprocessor.zig' || relativePath.startsWith('src/preprocessor/')) {
      continue
    }
    for (const forbidden of forbiddenImports) {
      if (source.includes(forbidden)) {
        fail(`${relativePath} makes the unavailable native frontend production-reachable`)
      }
    }
  }
}

function validateNativeImportClosure(contract, productionSources) {
  const nativeSources = new Set([
    ...contract.foundations.flatMap(foundation => foundation.nativeSources),
    ...contract.implementations.flatMap(implementation => implementation.nativeSources),
  ])
  const sourceByPath = new Map(productionSources)
  const allowedBuiltinModules = new Set(['std', 'builtin'])
  const pending = [...nativeSources]
  const visited = new Set()
  while (pending.length > 0) {
    const relativePath = pending.pop()
    if (visited.has(relativePath)) continue
    visited.add(relativePath)
    const source = sourceByPath.get(relativePath)
    if (source === undefined) fail(`native import closure is missing ${relativePath}`)
    const calls = [...source.matchAll(/@import\s*\(/g)]
    const imports = [...source.matchAll(/@import\s*\(\s*"([^"]+)"\s*\)/g)]
    if (calls.length !== imports.length) {
      fail(`${relativePath} contains a non-literal or malformed native import`)
    }
    for (const match of imports) {
      const specifier = match[1]
      if (allowedBuiltinModules.has(specifier)) continue
      if (!specifier.endsWith('.zig') || path.isAbsolute(specifier)) {
        fail(`${relativePath} imports external module ${JSON.stringify(specifier)}`)
      }
      const resolved = path.resolve(repositoryRoot, path.dirname(relativePath), specifier)
      const relative = path.relative(repositoryRoot, resolved).split(path.sep).join('/')
      if (!relative.startsWith('src/') || !sourceByPath.has(relative)) {
        fail(`${relativePath} import escapes the owned Zig source closure: ${specifier}`)
      }
      repositoryFile(relative)
      pending.push(relative)
    }
  }
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
    buildFile = fs.readFileSync(repositoryFile('build.zig'), 'utf8'),
    productionSources = loadProductionSources(),
  } = {},
) {
  exactKeys(
    contract,
    [
      'schemaVersion',
      'state',
      'nativeReleaseReady',
      'nativeReleaseVersion',
      'nativePublicationAuthority',
      'referenceCandidate',
      'targetRelease',
      'decision',
      'productionBoundary',
      'referenceOracles',
      'foundations',
      'implementations',
      'adapters',
    ],
    'root',
  )
  if (contract.schemaVersion !== 4) fail('schemaVersion must be 4')
  if (contract.state !== 'native-foundation') fail('state must remain native-foundation during Milestone 10')
  if (contract.nativeReleaseReady !== false) fail('native release must remain fail-closed')
  if (contract.nativeReleaseVersion !== null) fail('nativeReleaseVersion must remain null while closed')
  if (!same(contract.nativePublicationAuthority, expectedPublicationAuthority)) {
    fail('native publication authority drifted')
  }
  if (contract.referenceCandidate !== '0.5.0-rc.1') fail('reference candidate drifted')
  if (contract.targetRelease !== '0.6.0') fail('targetRelease must be 0.6.0')
  if (contract.decision !== 'ADR-013') fail('decision must be ADR-013')
  if (!same(contract.productionBoundary, expectedBoundary)) fail('production boundary drifted')
  if (!same(contract.referenceOracles, expectedReferenceOracles)) fail('reference oracle inventory drifted')
  if (!Array.isArray(contract.foundations) || contract.foundations.length !== expectedFoundations.length) {
    fail(`foundation inventory must contain ${expectedFoundations.length} rows`)
  }
  if (!Array.isArray(contract.implementations) ||
      contract.implementations.length !== expectedImplementations.length) {
    fail(`implementation inventory must contain ${expectedImplementations.length} rows`)
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
  for (const [index, implementation] of contract.implementations.entries()) {
    validateImplementation(implementation, index, contract, plan)
  }
  validateInternalReachability(contract.implementations, buildFile, productionSources)
  validateNativeImportClosure(contract, productionSources)

  requireText(plan, 'Plan version: 1.3', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## Milestone 10: Self-contained native stylesheet frontends', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## 17. First self-contained-native autonomous sequence', 'DEVELOPMENT_PLAN.md')
  requireText(decision, '- Status: Accepted', 'ADR-013')
  requireText(decision, 'zero `dependencies` and zero `optionalDependencies`', 'ADR-013')
  requireText(decision, 'All tag-triggered releases are fail-closed', 'ADR-013')
  requireText(decision, 'first fully graduated native candidate', 'ADR-013')
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
  requireText(releaseWorkflow, 'npm publish --tag next --provenance', 'release workflow')
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
  if (contract.nativePublicationAuthority?.authorized !== true) {
    fail(`release ${tag} rejected: native publication is not authorized`)
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
