#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { TextDecoder } from 'node:util'
import { gunzipSync } from 'node:zlib'
import { fileURLToPath } from 'node:url'
import {
  expectedPackedFiles,
  validatePackageDescription,
} from './validate-preprocessor-package.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const npmPackageArtifactLimits = Object.freeze({
  archiveBytes: 2 * 1024 * 1024,
  unpackedBytes: 4 * 1024 * 1024,
  tarBytes: 5 * 1024 * 1024,
  manifestBytes: 256 * 1024,
  packDescriptionBytes: 4 * 1024 * 1024,
  githubOutputBytes: 1024 * 1024,
})

const decoder = new TextDecoder('utf-8', { fatal: true })
const tarBlockBytes = 512
export const npmPackageExecutableFiles = Object.freeze(['index.js', 'install.js'])

function fail(message) {
  throw new Error(`npm package artifact: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function regularFile(filename, label, maximumBytes, permitEmpty = false) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename) || filename.includes('\0')) {
    fail(`${label} must be an absolute local path`)
  }
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if ((!permitEmpty && stat.size <= 0) || stat.size > maximumBytes) fail(`${label} has an invalid byte size`)
  return stat
}

function decodeField(bytes, label) {
  let end = bytes.indexOf(0)
  if (end === -1) end = bytes.length
  let value
  try {
    value = decoder.decode(bytes.subarray(0, end))
  } catch (error) {
    fail(`${label} is not UTF-8: ${error.message}`)
  }
  if (/[\0\r\n]/.test(value)) fail(`${label} contains control bytes`)
  return value
}

function parseOctal(bytes, label) {
  if ((bytes[0] & 0x80) !== 0) fail(`${label} uses an unsupported base-256 number`)
  const source = Buffer.from(bytes).toString('ascii').replaceAll('\0', '').trim()
  if (!/^[0-7]+$/.test(source)) fail(`${label} is not canonical octal`)
  const value = Number.parseInt(source, 8)
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} is outside the safe integer range`)
  return value
}

function checksum(header) {
  let total = 0
  for (let index = 0; index < header.length; index += 1) {
    total += index >= 148 && index < 156 ? 0x20 : header[index]
  }
  return total
}

function zeroBlock(block) {
  return block.every(byte => byte === 0)
}

function validateTarPath(value) {
  if (
    value.length === 0
    || value.startsWith('/')
    || value.includes('\\')
    || value.split('/').some(component => component === '' || component === '.' || component === '..')
  ) {
    fail(`archive entry path is unsafe: ${JSON.stringify(value)}`)
  }
  if (!value.startsWith('package/')) fail(`archive entry is outside package/: ${JSON.stringify(value)}`)
  const relative = value.slice('package/'.length)
  if (!expectedPackedFiles.includes(relative)) {
    fail(`archive entry is not in the exact package allowlist: ${JSON.stringify(relative)}`)
  }
  return relative
}

