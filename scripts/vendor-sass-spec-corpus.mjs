import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const selectionPath = path.join(
  repositoryRoot,
  'tests/preprocessors/sass/corpus/selection.json',
)
const corpusRoot = path.join(repositoryRoot, 'tests/preprocessors/sass/corpus')
const casesRoot = path.join(corpusRoot, 'cases')
const manifestPath = path.join(corpusRoot, 'manifest.json')
const licensePath = path.join(corpusRoot, 'SASS_SPEC_LICENSE')

function fail(message) {
  throw new Error(message)
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

function parseArguments(argumentsList) {
  let source = null
  let mode = null
  let archive = null
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index]
    if (argument === '--source' || argument === '--archive') {
      if (index + 1 >= argumentsList.length) fail(`${argument} requires a path`)
      const value = path.resolve(argumentsList[index + 1])
      if (argument === '--source') source = value
      else archive = value
      index += 1
      continue
    }
    if (argument === '--write' || argument === '--check') {
      if (mode !== null) fail('choose exactly one of --write or --check')
      mode = argument.slice(2)
      continue
    }
    fail(`unknown argument: ${argument}`)
  }
  if (source === null) fail('--source is required')
  if (mode === null) fail('choose exactly one of --write or --check')
  return { archive, mode, source }
}

function parseHrx(bytes, label) {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  const files = new Map()
  let current = null
  let chunks = []

  function flush(beforeHeader = false) {
    if (current !== null) {
      if (files.has(current)) fail(`${label}: duplicate HRX path ${current}`)
      let contents = chunks.join('')
      if (beforeHeader && contents.endsWith('\n')) {
        contents = contents.slice(0, -1)
        if (contents.endsWith('\r')) contents = contents.slice(0, -1)
      }
      files.set(current, Buffer.from(contents, 'utf8'))
    }
    chunks = []
  }

  for (const line of text.match(/.*(?:\n|$)/g) ?? []) {
    if (line === '') continue
    const header = /^<===> ?([^\r\n]*)\r?\n?$/.exec(line)
    if (header !== null) {
      flush(true)
      current = header[1] === '' ? null : header[1]
      if (
        current !== null &&
        (path.posix.isAbsolute(current) || current.includes('\\') || current.split('/').includes('..'))
      ) {
        fail(`${label}: unsafe HRX path ${current}`)
      }
    } else if (current !== null) {
      chunks.push(line)
    }
  }
  flush()
  return files
}

function selection() {
  const value = JSON.parse(fs.readFileSync(selectionPath, 'utf8'))
  exactKeys(value, ['schemaVersion', 'upstream', 'cases'], 'selection')
  if (value.schemaVersion !== 1) fail(`unsupported selection schema ${value.schemaVersion}`)
  exactKeys(value.upstream, [
    'repository',
    'revision',
    'tree',
    'archiveSha256',
    'packageVersion',
    'packageSha256',
    'license',
    'licenseSha256',
    'dartSassVersion',
    'dartSassTagCommit',
  ], 'selection upstream')
  if (!Array.isArray(value.cases) || value.cases.length === 0) {
    fail('selection cases must be a nonempty array')
  }
  return value
}

function safeSourceFile(root, relativePath) {
  if (
    typeof relativePath !== 'string' ||
    !relativePath.startsWith('spec/') ||
    !relativePath.endsWith('.hrx') ||
    path.posix.isAbsolute(relativePath) ||
    relativePath.includes('\\') ||
    relativePath.split('/').includes('..')
  ) {
    fail(`unsafe Sass-spec source path: ${relativePath}`)
  }
  const filename = path.resolve(root, ...relativePath.split('/'))
  if (!filename.startsWith(`${root}${path.sep}`)) fail(`source path escapes root: ${relativePath}`)
  const stat = fs.lstatSync(filename)
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`source is not a regular file: ${relativePath}`)
  return filename
}

function selectedFiles(files, upstreamCase, label) {
  if (
    typeof upstreamCase !== 'string' ||
    upstreamCase === '' ||
    path.posix.isAbsolute(upstreamCase) ||
    upstreamCase.includes('\\') ||
    upstreamCase.split('/').includes('..')
  ) {
    fail(`${label}: invalid upstream case path`)
  }
  const prefix = upstreamCase === '.' ? '' : `${upstreamCase}/`
  const selected = new Map()
  for (const [filename, bytes] of files) {
    if (!filename.startsWith(prefix)) continue
    const relative = filename.slice(prefix.length)
    if (relative === '') continue
    selected.set(relative, bytes)
  }
  if (selected.size === 0) fail(`${label}: upstream case is empty`)
  const inputs = [...selected.keys()].filter(filename => /^input\.(?:scss|sass)$/.test(filename))
  if (inputs.length !== 1) {
    fail(`${label}: expected one root input, found ${JSON.stringify(inputs)}`)
  }
  return { files: selected, input: inputs[0] }
}

function expectationFor(files) {
  for (const name of ['output-dart-sass.css', 'output.css']) {
    if (files.has(name)) return { outcome: 'success', path: name }
  }
  for (const name of ['error-dart-sass', 'error']) {
    if (files.has(name)) return { outcome: 'error', path: name }
  }
  fail('selected Sass-spec case has no output or error expectation')
}

function warningFor(files) {
  for (const name of ['warning-dart-sass', 'warning']) {
    if (files.has(name)) return name
  }
  return null
}

