import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  contractPath,
  loadContract,
  loadProductionSources,
  validateContract,
  validateReleaseTag,
} from './validate-native-contract.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

function clone(value) {
  return structuredClone(value)
}

test('accepts the bounded native stylesheet implementation contract', () => {
  const contract = validateContract(loadContract())
  assert.equal(contract.schemaVersion, 5)
  assert.equal(contract.state, 'native-foundation')
  assert.equal(contract.nativeReleaseReady, false)
  assert.deepEqual(contract.nativePublicationAuthority, {
    authorized: true,
    authorizedOn: '2026-07-27',
    scope: 'first-fully-graduated-native-release',
    workflow: '.github/workflows/release.yml',
    channels: ['github-prerelease', 'npm-next'],
  })
  assert.equal(contract.productionBoundary.packageDependencies, 0)
  assert.deepEqual(contract.foundations.map(foundation => foundation.id), [
    'shared-lossless-lexer',
    'shared-semantic-primitives',
    'confined-local-resolver',
    'transactional-core-validator',
  ])
  assert.deepEqual(contract.adapters.map(adapter => adapter.id), [
    'css',
    'scss',
    'sass',
    'less',
    'stylus',
  ])
  assert.deepEqual(contract.implementations.map(implementation => implementation.id), [
    'native-sass-parser',
    'native-sass-semantic-core',
    'native-sass-conformance',
    'native-less-parser',
    'native-less-semantic-core',
    'native-less-conformance',
    'native-stylus-parser',
    'native-stylus-semantic-core',
    'native-stylus-conformance',
  ])
  assert.deepEqual(contract.sassConformance, {
    ownerPackage: 'NSASS-012',
    releaseGapFamily: 'native-sass-conformance',
    state: 'closed',
    packageState: 'verified',
    oracle: {
      id: 'dart-sass',
      package: 'sass',
      version: '1.101.0',
      selection: 'tests/preprocessors/sass/corpus/selection.json',
      manifest: 'tests/preprocessors/sass/corpus/manifest.json',
      caseCount: 80,
    },
    completedCaseCount: 80,
    remainingCaseCount: 0,
    terminalContract: {
      selectionDerived: true,
      successCaseCount: 60,
      errorCaseCount: 20,
      deterministicRunsPerSuccessCase: 2,
      fuzzMutationsPerCase: 3,
      maxConcurrentCompilations: 4,
      evidenceTests: [
        'native Sass closes the finite pinned success corpus deterministically',
        'native Sass rejects the finite pinned error corpus deterministically',
        'native Sass parser owns finite resource and cancellation boundaries',
        'native Sass compilation is deterministic under bounded concurrency',
        'native Sass finite corpus seeds bounded parser and evaluator fuzzing',
        'native Sass successful transaction handles every allocation failure',
      ],
    },
    gates: {
      corpusDifferential: 'verified',
      negativeAndResource: 'verified',
      deterministicConcurrency: 'verified',
      fuzz: 'verified',
      allocationFailure: 'verified',
    },
  })
  assert.deepEqual(contract.sassEvaluatorClosure, {
    ownerPackage: 'NSASS-011',
    releaseGapFamily: 'native-sass-evaluation',
    state: 'closed',
    packageState: 'verified',
    oracle: {
      id: 'dart-sass',
      package: 'sass',
      version: '1.101.0',
      selection: 'tests/preprocessors/sass/corpus/selection.json',
      caseCount: 80,
    },
    terminalContract: {
      syntaxes: ['scss', 'sass'],
      callableKinds: ['function', 'mixin'],
      argumentOwnerClasses: ['caller', 'earlier-peer', 'later-peer'],
      reflectedContentOwnerClasses: [
        'receiver',
        'configured',
        'reexported',
        'caller',
        'peer',
      ],
      maxArgumentTransportEdges: 1,
      reflectedContentOutcome: 'reject-with-exact-syntax-diagnostic',
      reflectedContentDiagnostic: "Mixin doesn't accept a content block.",
    },
    evidenceTests: [
      'native Sass owns caller callables across one-hop local module calls',
      'native Sass caller callable arguments handle every allocation failure',
      'native Sass owns peer callables across one-hop local module calls',
      'native Sass peer callable arguments handle every allocation failure',
      'native Sass re-exported peer callable arguments fail without partial CSS',
      'native Sass rejects caller and peer callable content transport through meta.apply',
      'native Sass rejects same-engine mixin content through meta.apply',
      'native Sass meta.apply mixin content rejection handles every allocation failure',
    ],
    remainingPlanDomain: {
      releaseGapFamily: 'native-sass-dynamic-loading',
      features: [],
      referenceCases: [],
      completedSlices: [{
        feature: 'use-resolution',
        state: 'native-foundation',
        referenceCases: [
          'scss-use-sass-extension',
          'scss-use-scss-extension',
          'scss-use-import-only-exclusion',
          'scss-use-partial-index',
        ],
        evidenceTests: [
          'native Sass resolves the pinned one-hop use selection matrix',
          'native Sass local use handles every allocation failure',
        ],
      }, {
        feature: 'transitive-use',
        state: 'native-foundation',
        referenceCases: [],
        evidenceTests: [
          'native Sass evaluates the pinned transitive use graph once',
          'native Sass transitive use preserves parent callable ownership',
          'native Sass transitive local use enforces graph limits without partial CSS',
          'native Sass transitive use graph handles every allocation failure',
        ],
      }, {
        feature: 'forward-config',
        state: 'native-foundation',
        referenceCases: ['scss-forward-config'],
        evidenceTests: [
          'native Sass forwards the pinned configured module once',
          'native Sass exposes forwarded public variables without duplicate evaluation',
          'native Sass forward configuration failures own exact diagnostics',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ],
      }, {
        feature: 'forward-callables',
        state: 'native-foundation',
        referenceCases: [],
        evidenceTests: [
          'native Sass exposes forwarded public callables without duplicate evaluation',
          'native Sass local callables override forwarded members',
          'native Sass forward configuration failures own exact diagnostics',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ],
      }, {
        feature: 'forward-terminal-contract',
        state: 'native-foundation',
        referenceCases: [],
        evidenceTests: [
          'native Sass forward prefix and filters cover the finite public member contract',
          'native Sass forward covers the finite built-in module inventory',
          'native Sass forward resolution enforces confinement and graph limits',
          'native Sass configured forward handles every allocation failure',
        ],
      }, {
        feature: 'legacy-import',
        state: 'native-foundation',
        referenceCases: ['scss-import-import-only'],
        evidenceTests: [
          'native Sass resolves the pinned legacy import-only precedence',
          'native Sass legacy import rejects malformed directives without partial CSS',
          'native Sass legacy import handles every allocation failure',
        ],
      }, {
        feature: 'meta-load-css',
        state: 'native-foundation',
        referenceCases: ['scss-meta-load-css'],
        evidenceTests: [
          'native Sass executes the pinned meta load css terminal contract',
          'native Sass meta load css rejects unavailable modules without partial CSS',
          'native Sass meta load css handles every allocation failure',
        ],
      }],
    },
    conformancePackage: 'NSASS-012',
  })
  assert.deepEqual(contract.lessConformance, {
    ownerPackage: 'NLESS-012',
    releaseGapFamily: 'native-less-conformance',
    state: 'closed',
    packageState: 'verified',
    oracle: {
      id: 'less',
      package: 'less',
      version: '4.6.7',
      selection: 'tests/preprocessors/less/corpus/selection.json',
      caseCount: 88,
    },
    completedCaseCount: 88,
    remainingCaseCount: 0,
    terminalContract: {
      selectionDerived: true,
      successCaseCount: 68,
      errorCaseCount: 20,
      deterministicRunsPerSuccessCase: 2,
      fuzzMutationsPerCase: 3,
      maxConcurrentCompilations: 4,
      evidenceTests: [
        'native Less closes the finite pinned success corpus deterministically',
        'native Less rejects the finite pinned error corpus deterministically',
        'native Less parser owns finite resource and cancellation boundaries',
        'native Less compilation is deterministic under bounded concurrency',
        'native Less finite corpus seeds bounded parser and evaluator fuzzing',
        'native Less successful transaction handles every allocation failure',
      ],
    },
    gates: {
      corpusDifferential: 'verified',
      negativeAndResource: 'verified',
      deterministicConcurrency: 'verified',
      fuzz: 'verified',
      allocationFailure: 'verified',
    },
  })
  assert.deepEqual(contract.stylusConformance, {
    ownerPackage: 'NSTYLUS-012',
    releaseGapFamily: 'native-stylus-conformance',
    convergenceState: 'closed',
    state: 'in-progress',
    packageState: 'in-progress',
    oracle: {
      id: 'stylus',
      package: 'stylus',
      version: '0.64.0',
      selection: 'tests/preprocessors/stylus/corpus/selection.json',
      manifest: 'tests/preprocessors/stylus/corpus/manifest.json',
      caseCount: 346,
    },
    completedCaseCount: 184,
    remainingCaseCount: 162,
    terminalContract: {
      selectionDerived: true,
      successCaseCount: 326,
      errorCaseCount: 20,
      exactSuccessCount: 164,
      nonconformingSuccessCount: 162,
      exactSuccessCaseIdWyhash: 'f0d3f1294f4f10df',
      deterministicRunsPerSuccessCase: 2,
      fuzzMutationsPerCase: 3,
      maxConcurrentCompilations: 4,
      evidenceTests: [
        'native Stylus measures the finite pinned success corpus without ordinal expansion',
        'native Stylus closes the finite arithmetic conformance family',
        'native Stylus rejects the finite pinned error corpus deterministically',
        'native Stylus parser owns finite resource and cancellation boundaries',
        'native Stylus compilation is deterministic under bounded concurrency',
        'native Stylus finite corpus seeds bounded parser and evaluator fuzzing',
        'native Stylus successful transaction handles every allocation failure',
      ],
    },
    gates: {
      corpusDifferential: 'in-progress',
      negativeAndResource: 'verified',
      deterministicConcurrency: 'verified',
      fuzz: 'verified',
      allocationFailure: 'verified',
    },
  })
  const sassCore = contract.implementations[1]
  assert.equal(sassCore.capabilities.includes('local-use-pinned-resolution-foundation'), true)
  assert.equal(sassCore.capabilities.includes('local-use-transitive-graph-foundation'), true)
  assert.equal(sassCore.capabilities.includes('local-forward-config-foundation'), true)
  assert.equal(sassCore.capabilities.includes('local-forward-callable-foundation'), true)
  assert.equal(sassCore.capabilities.includes('local-forward-terminal-contract-foundation'), true)
  assert.equal(
    sassCore.capabilities.includes('local-legacy-import-only-precedence-foundation'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('local-meta-load-css-terminal-foundation'),
    true,
  )
  assert.equal(sassCore.capabilities.includes('legacy-color-core'), true)
  assert.equal(sassCore.capabilities.includes('closed-named-colors'), true)
  assert.equal(sassCore.capabilities.includes('color-space-equality'), true)
  assert.equal(sassCore.capabilities.includes('color-channel-accessors'), true)
  assert.equal(sassCore.capabilities.includes('legacy-color-manipulation'), true)
  assert.equal(sassCore.capabilities.includes('keyword-color-transforms'), true)
  assert.equal(sassCore.capabilities.includes('hwb-color-transforms'), true)
  assert.equal(sassCore.capabilities.includes('keyword-argument-binding'), true)
  assert.equal(sassCore.capabilities.includes('fixed-builtin-keyword-binding'), true)
  assert.equal(sassCore.capabilities.includes('color-constructor-keyword-overloads'), true)
  assert.equal(sassCore.capabilities.includes('variadic-map-get-binding'), true)
  assert.equal(sassCore.capabilities.includes('modern-lab-color-constructors'), true)
  assert.equal(sassCore.capabilities.includes('predefined-wide-gamut-colors'), true)
  assert.equal(sassCore.capabilities.includes('cross-space-color-conversion'), true)
  assert.equal(sassCore.capabilities.includes('modern-color-transforms'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-transform-aliases'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-calculation-introspection'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-content-existence'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-existence-queries'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-inspection'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-keywords'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-mixin-references'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-sass-function-references'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-callable-inspection'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-user-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-list-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-map-query-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-map-mutation-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-inspection-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-keywords-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-content-existence-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-call-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-get-function-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-get-mixin-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-reflected-if-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-user-mixin-application'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-apply-mixin-application'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-module-functions-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-module-mixins-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-module-variables-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-content-acceptance-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-calculation-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-existence-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-unary-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-compatibility-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-unitless-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-unit-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-acos-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-asin-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-atan-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-atan2-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-sin-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-cos-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-tan-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-log-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-pow-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-sqrt-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-div-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-clamp-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-hypot-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-min-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-max-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-math-random-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-parse-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-simple-selectors-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-is-superselector-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-unify-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-append-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-nest-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-extend-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-selector-replace-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-quote-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-unquote-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-length-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-index-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-slice-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-insert-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-upper-case-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-lower-case-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-string-split-function-invocation'), true)
  assert.equal(
    sassCore.capabilities.includes('built-in-string-unique-id-deterministic-rejection'),
    true,
  )
  assert.equal(sassCore.capabilities.includes('built-in-string-split-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-quote-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-unquote-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-quote-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-unquote-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-upper-case-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-lower-case-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-length-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-index-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-slice-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-legacy-insert-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-length-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-index-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-slice-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-insert-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-upper-case-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-lower-case-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-adjust-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-change-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-scale-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-rgb-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-rgba-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-hsl-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-hsla-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-hwb-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-lab-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-lch-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-oklab-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-oklch-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-red-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-green-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-blue-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-alpha-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-opacity-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-hue-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-saturation-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-lightness-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-whiteness-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-whiteness-direct-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-blackness-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-blackness-direct-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-mix-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-mix-direct-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-mix-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-lighten-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-lighten-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-darken-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-darken-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-saturate-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-saturate-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-desaturate-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-desaturate-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-adjust-hue-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-adjust-hue-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-complement-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-complement-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-complement-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-grayscale-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-grayscale-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-grayscale-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-invert-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-module-invert-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-invert-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-opacify-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-opacify-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-fade-in-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-fade-in-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-transparentize-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-transparentize-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-fade-out-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-color-legacy-fade-out-direct-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-ie-hex-str-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-space-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-to-space-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-is-legacy-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-is-missing-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-is-in-gamut-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-to-gamut-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-channel-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-same-function-invocation'), true)
  assert.equal(
    sassCore.capabilities.includes('built-in-meta-color-is-powerless-function-invocation'),
    true,
  )
  assert.equal(sassCore.capabilities.includes('built-in-meta-calc-function-reference-rejection'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-content-acceptance'), true)
  assert.equal(sassCore.capabilities.includes('plain-css-function-argument-evaluation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-parse-simple'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-composition'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-relations'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-extend-replace-compound'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-extend-replace-compound-lists'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-extend-replace-normalized-compounds'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-attribute-normalization'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-escape-normalization'), true)
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-simple-pseudo-normalization'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-list-functional-pseudo-normalization'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-list-functional-pseudo-relations'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-list-functional-pseudo-extend-replace'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-nth-function-grammar'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-lang-functional-pseudo-grammar'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-selector-dir-functional-pseudo-grammar'),
    true,
  )
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-compound'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-complex-strict'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-complex-weave-disjoint'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-complex-weave-shared-lcs'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-complex-weave-shared-rigid'), true)
  assert.equal(sassCore.capabilities.includes('built-in-selector-unify-complex-weave-terminal-siblings'), true)
  assert.equal(sassCore.capabilities.includes('built-in-map-queries'), true)
  assert.equal(sassCore.capabilities.includes('shallow-map-mutations'), true)
  assert.equal(sassCore.capabilities.includes('nested-deep-map-mutations'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-module-aliases'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-queries'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-transformations'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-join'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-zip'), true)
  assert.equal(sassCore.capabilities.includes('built-in-list-slash'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-constants-deterministic-random'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-division'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-extrema-hypotenuse'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-powers-roots-logarithms'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-trigonometry'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-unit-predicates'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-unit-serialization'), true)
  assert.equal(sassCore.capabilities.includes('built-in-math-unary-numeric'), true)
  assert.equal(sassCore.capabilities.includes('unicode-string-core'), true)
  assert.equal(sassCore.capabilities.includes('legacy-string-builtins'), true)
  assert.equal(sassCore.capabilities.includes('built-in-string-module-aliases'), true)
  assert.equal(sassCore.capabilities.includes('lazy-conditional-emission'), true)
  assert.equal(sassCore.capabilities.includes('lazy-legacy-if-function'), true)
  assert.equal(sassCore.capabilities.includes('legacy-if-final-splat-expansion'), true)
  assert.equal(sassCore.capabilities.includes('legacy-if-single-misplaced-rest-expansion'), true)
  assert.equal(sassCore.capabilities.includes('legacy-if-dual-splat-expansion'), true)
  assert.equal(
    sassCore.capabilities.includes('diagnostic-deprecation-source-deduplication'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-color-legacy-alpha-missing-channel-semantics'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-color-legacy-alpha-compound-unit-semantics'),
    true,
  )
  assert.equal(
    sassCore.capabilities.includes('built-in-color-legacy-alpha-modern-color-rejection-semantics'),
    true,
  )
  assert.equal(sassCore.capabilities.includes('flow-control-variable-scope'), true)
  assert.equal(sassCore.capabilities.includes('bounded-control-flow-loops'), true)
  assert.equal(sassCore.capabilities.includes('bounded-user-functions'), true)
  assert.equal(sassCore.capabilities.includes('bounded-user-mixins-content'), true)
  assert.equal(sassCore.capabilities.includes('callable-rest-splat-content-parameters'), true)
  assert.equal(sassCore.nativeSources.includes('src/preprocessor/sass_color.zig'), true)
  assert.equal(sassCore.nativeSources.includes('src/preprocessor/sass_arguments.zig'), true)
  assert.equal(sassCore.nativeSources.includes('src/preprocessor/sass_string.zig'), true)
  assert.equal(sassCore.testSources.includes('tests/native-preprocessor/sass_color.zig'), true)
  assert.equal(sassCore.testSources.includes('tests/native-preprocessor/sass_arguments.zig'), true)
  assert.equal(sassCore.testSources.includes('tests/native-preprocessor/sass_string.zig'), true)
  assert.equal(fs.realpathSync(contractPath).startsWith(`${repositoryRoot}${path.sep}`), true)
})

test('rejects widened, unpinned, or unevidenced native Sass conformance progress', () => {
  for (const mutate of [
    contract => { contract.sassConformance.releaseGapFamily = 'renamed-conformance' },
    contract => { contract.sassConformance.completedCaseCount = 5 },
    contract => { contract.sassConformance.remainingCaseCount = 75 },
    contract => { contract.sassConformance.terminalContract.successCaseCount = 59 },
    contract => { contract.sassConformance.terminalContract.selectionDerived = false },
    contract => { contract.sassConformance.gates.corpusDifferential = 'complete' },
  ]) {
    const changed = clone(loadContract())
    mutate(changed)
    assert.throws(() => validateContract(changed), /native Sass conformance/)
  }

  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/sass_conformance.zig'), 'utf8')
    .replace(
      'test "native Sass closes the finite pinned success corpus deterministically"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { sassConformanceTests: missingEvidence }),
    /native Sass conformance evidence.*missing/,
  )
})

test('rejects widened, unpinned, or unevidenced native Less conformance progress', () => {
  for (const mutate of [
    contract => { contract.lessConformance.releaseGapFamily = 'renamed-conformance' },
    contract => { contract.lessConformance.completedCaseCount = 87 },
    contract => { contract.lessConformance.remainingCaseCount = 1 },
    contract => { contract.lessConformance.terminalContract.successCaseCount = 67 },
    contract => { contract.lessConformance.terminalContract.selectionDerived = false },
    contract => { contract.lessConformance.terminalContract.evidenceTests.pop() },
    contract => { contract.lessConformance.gates.corpusDifferential = 'in-progress' },
  ]) {
    const changed = clone(loadContract())
    mutate(changed)
    assert.throws(() => validateContract(changed), /native Less conformance/)
  }

  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_conformance.zig'), 'utf8')
    .replace(
      'test "native Less closes the finite pinned success corpus deterministically"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { lessConformanceTests: missingEvidence }),
    /native Less conformance evidence.*missing/,
  )
})

test('rejects widened, unpinned, or unevidenced native Stylus conformance progress', () => {
  for (const mutate of [
    contract => { contract.stylusConformance.releaseGapFamily = 'renamed-conformance' },
    contract => { contract.stylusConformance.convergenceState = 'reduced' },
    contract => { contract.stylusConformance.completedCaseCount = 179 },
    contract => { contract.stylusConformance.remainingCaseCount = 167 },
    contract => { contract.stylusConformance.terminalContract.successCaseCount = 325 },
    contract => { contract.stylusConformance.terminalContract.selectionDerived = false },
    contract => { contract.stylusConformance.terminalContract.exactSuccessCount = 157 },
    contract => { contract.stylusConformance.terminalContract.nonconformingSuccessCount = 167 },
    contract => { contract.stylusConformance.terminalContract.exactSuccessCaseIdWyhash = 'not-a-hash' },
    contract => { contract.stylusConformance.terminalContract.evidenceTests.pop() },
    contract => { contract.stylusConformance.gates.corpusDifferential = 'verified' },
  ]) {
    const changed = clone(loadContract())
    mutate(changed)
    assert.throws(() => validateContract(changed), /native Stylus conformance/)
  }

  const missingTerminalEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/stylus_conformance.zig'), 'utf8')
    .replace(
      'test "native Stylus measures the finite pinned success corpus without ordinal expansion"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), {
      stylusConformanceTests: missingTerminalEvidence,
    }),
    /native Stylus conformance terminal evidence.*missing/,
  )

})

test('rejects an open ended or renamed native Sass evaluator closure', () => {
  for (const mutate of [
    contract => { contract.sassEvaluatorClosure.state = 'reduced' },
    contract => { contract.sassEvaluatorClosure.packageState = 'in-progress' },
    contract => { contract.sassEvaluatorClosure.terminalContract.maxArgumentTransportEdges = 2 },
    contract => { contract.sassEvaluatorClosure.terminalContract.argumentOwnerClasses.push('second-peer-hop') },
    contract => {
      contract.sassEvaluatorClosure.remainingPlanDomain.releaseGapFamily =
        contract.sassEvaluatorClosure.releaseGapFamily
    },
    contract => { contract.sassEvaluatorClosure.remainingPlanDomain.referenceCases.push('scss-meta-load-css') },
    contract => { contract.sassEvaluatorClosure.remainingPlanDomain.completedSlices[0].referenceCases.pop() },
  ]) {
    const changed = clone(loadContract())
    mutate(changed)
    assert.throws(() => validateContract(changed), /Sass evaluator closure drifted/)
  }
})

test('binds the finite native Less parser selection and executable evidence', () => {
  const changedSelection = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'tests/preprocessors/less/corpus/selection.json'),
    'utf8',
  ))
  changedSelection.cases.pop()
  assert.throws(
    () => validateContract(loadContract(), { lessSelection: changedSelection }),
    /native Less parser selection drifted/,
  )

  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_parser.zig'), 'utf8')
    .replace('test "native parser accepts every pinned Less success entry"', 'test "removed"')
  assert.throws(
    () => validateContract(loadContract(), { lessParserTests: missingEvidence }),
    /native Less parser evidence.*missing/,
  )
})

test('binds the finite native Stylus parser corpus and executable evidence', () => {
  const changedManifest = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'tests/preprocessors/stylus/corpus/manifest.json'),
    'utf8',
  ))
  changedManifest.cases.pop()
  assert.throws(
    () => validateContract(loadContract(), { stylusManifest: changedManifest }),
    /native Stylus parser corpus drifted/,
  )

  const changedSelection = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'tests/preprocessors/stylus/corpus/selection.json'),
    'utf8',
  ))
  changedSelection.negativeCases = changedSelection.negativeCases.filter(
    specCase => specCase.id !== 'unclosed-expression',
  )
  assert.throws(
    () => validateContract(loadContract(), { stylusSelection: changedSelection }),
    /native Stylus parser selection drifted/,
  )

  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/stylus_parser.zig'), 'utf8')
    .replace('test "native parser accepts every pinned Stylus success entry"', 'test "removed"')
  assert.throws(
    () => validateContract(loadContract(), { stylusParserTests: missingEvidence }),
    /native Stylus parser evidence.*missing/,
  )
})

