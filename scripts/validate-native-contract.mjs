#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateBuildTestGraph } from './validate-workflows.mjs'

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

const expectedSassEvaluatorClosure = Object.freeze({
  ownerPackage: 'NSASS-011',
  releaseGapFamily: 'native-sass-evaluation',
  state: 'closed',
  packageState: 'verified',
  oracle: Object.freeze({
    id: 'dart-sass',
    package: 'sass',
    version: '1.101.0',
    selection: 'tests/preprocessors/sass/corpus/selection.json',
    caseCount: 80,
  }),
  terminalContract: Object.freeze({
    syntaxes: Object.freeze(['scss', 'sass']),
    callableKinds: Object.freeze(['function', 'mixin']),
    argumentOwnerClasses: Object.freeze(['caller', 'earlier-peer', 'later-peer']),
    reflectedContentOwnerClasses: Object.freeze([
      'receiver',
      'configured',
      'reexported',
      'caller',
      'peer',
    ]),
    maxArgumentTransportEdges: 1,
    reflectedContentOutcome: 'reject-with-exact-syntax-diagnostic',
    reflectedContentDiagnostic: "Mixin doesn't accept a content block.",
  }),
  evidenceTests: Object.freeze([
    'native Sass owns caller callables across one-hop local module calls',
    'native Sass caller callable arguments handle every allocation failure',
    'native Sass owns peer callables across one-hop local module calls',
    'native Sass peer callable arguments handle every allocation failure',
    'native Sass re-exported peer callable arguments fail without partial CSS',
    'native Sass rejects caller and peer callable content transport through meta.apply',
    'native Sass rejects same-engine mixin content through meta.apply',
    'native Sass meta.apply mixin content rejection handles every allocation failure',
  ]),
  remainingPlanDomain: Object.freeze({
    releaseGapFamily: 'native-sass-dynamic-loading',
    features: Object.freeze([]),
    referenceCases: Object.freeze([]),
    completedSlices: Object.freeze([
      Object.freeze({
        feature: 'use-resolution',
        state: 'native-foundation',
        referenceCases: Object.freeze([
          'scss-use-sass-extension',
          'scss-use-scss-extension',
          'scss-use-import-only-exclusion',
          'scss-use-partial-index',
        ]),
        evidenceTests: Object.freeze([
          'native Sass resolves the pinned one-hop use selection matrix',
          'native Sass local use handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'transitive-use',
        state: 'native-foundation',
        referenceCases: Object.freeze([]),
        evidenceTests: Object.freeze([
          'native Sass evaluates the pinned transitive use graph once',
          'native Sass transitive use preserves parent callable ownership',
          'native Sass transitive local use enforces graph limits without partial CSS',
          'native Sass transitive use graph handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'forward-config',
        state: 'native-foundation',
        referenceCases: Object.freeze(['scss-forward-config']),
        evidenceTests: Object.freeze([
          'native Sass forwards the pinned configured module once',
          'native Sass exposes forwarded public variables without duplicate evaluation',
          'native Sass forward configuration failures own exact diagnostics',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'forward-callables',
        state: 'native-foundation',
        referenceCases: Object.freeze([]),
        evidenceTests: Object.freeze([
          'native Sass exposes forwarded public callables without duplicate evaluation',
          'native Sass local callables override forwarded members',
          'native Sass forward configuration failures own exact diagnostics',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'forward-terminal-contract',
        state: 'native-foundation',
        referenceCases: Object.freeze([]),
        evidenceTests: Object.freeze([
          'native Sass forward prefix and filters cover the finite public member contract',
          'native Sass forward covers the finite built-in module inventory',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'legacy-import',
        state: 'native-foundation',
        referenceCases: Object.freeze(['scss-import-import-only']),
        evidenceTests: Object.freeze([
          'native Sass resolves the pinned legacy import-only precedence',
          'native Sass legacy import rejects malformed directives without partial CSS',
          'native Sass legacy import handles every allocation failure',
        ]),
      }),
      Object.freeze({
        feature: 'meta-load-css',
        state: 'native-foundation',
        referenceCases: Object.freeze(['scss-meta-load-css']),
        evidenceTests: Object.freeze([
          'native Sass executes the pinned meta load css terminal contract',
          'native Sass meta load css rejects unavailable modules without partial CSS',
          'native Sass meta load css handles every allocation failure',
        ]),
      }),
    ]),
  }),
  conformancePackage: 'NSASS-012',
})

const expectedSassConformance = Object.freeze({
  ownerPackage: 'NSASS-012',
  releaseGapFamily: 'native-sass-conformance',
  state: 'closed',
  packageState: 'verified',
  oracle: Object.freeze({
    id: 'dart-sass',
    package: 'sass',
    version: '1.101.0',
    selection: 'tests/preprocessors/sass/corpus/selection.json',
    manifest: 'tests/preprocessors/sass/corpus/manifest.json',
    caseCount: 80,
  }),
  completedCaseCount: 80,
  remainingCaseCount: 0,
  terminalContract: Object.freeze({
    selectionDerived: true,
    successCaseCount: 60,
    errorCaseCount: 20,
    deterministicRunsPerSuccessCase: 2,
    fuzzMutationsPerCase: 3,
    maxConcurrentCompilations: 4,
    evidenceTests: Object.freeze([
      'native Sass closes the finite pinned success corpus deterministically',
      'native Sass rejects the finite pinned error corpus deterministically',
      'native Sass parser owns finite resource and cancellation boundaries',
      'native Sass compilation is deterministic under bounded concurrency',
      'native Sass finite corpus seeds bounded parser and evaluator fuzzing',
      'native Sass successful transaction handles every allocation failure',
    ]),
  }),
  gates: Object.freeze({
    corpusDifferential: 'verified',
    negativeAndResource: 'verified',
    deterministicConcurrency: 'verified',
    fuzz: 'verified',
    allocationFailure: 'verified',
  }),
})

const expectedLessConformance = Object.freeze({
  ownerPackage: 'NLESS-012',
  releaseGapFamily: 'native-less-conformance',
  state: 'closed',
  packageState: 'verified',
  oracle: Object.freeze({
    id: 'less',
    package: 'less',
    version: '4.6.7',
    selection: 'tests/preprocessors/less/corpus/selection.json',
    caseCount: 88,
  }),
  completedCaseCount: 88,
  remainingCaseCount: 0,
  terminalContract: Object.freeze({
    selectionDerived: true,
    successCaseCount: 68,
    errorCaseCount: 20,
    deterministicRunsPerSuccessCase: 2,
    fuzzMutationsPerCase: 3,
    maxConcurrentCompilations: 4,
    evidenceTests: Object.freeze([
      'native Less closes the finite pinned success corpus deterministically',
      'native Less rejects the finite pinned error corpus deterministically',
      'native Less parser owns finite resource and cancellation boundaries',
      'native Less compilation is deterministic under bounded concurrency',
      'native Less finite corpus seeds bounded parser and evaluator fuzzing',
      'native Less successful transaction handles every allocation failure',
    ]),
  }),
  gates: Object.freeze({
    corpusDifferential: 'verified',
    negativeAndResource: 'verified',
    deterministicConcurrency: 'verified',
    fuzz: 'verified',
    allocationFailure: 'verified',
  }),
})

const expectedStylusConformance = Object.freeze({
  ownerPackage: 'NSTYLUS-012',
  releaseGapFamily: 'native-stylus-conformance',
  convergenceState: 'closed',
  state: 'in-progress',
  packageState: 'in-progress',
  oracle: Object.freeze({
    id: 'stylus',
    package: 'stylus',
    version: '0.64.0',
    selection: 'tests/preprocessors/stylus/corpus/selection.json',
    manifest: 'tests/preprocessors/stylus/corpus/manifest.json',
    caseCount: 346,
  }),
  completedCaseCount: 205,
  remainingCaseCount: 141,
  terminalContract: Object.freeze({
    selectionDerived: true,
    successCaseCount: 326,
    errorCaseCount: 20,
    exactSuccessCount: 185,
    nonconformingSuccessCount: 141,
    exactSuccessCaseIdWyhash: '653eebfbaba42d25',
    deterministicRunsPerSuccessCase: 2,
    fuzzMutationsPerCase: 3,
    maxConcurrentCompilations: 4,
    evidenceTests: Object.freeze([
      'native Stylus measures the finite pinned success corpus without ordinal expansion',
      'native Stylus closes the finite arithmetic conformance family',
      'native Stylus closes the finite coercion conformance family',
      'native Stylus closes the finite atblock conformance family',
      'native Stylus closes the finite add-property conformance family',
      'native Stylus closes the finite cache conformance family',
      'native Stylus closes the finite contrast conformance family',
      'native Stylus closes the finite convert conformance family',
      'native Stylus closes the finite current-property conformance family',
      'native Stylus closes the finite define conformance family',
      'native Stylus closes the finite image-size conformance family',
      'native Stylus rejects the finite pinned error corpus deterministically',
      'native Stylus parser owns finite resource and cancellation boundaries',
      'native Stylus compilation is deterministic under bounded concurrency',
      'native Stylus finite corpus seeds bounded parser and evaluator fuzzing',
      'native Stylus successful transaction handles every allocation failure',
    ]),
  }),
  gates: Object.freeze({
    corpusDifferential: 'in-progress',
    negativeAndResource: 'verified',
    deterministicConcurrency: 'verified',
    fuzz: 'verified',
    allocationFailure: 'verified',
  }),
})

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
      'local-use-pinned-resolution-foundation',
      'local-use-transitive-graph-foundation',
      'local-forward-config-foundation',
      'local-forward-callable-foundation',
      'local-forward-terminal-contract-foundation',
      'local-legacy-import-only-precedence-foundation',
      'local-meta-load-css-terminal-foundation',
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
      'local-use-caller-callable-argument-ownership-foundation',
      'local-use-peer-callable-argument-ownership-foundation',
      'local-use-cross-engine-mixin-content-rejection',
      'local-use-meta-apply-mixin-content-rejection',
      'local-use-callable-result-ownership-foundation',
      'local-use-configuration-foundation',
      'local-use-built-in-callable-configuration-ownership-foundation',
      'local-use-cross-module-callable-configuration-ownership-foundation',
      'local-use-configured-callable-reexport-ownership-foundation',
      'local-use-reexported-callable-configuration-ownership-foundation',
      'local-use-recursive-reexported-callable-configuration-ownership-foundation',
      'local-use-finite-callable-reexport-depth-contract',
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
  Object.freeze({
    id: 'native-sass-conformance',
    current: 'native-internal',
    ownerPackage: 'NSASS-012',
    adapters: Object.freeze(['scss', 'sass']),
    capabilities: Object.freeze([
      'pinned-corpus-differential',
      'strict-negative-resource',
      'deterministic-concurrency',
      'bounded-fuzz',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze([]),
    testSources: Object.freeze(['tests/native-preprocessor/sass_conformance.zig']),
    testStep: 'test-native-sass-conformance',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-less-parser',
    current: 'native-internal',
    ownerPackage: 'NLESS-010',
    adapters: Object.freeze(['less']),
    capabilities: Object.freeze([
      'parsing',
      'pinned-success-syntax',
      'pinned-parse-negatives',
      'resource-cancellation',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze(['src/preprocessor/less.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/less_parser.zig']),
    testStep: 'test-native-less-parser',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-less-semantic-core',
    current: 'native-internal',
    ownerPackage: 'NLESS-011',
    adapters: Object.freeze(['less']),
    capabilities: Object.freeze([
      'plain-css-transaction',
      'permanent-javascript-plugin-rejection',
      'lazy-variable-scope-selector-declaration-foundation',
      'ruleset-operation-builtin-foundation',
      'confined-import-options-diagnostics-dependencies-maps',
      'resource-cancellation',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze(['src/preprocessor/less_evaluator.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/less_evaluator.zig']),
    testStep: 'test-native-less-evaluator',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-less-conformance',
    current: 'native-internal',
    ownerPackage: 'NLESS-012',
    adapters: Object.freeze(['less']),
    capabilities: Object.freeze([
      'pinned-corpus-differential',
      'strict-negative-resource',
      'deterministic-concurrency',
      'bounded-fuzz',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze([]),
    testSources: Object.freeze(['tests/native-preprocessor/less_conformance.zig']),
    testStep: 'test-native-less-conformance',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-stylus-parser',
    current: 'native-internal',
    ownerPackage: 'NSTYLUS-010',
    adapters: Object.freeze(['stylus']),
    capabilities: Object.freeze([
      'parsing',
      'indentation-optional-punctuation',
      'pinned-success-syntax',
      'pinned-parser-negatives',
      'resource-cancellation',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze(['src/preprocessor/stylus.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/stylus_parser.zig']),
    testStep: 'test-native-stylus-parser',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-stylus-semantic-core',
    current: 'native-internal',
    ownerPackage: 'NSTYLUS-011',
    adapters: Object.freeze(['stylus']),
    capabilities: Object.freeze([
      'plain-css-transaction',
      'permanent-use-plugin-hook-rejection',
      'variables-properties-selectors-expressions',
      'mixins-functions-control-operators-builtins',
      'confined-imports-require-globs-diagnostics-dependencies-maps',
      'resource-cancellation',
      'allocation-failure',
    ]),
    nativeSources: Object.freeze(['src/preprocessor/stylus_evaluator.zig']),
    testSources: Object.freeze(['tests/native-preprocessor/stylus_evaluator.zig']),
    testStep: 'test-native-stylus-evaluator',
    publicAvailable: false,
    productionReachable: false,
  }),
  Object.freeze({
    id: 'native-stylus-conformance',
    current: 'native-internal',
    ownerPackage: 'NSTYLUS-012',
    adapters: Object.freeze(['stylus']),
    capabilities: Object.freeze(['pinned-corpus-differential']),
    nativeSources: Object.freeze([]),
    testSources: Object.freeze(['tests/native-preprocessor/stylus_conformance.zig']),
    testStep: 'test-native-stylus-conformance',
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

function validateSassEvaluatorClosure(
  closure,
  contract,
  plan,
  sassSelection,
  sassEvaluatorSource,
  sassEvaluatorTests,
) {
  if (!same(closure, expectedSassEvaluatorClosure)) {
    fail('native Sass evaluator closure drifted')
  }
  if (closure.releaseGapFamily === closure.remainingPlanDomain.releaseGapFamily) {
    fail('native Sass evaluator closure drifted into a renamed family')
  }
  const oracle = contract.referenceOracles.find(candidate => candidate.id === closure.oracle.id)
  if (oracle === undefined || oracle.package !== closure.oracle.package ||
      oracle.version !== closure.oracle.version) {
    fail('native Sass evaluator oracle drifted')
  }
  if (sassSelection.upstream?.dartSassVersion !== closure.oracle.version ||
      !Array.isArray(sassSelection.cases) ||
      sassSelection.cases.length !== closure.oracle.caseCount) {
    fail('native Sass evaluator oracle drifted')
  }
  const selectedCases = new Set(sassSelection.cases.map(specCase => specCase.id))
  for (const referenceCase of closure.remainingPlanDomain.referenceCases) {
    if (!selectedCases.has(referenceCase)) {
      fail(`native Sass evaluator oracle is missing ${referenceCase}`)
    }
  }
  for (const completedSlice of closure.remainingPlanDomain.completedSlices) {
    if (closure.remainingPlanDomain.features.includes(completedSlice.feature)) {
      fail('native Sass module-system progress retained a completed feature')
    }
    for (const referenceCase of completedSlice.referenceCases) {
      if (!selectedCases.has(referenceCase)) {
        fail(`native Sass evaluator oracle is missing ${referenceCase}`)
      }
    }
    for (const evidenceTest of completedSlice.evidenceTests) {
      requireText(
        sassEvaluatorTests,
        `test "${evidenceTest}"`,
        'native Sass module-system evidence',
      )
    }
  }
  requireText(
    plan,
    '`NSASS-011` | Implement Sass evaluation, mixins/functions, control flow, lists/maps, calculations/colors, `@use`/`@forward`/legacy imports, built-in modules, diagnostics, dependencies, and maps',
    'DEVELOPMENT_PLAN.md native Sass evaluator package',
  )
  requireText(
    sassEvaluatorSource,
    'pub const max_callable_argument_transport_edges: u8 = 1;',
    'native Sass evaluator terminal boundary',
  )
  requireText(
    sassEvaluatorSource,
    closure.terminalContract.reflectedContentDiagnostic,
    'native Sass reflected content diagnostic',
  )
  for (const evidenceTest of closure.evidenceTests) {
    requireText(
      sassEvaluatorTests,
      `test "${evidenceTest}"`,
      'native Sass evaluator evidence',
    )
  }
}

function validateSassConformance(
  conformance,
  contract,
  plan,
  sassSelection,
  sassManifest,
  sassConformanceTests,
) {
  if (!same(conformance, expectedSassConformance)) {
    fail('native Sass conformance contract drifted')
  }
  const oracle = contract.referenceOracles.find(candidate => candidate.id === conformance.oracle.id)
  if (oracle === undefined || oracle.package !== conformance.oracle.package ||
      oracle.version !== conformance.oracle.version) {
    fail('native Sass conformance oracle drifted')
  }
  if (!Array.isArray(sassSelection.cases) ||
      !Array.isArray(sassManifest.cases) ||
      sassSelection.cases.length !== conformance.oracle.caseCount ||
      sassManifest.caseCount !== conformance.oracle.caseCount ||
      sassManifest.cases.length !== conformance.oracle.caseCount) {
    fail('native Sass conformance terminal corpus drifted')
  }
  const selectedIds = sassSelection.cases.map(specCase => specCase.id)
  const manifestIds = sassManifest.cases.map(specCase => specCase.id)
  if (!same(selectedIds, manifestIds)) fail('native Sass conformance terminal corpus drifted')
  const successCaseCount = sassSelection.cases.filter(specCase => specCase.outcome === 'success').length
  const errorCaseCount = sassSelection.cases.filter(specCase => specCase.outcome === 'error').length
  if (!conformance.terminalContract.selectionDerived ||
      successCaseCount !== conformance.terminalContract.successCaseCount ||
      errorCaseCount !== conformance.terminalContract.errorCaseCount ||
      successCaseCount + errorCaseCount !== conformance.oracle.caseCount) {
    fail('native Sass conformance terminal accounting drifted')
  }
  for (const evidenceTest of conformance.terminalContract.evidenceTests) {
    requireText(
      sassConformanceTests,
      `test "${evidenceTest}"`,
      'native Sass conformance evidence',
    )
  }
  if (conformance.completedCaseCount !== conformance.oracle.caseCount ||
      conformance.completedCaseCount + conformance.remainingCaseCount !== conformance.oracle.caseCount) {
    fail('native Sass conformance case accounting drifted')
  }
  requireText(
    plan,
    '`NSASS-012` | Pass the pinned Sass reference corpus, strict negative/resource fixtures, exact differential output, deterministic concurrency, fuzzing, and allocation-failure gates',
    'DEVELOPMENT_PLAN.md native Sass conformance package',
  )
}

function validateLessConformance(
  conformance,
  contract,
  plan,
  selection,
  conformanceTests,
) {
  if (!same(conformance, expectedLessConformance)) {
    fail('native Less conformance contract drifted')
  }
  const oracle = contract.referenceOracles.find(candidate => candidate.id === conformance.oracle.id)
  if (oracle === undefined || oracle.package !== conformance.oracle.package ||
      oracle.version !== conformance.oracle.version) {
    fail('native Less conformance oracle drifted')
  }
  if (!Array.isArray(selection.cases) || selection.cases.length !== conformance.oracle.caseCount) {
    fail('native Less conformance terminal corpus drifted')
  }
  const successCaseCount = selection.cases.filter(specCase => specCase.outcome === 'success').length
  const errorCaseCount = selection.cases.filter(specCase => specCase.outcome === 'error').length
  if (!conformance.terminalContract.selectionDerived ||
      successCaseCount !== conformance.terminalContract.successCaseCount ||
      errorCaseCount !== conformance.terminalContract.errorCaseCount ||
      successCaseCount + errorCaseCount !== conformance.oracle.caseCount) {
    fail('native Less conformance terminal accounting drifted')
  }
  for (const evidenceTest of conformance.terminalContract.evidenceTests) {
    requireText(
      conformanceTests,
      `test "${evidenceTest}"`,
      'native Less conformance evidence',
    )
  }
  if (conformance.completedCaseCount !== conformance.oracle.caseCount ||
      conformance.completedCaseCount + conformance.remainingCaseCount !== conformance.oracle.caseCount) {
    fail('native Less conformance case accounting drifted')
  }
  requireText(
    plan,
    '`NLESS-012` | Pass the pinned Less 4.6.7 corpus, strict negative/resource fixtures, exact differential output, deterministic concurrency, fuzzing, and allocation-failure gates',
    'DEVELOPMENT_PLAN.md native Less conformance package',
  )
}

function validateLessParser(selection, tests, plan) {
  if (selection.upstream?.packageVersion !== '4.6.7' || !Array.isArray(selection.cases) ||
      selection.cases.length !== 88) {
    fail('native Less parser selection drifted')
  }
  const successCases = selection.cases.filter(specCase => specCase.outcome === 'success')
  const parseErrors = selection.cases.filter(specCase =>
    specCase.outcome === 'error' && specCase.suite === 'tests-error/parse')
  if (successCases.length !== 68 || parseErrors.length !== 10) {
    fail('native Less parser selection drifted')
  }
  for (const evidenceTest of [
    'native parser accepts every pinned Less success entry',
    'native parser rejects every pinned Less parse error',
    'invalid UTF-8 and parser resource ceilings fail closed',
    'Less tokenization and parsing cancellation expose no partial document',
    'native Less parser handles every allocation failure',
  ]) {
    requireText(tests, `test "${evidenceTest}"`, 'native Less parser evidence')
  }
  requireText(
    plan,
    '`NLESS-010` | Implement native Less parsing for variables, nesting, mixins, guards, detached rulesets, extends, interpolation, operations, and CSS-preserving syntax behind an unavailable experimental gate',
    'DEVELOPMENT_PLAN.md native Less parser package',
  )
}

function validateStylusParser(manifest, selection, source, tests, plan) {
  if (manifest.upstream?.packageVersion !== '0.64.0' ||
      manifest.officialCandidateCount !== 355 ||
      manifest.officialSuccessCount !== 326 ||
      manifest.integrationErrorCount !== 20 ||
      manifest.caseCount !== 346 ||
      !Array.isArray(manifest.cases) ||
      manifest.cases.length !== 346) {
    fail('native Stylus parser corpus drifted')
  }
  if (selection.upstream?.packageVersion !== '0.64.0' ||
      !Array.isArray(selection.negativeCases) ||
      selection.negativeCases.length !== 20) {
    fail('native Stylus parser selection drifted')
  }
  const parserNegativeIds = [
    'unclosed-expression',
    'unexpected-brace',
    'unclosed-media',
    'unclosed-function',
    'dangling-selector',
    'empty-import',
    'root-break',
    'bad-charset',
    'unclosed-object',
    'unterminated-string',
    'bad-ternary',
    'bad-atblock',
    'bad-property',
  ]
  const selectedNegatives = new Set(selection.negativeCases.map(specCase => specCase.id))
  for (const id of parserNegativeIds) {
    if (!selectedNegatives.has(id)) fail(`native Stylus parser selection is missing ${id}`)
    requireText(tests, `"${id}"`, 'native Stylus parser negative evidence')
  }
  for (const evidenceTest of [
    'native Stylus parser preserves indentation optional punctuation and syntax kinds',
    'native parser accepts every pinned Stylus success entry',
    'native parser rejects every pinned Stylus parser error',
    'invalid UTF-8 and Stylus parser resource ceilings fail closed',
    'Stylus tokenization and parsing cancellation expose no partial document',
    'native Stylus parser handles every allocation failure',
  ]) {
    requireText(tests, `test "${evidenceTest}"`, 'native Stylus parser evidence')
  }
  requireText(
    source,
    'execute project plugins or',
    'native Stylus permanent execution boundary',
  )
  requireText(
    plan,
    '`NSTYLUS-010` | Implement native Stylus lexical indentation and optional punctuation, variables, properties, selectors, expressions, and CSS-preserving syntax behind an unavailable experimental gate',
    'DEVELOPMENT_PLAN.md native Stylus parser package',
  )
}

function validateStylusEvaluator(selection, source, tests, plan) {
  const useExclusion = selection.exclusions?.find(entry => entry.name === 'bifs.use')
  if (useExclusion?.category !== 'executable-extension') {
    fail('native Stylus evaluator use() exclusion drifted')
  }
  for (const evidenceTest of [
    'native Stylus transaction preserves the finite plain CSS foundation',
    'native Stylus permanently rejects use plugins without partial CSS',
    'native Stylus imports require a confined source identity',
    'native Stylus closes confined import require glob dependency and map semantics',
    'native Stylus import failures own source diagnostics without partial CSS',
    'native Stylus imports own terminal depth count byte and cancellation boundaries',
    'native Stylus evaluates the fixed variable property selector expression slice',
    'native Stylus semantic failures own diagnostics without partial CSS',
    'native Stylus evaluates the fixed callable control operator builtin slice',
    'native Stylus callable control slice fails closed with exact diagnostics',
    'native Stylus semantic values and bindings retain finite ceilings',
    'native Stylus plain CSS foundation owns resource and cancellation boundaries',
    'native Stylus transaction handles every allocation failure',
    'native Stylus import transaction handles every allocation failure',
  ]) {
    requireText(tests, `test "${evidenceTest}"`, 'native Stylus evaluator evidence')
  }
  for (const permanentBoundary of [
    'native Stylus use() plugins are permanently disabled',
    'external custom evaluator hooks are permanently',
  ]) {
    requireText(source, permanentBoundary, 'native Stylus permanent execution boundary')
  }
  requireText(
    tests,
    'tests/preprocessors/stylus/corpus/files/upstream/cases/bifs.use.styl',
    'native Stylus evaluator pinned plugin boundary',
  )
  requireText(
    plan,
    '`NSTYLUS-011` | Implement Stylus mixins/functions, control flow, operators, imports/globs, built-ins, diagnostics, dependencies, and maps while permanently rejecting project plugins and evaluator hooks',
    'DEVELOPMENT_PLAN.md native Stylus evaluator package',
  )
}

function validateStylusConformance(
  conformance,
  contract,
  plan,
  selection,
  manifest,
  conformanceTests,
) {
  if (!same(conformance, expectedStylusConformance)) {
    fail('native Stylus conformance contract drifted')
  }
  const oracle = contract.referenceOracles.find(candidate => candidate.id === conformance.oracle.id)
  if (oracle === undefined || oracle.package !== conformance.oracle.package ||
      oracle.version !== conformance.oracle.version) {
    fail('native Stylus conformance oracle drifted')
  }
  if (selection.upstream?.packageVersion !== conformance.oracle.version ||
      manifest.upstream?.packageVersion !== conformance.oracle.version ||
      !Array.isArray(manifest.cases) ||
      manifest.caseCount !== conformance.oracle.caseCount ||
      manifest.cases.length !== conformance.oracle.caseCount) {
    fail('native Stylus conformance terminal corpus drifted')
  }
  const successCaseCount = manifest.cases.filter(specCase => specCase.outcome === 'success').length
  const errorCaseCount = manifest.cases.filter(specCase => specCase.outcome === 'error').length
  if (!conformance.terminalContract.selectionDerived ||
      successCaseCount !== conformance.terminalContract.successCaseCount ||
      errorCaseCount !== conformance.terminalContract.errorCaseCount ||
      successCaseCount + errorCaseCount !== conformance.oracle.caseCount) {
    fail('native Stylus conformance terminal accounting drifted')
  }
  if (conformance.convergenceState !== 'closed' ||
      !Number.isInteger(conformance.terminalContract.exactSuccessCount) ||
      !Number.isInteger(conformance.terminalContract.nonconformingSuccessCount) ||
      conformance.terminalContract.exactSuccessCount +
        conformance.terminalContract.nonconformingSuccessCount !== successCaseCount ||
      conformance.completedCaseCount !==
        conformance.terminalContract.exactSuccessCount + errorCaseCount ||
      conformance.remainingCaseCount !==
        conformance.terminalContract.nonconformingSuccessCount ||
      conformance.completedCaseCount + conformance.remainingCaseCount !==
        conformance.oracle.caseCount ||
      !/^[0-9a-f]{16}$/.test(conformance.terminalContract.exactSuccessCaseIdWyhash)) {
    fail('native Stylus conformance convergence contract drifted')
  }
  requireText(
    conformanceTests,
    `expectEqual(@as(usize, ${conformance.terminalContract.exactSuccessCount}), exact_success_count)`,
    'native Stylus conformance exact success accounting',
  )
  requireText(
    conformanceTests,
    `expectEqual(@as(usize, ${conformance.terminalContract.nonconformingSuccessCount}), nonconforming_count)`,
    'native Stylus conformance nonconforming success accounting',
  )
  requireText(
    conformanceTests,
    `@as(u64, 0x${conformance.terminalContract.exactSuccessCaseIdWyhash})`,
    'native Stylus conformance exact identity hash',
  )
  for (const evidenceTest of conformance.terminalContract.evidenceTests) {
    requireText(
      conformanceTests,
      `test "${evidenceTest}"`,
      'native Stylus conformance terminal evidence',
    )
  }
  requireText(
    plan,
    '`NSTYLUS-012` | Pass the pinned Stylus 0.64.0 corpus, strict negative/resource fixtures, exact differential output, deterministic concurrency, fuzzing, and allocation-failure gates',
    'DEVELOPMENT_PLAN.md native Stylus conformance package',
  )
}

function validateLessEvaluator(source, tests, plan) {
  for (const evidenceTest of [
    'native Less transaction preserves the finite plain CSS foundation',
    'native Less lazily resolves the pinned variable foundation',
    'native Less evaluates the pinned lexical scope and nested selector foundation',
    'native Less resolves pinned redefinition indirection and selector interpolation',
    'native Less variable failures own exact diagnostics without partial CSS',
    'native Less evaluates the admitted operation boundary',
    'native Less evaluates the fixed ruleset operation and builtin matrix',
    'native Less ruleset matrix failures own exact diagnostics without partial CSS',
    'native Less closes the confined import option dependency and map foundation',
    'native Less binds the pinned render options to exact arithmetic',
    'native Less import failures own source-aware diagnostics without partial CSS',
    'native Less imports own terminal depth and cancellation boundaries',
    'native Less permanently rejects JavaScript and plugins without partial CSS',
    'native Less plain CSS foundation owns resource and cancellation boundaries',
    'native Less ruleset transaction handles every allocation failure',
    'native Less import transaction handles every allocation failure',
  ]) {
    requireText(tests, `test "${evidenceTest}"`, 'native Less evaluator evidence')
  }
  for (const referenceCase of [
    'less-lazy-eval-lazy-eval',
    'less-scope-scope',
    'less-variables-variables',
    'less-mixins-guards-mixins-guards',
    'less-detached-rulesets-detached-rulesets',
    'less-extend-extend',
    'less-operations-operations',
    'less-color-functions-basic',
    'less-error-eval-add-mixed-units',
    'less-error-eval-recursive-variable',
    'less-error-eval-at-rules-undefined-var',
    'less-import-import-once',
    'less-import-import-interpolation',
    'less-import-import-reference-issues',
    'less-charsets-charsets',
    'less-layer-layer',
  ]) {
    requireText(tests, referenceCase, 'native Less evaluator pinned reference evidence')
  }
  for (const permanentBoundary of [
    'native Less JavaScript evaluation is permanently disabled',
    'native Less plugins are permanently disabled',
  ]) {
    requireText(source, permanentBoundary, 'native Less permanent execution boundary')
  }
  requireText(
    plan,
    '`NLESS-011` | Implement Less lazy evaluation, imports/options, functions/colors/units, URL behavior, diagnostics, dependencies, and maps while permanently rejecting JavaScript and plugins',
    'DEVELOPMENT_PLAN.md native Less evaluator package',
  )
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
    sassSelection = loadJson('tests/preprocessors/sass/corpus/selection.json'),
    sassManifest = loadJson('tests/preprocessors/sass/corpus/manifest.json'),
    sassEvaluatorSource = fs.readFileSync(
      repositoryFile('src/preprocessor/sass_evaluator.zig'),
      'utf8',
    ),
    sassEvaluatorTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/sass_evaluator.zig'),
      'utf8',
    ),
    sassConformanceTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/sass_conformance.zig'),
      'utf8',
    ),
    lessSelection = loadJson('tests/preprocessors/less/corpus/selection.json'),
    lessParserTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/less_parser.zig'),
      'utf8',
    ),
    lessEvaluatorSource = fs.readFileSync(
      repositoryFile('src/preprocessor/less_evaluator.zig'),
      'utf8',
    ),
    lessEvaluatorTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/less_evaluator.zig'),
      'utf8',
    ),
    lessConformanceTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/less_conformance.zig'),
      'utf8',
    ),
    stylusManifest = loadJson('tests/preprocessors/stylus/corpus/manifest.json'),
    stylusSelection = loadJson('tests/preprocessors/stylus/corpus/selection.json'),
    stylusParserSource = fs.readFileSync(
      repositoryFile('src/preprocessor/stylus.zig'),
      'utf8',
    ),
    stylusParserTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/stylus_parser.zig'),
      'utf8',
    ),
    stylusEvaluatorSource = fs.readFileSync(
      repositoryFile('src/preprocessor/stylus_evaluator.zig'),
      'utf8',
    ),
    stylusEvaluatorTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/stylus_evaluator.zig'),
      'utf8',
    ),
    stylusConformanceTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/stylus_conformance.zig'),
      'utf8',
    ),
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
      'sassEvaluatorClosure',
      'sassConformance',
      'lessConformance',
      'stylusConformance',
      'foundations',
      'implementations',
      'adapters',
    ],
    'root',
  )
  if (contract.schemaVersion !== 5) fail('schemaVersion must be 5')
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
  validateSassEvaluatorClosure(
    contract.sassEvaluatorClosure,
    contract,
    plan,
    sassSelection,
    sassEvaluatorSource,
    sassEvaluatorTests,
  )
  validateSassConformance(
    contract.sassConformance,
    contract,
    plan,
    sassSelection,
    sassManifest,
    sassConformanceTests,
  )
  validateLessParser(lessSelection, lessParserTests, plan)
  validateLessEvaluator(lessEvaluatorSource, lessEvaluatorTests, plan)
  validateLessConformance(
    contract.lessConformance,
    contract,
    plan,
    lessSelection,
    lessConformanceTests,
  )
  validateStylusParser(
    stylusManifest,
    stylusSelection,
    stylusParserSource,
    stylusParserTests,
    plan,
  )
  validateStylusEvaluator(
    stylusSelection,
    stylusEvaluatorSource,
    stylusEvaluatorTests,
    plan,
  )
  validateStylusConformance(
    contract.stylusConformance,
    contract,
    plan,
    stylusSelection,
    stylusManifest,
    stylusConformanceTests,
  )
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

  requireText(plan, 'Plan version: 1.5', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## Milestone 10: Self-contained native stylesheet frontends', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## 17. First self-contained-native autonomous sequence', 'DEVELOPMENT_PLAN.md')
  requireText(decision, '- Status: Accepted', 'ADR-013')
  requireText(decision, 'zero `dependencies` and zero `optionalDependencies`', 'ADR-013')
  requireText(decision, 'All tag-triggered releases are fail-closed', 'ADR-013')
  requireText(decision, 'first fully graduated native candidate', 'ADR-013')
  requireText(readme, 'Native dependency-free migration', 'README.md')

  const buildGate = 'npm run test:native-contract && npm run check:native-contract'
  requireText(buildWorkflow, buildGate, 'build workflow')
  requireText(buildWorkflow, 'zig build test --summary all', 'build workflow')
  if (buildWorkflow.includes('zig build test-native-preprocessor --summary all')) {
    fail('build workflow must not duplicate native frontend coverage before the complete root test graph')
  }
  validateBuildTestGraph(buildFile)
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