function listFiles(root) {
  if (!fs.existsSync(root)) return []
  const output = []
  function visit(directory, relative) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isSymbolicLink()) fail(`generated corpus contains a symlink: ${entry.name}`)
      const childRelative = relative === '' ? entry.name : `${relative}/${entry.name}`
      const child = path.join(directory, entry.name)
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
  const actual = fs.readFileSync(filename)
  if (!actual.equals(bytes)) fail(`stale generated file: ${path.relative(repositoryRoot, filename)}`)
}

function main() {
  const args = parseArguments(process.argv.slice(2))
  const config = selection()
  if (!fs.statSync(args.source).isDirectory()) fail('--source must be an extracted Sass-spec directory')
  if (args.archive !== null) {
    const digest = sha256(fs.readFileSync(args.archive))
    if (digest !== config.upstream.archiveSha256) {
      fail(`Sass-spec archive checksum mismatch: ${digest}`)
    }
  }

  const packageBytes = fs.readFileSync(path.join(args.source, 'package.json'))
  const packageJson = JSON.parse(packageBytes)
  if (
    packageJson.name !== 'sass-spec' ||
    packageJson.version !== config.upstream.packageVersion ||
    packageJson.license !== config.upstream.license ||
    sha256(packageBytes) !== config.upstream.packageSha256
  ) {
    fail('Sass-spec package identity does not match the reviewed pin')
  }
  const licenseBytes = fs.readFileSync(path.join(args.source, 'LICENSE'))
  if (sha256(licenseBytes) !== config.upstream.licenseSha256) {
    fail('Sass-spec license does not match the reviewed MIT text')
  }

  const ids = new Set()
  const expectedFiles = new Set()
  const sourceCache = new Map()
  const cases = []
  for (const [index, selectedCase] of config.cases.entries()) {
    exactKeys(
      selectedCase,
      ['id', 'feature', 'source', 'upstreamCase', 'syntax', 'outcome'],
      `selection case ${index}`,
    )
    if (typeof selectedCase.id !== 'string' || !/^[a-z][a-z0-9-]+$/.test(selectedCase.id)) {
      fail(`selection case ${index}: invalid id`)
    }
    if (ids.has(selectedCase.id)) fail(`duplicate case id: ${selectedCase.id}`)
    ids.add(selectedCase.id)
    if (typeof selectedCase.feature !== 'string' || !/^[a-z][a-z0-9-]+$/.test(selectedCase.feature)) {
      fail(`${selectedCase.id}: invalid feature`)
    }
    if (!['scss', 'sass'].includes(selectedCase.syntax)) fail(`${selectedCase.id}: invalid syntax`)
    if (!['success', 'error'].includes(selectedCase.outcome)) fail(`${selectedCase.id}: invalid outcome`)

    let source = sourceCache.get(selectedCase.source)
    if (source === undefined) {
      const filename = safeSourceFile(args.source, selectedCase.source)
      const bytes = fs.readFileSync(filename)
      source = { bytes, files: parseHrx(bytes, selectedCase.source) }
      sourceCache.set(selectedCase.source, source)
    }
    const chosen = selectedFiles(
      source.files,
      selectedCase.upstreamCase,
      `${selectedCase.source}:${selectedCase.upstreamCase}`,
    )
    const syntax = path.posix.extname(chosen.input).slice(1)
    const expectation = expectationFor(chosen.files)
    if (syntax !== selectedCase.syntax || expectation.outcome !== selectedCase.outcome) {
      fail(`${selectedCase.id}: selected syntax or outcome does not match upstream`)
    }

    const files = []
    for (const [relativePath, bytes] of [...chosen.files].sort(([left], [right]) => (
      Buffer.from(left).compare(Buffer.from(right))
    ))) {
      const generatedRelative = `${selectedCase.id}/${relativePath}`
      expectedFiles.add(generatedRelative)
      writeOrCheck(path.join(casesRoot, ...generatedRelative.split('/')), bytes, args.mode)
      files.push({
        path: relativePath,
        bytes: bytes.length,
        sha256: sha256(bytes),
      })
    }
    cases.push({
      id: selectedCase.id,
      feature: selectedCase.feature,
      syntax,
      outcome: expectation.outcome,
      entry: chosen.input,
      expected: expectation.path,
      warning: warningFor(chosen.files),
      upstream: {
        source: selectedCase.source,
        case: selectedCase.upstreamCase,
        sourceSha256: sha256(source.bytes),
      },
      files,
    })
  }

  const actualFiles = listFiles(casesRoot)
  const wantedFiles = [...expectedFiles].sort((left, right) => Buffer.from(left).compare(Buffer.from(right)))
  if (JSON.stringify(actualFiles) !== JSON.stringify(wantedFiles)) {
    fail(`generated case inventory differs: expected ${wantedFiles.length}, found ${actualFiles.length}`)
  }

  const manifest = {
    schemaVersion: 1,
    upstream: config.upstream,
    licenseFile: {
      path: 'SASS_SPEC_LICENSE',
      sha256: sha256(licenseBytes),
    },
    caseCount: cases.length,
    cases,
  }
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  writeOrCheck(licensePath, licenseBytes, args.mode)
  writeOrCheck(manifestPath, manifestBytes, args.mode)
  process.stdout.write(`Sass corpus ${args.mode}: ${cases.length} cases, ${wantedFiles.length} files\n`)
}

main()