test('binds the native Stylus evaluator and permanent execution boundary', () => {
  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/stylus_evaluator.zig'), 'utf8')
    .replace(
      'test "native Stylus permanently rejects use plugins without partial CSS"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { stylusEvaluatorTests: missingEvidence }),
    /native Stylus evaluator evidence.*missing/,
  )

  const missingSemanticEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/stylus_evaluator.zig'), 'utf8')
    .replace(
      'test "native Stylus evaluates the fixed callable control operator builtin slice"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { stylusEvaluatorTests: missingSemanticEvidence }),
    /native Stylus evaluator evidence.*missing/,
  )

  const missingImportEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/stylus_evaluator.zig'), 'utf8')
    .replace(
      'test "native Stylus closes confined import require glob dependency and map semantics"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { stylusEvaluatorTests: missingImportEvidence }),
    /native Stylus evaluator evidence.*missing/,
  )

  const weakenedBoundary = fs
    .readFileSync(path.join(repositoryRoot, 'src/preprocessor/stylus_evaluator.zig'), 'utf8')
    .replace(
      'native Stylus use() plugins are permanently disabled',
      'native Stylus use() plugins are unavailable',
    )
  assert.throws(
    () => validateContract(loadContract(), { stylusEvaluatorSource: weakenedBoundary }),
    /native Stylus permanent execution boundary.*missing/,
  )

  const weakenedContract = loadContract()
  const implementation = weakenedContract.implementations.find(
    row => row.id === 'native-stylus-semantic-core',
  )
  implementation.capabilities = implementation.capabilities.filter(
    capability => capability !== 'mixins-functions-control-operators-builtins',
  )
  assert.throws(
    () => validateContract(weakenedContract),
    /implementations.*inventory drifted/,
  )
})

