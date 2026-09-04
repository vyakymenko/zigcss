const MAX_IMAGE_BYTES = 10 * 1024 * 1024
const MAX_DIMENSION = 0x7fffffff
const MAX_PNG_CHUNKS = 65_536
const MAX_GIF_BLOCKS = 65_536
const MAX_JPEG_SEGMENTS = 65_536
const MAX_SVG_ROOT_BYTES = 64 * 1024
const jpegStartOfFrame = new Set([
  0xc0, 0xc1, 0xc2, 0xc3,
  0xc5, 0xc6, 0xc7,
  0xc9, 0xca, 0xcb,
  0xcd, 0xce, 0xcf,
])
const pngCrcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  let crc = value
  for (let bit = 0; bit < 8; bit += 1) {
    crc = (crc & 1) === 1 ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1)
  }
  return crc >>> 0
})

function invalid() {
  throw new Error('Unsupported or invalid image dimensions')
}

function dimensions(width, height) {
  if (
    !Number.isFinite(width) ||
    !Number.isFinite(height) ||
    width <= 0 ||
    height <= 0 ||
    width > MAX_DIMENSION ||
    height > MAX_DIMENSION
  ) {
    invalid()
  }
  return Object.freeze({ width, height })
}

function pngCrc32(bytes, start, end) {
  let crc = 0xffffffff
  for (let offset = start; offset < end; offset += 1) {
    crc = pngCrcTable[(crc ^ bytes[offset]) & 0xff] ^ (crc >>> 8)
  }
  return (crc ^ 0xffffffff) >>> 0
}

function validPngHeader(bytes, dataStart) {
  const bitDepth = bytes[dataStart + 8]
  const colorType = bytes[dataStart + 9]
  const allowedDepths = new Map([
    [0, new Set([1, 2, 4, 8, 16])],
    [2, new Set([8, 16])],
    [3, new Set([1, 2, 4, 8])],
    [4, new Set([8, 16])],
    [6, new Set([8, 16])],
  ])
  return (
    allowedDepths.get(colorType)?.has(bitDepth) === true &&
    bytes[dataStart + 10] === 0 &&
    bytes[dataStart + 11] === 0 &&
    (bytes[dataStart + 12] === 0 || bytes[dataStart + 12] === 1)
  )
}

function pngDimensions(bytes) {
  if (bytes.length < 57) invalid()
  let offset = 8
  let chunks = 0
  let result = null
  let sawImageData = false
  while (offset + 12 <= bytes.length && chunks < MAX_PNG_CHUNKS) {
    const length = bytes.readUInt32BE(offset)
    const typeStart = offset + 4
    const dataStart = typeStart + 4
    const dataEnd = dataStart + length
    const chunkEnd = dataEnd + 4
    if (dataEnd < dataStart || chunkEnd > bytes.length) invalid()
    for (let index = typeStart; index < dataStart; index += 1) {
      const value = bytes[index]
      if (!((value >= 0x41 && value <= 0x5a) || (value >= 0x61 && value <= 0x7a))) invalid()
    }
    if (pngCrc32(bytes, typeStart, dataEnd) !== bytes.readUInt32BE(dataEnd)) invalid()
    const type = bytes.toString('ascii', typeStart, dataStart)
    chunks += 1

    if (chunks === 1) {
      if (type !== 'IHDR' || length !== 13 || !validPngHeader(bytes, dataStart)) invalid()
      result = dimensions(bytes.readUInt32BE(dataStart), bytes.readUInt32BE(dataStart + 4))
    } else if (type === 'IHDR') {
      invalid()
    }
    if (type === 'IDAT') sawImageData = true
    if (type === 'IEND') {
      if (length !== 0 || !sawImageData || result === null || chunkEnd !== bytes.length) invalid()
      return result
    }
    offset = chunkEnd
  }
  invalid()
}

function skipGifColorTable(bytes, offset, packed) {
  if ((packed & 0x80) === 0) return offset
  const size = 3 * (2 << (packed & 0x07))
  if (offset + size > bytes.length) invalid()
  return offset + size
}

function skipGifSubBlocks(bytes, initialOffset) {
  let offset = initialOffset
  let blocks = 0
  while (offset < bytes.length && blocks < MAX_GIF_BLOCKS) {
    const length = bytes[offset]
    offset += 1
    blocks += 1
    if (length === 0) return offset
    if (offset + length > bytes.length) invalid()
    offset += length
  }
  invalid()
}

