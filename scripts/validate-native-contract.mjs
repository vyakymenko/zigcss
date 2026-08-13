#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { nativeTargetContract } from './native-target-contract.mjs'
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
    currentReferencePackage: false,
    developmentOracle: true,
    productionInNativeTarget: false,
  }),
  Object.freeze({
    id: 'less',
    package: 'less',
    version: '4.6.7',
    license: 'Apache-2.0',
    adapters: Object.freeze(['less']),
    currentReferencePackage: false,
    developmentOracle: true,
    productionInNativeTarget: false,
  }),
  Object.freeze({
    id: 'stylus',
    package: 'stylus',
    version: '0.64.0',
    license: 'MIT',
    adapters: Object.freeze(['stylus']),
    currentReferencePackage: false,
    developmentOracle: true,
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
  state: 'closed',
  packageState: 'verified',
  oracle: Object.freeze({
    id: 'stylus',
    package: 'stylus',
    version: '0.64.0',
    selection: 'tests/preprocessors/stylus/corpus/selection.json',
    manifest: 'tests/preprocessors/stylus/corpus/manifest.json',
    caseCount: 346,
  }),
  completedCaseCount: 346,
  remainingCaseCount: 0,
  terminalContract: Object.freeze({
    selectionDerived: true,
    successCaseCount: 326,
    errorCaseCount: 20,
    exactSuccessCount: 326,
    nonconformingSuccessCount: 0,
    exactSuccessCaseIdWyhash: '3b55c78d94378874',
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
      'native Stylus closes the finite join conformance family',
      'native Stylus closes the finite JSON conformance family',
      'native Stylus closes the finite length conformance family',
      'native Stylus closes the finite merge conformance family',
      'native Stylus closes the finite prefix classes conformance family',
      'native Stylus closes the finite push conformance family',
      'native Stylus closes the finite saturate desaturate conformance family',
      'native Stylus closes the finite selector conformance family',
      'native Stylus closes the finite selector exists conformance family',
      'native Stylus closes the finite transparentify conformance family',
      'native Stylus closes the finite URL conformance family',
      'native Stylus closes the finite comments conformance family',
      'native Stylus closes the finite compressed units conformance family',
      'native Stylus closes the finite control blueprint screen conformance family',
      'native Stylus closes the finite CSS functions single-line conformance family',
      'native Stylus closes the finite CSS keyframes conformance family',
      'native Stylus closes the finite CSS large conformance family',
      'native Stylus closes the finite CSS mixins root wonky conformance family',
      'native Stylus closes the finite CSS selector interpolation conformance family',
      'native Stylus closes the finite interpolated property conformance family',
      'native Stylus closes the finite introspection conformance family',
      'native Stylus closes the finite keyframes conformance family',
      'native Stylus closes the finite keyframes fabrication defaults conformance family',
      'native Stylus closes the finite keyframes newlines conformance family',
      'native Stylus closes the finite kwargs conformance family',
      'native Stylus closes the finite literal conformance family',
      'native Stylus closes the finite literal color conformance family',
      'native Stylus closes the finite media bubble conformance family',
      'native Stylus closes the finite media complex conformance family',
      'native Stylus closes the finite mixins complex conformance family',
      'native Stylus closes the finite multiline conformance family',
      'native Stylus closes the finite object complex conformance family',
      'native Stylus closes the finite object mixin conformance family',
      'native Stylus closes the finite operator range conformance family',
      'native Stylus closes the finite operators conformance family',
      'native Stylus closes the finite root assignment conformance family',
      'native Stylus closes the finite complex operators conformance family',
      'native Stylus closes the finite CSS selectors conformance family',
      'native Stylus closes the finite CSS whitespace conformance family',
      'native Stylus closes the finite dumb conformance family',
      'native Stylus closes the finite eol escape conformance family',
      'native Stylus closes the finite complex extension conformance family',
      'native Stylus closes the finite loop extension conformance family',
      'native Stylus closes the finite loop context extension conformance family',
      'native Stylus closes the finite media query extension conformance family',
      'native Stylus closes the finite mixin extension conformance family',
      'native Stylus closes the finite nested mixin extension conformance family',
      'native Stylus closes the finite multiple definition extension conformance family',
      'native Stylus closes the finite multiple selector extension conformance family',
      'native Stylus closes the finite variable extension target conformance family',
      'native Stylus closes the finite optional extension target conformance family',
      'native Stylus closes the finite placeholder extension conformance family',
      'native Stylus closes the finite font face conformance family',
      'native Stylus closes the finite complex for-loop conformance family',
      'native Stylus closes the finite function arguments conformance family',
      'native Stylus closes the finite anonymous functions conformance family',
      'native Stylus closes the finite call mixin conformance family',
      'native Stylus closes the finite call to string conformance family',
      'native Stylus closes the finite multiline function conformance family',
      'native Stylus closes the finite multiple call conformance family',
      'native Stylus closes the finite nested function conformance family',
      'native Stylus closes the finite function property conformance family',
      'native Stylus closes the finite function URL conformance family',
      'native Stylus closes the finite if conformance family',
      'native Stylus closes the finite if else conformance family',
      'native Stylus closes the finite if mixin conformance family',
      'native Stylus closes the finite import clone conformance family',
      'native Stylus closes the finite import include complex conformance family',
      'native Stylus closes the finite import include function call conformance family',
      'native Stylus closes the finite import lookup conformance family',
      'native Stylus closes the finite import ordering conformance family',
      'native Stylus closes the finite operator unary conformance family',
      'native Stylus closes the finite parse conformance family',
      'native Stylus closes the finite properties conformance family',
      'native Stylus closes the finite property access conformance family',
      'native Stylus closes the finite regression 1182 conformance family',
      'native Stylus closes the finite regression 1205 conformance family',
      'native Stylus closes the finite regression 1206 conformance family',
      'native Stylus closes the finite regression 1277 conformance family',
      'native Stylus closes the finite regression 130 conformance family',
      'native Stylus closes the finite regression 131 conformance family',
      'native Stylus closes the finite regression 137 conformance family',
      'native Stylus closes the finite regression 142 conformance family',
      'native Stylus closes the finite regression 156 conformance family',
      'native Stylus closes the finite regression 1572 conformance family',
      'native Stylus closes the finite regression 1584 conformance family',
      'native Stylus closes the finite regression 1997 conformance family',
      'native Stylus closes the finite regression 216 conformance family',
      'native Stylus closes the finite regression 272 conformance family',
      'native Stylus closes the finite regression 274 conformance family',
      'native Stylus closes the finite regression 2820 conformance family',
      'native Stylus closes the finite regression 432 conformance family',
      'native Stylus closes the finite regression 475 conformance family',
      'native Stylus closes the finite regression 480 conformance family',
      'native Stylus closes the finite regression 498 conformance family',
      'native Stylus closes the finite regression 499 conformance family',
      'native Stylus closes the finite regression 503 conformance family',
      'native Stylus closes the finite complex selectors conformance family',
      'native Stylus closes the finite nested selectors conformance family',
      'native Stylus closes the finite supports conformance family',
      'native Stylus closes the finite variables conformance family',
      'native Stylus rejects the finite pinned error corpus deterministically',
      'native Stylus parser owns finite resource and cancellation boundaries',
      'native Stylus compilation is deterministic under bounded concurrency',
      'native Stylus finite corpus seeds bounded parser and evaluator fuzzing',
      'native Stylus successful transaction handles every allocation failure',
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

const expectedProductRouting = Object.freeze({
  ownerPackage: 'NATIVE-006',
  releaseGapFamily: 'native-product-routing',
  state: 'closed',
  packageState: 'verified',
  terminalContract: Object.freeze({
    adapters: Object.freeze(['scss', 'sass', 'less', 'stylus']),
    surfaces: Object.freeze([
      'shared-native-compiler',
      'zig-api',
      'binary-cli',
      'javascript-wrapper',
      'files-and-stdin',
      'batch',
      'watch',
      'parallel',
      'diagnostics-and-dependencies',
      'source-maps',
    ]),
    providerProcesses: 0,
  }),
  routes: Object.freeze([
    Object.freeze({
      id: 'shared-native-compiler',
      releaseGapFamily: 'native-shared-compiler-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'native compiler routes every private frontend through one deterministic transaction',
        'native compiler owns source terminal limits without partial results',
        'native compiler rejects invalid roots and language failures without a result',
        'native compiler route handles every allocation failure',
      ]),
    }),
    Object.freeze({
      id: 'zig-api',
      releaseGapFamily: 'native-zig-api-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'external Zig API routes the finite native syntax set through owned CSS results',
        'external Zig API preserves exact input resource limits without partial results',
        'external Zig API rejects invalid roots paths and language failures',
        'external Zig API route handles every allocation failure',
      ]),
    }),
    Object.freeze({
      id: 'binary-cli',
      releaseGapFamily: 'native-binary-cli-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'binary CLI routes the finite native syntax set through the pre-graduation bridge',
        'binary CLI keeps native routing explicit and pending execution modes fail closed',
        'binary CLI native failures commit no partial output',
      ]),
    }),
    Object.freeze({
      id: 'javascript-wrapper',
      releaseGapFamily: 'native-javascript-wrapper-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'javascript wrapper routes the finite native syntax set through the installed binary',
        'javascript wrapper keeps native routing explicit and ungated preprocessors fail closed',
      ]),
    }),
    Object.freeze({
      id: 'files-and-stdin',
      releaseGapFamily: 'native-files-stdin-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'binary CLI routes the finite native syntax set through the pre-graduation bridge',
        'binary CLI routes the finite native syntax set from stdin',
        'binary CLI native stdin confines imports and commits no partial output',
        'binary CLI native stdin enforces the exact input byte terminal',
      ]),
    }),
    Object.freeze({
      id: 'batch',
      releaseGapFamily: 'native-batch-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'binary CLI routes the finite native syntax set through deterministic batches',
        'binary CLI native batch failures commit no partial output',
      ]),
    }),
    Object.freeze({
      id: 'watch',
      releaseGapFamily: 'native-watch-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'external Zig API owns opaque watch snapshots and detects one transition',
        'binary CLI native watch invalidates the finite syntax dependency set',
        'binary CLI native watch failures retain output and recover once',
        'binary CLI native watch rejects entry link substitution and recovers',
      ]),
    }),
    Object.freeze({
      id: 'parallel',
      releaseGapFamily: 'native-parallel-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'binary CLI routes the finite native syntax set through the bounded parallel queue',
        'binary CLI native parallel failure cancels queued work without partial output',
      ]),
    }),
    Object.freeze({
      id: 'diagnostics-and-dependencies',
      releaseGapFamily: 'native-result-facts-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'external Zig API owns native diagnostics and dependency facts',
        'external Zig API returns structured native failures without partial facts',
        'binary CLI renders structured native diagnostics without partial output',
        'javascript wrapper preserves native diagnostic streams and exit status',
      ]),
    }),
    Object.freeze({
      id: 'source-maps',
      releaseGapFamily: 'native-source-map-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'external Zig API composes deterministic source maps for the finite native syntax set',
        'external Zig API composes imported Unicode source positions without intermediate leaks',
        'binary CLI routes composed native source maps through files stdin and parallel batches',
        'binary CLI native watch atomically replaces CSS and its composed source map',
        'javascript wrapper routes the finite native syntax set through the installed binary',
      ]),
    }),
  ]),
})