test('binds the native Less evaluator and permanent execution boundary', () => {
  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace(
      'test "native Less permanently rejects JavaScript and plugins without partial CSS"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingEvidence }),
    /native Less evaluator evidence.*missing/,
  )

  const missingSemanticEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace(
      'test "native Less lazily resolves the pinned variable foundation"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingSemanticEvidence }),
    /native Less evaluator evidence.*missing/,
  )

  const missingRulesetEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace(
      'test "native Less evaluates the fixed ruleset operation and builtin matrix"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingRulesetEvidence }),
    /native Less evaluator evidence.*missing/,
  )

  const missingImportEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace(
      'test "native Less closes the confined import option dependency and map foundation"',
      'test "removed"',
    )
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingImportEvidence }),
    /native Less evaluator evidence.*missing/,
  )

  const missingReferenceEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace('less-error-eval-recursive-variable', 'removed-reference-case')
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingReferenceEvidence }),
    /native Less evaluator pinned reference evidence.*missing/,
  )

  const missingRulesetReference = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace('less-mixins-guards-mixins-guards', 'removed-reference-case')
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingRulesetReference }),
    /native Less evaluator pinned reference evidence.*missing/,
  )

  const missingImportReference = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/less_evaluator.zig'), 'utf8')
    .replace('less-import-import-once', 'removed-reference-case')
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorTests: missingImportReference }),
    /native Less evaluator pinned reference evidence.*missing/,
  )

  const weakenedContract = loadContract()
  const lessImplementation = weakenedContract.implementations.find(
    implementation => implementation.id === 'native-less-semantic-core',
  )
  lessImplementation.capabilities = lessImplementation.capabilities.filter(
    capability => capability !== 'ruleset-operation-builtin-foundation',
  )
  assert.throws(
    () => validateContract(weakenedContract),
    /implementations.*inventory drifted/,
  )

  const weakenedImportContract = loadContract()
  const importImplementation = weakenedImportContract.implementations.find(
    implementation => implementation.id === 'native-less-semantic-core',
  )
  importImplementation.capabilities = importImplementation.capabilities.filter(
    capability => capability !== 'confined-import-options-diagnostics-dependencies-maps',
  )
  assert.throws(
    () => validateContract(weakenedImportContract),
    /implementations.*inventory drifted/,
  )

  const weakenedBoundary = fs
    .readFileSync(path.join(repositoryRoot, 'src/preprocessor/less_evaluator.zig'), 'utf8')
    .replace('native Less plugins are permanently disabled', 'native Less plugins are unavailable')
  assert.throws(
    () => validateContract(loadContract(), { lessEvaluatorSource: weakenedBoundary }),
    /native Less permanent execution boundary.*missing/,
  )
})

