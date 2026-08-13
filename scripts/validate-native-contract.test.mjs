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

const expectedReleaseGraduation = {
  ownerPackage: 'NATIVE-009',
  releaseGapFamily: 'native-release-evidence',
  state: 'in-progress',
  packageState: 'in-progress',
  candidateVersion: '0.6.0-rc.2',
  candidateTag: 'v0.6.0-rc.2',
  candidateSelection: {
    selectedOn: '2026-08-13',
    localTagStateAtSelection: 'absent',
    githubRepository: 'vyakymenko/zigcss',
    githubTagStateAtSelection: 'absent',
    npmPackage: 'zigcss',
    npmVersionStateAtSelection: 'absent',
    observedPublishedNpmVersions: ['0.2.0', '0.2.1', '0.3.0', '0.4.0-rc.3'],
  },
  terminalContract: {
    syntaxes: ['css', 'scss', 'sass', 'less', 'stylus'],
    targets: [
      'x86_64-linux',
      'aarch64-linux',
      'x86_64-macos',
      'aarch64-macos',
      'x86_64-windows',
    ],
    preTagSurfaces: [
      'release-evidence-contract',
      'immutable-candidate',
      'local-validation',
      'hosted-validation',
      'release-validation',
      'artifact-validation',
      'provenance-validation',
      'consumer-validation',
      'origin-main-integration',
    ],
    postTagSurfaces: ['tag-workflow-publication'],
    publicationChannels: ['github-prerelease', 'npm-next'],
    npmDistTag: 'next',
    referenceCandidateEligible: false,
  },
  gates: [{
    id: 'release-evidence-contract',
    state: 'verified',
    evidenceRequirements: [
      'finite local hosted release artifact provenance consumer and publication surfaces are machine-bound',
      'five native syntax and target inventories are resource-derived',
      'candidate version and tag selection remains separate from the closed release interlock',
    ],
  }, {
    id: 'immutable-candidate',
    state: 'verified',
    evidenceRequirements: [
      'one unused 0.6.x native version and matching immutable v tag are selected',
      'the provider-backed 0.5.0-rc.1 reference candidate remains ineligible',
    ],
  }, {
    id: 'local-validation',
    state: 'verified',
    evidenceRequirements: [
      'Debug ReleaseSafe differential fuzz allocation resource documentation package and audit gates pass on the candidate',
    ],
  }, {
    id: 'hosted-validation',
    state: 'verified',
    evidenceRequirements: [
      'one automatic Build on the exact integrated candidate passes Test Suite five targets and aggregate evidence within runtime budgets',
    ],
  }, {
    id: 'release-validation',
    state: 'pending',
    evidenceRequirements: [
      'version native package workflow and publication preflight policies pass before npm authentication',
    ],
  }, {
    id: 'artifact-validation',
    state: 'pending',
    evidenceRequirements: [
      'five exact native archives checksums SPDX inventories and direct smokes pass',
    ],
  }, {
    id: 'provenance-validation',
    state: 'pending',
    evidenceRequirements: [
      'five exact archives and SBOMs are bound by verified GitHub attestations',
    ],
  }, {
    id: 'consumer-validation',
    state: 'pending',
    evidenceRequirements: [
      'direct archives and offline installed packages compile all five syntaxes on all five targets',
    ],
  }, {
    id: 'origin-main-integration',
    state: 'pending',
    evidenceRequirements: [
      'the exact candidate commit is integrated to origin main before tag creation',
    ],
  }, {
    id: 'tag-workflow-publication',
    state: 'pending',
    evidenceRequirements: [
      'one immutable tag produces one GitHub prerelease and the exact npm next publication',
    ],
  }],
}

function makeReleaseReady(version = '0.6.0-rc.2') {
  const contract = clone(loadContract())
  contract.state = 'native-graduated'
  contract.nativeReleaseReady = true
  contract.nativeReleaseVersion = version
  for (const adapter of contract.adapters) adapter.current = 'native-graduated'
  contract.releaseGraduation.state = 'candidate-ready'
  contract.releaseGraduation.candidateVersion = version
  contract.releaseGraduation.candidateTag = `v${version}`
  const preTagSurfaces = new Set(contract.releaseGraduation.terminalContract.preTagSurfaces)
  for (const gate of contract.releaseGraduation.gates) {
    if (preTagSurfaces.has(gate.id)) gate.state = 'verified'
  }
  return contract
}

