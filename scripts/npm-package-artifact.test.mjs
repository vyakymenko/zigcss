import assert from 'node:assert/strict'
import test from 'node:test'
import { gzipSync } from 'node:zlib'
import {
  inspectNpmPackageBytes,
  npmPackageExecutableFiles,
  validatePackDescription,
} from './npm-package-artifact.mjs'
import { expectedPackedFiles } from './validate-preprocessor-package.mjs'

const version = '0.6.0-rc.2'
const manifest = Buffer.from(`${JSON.stringify({ name: 'zigcss', version })}\n`)

function octal(header, offset, length, value) {
  const encoded = `${value.toString(8).padStart(length - 1, '0')}\0`
  header.write(encoded, offset, length, 'ascii')
}

function checksum(header) {
  let total = 0
  for (let index = 0; index < header.length; index += 1) {
    total += index >= 148 && index < 156 ? 0x20 : header[index]
  }
  return total
}

function refreshChecksum(header) {
  header.fill(0x20, 148, 156)
  const encoded = `${checksum(header).toString(8).padStart(6, '0')}\0 `
  header.write(encoded, 148, 8, 'ascii')
}

function tarEntry(relative, content, mutateHeader = undefined) {
  const header = Buffer.alloc(512)
  header.write(`package/${relative}`, 0, 100, 'utf8')
  octal(header, 100, 8, npmPackageExecutableFiles.includes(relative) ? 0o755 : 0o644)
  octal(header, 108, 8, 0)
  octal(header, 116, 8, 0)
  octal(header, 124, 12, content.length)
  octal(header, 136, 12, 0)
  header[156] = 0x30
  header.write('ustar\0', 257, 6, 'ascii')
  header.write('00', 263, 2, 'ascii')
  header.write('root', 265, 32, 'ascii')
  header.write('root', 297, 32, 'ascii')
  octal(header, 329, 8, 0)
  octal(header, 337, 8, 0)
  mutateHeader?.(header, relative)
  refreshChecksum(header)
  const padding = Buffer.alloc((512 - (content.length % 512)) % 512)
  return Buffer.concat([header, content, padding])
}

function fixture(options = {}) {
  const files = expectedPackedFiles
    .filter(relative => relative !== options.omit)
    .map(relative => ({
      relative,
      content: relative === 'package.json' ? manifest : Buffer.from(`${relative}\n`),
    }))
  if (options.duplicate !== undefined) {
    const original = files.find(file => file.relative === options.duplicate)
    files.push({ ...original })
  }
  const tar = Buffer.concat([
    ...files.map(file => tarEntry(file.relative, file.content, options.mutateHeader)),
    Buffer.alloc(1024),
  ])
  return gzipSync(tar)
}

function inspection() {
  return {
    ...inspectNpmPackageBytes(fixture(), version, manifest),
    filename: `zigcss-${version}.tgz`,
  }
}

test('exact npm package parser accepts the closed inventory and binds npm pack metadata', () => {
  const result = inspection()
  assert.equal(result.entryCount, expectedPackedFiles.length)
  assert.equal(result.manifestText, manifest.toString())
  assert.deepEqual(
    result.files.map(file => file.path),
    [...expectedPackedFiles].sort((left, right) => left.localeCompare(right, 'en')),
  )
  assert.equal(validatePackDescription([{
    id: `zigcss@${version}`,
    name: 'zigcss',
    version,
    filename: result.filename,
    size: result.bytes,
    unpackedSize: result.unpackedBytes,
    shasum: result.shasum,
    integrity: result.integrity,
    bundled: [],
    entryCount: result.entryCount,
    files: result.files,
  }], result), true)
})

test('exact npm package parser rejects traversal, links, and link targets before extraction', () => {
  assert.throws(
    () => inspectNpmPackageBytes(fixture({
      mutateHeader(header, relative) {
        if (relative === expectedPackedFiles[0]) {
          header.fill(0, 0, 100)
          header.write('package/../escape', 0, 100, 'ascii')
        }
      },
    }), version, manifest),
    /path is unsafe/,
  )
  assert.throws(
    () => inspectNpmPackageBytes(fixture({
      mutateHeader(header, relative) {
        if (relative === expectedPackedFiles[0]) header[156] = 0x32
      },
    }), version, manifest),
    /regular tar entry/,
  )
  assert.throws(
    () => inspectNpmPackageBytes(fixture({
      mutateHeader(header, relative) {
        if (relative === expectedPackedFiles[0]) header.write('outside', 157, 100, 'ascii')
      },
    }), version, manifest),
    /must not carry a link target/,
  )
})

test('exact npm package parser rejects inventory, header, mode, manifest, and gzip drift', () => {
  assert.throws(
    () => inspectNpmPackageBytes(fixture({ omit: expectedPackedFiles.at(-1) }), version, manifest),
    /inventory changed/,
  )
  assert.throws(
    () => inspectNpmPackageBytes(fixture({ duplicate: expectedPackedFiles[0] }), version, manifest),
    /duplicate entry/,
  )
  assert.throws(
    () => inspectNpmPackageBytes(fixture({
      mutateHeader(header, relative) {
        if (relative === expectedPackedFiles[0]) octal(header, 100, 8, 0o777)
      },
    }), version, manifest),
    /has mode 777/,
  )
  const corrupt = fixture()
  corrupt[corrupt.length - 1] ^= 0xff
  assert.throws(() => inspectNpmPackageBytes(corrupt, version, manifest), /bounded gzip data/)
  assert.throws(
    () => inspectNpmPackageBytes(fixture(), version, Buffer.from('{}\n')),
    /differs from the tested manifest/,
  )
})

test('npm pack metadata must describe exactly the verified archive bytes', () => {
  const result = inspection()
  const description = {
    id: `zigcss@${version}`,
    name: 'zigcss',
    version,
    filename: result.filename,
    size: result.bytes,
    unpackedSize: result.unpackedBytes,
    shasum: result.shasum,
    integrity: result.integrity,
    bundled: [],
    entryCount: result.entryCount,
    files: result.files,
  }
  assert.throws(() => validatePackDescription([], result), /exactly one archive/)
  assert.throws(
    () => validatePackDescription([{ ...description, shasum: '0'.repeat(40) }], result),
    /does not match the exact archive bytes/,
  )
  assert.throws(
    () => validatePackDescription([{ ...description, files: description.files.slice(1) }], result),
    /identity or exact runtime inventory changed/,
  )
})