test('binds the native Sass evaluator closure to executable and pinned reference evidence', () => {
  const missingSemanticEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/sass_evaluator.zig'), 'utf8')
    .replace('test "native Sass owns caller callables across one-hop local module calls"', 'test "removed"')
  assert.throws(
    () => validateContract(loadContract(), { sassEvaluatorTests: missingSemanticEvidence }),
    /native Sass evaluator evidence.*missing/,
  )

  const missingModuleEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/native-preprocessor/sass_evaluator.zig'), 'utf8')
    .replace('test "native Sass resolves the pinned one-hop use selection matrix"', 'test "removed"')
  assert.throws(
    () => validateContract(loadContract(), { sassEvaluatorTests: missingModuleEvidence }),
    /native Sass module-system evidence.*missing/,
  )

  const changedSelection = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'tests/preprocessors/sass/corpus/selection.json'),
    'utf8',
  ))
  changedSelection.upstream.dartSassVersion = '1.101.1'
  assert.throws(
    () => validateContract(loadContract(), { sassSelection: changedSelection }),
    /native Sass evaluator oracle drifted/,
  )
})

test('rejects any widened production runtime boundary', () => {
  for (const [field, value] of [
    ['packageDependencies', 1],
    ['packageOptionalDependencies', 1],
    ['externalLanguageEngines', 1],
    ['compileChildProcesses', 1],
    ['compileNetworkAccess', true],
    ['runtimeDownloads', true],
    ['nonSystemDynamicLanguageLibraries', 1],
  ]) {
    const changed = clone(loadContract())
    changed.productionBoundary[field] = value
    assert.throws(() => validateContract(changed), /production boundary drifted/)
  }
})