test('accepts the bounded native stylesheet implementation contract', () => {
  const contract = validateContract(loadContract())
  assert.equal(contract.schemaVersion, 9)
  assert.equal(contract.state, 'native-differential')
  assert.equal(contract.nativeReleaseReady, false)
  assert.deepEqual(contract.nativePublicationAuthority, {
    authorized: true,
    authorizedOn: '2026-07-27',
    scope: 'first-fully-graduated-native-release',
    workflow: '.github/workflows/release.yml',
    channels: ['github-prerelease', 'npm-next'],
  })
  assert.equal(contract.productionBoundary.packageDependencies, 0)
  assert.deepEqual(
    contract.referenceOracles.map(oracle => ({
      id: oracle.id,
      currentReferencePackage: oracle.currentReferencePackage,
      developmentOracle: oracle.developmentOracle,
      productionInNativeTarget: oracle.productionInNativeTarget,
    })),
    [
      { id: 'dart-sass', currentReferencePackage: false, developmentOracle: true, productionInNativeTarget: false },
      { id: 'less', currentReferencePackage: false, developmentOracle: true, productionInNativeTarget: false },
      { id: 'stylus', currentReferencePackage: false, developmentOracle: true, productionInNativeTarget: false },
    ],
  )
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
  assert.deepEqual(
    contract.adapters.slice(1).map(adapter => ({
      id: adapter.id,
      current: adapter.current,
      nativeSources: adapter.nativeSources,
    })),
    [{
      id: 'scss',
      current: 'native-differential',
      nativeSources: [
        'src/preprocessor/sass.zig',
        'src/preprocessor/sass_evaluator.zig',
        'src/preprocessor/sass_arguments.zig',
        'src/preprocessor/sass_numeric.zig',
        'src/preprocessor/sass_color.zig',
        'src/preprocessor/sass_string.zig',
        'src/preprocessor/sass_selector.zig',
      ],
    }, {
      id: 'sass',
      current: 'native-differential',
      nativeSources: [
        'src/preprocessor/sass.zig',
        'src/preprocessor/sass_evaluator.zig',
        'src/preprocessor/sass_arguments.zig',
        'src/preprocessor/sass_numeric.zig',
        'src/preprocessor/sass_color.zig',
        'src/preprocessor/sass_string.zig',
        'src/preprocessor/sass_selector.zig',
      ],
    }, {
      id: 'less',
      current: 'native-differential',
      nativeSources: [
        'src/preprocessor/less.zig',
        'src/preprocessor/less_evaluator.zig',
      ],
    }, {
      id: 'stylus',
      current: 'native-differential',
      nativeSources: [
        'src/preprocessor/stylus.zig',
        'src/preprocessor/stylus_evaluator.zig',
      ],
    }],
  )
  assert.deepEqual(contract.capabilityGraduation, {
    ownerPackage: 'NATIVE-008',
    releaseGapFamily: 'native-capability-graduation',
    state: 'closed',
    packageState: 'verified',
    terminalContract: {
      adapters: ['scss', 'sass', 'less', 'stylus'],
      surfaces: [
        'machine-rows',
        'binary-help',
        'readme',
        'website',
        'examples',
        'guides-and-compatibility',
        'changelog-and-migration-notes',
      ],
      pluginParity: false,
    },
    gates: [{
      id: 'machine-rows',
      state: 'verified',
      closureEvidence: [
        'all four native preprocessor conformance packages are verified',
        'native product routing and zero-dependency packaging are verified',
        'exact native source inventories are bound while public claims remain unchanged',
      ],
    }, {
      id: 'binary-help',
      state: 'verified',
      closureEvidence: ['stable native syntax selection and help agree with executable CLI tests'],
    }, {
      id: 'readme',
      state: 'verified',
      closureEvidence: ['README describes the exact self-contained native source snapshot'],
    }, {
      id: 'website',
      state: 'verified',
      closureEvidence: ['website claims and input/output lab execute the native product path'],
    }, {
      id: 'examples',
      state: 'verified',
      closureEvidence: ['public examples compile through the native binary and Zig API'],
    }, {
      id: 'guides-and-compatibility',
      state: 'verified',
      closureEvidence: ['machine capability rows and guides agree with native evidence'],
    }, {
      id: 'changelog-and-migration-notes',
      state: 'verified',
      closureEvidence: ['changelog and migration notes retain oracle and plugin boundaries'],
    }],
  })
  assert.deepEqual(contract.releaseGraduation, expectedReleaseGraduation)
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
    'native-product-compiler',
  ])
  assert.deepEqual(contract.productRouting, {
    ownerPackage: 'NATIVE-006',
    releaseGapFamily: 'native-product-routing',
    state: 'closed',
    packageState: 'verified',
    terminalContract: {
      adapters: ['scss', 'sass', 'less', 'stylus'],
      surfaces: [
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
      ],
      providerProcesses: 0,
    },
    routes: [{
      id: 'shared-native-compiler',
      releaseGapFamily: 'native-shared-compiler-routing',
      state: 'verified',
      evidenceTests: [
        'native compiler routes every private frontend through one deterministic transaction',
        'native compiler owns source terminal limits without partial results',
        'native compiler rejects invalid roots and language failures without a result',
        'native compiler route handles every allocation failure',
      ],
    }, {
      id: 'zig-api',
      releaseGapFamily: 'native-zig-api-routing',
      state: 'verified',
      evidenceTests: [
        'external Zig API routes the finite native syntax set through owned CSS results',
        'external Zig API preserves exact input resource limits without partial results',
        'external Zig API rejects invalid roots paths and language failures',
        'external Zig API route handles every allocation failure',
      ],
    }, {
      id: 'binary-cli',
      releaseGapFamily: 'native-binary-cli-routing',
      state: 'verified',
      evidenceTests: [
        'binary CLI routes the finite native syntax set through the pre-graduation bridge',
        'binary CLI keeps native routing explicit and pending execution modes fail closed',
        'binary CLI native failures commit no partial output',
      ],
    }, {
      id: 'javascript-wrapper',
      releaseGapFamily: 'native-javascript-wrapper-routing',
      state: 'verified',
      evidenceTests: [
        'javascript wrapper routes the finite native syntax set through the installed binary',
        'javascript wrapper keeps native routing explicit and ungated preprocessors fail closed',
      ],
    }, {
      id: 'files-and-stdin',
      releaseGapFamily: 'native-files-stdin-routing',
      state: 'verified',
      evidenceTests: [
        'binary CLI routes the finite native syntax set through the pre-graduation bridge',
        'binary CLI routes the finite native syntax set from stdin',
        'binary CLI native stdin confines imports and commits no partial output',
        'binary CLI native stdin enforces the exact input byte terminal',
      ],
    }, {
      id: 'batch',
      releaseGapFamily: 'native-batch-routing',
      state: 'verified',
      evidenceTests: [
        'binary CLI routes the finite native syntax set through deterministic batches',
        'binary CLI native batch failures commit no partial output',
      ],
    }, {
      id: 'watch',
      releaseGapFamily: 'native-watch-routing',
      state: 'verified',
      evidenceTests: [
        'external Zig API owns opaque watch snapshots and detects one transition',
        'binary CLI native watch invalidates the finite syntax dependency set',
        'binary CLI native watch failures retain output and recover once',
        'binary CLI native watch rejects entry link substitution and recovers',
      ],
    }, {
      id: 'parallel',
      releaseGapFamily: 'native-parallel-routing',
      state: 'verified',
      evidenceTests: [
        'binary CLI routes the finite native syntax set through the bounded parallel queue',
        'binary CLI native parallel failure cancels queued work without partial output',
      ],
    }, {
      id: 'diagnostics-and-dependencies',
      releaseGapFamily: 'native-result-facts-routing',
      state: 'verified',
      evidenceTests: [
        'external Zig API owns native diagnostics and dependency facts',
        'external Zig API returns structured native failures without partial facts',
        'binary CLI renders structured native diagnostics without partial output',
        'javascript wrapper preserves native diagnostic streams and exit status',
      ],
    }, {
      id: 'source-maps',
      releaseGapFamily: 'native-source-map-routing',
      state: 'verified',
      evidenceTests: [
        'external Zig API composes deterministic source maps for the finite native syntax set',
        'external Zig API composes imported Unicode source positions without intermediate leaks',
        'binary CLI routes composed native source maps through files stdin and parallel batches',
        'binary CLI native watch atomically replaces CSS and its composed source map',
        'javascript wrapper routes the finite native syntax set through the installed binary',
      ],
    }],
  })
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
    state: 'closed',
    packageState: 'verified',
    oracle: {
      id: 'stylus',
      package: 'stylus',
      version: '0.64.0',
      selection: 'tests/preprocessors/stylus/corpus/selection.json',
      manifest: 'tests/preprocessors/stylus/corpus/manifest.json',
      caseCount: 346,
    },
    completedCaseCount: 346,
    remainingCaseCount: 0,
    terminalContract: {
      selectionDerived: true,
      successCaseCount: 326,
      errorCaseCount: 20,
      exactSuccessCount: 326,
      nonconformingSuccessCount: 0,
      exactSuccessCaseIdWyhash: '3b55c78d94378874',
      deterministicRunsPerSuccessCase: 2,
      fuzzMutationsPerCase: 3,
      maxConcurrentCompilations: 4,
      evidenceTests: [
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
    contract => { contract.stylusConformance.completedCaseCount = 212 },
    contract => { contract.stylusConformance.remainingCaseCount = 134 },
    contract => { contract.stylusConformance.terminalContract.successCaseCount = 325 },
    contract => { contract.stylusConformance.terminalContract.selectionDerived = false },
    contract => { contract.stylusConformance.terminalContract.exactSuccessCount = 192 },
    contract => { contract.stylusConformance.terminalContract.nonconformingSuccessCount = 134 },
    contract => { contract.stylusConformance.terminalContract.exactSuccessCaseIdWyhash = '7146b1a62ee0a431' },
    contract => { contract.stylusConformance.terminalContract.evidenceTests.pop() },
    contract => { contract.stylusConformance.gates.corpusDifferential = 'in-progress' },
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

test('binds differential native adapter rows while release claims remain closed', () => {
  const adapterClaim = clone(loadContract())
  adapterClaim.adapters[1].current = 'native-graduated'
  assert.throws(() => validateContract(adapterClaim), /must remain native-differential/)

  const staleAdapter = clone(loadContract())
  staleAdapter.adapters[1].current = 'reference-only'
  assert.throws(() => validateContract(staleAdapter), /must remain native-differential/)

  const releaseClaim = clone(loadContract())
  releaseClaim.nativeReleaseReady = true
  assert.throws(() => validateContract(releaseClaim), /native release must remain fail-closed/)

  const sourceClaim = clone(loadContract())
  sourceClaim.adapters[1].nativeSources.pop()
  assert.throws(() => validateContract(sourceClaim), /native source inventory drifted/)
})

test('binds the finite NATIVE-008 capability graduation terminal', () => {
  for (const mutate of [
    graduation => { graduation.ownerPackage = 'NATIVE-009' },
    graduation => { graduation.releaseGapFamily = 'renamed-capability-family' },
    graduation => { graduation.state = 'in-progress' },
    graduation => { graduation.packageState = 'in-progress' },
    graduation => graduation.terminalContract.adapters.pop(),
    graduation => graduation.terminalContract.surfaces.reverse(),
    graduation => { graduation.terminalContract.pluginParity = true },
    graduation => { graduation.gates[0].state = 'pending' },
    graduation => { graduation.gates[1].state = 'pending' },
    graduation => { graduation.gates[3].state = 'pending' },
    graduation => { graduation.gates[4].state = 'pending' },
    graduation => { graduation.gates[5].state = 'pending' },
    graduation => { graduation.gates[6].state = 'pending' },
    graduation => graduation.gates.push(structuredClone(graduation.gates[0])),
  ]) {
    const changed = clone(loadContract())
    mutate(changed.capabilityGraduation)
    assert.throws(() => validateContract(changed), /capability graduation contract drifted/)
  }

  const nativeExampleSources = Object.fromEntries([
    'examples/native/styles.css',
    'examples/native/styles.scss',
    'examples/native/styles.sass',
    'examples/native/styles.less',
    'examples/native/styles.styl',
  ].map(relativePath => [
    relativePath,
    fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8'),
  ]))
  delete nativeExampleSources['examples/native/styles.styl']
  assert.throws(
    () => validateContract(loadContract(), { nativeExampleSources }),
    /native binary example inventory drifted from its finite terminal set/,
  )

  const buildFile = fs.readFileSync(path.join(repositoryRoot, 'build.zig'), 'utf8')
  assert.throws(
    () => validateContract(loadContract(), {
      buildFile: buildFile.replace(
        'b.path("examples/native/styles.styl")',
        'b.path("examples/native/styles.next")',
      ),
    }),
    /native binary example build row examples\/native\/styles\.styl is missing/,
  )

  const nativeApiExample = fs.readFileSync(
    path.join(repositoryRoot, 'examples/native_api.zig'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      nativeApiExample: nativeApiExample.replace('inline for (examples)', 'for (examples)'),
    }),
    /parameterized native Zig API example execution is missing/,
  )

  const documentationPolicy = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'docs/documentation-validation.json'),
    'utf8',
  ))
  documentationPolicy.executableZigExamples = documentationPolicy.executableZigExamples.filter(
    relativePath => relativePath !== 'examples/native_api.zig',
  )
  assert.throws(
    () => validateContract(loadContract(), { documentationPolicy }),
    /documentation executable Zig example inventory drifted/,
  )

  const formatMatrix = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'tests/formats/matrix.json'),
    'utf8',
  ))
  formatMatrix.adapters.find(row => row.id === 'less').compatibility = 'Unverified'
  assert.throws(
    () => validateContract(loadContract(), { formatMatrix }),
    /format matrix native capability state drifted for less/,
  )

  const capabilityMetadata = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'docs/src/data/capabilities.json'),
    'utf8',
  ))
  capabilityMetadata.capabilities.find(row => row.id === 'scss').status = 'Experimental'
  assert.throws(
    () => validateContract(loadContract(), { capabilityMetadata }),
    /capability metadata native status drifted for scss/,
  )

  for (const [field, relativePath, needle, replacement, expectedError] of [
    [
      'formatGuide',
      'docs/src/content/docs/guide/format-compatibility.md',
      'These exact providers are development-only reference oracles.',
      'These providers run in production.',
      /format compatibility guide is missing/,
    ],
    [
      'statusGuide',
      'docs/src/content/docs/guide/status.md',
      'The package JavaScript wrapper only locates and invokes that binary',
      'The package JavaScript wrapper hosts every language',
      /status guide is missing/,
    ],
    [
      'recoveryGuide',
      'docs/src/content/docs/guide/recovery-cli.md',
      'They do not run during compilation',
      'They run during compilation',
      /native CLI guide is missing/,
    ],
    [
      'buildGuide',
      'docs/src/content/docs/guide/build-from-source.md',
      'const native = zigcss.experimental_native;',
      'const native = zigcss;',
      /build-from-source guide native Zig API example drifted/,
    ],
    [
      'changelog',
      'CHANGELOG.md',
      'remain exact development-only reference oracles and do not run during compilation',
      'remain production runtime dependencies',
      /changelog migration notes is missing/,
    ],
  ]) {
    const source = fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8')
    const changed = source.replace(needle, replacement)
    assert.notEqual(changed, source, `${relativePath} fixture is missing ${JSON.stringify(needle)}`)
    assert.throws(
      () => validateContract(loadContract(), { [field]: changed }),
      expectedError,
    )
  }
})