const expectedPackageMigration = Object.freeze({
  ownerPackage: 'NATIVE-007',
  releaseGapFamily: 'native-zero-dependency-package',
  state: 'closed',
  packageState: 'verified',
  terminalContract: Object.freeze({
    surfaces: Object.freeze([
      'production-package-closure',
      'direct-archive-offline-package',
      'runtime-process-network-tracing',
      'five-native-targets',
      'release-sbom-provenance',
      'consumer-behavior',
    ]),
  }),
  gates: Object.freeze([
    Object.freeze({
      id: 'production-package-closure',
      state: 'verified',
      evidenceTests: Object.freeze([
        'native npm package has zero production and optional dependencies',
        'native npm archive excludes provider host and JavaScript API bytes',
        'javascript wrapper cannot reach the provider host',
      ]),
    }),
    Object.freeze({
      id: 'direct-archive-offline-package',
      state: 'verified',
      evidenceTests: Object.freeze([
        'direct native archive compiles the finite five-language syntax set',
        'offline installed native package compiles the finite five-language syntax set',
      ]),
    }),
    Object.freeze({
      id: 'runtime-process-network-tracing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'direct native archive runtime trace admits one native child and zero network access',
        'offline installed native package runtime trace admits one native child and zero network access',
      ]),
    }),
    Object.freeze({
      id: 'five-native-targets',
      state: 'verified',
      evidenceTests: Object.freeze([
        'native smoke policy covers every release target on one matching runner',
        'native smoke builds a canonical commit-bound five-target receipt',
        'build matrix uploads one commit-bound native receipt from every matching runner',
        'native smoke validates one closed commit-bound receipt set across every release target',
        'build aggregates every matching runner receipt before package verification',
      ]),
    }),
    Object.freeze({
      id: 'release-sbom-provenance',
      state: 'verified',
      evidenceTests: Object.freeze([
        'release metadata is deterministic, bounded SPDX 2.3 with exact SHA-256 subjects',
        'local Sigstore bundles bind exact subjects and predicates before cryptographic verification',
        'release workflow generates, signs, verifies, and uploads the closed five-target inventory',
      ]),
    }),
    Object.freeze({
      id: 'consumer-behavior',
      state: 'verified',
      evidenceTests: Object.freeze([
        'npm installer derives exactly the release workflow asset contract',
        'npm installer independently validates all five executable target headers',
        'npm package runs one installer lifecycle and CI gates it before dependency installation',
      ]),
    }),
  ]),
})

const expectedCapabilityGraduation = Object.freeze({
  ownerPackage: 'NATIVE-008',
  releaseGapFamily: 'native-capability-graduation',
  state: 'closed',
  packageState: 'verified',
  terminalContract: Object.freeze({
    adapters: Object.freeze(['scss', 'sass', 'less', 'stylus']),
    surfaces: Object.freeze([
      'machine-rows',
      'binary-help',
      'readme',
      'website',
      'examples',
      'guides-and-compatibility',
      'changelog-and-migration-notes',
    ]),
    pluginParity: false,
  }),
  gates: Object.freeze([
    Object.freeze({
      id: 'machine-rows',
      state: 'verified',
      closureEvidence: Object.freeze([
        'all four native preprocessor conformance packages are verified',
        'native product routing and zero-dependency packaging are verified',
        'exact native source inventories are bound while public claims remain unchanged',
      ]),
    }),
    Object.freeze({
      id: 'binary-help',
      state: 'verified',
      closureEvidence: Object.freeze([
        'stable native syntax selection and help agree with executable CLI tests',
      ]),
    }),
    Object.freeze({
      id: 'readme',
      state: 'verified',
      closureEvidence: Object.freeze([
        'README describes the exact self-contained native source snapshot',
      ]),
    }),
    Object.freeze({
      id: 'website',
      state: 'verified',
      closureEvidence: Object.freeze([
        'website claims and input/output lab execute the native product path',
      ]),
    }),
    Object.freeze({
      id: 'examples',
      state: 'verified',
      closureEvidence: Object.freeze([
        'public examples compile through the native binary and Zig API',
      ]),
    }),
    Object.freeze({
      id: 'guides-and-compatibility',
      state: 'verified',
      closureEvidence: Object.freeze([
        'machine capability rows and guides agree with native evidence',
      ]),
    }),
    Object.freeze({
      id: 'changelog-and-migration-notes',
      state: 'verified',
      closureEvidence: Object.freeze([
        'changelog and migration notes retain oracle and plugin boundaries',
      ]),
    }),
  ]),
})

const expectedReleaseGraduation = Object.freeze({
  ownerPackage: 'NATIVE-009',
  releaseGapFamily: 'native-release-evidence',
  state: 'in-progress',
  packageState: 'in-progress',
  candidateVersion: null,
  candidateTag: null,
  terminalContract: Object.freeze({
    syntaxes: Object.freeze(['css', 'scss', 'sass', 'less', 'stylus']),
    targets: Object.freeze(nativeTargetContract.map(target => target.target)),
    preTagSurfaces: Object.freeze([
      'release-evidence-contract',
      'immutable-candidate',
      'local-validation',
      'hosted-validation',
      'release-validation',
      'artifact-validation',
      'provenance-validation',
      'consumer-validation',
      'origin-main-integration',
    ]),
    postTagSurfaces: Object.freeze(['tag-workflow-publication']),
    publicationChannels: Object.freeze(['github-prerelease', 'npm-next']),
    npmDistTag: 'next',
    referenceCandidateEligible: false,
  }),
  gates: Object.freeze([
    Object.freeze({
      id: 'release-evidence-contract',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'finite local hosted release artifact provenance consumer and publication surfaces are machine-bound',
        'five native syntax and target inventories are resource-derived',
        'candidate version tag and release interlock remain unselected and closed',
      ]),
    }),
    Object.freeze({
      id: 'immutable-candidate',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'one unused 0.6.x native version and matching immutable v tag are selected',
        'the provider-backed 0.5.0-rc.1 reference candidate remains ineligible',
      ]),
    }),
    Object.freeze({
      id: 'local-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'Debug ReleaseSafe differential fuzz allocation resource documentation package and audit gates pass on the candidate',
      ]),
    }),
    Object.freeze({
      id: 'hosted-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'one automatic Build on the exact integrated candidate passes Test Suite five targets and aggregate evidence within runtime budgets',
      ]),
    }),
    Object.freeze({
      id: 'release-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'version native package workflow and publication preflight policies pass before npm authentication',
      ]),
    }),
    Object.freeze({
      id: 'artifact-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'five exact native archives checksums SPDX inventories and direct smokes pass',
      ]),
    }),
    Object.freeze({
      id: 'provenance-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'five exact archives and SBOMs are bound by verified GitHub attestations',
      ]),
    }),
    Object.freeze({
      id: 'consumer-validation',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'direct archives and offline installed packages compile all five syntaxes on all five targets',
      ]),
    }),
    Object.freeze({
      id: 'origin-main-integration',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'the exact candidate commit is integrated to origin main before tag creation',
      ]),
    }),
    Object.freeze({
      id: 'tag-workflow-publication',
      state: 'pending',
      evidenceRequirements: Object.freeze([
        'one immutable tag produces one GitHub prerelease and the exact npm next publication',
      ]),
    }),
  ]),
})

const websiteSourcePaths = Object.freeze([
  'docs/src/app/components/Home.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Convergence.tsx',
  'docs/src/app/components/FormatShowcase.tsx',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/Playground.tsx',
])

const expectedFormatLabMetadata = Object.freeze([
  Object.freeze({
    id: 'css',
    label: 'CSS',
    extension: '.css',
    frontend: 'Native ZigCSS',
    pipeline: 'CSS → native ZigCSS core → compact CSS',
  }),
  Object.freeze({
    id: 'scss',
    label: 'SCSS',
    extension: '.scss',
    frontend: 'Native Sass frontend',
    pipeline: 'SCSS → native Sass frontend → ZigCSS core → compact CSS',
  }),
  Object.freeze({
    id: 'sass',
    label: 'Sass',
    extension: '.sass',
    frontend: 'Native Sass frontend',
    pipeline: 'Indented Sass → native Sass frontend → ZigCSS core → compact CSS',
  }),
  Object.freeze({
    id: 'less',
    label: 'Less',
    extension: '.less',
    frontend: 'Native Less frontend',
    pipeline: 'Less → native Less frontend → ZigCSS core → compact CSS',
  }),
  Object.freeze({
    id: 'stylus',
    label: 'Stylus',
    extension: '.styl',
    frontend: 'Native Stylus frontend',
    pipeline: 'Stylus → native Stylus frontend → ZigCSS core → compact CSS',
  }),
])