test('rejects external modules and escaped files in the native Zig import closure', () => {
  for (const [target, injected] of [
    ['src/preprocessor/sass_string.zig', '@import("sass-runtime")'],
    ['src/preprocessor/sass_string.zig', '@import("../../outside.zig")'],
    ['src/css/emitter.zig', '@import("transitive-runtime")'],
  ]) {
    const productionSources = loadProductionSources().map(([relativePath, source]) => [
      relativePath,
      relativePath === target ? `${source}\nconst drift = ${injected};\n` : source,
    ])
    assert.throws(
      () => validateContract(loadContract(), { productionSources }),
      /imports external module|import escapes the owned Zig source closure/,
    )
  }
})

test('rejects premature native adapter and release claims', () => {
  const adapterClaim = clone(loadContract())
  adapterClaim.adapters[1].current = 'native-graduated'
  assert.throws(() => validateContract(adapterClaim), /must remain reference-only/)

  const releaseClaim = clone(loadContract())
  releaseClaim.nativeReleaseReady = true
  assert.throws(() => validateContract(releaseClaim), /native release must remain fail-closed/)

  const sourceClaim = clone(loadContract())
  sourceClaim.adapters[1].nativeSources = ['src/preprocessor/lexer.zig']
  assert.throws(() => validateContract(sourceClaim), /cannot claim native sources/)
})