test('binds the finite NATIVE-009 candidate and hosted-validation evidence', () => {
  const contract = loadContract()
  assert.deepEqual(contract.releaseGraduation, expectedReleaseGraduation)

  for (const mutate of [
    release => { release.ownerPackage = 'NATIVE-008' },
    release => { release.releaseGapFamily = 'renamed-release-family' },
    release => { release.state = 'closed' },
    release => { release.packageState = 'verified' },
    release => { release.candidateVersion = '0.6.0-rc.3' },
    release => { release.candidateTag = 'v0.6.0-rc.3' },
    release => { release.candidateSelection.githubTagStateAtSelection = 'present' },
    release => { release.candidateSelection.observedPublishedNpmVersions.push('0.6.0-rc.2') },
    release => release.terminalContract.syntaxes.pop(),
    release => release.terminalContract.targets.reverse(),
    release => release.terminalContract.preTagSurfaces.reverse(),
    release => release.terminalContract.postTagSurfaces.push('npm-latest'),
    release => { release.terminalContract.referenceCandidateEligible = true },
    release => { release.gates[0].state = 'pending' },
    release => { release.gates[1].state = 'pending' },
    release => { release.gates[2].state = 'pending' },
    release => { release.gates[3].state = 'pending' },
    release => release.gates.push(clone(release.gates[0])),
  ]) {
    const changed = clone(contract)
    mutate(changed.releaseGraduation)
    assert.throws(() => validateContract(changed), /release graduation contract drifted/)
  }

  const ready = clone(contract)
  ready.nativeReleaseReady = true
  ready.nativeReleaseVersion = '0.6.0-rc.2'
  assert.throws(
    () => validateReleaseTag(ready, 'v0.6.0-rc.2'),
    /release evidence is incomplete/,
  )

  const buildWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/build.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(contract, {
      buildWorkflow: buildWorkflow.replace('name: Native Package Evidence', 'name: Missing Evidence'),
    }),
    /hosted aggregate package evidence is missing/,
  )

  const releaseWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/release.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(contract, {
      releaseWorkflow: releaseWorkflow.replace('needs: create-release', 'needs: release'),
    }),
    /npm publication dependency on GitHub prerelease is missing/,
  )
})