const expectedNativeExampleRows = Object.freeze([
  Object.freeze({
    path: 'examples/native/styles.css',
    syntax: 'css',
    source: '.card {\n  color: red;\n}\n',
    output: '.card{color:red}',
  }),
  Object.freeze({
    path: 'examples/native/styles.scss',
    syntax: 'scss',
    source: '$color: red;\n.card {\n  color: $color;\n}\n',
    output: '.card{color:red}',
  }),
  Object.freeze({
    path: 'examples/native/styles.sass',
    syntax: 'sass',
    source: '$color: red\n.card\n  color: $color\n',
    output: '.card{color:red}',
  }),
  Object.freeze({
    path: 'examples/native/styles.less',
    syntax: 'less',
    source: '@color: red;\n.card {\n  color: @color;\n}\n',
    output: '.card{color:red}',
  }),
  Object.freeze({
    path: 'examples/native/styles.styl',
    syntax: 'stylus',
    source: 'color = red\n.card\n  color color\n',
    output: '.card{color:#f00}',
  }),
])

const expectedNativeCapabilityOracles = Object.freeze({
  scss: 'Dart Sass 1.101.0 development oracle',
  sass: 'Dart Sass 1.101.0 development oracle',
  less: 'Less 4.6.7 development oracle',
  stylus: 'Stylus 0.64.0 development oracle',
})

const expectedDifferentialAdapterSources = Object.freeze({
  scss: Object.freeze([
    'src/preprocessor/sass.zig',
    'src/preprocessor/sass_evaluator.zig',
    'src/preprocessor/sass_arguments.zig',
    'src/preprocessor/sass_numeric.zig',
    'src/preprocessor/sass_color.zig',
    'src/preprocessor/sass_string.zig',
    'src/preprocessor/sass_selector.zig',
  ]),
  sass: Object.freeze([
    'src/preprocessor/sass.zig',
    'src/preprocessor/sass_evaluator.zig',
    'src/preprocessor/sass_arguments.zig',
    'src/preprocessor/sass_numeric.zig',
    'src/preprocessor/sass_color.zig',
    'src/preprocessor/sass_string.zig',
    'src/preprocessor/sass_selector.zig',
  ]),
  less: Object.freeze([
    'src/preprocessor/less.zig',
    'src/preprocessor/less_evaluator.zig',
  ]),
  stylus: Object.freeze([
    'src/preprocessor/stylus.zig',
    'src/preprocessor/stylus_evaluator.zig',
  ]),
})