test('binds the owner-authorized native publication boundary', () => {
  for (const mutate of [
    authority => { authority.authorized = false },
    authority => { authority.authorizedOn = '2026-07-26' },
    authority => { authority.scope = 'any-release' },
    authority => { authority.workflow = '.github/workflows/build.yml' },
    authority => { authority.channels = ['npm-latest'] },
  ]) {
    const changed = clone(loadContract())
    mutate(changed.nativePublicationAuthority)
    assert.throws(() => validateContract(changed), /native publication authority drifted/)
  }
})

test('binds implemented native foundation sources and focused test inventories', () => {
  const changed = clone(loadContract())
  changed.foundations[0].nativeSources.reverse()
  assert.throws(() => validateContract(changed), /foundation.*inventory drifted/)

  const ownerChanged = clone(loadContract())
  ownerChanged.foundations[0].ownerPackage = 'NATIVE-003'
  assert.throws(() => validateContract(ownerChanged), /foundation.*inventory drifted/)
})

test('binds unavailable native frontend internals without admitting product reachability', () => {
  for (const index of [0, 1, 2, 3, 4, 5, 6]) {
    for (const field of ['publicAvailable', 'productionReachable']) {
      const changed = clone(loadContract())
      changed.implementations[index][field] = true
      assert.throws(() => validateContract(changed), /implementation.*inventory drifted/)
    }
  }

  const sourceChanged = clone(loadContract())
  sourceChanged.implementations[0].nativeSources = ['src/preprocessor/lexer.zig']
  assert.throws(() => validateContract(sourceChanged), /implementation.*inventory drifted/)

  const evaluatorSourceChanged = clone(loadContract())
  evaluatorSourceChanged.implementations[1].nativeSources = ['src/preprocessor/evaluator.zig']
  assert.throws(() => validateContract(evaluatorSourceChanged), /implementation.*inventory drifted/)

  const lessSourceChanged = clone(loadContract())
  lessSourceChanged.implementations[3].nativeSources = ['src/preprocessor/lexer.zig']
  assert.throws(() => validateContract(lessSourceChanged), /implementation.*inventory drifted/)

  const stylusSourceChanged = clone(loadContract())
  stylusSourceChanged.implementations[6].nativeSources = ['src/preprocessor/lexer.zig']
  assert.throws(() => validateContract(stylusSourceChanged), /implementation.*inventory drifted/)

  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: [[
        'src/lib.zig',
        'const sass = @import("preprocessor/sass.zig");',
      ]],
    }),
    /makes the unavailable native frontend production-reachable/,
  )
})

