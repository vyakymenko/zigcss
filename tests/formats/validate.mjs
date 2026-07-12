import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateCssModules } from './css_modules_validate.mjs'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '../..')
const matrixPath = path.join(scriptDirectory, 'matrix.json')
const strategyPath = path.join(repositoryRoot, 'docs/adr/ADR-005-preprocessor-strategy.md')
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

function validateMatrix() {
  const matrix = JSON.parse(fs.readFileSync(matrixPath, 'utf8'))
  if (matrix.schemaVersion !== 1) fail(`unsupported matrix schema: ${matrix.schemaVersion}`)
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

  const ids = new Set()
  const publicSyntaxes = new Set()
  const coveredSources = new Set()
  const coveredLegacySources = new Set()
  const strategyDocument = fs.readFileSync(strategyPath, 'utf8')
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
    if (adapter.implementation === 'LegacyCharacterized') {
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
      fail(`${adapter.id}: ADR-005 does not record strategy ${adapter.strategy}`)
    }
  }
  expectExactSet(ids, expectedAdapterIds, 'adapter inventory')

  const formatsDirectory = path.join(repositoryRoot, 'src/formats')
  const legacySources = fs
    .readdirSync(formatsDirectory)
    .filter(name => name.endsWith('.zig'))
    .map(name => `src/formats/${name}`)
  legacySources.push('src/tailwind.zig')
  expectExactSet(coveredLegacySources, legacySources, 'legacy adapter source inventory')
  const nativeSources = matrix.adapters
    .filter(adapter => adapter.implementation === 'LimitedNative')
    .flatMap(adapter => adapter.sourceFiles)
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

function validateCliRejections(compiler, matrix) {
  fs.accessSync(compiler, fs.constants.X_OK)
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-format-matrix-'))
  let rejectionCount = 0
  try {
    for (const adapter of matrix.adapters) {
      for (const extension of adapter.extensions) {
        const stem = adapter.id.replace(/[^a-z0-9-]/g, '-')
        const input = path.join(temporary, `${stem}-${rejectionCount}${extension}`)
        const output = path.join(temporary, `${stem}-${rejectionCount}.css`)
        fs.writeFileSync(input, adapter.probe)
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
  return rejectionCount
}

const { compiler, moduleDriver } = binariesFromArguments(process.argv.slice(2))
const matrix = validateMatrix()
const rejectionCount = validateCliRejections(compiler, matrix)
const moduleEvidence = validateCssModules(moduleDriver)
const removedCount = matrix.adapters.filter(adapter => adapter.implementation === 'Removed').length
const nativeCount = matrix.adapters.filter(adapter => adapter.implementation === 'LimitedNative').length
console.log(
  `Format matrix verified: ${matrix.adapters.length} adapters, ${removedCount} removed implementations, ${nativeCount} limited native implementation, ${rejectionCount} rejected extension probes, ${moduleEvidence.outputs} independently parsed CSS Modules outputs, ${moduleEvidence.compositionDifferentials} composition differential, ${moduleEvidence.rejections} strict module rejection (Lightning CSS ${moduleEvidence.validatorVersion}), complete adapter-source coverage.`,
)
