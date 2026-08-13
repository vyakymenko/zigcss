import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateCssModules } from './css_modules_validate.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const scriptDirectory = path.dirname(scriptPath)
const repositoryRoot = path.resolve(scriptDirectory, '../..')
const matrixPath = path.join(scriptDirectory, 'matrix.json')
const strategyPaths = [
  path.join(repositoryRoot, 'docs/adr/ADR-005-preprocessor-strategy.md'),
  path.join(repositoryRoot, 'docs/adr/ADR-012-canonical-preprocessor-host.md'),
  path.join(repositoryRoot, 'docs/adr/ADR-013-self-contained-native-frontends.md'),
]
const expectedCanonicalProviders = {
  'dart-sass': {
    package: 'sass',
    version: '1.101.0',
    license: 'MIT',
    adapters: ['scss', 'sass'],
  },
  less: {
    package: 'less',
    version: '4.6.7',
    license: 'Apache-2.0',
    adapters: ['less'],
  },
  stylus: {
    package: 'stylus',
    version: '0.64.0',
    license: 'MIT',
    adapters: ['stylus'],
  },
}
const expectedAdapterIds = [
  'scss',
  'sass',
  'less',
  'stylus',
  'css-modules',
  'css-in-js',
  'postcss',
  'tailwind',
]
const expectedCanonicalSourceFiles = [
  'src/preprocessor/less.zig',
  'src/preprocessor/less_evaluator.zig',
  'src/preprocessor/sass.zig',
  'src/preprocessor/sass_arguments.zig',
  'src/preprocessor/sass_color.zig',
  'src/preprocessor/sass_evaluator.zig',
  'src/preprocessor/sass_numeric.zig',
  'src/preprocessor/sass_selector.zig',
  'src/preprocessor/sass_string.zig',
  'src/preprocessor/stylus.zig',
  'src/preprocessor/stylus_evaluator.zig',
]

function fail(message) {
  throw new Error(message)
}

function binariesFromArguments(argumentsList) {
  let compiler = path.join(
    repositoryRoot,
    'zig-out',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  )
  let moduleDriver = path.join(
    repositoryRoot,
    'zig-out',
    'bin',
    process.platform === 'win32'
      ? 'zigcss-css-modules-test-driver.exe'
      : 'zigcss-css-modules-test-driver',
  )
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index]
    if (argument !== '--compiler' && argument !== '--module-driver') {
      fail(`unknown argument: ${argument}`)
    }
    if (index + 1 >= argumentsList.length) fail('--compiler requires a path')
    if (argument === '--compiler') compiler = path.resolve(argumentsList[index + 1])
    else moduleDriver = path.resolve(argumentsList[index + 1])
    index += 1
  }
  return { compiler, moduleDriver }
}

function sorted(values) {
  return [...values].sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
}

function expectExactSet(actual, expected, label) {
  const actualSorted = sorted(new Set(actual))
  const expectedSorted = sorted(new Set(expected))
  if (JSON.stringify(actualSorted) !== JSON.stringify(expectedSorted)) {
    fail(`${label}: expected ${JSON.stringify(expectedSorted)}, found ${JSON.stringify(actualSorted)}`)
  }
}

function repositoryPath(relativePath) {
  const resolved = path.resolve(repositoryRoot, relativePath)
  if (!resolved.startsWith(`${repositoryRoot}${path.sep}`)) {
    fail(`path escapes repository: ${relativePath}`)
  }
  return resolved
}

function repositoryFile(relativePath) {
  const resolved = repositoryPath(relativePath)
  if (!fs.statSync(resolved).isFile()) fail(`not a file: ${relativePath}`)
  return resolved
}

export function discoverLegacyAdapterSources(root) {
  const formatsDirectory = path.join(root, 'src/formats')
  const legacySources = []
  if (fs.existsSync(formatsDirectory)) {
    const stat = fs.lstatSync(formatsDirectory)
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail('src/formats must be a regular directory')
    legacySources.push(
      ...fs
        .readdirSync(formatsDirectory)
        .filter(name => name.endsWith('.zig'))
        .map(name => `src/formats/${name}`),
    )
  }
  const tailwindPath = path.join(root, 'src/tailwind.zig')
  if (fs.existsSync(tailwindPath)) {
    const stat = fs.lstatSync(tailwindPath)
    if (!stat.isFile() || stat.isSymbolicLink()) fail('src/tailwind.zig must be a regular file')
    legacySources.push('src/tailwind.zig')
  }
  return sorted(legacySources)
}