function parseTar(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > npmPackageArtifactLimits.tarBytes) {
    fail('uncompressed tar has an invalid byte size')
  }
  if (bytes.length % tarBlockBytes !== 0) fail('uncompressed tar is not block-aligned')

  const entries = []
  const seen = new Set()
  let unpackedBytes = 0
  let offset = 0
  let terminated = false

  while (offset + tarBlockBytes <= bytes.length) {
    const header = bytes.subarray(offset, offset + tarBlockBytes)
    if (zeroBlock(header)) {
      const second = bytes.subarray(offset + tarBlockBytes, offset + 2 * tarBlockBytes)
      if (second.length !== tarBlockBytes || !zeroBlock(second)) {
        fail('tar terminator must contain two zero blocks')
      }
      if (!zeroBlock(bytes.subarray(offset))) fail('tar contains nonzero trailing bytes')
      terminated = true
      break
    }

    if (decodeField(header.subarray(257, 263), 'tar magic') !== 'ustar') {
      fail('tar entry does not use the ustar format')
    }
    if (decodeField(header.subarray(263, 265), 'tar version') !== '00') {
      fail('tar entry has an unsupported ustar version')
    }
    const storedChecksum = parseOctal(header.subarray(148, 156), 'tar checksum')
    if (storedChecksum !== checksum(header)) fail('tar header checksum does not match')

    const prefix = decodeField(header.subarray(345, 500), 'tar path prefix')
    const name = decodeField(header.subarray(0, 100), 'tar path')
    const combined = prefix === '' ? name : `${prefix}/${name}`
    const relative = validateTarPath(combined)
    if (seen.has(relative)) fail(`tar contains duplicate entry ${relative}`)
    seen.add(relative)

    const type = header[156]
    if (type !== 0 && type !== 0x30) fail(`${relative} must be a regular tar entry`)
    if (decodeField(header.subarray(157, 257), 'tar link target') !== '') {
      fail(`${relative} must not carry a link target`)
    }
    const mode = parseOctal(header.subarray(100, 108), `${relative} mode`) & 0o777
    const expectedMode = npmPackageExecutableFiles.includes(relative) ? 0o755 : 0o644
    if (mode !== expectedMode) fail(`${relative} has mode ${mode.toString(8)} instead of ${expectedMode.toString(8)}`)
    const size = parseOctal(header.subarray(124, 136), `${relative} size`)
    if (size <= 0 || size > npmPackageArtifactLimits.unpackedBytes) {
      fail(`${relative} has an invalid byte size`)
    }
    unpackedBytes += size
    if (!Number.isSafeInteger(unpackedBytes) || unpackedBytes > npmPackageArtifactLimits.unpackedBytes) {
      fail('package unpacked bytes exceed the limit')
    }

    const contentStart = offset + tarBlockBytes
    const contentEnd = contentStart + size
    const paddedEnd = contentStart + Math.ceil(size / tarBlockBytes) * tarBlockBytes
    if (contentEnd > bytes.length || paddedEnd > bytes.length) fail(`${relative} content is truncated`)
    entries.push(Object.freeze({
      path: relative,
      size,
      mode,
      content: Buffer.from(bytes.subarray(contentStart, contentEnd)),
    }))
    offset = paddedEnd
  }

  if (!terminated) fail('tar is missing its canonical terminator')
  const actualFiles = entries.map(entry => entry.path).sort()
  if (!same(actualFiles, [...expectedPackedFiles])) {
    fail(`tar package inventory changed: ${JSON.stringify(actualFiles)}`)
  }
  return Object.freeze({ entries: Object.freeze(entries), unpackedBytes })
}

function parseManifest(entry, version, expectedManifestSource) {
  if (entry.size > npmPackageArtifactLimits.manifestBytes) fail('package.json exceeds its byte limit')
  let text
  try {
    text = decoder.decode(entry.content)
  } catch (error) {
    fail(`package.json is not UTF-8: ${error.message}`)
  }
  let manifest
  try {
    manifest = JSON.parse(text)
  } catch (error) {
    fail(`package.json is not JSON: ${error.message}`)
  }
  if (manifest?.name !== 'zigcss' || manifest.version !== version) {
    fail('package.json identity does not match the release')
  }
  if (expectedManifestSource !== undefined) {
    const expected = Buffer.isBuffer(expectedManifestSource)
      ? expectedManifestSource
      : Buffer.from(expectedManifestSource)
    if (!entry.content.equals(expected)) fail('packed package.json differs from the tested manifest')
  }
  return Object.freeze({ text, value: manifest })
}