test('binds stable binary help to executable finite syntax evidence', () => {
  const missingEvidence = fs
    .readFileSync(path.join(repositoryRoot, 'tests/cli/native_cli.zig'), 'utf8')
    .replace(
      'test "stable native syntax selection and help agree with executable CLI tests"',
      'test "removed stable native CLI evidence"',
    )
  assert.throws(
    () => validateContract(loadContract(), { cliTests: missingEvidence }),
    /stable native CLI executable evidence is missing/,
  )

  const staleHelp = loadProductionSources().map(([relativePath, source]) => [
    relativePath,
    relativePath === 'src/main.zig'
      ? source.replace(
        '--syntax <syntax>        Select css (default), scss, sass, less, or stylus',
        '--syntax <syntax>        Select CSS (default), or a gated native syntax',
      )
      : source,
  ])
  assert.throws(
    () => validateContract(loadContract(), { productionSources: staleHelp }),
    /stable native syntax help is missing/,
  )

  const staleGate = loadProductionSources().map(([relativePath, source]) => [
    relativePath,
    relativePath === 'src/main.zig'
      ? source.replace(
        'if (native_syntax != null) {',
        'if (native_syntax != null) {\n        // the native route requires --experimental-native',
      )
      : source,
  ])
  assert.throws(
    () => validateContract(loadContract(), { productionSources: staleGate }),
    /stable native syntax selection still requires the experimental gate/,
  )
})