function formatTagsFromSource(source) {
  const match = source.match(/pub const Format = enum \{([\s\S]*?)\n\};/)
  if (!match) fail('src/formats.zig does not declare Format')
  return match[1]
    .split('\n')
    .map(line => line.trim().replace(/,$/, ''))
    .filter(line => line.length > 0 && !line.startsWith('//'))
}

function syntaxTagsFromSource(source) {
  const match = source.match(/pub const Syntax = enum \{([\s\S]*?)\n\};/)
  if (!match) fail('src/api.zig does not declare Syntax')
  return match[1]
    .split('\n')
    .map(line => line.trim().replace(/,$/, ''))
    .filter(line => line.length > 0 && !line.startsWith('//'))
}

function validateCanonicalProviders(matrix) {
  const providers = matrix.canonicalProviders
  if (providers === null || typeof providers !== 'object' || Array.isArray(providers)) {
    fail('canonicalProviders must be an object')
  }
  expectExactSet(
    Object.keys(providers),
    Object.keys(expectedCanonicalProviders),
    'canonical provider inventory',
  )
  const claimedAdapters = []
  for (const [providerId, expected] of Object.entries(expectedCanonicalProviders)) {
    const provider = providers[providerId]
    if (provider === null || typeof provider !== 'object' || Array.isArray(provider)) {
      fail(`${providerId}: canonical provider must be an object`)
    }
    expectExactSet(Object.keys(provider), Object.keys(expected), `${providerId}: provider fields`)
    for (const field of ['package', 'version', 'license']) {
      if (provider[field] !== expected[field]) {
        fail(`${providerId}: expected ${field} ${expected[field]}, found ${provider[field]}`)
      }
    }
    if (!/^\d+\.\d+\.\d+$/.test(provider.version)) {
      fail(`${providerId}: version must be an exact semantic version`)
    }
    if (!Array.isArray(provider.adapters)) fail(`${providerId}: adapters must be an array`)
    expectExactSet(provider.adapters, expected.adapters, `${providerId}: adapter ownership`)
    claimedAdapters.push(...provider.adapters)
  }
  expectExactSet(claimedAdapters, ['scss', 'sass', 'less', 'stylus'], 'canonical adapter ownership')
}

