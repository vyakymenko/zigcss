import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/stylus/corpus')
const filesRoot = path.join(corpusRoot, 'files')
const selectionPath = path.join(corpusRoot, 'selection.json')
const manifestPath = path.join(corpusRoot, 'manifest.json')
const licensePath = path.join(corpusRoot, 'STYLUS_LICENSE')
const forbiddenExecutable = /\.(?:c?js|mjs)$/i

function fail(message) {
  throw new Error(`Stylus corpus: ${message}`)
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

function sorted(values) {
  return [...values].sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
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

function safeName(value, label) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    Buffer.byteLength(value, 'utf8') > 512 ||
    !/^[A-Za-z0-9._-]+$/.test(value) ||
    value === '.' ||
    value === '..'
  ) {
    fail(`${label} is invalid`)
  }
  return value
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

function readSelection() {
  const value = JSON.parse(fs.readFileSync(selectionPath, 'utf8'))
  exactKeys(value, ['schemaVersion', 'upstream', 'exclusions', 'negativeCases'], 'selection')
  if (value.schemaVersion !== 1) fail(`unsupported selection schema ${value.schemaVersion}`)
  exactKeys(value.upstream, [
    'repository',
    'tag',
    'revision',
    'tree',
    'archiveSha256',
    'packageSha256',
    'testRunSha256',
    'packageVersion',
    'license',
    'licenseSha256',
  ], 'selection upstream')
  if (
    value.upstream.repository !== 'https://github.com/stylus/stylus' ||
    value.upstream.tag !== '0.64.0' ||
    value.upstream.packageVersion !== '0.64.0' ||
    value.upstream.license !== 'MIT'
  ) {
    fail('selection upstream identity is invalid')
  }
  for (const key of [
    'revision',
    'tree',
    'archiveSha256',
    'packageSha256',
    'testRunSha256',
    'licenseSha256',
  ]) {
    if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value.upstream[key])) {
      fail(`selection upstream ${key} is invalid`)
    }
  }

  if (!Array.isArray(value.exclusions) || value.exclusions.length === 0) {
    fail('selection exclusions must be a nonempty array')
  }
  const excludedNames = new Set()
  const exclusions = value.exclusions.map((item, index) => {
    exactKeys(item, ['name', 'category', 'reason'], `exclusion ${index}`)
    const name = safeName(item.name, `exclusion ${index} name`)
    if (excludedNames.has(name)) fail(`duplicate exclusion: ${name}`)
    excludedNames.add(name)
    if (!['executable-extension', 'unsupported-option', 'generated-css-invalid'].includes(item.category)) {
      fail(`exclusion ${name} has an invalid category`)
    }
    if (
      typeof item.reason !== 'string' ||
      item.reason.length < 20 ||
      Buffer.byteLength(item.reason, 'utf8') > 512 ||
      /[\u0000\r\n]/.test(item.reason)
    ) {
      fail(`exclusion ${name} has an invalid reason`)
    }
    return { ...item, name }
  })

  if (!Array.isArray(value.negativeCases) || value.negativeCases.length === 0) {
    fail('selection negativeCases must be a nonempty array')
  }
  const negativeIds = new Set()
  const negativeCases = value.negativeCases.map((item, index) => {
    exactKeys(item, ['id', 'feature', 'source', 'expected'], `negative case ${index}`)
    if (typeof item.id !== 'string' || !/^[a-z][a-z0-9-]+$/.test(item.id)) {
      fail(`negative case ${index} has an invalid id`)
    }
    if (negativeIds.has(item.id)) fail(`duplicate negative case: ${item.id}`)
    negativeIds.add(item.id)
    if (typeof item.feature !== 'string' || !/^[a-z][a-z0-9-]+$/.test(item.feature)) {
      fail(`negative case ${item.id} has an invalid feature`)
    }
    if (
      typeof item.source !== 'string' ||
      item.source.length === 0 ||
      !item.source.endsWith('\n') ||
      Buffer.byteLength(item.source, 'utf8') > 8192 ||
      item.source.includes('\r') ||
      item.source.includes('\u0000')
    ) {
      fail(`negative case ${item.id} has invalid source`)
    }
    exactKeys(item.expected, ['message', 'line', 'column'], `${item.id} expected`)
    if (
      typeof item.expected.message !== 'string' ||
      item.expected.message.length === 0 ||
      Buffer.byteLength(item.expected.message, 'utf8') > 4096 ||
      /[\u0000\r\n]/.test(item.expected.message) ||
      !Number.isSafeInteger(item.expected.line) ||
      item.expected.line < 1 ||
      !Number.isSafeInteger(item.expected.column) ||
      item.expected.column < 1
    ) {
      fail(`negative case ${item.id} has invalid expected metadata`)
    }
    return item
  })
  return { ...value, exclusions, negativeCases }
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
  return sorted(output)
}

function collectTree(sourceRoot, sourceRelative, targetRelative, output) {
  const relative = safeRelative(sourceRelative, 'source path')
  const filename = path.resolve(sourceRoot, ...relative.split('/'))
  if (!filename.startsWith(`${sourceRoot}${path.sep}`)) fail(`source path escapes root: ${relative}`)
  const stat = fs.lstatSync(filename)
  if (stat.isSymbolicLink()) fail(`source contains a symlink: ${relative}`)
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(filename, { withFileTypes: true }).sort((left, right) => (
      Buffer.from(left.name).compare(Buffer.from(right.name))
    ))) {
      collectTree(
        sourceRoot,
        `${relative}/${entry.name}`,
        `${targetRelative}/${entry.name}`,
        output,
      )
    }
    return
  }
  if (!stat.isFile()) fail(`source contains a special file: ${relative}`)
  if (forbiddenExecutable.test(relative)) return
  const target = safeRelative(targetRelative, 'target path')
  const bytes = fs.readFileSync(filename)
  output.set(target, { bytes, source: relative })
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

