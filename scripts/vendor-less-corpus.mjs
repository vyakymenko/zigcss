import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/less/corpus')
const filesRoot = path.join(corpusRoot, 'files')
const selectionPath = path.join(corpusRoot, 'selection.json')
const manifestPath = path.join(corpusRoot, 'manifest.json')
const licensePath = path.join(corpusRoot, 'LESS_LICENSE')
const sourcePrefix = 'packages/test-data/'

function fail(message) {
  throw new Error(`Less corpus: ${message}`)
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
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
  const value = JSON.parse(fs.readFileSync(selectionPath, 'utf8'))
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
  const dependencies = {}
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
    dependencies[id] = owned
  }
  return { ...value, options, support, dependencies, cases }
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

function collectSource(sourceRoot, relativePath, output) {
  const filename = sourcePath(sourceRoot, relativePath)
  const stat = fs.lstatSync(filename)
  if (stat.isSymbolicLink()) fail(`source contains a symlink: ${relativePath}`)
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(filename, { withFileTypes: true }).sort((left, right) => (
      Buffer.from(left.name).compare(Buffer.from(right.name))
    ))) {
      collectSource(sourceRoot, `${relativePath}/${entry.name}`, output)
    }
    return
  }
  if (!stat.isFile()) fail(`source contains a special file: ${relativePath}`)
  const target = generatedPath(relativePath)
  const bytes = fs.readFileSync(filename)
  const existing = output.get(target)
  if (existing !== undefined && !existing.bytes.equals(bytes)) {
    fail(`selected source bytes conflict: ${target}`)
  }
  output.set(target, { bytes, source: relativePath })
}

function listFiles(root) {
  if (!fs.existsSync(root)) return []
  const output = []
  function visit(directory, relative) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = path.join(directory, entry.name)
      if (entry.isSymbolicLink()) fail(`generated corpus contains a symlink: ${childRelative}`)
      if (entry.isDirectory()) visit(child, childRelative)
      else if (entry.isFile()) output.push(childRelative)
      else fail(`generated corpus contains a special file: ${childRelative}`)
    }
  }
  visit(root, '')
  return output.sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
}

function writeOrCheck(filename, bytes, mode) {
  if (mode === 'write') {
    fs.mkdirSync(path.dirname(filename), { recursive: true })
    fs.writeFileSync(filename, bytes)
    return
  }
  if (!fs.existsSync(filename)) fail(`missing generated file: ${path.relative(repositoryRoot, filename)}`)
  if (!fs.readFileSync(filename).equals(bytes)) {
    fail(`stale generated file: ${path.relative(repositoryRoot, filename)}`)
  }
}

function verifiedPackage(sourceRoot, relativePath, expectedName, expectedDigest, upstream) {
  const filename = path.join(sourceRoot, ...relativePath.split('/'))
  const bytes = fs.readFileSync(filename)
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
    const archiveStat = fs.lstatSync(arguments_.archive)
    if (!archiveStat.isFile() || archiveStat.isSymbolicLink()) {
      fail('--archive must be a regular file')
    }
    const digest = sha256(fs.readFileSync(arguments_.archive))
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
  const license = fs.readFileSync(path.join(arguments_.source, 'LICENSE'))
  if (sha256(license) !== selection.upstream.licenseSha256) {
    fail('LICENSE does not match the reviewed Apache-2.0 text')
  }

  const selectedFiles = new Map()
  for (const selectedCase of selection.cases) {
    for (const relative of [selectedCase.entry, selectedCase.expected]) {
      collectSource(
        arguments_.source,
        `${sourcePrefix}${selectedCase.suite}/${relative}`,
        selectedFiles,
      )
    }
  }
  for (const support of selection.support) {
    collectSource(arguments_.source, `${sourcePrefix}${support}`, selectedFiles)
  }
  for (const dependencies of Object.values(selection.dependencies)) {
    for (const dependency of dependencies) {
      collectSource(
        arguments_.source,
        `${sourcePrefix}tests-unit/${dependency}`,
        selectedFiles,
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

main()
