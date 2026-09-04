import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { imageDimensions } from '../../../preprocessor/image-dimensions.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const stylusImages = path.join(
  repositoryRoot,
  'tests/preprocessors/stylus/corpus/files/upstream/images',
)

test('reads the closed PNG, GIF, JPEG, and SVG dimension family', () => {
  const expected = {
    'circle.svg': { width: 120, height: 120 },
    'flowers.jpeg': { width: 640, height: 480 },
    'flowers_p.jpg': { width: 640, height: 480 },
    gif: { width: 118, height: 104 },
    'tiger.svg': { width: 900, height: 900 },
    'tux.png': { width: 510, height: 640 },
  }
  for (const [name, dimensions] of Object.entries(expected)) {
    const actual = imageDimensions(fs.readFileSync(path.join(stylusImages, name)))
    assert.deepEqual(actual, dimensions, name)
    assert.equal(Object.isFrozen(actual), true, name)
  }
})

test('uses a finite SVG root header and viewBox fallback', () => {
  assert.deepEqual(
    imageDimensions(Buffer.from('<?xml version="1.0"?><svg viewBox="0 0 12.5 9"></svg>')),
    { width: 12.5, height: 9 },
  )
  assert.deepEqual(
    imageDimensions(Buffer.from('<!-- harmless --><svg width="2px" height="3px"></svg>')),
    { width: 2, height: 3 },
  )
  assert.deepEqual(
    imageDimensions(Buffer.from('<svg aria-label="1 > 0" width="7" height="9"></svg>')),
    { width: 7, height: 9 },
  )
})

test('rejects unsupported and malformed inputs with bounded monotonic scans', () => {
  const png = fs.readFileSync(path.join(stylusImages, 'tux.png'))
  const gif = fs.readFileSync(path.join(stylusImages, 'gif'))
  const jpeg = fs.readFileSync(path.join(stylusImages, 'flowers.jpeg'))
  const zeroWidthPng = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    'base64',
  )
  zeroWidthPng.writeUInt32BE(0, 16)
  const badPngCrc = Buffer.from(png)
  badPngCrc[badPngCrc.length - 1] ^= 1
  const malformed = [
    Buffer.alloc(0),
    Buffer.from('not-an-image'),
    Buffer.from('icns\0\0\0\0'),
    Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x00]),
    Buffer.from([0xff, 0xd8, ...Array(512).fill(0xff)]),
    Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x07, 0x08, 0x00, 0x01, 0x00, 0x01, 0x00]),
    jpeg.subarray(0, jpeg.length - 2),
    png.subarray(0, 33),
    badPngCrc,
    gif.subarray(0, 10),
    gif.subarray(0, 13),
    zeroWidthPng,
    Buffer.from('<svg width="100%" height="10"></svg>'),
    Buffer.from('<svg viewBox="0 0 1 -1"></svg>'),
    Buffer.from('<!-- <svg width="1" height="1">'),
    Buffer.from('garbage<svg width="7" height="9"></svg>'),
    Buffer.from('<svg data-x=" width=\'7\' height=\'9\' "></svg>'),
  ]
  for (const input of malformed) {
    assert.throws(() => imageDimensions(input), /invalid image dimensions/i)
  }
  assert.throws(() => imageDimensions(new Uint8Array([1, 2, 3])), /invalid image dimensions/i)
  assert.throws(
    () => imageDimensions(Buffer.alloc((10 * 1024 * 1024) + 1)),
    /invalid image dimensions/i,
  )
})
