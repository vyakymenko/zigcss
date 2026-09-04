import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readStableUtf8File } from './bounded-filesystem.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const metadataPath = path.join(repositoryRoot, 'docs', 'src', 'data', 'capabilities.json')
export const startMarker = '<!-- capability-status:start -->'
export const endMarker = '<!-- capability-status:end -->'
export const generatedTargets = [
  path.join(repositoryRoot, 'docs', 'src', 'content', 'docs', 'guide', 'status.md'),
]
const maximumSourceBytes = 2 * 1024 * 1024

function fail(message) {
  throw new Error(`capability metadata: ${message}`)
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.length === 0) fail(`${label} must be a non-empty string`)
}

function readText(filename, label) {
  return readStableUtf8File(filename, {
    label,
    maximumBytes: maximumSourceBytes,
    reject: fail,
  })
}

function validateGateCommand(command, root) {
  const rootManifest = JSON.parse(readText(path.join(root, 'package.json'), 'root package manifest'))
  const docsManifest = JSON.parse(readText(path.join(root, 'docs', 'package.json'), 'documentation package manifest'))
  const rootMatch = /^npm run ([a-z0-9:-]+)$/.exec(command)
  if (rootMatch) {
    if (rootManifest.scripts[rootMatch[1]] === undefined) fail(`gate command has no root script: ${command}`)
    return
  }
  if (command === 'npm --prefix docs test -- --run') {
    if (docsManifest.scripts.test === undefined) fail('docs test script is missing')
    return
  }
  const zigMatch = /^zig build ([a-z0-9-]+) --summary all$/.exec(command)
  if (zigMatch) {
    const buildSource = readText(path.join(root, 'build.zig'), 'Zig build source')
    const escapedStep = zigMatch[1].replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    if (!new RegExp(`\\bb\\.step\\(\\s*"${escapedStep}"`).test(buildSource)) {
      fail(`gate command has no Zig build step: ${command}`)
    }
    return
  }
  fail(`unsupported gate command: ${command}`)
}

export function loadMetadata() {
  return JSON.parse(readText(metadataPath, 'capability metadata'))
}