test('binds the current provider package only as migration reference evidence', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  manifest.dependencies = { ...manifest.dependencies, sass: '^1.101.0' }
  assert.throws(
    () => validateContract(loadContract(), { manifest }),
    /canonical reference dependency graph drifted/,
  )
})

test('release tags fail closed until all native rows graduate', () => {
  const contract = validateContract(loadContract())
  assert.throws(
    () => validateReleaseTag(contract, 'v0.5.0-rc.1'),
    /native frontends are not graduated/,
  )
  assert.throws(() => validateReleaseTag(contract, 'not-a-tag'), /invalid release tag/)
})

test('release tags require the exact owner publication authority after graduation', () => {
  const contract = clone(loadContract())
  contract.nativeReleaseReady = true
  contract.nativeReleaseVersion = '0.6.0'
  assert.doesNotThrow(() => validateReleaseTag(contract, 'v0.6.0'))

  contract.nativePublicationAuthority.authorized = false
  assert.throws(
    () => validateReleaseTag(contract, 'v0.6.0'),
    /native publication is not authorized/,
  )
})

test('requires the native interlock before npm publication preflight', () => {
  const releaseWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/release.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), { releaseWorkflow: releaseWorkflow.replace(
      'npm run check:native-contract -- --release-tag "$GITHUB_REF_NAME"',
      'npm run check:version',
    ) }),
    /release workflow is missing/,
  )
})

