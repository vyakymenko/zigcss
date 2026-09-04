import { createHash, randomBytes } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  hashStableRegularFile,
  readBoundedDirectory,
  readStableRegularFile,
  readStableUtf8File,
} from './bounded-filesystem.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/less/corpus')
const filesRoot = path.join(corpusRoot, 'files')
const selectionPath = path.join(corpusRoot, 'selection.json')
const manifestPath = path.join(corpusRoot, 'manifest.json')
const licensePath = path.join(corpusRoot, 'LESS_LICENSE')
const sourcePrefix = 'packages/test-data/'
const maximumArchiveBytes = 256 * 1024 * 1024
const maximumFileBytes = 16 * 1024 * 1024
const maximumSelectionBytes = 2 * 1024 * 1024
const maximumTraversalBytes = 256 * 1024 * 1024
const maximumTraversalDepth = 32
const maximumTraversalEntries = 20_000
const maximumEntriesPerDirectory = 4096

function fail(message) {
  throw new Error(`Less corpus: ${message}`)
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function traversalBudget() {
  return { bytes: 0, entries: 0 }
}

function accountEntry(budget, relativePath, depth) {
  budget.entries += 1
  if (budget.entries > maximumTraversalEntries) fail(`source traversal exceeds ${maximumTraversalEntries} entries`)
  if (depth > maximumTraversalDepth) fail(`source traversal exceeds depth ${maximumTraversalDepth}: ${relativePath}`)
}

function accountBytes(budget, bytes) {
  budget.bytes += bytes.length
  if (budget.bytes > maximumTraversalBytes) fail(`source traversal exceeds ${maximumTraversalBytes} bytes`)
}

function exactKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} fields must be ${JSON.stringify(wanted)}, found ${JSON.stringify(actual)}`)
  }
}

function parseArguments(values) {
  let source = null
  let archive = null
  let mode = null
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index]
    if (value === '--source' || value === '--archive') {
      if (index + 1 >= values.length) fail(`${value} requires a path`)
      const resolved = path.resolve(values[index + 1])
      if (value === '--source') source = resolved
      else archive = resolved
      index += 1
      continue
    }
    if (value === '--write' || value === '--check') {
      if (mode !== null) fail('choose exactly one of --write or --check')
      mode = value.slice(2)
      continue
    }
    fail(`unknown argument: ${value}`)
  }
  if (source === null) fail('--source is required')
  if (mode === null) fail('choose exactly one of --write or --check')
  return { archive, mode, source }
}

function safeRelative(value, label) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    Buffer.byteLength(value, 'utf8') > 4096 ||
    path.posix.isAbsolute(value) ||
    value.includes('\\') ||
    value.split('/').some(part => part === '' || part === '.' || part === '..') ||
    /[\u0000\r\n]/.test(value)
  ) {
    fail(`${label} is not a safe relative path`)
  }
  return value
}

function providerOptions(value, label) {
  exactKeys(value, ['math', 'quietDeprecations', 'rewriteUrls', 'strictUnits'], label)
  if (!['always', 'parens-division', 'parens'].includes(value.math)) {
    fail(`${label}.math is invalid`)
  }
  if (!['off', 'local', 'all'].includes(value.rewriteUrls)) {
    fail(`${label}.rewriteUrls is invalid`)
  }
  if (
    typeof value.quietDeprecations !== 'boolean' ||
    typeof value.strictUnits !== 'boolean'
  ) {
    fail(`${label} booleans are invalid`)
  }
  return { ...value }
}

function readSelection() {
  const value = JSON.parse(readStableUtf8File(selectionPath, {
    label: 'selection.json',
    maximumBytes: maximumSelectionBytes,
    reject: fail,
  }))
  exactKeys(
    value,
    ['schemaVersion', 'upstream', 'options', 'support', 'dependencies', 'cases'],
    'selection',
  )
  if (value.schemaVersion !== 1) fail(`unsupported selection schema ${value.schemaVersion}`)
  exactKeys(value.upstream, [
    'repository',
    'tag',
    'tagObject',
    'revision',
    'tree',
    'archiveSha256',
    'rootPackageSha256',
    'providerPackageSha256',
    'packageVersion',
    'license',
    'licenseSha256',
  ], 'selection upstream')
  if (
    value.upstream.repository !== 'https://github.com/less/less.js' ||
    value.upstream.tag !== `v${value.upstream.packageVersion}` ||
    value.upstream.packageVersion !== '4.6.7' ||
    value.upstream.license !== 'Apache-2.0'
  ) {
    fail('selection upstream identity is invalid')
  }
  for (const key of [
    'tagObject',
    'revision',
    'tree',
    'archiveSha256',
    'rootPackageSha256',
    'providerPackageSha256',
    'licenseSha256',
  ]) {
    if (!/^[0-9a-f]{40}$/.test(value.upstream[key]) && !/^[0-9a-f]{64}$/.test(value.upstream[key])) {
      fail(`selection upstream ${key} is invalid`)
    }
  }

  exactKeys(value.options, ['success', 'error'], 'selection options')
  const options = {
    success: providerOptions(value.options.success, 'selection success options'),
    error: providerOptions(value.options.error, 'selection error options'),
  }

  if (!Array.isArray(value.support)) fail('selection support must be an array')
  const support = value.support.map((item, index) => safeRelative(item, `support ${index}`))
  if (new Set(support).size !== support.length) fail('selection support paths must be unique')

  if (!Array.isArray(value.cases) || value.cases.length === 0) {
    fail('selection cases must be a nonempty array')
  }
  const ids = new Set()
  const cases = value.cases.map((selectedCase, index) => {
    exactKeys(
      selectedCase,
      ['id', 'feature', 'suite', 'outcome', 'entry', 'expected'],
      `selection case ${index}`,
    )
    if (typeof selectedCase.id !== 'string' || !/^[a-z][a-z0-9-]+$/.test(selectedCase.id)) {
      fail(`selection case ${index} has an invalid id`)
    }
    if (ids.has(selectedCase.id)) fail(`duplicate case id: ${selectedCase.id}`)
    ids.add(selectedCase.id)
    if (
      typeof selectedCase.feature !== 'string' ||
      !/^[a-z][a-z0-9-]+$/.test(selectedCase.feature)
    ) {
      fail(`${selectedCase.id} has an invalid feature`)
    }
    if (!['tests-unit', 'tests-error/eval', 'tests-error/parse'].includes(selectedCase.suite)) {
      fail(`${selectedCase.id} has an invalid suite`)
    }
    if (!['success', 'error'].includes(selectedCase.outcome)) {
      fail(`${selectedCase.id} has an invalid outcome`)
    }
    if (
      (selectedCase.suite === 'tests-unit') !== (selectedCase.outcome === 'success')
    ) {
      fail(`${selectedCase.id} suite and outcome do not agree`)
    }
    const entry = safeRelative(selectedCase.entry, `${selectedCase.id} entry`)
    const expected = safeRelative(selectedCase.expected, `${selectedCase.id} expectation`)
    if (!entry.endsWith('.less')) fail(`${selectedCase.id} entry must be Less`)
    const expectedExtension = selectedCase.outcome === 'success' ? '.css' : '.txt'
    if (!expected.endsWith(expectedExtension)) {
      fail(`${selectedCase.id} expectation must end with ${expectedExtension}`)
    }
    return { ...selectedCase, entry, expected }
  })

  if (
    value.dependencies === null ||
    typeof value.dependencies !== 'object' ||
    Array.isArray(value.dependencies)
  ) {
    fail('selection dependencies must be an object')
  }
  const casesById = new Map(cases.map(selectedCase => [selectedCase.id, selectedCase]))
  const dependencies = new Map()
  for (const [id, values] of Object.entries(value.dependencies)) {
    const selectedCase = casesById.get(id)
    if (selectedCase === undefined || selectedCase.outcome !== 'success') {
      fail(`dependency owner is not a selected success case: ${id}`)
    }
    if (!Array.isArray(values) || values.length === 0) {
      fail(`${id} dependencies must be a nonempty array`)
    }
    const owned = values.map((item, index) => safeRelative(item, `${id} dependency ${index}`))
    if (new Set(owned).size !== owned.length) fail(`${id} dependencies must be unique`)
    dependencies.set(id, owned)
  }
  return { ...value, options, support, dependencies: Object.fromEntries(dependencies), cases }
}

function sourcePath(sourceRoot, relativePath) {
  if (!relativePath.startsWith(sourcePrefix)) fail(`source path is outside test data: ${relativePath}`)
  safeRelative(relativePath, 'source path')
  const filename = path.resolve(sourceRoot, ...relativePath.split('/'))
  if (!filename.startsWith(`${sourceRoot}${path.sep}`)) fail(`source path escapes root: ${relativePath}`)
  return filename
}

function generatedPath(sourceRelative) {
  if (!sourceRelative.startsWith(sourcePrefix)) fail(`invalid generated source: ${sourceRelative}`)
  return sourceRelative.slice(sourcePrefix.length)
}

export function collectLessSource(sourceRoot, relativePath, output, budget = traversalBudget(), depth = 0) {
  accountEntry(budget, relativePath, depth)
  const filename = sourcePath(sourceRoot, relativePath)
  const entries = readBoundedDirectory(filename, {
    allowFile: true,
    label: `source path ${relativePath}`,
    maximumEntries: maximumEntriesPerDirectory,
    reject: fail,
  })
  if (entries !== null) {
    entries.sort((left, right) => (
      Buffer.from(left.name).compare(Buffer.from(right.name))
    ))
    for (const entry of entries) {
      collectLessSource(sourceRoot, `${relativePath}/${entry.name}`, output, budget, depth + 1)
    }
    return
  }
  const target = generatedPath(relativePath)
  const bytes = readStableRegularFile(filename, {
    label: `source file ${relativePath}`,
    maximumBytes: maximumFileBytes,
    reject: fail,
  })
  accountBytes(budget, bytes)
  const existing = output.get(target)
  if (existing !== undefined && !existing.bytes.equals(bytes)) {
    fail(`selected source bytes conflict: ${target}`)
  }
  output.set(target, { bytes, source: relativePath })
}

function listFiles(root) {
  const first = readBoundedDirectory(root, {
    allowMissing: true,
    label: 'generated corpus root',
    maximumEntries: maximumEntriesPerDirectory,
    reject: fail,
  })
  if (first === null) return []
  const output = []
  const budget = traversalBudget()
  function visit(directory, relative, entries, depth) {
    for (const entry of entries) {
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = path.join(directory, entry.name)
      accountEntry(budget, childRelative, depth + 1)
      if (entry.isSymbolicLink()) fail(`generated corpus contains a symlink: ${childRelative}`)
      if (entry.isDirectory()) {
        const children = readBoundedDirectory(child, {
          label: `generated corpus directory ${childRelative}`,
          maximumEntries: maximumEntriesPerDirectory,
          reject: fail,
        })
        visit(child, childRelative, children, depth + 1)
      }
      else if (entry.isFile()) output.push(childRelative)
      else fail(`generated corpus contains a special file: ${childRelative}`)
    }
  }
  visit(root, '', first, 0)
  return output.sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
}

function writeAtomicFile(filename, bytes) {
  const temporary = `${filename}.tmp-${process.pid}-${randomBytes(8).toString('hex')}`
  try {
    fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o644 })
    fs.renameSync(temporary, filename)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

function writeOrCheck(filename, bytes, mode) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > maximumFileBytes) {
    fail(`generated file ${path.relative(repositoryRoot, filename)} is outside its byte limit`)
  }
  if (mode === 'write') {
    fs.mkdirSync(path.dirname(filename), { recursive: true })
    writeAtomicFile(filename, bytes)
    return
  }
  const actual = readStableRegularFile(filename, {
    label: `generated file ${path.relative(repositoryRoot, filename)}`,
    maximumBytes: maximumFileBytes,
    reject: fail,
  })
  if (!actual.equals(bytes)) {
    fail(`stale generated file: ${path.relative(repositoryRoot, filename)}`)
  }
}

function verifiedPackage(sourceRoot, relativePath, expectedName, expectedDigest, upstream) {
  const filename = path.join(sourceRoot, ...relativePath.split('/'))
  const bytes = readStableRegularFile(filename, {
    label: relativePath,
    maximumBytes: maximumFileBytes,
    reject: fail,
  })
  const value = JSON.parse(bytes)
  if (
    value.name !== expectedName ||
    value.version !== upstream.packageVersion ||
    value.license !== upstream.license ||
    sha256(bytes) !== expectedDigest
  ) {
    fail(`${relativePath} does not match the reviewed package identity`)
  }
}

function main() {
  const arguments_ = parseArguments(process.argv.slice(2))
  const selection = readSelection()
  const sourceStat = fs.lstatSync(arguments_.source)
  if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) {
    fail('--source must be a regular extracted Less repository directory')
  }
  if (arguments_.archive !== null) {
    const digest = hashStableRegularFile(arguments_.archive, {
      label: '--archive',
      maximumBytes: maximumArchiveBytes,
      reject: fail,
    })
    if (digest !== selection.upstream.archiveSha256) {
      fail(`archive checksum mismatch: ${digest}`)
    }
  }

  verifiedPackage(
    arguments_.source,
    'package.json',
    '@less/root',
    selection.upstream.rootPackageSha256,
    selection.upstream,
  )
  verifiedPackage(
    arguments_.source,
    'packages/less/package.json',
    'less',
    selection.upstream.providerPackageSha256,
    selection.upstream,
  )
  const license = readStableRegularFile(path.join(arguments_.source, 'LICENSE'), {
    label: 'LICENSE',
    maximumBytes: maximumFileBytes,
    reject: fail,
  })
  if (sha256(license) !== selection.upstream.licenseSha256) {
    fail('LICENSE does not match the reviewed Apache-2.0 text')
  }

  const selectedFiles = new Map()
  const sourceBudget = traversalBudget()
  for (const selectedCase of selection.cases) {
    for (const relative of [selectedCase.entry, selectedCase.expected]) {
      collectLessSource(
        arguments_.source,
        `${sourcePrefix}${selectedCase.suite}/${relative}`,
        selectedFiles,
        sourceBudget,
      )
    }
  }
  for (const support of selection.support) {
    collectLessSource(arguments_.source, `${sourcePrefix}${support}`, selectedFiles, sourceBudget)
  }
  for (const dependencies of Object.values(selection.dependencies)) {
    for (const dependency of dependencies) {
      collectLessSource(
        arguments_.source,
        `${sourcePrefix}tests-unit/${dependency}`,
        selectedFiles,
        sourceBudget,
      )
    }
  }

  const orderedFiles = [...selectedFiles].sort(([left], [right]) => (
    Buffer.from(left).compare(Buffer.from(right))
  ))
  for (const [relative, file] of orderedFiles) {
    writeOrCheck(path.join(filesRoot, ...relative.split('/')), file.bytes, arguments_.mode)
  }
  const actualFiles = listFiles(filesRoot)
  const expectedFiles = orderedFiles.map(([relative]) => relative)
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    fail(`generated file inventory differs: expected ${expectedFiles.length}, found ${actualFiles.length}`)
  }

  const cases = selection.cases.map(selectedCase => ({
    ...selectedCase,
    entry: `${selectedCase.suite}/${selectedCase.entry}`,
    expected: `${selectedCase.suite}/${selectedCase.expected}`,
    dependencies: [...(selection.dependencies[selectedCase.id] ?? [])],
  }))
  const manifest = {
    schemaVersion: 1,
    upstream: selection.upstream,
    licenseFile: {
      path: 'LESS_LICENSE',
      sha256: sha256(license),
    },
    options: selection.options,
    caseCount: cases.length,
    successCount: cases.filter(item => item.outcome === 'success').length,
    errorCount: cases.filter(item => item.outcome === 'error').length,
    files: orderedFiles.map(([relative, file]) => ({
      path: relative,
      source: file.source,
      bytes: file.bytes.length,
      sha256: sha256(file.bytes),
    })),
    cases,
  }
  writeOrCheck(licensePath, license, arguments_.mode)
  writeOrCheck(
    manifestPath,
    Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`),
    arguments_.mode,
  )
  process.stdout.write(
    `Less corpus ${arguments_.mode}: ${manifest.caseCount} cases, ${manifest.files.length} files\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
