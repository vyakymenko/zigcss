#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { nativeTargetContract } from './native-target-contract.mjs'
import {
  manifestPackageFiles,
  packageBins,
  packageExports,
  packageTypesVersions,
} from './validate-preprocessor-package.mjs'
import {
  compareReleaseVersionPrecedence,
  parseReleaseVersion,
} from './validate-release-version.mjs'
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
    version: '4.9.0',
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
    developmentVersion: '4.9.0',
    baselineVersion: '4.6.7',
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
      'programmatic-node-api',
      'files-and-stdin',
      'batch',
      'watch',
      'parallel',
      'diagnostics-and-dependencies',
      'source-maps',
      'verified-optimizer',
      'verified-target-prefix',
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
      id: 'programmatic-node-api',
      releaseGapFamily: 'native-programmatic-node-api-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'programmatic Node API exposes matching CommonJS and real ESM surfaces',
        'binary hidden Node route dispatches one typed bounded frame',
        'detectSyntax owns the closed five-syntax extension set',
        'string API routes all five syntaxes through one exact framed request',
        'file APIs infer all five syntaxes and default roots to the entry directory',
        'request normalization carries maps, dependencies, optimizer, prefix query, and roots',
        'source parents and explicit roots are canonical across directory symlinks',
        'validation is closed and rejects unsafe combinations before process launch',
        'compile failures expose immutable diagnostics and never partial CSS',
        'malformed, truncated, mismatched, oversized, and invalid typed responses fail closed',
        'async API enforces timeout and AbortSignal termination',
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
        'binary CLI routes stable CSS source maps through files stdin and parallel batches',
        'binary CLI stable CSS watch atomically replaces CSS and its inline source map',
        'javascript wrapper routes the finite native syntax set through the installed binary',
      ]),
    }),
    Object.freeze({
      id: 'verified-optimizer',
      releaseGapFamily: 'native-verified-optimizer-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'native compiler applies the closed optimizer after every private frontend',
        'external Zig API applies the verified optimizer to the finite native syntax set',
        'binary CLI applies the verified optimizer to native files stdin and parallel batches',
        'binary CLI native optimizer watch commits only byte-stable output',
        'binary CLI rejects native maps plus optimizer before reading any syntax',
        'javascript wrapper forwards native optimizer requests unchanged',
      ]),
    }),
    Object.freeze({
      id: 'verified-target-prefix',
      releaseGapFamily: 'native-verified-target-prefix-routing',
      state: 'verified',
      evidenceTests: Object.freeze([
        'native compiler applies verified target prefixing after every private frontend',
        'external Zig API applies verified target prefixing to the finite native syntax set',
        'binary CLI applies verified target prefixing to native files stdin maps optimize and parallel batches',
        'binary CLI native target prefix watch retains output recovers and shares one immutable query',
        'javascript wrapper forwards verified target prefix requests unchanged',
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
        'native npm archive includes only the bounded runtime declaration metadata and trust inventory',
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
        'npm package binds every native archive to one exact version and digest inventory',
        'npm installer rejects same-origin checksum substitution before downloading an archive',
        'npm installer reads its trust manifest only from a bounded regular stable UTF-8 file',
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

export const expectedReleaseGraduation = Object.freeze({
  ownerPackage: 'NATIVE-009',
  releaseGapFamily: 'native-release-evidence',
  state: 'closed',
  packageState: 'verified',
  candidateVersion: '0.6.0-rc.2',
  candidateTag: 'v0.6.0-rc.2',
  candidateSelection: Object.freeze({
    selectedOn: '2026-08-13',
    localTagStateAtSelection: 'absent',
    githubRepository: 'vyakymenko/zigcss',
    githubTagStateAtSelection: 'absent',
    npmPackage: 'zigcss',
    npmVersionStateAtSelection: 'absent',
    observedPublishedNpmVersions: Object.freeze(['0.2.0', '0.2.1', '0.3.0', '0.4.0-rc.3']),
  }),
  publicationEvidence: Object.freeze({
    tagCommit: 'b63e190f7edeccd829abe34bfb96d9e1a8a320e2',
    workflowRunId: 31694233958,
    workflowAttempt: 1,
    workflowConclusion: 'success',
    workflowCompletedAt: '2026-08-13T11:13:44Z',
    githubReleaseId: 369856953,
    githubPrerelease: true,
    githubDraft: false,
    githubImmutable: false,
    githubPublishedAt: '2026-08-13T11:13:25Z',
    githubAssetCount: 25,
    assetsPerTarget: 5,
    npmVersion: '0.6.0-rc.2',
    npmDistTag: 'next',
    npmLatest: '0.3.0',
    npmFileCount: 7,
    npmIntegrity: 'sha512-Vm2rXUNvfDADtAyuuMeLwKZh+SWqWKJp1nwNMTi/b1RCAMGFO7wAPCAAQlfL1YBZ59WTb6+kBFnA+Gd6Ckjuyw==',
    npmProvenancePredicateType: 'https://slsa.dev/provenance/v1',
  }),
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
        'candidate version and tag were bound to the release-ready interlock before the closed publication',
      ]),
    }),
    Object.freeze({
      id: 'immutable-candidate',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'one unused 0.6.x native version and matching protected historical v tag are selected',
        'the provider-backed 0.5.0-rc.1 reference candidate remains ineligible',
      ]),
    }),
    Object.freeze({
      id: 'local-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'Debug ReleaseSafe differential fuzz allocation resource documentation package and audit gates pass on the candidate',
      ]),
    }),
    Object.freeze({
      id: 'hosted-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'one automatic Build on the exact integrated candidate passes Test Suite five targets and aggregate evidence within runtime budgets',
      ]),
    }),
    Object.freeze({
      id: 'release-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'version native package workflow and publication preflight policies pass before npm authentication',
      ]),
    }),
    Object.freeze({
      id: 'artifact-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'five exact native archives checksums SPDX inventories and direct smokes pass',
      ]),
    }),
    Object.freeze({
      id: 'provenance-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'five exact archives and SBOMs are bound by verified GitHub attestations',
      ]),
    }),
    Object.freeze({
      id: 'consumer-validation',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'direct archives and offline installed packages compile all five syntaxes on all five targets',
      ]),
    }),
    Object.freeze({
      id: 'origin-main-integration',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'the exact candidate commit is integrated to origin main before tag creation',
      ]),
    }),
    Object.freeze({
      id: 'tag-workflow-publication',
      state: 'verified',
      evidenceRequirements: Object.freeze([
        'one protected historical tag produced one verified GitHub prerelease with five native archives and 25 release assets whose API now reads immutable=false',
        'npm 0.6.0-rc.2 is published on next with provenance while latest remains stable',
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
  less: 'Less 4.9.0 development oracle over frozen 4.6.7 baseline',
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
  less: '4.9.0',
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
      'verified-fixed-point-optimizer',
      'all-native-syntax-optimizer',
      'optimizer-map-fail-fast',
      'optimized-watch-and-batch',
      'verified-target-prefix',
      'strict-explicit-target-query',
      'all-native-syntax-prefix',
      'prefix-map-and-optimizer-composition',
      'prefixed-watch-and-batch',
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
  requireText(home, 'STABLE RELEASE · VERIFIED', 'website stable publication boundary')
  requireText(home, 'The providers are ', 'website development-oracle heading')
  requireText(home, 'REL-010 · 0.6.0 · 15 attested subjects + 10 bundles · npm latest', 'website stable publication evidence')
  requireText(home, 'CLI · JS wrapper · Zig API', 'website thin wrapper interface claim')
  requireText(home, 'Next.js · Turbopack + Webpack', 'website pinned Next.js host proof inventory')
  requireText(
    gettingStarted,
    'The source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig frontends and one strict output boundary.',
    'website native getting-started boundary',
  )
  requireText(
    gettingStarted,
    'Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 remain development-only reference oracles; Less forward-checks the frozen 4.6.7 native baseline, and none of them runs during compilation.',
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
    'The table mixes explicitly labeled published-stable rows with current-source evidence. REL-010 promotes only the stable 0.6.0 rows; rows whose contract says current, source-checkout, or Unreleased remain Unreleased even after their gates pass.',
    'website published compatibility boundary',
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
    ['less', 'Less 4.9.0'],
    ['stylus', 'Stylus 0.64.0'],
  ]) {
    const example = formatExamples.find(row => row.id === id)
    requireText(example?.note ?? '', 'development-only', `website ${id} lab oracle role`)
    requireText(example?.note ?? '', oracle, `website ${id} lab oracle identity`)
  }
  requireText(
    formatExamples.find(row => row.id === 'less')?.note ?? '',
    'frozen 4.6.7 conformance baseline',
    'website Less lab frozen baseline identity',
  )

  for (const [needle, label] of [
    ["import { spawnSync } from 'node:child_process'", 'website lab native process harness'],
    [
      "spawnSync(binaryPath, ['-', '--syntax', example.id, '--minify'],",
      'website lab native executable evidence',
    ],
    ['assert.equal(result.status, 0', 'website lab native exit evidence'],
    ['assert.equal(result.stdout, example.output, example.id)', 'website lab exact output evidence'],
    ["const activeVersion = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()", 'website prerelease version identity'],
    ['const prereleaseNotice = `Warning: ZigCSS ${activeVersion} is an experimental release candidate; do not use it for production CSS.\\n`', 'website prerelease warning identity'],
    ['assert.equal(result.stderr, prereleaseNotice)', 'website prerelease warning boundary'],
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
  buildWorkflow,
) {
  if (!same(graduation, expectedCapabilityGraduation)) {
    fail('capability graduation contract drifted')
  }
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
    '--source-map             Embed a deterministic inline source map',
    'stable native source-map help',
  )
  requireText(
    help,
    '--depfile <path>         Write one bounded Make/Ninja dependency file',
    'stable native depfile help',
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
  requireText(evidence, '--source-map             Embed a deterministic inline source map', 'stable source-map help evidence')
  requireText(evidence, '--depfile <path>         Write one bounded Make/Ninja dependency file', 'stable depfile help evidence')

  for (const [needle, label] of [
    [
      'The current source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths.',
      'README native five-language source snapshot',
    ],
    [
      'Dart Sass 1.101.0 and Stylus 0.64.0 remain exact development-only reference oracles.',
      'README development-only oracle boundary',
    ],
    [
      'Less 4.9.0 is the current development oracle over the frozen 4.6.7 native conformance baseline; advancing that forward oracle does not regraduate or rewrite the published native behavior.',
      'README Less forward-oracle boundary',
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
      '| SCSS (`.scss`) | Native Sass-family parser/evaluator | `native-graduated` |',
      'README SCSS native-graduated row',
    ],
    [
      '| Sass (`.sass`) | Native Sass-family parser/evaluator | `native-graduated` |',
      'README Sass native-graduated row',
    ],
    [
      '| Less (`.less`) | Native Less parser/evaluator | `native-graduated` |',
      'README Less native-graduated row',
    ],
    [
      '| Stylus (`.styl`) | Native Stylus parser/evaluator | `native-graduated` |',
      'README Stylus native-graduated row',
    ],
    [
      'Arbitrary Sass plugins, custom functions and importers, Less JavaScript and plugins, Stylus plugins and evaluator hooks, and executable project code remain outside the native product contract.',
      'README native plugin boundary',
    ],
    [
      '`--autoprefix` and `--browsers` require each other.',
      'README explicit target-query pairing',
    ],
    [
      'The pass covers a reviewed eight-feature subset rather than general autoprefixing.',
      'README bounded target-prefix claim',
    ],
    [
      'The package JavaScript wrapper only locates and invokes the installed native binary; it does not host language semantics.',
      'README thin JavaScript wrapper boundary',
    ],
    [
      'In a direct checkout with regular `build.zig` and `src/node_protocol.zig` markers, it accepts only a regular, non-symlink `zig-out/bin/zigcss` whose real path stays inside that checkout',
      'README confined source-checkout JavaScript wrapper boundary',
    ],
    [
      'The current `Unreleased` source package also exports a typed programmatic Node.js API from its package root for both CommonJS and real ESM consumers.',
      'README programmatic Node API module boundary',
    ],
    [
      '`compile`, `compileSync`, `compileFile`, `compileFileSync`, `detectSyntax`, and `ZigCssCompileError`',
      'README programmatic Node API export inventory',
    ],
    [
      'The API deliberately provides no watch mode, incremental cache, plugin execution, provider fallback, or private transport access.',
      'README programmatic Node API negative boundary',
    ],
    [
      'The current `Unreleased` source package adds explicit, typed adapter subpaths on top of the programmatic compiler.',
      'README explicit build-tool adapter boundary',
    ],
    [
      'preserve authored CSS imports for the downstream CSS layer',
      'README downstream CSS ownership boundary',
    ],
    [
      'reuses only `zigcss/webpack` for one global `app/styles.scss` entry',
      'README bounded Next.js Turbopack reuse boundary',
    ],
    [
      'The separate `next build --webpack` proof uses one path-confined `enforce: \'pre\'` rule',
      'README bounded Next.js Webpack reuse boundary',
    ],
    [
      'Next.js/Webpack does not preserve the original ZigCSS source-map chain in the final stylesheet, so no source-map delivery claim is made.',
      'README Next.js Webpack source-map boundary',
    ],
    [
      'routes one external `.module.scss` file through `zigcss/vite`',
      'README bounded SvelteKit Vite reuse boundary',
    ],
    [
      'No PostCSS adapter is shipped',
      'README PostCSS parser-order boundary',
    ],
    ['`nativeReleaseReady: true`', 'README release-ready native interlock'],
    [
      'GitHub prerelease and npm `next` publication are verified',
      'README published native release terminal',
    ],
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
    ['zigcss.prefixing.target_query.parse(', 'native Zig API example strict target query'],
    ['.prefix = true', 'native Zig API example verified target prefix'],
    ['.targets = &targets', 'native Zig API example borrowed target query'],
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
        row.compatibility !== 'NativeGraduated' || row.implementation !== 'NativeFrontend' ||
        row.strategy !== 'native-reimplementation' || row.ownerPackages.at(-1) !== 'NATIVE-009') {
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
    if (row?.status !== 'Native graduated verified' || row.statusKind !== 'verified') {
      fail(`capability metadata native status drifted for ${id}`)
    }
    requireText(row.behavior, '`zigcss.experimental_native`', `capability metadata native Zig API ${id}`)
    requireText(row.behavior, oracle, `capability metadata development oracle ${id}`)
    requireText(row.behavior, 'does not run during compilation', `capability metadata oracle execution boundary ${id}`)
    if (!row.evidence.includes('release-version')) {
      fail(`capability metadata native release evidence is missing for ${id}`)
    }
  }

  const releaseArtifacts = capabilities.get('release-artifacts')
  if (releaseArtifacts?.status !== 'Experimental, published and native-smoke-gated') {
    fail('capability metadata published release status drifted')
  }
  requireText(
    releaseArtifacts.behavior,
    'Protected historical tag `v0.6.0-rc.2` produced one verified GitHub prerelease with five architecture-matched archives and 25 exact assets; that release predates Immutable Releases and reads back `immutable: false`',
    'capability metadata published release terminal',
  )
  const nodeApi = capabilities.get('node-api')
  if (nodeApi?.status !== 'Experimental, package-tested' || nodeApi.statusKind !== 'experimental') {
    fail('capability metadata programmatic Node API status drifted')
  }
  for (const needle of [
    'CommonJS and ESM',
    '`compile`',
    '`compileSync`',
    '`compileFile`',
    '`compileFileSync`',
    '`detectSyntax`',
    '`ZigCssCompileError`',
    'all five syntaxes',
    'canonicalizes source/root paths',
    'parsed maps',
    'optimizer',
    'target-prefix',
    '`AbortSignal`',
    'zero production dependencies',
    'strict TypeScript 7.0.2 consumer',
    'lifecycle-disabled offline local-tarball matrix',
    "npm, pnpm 11.25.0, Yarn Classic 1.22.22, Yarn Modern 4.9.4 in both `node-modules` and default Plug'n'Play modes, and Bun 1.4.0",
    'All six execution variants',
    'The five `node_modules` variants use ordinary CommonJS, ESM, and declaration package resolution',
    "The default-PnP route uses Yarn's loader for CommonJS and ESM export resolution",
    'verifies exact import/require declaration bytes',
    'path-maps those files for a condition-specific strict compile',
    'exact unpatched TypeScript 7.0.2 without a Yarn SDK or patch',
    '`TS2307` for no-paths PnP package resolution',
    'native TypeScript PnP resolution is not claimed',
    "[Yarn's official SDK guidance](https://yarnpkg.com/getting-started/editor-sdks)",
    '`preferUnplugged`',
    'no `node_modules`',
    'confined Yarn and Corepack state',
    'release-independent local-fixture recovery',
  ]) {
    requireText(nodeApi.behavior, needle, 'capability metadata programmatic Node API')
  }
  if (!same(nodeApi.evidence, ['node-api', 'preprocessor-product', 'preprocessor-package', 'package-managers', 'typescript-surface'])) {
    fail('capability metadata programmatic Node API evidence drifted')
  }
  const buildToolAdapters = capabilities.get('alternate-ecosystem-formats')
  if (
    buildToolAdapters?.status !== 'Experimental, adapter-tested' ||
    buildToolAdapters.statusKind !== 'experimental'
  ) {
    fail('capability metadata build-tool adapter status drifted')
  }
  for (const needle of [
    'Vite, Rollup, esbuild, and Bun plugins',
    'Webpack/Rspack raw loader',
    'Deterministic protocol-fixture tests',
    'After the native Debug suite builds `zig-out/bin/zigcss`',
    'real Vite, Rollup, esbuild, pinned Bun 1.4.0, Webpack 5.110.2, and Rspack 2.2.2 builds all compile SCSS through that exact current-checkout binary',
    'Bun deliberately makes no native-import watch claim',
    'pinned Next.js 16.3.4 Turbopack build reuses only `zigcss/webpack`',
    'Next.js 16.2+ module types are required',
    'does not claim CSS Modules, indented Sass, Less, Stylus, arbitrary SCSS globs',
    'a `zigcss/turbopack` export, a general Turbopack plugin, or wider framework support',
    'pinned SvelteKit 2.70.3, Svelte 5.57.0, and Vite 8.2.2 source-checkout gate',
    'external `.module.scss` file through `zigcss/vite`',
    'does not claim embedded `<style lang="scss">` blocks, Svelte preprocessors, framework HMR or watch invalidation',
    'real Parcel 2.16.4 local-transformer example',
    "Parcel's naming rule prevents a `zigcss/parcel` export",
    'Exact Next.js Webpack, Astro, and Nuxt host proofs are tracked as separate current-source capability rows',
    'TypeScript 7.0.2 strictly compiles every public adapter subpath',
    'Bazel, Nx, other framework adapters',
  ]) {
    requireText(buildToolAdapters.behavior, needle, 'capability metadata build-tool adapters')
  }
  if (!same(buildToolAdapters.evidence, ['bundler-adapters', 'turbopack-example', 'sveltekit-example', 'parcel-example', 'node-api', 'typescript-surface', 'documentation'])) {
    fail('capability metadata build-tool adapter evidence drifted')
  }
  const nextWebpackHost = capabilities.get('next-webpack-host-example')
  if (nextWebpackHost?.status !== 'Experimental, pinned host-tested' || nextWebpackHost.statusKind !== 'experimental') {
    fail('capability metadata Next.js Webpack host status drifted')
  }
  for (const needle of [
    'Next.js 16.3.4 current-source Webpack gate',
    '`zigcss/webpack`',
    "exact-project-file `enforce: 'pre'` rule",
    'exact Sass 1.101.0 remains only the downstream parser',
    'repeats `npm ci` offline',
    'blocking public Node network entry points',
    'exact Node 24.20.0 LTS CI host',
    'canonical staged ZigCSS `--internal-node-v1` invocation',
    'dependency-only warm rebuild',
    'unchanged persistent-cache hit with zero native invocations',
    'not an OS sandbox',
    'invokes native ZigCSS again',
    'source-map delivery is not claimed',
    'not stable 0.6.0 adapter delivery',
    'development HMR or watch invalidation',
    'a `zigcss/next` export',
    'other Next.js/Webpack versions',
  ]) requireText(nextWebpackHost.behavior, needle, 'capability metadata Next.js Webpack host')
  if (!same(nextWebpackHost.evidence, ['next-webpack-example', 'bundler-adapters', 'node-api', 'documentation'])) {
    fail('capability metadata Next.js Webpack host evidence drifted')
  }
  const astroHost = capabilities.get('astro-host-example')
  if (astroHost?.status !== 'Experimental, pinned host-tested' || astroHost.statusKind !== 'experimental') {
    fail('capability metadata Astro host status drifted')
  }
  for (const needle of [
    'Astro 7.2.10 current-source gate',
    '`zigcss/vite`',
    'cached-offline, deny-network static production build',
    'same scoped binding in rendered HTML and emitted JavaScript',
    'one native Sass partial',
    'one fingerprinted SVG asset',
    'exact composed source-map content',
    'not stable 0.6.0 adapter delivery',
    '`zigcss/astro` export',
  ]) requireText(astroHost.behavior, needle, 'capability metadata Astro host')
  if (!same(astroHost.evidence, ['astro-example', 'bundler-adapters', 'node-api', 'documentation'])) {
    fail('capability metadata Astro host evidence drifted')
  }
  const nuxtHost = capabilities.get('nuxt-host-example')
  if (nuxtHost?.status !== 'Experimental, pinned host-tested' || nuxtHost.statusKind !== 'experimental') {
    fail('capability metadata Nuxt host status drifted')
  }
  for (const needle of [
    'Nuxt 4.5.2 current-source gate',
    '`zigcss/vite`',
    'deny-network production build',
    'client bundle, Nitro server bundle, and prerender output',
    'one native Sass partial',
    'one emitted SVG asset',
    "Nuxt's intermediate Vite output",
    'public output retains client JavaScript maps',
    'no public production CSS map or runtime SSR request is claimed',
    'not stable 0.6.0 adapter delivery',
    '`zigcss/nuxt` export',
  ]) requireText(nuxtHost.behavior, needle, 'capability metadata Nuxt host')
  if (!same(nuxtHost.evidence, ['nuxt-example', 'bundler-adapters', 'node-api', 'documentation'])) {
    fail('capability metadata Nuxt host evidence drifted')
  }
  requireText(
    buildWorkflow,
    'run: npm run test:bundler-adapters',
    'build workflow builder-adapter evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:turbopack-example',
    'build workflow Next.js Turbopack evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:next-webpack-example',
    'build workflow Next.js Webpack evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:sveltekit-example',
    'build workflow SvelteKit evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:astro-example',
    'build workflow Astro evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:nuxt-example',
    'build workflow Nuxt evidence gate',
  )
  requireText(
    buildWorkflow,
    'run: npm run test:parcel-example',
    'build workflow Parcel local-transformer evidence gate',
  )

  for (const [document, label, needles] of [
    [
      formatGuide,
      'format compatibility guide',
      [
        'The four preprocessor rows are `native-graduated` on the published stable release',
        'These exact providers are development-only reference oracles.',
        'they do not run during compilation',
        'The current `Unreleased` package-root Node.js API exposes the same closed five-syntax set',
        'Explicit experimental adapters now expose the current-checkout compiler through `zigcss/vite`, `zigcss/rollup`, `zigcss/esbuild`, `zigcss/bun`, `zigcss/webpack`, and `zigcss/rspack`',
        'These integrations do not add new source languages or imply a published Parcel transformer, framework-specific adapter, Nx executor, Bazel rule, Angular integration, or general framework compatibility.',
        'A pinned Next.js 16.3.4 Turbopack example reuses only `zigcss/webpack`',
        'Next.js 16.2+ loader output module types are required',
        'The same exact host now has a separate Webpack proof with Sass 1.101.0 only as the downstream parser',
        'cached-offline `next build --webpack` production builds while blocking public Node network entry points',
        'unchanged zero-native-invocation cache hit',
        'not an OS sandbox',
        'The final Webpack stylesheet does not retain the original ZigCSS source-map chain.',
        'npm run test:next-webpack-example',
        'A separate pinned SvelteKit 2.70.3/Svelte 5.57.0/Vite 8.2.2 example reuses `zigcss/vite`',
        'Embedded styles, Svelte preprocessors, framework HMR/watch invalidation',
        'A pinned Astro 7.2.10 static example registers `zigcss/vite`',
        'repeats `npm ci` offline, denies network access during the production build',
        'A pinned Nuxt 4.5.2 example also registers `zigcss/vite`',
        'no public production CSS map or runtime SSR request is claimed',
        'No PostCSS adapter is shipped',
        'CSS-in-JS, PostCSS plugin execution, and Tailwind-like compilation remain unavailable.',
      ],
    ],
    [
      statusGuide,
      'status guide',
      [
        'SCSS, indented Sass, Less, and Stylus route through self-contained native Zig parser/evaluators',
        'The JavaScript command launcher only locates and invokes that binary.',
        'The current `Unreleased` source package additionally exposes a typed programmatic Node.js API',
        '## Programmatic Node.js API boundary',
        'The closed export set is `compile`, `compileSync`, `compileFile`, `compileFileSync`, `detectSyntax`, and `ZigCssCompileError`.',
        'A string `sourcePath` may name a virtual file, but its parent must exist and is realpath-canonicalized.',
        'This is a generic compiler API, not an incremental service.',
        '## Tooling integration boundary',
        'Webpack and Rspack share one async raw loader with strict rightmost-loader ordering',
        'The two Next.js modes are deliberately narrower than a framework adapter',
        'they remain source-checkout-only until a future release ships the current native protocol',
        'development HMR/watch invalidation',
        '`zigcss/turbopack` or `zigcss/next` export',
        'The SvelteKit example is equally narrow',
        'embedded `<style lang="scss">`, Svelte preprocessors, framework HMR/watch invalidation',
        'The Astro example claims only one external CSS Module in an exact Astro 7.2.10 static build',
        'The Nuxt example claims only one external CSS Module in the exact Nuxt 4.5.2 client, Nitro bundle, and prerender build',
        'Both remain current-source-checkout proofs rather than stable 0.6.0 delivery.',
        'No PostCSS adapter is shipped',
        'A separately published Parcel transformer or framework-specific adapter, Bazel rule, Nx executor, and Angular integration remain unclaimed',
        'A separate pinned Next.js 16.3.4 Webpack gate uses one exact-project-file `enforce: \'pre\'` rule',
        'blocks public Node network entry points during `next build --webpack`',
        'unchanged cache hit with zero native invocations',
        'dependency-only warm rebuild',
        'the final stylesheet does not retain the original ZigCSS source-map chain',
        'seven independently locked npm surfaces',
        'The local Parcel example is an eighth exact package manifest',
        'it must stay dependency-free and script-free',
        "The ordinary build workflow's Test job uses exact Node 24.20.0 LTS",
        'The explicit `zigcss.experimental_native` namespace admits exactly SCSS, indented Sass, Less, and Stylus.',
        '`NATIVE-009` published candidate `0.6.0-rc.2` is verified on the GitHub prerelease and npm `next` channels',
      ],
    ],
    [
      recoveryGuide,
      'native CLI guide',
      [
        'SCSS, indented Sass, Less, and Stylus enter self-contained native Zig parser/evaluators',
        'The root JavaScript launcher only locates and invokes the binary',
        'Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 are development-only reference oracles.',
        'Less 4.9.0 forward-checks the frozen 4.6.7 native conformance baseline rather than changing the published native contract.',
        'These providers do not run during compilation',
        '`--depfile` writes the authored output path as its target',
        'This does not claim a two-file filesystem transaction.',
        'Matching a development oracle does not grant those extension points implicitly.',
      ],
    ],
    [
      buildGuide,
      'build-from-source guide',
      [
        'Exact Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 providers remain development-only reference oracles',
        'Less 4.9.0 is a forward oracle over the frozen 4.6.7 native conformance baseline, not a new native graduation.',
        'do not run during compilation',
        'examples/native/styles.styl',
        'seven exact npm manifest/version-3-lockfile pairs',
        'one exact dependency-free and script-free manifest whose Parcel toolchain is owned by the root lockfile',
        "The build workflow's Test job uses exact Node 24.20.0 LTS",
      ],
    ],
    [
      changelog,
      'changelog migration notes',
      [
        '`NATIVE-008` closes the finite source-capability inventory',
        '`nativeReleaseReady` is `true` for exact candidate `0.6.0-rc.2`',
        'one protected tag workflow produced the verified, historically mutable GitHub prerelease, 25 release assets, and immutable npm `next` package with provenance',
        'remain exact development-only reference oracles and do not run during compilation',
        'zero production dependencies and zero optional dependencies',
        'Add a typed zero-production-dependency Node.js API at the package root',
        'Add a private length-framed `zigcss-node-v1` native transport',
        'Add a bounded Astro source-checkout example',
        'Add a bounded Nuxt source-checkout example',
        'Add `--depfile <path>` for one explicit file-to-file compilation.',
        'The former programmatic provider-backed JavaScript preprocessor API is not part of this source contract.',
        'Keep arbitrary preprocessor plugins, custom functions/importers, Less JavaScript, Stylus evaluator hooks, executable project code',
      ],
    ],
  ]) {
    for (const needle of needles) requireText(document, needle, label)
  }
}

function validateReleaseGraduation(release, buildWorkflow, releaseWorkflow) {
  if (!same(release, expectedReleaseGraduation)) {
    fail('release graduation contract drifted')
  }

  for (const target of nativeTargetContract) {
    requireText(buildWorkflow, `target: ${target.target}`, `Build native target ${target.target}`)
    requireText(releaseWorkflow, `target: ${target.target}`, `Release native target ${target.target}`)
  }
  for (const [needle, label] of [
    ['name: Test Suite', 'hosted Test Suite evidence'],
    ['name: Native Package Evidence', 'hosted aggregate package evidence'],
    ['  npm-preflight:\n', 'release npm preflight'],
    ['  release:\n', 'release artifact matrix'],
    ['  create-release:\n', 'GitHub release creation'],
    ['  publish-npm:\n', 'npm publication'],
    ['needs: npm-preflight', 'artifact dependency on npm preflight'],
    ['needs: [npm-preflight, release]', 'GitHub release dependency on preflight and artifacts'],
    ['needs: [npm-preflight, create-release]', 'npm publication dependency on preflight and GitHub release'],
    ['npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --registry=https://registry.npmjs.org/ --provenance', 'exact canonical-registry channel-aware npm provenance publication'],
    ['prerelease: ${{ needs.npm-preflight.outputs.github-prerelease }}', 'SemVer-derived GitHub release boundary'],
  ]) {
    requireText(
      needle.startsWith('name:') ? buildWorkflow : releaseWorkflow,
      needle,
      label,
    )
  }
}

function validateAdapter(adapter, index) {
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
  }

  for (const source of adapter.nativeSources) repositoryFile(source)

  if (adapter.id === 'css') {
    if (adapter.current !== 'native-graduated') fail('CSS must remain native-graduated')
    if (!same(adapter.nativeSources, ['src/tokenizer.zig', 'src/css.zig'])) {
      fail('CSS native source inventory drifted')
    }
  } else {
    if (adapter.current !== 'native-graduated') {
      fail(`${adapter.id} must be native-graduated for the release-ready candidate`)
    }
    if (adapter.ownerPackages.at(-1) !== 'NATIVE-009') {
      fail(`${adapter.id} native graduation must be owned by NATIVE-009`)
    }
    if (!same(adapter.nativeSources, expectedDifferentialAdapterSources[adapter.id])) {
      fail(`${adapter.id} native source inventory drifted`)
    }
  }
}

function validateFoundation(foundation, index) {
  const label = `foundations[${index}]`
  exactKeys(
    foundation,
    ['id', 'current', 'ownerPackage', 'nativeSources', 'testSources', 'testStep'],
    label,
  )
  if (!same(foundation, expectedFoundations[index])) {
    fail(`${label} inventory drifted`)
  }
  for (const source of foundation.nativeSources) repositoryFile(source)
  for (const source of foundation.testSources) repositoryFile(source)
}

function validateImplementation(implementation, index, contract) {
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
  for (const adapterId of implementation.adapters) {
    const adapter = contract.adapters.find(candidate => candidate.id === adapterId)
    if (adapter === undefined) fail(`${label} references unknown adapter ${adapterId}`)
    if (adapter.current !== 'native-graduated') {
      fail(`${label} requires the bounded native-graduated ${adapterId} adapter state`)
    }
  }
  for (const source of implementation.nativeSources) repositoryFile(source)
  for (const source of implementation.testSources) repositoryFile(source)
}

function validateProductRouting(
  routing,
  compilerTests,
  zigApiTests,
  cliTests,
  nodeWrapperSource,
  nodeWrapperTests,
  nodeApiTests,
  sassConformanceTests,
  lessConformanceTests,
  stylusConformanceTests,
) {
  if (!same(routing, expectedProductRouting)) fail('product routing contract drifted')
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
              : route.id === 'programmatic-node-api'
                ? `${nodeApiTests}\n${cliTests}`
              : route.id === 'files-and-stdin' || route.id === 'batch' || route.id === 'parallel'
                ? cliTests
                : route.id === 'watch'
                  ? `${zigApiTests}\n${cliTests}`
                  : route.id === 'diagnostics-and-dependencies'
                    ? `${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                    : route.id === 'source-maps'
                      ? `${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                      : route.id === 'verified-optimizer'
                        ? `${compilerTests}\n${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                        : route.id === 'verified-target-prefix'
                          ? `${compilerTests}\n${zigApiTests}\n${cliTests}\n${nodeWrapperTests}`
                      : ''
      for (const evidenceTest of route.evidenceTests) {
        const testDeclaration = route.id === 'javascript-wrapper' ||
          (route.id === 'programmatic-node-api' &&
            !evidenceTest.startsWith('binary hidden Node route ')) ||
          ((route.id === 'diagnostics-and-dependencies' ||
            route.id === 'source-maps' ||
            route.id === 'verified-optimizer' ||
            route.id === 'verified-target-prefix') &&
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
  manifest,
  packageTests,
  nodeWrapperSource,
  nodeWrapperTests,
  nodeApiSource,
  nodeApiTests,
  releaseSmokeSource,
  releaseSmokeTests,
  nativePackageEvidenceTests,
  releaseMetadataTests,
  releaseConsumerTests,
  releaseSmokePreloadSource,
  productionSources,
) {
  if (!same(migration, expectedPackageMigration)) fail('native package migration contract drifted')
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
  if (
    manifest.main !== 'api.cjs' ||
    manifest.types !== 'api.d.ts' ||
    manifest.preferUnplugged !== true ||
    !same(manifest.bin, packageBins) ||
    !same(manifest.exports, packageExports) ||
    !same(manifest.typesVersions, packageTypesVersions)
  ) {
    fail('native package migration export inventory drifted')
  }
  if (!same(manifest.files, manifestPackageFiles) ||
    manifest.files.some(relativePath => (
      relativePath === 'preprocessor' ||
      relativePath.startsWith('preprocessor/')
    ))) {
    fail('native package migration programmatic API or provider-host boundary drifted')
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
  for (const [needle, label] of [
    [
      "for (const marker of ['build.zig', path.join('src', 'node_protocol.zig')]) {",
      'native package migration JavaScript wrapper source-checkout markers',
    ],
    [
      "const candidate = regularExecutable(path.join(root, 'zig-out', 'bin', binaryName));",
      'native package migration JavaScript wrapper source-checkout executable',
    ],
    [
      'return candidate !== null && containsLocalPath(root, candidate) ? candidate : null;',
      'native package migration JavaScript wrapper source-checkout confinement',
    ],
    [
      'return packagedBinary !== null && containsLocalPath(root, packagedBinary) ? packagedBinary : null;',
      'native package migration JavaScript wrapper packaged confinement',
    ],
  ]) {
    requireText(nodeWrapperSource, needle, label)
  }
  requireText(
    nodeWrapperTests,
    "test('javascript wrapper selects only a marker-verified confined source-checkout binary'",
    'native package migration JavaScript wrapper source-checkout evidence',
  )
  for (const [needle, label] of [
    [
      "for (const marker of ['build.zig', path.join('src', 'node_protocol.zig')]) {",
      'native package migration programmatic Node API source-checkout markers',
    ],
    [
      "const candidate = regularExecutable(path.join(root, 'zig-out', 'bin', binaryName));",
      'native package migration programmatic Node API source-checkout executable',
    ],
    [
      'return candidate !== null && containsLocalPath(root, candidate) ? candidate : null;',
      'native package migration programmatic Node API source-checkout confinement',
    ],
  ]) {
    requireText(nodeApiSource, needle, label)
  }
  for (const [needle, label] of [
    [
      "test('a direct source checkout selects only its marker-verified confined freshly built native binary'",
      'native package migration programmatic Node API source-checkout evidence',
    ],
    [
      'source-checkout API must reject a missing protocol marker',
      'native package migration programmatic Node API missing-marker evidence',
    ],
    [
      'source-checkout API must reject a symlink protocol marker',
      'native package migration programmatic Node API symlink-marker evidence',
    ],
    [
      'source-checkout API must reject a final binary symlink',
      'native package migration programmatic Node API binary-symlink evidence',
    ],
    [
      'source-checkout API must reject an intermediate-directory escape',
      'native package migration programmatic Node API confinement evidence',
    ],
  ]) {
    requireText(nodeApiTests, needle, label)
  }
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
    ["immutableFunction(childProcess, 'spawn', function tracedNativeSpawn", 'admitted native child trace'],
    ["immutableFunction(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn", 'direct ChildProcess denial'],
    ['Reflect.ownKeys(options)', 'native child option inventory'],
    ['optionKeys.length === 2', 'CLI launcher native child exact option boundary'],
    ["args[0] === '--internal-node-v1'", 'programmatic API private native route'],
    ['optionKeys.length === 3', 'programmatic API native child exact option boundary'],
    ["['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']", 'alternate child denial'],
    ["record('native-spawn')", 'native spawn event'],
    ["record('network-denied')", 'network denial event'],
    ["immutableFunction(http, 'request'", 'HTTP denial'],
    ["immutableFunction(https, 'request'", 'HTTPS denial'],
    ["immutableFunction(net, 'connect'", 'TCP denial'],
    ["immutableFunction(net.Server.prototype, 'listen'", 'listener denial'],
    ["immutableFunction(net, 'createServer'", 'TCP server denial'],
    ["immutableFunction(http, 'createServer'", 'HTTP server denial'],
    ["immutableFunction(https, 'createServer'", 'HTTPS server denial'],
    ["immutableFunction(tls, 'connect'", 'TLS denial'],
    ["immutableFunction(tls, 'createServer'", 'TLS server denial'],
    ["immutableFunction(http2, 'connect'", 'HTTP2 denial'],
    ["immutableFunction(http2, 'createServer'", 'HTTP2 server denial'],
    ["immutableFunction(http2, 'createSecureServer'", 'secure HTTP2 server denial'],
    ["immutableFunction(dgram, 'createSocket'", 'datagram denial'],
    ['for (const name of Object.keys(dns))', 'dynamic callback DNS denial'],
    ['allowedDnsConfigurationFunctions', 'finite DNS configuration allowlist'],
    ["immutableValue(dns, 'Resolver'", 'callback DNS resolver denial'],
    ["immutableValue(dnsPromises, 'Resolver'", 'promise DNS resolver denial'],
    ["immutableValue(\n    globalThis,\n    'fetch'", 'fetch denial'],
    ["immutableValue(workerThreads, 'Worker'", 'worker denial'],
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
}

function validateLessConformance(
  conformance,
  contract,
  selection,
  conformanceTests,
) {
  if (!same(conformance, expectedLessConformance)) {
    fail('native Less conformance contract drifted')
  }
  const oracle = contract.referenceOracles.find(candidate => candidate.id === conformance.oracle.id)
  if (oracle === undefined || oracle.package !== conformance.oracle.package ||
      oracle.version !== conformance.oracle.developmentVersion ||
      selection.upstream?.packageVersion !== conformance.oracle.baselineVersion) {
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
}

function validateLessParser(selection, tests) {
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
}

function validateStylusParser(manifest, selection, source, tests) {
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
}

function validateStylusEvaluator(selection, source, tests) {
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
}

function validateStylusConformance(
  conformance,
  contract,
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
}

function validateLessEvaluator(source, tests) {
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
  const nativeEvaluator = sourceByPath.get('src/preprocessor/evaluator.zig') ?? ''
  const nativeSource = sourceByPath.get('src/preprocessor/source.zig') ?? ''
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
    'const css = compiled.takeCss();',
    'native Zig API zero-copy owned CSS promotion',
  )
  requireText(
    nativeCompiler,
    'return self.validated.takeCss();',
    'native compiler owned CSS transfer',
  )
  requireText(
    nativeEvaluator,
    'self.core.css = &.{};',
    'native evaluator moved-from CSS teardown safety',
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
  for (const [source, needle, label] of [
    [nativeApi, '(options.source_map and options.optimize) or', 'native Zig API optimizer/map fail-fast'],
    [nativeApi, '.optimize = options.optimize,', 'native Zig API optimizer promotion'],
    [nativeApi, '(options.prefix and options.targets == null) or', 'native Zig API prefix/target fail-fast'],
    [nativeApi, '.prefix = options.prefix,', 'native Zig API target-prefix promotion'],
    [nativeApi, '.targets = options.targets,', 'native Zig API target-query promotion'],
    [nativeCompiler, '(options.source_map and options.optimize) or', 'native compiler optimizer/map fail-fast'],
    [nativeCompiler, '.optimize = options.optimize,', 'native compiler optimizer promotion'],
    [nativeCompiler, '(options.prefix and options.targets == null) or', 'native compiler prefix/target fail-fast'],
    [nativeCompiler, '.prefix = options.prefix,', 'native compiler target-prefix promotion'],
    [nativeCompiler, '.targets = options.targets,', 'native compiler target-query promotion'],
    [nativeEvaluator, 'verified_optimizer.applyToFixedPoint(', 'native evaluator verified fixed-point optimizer'],
    [nativeEvaluator, 'prefix_rewrite.applyToStylesheet(', 'native evaluator verified target-prefix rewrite'],
  ]) {
    requireText(source, needle, label)
  }
  for (const [needle, label] of [
    ['pub fn composeCoreMap(', 'native source-map bounded composition'],
    ['core_sourcemap.decodeMappings(', 'native source-map strict core decoding'],
    ['const inner = frontend.lookup(', 'native source-map greatest-lower-bound tracing'],
    ['max_composed_source_map_bytes', 'native source-map output terminal'],
  ]) {
    requireText(nativeSourceMap, needle, label)
  }
  for (const [needle, label] of [
    ['fn renderCssWithInlineSourceMap(', 'all-syntax binary CLI source-map renderer'],
    ['fn renderNativeCss(', 'native binary CLI source-map renderer'],
    ['std.base64.standard.Encoder.encode(', 'native binary CLI inline source-map encoding'],
    ['task.rendered_css = renderCssWithInlineSourceMap(', 'stable CSS binary CLI parallel map preparation'],
    ['task.rendered_css = renderNativeCss(', 'native binary CLI parallel map preparation'],
    ['--source-map             Embed a deterministic inline source map', 'native binary CLI source-map help'],
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
    nativeSource,
    'name_index: std.StringHashMapUnmanaged(SourceId)',
    'native source-table owned-name index',
  )
  requireText(
    nativeSource,
    'pub fn findByName(',
    'native source-table indexed exact lookup',
  )
  requireText(
    nativeWatchState[0],
    'compiled.sourceTable().findByName(dependency.url)',
    'native Zig API watch snapshot indexed compiler-owned lookup',
  )
  requireText(
    nativeWatchState[0],
    'contentHash(source_file.bytes)',
    'native Zig API watch snapshot compiler-owned bytes',
  )
  requireText(
    nativeWatchState[0],
    'const hash = session.contentFingerprint(item.url)',
    'native Zig API confined streaming watch fingerprint',
  )
  if (nativeWatchState[0].includes('session.load(item.url')) {
    fail('native Zig API watch polling regressed to full dependency loads')
  }
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
    '"--profile is unavailable for native stylesheet syntax"',
    'native binary CLI profile boundary',
  )
  requireText(
    binaryCli,
    '--optimize               Run the closed verified optimizer preset',
    'all-syntax binary CLI optimizer help',
  )
  for (const [needle, label] of [
    ['--autoprefix             Run verified eight-feature target prefixing', 'all-syntax binary CLI target-prefix help'],
    ['--browsers <query>       Set explicit browser minima (requires --autoprefix)', 'all-syntax binary CLI target-query help'],
    ['zigcss.prefixing.target_query.parse(allocator, value, .{})', 'binary CLI strict target-query parser'],
    ['"--autoprefix requires --browsers <query>"', 'binary CLI prefix/query pairing'],
    ['.transforms = .{ .optimize = optimize, .prefix = prefix.enabled },', 'stable CSS binary CLI target-prefix dispatch'],
    ['.targets = prefix.targets,', 'stable CSS binary CLI target-query dispatch'],
    ['.prefix = prefix.enabled,', 'native binary CLI target-prefix dispatch'],
    ['.targets = prefix.targets,', 'native binary CLI target-query dispatch'],
  ]) {
    requireText(binaryCli, needle, label)
  }
  requireText(
    nodeWrapperTests,
    "test('javascript wrapper forwards verified target prefix requests unchanged'",
    'native JavaScript wrapper target-prefix forwarding',
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
    stablePromotion = loadJson('release/stable-promotion.json'),
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
    nodeApiTests = fs.readFileSync(
      repositoryFile('scripts/verify-node-api.test.mjs'),
      'utf8',
    ),
    nodeApiSource = fs.readFileSync(repositoryFile('api.cjs'), 'utf8'),
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
  if (contract.schemaVersion !== 10) fail('schemaVersion must be 10')
  if (contract.state !== 'native-graduated') {
    fail('state must be native-graduated for the release-ready candidate')
  }
  if (contract.nativeReleaseReady !== true) fail('native release must be ready')
  if (contract.nativeReleaseVersion !== '0.6.0-rc.2') {
    fail('nativeReleaseVersion must match the exact release-ready candidate')
  }
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
    sassSelection,
    sassEvaluatorSource,
    sassEvaluatorTests,
  )
  validateSassConformance(
    contract.sassConformance,
    contract,
    sassSelection,
    sassManifest,
    sassConformanceTests,
  )
  validateLessParser(lessSelection, lessParserTests)
  validateLessEvaluator(lessEvaluatorSource, lessEvaluatorTests)
  validateLessConformance(
    contract.lessConformance,
    contract,
    lessSelection,
    lessConformanceTests,
  )
  validateStylusParser(
    stylusManifest,
    stylusSelection,
    stylusParserSource,
    stylusParserTests,
  )
  validateStylusEvaluator(
    stylusSelection,
    stylusEvaluatorSource,
    stylusEvaluatorTests,
  )
  validateStylusConformance(
    contract.stylusConformance,
    contract,
    stylusSelection,
    stylusManifest,
    stylusConformanceTests,
  )
  validateProductRouting(
    contract.productRouting,
    compilerTests,
    zigApiTests,
    cliTests,
    nodeWrapperSource,
    nodeWrapperTests,
    nodeApiTests,
    sassConformanceTests,
    lessConformanceTests,
    stylusConformanceTests,
  )
  validatePackageMigration(
    contract.packageMigration,
    manifest,
    packageTests,
    nodeWrapperSource,
    nodeWrapperTests,
    nodeApiSource,
    nodeApiTests,
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
    buildWorkflow,
  )
  validateReleaseGraduation(
    contract.releaseGraduation,
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

  const activePackageVersion = parseReleaseVersion(manifest.version, 'active package version')
  const publishedStableVersion = parseReleaseVersion(
    stablePromotion?.candidateVersion,
    'immutable published stable version',
  )
  const stablePromotionOwnsPublishedEvidence =
    stablePromotion?.ownerPackage === 'REL-010'
    && stablePromotion?.releaseGapFamily === 'stable-release-promotion'
    && stablePromotion?.state === 'closed'
    && stablePromotion?.packageState === 'verified'
    && stablePromotion?.stableReleaseReady === false
    && publishedStableVersion.prerelease === null
    && publishedStableVersion.build === null
    && stablePromotion?.candidateTag === `v${publishedStableVersion.value}`
    && stablePromotion?.previousPrerelease?.version === contract.releaseGraduation.candidateVersion
    && stablePromotion?.previousPrerelease?.tag === contract.releaseGraduation.candidateTag
    && stablePromotion?.publicationEvidence?.npmVersion === publishedStableVersion.value
    && stablePromotion?.publicationEvidence?.npmLatest === publishedStableVersion.value
    && stablePromotion?.publicationEvidence?.npmDistTag === 'latest'
    && stablePromotion?.publicationEvidence?.npmNext === contract.releaseGraduation.candidateVersion
    && stablePromotion?.publicationEvidence?.githubPrerelease === false
    && stablePromotion?.publicationEvidence?.githubDraft === false
    && stablePromotion?.publicationEvidence?.githubImmutable === false
    && stablePromotion?.publicationEvidence?.githubReleaseUrl === `https://github.com/vyakymenko/zigcss/releases/tag/v${publishedStableVersion.value}`
    && /^[0-9a-f]{40}$/.test(stablePromotion?.publicationEvidence?.tagCommit ?? '')
  if (!stablePromotionOwnsPublishedEvidence) {
    fail('immutable stable promotion no longer binds the published native prerelease and stable publication')
  }
  if (compareReleaseVersionPrecedence(activePackageVersion.value, publishedStableVersion.value) < 0) {
    fail(`active package version ${activePackageVersion.value} is older than immutable stable publication ${publishedStableVersion.value}`)
  }
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
  if (manifest.scripts?.['test:bundler-adapters'] !== 'node --test scripts/verify-bundler-adapters.test.mjs') {
    fail('package script test:bundler-adapters is missing or changed')
  }
  if (manifest.scripts?.['test:turbopack-example'] !== 'node --test scripts/verify-turbopack-example.test.mjs') {
    fail('package script test:turbopack-example is missing or changed')
  }
  if (manifest.scripts?.['test:next-webpack-example'] !== 'node --test scripts/verify-next-webpack-example.test.mjs') {
    fail('package script test:next-webpack-example is missing or changed')
  }
  if (manifest.scripts?.['test:sveltekit-example'] !== 'node --test scripts/verify-sveltekit-example.test.mjs') {
    fail('package script test:sveltekit-example is missing or changed')
  }
  if (manifest.scripts?.['test:astro-example'] !== 'node --test scripts/verify-astro-example.test.mjs') {
    fail('package script test:astro-example is missing or changed')
  }
  if (manifest.scripts?.['test:nuxt-example'] !== 'node --test scripts/verify-nuxt-example.test.mjs') {
    fail('package script test:nuxt-example is missing or changed')
  }
  if (manifest.scripts?.['test:parcel-example'] !== 'node --test scripts/verify-parcel-example.test.mjs') {
    fail('package script test:parcel-example is missing or changed')
  }
  if (manifest.scripts?.['test:types'] !== 'tsc -p tests/typescript/tsconfig.json') {
    fail('package script test:types is missing or changed')
  }
  if (manifest.scripts?.['test:build-systems'] !== 'node --test scripts/verify-build-system-examples.test.mjs') {
    fail('package script test:build-systems is missing or changed')
  }
  if (manifest.scripts?.['test:package-managers'] !== 'node --test scripts/verify-package-managers.test.mjs') {
    fail('package script test:package-managers is missing or changed')
  }
  if (manifest.scripts?.['test:workflows'] !== 'node --test scripts/run-zig-test-suite.test.mjs scripts/setup-zig-action.test.mjs scripts/smoke-development-container.test.mjs scripts/test-release-container.test.mjs scripts/validate-workflows.test.mjs scripts/verify-build-workflow-run.test.mjs scripts/verify-code-scanning-gate.test.mjs scripts/verify-release-controls.test.mjs') {
    fail('package script test:workflows must retain the Zig suite runner contract')
  }

  for (const [index, foundation] of contract.foundations.entries()) {
    validateFoundation(foundation, index)
  }
  for (const [index, adapter] of contract.adapters.entries()) validateAdapter(adapter, index)
  for (const [index, implementation] of contract.implementations.entries()) {
    validateImplementation(implementation, index, contract)
  }
  validateInternalReachability(
    contract.implementations,
    buildFile,
    productionSources,
    nodeWrapperTests,
  )
  validateNativeImportClosure(contract, productionSources)

  requireText(decision, '- Status: Accepted', 'ADR-013')
  requireText(decision, 'zero `dependencies` and zero `optionalDependencies`', 'ADR-013')
  requireText(decision, 'All tag-triggered releases are fail-closed', 'ADR-013')
  requireText(decision, 'first fully graduated native candidate', 'ADR-013')
  requireText(readme, 'Native dependency-free migration', 'README.md')

  const buildGate = 'npm run test:native-contract && npm run test:native-package-evidence && npm run check:native-contract'
  requireText(buildWorkflow, buildGate, 'build workflow')
  requireText(buildWorkflow, 'npm run test:node-wrapper', 'native JavaScript wrapper workflow')
  requireText(buildWorkflow, 'run: npm run test:package-managers', 'package-manager recovery workflow')
  requireText(buildWorkflow, 'run: npm run test:bundler-adapters', 'builder adapter workflow')
  requireText(buildWorkflow, 'run: npm run test:turbopack-example', 'Turbopack example workflow')
  requireText(buildWorkflow, 'run: npm run test:next-webpack-example', 'Next.js Webpack example workflow')
  requireText(buildWorkflow, 'run: npm run test:sveltekit-example', 'SvelteKit example workflow')
  requireText(buildWorkflow, 'run: npm run test:astro-example', 'Astro example workflow')
  requireText(buildWorkflow, 'run: npm run test:nuxt-example', 'Nuxt example workflow')
  requireText(buildWorkflow, 'run: npm run test:parcel-example', 'Parcel example workflow')
  requireText(buildWorkflow, 'run: npm run test:types', 'TypeScript package-surface workflow')
  requireText(buildWorkflow, 'run: npm run test:build-systems', 'dependency-file build-system workflow')
  requireText(buildWorkflow, 'node scripts/run-zig-test-suite.mjs --mode Debug', 'build workflow')
  requireText(buildWorkflow, 'node scripts/run-zig-test-suite.mjs --mode ReleaseSafe', 'build workflow')
  if (buildWorkflow.includes('zig build test-native-preprocessor --summary all')) {
    fail('build workflow must not duplicate native frontend coverage before the complete root test graph')
  }
  const runTestsStep = [
    '      - name: Run Tests',
    '        run: node scripts/run-zig-test-suite.mjs --mode Debug',
  ].join('\n')
  if (buildWorkflow.split(runTestsStep).length !== 2) {
    fail('build workflow must own one exact Run Tests gate')
  }
  const adapterStep = [
    '      - name: Verify build-tool adapters',
    '        env:',
    '          ZIGCSS_ADAPTER_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:bundler-adapters',
  ].join('\n')
  const turbopackStep = [
    '      - name: Verify Next.js Turbopack global SCSS integration',
    '        env:',
    '          ZIGCSS_TURBOPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:turbopack-example',
  ].join('\n')
  const nextWebpackStep = [
    '      - name: Verify Next.js Webpack global SCSS integration',
    '        env:',
    '          ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:next-webpack-example',
  ].join('\n')
  const sveltekitStep = [
    '      - name: Verify SvelteKit external CSS Module integration',
    '        env:',
    '          ZIGCSS_SVELTEKIT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:sveltekit-example',
  ].join('\n')
  const astroStep = [
    '      - name: Verify Astro external CSS Module integration',
    '        env:',
    '          ZIGCSS_ASTRO_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:astro-example',
  ].join('\n')
  const nuxtStep = [
    '      - name: Verify Nuxt external CSS Module integration',
    '        env:',
    '          ZIGCSS_NUXT_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:nuxt-example',
  ].join('\n')
  const parcelStep = [
    '      - name: Verify Parcel local transformer integration',
    '        env:',
    '          ZIGCSS_PARCEL_NATIVE_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    '        run: npm run test:parcel-example',
  ].join('\n')
  const buildSystemsStep = [
    '      - name: Verify dependency-file build-system integrations',
    '        env:',
    '          ZIGCSS_REAL_BINARY: ${{ github.workspace }}/zig-out/bin/zigcss',
    "          ZIGCSS_REQUIRE_BUILD_SYSTEMS: '1'",
    '        run: npm run test:build-systems',
  ].join('\n')
  if (buildWorkflow.split(buildSystemsStep).length !== 2) {
    fail('build workflow build-system gate must own exact ZIGCSS_REAL_BINARY env')
  }
  if (buildWorkflow.split(adapterStep).length !== 2) {
    fail('build workflow adapter gate must own exact ZIGCSS_ADAPTER_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(turbopackStep).length !== 2) {
    fail('build workflow Turbopack gate must own exact ZIGCSS_TURBOPACK_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(nextWebpackStep).length !== 2) {
    fail('build workflow Next.js Webpack gate must own exact ZIGCSS_NEXT_WEBPACK_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(sveltekitStep).length !== 2) {
    fail('build workflow SvelteKit gate must own exact ZIGCSS_SVELTEKIT_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(astroStep).length !== 2) {
    fail('build workflow Astro gate must own exact ZIGCSS_ASTRO_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(nuxtStep).length !== 2) {
    fail('build workflow Nuxt gate must own exact ZIGCSS_NUXT_NATIVE_BINARY env')
  }
  if (buildWorkflow.split(parcelStep).length !== 2) {
    fail('build workflow Parcel gate must own exact ZIGCSS_PARCEL_NATIVE_BINARY env')
  }
  if (
    buildWorkflow.indexOf(adapterStep) <= buildWorkflow.indexOf(runTestsStep)
    || buildWorkflow.indexOf(turbopackStep) <= buildWorkflow.indexOf(adapterStep)
    || buildWorkflow.indexOf(nextWebpackStep) <= buildWorkflow.indexOf(turbopackStep)
    || buildWorkflow.indexOf(sveltekitStep) <= buildWorkflow.indexOf(nextWebpackStep)
    || buildWorkflow.indexOf(astroStep) <= buildWorkflow.indexOf(sveltekitStep)
    || buildWorkflow.indexOf(nuxtStep) <= buildWorkflow.indexOf(astroStep)
    || buildWorkflow.indexOf(parcelStep) <= buildWorkflow.indexOf(nuxtStep)
    || buildWorkflow.indexOf(buildSystemsStep) <= buildWorkflow.indexOf(parcelStep)
  ) {
    fail('build workflow native adapter, Turbopack, Next.js Webpack, SvelteKit, Astro, Nuxt, Parcel, and dependency-file build-system gates must run after Run Tests')
  }
  validateBuildTestGraph(buildFile)
  const candidateCommitLookup = 'git rev-parse "${GITHUB_SHA}^{commit}"'
  const originMainLookup = 'git ls-remote --exit-code --refs origin refs/heads/main'
  const buildEvidenceGate = 'node scripts/verify-build-workflow-run.mjs \\'
  const codeScanningGate = 'node scripts/verify-code-scanning-gate.mjs \\'
  const candidateAdmissionGate = 'node scripts/validate-release-admission.mjs --check \\'
  const immutableReleaseEnvironment = '    environment:\n      name: immutable-release'
  const releaseGate = '--release-tag "$GITHUB_REF_NAME"'
  requireText(
    releaseWorkflow,
    candidateAdmissionGate,
    'release workflow candidate admission',
  )
  requireText(releaseWorkflow, buildEvidenceGate, 'release workflow Build evidence gate')
  requireText(releaseWorkflow, codeScanningGate, 'release workflow CodeQL evidence gate')
  if (
    releaseWorkflow.split(immutableReleaseEnvironment).length !== 2
    || releaseWorkflow.includes('IMMUTABLE_RELEASES_READ_TOKEN')
  ) {
    fail('release workflow must gate publication on one immutable-release approval environment without a stored administration credential')
  }
  if (releaseWorkflow.split(candidateCommitLookup).length !== 4) {
    fail('release workflow candidate commit lookup must appear exactly three times')
  }
  requireText(releaseWorkflow, originMainLookup, 'release workflow exact origin main lookup')
  requireText(releaseWorkflow, releaseGate, 'release workflow')
  requireText(
    releaseWorkflow,
    '--candidate-commit "$candidate_commit"',
    'release workflow candidate commit',
  )
  requireText(
    releaseWorkflow,
    '--origin-main-commit "$origin_main_commit"',
    'release workflow origin main commit',
  )
  requireText(
    releaseWorkflow,
    'npm publish "$NPM_PACKAGE_ARCHIVE" --tag "$RELEASE_CHANNEL" --registry=https://registry.npmjs.org/ --provenance',
    'release workflow exact npm archive publication',
  )
  if (
    releaseWorkflow.indexOf(buildEvidenceGate) >= releaseWorkflow.indexOf(codeScanningGate)
    || releaseWorkflow.indexOf(codeScanningGate) >= releaseWorkflow.indexOf(candidateAdmissionGate)
  ) {
    fail('release Build and CodeQL evidence gates must run in order before candidate admission')
  }
  if (releaseWorkflow.lastIndexOf(candidateCommitLookup) > releaseWorkflow.indexOf(releaseGate)) {
    fail('all three release candidate commit lookups must run before candidate admission')
  }
  if (releaseWorkflow.indexOf(originMainLookup) > releaseWorkflow.indexOf(releaseGate)) {
    fail('release exact origin main lookup must run before candidate admission')
  }
  if (releaseWorkflow.indexOf(releaseGate) > releaseWorkflow.indexOf('npm whoami')) {
    fail('release interlock must run before npm authentication/publication preflight')
  }

  return contract
}

export function validateReleaseTag(contract, tag, candidateCommit, originMainCommit) {
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
  if (
    release?.state === 'closed'
    || release?.packageState === 'verified'
    || publication?.state === 'verified'
  ) {
    fail(`release ${tag} rejected: native release is already published`)
  }
  const publicationStateValid = publication !== undefined
    && publication.state === 'pending'
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
    && release.state === 'candidate-ready'
    && release.packageState === 'in-progress'
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
  if (typeof candidateCommit !== 'string' || !/^[0-9a-f]{40}$/.test(candidateCommit)) {
    fail('candidate commit must be a canonical full SHA-1')
  }
  if (typeof originMainCommit !== 'string' || !/^[0-9a-f]{40}$/.test(originMainCommit)) {
    fail('origin main commit must be a canonical full SHA-1')
  }
  if (candidateCommit !== originMainCommit) {
    fail('candidate commit is not the exact origin main commit')
  }
}

function parseArguments(args) {
  if (same(args, ['--check'])) return { mode: 'check' }

  const releaseArgs = args[0] === '--check' ? args.slice(1) : args
  if (
    releaseArgs.length === 6
    && releaseArgs[0] === '--release-tag'
    && releaseArgs[2] === '--candidate-commit'
    && releaseArgs[4] === '--origin-main-commit'
  ) {
    return {
      mode: 'release-tag',
      tag: releaseArgs[1],
      candidateCommit: releaseArgs[3],
      originMainCommit: releaseArgs[5],
    }
  }

  fail(
    'usage: node scripts/validate-native-contract.mjs --check|'
      + '--release-tag vX.Y.Z --candidate-commit SHA --origin-main-commit SHA',
  )
}

function main() {
  const options = parseArguments(process.argv.slice(2))

  const contract = validateContract(loadContract())
  if (options.mode === 'release-tag') {
    validateReleaseTag(
      contract,
      options.tag,
      options.candidateCommit,
      options.originMainCommit,
    )
  }
  const releaseGate = contract.releaseGraduation?.packageState === 'verified'
    ? 'closed (published)'
    : contract.nativeReleaseReady
      ? 'open'
      : 'closed'
  process.stdout.write(
    `Native contract verified: ${contract.adapters.length} adapters, target ${contract.targetRelease}, release gate ${releaseGate}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