function featureFor(name) {
  const first = name.split('.')[0]
  const mapped = {
    atrules: 'at-rules',
    atblock: 'at-rules',
    atscope: 'at-rules',
    bifs: 'built-ins',
    for: 'control',
    if: 'control',
    function: 'functions',
    functions: 'functions',
    import: 'imports',
    require: 'imports',
    mixin: 'mixins',
    mixins: 'mixins',
    operator: 'operators',
    operators: 'operators',
    selector: 'selectors',
    selectors: 'selectors',
  }[first] ?? first
  return mapped.replace(/[^a-z0-9-]+/g, '-')
}

function main() {
  const arguments_ = parseArguments(process.argv.slice(2))
  const selection = readSelection()
  const sourceStat = fs.lstatSync(arguments_.source)
  if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) {
    fail('--source must be a regular extracted Stylus repository directory')
  }
  if (arguments_.archive !== null) {
    const archiveStat = fs.lstatSync(arguments_.archive)
    if (!archiveStat.isFile() || archiveStat.isSymbolicLink()) {
      fail('--archive must be a regular file')
    }
    const digest = sha256(fs.readFileSync(arguments_.archive))
    if (digest !== selection.upstream.archiveSha256) fail(`archive checksum mismatch: ${digest}`)
  }

  const packageBytes = fs.readFileSync(path.join(arguments_.source, 'package.json'))
  const packageValue = JSON.parse(packageBytes)
  if (
    packageValue.name !== 'stylus' ||
    packageValue.version !== selection.upstream.packageVersion ||
    packageValue.license !== selection.upstream.license ||
    sha256(packageBytes) !== selection.upstream.packageSha256
  ) {
    fail('package.json does not match the reviewed provider identity')
  }
  const testRun = fs.readFileSync(path.join(arguments_.source, 'test/run.js'))
  if (sha256(testRun) !== selection.upstream.testRunSha256) {
    fail('test/run.js does not match the reviewed official harness')
  }
  const license = fs.readFileSync(path.join(arguments_.source, 'LICENSE'))
  if (sha256(license) !== selection.upstream.licenseSha256) {
    fail('LICENSE does not match the reviewed MIT text')
  }

  const casesDirectory = path.join(arguments_.source, 'test/cases')
  const candidates = sorted(fs.readdirSync(casesDirectory)
    .filter(name => name.endsWith('.styl'))
    .map(name => name.slice(0, -5))
    .filter(name => name !== 'index'))
  for (const name of candidates) {
    safeName(name, 'official case')
    const expected = path.join(casesDirectory, `${name}.css`)
    if (!fs.lstatSync(expected).isFile()) fail(`official case ${name} has no paired CSS`)
  }
  const candidateNames = new Set(candidates)
  for (const item of selection.exclusions) {
    if (!candidateNames.has(item.name)) fail(`excluded case is not official: ${item.name}`)
  }
  const excluded = new Set(selection.exclusions.map(item => item.name))
  const selected = candidates.filter(name => !excluded.has(name))

  const selectedFiles = new Map()
  collectTree(arguments_.source, 'test/cases', 'upstream/cases', selectedFiles)
  collectTree(arguments_.source, 'test/images', 'upstream/images', selectedFiles)
  for (const item of selection.negativeCases) {
    const relative = `integration/errors/${item.id}.styl`
    selectedFiles.set(relative, {
      bytes: Buffer.from(item.source),
      source: `selection.json#negativeCases/${item.id}`,
    })
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

  const successCases = selected.map(name => ({
    id: `stylus-official-${name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`,
    feature: featureFor(name),
    source: 'official',
    upstreamName: name,
    outcome: 'success',
    entry: `upstream/cases/${name}.styl`,
    expected: `upstream/cases/${name}.css`,
    style: name.includes('compress') ? 'compressed' : 'expanded',
    providerOptions: {
      hoistAtrules: name.includes('hoist.'),
      includeCss: name.includes('include'),
    },
  }))
  const errorCases = selection.negativeCases.map(item => ({
    id: `stylus-integration-${item.id}`,
    feature: item.feature,
    source: 'integration',
    upstreamName: null,
    outcome: 'error',
    entry: `integration/errors/${item.id}.styl`,
    expected: item.expected,
    style: 'expanded',
    providerOptions: { hoistAtrules: false, includeCss: false },
  }))
  const cases = [...successCases, ...errorCases]
  const manifest = {
    schemaVersion: 1,
    upstream: selection.upstream,
    licenseFile: { path: 'STYLUS_LICENSE', sha256: sha256(license) },
    officialCandidateCount: candidates.length,
    excludedCount: selection.exclusions.length,
    officialSuccessCount: successCases.length,
    integrationErrorCount: errorCases.length,
    caseCount: cases.length,
    exclusions: selection.exclusions,
    files: orderedFiles.map(([relative, file]) => ({
      path: relative,
      source: file.source,
      bytes: file.bytes.length,
      sha256: sha256(file.bytes),
    })),
    cases,
  }
  writeOrCheck(licensePath, license, arguments_.mode)
  writeOrCheck(manifestPath, Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`), arguments_.mode)
  process.stdout.write(
    `Stylus corpus ${arguments_.mode}: ${manifest.caseCount} cases, ${manifest.files.length} files\n`,
  )
}

main()