export function inspectNpmPackageBytes(source, version, expectedManifestSource = undefined) {
  parseReleaseVersion(version, 'npm package artifact version')
  const bytes = Buffer.isBuffer(source) ? source : Buffer.from(source)
  if (bytes.length <= 0 || bytes.length > npmPackageArtifactLimits.archiveBytes) {
    fail('package archive has an invalid byte size')
  }
  let tar
  try {
    tar = gunzipSync(bytes, { maxOutputLength: npmPackageArtifactLimits.tarBytes })
  } catch (error) {
    fail(`package archive is not bounded gzip data: ${error.message}`)
  }
  const parsed = parseTar(tar)
  const manifestEntry = parsed.entries.find(entry => entry.path === 'package.json')
  if (manifestEntry === undefined) fail('package archive is missing package.json')
  const manifest = parseManifest(manifestEntry, version, expectedManifestSource)
  const files = parsed.entries.map(entry => Object.freeze({
    path: entry.path,
    size: entry.size,
    mode: entry.mode,
  })).sort((left, right) => left.path.localeCompare(right.path, 'en'))
  return Object.freeze({
    name: 'zigcss',
    version,
    bytes: bytes.length,
    unpackedBytes: parsed.unpackedBytes,
    entryCount: files.length,
    shasum: crypto.createHash('sha1').update(bytes).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(bytes).digest('base64')}`,
    files: Object.freeze(files),
    manifestText: manifest.text,
  })
}

export function inspectNpmPackageArchive(filename, version, manifestFilename = path.join(repositoryRoot, 'package.json')) {
  regularFile(filename, 'package archive', npmPackageArtifactLimits.archiveBytes)
  if (path.basename(filename) !== `zigcss-${version}.tgz`) {
    fail('package archive filename does not match its release version')
  }
  regularFile(manifestFilename, 'tested package manifest', npmPackageArtifactLimits.manifestBytes)
  return Object.freeze({
    ...inspectNpmPackageBytes(
      fs.readFileSync(filename),
      version,
      fs.readFileSync(manifestFilename),
    ),
    filename: path.basename(filename),
  })
}

function parsePackDescription(source) {
  if (typeof source !== 'string' || source.length === 0 || Buffer.byteLength(source) > npmPackageArtifactLimits.packDescriptionBytes) {
    fail('npm pack description is empty or oversized')
  }
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`npm pack description is not JSON: ${error.message}`)
  }
}

export function validatePackDescription(source, inspection) {
  const parsed = typeof source === 'string' ? parsePackDescription(source) : source
  if (!Array.isArray(parsed) || parsed.length !== 1) fail('npm pack must describe exactly one archive')
  const item = parsed[0]
  validatePackageDescription(item, inspection.version)
  if (
    item.name !== inspection.name
    || item.version !== inspection.version
    || item.filename !== inspection.filename
    || item.size !== inspection.bytes
    || item.unpackedSize !== inspection.unpackedBytes
    || item.entryCount !== inspection.entryCount
    || item.shasum !== inspection.shasum
    || item.integrity !== inspection.integrity
    || !Array.isArray(item.bundled)
    || item.bundled.length !== 0
  ) {
    fail('npm pack description does not match the exact archive bytes')
  }
  const describedFiles = item.files.map(file => ({
    path: file.path,
    size: file.size,
    mode: file.mode,
  })).sort((left, right) => left.path.localeCompare(right.path, 'en'))
  if (!same(describedFiles, inspection.files)) {
    fail('npm pack file metadata does not match the tar inventory')
  }
  return true
}

function appendGithubOutput(filename, inspection) {
  const stat = regularFile(filename, 'GitHub output file', npmPackageArtifactLimits.githubOutputBytes, true)
  const output = [
    `archive-name=${inspection.filename}`,
    `archive-shasum=${inspection.shasum}`,
    `archive-integrity=${inspection.integrity}`,
    `archive-bytes=${inspection.bytes}`,
    '',
  ].join('\n')
  if (stat.size + Buffer.byteLength(output) > npmPackageArtifactLimits.githubOutputBytes) {
    fail('GitHub output file would exceed its byte limit')
  }
  fs.appendFileSync(filename, output, { encoding: 'utf8', flag: 'a' })
}

function parseArgs(args) {
  if (args.length < 1 || !['prepare', 'verify'].includes(args[0])) {
    fail('usage: prepare|verify --archive path --version semver [options]')
  }
  const mode = args[0]
  const values = new Map()
  for (let index = 1; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!name?.startsWith('--') || value === undefined || value.length === 0 || values.has(name)) {
      fail('arguments must be unique name/value pairs')
    }
    values.set(name, value)
  }
  const allowed = mode === 'prepare'
    ? new Set(['--archive', '--version', '--pack-description', '--github-output'])
    : new Set(['--archive', '--version', '--expected-shasum', '--expected-integrity'])
  for (const name of values.keys()) {
    if (!allowed.has(name)) fail(`unsupported ${mode} option ${name}`)
  }
  for (const name of allowed) {
    if (!values.has(name)) fail(`${mode} requires ${name}`)
  }
  return { mode, values }
}

function main() {
  const { mode, values } = parseArgs(process.argv.slice(2))
  const version = values.get('--version')
  const archive = values.get('--archive')
  const inspection = inspectNpmPackageArchive(archive, version)
  if (mode === 'prepare') {
    const description = values.get('--pack-description')
    regularFile(description, 'npm pack description', npmPackageArtifactLimits.packDescriptionBytes)
    validatePackDescription(fs.readFileSync(description, 'utf8'), inspection)
    appendGithubOutput(values.get('--github-output'), inspection)
    process.stdout.write(
      `Prepared exact npm package ${inspection.filename}: ${inspection.entryCount} files, ${inspection.bytes} bytes, ${inspection.integrity}.\n`,
    )
    return
  }
  if (
    inspection.shasum !== values.get('--expected-shasum')
    || inspection.integrity !== values.get('--expected-integrity')
  ) {
    fail('downloaded workflow artifact differs from the packed digest outputs')
  }
  process.stdout.write(
    `Verified exact npm package ${inspection.filename}: ${inspection.entryCount} files, ${inspection.bytes} bytes, ${inspection.integrity}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