const expectedReferenceDevelopmentDependencies = Object.freeze({
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
  Object.freeze({
    id: 'native-product-compiler',
    current: 'native-batch',
    ownerPackage: 'NATIVE-006',
    adapters: Object.freeze(['scss', 'sass', 'less', 'stylus']),
    capabilities: Object.freeze([
      'shared-native-compiler',
      'owned-source-table',
      'confined-entry-identity',
      'transactional-result',
      'pre-graduation-zig-api',
      'owned-css-result',
      'bounded-entry-input',
      'pre-graduation-binary-cli',
      'explicit-native-cli-gate',
      'single-file-native-cli',
      'no-partial-cli-output',
      'pre-graduation-javascript-wrapper',
      'explicit-native-wrapper-gate',
      'exact-wrapper-argument-forwarding',
      'pre-graduation-files-and-stdin',
      'cwd-confined-native-stdin',
      'bounded-native-stdin',
      'transactional-native-stdin-output',
      'pre-graduation-native-batch',
      'deterministic-native-batch',
      'compile-before-write-native-batch',
    ]),
    nativeSources: Object.freeze([
      'src/preprocessor/compiler.zig',
      'src/native_api.zig',
    ]),
    testSources: Object.freeze([
      'tests/native-preprocessor/compiler.zig',
      'tests/public-api/native_consumer.zig',
      'tests/cli/native_cli.zig',
      'scripts/verify-node-wrapper.test.mjs',
    ]),
    testStep: 'test-native-cli',
    publicAvailable: false,
    productionReachable: true,
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

function validateWebsiteGraduation(websiteSources, formatExamples, siteExamplesTests) {
  if (websiteSources === null || typeof websiteSources !== 'object' || Array.isArray(websiteSources)) {
    fail('website native source inventory is missing')
  }
  if (!same(Object.keys(websiteSources).sort(), [...websiteSourcePaths].sort())) {
    fail('website native source inventory drifted')
  }

  const home = websiteSources['docs/src/app/components/Home.tsx']
  const gettingStarted = websiteSources['docs/src/app/components/GettingStarted.tsx']
  const convergence = websiteSources['docs/src/app/components/Convergence.tsx']
  const showcase = websiteSources['docs/src/app/components/FormatShowcase.tsx']
  const features = websiteSources['docs/src/app/components/Features.tsx']
  const playground = websiteSources['docs/src/app/components/Playground.tsx']

  requireText(
    home,
    'All five source inputs run through self-contained native Zig frontends.',
    'website native five-language source claim',
  )
  requireText(
    home,
    'zig-out/bin/zigcss --syntax scss input.scss -o output.css --minify',
    'website native source command',
  )
  requireText(home, 'NATIVE SNAPSHOT · RELEASE NOT SHIPPED', 'website unpublished native release boundary')
  requireText(home, 'The providers are ', 'website development-oracle heading')
  requireText(home, 'nativeReleaseReady: false', 'website closed native release interlock')
  requireText(home, 'CLI · JS wrapper · Zig API', 'website thin wrapper interface claim')
  requireText(
    gettingStarted,
    'The source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig frontends and one strict output boundary.',
    'website native getting-started boundary',
  )
  requireText(
    gettingStarted,
    'Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles; they do not run during compilation.',
    'website development-only oracle boundary',
  )
  requireText(
    gettingStarted,
    'Stylesheet compilation itself requires no Node.js, provider process, network service, or runtime download.',
    'website zero-runtime compilation boundary',
  )
  requireText(
    gettingStarted,
    'The package JavaScript wrapper only locates and invokes that binary; it does not host language semantics.',
    'website thin JavaScript wrapper boundary',
  )
  requireText(
    convergence,
    'Native frontends feed one fail-closed Zig core.',
    'website native convergence claim',
  )
  requireText(
    showcase,
    'Every recorded fixture is executed by the source-built native ZigCSS binary.',
    'website native lab claim',
  )
  requireText(showcase, '{selected.frontend}', 'website native lab frontend label')
  requireText(
    features,
    'The compatibility table below records the closed NATIVE-008 native-differential source snapshot; release graduation remains fail-closed under NATIVE-009.',
    'website closed compatibility boundary',
  )
  requireText(playground, 'Playground unavailable', 'website public compile service boundary')
  requireText(playground, 'The public compile API is disabled', 'website disabled public compile API')

  const combinedWebsite = Object.values(websiteSources).join('\n').toLowerCase()
  for (const staleClaim of [
    'npm ci\\nzig build\\nnode index.js input.scss',
    'Five canonical inputs, one bounded host',
    'CSS runs natively. SCSS and Sass run through Dart Sass',
    'Node.js 20.19 or newer is also required for the canonical frontend host',
    'executable remains the CSS-only core',
    'Exact pinned frontends feed one fail-closed Zig core',
    'inspect the exact provider, bytes, digest',
    'Canonical preprocessor behavior remains version-pinned',
    'The target replaces Dart Sass, Less, and Stylus with native Zig frontends',
    'CLI · JS API · Zig API',
  ]) {
    if (combinedWebsite.includes(staleClaim.toLowerCase())) {
      fail(`website retains stale provider-era source claim: ${JSON.stringify(staleClaim)}`)
    }
  }

  if (!Array.isArray(formatExamples) || formatExamples.length !== expectedFormatLabMetadata.length) {
    fail(`website native lab must contain ${expectedFormatLabMetadata.length} exact syntax rows`)
  }
  for (const [index, example] of formatExamples.entries()) {
    exactKeys(
      example,
      ['id', 'label', 'extension', 'frontend', 'input', 'output', 'pipeline', 'note'],
      `website format examples[${index}]`,
    )
    const metadata = {
      id: example.id,
      label: example.label,
      extension: example.extension,
      frontend: example.frontend,
      pipeline: example.pipeline,
    }
    if (!same(metadata, expectedFormatLabMetadata[index])) {
      fail(`website native lab metadata drifted at row ${index}`)
    }
    if (typeof example.input !== 'string' || example.input.length === 0 ||
        typeof example.output !== 'string' || example.output.length === 0) {
      fail(`website native lab row ${example.id} must own nonempty input and output`)
    }
  }
  for (const [id, oracle] of [
    ['scss', 'Dart Sass 1.101.0'],
    ['sass', 'Dart Sass 1.101.0'],
    ['less', 'Less 4.6.7'],
    ['stylus', 'Stylus 0.64.0'],
  ]) {
    const example = formatExamples.find(row => row.id === id)
    requireText(example?.note ?? '', 'development-only', `website ${id} lab oracle role`)
    requireText(example?.note ?? '', oracle, `website ${id} lab oracle identity`)
  }

  for (const [needle, label] of [
    ["import { spawnSync } from 'node:child_process'", 'website lab native process harness'],
    [
      "spawnSync(binaryPath, ['-', '--syntax', example.id, '--minify'],",
      'website lab native executable evidence',
    ],
    ['assert.equal(result.status, 0', 'website lab native exit evidence'],
    ['assert.equal(result.stdout, example.output, example.id)', 'website lab exact output evidence'],
    ['assert.match(result.stderr, /experimental release candidate/)', 'website lab warning evidence'],
  ]) {
    requireText(siteExamplesTests, needle, label)
  }
  for (const forbidden of [
    'compileStringWithRuntime',
    'runPreprocessorHost',
    'preprocessor/product-api.mjs',
    'preprocessor/runner.mjs',
    'preprocessor/core-runner.mjs',
  ]) {
    if (siteExamplesTests.includes(forbidden)) {
      fail(`website lab executable evidence retains provider host path ${JSON.stringify(forbidden)}`)
    }
  }
}

function validateCapabilityGraduation(
  graduation,
  productionSources,
  cliTests,
  plan,
  readme,
  websiteSources,
  formatExamples,
  siteExamplesTests,
  buildFile,
  documentationPolicy,
  nativeApiExample,
  nativeExampleSources,
  buildGuide,
  formatGuide,
  recoveryGuide,
  statusGuide,
  formatMatrix,
  capabilityMetadata,
  changelog,
) {
  if (!same(graduation, expectedCapabilityGraduation)) {
    fail('capability graduation contract drifted')
  }
  requireText(plan, '`NATIVE-008` | Graduate native rows in machine metadata', 'NATIVE-008 plan package')

  const binaryCli = new Map(productionSources).get('src/main.zig') ?? ''
  const help = binaryCli.match(/fn printUsage\(\) !void \{[\s\S]*?\n\}/)?.[0]
  if (help === undefined) fail('native binary help implementation is missing')
  requireText(
    help,
    '--syntax <syntax>        Select css (default), scss, sass, less, or stylus',
    'stable native syntax help',
  )
  requireText(
    help,
    '--source-map             Embed a composed map for a native stylesheet syntax',
    'stable native source-map help',
  )
  for (const forbidden of ['--experimental-native', 'gated native syntax', 'pre-graduation']) {
    if (help.includes(forbidden)) fail(`native binary help retains pre-graduation option ${JSON.stringify(forbidden)}`)
  }
  if (binaryCli.includes('the native route requires --experimental-native')) {
    fail('stable native syntax selection still requires the experimental gate')
  }

  const evidenceName = 'stable native syntax selection and help agree with executable CLI tests'
  const evidence = cliTests.match(new RegExp(
    `test "${evidenceName}" \\{[\\s\\S]*?\\n\\}\\n\\ntest `,
  ))?.[0]
  if (evidence === undefined) fail('stable native CLI executable evidence is missing')
  requireText(evidence, 'inline for (route_cases)', 'finite stable native syntax evidence')
  requireText(
    evidence,
    'runCompilerNamed(case.filename, case.input, &.{\n            "--syntax",',
    'ungated stable native syntax evidence',
  )
  requireText(evidence, '--syntax <syntax>        Select css (default), scss, sass, less, or stylus', 'stable help evidence')

  for (const [needle, label] of [
    [
      'The current source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths.',
      'README native five-language source snapshot',
    ],
    [
      'Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles.',
      'README development-only oracle boundary',
    ],
    [
      'zero `dependencies` and zero `optionalDependencies`',
      'README zero production dependency boundary',
    ],
    [
      'The compiler itself starts no child process, performs no network access, and requires no runtime download.',
      'README zero-runtime compilation boundary',
    ],
    [
      '| CSS (`.css`) | Native ZigCSS tokenizer/parser | `native-graduated` |',
      'README CSS native-graduated row',
    ],
    [
      '| SCSS (`.scss`) | Native Sass-family parser/evaluator | `native-differential` |',
      'README SCSS native-differential row',
    ],
    [
      '| Sass (`.sass`) | Native Sass-family parser/evaluator | `native-differential` |',
      'README Sass native-differential row',
    ],
    [
      '| Less (`.less`) | Native Less parser/evaluator | `native-differential` |',
      'README Less native-differential row',
    ],
    [
      '| Stylus (`.styl`) | Native Stylus parser/evaluator | `native-differential` |',
      'README Stylus native-differential row',
    ],
    [
      'Arbitrary Sass plugins, custom functions and importers, Less JavaScript and plugins, Stylus plugins and evaluator hooks, and executable project code remain outside the native product contract.',
      'README native plugin boundary',
    ],
    [
      'The package JavaScript wrapper only locates and invokes the installed native binary; it does not host language semantics.',
      'README thin JavaScript wrapper boundary',
    ],
    ['`nativeReleaseReady: false`', 'README closed native release interlock'],
  ]) {
    requireText(readme, needle, label)
  }

  for (const [syntax, extension] of [
    ['css', 'css'],
    ['scss', 'scss'],
    ['sass', 'sass'],
    ['less', 'less'],
    ['stylus', 'styl'],
  ]) {
    requireText(
      readme,
      `zig-out/bin/zigcss --syntax ${syntax} styles.${extension} -o dist/styles.css --minify`,
      'README explicit native syntax commands',
    )
  }

  const normalizedReadme = readme.toLowerCase()
  for (const staleClaim of [
    'the four preprocessor frontends are moving through private native conformance gates',
    'source snapshot adds a canonical five-language reference pipeline',
    'Private Zig parser/evaluator in progress',
    'Planned after Sass graduation',
    'Planned after Less graduation',
    'The CSS-only native executable is written to',
    'root npm launcher composes that core with the exact canonical development providers',
    'before any provider process can start',
    'semantic core under active conformance development',
    'native implementations pending in dependency order',
    'Native package routing and zero-dependency cutover: gated behind all language graduations',
  ]) {
    if (normalizedReadme.includes(staleClaim.toLowerCase())) {
      fail(`README retains stale provider-era source claims: ${JSON.stringify(staleClaim)}`)
    }
  }

  validateWebsiteGraduation(websiteSources, formatExamples, siteExamplesTests)

  if (nativeExampleSources === null || typeof nativeExampleSources !== 'object' || Array.isArray(nativeExampleSources)) {
    fail('native binary example inventory is missing')
  }
  if (!same(Object.keys(nativeExampleSources).sort(), expectedNativeExampleRows.map(row => row.path).sort())) {
    fail('native binary example inventory drifted from its finite terminal set')
  }
  for (const row of expectedNativeExampleRows) {
    if (nativeExampleSources[row.path] !== row.source) {
      fail(`native binary example source drifted for ${row.path}`)
    }
    requireText(buildFile, `b.path("${row.path}")`, `native binary example build row ${row.path}`)
    requireText(buildFile, `.syntax = "${row.syntax}"`, `native binary example syntax ${row.syntax}`)
    requireText(buildFile, `.expected = "${row.output}"`, `native binary example output ${row.syntax}`)
  }
  for (const [needle, label] of [
    ['const native_cli_examples = [_]NativeCliExample{', 'finite native binary example table'],
    ['for (native_cli_examples) |example| {', 'parameterized native binary example execution'],
    ['documentation_examples_step.dependOn(&run_native_cli_example.step);', 'documentation native binary example gate'],
    ['b.path("examples/native_api.zig")', 'native Zig API example build input'],
    ['documentation_examples_step.dependOn(&run_native_api_example.step);', 'documentation native Zig API example gate'],
    ['"test-native-product"', 'focused native product evidence gate'],
    ['native_product_step.dependOn(&run_native_zig_api_tests.step);', 'native product Zig API evidence ownership'],
    ['native_product_step.dependOn(&run_native_cli_tests.step);', 'native product binary evidence ownership'],
  ]) {
    requireText(buildFile, needle, label)
  }
  for (const [needle, label] of [
    ['const examples = [_]Example{', 'finite native Zig API example table'],
    ['inline for (examples) |example| {', 'parameterized native Zig API example execution'],
    ['var result = try native.compile(', 'native Zig API example compile call'],
    ['.root_paths = &.{root}', 'native Zig API example confined root'],
    ['.format = .minified', 'native Zig API example deterministic format'],
  ]) {
    requireText(nativeApiExample, needle, label)
  }
  for (const syntax of Object.keys(expectedNativeCapabilityOracles)) {
    requireText(nativeApiExample, `.syntax = .${syntax}`, `native Zig API ${syntax} row`)
  }
  if (!same(documentationPolicy.executableZigExamples, [
    'examples/public_api.zig',
    'examples/native_api.zig',
    'examples/css_modules.zig',
  ])) {
    fail('documentation executable Zig example inventory drifted')
  }
  const nativeFence = /<!-- native-api-example:start -->\s*```zig\n([\s\S]*?)\n```\s*<!-- native-api-example:end -->/
  for (const [document, label] of [[readme, 'README'], [buildGuide, 'build-from-source guide']]) {
    const example = document.match(nativeFence)?.[1]
    if (example === undefined || example.trim() !== nativeApiExample.trim()) {
      fail(`${label} native Zig API example drifted from the compiled source`)
    }
  }

  if (formatMatrix.schemaVersion !== 4 || !Array.isArray(formatMatrix.adapters)) {
    fail('format matrix must use native capability schema 4')
  }
  const nativeRows = formatMatrix.adapters.filter(row =>
    Object.hasOwn(expectedNativeCapabilityOracles, row.id))
  if (!same(nativeRows.map(row => row.id), Object.keys(expectedNativeCapabilityOracles))) {
    fail('format matrix native adapter inventory drifted')
  }
  for (const row of nativeRows) {
    if (row.nativeSyntax !== row.id || row.availability !== 'NativeCliZigApi' ||
        row.compatibility !== 'NativeDifferential' || row.implementation !== 'NativeFrontend' ||
        row.strategy !== 'native-reimplementation') {
      fail(`format matrix native capability state drifted for ${row.id}`)
    }
    if (typeof row.referenceOracleId !== 'string' || row.referenceOracleId.length === 0) {
      fail(`format matrix native reference oracle is missing for ${row.id}`)
    }
  }

  if (!Array.isArray(capabilityMetadata.capabilities)) {
    fail('capability metadata row inventory is missing')
  }
  const capabilities = new Map(capabilityMetadata.capabilities.map(row => [row.id, row]))
  for (const [id, oracle] of Object.entries(expectedNativeCapabilityOracles)) {
    const row = capabilities.get(id)
    if (row?.status !== 'Native differential verified' || row.statusKind !== 'verified') {
      fail(`capability metadata native status drifted for ${id}`)
    }
    requireText(row.behavior, '`zigcss.experimental_native`', `capability metadata native Zig API ${id}`)
    requireText(row.behavior, oracle, `capability metadata development oracle ${id}`)
    requireText(row.behavior, 'does not run during compilation', `capability metadata oracle execution boundary ${id}`)
  }

  for (const [document, label, needles] of [
    [
      formatGuide,
      'format compatibility guide',
      [
        'The four preprocessor rows are `native-differential`, not yet `native-graduated`',
        'These exact providers are development-only reference oracles.',
        'they do not run during compilation',
        'CSS-in-JS, PostCSS plugin execution, and Tailwind-like compilation remain unavailable.',
      ],
    ],
    [
      statusGuide,
      'status guide',
      [
        'SCSS, indented Sass, Less, and Stylus route through self-contained native Zig parser/evaluators',
        'The package JavaScript wrapper only locates and invokes that binary',
        'The explicit `zigcss.experimental_native` namespace admits exactly SCSS, indented Sass, Less, and Stylus.',
        '`NATIVE-009` release graduation is closed',
      ],
    ],
    [
      recoveryGuide,
      'native CLI guide',
      [
        'SCSS, indented Sass, Less, and Stylus enter self-contained native Zig parser/evaluators',
        'The root JavaScript launcher only locates and invokes the binary',
        'Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 are development-only reference oracles.',
        'They do not run during compilation',
        'Matching a development oracle does not grant those extension points implicitly.',
      ],
    ],
    [
      buildGuide,
      'build-from-source guide',
      [
        'Exact Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 providers remain development-only reference oracles',
        'do not run during compilation',
        'examples/native/styles.styl',
      ],
    ],
    [
      changelog,
      'changelog migration notes',
      [
        '`NATIVE-008` closes the finite source-capability inventory',
        '`nativeReleaseReady` remains `false`',
        'remain exact development-only reference oracles and do not run during compilation',
        'zero production dependencies and zero optional dependencies',
        'The former programmatic provider-backed JavaScript preprocessor API is not part of this source contract.',
        'Keep arbitrary preprocessor plugins, custom functions/importers, Less JavaScript, Stylus evaluator hooks, executable project code',
      ],
    ],
  ]) {
    for (const needle of needles) requireText(document, needle, label)
  }
}

function validateReleaseGraduation(release, plan, buildWorkflow, releaseWorkflow) {
  if (!same(release, expectedReleaseGraduation)) {
    fail('release graduation contract drifted')
  }

  requireText(
    plan,
    '`NATIVE-009` | Select one immutable native release candidate, pass every local/hosted/release/consumer gate',
    'NATIVE-009 roadmap release contract',
  )
  for (const target of nativeTargetContract) {
    requireText(buildWorkflow, `target: ${target.target}`, `Build native target ${target.target}`)
    requireText(releaseWorkflow, `target: ${target.target}`, `Release native target ${target.target}`)
  }
  for (const [needle, label] of [
    ['name: Test Suite', 'hosted Test Suite evidence'],
    ['name: Native Package Evidence', 'hosted aggregate package evidence'],
    ['  npm-preflight:\n', 'release npm preflight'],
    ['  release:\n', 'release artifact matrix'],
    ['  create-release:\n', 'GitHub prerelease creation'],
    ['  publish-npm:\n', 'npm next publication'],
    ['needs: npm-preflight', 'artifact dependency on npm preflight'],
    ['needs: release', 'GitHub prerelease dependency on artifacts'],
    ['needs: create-release', 'npm publication dependency on GitHub prerelease'],
    ['npm publish --tag next --provenance', 'npm next provenance publication'],
    ['prerelease: true', 'GitHub prerelease boundary'],
  ]) {
    requireText(
      needle.startsWith('name:') ? buildWorkflow : releaseWorkflow,
      needle,
      label,
    )
  }
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
    if (adapter.current !== 'native-differential') {
      fail(`${adapter.id} must remain native-differential until the NATIVE-009 release gate closes`)
    }
    if (!same(adapter.nativeSources, expectedDifferentialAdapterSources[adapter.id])) {
      fail(`${adapter.id} native source inventory drifted`)
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
    if (adapter.current !== 'native-differential') {
      fail(`${label} requires the bounded native-differential ${adapterId} adapter state`)
    }
  }
  for (const source of implementation.nativeSources) repositoryFile(source)
  for (const source of implementation.testSources) repositoryFile(source)
}

function validateProductRouting(
  routing,
  plan,
  compilerTests,
  zigApiTests,
  cliTests,
  nodeWrapperSource,
  nodeWrapperTests,
  sassConformanceTests,
  lessConformanceTests,
  stylusConformanceTests,
) {
  if (!same(routing, expectedProductRouting)) fail('product routing contract drifted')
  requireText(
    plan,
    '`NATIVE-006` | Route individually graduated native syntaxes through the Zig API, binary CLI, JavaScript wrapper, files/stdin, batch, watch, parallel, diagnostics, dependencies, and source maps without a provider process',
    'DEVELOPMENT_PLAN.md native product routing package',
  )
  if (!same(
    routing.terminalContract.surfaces,
    routing.routes.map(route => route.id),
  )) {
    fail('product routing terminal surface inventory drifted')
  }
  for (const route of routing.routes) {
    if (route.state === 'verified') {
      if (route.evidenceTests.length === 0) fail('product routing verified route lacks evidence')
      const evidenceSource = route.id === 'shared-native-compiler'
        ? compilerTests
        : route.id === 'zig-api'
          ? zigApiTests
          : route.id === 'binary-cli'
            ? cliTests
            : route.id === 'javascript-wrapper'
              ? nodeWrapperTests
              : route.id === 'files-and-stdin' || route.id === 'batch' || route.id === 'parallel'
                ? cliTests
                : route.id === 'watch'
                  ? `${zigApiTests}\n${cliTests}`
                  : route.id === 'diagnostics-and-dependencies'
                    ? `${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                    : route.id === 'source-maps'
                      ? `${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                      : ''
      for (const evidenceTest of route.evidenceTests) {
        const testDeclaration = route.id === 'javascript-wrapper' ||
          ((route.id === 'diagnostics-and-dependencies' || route.id === 'source-maps') &&
            evidenceTest.startsWith('javascript wrapper '))
          ? `test('${evidenceTest}'`
          : `test "${evidenceTest}"`
        requireText(
          evidenceSource,
          testDeclaration,
          `native product routing ${route.id} evidence`,
        )
      }
    } else if (route.state !== 'pending' || route.evidenceTests.length !== 0) {
      fail('product routing pending route drifted')
    }
  }
  requireText(
    cliTests,
    'const native_parallel_worker_cap = 8;',
    'native product routing parallel worker terminal',
  )
  requireText(
    cliTests,
    'const native_parallel_queued_case_count = native_parallel_worker_cap + 1;',
    'native product routing parallel queued over-boundary',
  )
  requireText(
    nodeWrapperSource,
    'runNative(binaryPath, args);',
    'native product routing JavaScript wrapper binary dispatch',
  )
  for (const [label, tests] of [
    ['Sass', sassConformanceTests],
    ['Less', lessConformanceTests],
    ['Stylus', stylusConformanceTests],
  ]) {
    requireText(
      tests,
      'const compiler = preprocessor.compiler;',
      `native product routing ${label} conformance`,
    )
    requireText(
      tests,
      'return compiler.compile(',
      `native product routing ${label} conformance`,
    )
  }
}

function validatePackageMigration(
  migration,
  plan,
  manifest,
  packageTests,
  nodeWrapperSource,
  nodeWrapperTests,
  releaseSmokeSource,
  releaseSmokeTests,
  nativePackageEvidenceTests,
  releaseMetadataTests,
  releaseConsumerTests,
  releaseSmokePreloadSource,
  productionSources,
) {
  if (!same(migration, expectedPackageMigration)) fail('native package migration contract drifted')
  requireText(
    plan,
    '`NATIVE-007` | Remove production providers/host/runtime closure; prove zero `dependencies` and `optionalDependencies`, closed archive/package inventories, no compile child process/network/runtime data, offline installation, five native targets, SBOM, provenance, and consumer behavior',
    'DEVELOPMENT_PLAN.md native package migration package',
  )
  if (!same(
    migration.terminalContract.surfaces,
    migration.gates.map(gate => gate.id),
  )) {
    fail('native package migration terminal surface inventory drifted')
  }
  for (const gate of migration.gates) {
    if (gate.state === 'verified' || gate.state === 'implemented') {
      if (gate.evidenceTests.length === 0) fail('native package migration verified gate lacks evidence')
      for (const evidenceTest of gate.evidenceTests) {
        let source = packageTests
        if (
          evidenceTest.startsWith('native smoke validates ')
          || evidenceTest.startsWith('build aggregates ')
        ) {
          source = nativePackageEvidenceTests
        } else if (
          evidenceTest.startsWith('release metadata ')
          || evidenceTest.startsWith('local Sigstore ')
          || evidenceTest.startsWith('release workflow generates, ')
        ) {
          source = releaseMetadataTests
        } else if (
          evidenceTest.startsWith('npm installer ')
          || evidenceTest.startsWith('npm package ')
        ) {
          source = releaseConsumerTests
        } else if (evidenceTest.startsWith('javascript wrapper ')) {
          source = nodeWrapperTests
        } else if (
          evidenceTest.startsWith('direct native archive ')
          || evidenceTest.startsWith('offline installed native package ')
          || evidenceTest.startsWith('native smoke ')
          || evidenceTest.startsWith('build matrix ')
        ) {
          source = releaseSmokeTests
        }
        requireText(
          source,
          `test('${evidenceTest}'`,
          `native package migration ${gate.id} evidence`,
        )
      }
    } else if (gate.state !== 'pending' || gate.evidenceTests.length !== 0) {
      fail('native package migration pending gate drifted')
    }
  }

  if (!same(manifest.dependencies ?? {}, {})) {
    fail('native package migration production dependency closure is not empty')
  }
  if (Object.keys(manifest.optionalDependencies ?? {}).length !== 0) {
    fail('native package migration optional dependency closure is not empty')
  }
  const referenceDependencies = Object.fromEntries(
    Object.keys(expectedReferenceDevelopmentDependencies).map(name => [
      name,
      manifest.devDependencies?.[name],
    ]),
  )
  if (!same(referenceDependencies, expectedReferenceDevelopmentDependencies)) {
    fail('native package migration development oracle graph drifted')
  }
  if (!same(manifest.exports, {
    '.': './index.js',
    './package.json': './package.json',
  })) {
    fail('native package migration export inventory drifted')
  }
  if (!Array.isArray(manifest.files) || manifest.files.some(relativePath => (
    relativePath === 'api.mjs' ||
    relativePath === 'preprocessor' ||
    relativePath.startsWith('preprocessor/')
  ))) {
    fail('native package migration retained provider host or JavaScript API bytes')
  }
  for (const forbidden of ['preprocessor/', 'shouldUseProductCli', 'import(']) {
    if (nodeWrapperSource.includes(forbidden)) {
      fail(`native package migration JavaScript wrapper retained ${forbidden}`)
    }
  }
  requireText(
    nodeWrapperSource,
    'runNative(binaryPath, args);',
    'native package migration JavaScript wrapper binary dispatch',
  )
  requireText(
    releaseSmokeSource,
    'const directNativeSmokes = checkNativePreprocessors(',
    'native package migration direct archive language smoke',
  )
  requireText(
    releaseSmokeSource,
    'const offlineNativeSmokes = checkNativePreprocessors(',
    'native package migration offline package language smoke',
  )
  requireText(
    releaseSmokeSource,
    "npm_config_offline: 'true'",
    'native package migration offline package mode',
  )
  for (const [needle, label] of [
    ['const directRuntimeTrace = createRuntimeTrace(', 'direct archive runtime trace creation'],
    ['validateRuntimeTrace(directRuntimeTrace, 6,', 'direct archive runtime trace'],
    ['const offlineRuntimeTrace = createRuntimeTrace(', 'offline package runtime trace creation'],
    ['validateRuntimeTrace(offlineRuntimeTrace, 6,', 'offline package runtime trace'],
    ['offlineEnvironment,', 'offline package traced environment'],
    ['export function nativeTargetEvidence(', 'five-target receipt construction'],
    ['export function writeNativeTargetEvidence(', 'five-target receipt write'],
    ['nativeTargetEvidence(result, {', 'five-target receipt main binding'],
    ['writeNativeTargetEvidence(repositoryRoot, options.evidence, evidence)', 'five-target receipt output binding'],
  ]) {
    requireText(
      releaseSmokeSource,
      needle,
      `native package migration ${label}`,
    )
  }
  for (const [needle, label] of [
    ['childProcess.spawn = function tracedNativeSpawn', 'admitted native child trace'],
    ['childProcess.ChildProcess.prototype.spawn = function guardedChildSpawn', 'direct ChildProcess denial'],
    ['Reflect.ownKeys(options)', 'native child option inventory'],
    ['optionKeys.length !== 2', 'native child exact option boundary'],
    ["['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']", 'alternate child denial'],
    ["record('native-spawn')", 'native spawn event'],
    ["record('network-denied')", 'network denial event'],
    ['http.request =', 'HTTP denial'],
    ['https.request =', 'HTTPS denial'],
    ['net.connect =', 'TCP denial'],
    ['net.Server.prototype.listen =', 'listener denial'],
    ['net.createServer =', 'TCP server denial'],
    ['http.createServer =', 'HTTP server denial'],
    ['https.createServer =', 'HTTPS server denial'],
    ['tls.connect =', 'TLS denial'],
    ['tls.createServer =', 'TLS server denial'],
    ['http2.connect =', 'HTTP2 denial'],
    ['http2.createServer =', 'HTTP2 server denial'],
    ['http2.createSecureServer =', 'secure HTTP2 server denial'],
    ['dgram.createSocket =', 'datagram denial'],
    ["dns.lookup = denyDnsCallback('dns.lookup')", 'DNS denial'],
    ['dns.Resolver = class DisabledDnsResolver', 'callback DNS resolver denial'],
    ['dnsPromises.Resolver = class DisabledDnsPromisesResolver', 'promise DNS resolver denial'],
    ['globalThis.fetch =', 'fetch denial'],
    ["event: 'runtime-summary'", 'runtime summary'],
  ]) {
    requireText(
      releaseSmokePreloadSource,
      needle,
      `native package migration ${label}`,
    )
  }

  const forbiddenRuntimePrimitives = [
    ['process', 'std.process.Child'],
    ['process', 'std.ChildProcess'],
    ['process', 'std.posix.exec'],
    ['process', 'std.posix.fork'],
    ['process', 'std.posix.spawn'],
    ['process', 'CreateProcessA'],
    ['process', 'CreateProcessW'],
    ['network', 'std.net'],
    ['network', 'std.http'],
    ['network', 'std.crypto.tls'],
    ['network', 'std.posix.socket'],
    ['network', 'std.posix.connect'],
    ['network', 'ws2_32'],
    ['foreign runtime', 'std.DynLib'],
    ['foreign runtime', 'dlopen'],
    ['foreign runtime', 'LoadLibraryA'],
    ['foreign runtime', 'LoadLibraryW'],
    ['foreign runtime', 'GetProcAddress'],
    ['foreign runtime', '@cImport'],
    ['foreign runtime', '@extern'],
  ]
  for (const [relativePath, source] of productionSources) {
    for (const [kind, primitive] of forbiddenRuntimePrimitives) {
      if (source.includes(primitive)) {
        fail(`native package migration runtime closure contains forbidden ${kind} primitive ${primitive} in ${relativePath}`)
      }
    }
  }
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

function validateInternalReachability(implementations, buildFile, productionSources, nodeWrapperTests) {
  requireText(buildFile, 'root_source_file = b.path("src/preprocessor.zig")', 'build.zig')
  for (const implementation of implementations) {
    for (const testSource of implementation.testSources) {
      if (!testSource.endsWith('.zig')) continue
      requireText(
        buildFile,
        `root_source_file = b.path("${testSource}")`,
        `${implementation.id} test wiring`,
      )
    }
  }
  requireText(
    buildFile,
    'root_source_file = b.path("tests/public-api/native_consumer.zig")',
    'native Zig API test wiring',
  )
  requireText(
    buildFile,
    '"test-native-zig-api"',
    'native Zig API focused test step',
  )
  requireText(
    buildFile,
    'test_step.dependOn(&run_native_zig_api_tests.step);',
    'native Zig API aggregate test ownership',
  )
  requireText(
    buildFile,
    'root_source_file = b.path("tests/cli/native_cli.zig")',
    'native binary CLI test wiring',
  )
  requireText(
    buildFile,
    '"test-native-cli"',
    'native binary CLI focused test step',
  )
  requireText(
    buildFile,
    'test_step.dependOn(&run_native_cli_tests.step);',
    'native binary CLI aggregate test ownership',
  )
  const sourceByPath = new Map(productionSources)
  const libraryRoot = sourceByPath.get('src/lib.zig') ?? ''
  const nativeApi = sourceByPath.get('src/native_api.zig') ?? ''
  const nativeCompiler = sourceByPath.get('src/preprocessor/compiler.zig') ?? ''
  const nativeSourceMap = sourceByPath.get('src/preprocessor/sourcemap.zig') ?? ''
  const binaryCli = sourceByPath.get('src/main.zig') ?? ''
  const sassEvaluator = sourceByPath.get('src/preprocessor/sass_evaluator.zig') ?? ''
  requireText(
    libraryRoot,
    'pub const experimental_native = @import("native_api.zig");',
    'public pre-graduation native Zig API namespace',
  )
  const bridgeImports = [...nativeApi.matchAll(/@import\s*\(\s*"(preprocessor\/[^"]+)"\s*\)/g)]
    .map(match => match[1])
  if (!same(bridgeImports, [
    'preprocessor/compiler.zig',
    'preprocessor/resolver.zig',
  ])) {
    fail('native Zig API bridge import inventory drifted')
  }
  requireText(
    nativeApi,
    'const css = try allocator.dupe(u8, compiled.css());',
    'native Zig API owned CSS promotion',
  )
  requireText(
    nativeApi,
    '.source_map = options.source_map,',
    'native Zig API source-map request promotion',
  )
  requireText(
    nativeApi,
    'compiled.composeSourceMap(allocator)',
    'native Zig API composed source-map promotion',
  )
  requireText(
    nativeApi,
    'source_map: ?[]const u8,',
    'native Zig API owned source-map result',
  )
  requireText(
    nativeApi,
    'if (self.source_map) |bytes| allocator.free(bytes);',
    'native Zig API source-map teardown',
  )
  requireText(
    nativeCompiler,
    'pub fn composeSourceMap(',
    'native compiler source-map composition route',
  )
  requireText(
    nativeCompiler,
    'native_sourcemap.composeCoreMap(',
    'native compiler two-stage source-map composition',
  )
  for (const [needle, label] of [
    ['pub fn composeCoreMap(', 'native source-map bounded composition'],
    ['core_sourcemap.decodeMappings(', 'native source-map strict core decoding'],
    ['const inner = frontend.lookup(', 'native source-map greatest-lower-bound tracing'],
    ['max_composed_source_map_bytes', 'native source-map output terminal'],
  ]) {
    requireText(nativeSourceMap, needle, label)
  }
  for (const [needle, label] of [
    ['fn renderNativeCss(', 'native binary CLI source-map renderer'],
    ['std.base64.standard.Encoder.encode(', 'native binary CLI inline source-map encoding'],
    ['task.rendered_css = renderNativeCss(', 'native binary CLI parallel map preparation'],
    ['--source-map             Embed a composed map for a native stylesheet syntax', 'native binary CLI source-map help'],
  ]) {
    requireText(binaryCli, needle, label)
  }
  requireText(
    nodeWrapperTests,
    "'--source-map',",
    'native JavaScript wrapper source-map forwarding',
  )
  for (const pendingResultSurface of [
    'compiled.edges(',
  ]) {
    if (nativeApi.includes(pendingResultSurface)) {
      fail('native Zig API crossed the pending edge-fact route')
    }
  }
  const nativeWatchState = nativeApi.match(
    /const WatchState = struct \{[\s\S]*?\n\};\n\nfn contentHash/,
  )
  if (!nativeWatchState) fail('native Zig API opaque watch state is missing')
  requireText(
    nativeWatchState[0],
    'const dependencies = compiled.dependencies();',
    'native Zig API opaque watch dependency snapshot',
  )
  requireText(
    nativeApi,
    'const bytes = dependencySourceBytes(compiled, dependency.url)',
    'native Zig API watch snapshot compiler-owned bytes',
  )
  requireText(
    nativeWatchState[0],
    'var loaded = session.load(item.url,',
    'native Zig API confined watch polling',
  )
  requireText(
    nativeWatchState[0],
    'var loaded = session.load(self.entry_url,',
    'native Zig API confined watch entry reload',
  )
  if (nativeWatchState[0].includes('readFileAlloc(')) {
    fail('native Zig API watch polling bypassed the confined resolver')
  }
  requireText(
    nativeApi,
    'pub fn pollWatchInputs(self: *CompileResult)',
    'native Zig API opaque watch polling',
  )
  requireText(
    nativeApi,
    'pub fn readWatchInput(',
    'native Zig API confined watch entry surface',
  )
  for (const [needle, label] of [
    ['diagnostics: []const Diagnostic,', 'owned diagnostic result field'],
    ['dependencies: []const Dependency,', 'owned dependency result field'],
    ['native_compiler.compileReported(', 'structured compiler outcome'],
    ['compiled.nativeDiagnostics(),', 'diagnostic promotion'],
    ['cloneDependencies(allocator, compiled.dependencies())', 'dependency promotion'],
    ['releaseDiagnostics(allocator, self.diagnostics);', 'diagnostic teardown'],
    ['releaseDependencies(allocator, self.dependencies);', 'dependency teardown'],
  ]) {
    requireText(nativeApi, needle, `native Zig API ${label}`)
  }
  requireText(
    sassEvaluator,
    'parsed.url,\n            &configuration,\n            .forward,\n            node.span,',
    'native Sass forward dependency kind',
  )
  requireText(
    sassEvaluator,
    'candidates,\n                dependency_kind,\n                "native Sass local module URL is ambiguous"',
    'native Sass delegated dependency kind',
  )
  for (const pendingPublicResultSurface of [
    'pub fn edges(',
  ]) {
    if (nativeApi.includes(pendingPublicResultSurface)) {
      fail('native Zig API exposed the pending edge-fact route')
    }
  }
  requireText(
    binaryCli,
    'const native_api = zigcss.experimental_native;',
    'native binary CLI pre-graduation bridge',
  )
  requireText(
    binaryCli,
    'var result = native_api.compile(',
    'native binary CLI shared API dispatch',
  )
  requireText(
    binaryCli,
    '"multiple inputs require --output-dir"',
    'native binary CLI explicit batch admission boundary',
  )
  requireText(
    binaryCli,
    'const stdin_root = if (isStdioPath(input_file))',
    'native binary CLI confined stdin root',
  )
  requireText(
    binaryCli,
    'nativeStdinEntryName(syntax)',
    'native binary CLI synthetic stdin identity',
  )
  requireText(
    binaryCli,
    '"optimize and profile are unavailable for native stylesheet syntax"',
    'native binary CLI pending execution-mode boundary',
  )
  requireText(
    binaryCli,
    'Watch one input and its confined local imports',
    'native binary CLI watch help boundary',
  )
  requireText(
    binaryCli,
    'Select css (default), scss, sass, less, or stylus',
    'native binary CLI finite syntax help boundary',
  )
  requireText(
    binaryCli,
    'printNativeDiagnostics(result.diagnostics);',
    'native binary CLI structured diagnostic rendering',
  )
  const nativeWatch = binaryCli.match(
    /fn watchNativeFile\([\s\S]*?\n}\n\nfn compileTask/,
  )
  if (!nativeWatch) fail('native binary CLI watch route is missing')
  requireText(
    nativeWatch[0],
    'compileNativeLoadedSource(',
    'native binary CLI watch loaded-source dispatch',
  )
  requireText(
    nativeWatch[0],
    'try result.pollWatchInputs()',
    'native binary CLI watch opaque dependency polling',
  )
  requireText(
    nativeWatch[0],
    'result.readWatchInput(allocator)',
    'native binary CLI retained entry authority',
  )
  requireText(
    nativeWatch[0],
    'try commitNativeResult(',
    'native binary CLI watch atomic result commit',
  )
  requireText(
    nativeWatch[0],
    '&next_result,\n                source_map,',
    'native binary CLI watch composed map commit',
  )
  if (nativeWatch[0].includes('compileNativeSource(') ||
      nativeWatch[0].includes('std.Thread.spawn') ||
      nativeWatch[0].includes('compileFilesParallel(')) {
    fail('native binary CLI watch crossed a duplicate-read or pending parallel boundary')
  }
  const nativeBatch = binaryCli.match(
    /fn compileNativeBatch\([\s\S]*?\n}\n\nfn experimentalFormatName/,
  )
  if (!nativeBatch) fail('native binary CLI batch route is missing')
  requireText(
    nativeBatch[0],
    'try compileNativeFilesParallel(allocator, tasks.items);',
    'native binary CLI bounded parallel dispatch',
  )
  requireText(
    nativeBatch[0],
    'try findOutputCollision(allocator, input_files, planned_outputs)',
    'native binary CLI batch collision planning',
  )
  const nativeParallel = binaryCli.match(
    /fn compileNativeFilesParallel\([\s\S]*?\n}\n\nconst CompileError/,
  )
  if (!nativeParallel) fail('native binary CLI parallel route is missing')
  const nativeTask = binaryCli.match(
    /const NativeBatchTask = struct \{[\s\S]*?\n};\n\nfn setTaskError/,
  )
  if (!nativeTask) fail('native binary CLI parallel task ownership is missing')
  for (const [needle, label] of [
    ['allocator_state: NativeBatchTaskAllocator = .{},', 'allocator state'],
    ['const allocator_check = self.allocator_state.deinit();', 'allocator teardown'],
    ['std.debug.assert(allocator_check == .ok);', 'allocator leak check'],
  ]) {
    requireText(nativeTask[0], needle, `native binary CLI parallel ${label}`)
  }
  for (const [needle, label] of [
    ['const max_batch_workers = 8;', 'worker terminal'],
    ['const NativeBatchTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });', 'independent task allocator'],
    ['const NativeBatchWorkQueue = struct', 'bounded work queue'],
    ['task.result = compileNativeSourceQuiet(', 'quiet native task dispatch'],
    ['queue.cancelForFailure();', 'failure cancellation'],
    ['const worker_count = batchWorkerCount(tasks.len, cpu_count);', 'worker cap'],
    ['std.Thread.spawn(.{}, nativeBatchWorker, .{&queue})', 'thread spawn'],
    ['for (threads[0..spawned]) |thread| thread.join();', 'thread join'],
    ['queue.markPendingCancelled();', 'pending cancellation'],
    ['if (queue.failed)', 'transaction failure'],
    ['task.rendered_css orelse task.result.?.css,', 'ordered composed-map commit'],
  ]) {
    requireText(binaryCli, needle, `native binary CLI parallel ${label}`)
  }
  const joinIndex = nativeParallel[0].indexOf('for (threads[0..spawned]) |thread| thread.join();')
  const writeIndex = nativeParallel[0].indexOf('task.rendered_css orelse task.result.?.css,')
  if (joinIndex < 0 || writeIndex < 0 || joinIndex > writeIndex) {
    fail('native binary CLI parallel route writes before every worker joins')
  }
  if (binaryCli.includes('std.process.Child')) {
    fail('native binary CLI introduced a provider child-process path')
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
    if (relativePath === 'src/native_api.zig') continue
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
    websiteSources = Object.fromEntries(websiteSourcePaths.map(relativePath => [
      relativePath,
      fs.readFileSync(repositoryFile(relativePath), 'utf8'),
    ])),
    formatExamples = loadJson('docs/src/data/format-examples.json'),
    siteExamplesTests = fs.readFileSync(
      repositoryFile('tests/preprocessors/product/site-examples.test.mjs'),
      'utf8',
    ),
    documentationPolicy = loadJson('docs/documentation-validation.json'),
    nativeApiExample = fs.readFileSync(repositoryFile('examples/native_api.zig'), 'utf8'),
    nativeExampleSources = Object.fromEntries(expectedNativeExampleRows.map(row => [
      row.path,
      fs.readFileSync(repositoryFile(row.path), 'utf8'),
    ])),
    buildGuide = fs.readFileSync(
      repositoryFile('docs/src/content/docs/guide/build-from-source.md'),
      'utf8',
    ),
    formatGuide = fs.readFileSync(
      repositoryFile('docs/src/content/docs/guide/format-compatibility.md'),
      'utf8',
    ),
    recoveryGuide = fs.readFileSync(
      repositoryFile('docs/src/content/docs/guide/recovery-cli.md'),
      'utf8',
    ),
    statusGuide = fs.readFileSync(
      repositoryFile('docs/src/content/docs/guide/status.md'),
      'utf8',
    ),
    formatMatrix = loadJson('tests/formats/matrix.json'),
    capabilityMetadata = loadJson('docs/src/data/capabilities.json'),
    changelog = fs.readFileSync(repositoryFile('CHANGELOG.md'), 'utf8'),
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
    compilerTests = fs.readFileSync(
      repositoryFile('tests/native-preprocessor/compiler.zig'),
      'utf8',
    ),
    cliTests = fs.readFileSync(
      repositoryFile('tests/cli/native_cli.zig'),
      'utf8',
    ),
    zigApiTests = fs.readFileSync(
      repositoryFile('tests/public-api/native_consumer.zig'),
      'utf8',
    ),
    nodeWrapperSource = fs.readFileSync(repositoryFile('index.js'), 'utf8'),
    nodeWrapperTests = fs.readFileSync(
      repositoryFile('scripts/verify-node-wrapper.test.mjs'),
      'utf8',
    ),
    packageTests = fs.readFileSync(
      repositoryFile('scripts/validate-preprocessor-package.test.mjs'),
      'utf8',
    ),
    releaseSmokeSource = fs.readFileSync(
      repositoryFile('scripts/smoke-release-artifact.mjs'),
      'utf8',
    ),
    releaseSmokeTests = fs.readFileSync(
      repositoryFile('scripts/smoke-release-artifact.test.mjs'),
      'utf8',
    ),
    nativePackageEvidenceTests = fs.readFileSync(
      repositoryFile('scripts/validate-native-package-evidence.test.mjs'),
      'utf8',
    ),
    releaseMetadataTests = fs.readFileSync(
      repositoryFile('scripts/generate-release-metadata.test.mjs'),
      'utf8',
    ),
    releaseConsumerTests = fs.readFileSync(
      repositoryFile('scripts/verify-release-consumers.test.mjs'),
      'utf8',
    ),
    releaseSmokePreloadSource = fs.readFileSync(
      repositoryFile('scripts/release-smoke-preload.cjs'),
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
      'productRouting',
      'packageMigration',
      'capabilityGraduation',
      'releaseGraduation',
      'foundations',
      'implementations',
      'adapters',
    ],
    'root',
  )
  if (contract.schemaVersion !== 9) fail('schemaVersion must be 9')
  if (contract.state !== 'native-differential') {
    fail('state must remain native-differential until the NATIVE-009 release gate closes')
  }
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
  validateProductRouting(
    contract.productRouting,
    plan,
    compilerTests,
    zigApiTests,
    cliTests,
    nodeWrapperSource,
    nodeWrapperTests,
    sassConformanceTests,
    lessConformanceTests,
    stylusConformanceTests,
  )
  validatePackageMigration(
    contract.packageMigration,
    plan,
    manifest,
    packageTests,
    nodeWrapperSource,
    nodeWrapperTests,
    releaseSmokeSource,
    releaseSmokeTests,
    nativePackageEvidenceTests,
    releaseMetadataTests,
    releaseConsumerTests,
    releaseSmokePreloadSource,
    productionSources,
  )
  validateCapabilityGraduation(
    contract.capabilityGraduation,
    productionSources,
    cliTests,
    plan,
    readme,
    websiteSources,
    formatExamples,
    siteExamplesTests,
    buildFile,
    documentationPolicy,
    nativeApiExample,
    nativeExampleSources,
    buildGuide,
    formatGuide,
    recoveryGuide,
    statusGuide,
    formatMatrix,
    capabilityMetadata,
    changelog,
  )
  validateReleaseGraduation(
    contract.releaseGraduation,
    plan,
    buildWorkflow,
    releaseWorkflow,
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
  if (!same(manifest.dependencies ?? {}, {})) {
    fail('native package production dependency graph is not empty')
  }
  if (manifest.optionalDependencies !== undefined && Object.keys(manifest.optionalDependencies).length !== 0) {
    fail('current package has unexpected optionalDependencies')
  }
  const referenceDependencies = Object.fromEntries(
    Object.keys(expectedReferenceDevelopmentDependencies).map(name => [
      name,
      manifest.devDependencies?.[name],
    ]),
  )
  if (!same(referenceDependencies, expectedReferenceDevelopmentDependencies)) {
    fail('development-only canonical reference dependency graph drifted')
  }
  if (manifest.scripts?.['check:native-contract'] !== 'node scripts/validate-native-contract.mjs --check') {
    fail('package script check:native-contract is missing or changed')
  }
  if (manifest.scripts?.['test:native-contract'] !== 'node --test scripts/validate-native-contract.test.mjs') {
    fail('package script test:native-contract is missing or changed')
  }
  if (manifest.scripts?.['test:native-package-evidence'] !== 'node --test scripts/validate-native-package-evidence.test.mjs') {
    fail('package script test:native-package-evidence is missing or changed')
  }
  if (manifest.scripts?.['test:workflows'] !== 'node --test scripts/run-zig-test-suite.test.mjs scripts/setup-zig-action.test.mjs scripts/validate-workflows.test.mjs') {
    fail('package script test:workflows must retain the Zig suite runner contract')
  }

  for (const [index, foundation] of contract.foundations.entries()) {
    validateFoundation(foundation, index, plan)
  }
  for (const [index, adapter] of contract.adapters.entries()) validateAdapter(adapter, index, plan)
  for (const [index, implementation] of contract.implementations.entries()) {
    validateImplementation(implementation, index, contract, plan)
  }
  validateInternalReachability(
    contract.implementations,
    buildFile,
    productionSources,
    nodeWrapperTests,
  )
  validateNativeImportClosure(contract, productionSources)

  requireText(plan, 'Plan version: 1.5', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## Milestone 10: Self-contained native stylesheet frontends', 'DEVELOPMENT_PLAN.md')
  requireText(plan, '## 17. First self-contained-native autonomous sequence', 'DEVELOPMENT_PLAN.md')
  requireText(decision, '- Status: Accepted', 'ADR-013')
  requireText(decision, 'zero `dependencies` and zero `optionalDependencies`', 'ADR-013')
  requireText(decision, 'All tag-triggered releases are fail-closed', 'ADR-013')
  requireText(decision, 'first fully graduated native candidate', 'ADR-013')
  requireText(readme, 'Native dependency-free migration', 'README.md')

  const buildGate = 'npm run test:native-contract && npm run test:native-package-evidence && npm run check:native-contract'
  requireText(buildWorkflow, buildGate, 'build workflow')
  requireText(buildWorkflow, 'npm run test:node-wrapper', 'native JavaScript wrapper workflow')
  requireText(buildWorkflow, 'node scripts/run-zig-test-suite.mjs --mode Debug', 'build workflow')
  requireText(buildWorkflow, 'node scripts/run-zig-test-suite.mjs --mode ReleaseSafe', 'build workflow')
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
  const release = contract.releaseGraduation
  const expectedGates = new Map(expectedReleaseGraduation.gates.map(gate => [gate.id, gate]))
  const actualGates = Array.isArray(release?.gates)
    ? new Map(release.gates.map(gate => [gate.id, gate]))
    : new Map()
  const preTagComplete = expectedReleaseGraduation.terminalContract.preTagSurfaces.every(id => {
    const actual = actualGates.get(id)
    const expected = expectedGates.get(id)
    return actual?.state === 'verified'
      && expected !== undefined
      && same(actual.evidenceRequirements, expected.evidenceRequirements)
  })
  const publication = actualGates.get('tag-workflow-publication')
  const publicationStateValid = publication !== undefined
    && (publication.state === 'pending' || publication.state === 'verified')
    && same(
      publication.evidenceRequirements,
      expectedGates.get('tag-workflow-publication').evidenceRequirements,
    )
  const adaptersGraduated = Array.isArray(contract.adapters)
    && contract.adapters.length === 5
    && contract.adapters.every(adapter => adapter.current === 'native-graduated')
  const gateInventoryExact = Array.isArray(release?.gates)
    && release.gates.length === expectedReleaseGraduation.gates.length
    && same(
      release.gates.map(gate => gate.id),
      expectedReleaseGraduation.gates.map(gate => gate.id),
    )
  const releaseEvidenceComplete = contract.state === 'native-graduated'
    && contract.packageMigration?.packageState === 'verified'
    && contract.capabilityGraduation?.packageState === 'verified'
    && release?.ownerPackage === 'NATIVE-009'
    && release.releaseGapFamily === 'native-release-evidence'
    && (release.state === 'candidate-ready' || release.state === 'closed')
    && (release.packageState === 'in-progress' || release.packageState === 'verified')
    && release.candidateVersion === contract.nativeReleaseVersion
    && release.candidateVersion !== contract.referenceCandidate
    && /^0\.6\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(release.candidateVersion)
    && release.candidateTag === tag
    && same(release.terminalContract, expectedReleaseGraduation.terminalContract)
    && actualGates.size === expectedGates.size
    && gateInventoryExact
    && preTagComplete
    && publicationStateValid
    && adaptersGraduated
  if (!releaseEvidenceComplete) {
    fail(`release ${tag} rejected: native release evidence is incomplete`)
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