test('requires one complete build graph with every native frontend runner in CI', () => {
  const buildWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/build.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), { buildWorkflow: buildWorkflow.replaceAll(
      'zig build test --summary all',
      'zig build test-native-preprocessor --summary all',
    ) }),
    /build workflow is missing.*zig build test --summary all/,
  )
  assert.throws(
    () => validateContract(loadContract(), { buildWorkflow: buildWorkflow.replace(
      'zig build test --summary all',
      'zig build test-native-preprocessor --summary all\n        run: zig build test --summary all',
    ) }),
    /must not duplicate native frontend coverage/,
  )

  const buildFile = fs.readFileSync(path.join(repositoryRoot, 'build.zig'), 'utf8')
  assert.throws(
    () => validateContract(loadContract(), { buildFile: buildFile.replace(
      '    test_step.dependOn(&run_native_sass_evaluator_tests.step);',
      '    // removed native Sass evaluator coverage',
    ) }),
    /missing native runner run_native_sass_evaluator_tests/,
  )
  assert.throws(
    () => validateContract(loadContract(), { buildFile: buildFile.replace(
      '    test_step.dependOn(&run_native_sass_conformance_tests.step);',
      '    // removed native Sass conformance coverage',
    ) }),
    /missing native runner run_native_sass_conformance_tests/,
  )
  assert.throws(
    () => validateContract(loadContract(), { buildFile: buildFile.replace(
      '    test_step.dependOn(&run_native_less_conformance_tests.step);',
      '    // removed native Less conformance coverage',
    ) }),
    /missing native runner run_native_less_conformance_tests/,
  )
})