export function validateMetadata(metadata, root = repositoryRoot) {
  if (metadata === null || typeof metadata !== 'object' || Array.isArray(metadata)) fail('root must be an object')
  if (metadata.schemaVersion !== 1) fail('schemaVersion must be 1')
  if (!Array.isArray(metadata.statusKinds) || metadata.statusKinds.length !== 4) fail('statusKinds must define four closed values')
  const allowedKinds = new Set(['experimental', 'verified', 'unavailable', 'disabled'])
  if (new Set(metadata.statusKinds).size !== allowedKinds.size || metadata.statusKinds.some(kind => !allowedKinds.has(kind))) {
    fail('statusKinds does not match the closed vocabulary')
  }
  if (metadata.gates === null || typeof metadata.gates !== 'object' || Array.isArray(metadata.gates)) fail('gates must be an object')
  if (!Array.isArray(metadata.capabilities) || metadata.capabilities.length === 0) fail('capabilities must be a non-empty array')

  const canonicalRoot = fs.realpathSync(root)
  const gateIds = new Set(Object.keys(metadata.gates))
  const usedGateIds = new Set()
  for (const [gateId, gate] of Object.entries(metadata.gates)) {
    if (!/^[a-z0-9-]+$/.test(gateId)) fail(`invalid gate id: ${gateId}`)
    if (gate === null || typeof gate !== 'object' || Array.isArray(gate)) fail(`gate ${gateId} must be an object`)
    requireString(gate.command, `gate ${gateId} command`)
    validateGateCommand(gate.command, root)
    if (!Array.isArray(gate.anchors) || gate.anchors.length === 0) fail(`gate ${gateId} needs an anchor`)
    for (const [anchorIndex, anchor] of gate.anchors.entries()) {
      requireString(anchor.path, `gate ${gateId} anchor ${anchorIndex} path`)
      if (path.isAbsolute(anchor.path) || anchor.path.split(/[\\/]/).includes('..')) fail(`gate ${gateId} anchor escapes the repository`)
      const absolutePath = path.resolve(root, anchor.path)
      const relative = path.relative(root, absolutePath)
      if (relative.startsWith('..') || path.isAbsolute(relative)) fail(`gate ${gateId} anchor escapes the repository`)
      const canonicalPath = fs.realpathSync(absolutePath)
      const canonicalRelative = path.relative(canonicalRoot, canonicalPath)
      if (canonicalRelative.startsWith('..') || path.isAbsolute(canonicalRelative)) fail(`gate ${gateId} anchor escapes the repository`)
      if (!Array.isArray(anchor.contains) || anchor.contains.length === 0) fail(`gate ${gateId} anchor needs a content assertion`)
      const content = readText(absolutePath, `gate ${gateId} anchor ${anchor.path}`)
      for (const [needleIndex, needle] of anchor.contains.entries()) {
        requireString(needle, `gate ${gateId} anchor ${anchorIndex} content ${needleIndex}`)
        if (!content.includes(needle)) fail(`gate ${gateId} anchor ${anchor.path} is missing: ${needle}`)
      }
    }
  }

  const ids = new Set()
  const surfaces = new Set()
  for (const [index, capability] of metadata.capabilities.entries()) {
    if (capability === null || typeof capability !== 'object' || Array.isArray(capability)) fail(`capability ${index} must be an object`)
    requireString(capability.id, `capability ${index} id`)
    if (!/^[a-z0-9-]+$/.test(capability.id) || ids.has(capability.id)) fail(`invalid or duplicate capability id: ${capability.id}`)
    ids.add(capability.id)
    requireString(capability.surface, `capability ${capability.id} surface`)
    if (surfaces.has(capability.surface)) fail(`duplicate capability surface: ${capability.surface}`)
    surfaces.add(capability.surface)
    requireString(capability.status, `capability ${capability.id} status`)
    if (!allowedKinds.has(capability.statusKind)) fail(`capability ${capability.id} has unknown statusKind`)
    const validStatus =
      (capability.statusKind === 'experimental' && capability.status.startsWith('Experimental')) ||
      (capability.statusKind === 'verified' && /verified/i.test(capability.status)) ||
      (capability.statusKind === 'unavailable' && capability.status === 'Unavailable') ||
      (capability.statusKind === 'disabled' && capability.status === 'Disabled')
    if (!validStatus) fail(`capability ${capability.id} status contradicts statusKind`)
    requireString(capability.behavior, `capability ${capability.id} behavior`)
    if (capability.behavior.includes('\n') || capability.behavior.includes('|')) fail(`capability ${capability.id} behavior must fit one safe table cell`)
    if (!/^(?:[^`]|`[^`\r\n]+`)*$/.test(capability.behavior)) fail(`capability ${capability.id} behavior has invalid inline code markup`)
    if (!Array.isArray(capability.evidence) || capability.evidence.length === 0) fail(`capability ${capability.id} has no evidence`)
    if (new Set(capability.evidence).size !== capability.evidence.length) fail(`capability ${capability.id} repeats evidence`)
    for (const gateId of capability.evidence) {
      if (!gateIds.has(gateId)) fail(`capability ${capability.id} references unknown gate ${gateId}`)
      usedGateIds.add(gateId)
    }
  }
  for (const gateId of gateIds) if (!usedGateIds.has(gateId)) fail(`unused evidence gate: ${gateId}`)
  return metadata
}

function escapeCell(value) {
  return value.replaceAll('\\', '\\\\').replaceAll('|', '\\|').replaceAll('\r', ' ').replaceAll('\n', ' ')
}

export function renderTable(metadata) {
  const rows = [
    '| Surface | Status | Current behavior |',
    '|---|---|---|',
    ...metadata.capabilities.map(capability =>
      `| ${escapeCell(capability.surface)} | ${escapeCell(capability.status)} | ${escapeCell(capability.behavior)} |`),
  ]
  return rows.join('\n')
}

export function replaceGeneratedTable(content, table) {
  const start = content.indexOf(startMarker)
  const end = content.indexOf(endMarker)
  if (start === -1 || end === -1 || end < start) fail('generated target is missing ordered markers')
  if (content.indexOf(startMarker, start + startMarker.length) !== -1 || content.indexOf(endMarker, end + endMarker.length) !== -1) {
    fail('generated target has duplicate markers')
  }
  return `${content.slice(0, start)}${startMarker}\n${table}\n${endMarker}${content.slice(end + endMarker.length)}`
}

export function expectedTargets(metadata = validateMetadata(loadMetadata())) {
  const table = renderTable(metadata)
  return generatedTargets.map(target => {
    const current = readText(target, `generated target ${path.relative(repositoryRoot, target)}`)
    return { target, current, content: replaceGeneratedTable(current, table) }
  })
}

function main() {
  const mode = process.argv[2]
  if ((mode !== '--check' && mode !== '--write') || process.argv.length !== 3) {
    throw new Error('usage: node scripts/generate-capability-status.mjs --check|--write')
  }
  const metadata = validateMetadata(loadMetadata())
  const targets = expectedTargets(metadata)
  const stale = targets.filter(({ current, content }) => current !== content)
  if (mode === '--write') {
    for (const { target, content } of stale) fs.writeFileSync(target, content)
  } else if (stale.length !== 0) {
    throw new Error(`generated capability tables are stale: ${stale.map(({ target }) => path.relative(repositoryRoot, target)).join(', ')}`)
  }
  process.stdout.write(
    `Capability status ${mode === '--write' ? 'generated' : 'verified'}: ${metadata.capabilities.length} rows, ${Object.keys(metadata.gates).length} executable evidence gates, ${targets.length} Markdown table${targets.length === 1 ? '' : 's'}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