test('binds the README to the exact self-contained native source snapshot', () => {
  const readme = fs.readFileSync(path.join(repositoryRoot, 'README.md'), 'utf8')
  for (const [needle, replacement, expectedError] of [
    [
      'The current source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths.',
      'The current source snapshot compiles CSS through a native Zig path.',
      /README native five-language source snapshot is missing/,
    ],
    [
      'Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles.',
      'Canonical providers remain available at runtime.',
      /README development-only oracle boundary is missing/,
    ],
    [
      'zero `dependencies` and zero `optionalDependencies`',
      'a bounded production dependency graph',
      /README zero production dependency boundary is missing/,
    ],
    [
      'The compiler itself starts no child process, performs no network access, and requires no runtime download.',
      'Compilation may start a provider process.',
      /README zero-runtime compilation boundary is missing/,
    ],
    [
      '| SCSS (`.scss`) | Native Sass-family parser/evaluator | `native-differential` |',
      '| SCSS (`.scss`) | Canonical provider | Planned |',
      /README SCSS native-differential row is missing/,
    ],
    [
      '| Sass (`.sass`) | Native Sass-family parser/evaluator | `native-differential` |',
      '| Sass (`.sass`) | Canonical provider | Planned |',
      /README Sass native-differential row is missing/,
    ],
    [
      '| Less (`.less`) | Native Less parser/evaluator | `native-differential` |',
      '| Less (`.less`) | Canonical provider | Planned |',
      /README Less native-differential row is missing/,
    ],
    [
      '| Stylus (`.styl`) | Native Stylus parser/evaluator | `native-differential` |',
      '| Stylus (`.styl`) | Canonical provider | Planned |',
      /README Stylus native-differential row is missing/,
    ],
    [
      'zig-out/bin/zigcss --syntax stylus styles.styl -o dist/styles.css --minify',
      'node index.js styles.styl -o dist/styles.css --minify',
      /README explicit native syntax commands is missing/,
    ],
    [
      'Arbitrary Sass plugins, custom functions and importers, Less JavaScript and plugins, Stylus plugins and evaluator hooks, and executable project code remain outside the native product contract.',
      'Provider plugins may be loaded by the native compiler.',
      /README native plugin boundary is missing/,
    ],
    [
      '`nativeReleaseReady: false`',
      '`nativeReleaseReady: true`',
      /README closed native release interlock is missing/,
    ],
  ]) {
    const changed = readme.replace(needle, replacement)
    assert.notEqual(changed, readme, `README fixture is missing ${JSON.stringify(needle)}`)
    assert.throws(
      () => validateContract(loadContract(), { readme: changed }),
      expectedError,
    )
  }

  assert.throws(
    () => validateContract(loadContract(), {
      readme: `${readme}\nThe four preprocessor frontends are moving through private native conformance gates.\n`,
    }),
    /README retains stale provider-era source claims/,
  )
})

test('binds website claims and the recorded lab to the native product path', () => {
  const websiteSources = Object.fromEntries([
    'docs/src/app/components/Home.tsx',
    'docs/src/app/components/GettingStarted.tsx',
    'docs/src/app/components/Convergence.tsx',
    'docs/src/app/components/FormatShowcase.tsx',
    'docs/src/app/components/Features.tsx',
    'docs/src/app/components/Playground.tsx',
  ].map(relativePath => [
    relativePath,
    fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8'),
  ]))
  const formatExamples = JSON.parse(fs.readFileSync(
    path.join(repositoryRoot, 'docs/src/data/format-examples.json'),
    'utf8',
  ))
  const siteExamplesTests = fs.readFileSync(
    path.join(repositoryRoot, 'tests/preprocessors/product/site-examples.test.mjs'),
    'utf8',
  )

  for (const [relativePath, needle, replacement, expectedError] of [
    [
      'docs/src/app/components/Home.tsx',
      'All five source inputs run through self-contained native Zig frontends.',
      'Only CSS runs through a native Zig frontend.',
      /website native five-language source claim is missing/,
    ],
    [
      'docs/src/app/components/GettingStarted.tsx',
      'Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles; they do not run during compilation.',
      'Canonical providers run during compilation.',
      /website development-only oracle boundary is missing/,
    ],
    [
      'docs/src/app/components/Convergence.tsx',
      'Native frontends feed one fail-closed Zig core.',
      'Exact pinned providers feed one fail-closed Zig core.',
      /website native convergence claim is missing/,
    ],
    [
      'docs/src/app/components/FormatShowcase.tsx',
      'Every recorded fixture is executed by the source-built native ZigCSS binary.',
      'Every recorded fixture is executed by the canonical provider host.',
      /website native lab claim is missing/,
    ],
    [
      'docs/src/app/components/Features.tsx',
      'The compatibility table below records the closed NATIVE-008 native-differential source snapshot; release graduation remains fail-closed under NATIVE-009.',
      'The compatibility table describes an unbounded future product path.',
      /website closed compatibility boundary is missing/,
    ],
  ]) {
    const changed = { ...websiteSources }
    changed[relativePath] = changed[relativePath].replaceAll(needle, replacement)
    assert.notEqual(changed[relativePath], websiteSources[relativePath], `website fixture is missing ${JSON.stringify(needle)}`)
    assert.throws(
      () => validateContract(loadContract(), { websiteSources: changed }),
      expectedError,
    )
  }

  const changedExamples = structuredClone(formatExamples)
  changedExamples[1].frontend = 'Dart Sass 1.101.0'
  assert.throws(
    () => validateContract(loadContract(), { formatExamples: changedExamples }),
    /website native lab metadata drifted/,
  )

  const hostRoutedTest = siteExamplesTests.replace(
    "spawnSync(binaryPath, ['-', '--syntax', example.id, '--minify'],",
    'compileStringWithRuntime(example.input,',
  )
  assert.notEqual(hostRoutedTest, siteExamplesTests, 'native site-lab executable fixture is missing')
  assert.throws(
    () => validateContract(loadContract(), { siteExamplesTests: hostRoutedTest }),
    /website lab native executable evidence is missing/,
  )
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

test('binds internal native implementations behind the differential product bridge', () => {
  for (const index of loadContract().implementations.keys()) {
    const publicChanged = clone(loadContract())
    publicChanged.implementations[index].publicAvailable = true
    assert.throws(() => validateContract(publicChanged), /implementation.*inventory drifted/)

    const productionChanged = clone(loadContract())
    productionChanged.implementations[index].productionReachable = index !== 9
    assert.throws(() => validateContract(productionChanged), /implementation.*inventory drifted/)
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
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/lib.zig'
          ? `${source}\nconst sass = @import("preprocessor/sass.zig");\n`
          : source,
      ]),
    }),
    /makes the unavailable native frontend production-reachable/,
  )

  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? `${source}\nconst sass = @import("preprocessor/sass.zig");\n`
          : source,
      ]),
    }),
    /native Zig API bridge import inventory drifted/,
  )

  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? source.replace('.source_map = options.source_map,', '.source_map = false,')
          : source,
      ]),
    }),
    /native Zig API source-map request promotion.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? source.replace('compiled.composeSourceMap(allocator)', 'missingSourceMap(allocator)')
          : source,
      ]),
    }),
    /native Zig API composed source-map promotion.*missing/,
  )
})

