import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import zlib from 'node:zlib'
import { fileURLToPath } from 'node:url'

const docsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const distRoot = path.join(docsRoot, 'dist')
const manifestPath = path.join(distRoot, '.vite', 'manifest.json')
const budgetBytes = 160 * 1024

if (!fs.existsSync(manifestPath)) {
  throw new Error('bundle budget: Vite manifest is missing; run the production build first')
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const files = new Set()
const visited = new Set()

function manifestKeyFor(source) {
  return Object.entries(manifest).find(([key, value]) => key === source || value.src === source)?.[0]
}

function collect(key) {
  if (!key || visited.has(key)) return
  const entry = manifest[key]
  if (!entry) throw new Error(`bundle budget: manifest entry is missing: ${key}`)
  visited.add(key)
  if (entry.file?.endsWith('.js')) files.add(entry.file)
  for (const imported of entry.imports ?? []) collect(imported)
}

for (const source of ['index.html', 'src/app/components/Home.tsx']) {
  const key = manifestKeyFor(source)
  if (!key) throw new Error(`bundle budget: landing source is missing from the manifest: ${source}`)
  collect(key)
}

const gzipBytes = [...files].reduce((total, relativePath) => {
  const bytes = fs.readFileSync(path.join(distRoot, relativePath))
  return total + zlib.gzipSync(bytes, { level: 9 }).byteLength
}, 0)

if (gzipBytes > budgetBytes) {
  throw new Error(`bundle budget: landing JavaScript is ${gzipBytes} bytes gzip; limit is ${budgetBytes}`)
}

process.stdout.write(
  `Landing JavaScript budget verified: ${(gzipBytes / 1024).toFixed(1)} KiB gzip across ${files.size} chunks (limit ${(budgetBytes / 1024).toFixed(0)} KiB).\n`,
)