function gifDimensions(bytes) {
  if (bytes.length < 14) invalid()
  const header = bytes.toString('ascii', 0, 6)
  if (header !== 'GIF87a' && header !== 'GIF89a') invalid()
  const result = dimensions(bytes.readUInt16LE(6), bytes.readUInt16LE(8))
  let offset = skipGifColorTable(bytes, 13, bytes[10])
  let blocks = 0
  let sawImage = false
  while (offset < bytes.length && blocks < MAX_GIF_BLOCKS) {
    const marker = bytes[offset]
    offset += 1
    blocks += 1
    if (marker === 0x3b) {
      if (!sawImage || offset !== bytes.length) invalid()
      return result
    }
    if (marker === 0x21) {
      if (offset >= bytes.length) invalid()
      offset += 1
      offset = skipGifSubBlocks(bytes, offset)
      continue
    }
    if (marker !== 0x2c || offset + 9 > bytes.length) invalid()
    dimensions(bytes.readUInt16LE(offset + 4), bytes.readUInt16LE(offset + 6))
    offset = skipGifColorTable(bytes, offset + 9, bytes[offset + 8])
    if (offset >= bytes.length || bytes[offset] < 2 || bytes[offset] > 8) invalid()
    offset = skipGifSubBlocks(bytes, offset + 1)
    sawImage = true
  }
  invalid()
}

function validateJpegFrame(bytes, offset, length) {
  if (length < 11) invalid()
  const componentCount = bytes[offset + 7]
  if (componentCount < 1 || componentCount > 4 || length !== 8 + (3 * componentCount)) invalid()
  const precision = bytes[offset + 2]
  if (precision < 1 || precision > 16) invalid()
  const componentIds = new Set()
  for (let index = 0; index < componentCount; index += 1) {
    const componentOffset = offset + 8 + (3 * index)
    const id = bytes[componentOffset]
    const sampling = bytes[componentOffset + 1]
    if (
      componentIds.has(id) ||
      (sampling >>> 4) === 0 ||
      (sampling & 0x0f) === 0 ||
      bytes[componentOffset + 2] > 3
    ) {
      invalid()
    }
    componentIds.add(id)
  }
  return {
    componentIds,
    result: dimensions(bytes.readUInt16BE(offset + 5), bytes.readUInt16BE(offset + 3)),
  }
}

function validateJpegScan(bytes, offset, length, frame) {
  if (frame === null || length < 8) invalid()
  const componentCount = bytes[offset + 2]
  if (componentCount < 1 || componentCount > 4 || length !== 6 + (2 * componentCount)) invalid()
  const selectors = new Set()
  for (let index = 0; index < componentCount; index += 1) {
    const selector = bytes[offset + 3 + (2 * index)]
    if (!frame.componentIds.has(selector) || selectors.has(selector)) invalid()
    selectors.add(selector)
  }
}

function jpegDimensions(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) invalid()
  let offset = 2
  let segments = 0
  let frame = null
  let sawScan = false
  while (offset < bytes.length && segments < MAX_JPEG_SEGMENTS) {
    if (bytes[offset] !== 0xff) invalid()
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1
    if (offset >= bytes.length) invalid()
    const marker = bytes[offset]
    offset += 1
    segments += 1

    if (marker === 0x00 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) invalid()
    if (marker === 0xd9) {
      if (frame === null || !sawScan || offset !== bytes.length) invalid()
      return frame.result
    }
    if (marker === 0x01) continue
    if (offset + 2 > bytes.length) invalid()
    const length = bytes.readUInt16BE(offset)
    if (length < 2 || offset + length > bytes.length) invalid()
    if (jpegStartOfFrame.has(marker)) {
      if (frame !== null) invalid()
      frame = validateJpegFrame(bytes, offset, length)
    }
    if (marker === 0xda) {
      validateJpegScan(bytes, offset, length, frame)
      sawScan = true
      offset += length
      let markerOffset = -1
      while (offset < bytes.length) {
        if (bytes[offset] !== 0xff) {
          offset += 1
          continue
        }
        const prefix = offset
        while (offset < bytes.length && bytes[offset] === 0xff) offset += 1
        if (offset >= bytes.length) invalid()
        const entropyMarker = bytes[offset]
        if (entropyMarker === 0x00 || (entropyMarker >= 0xd0 && entropyMarker <= 0xd7)) {
          offset += 1
          continue
        }
        markerOffset = prefix
        break
      }
      if (markerOffset === -1) invalid()
      offset = markerOffset
      continue
    }
    offset += length
  }
  invalid()
}

