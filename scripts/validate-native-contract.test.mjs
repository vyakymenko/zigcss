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

test('accepts the closed native Sass implementation contract', () => {
  const contract = validateContract(loadContract())
  assert.equal(contract.schemaVersion, 4)
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
  ])
  const sassCore = contract.implementations[1]
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
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-blackness-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-mix-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-lighten-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-darken-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-saturate-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-desaturate-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-adjust-hue-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-complement-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-grayscale-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-invert-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-opacify-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-fade-in-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-transparentize-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-fade-out-function-invocation'), true)
  assert.equal(sassCore.capabilities.includes('built-in-meta-color-ie-hex-str-function-invocation'), true)
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

test('binds unavailable native Sass internals without admitting product reachability', () => {
  for (const index of [0, 1]) {
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

test('requires the focused native frontend foundation gate in build CI', () => {
  const buildWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/build.yml'),
    'utf8',
  )
  assert.throws(
    () => validateContract(loadContract(), { buildWorkflow: buildWorkflow.replace(
      'zig build test-native-preprocessor --summary all',
      'zig build test --summary all',
    ) }),
    /build workflow is missing.*test-native-preprocessor/,
  )
})