function validateMatrix() {
  const matrix = JSON.parse(fs.readFileSync(matrixPath, 'utf8'))
  if (matrix.schemaVersion !== 4) fail(`unsupported matrix schema: ${matrix.schemaVersion}`)
  const availability = new Set(Object.keys(matrix.availabilityDefinitions ?? {}))
  const compatibility = new Set(Object.keys(matrix.compatibilityDefinitions ?? {}))
  const implementations = new Set(Object.keys(matrix.implementationDefinitions ?? {}))
  const strategies = new Set(Object.keys(matrix.strategyDefinitions ?? {}))
  if (
    availability.size === 0 ||
    compatibility.size === 0 ||
    implementations.size === 0 ||
    strategies.size === 0
  ) {
    fail('matrix definitions must be nonempty')
  }
  if (!Array.isArray(matrix.adapters) || matrix.adapters.length === 0) {
    fail('matrix adapters must be nonempty')
  }
  validateCanonicalProviders(matrix)

  const ids = new Set()
  const publicSyntaxes = new Set()
  const nativeSyntaxes = new Set()
  const coveredSources = new Set()
  const coveredLegacySources = new Set()
  const strategyDocument = strategyPaths.map(strategyPath => fs.readFileSync(strategyPath, 'utf8')).join('\n')
  for (const adapter of matrix.adapters) {
    if (ids.has(adapter.id)) fail(`duplicate adapter id: ${adapter.id}`)
    ids.add(adapter.id)
    if (!/^[a-z][a-z0-9-]*$/.test(adapter.id)) fail(`invalid adapter id: ${adapter.id}`)
    if (typeof adapter.displayName !== 'string' || adapter.displayName.length === 0) {
      fail(`${adapter.id}: missing displayName`)
    }
    if (typeof adapter.cliDisplayName !== 'string' || adapter.cliDisplayName.length === 0) {
      fail(`${adapter.id}: missing cliDisplayName`)
    }
    if (!availability.has(adapter.availability)) {
      fail(`${adapter.id}: unknown availability ${adapter.availability}`)
    }
    if (!compatibility.has(adapter.compatibility)) {
      fail(`${adapter.id}: unknown compatibility ${adapter.compatibility}`)
    }
    if (!implementations.has(adapter.implementation)) {
      fail(`${adapter.id}: unknown implementation ${adapter.implementation}`)
    }
    if (!strategies.has(adapter.strategy)) fail(`${adapter.id}: unknown strategy ${adapter.strategy}`)
    if (adapter.strategy === 'native-reimplementation') {
      if (typeof adapter.referenceOracleId !== 'string') {
        fail(`${adapter.id}: native reimplementation requires referenceOracleId`)
      }
      const provider = matrix.canonicalProviders[adapter.referenceOracleId]
      if (provider === undefined || !provider.adapters.includes(adapter.id)) {
        fail(`${adapter.id}: referenceOracleId does not own the adapter`)
      }
      if (
        adapter.availability !== 'NativeCliZigApi' ||
        adapter.compatibility !== 'NativeGraduated' ||
        adapter.implementation !== 'NativeFrontend'
      ) {
        fail(`${adapter.id}: native graduated row has inconsistent public state`)
      }
      if (adapter.nativeSyntax !== adapter.id || nativeSyntaxes.has(adapter.nativeSyntax)) {
        fail(`${adapter.id}: native frontend needs one unique matching nativeSyntax`)
      }
      nativeSyntaxes.add(adapter.nativeSyntax)
      if (typeof adapter.probeOutput !== 'string' || adapter.probeOutput.length === 0) {
        fail(`${adapter.id}: native frontend needs probeOutput`)
      }
    } else if (adapter.referenceOracleId !== undefined) {
      fail(`${adapter.id}: non-native strategy cannot name referenceOracleId`)
    } else if (adapter.nativeSyntax !== undefined || adapter.probeOutput !== undefined) {
      fail(`${adapter.id}: non-native strategy cannot name nativeSyntax or probeOutput`)
    }
    if (!Array.isArray(adapter.extensions) || adapter.extensions.length === 0) {
      fail(`${adapter.id}: extensions must be nonempty`)
    }
    for (const extension of adapter.extensions) {
      if (!/^\.[a-z.]+$/.test(extension)) fail(`${adapter.id}: invalid extension ${extension}`)
    }
    if (!Array.isArray(adapter.ownerPackages) || adapter.ownerPackages.length === 0) {
      fail(`${adapter.id}: ownerPackages must be nonempty`)
    }
    for (const owner of adapter.ownerPackages) {
      if (!/^[A-Z]+-[0-9]{3}$/.test(owner)) fail(`${adapter.id}: invalid owner package ${owner}`)
    }
    if (typeof adapter.currentBoundary !== 'string' || adapter.currentBoundary.length === 0) {
      fail(`${adapter.id}: currentBoundary must be nonempty`)
    }
    if (!Array.isArray(adapter.knownRisks) || adapter.knownRisks.length === 0) {
      fail(`${adapter.id}: knownRisks must be nonempty`)
    }
    if (typeof adapter.probe !== 'string' || adapter.probe.length === 0) {
      fail(`${adapter.id}: probe must be nonempty`)
    }
    if (!Array.isArray(adapter.sourceFiles)) fail(`${adapter.id}: sourceFiles must be an array`)
    for (const sourceFile of adapter.sourceFiles) {
      repositoryFile(sourceFile)
      coveredSources.add(sourceFile)
      if (adapter.implementation === 'LegacyCharacterized') coveredLegacySources.add(sourceFile)
    }
    if (
      adapter.publicSyntax !== undefined &&
      (typeof adapter.publicSyntax !== 'string' || !/^[a-z][a-z0-9_]*$/.test(adapter.publicSyntax))
    ) {
      fail(`${adapter.id}: invalid publicSyntax`)
    }
    if (adapter.publicSyntax !== undefined) {
      if (publicSyntaxes.has(adapter.publicSyntax)) {
        fail(`${adapter.id}: duplicate publicSyntax ${adapter.publicSyntax}`)
      }
      publicSyntaxes.add(adapter.publicSyntax)
    }
    if (adapter.implementation === 'NativeFrontend') {
      if (adapter.formatTag !== null) fail(`${adapter.id}: native frontend retains a legacy Format tag`)
      if (adapter.sourceFiles.length === 0) fail(`${adapter.id}: native frontend sourceFiles must be nonempty`)
      if (!Array.isArray(adapter.sourceEvidence) || adapter.sourceEvidence.length === 0) {
        fail(`${adapter.id}: native frontend sourceEvidence must be nonempty`)
      }
      for (const evidence of adapter.sourceEvidence) {
        if (!adapter.sourceFiles.includes(evidence.file)) {
          fail(`${adapter.id}: evidence file is outside sourceFiles: ${evidence.file}`)
        }
        validateEvidence(adapter.id, evidence)
      }
      if (!Array.isArray(adapter.containmentEvidence) || adapter.containmentEvidence.length === 0) {
        fail(`${adapter.id}: native frontend containmentEvidence must be nonempty`)
      }
      for (const evidence of adapter.containmentEvidence) validateEvidence(adapter.id, evidence)
      if (adapter.publicSyntax !== undefined) {
        fail(`${adapter.id}: native frontend must use the bounded native namespace rather than stable CSS Syntax`)
      }
      if (adapter.removedBy !== undefined || adapter.removedSourceFiles !== undefined) {
        fail(`${adapter.id}: native frontend cannot retain removal metadata`)
      }
    } else if (adapter.implementation === 'LegacyCharacterized') {
      if (adapter.availability !== 'Unavailable' || adapter.compatibility !== 'Unverified') {
        fail(`${adapter.id}: legacy implementation must remain Unavailable and Unverified`)
      }
      if (adapter.sourceFiles.length === 0) fail(`${adapter.id}: legacy sourceFiles must be nonempty`)
      if (!Array.isArray(adapter.sourceEvidence) || adapter.sourceEvidence.length === 0) {
        fail(`${adapter.id}: sourceEvidence must be nonempty`)
      }
      for (const evidence of adapter.sourceEvidence) {
        if (!adapter.sourceFiles.includes(evidence.file)) {
          fail(`${adapter.id}: evidence file is outside sourceFiles: ${evidence.file}`)
        }
        validateEvidence(adapter.id, evidence)
      }
      if (adapter.removedBy !== undefined || adapter.removedSourceFiles !== undefined) {
        fail(`${adapter.id}: legacy implementation cannot claim removal metadata`)
      }
      if (adapter.publicSyntax !== undefined) {
        fail(`${adapter.id}: legacy implementation cannot expose a public syntax`)
      }
    } else if (adapter.implementation === 'LimitedNative') {
      if (adapter.formatTag !== null) fail(`${adapter.id}: native implementation retains a legacy Format tag`)
      if (adapter.sourceFiles.length === 0) fail(`${adapter.id}: native sourceFiles must be nonempty`)
      if (adapter.availability !== 'ExperimentalLibrary') {
        fail(`${adapter.id}: native implementation must be ExperimentalLibrary`)
      }
      if (adapter.compatibility !== 'NativeSubset') {
        fail(`${adapter.id}: native implementation must publish NativeSubset compatibility`)
      }
      if (typeof adapter.publicSyntax !== 'string') {
        fail(`${adapter.id}: native implementation must expose one publicSyntax`)
      }
      if (!Array.isArray(adapter.sourceEvidence) || adapter.sourceEvidence.length === 0) {
        fail(`${adapter.id}: native sourceEvidence must be nonempty`)
      }
      for (const evidence of adapter.sourceEvidence) {
        if (!adapter.sourceFiles.includes(evidence.file)) {
          fail(`${adapter.id}: evidence file is outside sourceFiles: ${evidence.file}`)
        }
        validateEvidence(adapter.id, evidence)
      }
      if (!Array.isArray(adapter.containmentEvidence) || adapter.containmentEvidence.length === 0) {
        fail(`${adapter.id}: native containmentEvidence must be nonempty`)
      }
      for (const evidence of adapter.containmentEvidence) validateEvidence(adapter.id, evidence)
      if (adapter.removedBy !== undefined || adapter.removedSourceFiles !== undefined) {
        fail(`${adapter.id}: native implementation cannot claim removal metadata`)
      }
    } else if (adapter.implementation === 'Removed') {
      if (adapter.availability !== 'Unavailable' || adapter.compatibility !== 'Unverified') {
        fail(`${adapter.id}: removed implementation must remain Unavailable and Unverified`)
      }
      if (adapter.formatTag !== null) fail(`${adapter.id}: removed implementation retains a Format tag`)
      if (adapter.sourceFiles.length !== 0) fail(`${adapter.id}: removed implementation retains sourceFiles`)
      if (!adapter.ownerPackages.includes(adapter.removedBy)) {
        fail(`${adapter.id}: removedBy must name an owner package`)
      }
      if (!Array.isArray(adapter.removedSourceFiles) || adapter.removedSourceFiles.length === 0) {
        fail(`${adapter.id}: removedSourceFiles must be nonempty`)
      }
      for (const removedSource of adapter.removedSourceFiles) {
        if (fs.existsSync(repositoryPath(removedSource))) {
          fail(`${adapter.id}: removed source still exists: ${removedSource}`)
        }
      }
      if (!Array.isArray(adapter.containmentEvidence) || adapter.containmentEvidence.length === 0) {
        fail(`${adapter.id}: containmentEvidence must be nonempty`)
      }
      for (const evidence of adapter.containmentEvidence) validateEvidence(adapter.id, evidence)
      if (adapter.sourceEvidence !== undefined) {
        fail(`${adapter.id}: removed implementation must not retain sourceEvidence`)
      }
      if (adapter.publicSyntax !== undefined) {
        fail(`${adapter.id}: removed implementation cannot expose a public syntax`)
      }
    }
    const strategyRow = `| \`${adapter.id}\` | \`${adapter.strategy}\` |`
    if (!strategyDocument.includes(strategyRow)) {
      fail(`${adapter.id}: accepted strategy ADRs do not record strategy ${adapter.strategy}`)
    }
  }
  expectExactSet(ids, expectedAdapterIds, 'adapter inventory')

  const legacySources = discoverLegacyAdapterSources(repositoryRoot)
  expectExactSet(coveredLegacySources, legacySources, 'legacy adapter source inventory')
  const nativeSources = matrix.adapters
    .filter(adapter => adapter.implementation === 'LimitedNative' || adapter.implementation === 'NativeFrontend')
    .flatMap(adapter => adapter.sourceFiles)
  const frontendSources = matrix.adapters
    .filter(adapter => adapter.implementation === 'NativeFrontend')
    .flatMap(adapter => adapter.sourceFiles)
  expectExactSet(frontendSources, expectedCanonicalSourceFiles, 'native frontend source inventory')
  expectExactSet(
    coveredSources,
    [...legacySources, ...nativeSources],
    'complete adapter source inventory',
  )

  const formatsSource = fs.readFileSync(path.join(repositoryRoot, 'src/formats.zig'), 'utf8')
  const sourceTags = formatTagsFromSource(formatsSource).filter(tag => tag !== 'css')
  const matrixTags = matrix.adapters
    .map(adapter => adapter.formatTag)
    .filter(tag => tag !== null)
  expectExactSet(matrixTags, sourceTags, 'Format enum coverage')
  for (const adapter of matrix.adapters) {
    if (adapter.formatTag === null) continue
    if (!formatsSource.includes(`.${adapter.formatTag} => "${adapter.displayName}"`)) {
      fail(`${adapter.id}: display name does not match src/formats.zig`)
    }
    for (const extension of adapter.extensions) {
      if (!formatsSource.includes(`std.mem.endsWith(u8, filename, "${extension}")`)) {
        fail(`${adapter.id}: extension is not classified by src/formats.zig: ${extension}`)
      }
    }
  }

  const apiSource = fs.readFileSync(path.join(repositoryRoot, 'src/api.zig'), 'utf8')
  expectExactSet(
    syntaxTagsFromSource(apiSource),
    ['css', ...publicSyntaxes],
    'public Syntax coverage',
  )
  return matrix
}

