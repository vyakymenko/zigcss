import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const corpusVersion = 'v1'
const relativeCorpusDirectory = path.join('benchmarks', 'corpora', corpusVersion)
const manifestName = 'manifest.json'
const corpusSpecs = [
  { id: 'small-flat', file: 'small.css', qualifiedRules: 1 },
  { id: 'medium-flat', file: 'medium.css', qualifiedRules: 128 },
  { id: 'large-flat', file: 'large.css', qualifiedRules: 2048 },
]

function fail(message) {
  throw new Error(`benchmark corpus: ${message}`)
}

function compareAscii(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function hexColor(index, salt) {
  const mixed = (Math.imul(index + 1, 0x9e3779b1) ^ salt) >>> 0
  return (mixed & 0xffffff).toString(16).padStart(6, '0')
}

function generateFlatCorpus(ruleCount) {
  let css = ''
  for (let index = 0; index < ruleCount; index += 1) {
    const selector = index.toString(10).padStart(4, '0')
    const foreground = hexColor(index, 0x13579bdf)
    const background = hexColor(index, 0x2468ace0)
    css += `.component-${selector}{color:#${foreground};background:#${background};padding:${index % 29}px ${index % 17}px;margin:${index % 23}px;border-radius:${index % 13}px}\n`
  }
  return css
}

function analyzeFlatCorpus(content) {
  if (!content.endsWith('\n')) fail('generated corpus must end with LF')
  const lines = content.slice(0, -1).split('\n')
  for (const [index, line] of lines.entries()) {
    const selector = index.toString(10).padStart(4, '0')
    const pattern = new RegExp(
      `^\\.component-${selector}\\{color:#[0-9a-f]{6};background:#[0-9a-f]{6};padding:[0-9]+px [0-9]+px;margin:[0-9]+px;border-radius:[0-9]+px\\}$`,
    )
    if (!pattern.test(line)) fail(`generated rule ${index} violates the closed flat-corpus grammar`)
  }
  return {
    qualifiedRules: lines.length,
    atRules: 0,
    declarations: lines.length * 5,
    maxRuleDepth: 1,
  }
}

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex')
}

function renderManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`
}

export function expectedCorpus() {
  const files = corpusSpecs.map(spec => {
    const content = generateFlatCorpus(spec.qualifiedRules)
    const complexity = analyzeFlatCorpus(content)
    if (complexity.qualifiedRules !== spec.qualifiedRules) fail(`generated rule count drifted for ${spec.id}`)
    return {
      name: spec.file,
      content,
      record: {
        id: spec.id,
        path: path.posix.join('benchmarks', 'corpora', corpusVersion, spec.file),
        bytes: Buffer.byteLength(content),
        sha256: sha256(content),
        complexity,
      },
    }
  })
  const manifest = {
    schemaVersion: 1,
    corpusVersion,
    generator: 'scripts/generate-benchmark-corpora.mjs',
    measurement: {
      bytes: 'Exact UTF-8 file length, including the final LF.',
      sha256: 'Lowercase SHA-256 of the exact file bytes.',
      complexity: {
        qualifiedRules: 'Qualified style-rule blocks.',
        atRules: 'At-rule statements and blocks.',
        declarations: 'Declarations inside qualified and at-rule blocks.',
        maxRuleDepth: 'Maximum nested rule depth; a top-level rule has depth 1.',
      },
    },
    corpora: files.map(file => file.record),
  }
  return {
    manifest,
    manifestContent: renderManifest(manifest),
    files: files.map(({ name, content }) => ({ name, content })),
  }
}

function confinedCorpusDirectory(root, create) {
  const absoluteRoot = fs.realpathSync(root)
  const directory = path.join(absoluteRoot, relativeCorpusDirectory)
  if (create) fs.mkdirSync(directory, { recursive: true })
  const directoryStat = fs.lstatSync(directory)
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    fail('version directory must be a real directory')
  }
  const canonicalDirectory = fs.realpathSync(directory)
  const relative = path.relative(absoluteRoot, canonicalDirectory)
  if (relative.startsWith('..') || path.isAbsolute(relative)) fail('version directory escapes the repository')
  return canonicalDirectory
}

function requireRegularFile(file) {
  const stat = fs.lstatSync(file)
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`corpus entry must be a regular non-symlink file: ${path.basename(file)}`)
}

function writeAtomic(file, content) {
  if (fs.existsSync(file)) requireRegularFile(file)
  const temporary = `${file}.zigcss-tmp`
  if (fs.existsSync(temporary)) fail(`refusing to replace existing temporary file: ${path.basename(temporary)}`)
  try {
    fs.writeFileSync(temporary, content, { flag: 'wx', mode: 0o644 })
    fs.renameSync(temporary, file)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

export function writeRepository(root = repositoryRoot) {
  const expected = expectedCorpus()
  const directory = confinedCorpusDirectory(root, true)
  for (const file of expected.files) writeAtomic(path.join(directory, file.name), file.content)
  writeAtomic(path.join(directory, manifestName), expected.manifestContent)
  return validateRepository(root)
}

export function validateRepository(root = repositoryRoot) {
  const expected = expectedCorpus()
  const directory = confinedCorpusDirectory(root, false)
  const expectedNames = [...expected.files.map(file => file.name), manifestName].sort(compareAscii)
  const actualNames = fs.readdirSync(directory).sort(compareAscii)
  if (actualNames.length !== expectedNames.length || actualNames.some((name, index) => name !== expectedNames[index])) {
    fail(`unexpected corpus inventory: expected ${expectedNames.join(', ')}, found ${actualNames.join(', ')}`)
  }

  for (const file of expected.files) {
    const target = path.join(directory, file.name)
    requireRegularFile(target)
    if (!fs.readFileSync(target).equals(Buffer.from(file.content))) fail(`stale corpus file: ${file.name}`)
  }

  const manifestPath = path.join(directory, manifestName)
  requireRegularFile(manifestPath)
  const manifestContent = fs.readFileSync(manifestPath, 'utf8')
  if (manifestContent !== expected.manifestContent) fail('stale corpus manifest: manifest.json')
  const manifest = JSON.parse(manifestContent)

  return {
    version: manifest.corpusVersion,
    corpora: manifest.corpora.length,
    bytes: manifest.corpora.reduce((total, corpus) => total + corpus.bytes, 0),
    qualifiedRules: manifest.corpora.reduce((total, corpus) => total + corpus.complexity.qualifiedRules, 0),
    declarations: manifest.corpora.reduce((total, corpus) => total + corpus.complexity.declarations, 0),
  }
}

function main() {
  const mode = process.argv[2]
  if ((mode !== '--check' && mode !== '--write') || process.argv.length !== 3) {
    fail('usage: node scripts/generate-benchmark-corpora.mjs --check|--write')
  }
  const report = mode === '--write' ? writeRepository() : validateRepository()
  process.stdout.write(
    `Benchmark corpus ${mode === '--write' ? 'generated' : 'verified'} ${report.version}: ${report.corpora} corpora, ${report.bytes} bytes, ${report.qualifiedRules} qualified rules, ${report.declarations} declarations.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