test('binds the finite native product routing inventory and verified closed package', () => {
  for (const mutate of [
    routing => { routing.state = 'in-progress' },
    routing => { routing.packageState = 'in-progress' },
    routing => routing.terminalContract.surfaces.reverse(),
    routing => routing.terminalContract.adapters.pop(),
    routing => { routing.terminalContract.providerProcesses = 1 },
    routing => { routing.routes[0].state = 'pending' },
    routing => { routing.routes[1].state = 'pending' },
    routing => { routing.routes[2].state = 'pending' },
    routing => { routing.routes[3].state = 'pending' },
    routing => { routing.routes[4].state = 'pending' },
    routing => { routing.routes[5].state = 'pending' },
    routing => { routing.routes[6].state = 'pending' },
    routing => { routing.routes[7].state = 'pending' },
    routing => { routing.routes[8].state = 'pending' },
    routing => { routing.routes[9].state = 'pending' },
    routing => routing.routes.push(clone(routing.routes[0])),
  ]) {
    const changed = clone(loadContract())
    mutate(changed.productRouting)
    assert.throws(() => validateContract(changed), /product routing.*drifted/)
  }

  const sassConformanceTests = fs.readFileSync(
    path.join(repositoryRoot, 'tests/native-preprocessor/sass_conformance.zig'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      sassConformanceTests: sassConformanceTests.replace(
        'return compiler.compile(',
        'return missing_route.compile(',
      ),
    }),
    /native product routing Sass conformance.*missing/,
  )

  const zigApiTests = fs.readFileSync(
    path.join(repositoryRoot, 'tests/public-api/native_consumer.zig'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      zigApiTests: zigApiTests.replace(
        'test "external Zig API route handles every allocation failure"',
        'test "missing external allocation evidence"',
      ),
    }),
    /native product routing zig-api evidence.*missing/,
  )

  for (const [needle, replacement, expected] of [
    ['compiled.nativeDiagnostics(),', '&.{},', /diagnostic promotion.*missing/],
    [
      'cloneDependencies(allocator, compiled.dependencies())',
      'cloneDependencies(allocator, &.{})',
      /dependency promotion.*missing/,
    ],
  ]) {
    assert.throws(
      () => validateContract(loadContract(), {
        productionSources: loadProductionSources().map(([relativePath, source]) => [
          relativePath,
          relativePath === 'src/native_api.zig'
            ? source.replace(needle, replacement)
            : source,
        ]),
      }),
      expected,
    )
  }
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/preprocessor/sass_evaluator.zig'
          ? source.replace(
            'parsed.url,\n            &configuration,\n            .forward,\n            node.span,',
            'parsed.url,\n            &configuration,\n            .use,\n            node.span,',
          )
          : source,
      ]),
    }),
    /native Sass forward dependency kind.*missing/,
  )

  const cliTests = fs.readFileSync(
    path.join(repositoryRoot, 'tests/cli/native_cli.zig'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native failures commit no partial output"',
        'test "missing binary CLI rollback evidence"',
      ),
    }),
    /native product routing binary-cli evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/main.zig'
          ? source.replaceAll(
            'printNativeDiagnostics(result.diagnostics);',
            'discardNativeDiagnostics(result.diagnostics);',
          )
          : source,
      ]),
    }),
    /structured diagnostic rendering.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native stdin enforces the exact input byte terminal"',
        'test "missing native stdin terminal evidence"',
      ),
    }),
    /native product routing files-and-stdin evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native batch failures commit no partial output"',
        'test "missing native batch rollback evidence"',
      ),
    }),
    /native product routing batch evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native watch failures retain output and recover once"',
        'test "missing native watch recovery evidence"',
      ),
    }),
    /native product routing watch evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native parallel failure cancels queued work without partial output"',
        'test "missing native parallel rollback evidence"',
      ),
    }),
    /native product routing parallel evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      zigApiTests: zigApiTests.replace(
        'test "external Zig API composes imported Unicode source positions without intermediate leaks"',
        'test "missing composed Unicode map evidence"',
      ),
    }),
    /native product routing source-maps evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'test "binary CLI native watch atomically replaces CSS and its composed source map"',
        'test "missing native mapped watch evidence"',
      ),
    }),
    /native product routing source-maps evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      cliTests: cliTests.replace(
        'const native_parallel_worker_cap = 8;',
        'const native_parallel_worker_cap = 9;',
      ),
    }),
    /native product routing parallel worker terminal.*missing/,
  )

  const nodeWrapperTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/verify-node-wrapper.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      nodeWrapperTests: nodeWrapperTests.replace(
        "test('javascript wrapper keeps native routing explicit and ungated preprocessors fail closed'",
        "test('missing JavaScript wrapper route evidence'",
      ),
    }),
    /native product routing javascript-wrapper evidence.*missing/,
  )

  const nodeWrapperSource = fs.readFileSync(path.join(repositoryRoot, 'index.js'), 'utf8')
  assert.throws(
    () => validateContract(loadContract(), {
      nodeWrapperSource: nodeWrapperSource.replace(
        'runNative(binaryPath, args);',
        'missingNativeDispatch(binaryPath, args);',
      ),
    }),
    /JavaScript wrapper binary dispatch.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      nodeWrapperTests: nodeWrapperTests.replace("'--source-map',", "'--source-map-missing',"),
    }),
    /JavaScript wrapper source-map forwarding.*missing/,
  )

  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/preprocessor/sourcemap.zig'
          ? source.replace('const inner = frontend.lookup(', 'const inner = missingLookup(')
          : source,
      ]),
    }),
    /native source-map greatest-lower-bound tracing.*missing/,
  )

  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/main.zig'
          ? source.replace(
            'const stdin_root = if (isStdioPath(input_file))',
            'const stdin_root = null',
          )
          : source,
      ]),
    }),
    /native binary CLI confined stdin root.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/main.zig'
          ? source.replace(
            'std.Thread.spawn(.{}, nativeBatchWorker, .{&queue})',
            'missingNativeThreadSpawn(.{}, nativeBatchWorker, .{&queue})',
          )
          : source,
      ]),
    }),
    /native binary CLI parallel thread spawn.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/main.zig'
          ? source.replace(
            'const NativeBatchTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });',
            'const NativeBatchTaskAllocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true });',
          )
          : source,
      ]),
    }),
    /native binary CLI parallel independent task allocator.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? source.replace(
            'const bytes = dependencySourceBytes(compiled, dependency.url)',
            'const bytes = duplicateDependencyRead(dependency.url)',
          )
          : source,
      ]),
    }),
    /watch snapshot compiler-owned bytes.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? source.replace(
            'var loaded = session.load(item.url,',
            'const loaded = std.fs.cwd().readFileAlloc(item.url,',
          )
          : source,
      ]),
    }),
    /confined watch polling.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/native_api.zig'
          ? source.replace(
            'var loaded = session.load(self.entry_url,',
            'const loaded = std.fs.cwd().readFileAlloc(self.entry_url,',
          )
          : source,
      ]),
    }),
    /confined watch entry reload.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      productionSources: loadProductionSources().map(([relativePath, source]) => [
        relativePath,
        relativePath === 'src/main.zig'
          ? source.replace('fn watchNativeFile(', 'fn watchNativeFile(/* std.Thread.spawn */')
          : source,
      ]),
    }),
    /native binary CLI watch crossed a duplicate-read or pending parallel boundary/,
  )
})