function decodeSvgPrefix(bytes) {
  const prefixLength = Math.min(bytes.length, MAX_SVG_ROOT_BYTES)
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(
      bytes.subarray(0, prefixLength),
      { stream: prefixLength < bytes.length },
    )
  } catch {
    invalid()
  }
}

function svgDeclarationEnd(source, initialOffset) {
  let quote = null
  let brackets = 0
  for (let offset = initialOffset; offset < source.length; offset += 1) {
    const character = source[offset]
    if (quote !== null) {
      if (character === quote) quote = null
      continue
    }
    if (character === '"' || character === "'") {
      quote = character
    } else if (character === '[') {
      brackets += 1
    } else if (character === ']') {
      if (brackets === 0) invalid()
      brackets -= 1
    } else if (character === '>' && brackets === 0) {
      return offset + 1
    }
  }
  invalid()
}

function svgTagEnd(source, initialOffset) {
  let quote = null
  for (let offset = initialOffset; offset < source.length; offset += 1) {
    const character = source[offset]
    if (quote !== null) {
      if (character === quote) quote = null
      continue
    }
    if (character === '"' || character === "'") {
      quote = character
    } else if (character === '>') {
      return offset + 1
    }
  }
  invalid()
}

function svgRootTag(bytes) {
  const source = decodeSvgPrefix(bytes)
  let offset = source.charCodeAt(0) === 0xfeff ? 1 : 0
  while (offset < source.length) {
    while (/\s/.test(source[offset] ?? '')) offset += 1
    if (source[offset] !== '<') invalid()
    if (source.startsWith('<!--', offset)) {
      const closing = source.indexOf('-->', offset + 4)
      if (closing === -1) invalid()
      offset = closing + 3
      continue
    }
    if (source.startsWith('<?', offset)) {
      const closing = source.indexOf('?>', offset + 2)
      if (closing === -1) invalid()
      offset = closing + 2
      continue
    }
    if (/^<!doctype(?:\s|>)/i.test(source.slice(offset))) {
      offset = svgDeclarationEnd(source, offset + 9)
      continue
    }
    const prefix = source.slice(offset, offset + 5).toLowerCase()
    if (prefix.startsWith('<svg') && /[\s/>]/.test(source[offset + 4] ?? '>')) {
      const end = svgTagEnd(source, offset + 4)
      return source.slice(offset, end)
    }
    invalid()
  }
  invalid()
}

function svgAttributes(tag) {
  const attributes = new Map()
  let offset = 4
  while (offset < tag.length) {
    while (/\s/.test(tag[offset] ?? '')) offset += 1
    if (tag[offset] === '>' || (tag[offset] === '/' && tag[offset + 1] === '>')) return attributes
    const nameMatch = /^[A-Za-z_:][A-Za-z0-9_.:-]*/.exec(tag.slice(offset))
    if (nameMatch === null) invalid()
    const name = nameMatch[0].toLowerCase()
    offset += nameMatch[0].length
    while (/\s/.test(tag[offset] ?? '')) offset += 1
    if (tag[offset] !== '=') invalid()
    offset += 1
    while (/\s/.test(tag[offset] ?? '')) offset += 1
    const quote = tag[offset]
    if (quote !== '"' && quote !== "'") invalid()
    const end = tag.indexOf(quote, offset + 1)
    if (end === -1 || attributes.has(name)) invalid()
    attributes.set(name, tag.slice(offset + 1, end))
    offset = end + 1
  }
  invalid()
}

function svgLength(value) {
  if (value === null) return null
  const match = /^\s*(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:px)?\s*$/i.exec(value)
  if (match === null) return null
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : null
}

function svgDimensions(bytes) {
  const attributes = svgAttributes(svgRootTag(bytes))
  const width = svgLength(attributes.get('width') ?? null)
  const height = svgLength(attributes.get('height') ?? null)
  if (width !== null && height !== null) return dimensions(width, height)

  const viewBox = attributes.get('viewbox') ?? null
  if (viewBox === null) invalid()
  const values = viewBox.trim().split(/[\s,]+/).map(Number)
  if (values.length !== 4 || values.some(value => !Number.isFinite(value))) invalid()
  return dimensions(values[2], values[3])
}

export function imageDimensions(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > MAX_IMAGE_BYTES) {
    invalid()
  }
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes.toString('ascii', 1, 4) === 'PNG' &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return pngDimensions(bytes)
  }
  if (bytes.length >= 6 && bytes.toString('ascii', 0, 3) === 'GIF') {
    return gifDimensions(bytes)
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    return jpegDimensions(bytes)
  }
  if (bytes.includes(0x3c)) return svgDimensions(bytes)
  invalid()
}