function validateEvidence(adapterId, evidence) {
  if (typeof evidence.contains !== 'string' || evidence.contains.length === 0) {
    fail(`${adapterId}: evidence anchor must be nonempty`)
  }
  const source = fs.readFileSync(repositoryFile(evidence.file), 'utf8')
  if (!source.includes(evidence.contains)) {
    fail(`${adapterId}: missing source evidence ${JSON.stringify(evidence.contains)}`)
  }
}

async function validateCliProbes(compiler, matrix) {
  fs.accessSync(compiler, fs.constants.X_OK)
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-format-matrix-'))
  let rejectionCount = 0
  let nativeCount = 0
  try {
    for (const adapter of matrix.adapters) {
      for (const extension of adapter.extensions) {
        const stem = adapter.id.replace(/[^a-z0-9-]/g, '-')
        const input = path.join(temporary, `${stem}-${rejectionCount}${extension}`)
        const output = path.join(temporary, `${stem}-${rejectionCount}.css`)
        fs.writeFileSync(input, adapter.probe)
        if (adapter.implementation === 'NativeFrontend') {
          const result = spawnSync(compiler, ['-', '--syntax', adapter.nativeSyntax, '--minify'], {
            cwd: temporary,
            encoding: 'utf8',
            input: adapter.probe,
            maxBuffer: 1024 * 1024,
          })
          if (result.error) fail(`${adapter.id}/${extension}: launch failed: ${result.error.message}`)
          if (result.signal) fail(`${adapter.id}/${extension}: compiler terminated by ${result.signal}`)
          if (result.status !== 0) {
            fail(`${adapter.id}/${extension}: expected exit 0, received ${result.status}\n${result.stderr}`)
          }
          if (result.stdout !== adapter.probeOutput) fail(`${adapter.id}/${extension}: native probe output changed`)
          if (!result.stderr.includes('experimental release candidate')) {
            fail(`${adapter.id}/${extension}: native probe omitted the release warning`)
          }
          if (fs.existsSync(output)) fail(`${adapter.id}/${extension}: stdout probe created an output file`)
          nativeCount += 1
          continue
        }
        const result = spawnSync(compiler, [input, '-o', output], {
          cwd: repositoryRoot,
          encoding: 'utf8',
          maxBuffer: 1024 * 1024,
        })
        if (result.error) fail(`${adapter.id}/${extension}: launch failed: ${result.error.message}`)
        if (result.signal) fail(`${adapter.id}/${extension}: compiler terminated by ${result.signal}`)
        if (result.status !== 2) {
          fail(`${adapter.id}/${extension}: expected exit 2, received ${result.status}\n${result.stderr}`)
        }
        if (result.stdout.length !== 0) fail(`${adapter.id}/${extension}: rejection emitted stdout`)
        const diagnostic = `${adapter.cliDisplayName} format adapter is experimental and unavailable`
        if (!result.stderr.includes(diagnostic)) {
          fail(`${adapter.id}/${extension}: missing diagnostic ${JSON.stringify(diagnostic)}`)
        }
        if (fs.existsSync(output)) fail(`${adapter.id}/${extension}: rejection created output`)
        rejectionCount += 1
      }
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
  return { nativeCount, rejectionCount }
}

async function main(args) {
  const { compiler, moduleDriver } = binariesFromArguments(args)
  const matrix = validateMatrix()
  const probes = await validateCliProbes(compiler, matrix)
  const moduleEvidence = validateCssModules(moduleDriver)
  const removedCount = matrix.adapters.filter(adapter => adapter.implementation === 'Removed').length
  const nativeCount = matrix.adapters.filter(adapter => adapter.implementation === 'LimitedNative').length
  const frontendCount = matrix.adapters.filter(adapter => adapter.implementation === 'NativeFrontend').length
  console.log(
    `Format matrix verified: ${matrix.adapters.length} adapters, ${frontendCount} native graduated frontends, ${removedCount} removed implementations, ${nativeCount} limited native implementation, ${probes.nativeCount} native CLI probes, ${probes.rejectionCount} rejected extension probes, ${moduleEvidence.outputs} independently parsed CSS Modules outputs (${moduleEvidence.valueFixtures} local-value fixture outputs), ${moduleEvidence.compositionDifferentials} composition differential, ${moduleEvidence.rejections} strict module rejections (Lightning CSS ${moduleEvidence.validatorVersion}), complete adapter-source coverage.`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main(process.argv.slice(2)).catch(error => {
    console.error(error)
    process.exitCode = 1
  })
}