test('owns the finite native zero-dependency package migration contract', () => {
  const contract = loadContract()
  assert.equal(contract.schemaVersion, 9)
  assert.deepEqual(contract.packageMigration, {
    ownerPackage: 'NATIVE-007',
    releaseGapFamily: 'native-zero-dependency-package',
    state: 'closed',
    packageState: 'verified',
    terminalContract: {
      surfaces: [
        'production-package-closure',
        'direct-archive-offline-package',
        'runtime-process-network-tracing',
        'five-native-targets',
        'release-sbom-provenance',
        'consumer-behavior',
      ],
    },
    gates: [
      {
        id: 'production-package-closure',
        state: 'verified',
        evidenceTests: [
          'native npm package has zero production and optional dependencies',
          'native npm archive excludes provider host and JavaScript API bytes',
          'javascript wrapper cannot reach the provider host',
        ],
      },
      {
        id: 'direct-archive-offline-package',
        state: 'verified',
        evidenceTests: [
          'direct native archive compiles the finite five-language syntax set',
          'offline installed native package compiles the finite five-language syntax set',
        ],
      },
      {
        id: 'runtime-process-network-tracing',
        state: 'verified',
        evidenceTests: [
          'direct native archive runtime trace admits one native child and zero network access',
          'offline installed native package runtime trace admits one native child and zero network access',
        ],
      },
      {
        id: 'five-native-targets',
        state: 'verified',
        evidenceTests: [
          'native smoke policy covers every release target on one matching runner',
          'native smoke builds a canonical commit-bound five-target receipt',
          'build matrix uploads one commit-bound native receipt from every matching runner',
          'native smoke validates one closed commit-bound receipt set across every release target',
          'build aggregates every matching runner receipt before package verification',
        ],
      },
      {
        id: 'release-sbom-provenance',
        state: 'verified',
        evidenceTests: [
          'release metadata is deterministic, bounded SPDX 2.3 with exact SHA-256 subjects',
          'local Sigstore bundles bind exact subjects and predicates before cryptographic verification',
          'release workflow generates, signs, verifies, and uploads the closed five-target inventory',
        ],
      },
      {
        id: 'consumer-behavior',
        state: 'verified',
        evidenceTests: [
          'npm installer derives exactly the release workflow asset contract',
          'npm installer independently validates all five executable target headers',
          'npm package runs one installer lifecycle and CI gates it before dependency installation',
        ],
      },
    ],
  })

  for (const mutate of [
    migration => { migration.state = 'in-progress' },
    migration => { migration.packageState = 'in-progress' },
    migration => migration.terminalContract.surfaces.reverse(),
    migration => { migration.gates[0].state = 'pending' },
    migration => { migration.gates[1].state = 'pending' },
    migration => { migration.gates[2].state = 'pending' },
    migration => { migration.gates[3].state = 'pending' },
    migration => { migration.gates[4].state = 'pending' },
    migration => { migration.gates[5].state = 'pending' },
    migration => migration.gates.push(clone(migration.gates[0])),
  ]) {
    const changed = clone(loadContract())
    mutate(changed.packageMigration)
    assert.throws(() => validateContract(changed), /native package migration.*drifted/)
  }

  const packageTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/validate-preprocessor-package.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      packageTests: packageTests.replace(
        "test('native npm archive excludes provider host and JavaScript API bytes'",
        "test('missing package archive evidence'",
      ),
    }),
    /native package migration production-package-closure evidence.*missing/,
  )

  const releaseSmokeTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/smoke-release-artifact.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokeTests: releaseSmokeTests.replace(
        "test('direct native archive compiles the finite five-language syntax set'",
        "test('missing direct archive evidence'",
      ),
    }),
    /native package migration direct-archive-offline-package evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokeTests: releaseSmokeTests.replace(
        "test('direct native archive runtime trace admits one native child and zero network access'",
        "test('missing direct runtime trace evidence'",
      ),
    }),
    /native package migration runtime-process-network-tracing evidence.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokeTests: releaseSmokeTests.replace(
        "test('native smoke builds a canonical commit-bound five-target receipt'",
        "test('missing native target receipt evidence'",
      ),
    }),
    /native package migration five-native-targets evidence.*missing/,
  )

  const nativePackageEvidenceTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/validate-native-package-evidence.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      nativePackageEvidenceTests: nativePackageEvidenceTests.replace(
        "test('native smoke validates one closed commit-bound receipt set across every release target'",
        "test('missing aggregate native target evidence'",
      ),
    }),
    /native package migration five-native-targets evidence.*missing/,
  )

  const releaseMetadataTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/generate-release-metadata.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseMetadataTests: releaseMetadataTests.replace(
        "test('release workflow generates, signs, verifies, and uploads the closed five-target inventory'",
        "test('missing release provenance evidence'",
      ),
    }),
    /native package migration release-sbom-provenance evidence.*missing/,
  )

  const releaseConsumerTests = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/verify-release-consumers.test.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseConsumerTests: releaseConsumerTests.replace(
        "test('npm installer independently validates all five executable target headers'",
        "test('missing native consumer target evidence'",
      ),
    }),
    /native package migration consumer-behavior evidence.*missing/,
  )

  const releaseSmokeSource = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/smoke-release-artifact.mjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokeSource: releaseSmokeSource.replace(
        'export function writeNativeTargetEvidence(',
        'function missingNativeTargetEvidenceWrite(',
      ),
    }),
    /native package migration five-target receipt write.*missing/,
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokeSource: releaseSmokeSource.replace(
        'validateRuntimeTrace(directRuntimeTrace, 6,',
        'missingDirectRuntimeTrace(directRuntimeTrace, 6,',
      ),
    }),
    /native package migration direct archive runtime trace.*missing/,
  )

  const releaseSmokePreloadSource = fs.readFileSync(
    path.join(repositoryRoot, 'scripts/release-smoke-preload.cjs'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), {
      releaseSmokePreloadSource: releaseSmokePreloadSource.replace(
        'childProcess.spawn = function tracedNativeSpawn',
        'childProcess.spawn = function missingNativeTrace',
      ),
    }),
    /native package migration admitted native child trace.*missing/,
  )

  for (const [kind, primitive] of [
    ['process', 'std.process.Child'],
    ['network', 'std.net'],
    ['foreign runtime', 'std.DynLib'],
  ]) {
    assert.throws(
      () => validateContract(loadContract(), {
        productionSources: loadProductionSources().map(([relativePath, source]) => [
          relativePath,
          relativePath === 'src/preprocessor/compiler.zig'
            ? `${source}\nconst leaked_runtime = ${primitive};\n`
            : source,
        ]),
      }),
      new RegExp(`native package migration runtime closure contains forbidden ${kind} primitive ${primitive.replaceAll('.', '\\.')}`),
    )
  }

  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  manifest.exports['./api'] = './api.mjs'
  assert.throws(
    () => validateContract(loadContract(), { manifest }),
    /native package migration export inventory drifted/,
  )
})

test('binds canonical providers only as exact development-oracle evidence', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  manifest.devDependencies = { ...manifest.devDependencies, sass: '^1.101.0' }
  assert.throws(
    () => validateContract(loadContract(), { manifest }),
    /development oracle graph drifted|development-only canonical reference dependency graph drifted/,
  )

  manifest.devDependencies.sass = '1.101.0'
  manifest.dependencies = { sass: '1.101.0' }
  assert.throws(
    () => validateContract(loadContract(), { manifest }),
    /production dependency closure is not empty|production dependency graph is not empty/,
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
  const contract = makeReleaseReady()
  assert.doesNotThrow(() => validateReleaseTag(contract, 'v0.6.0-rc.2'))
  assert.throws(
    () => validateReleaseTag(contract, 'v0.6.0-rc.1'),
    /does not match the graduated native version/,
  )

  const missingGate = makeReleaseReady()
  missingGate.releaseGraduation.gates.find(gate => gate.id === 'local-validation').state = 'pending'
  assert.throws(
    () => validateReleaseTag(missingGate, 'v0.6.0-rc.2'),
    /native release evidence is incomplete/,
  )

  const duplicatedGate = makeReleaseReady()
  duplicatedGate.releaseGraduation.gates.push(clone(duplicatedGate.releaseGraduation.gates[0]))
  assert.throws(
    () => validateReleaseTag(duplicatedGate, 'v0.6.0-rc.2'),
    /native release evidence is incomplete/,
  )

  const ungraduatedAdapter = makeReleaseReady()
  ungraduatedAdapter.adapters[1].current = 'native-differential'
  assert.throws(
    () => validateReleaseTag(ungraduatedAdapter, 'v0.6.0-rc.2'),
    /native release evidence is incomplete/,
  )

  contract.nativePublicationAuthority.authorized = false
  assert.throws(
    () => validateReleaseTag(contract, 'v0.6.0-rc.2'),
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
      'node scripts/run-zig-test-suite.mjs --mode Debug',
      'zig build test-native-preprocessor --summary all',
    ) }),
    /build workflow is missing.*run-zig-test-suite\.mjs --mode Debug/,
  )
  assert.throws(
    () => validateContract(loadContract(), { buildWorkflow: buildWorkflow.replace(
      'node scripts/run-zig-test-suite.mjs --mode Debug',
      'zig build test-native-preprocessor --summary all\n        run: node scripts/run-zig-test-suite.mjs --mode Debug',
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
