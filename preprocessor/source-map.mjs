const MAX_SOURCE_MAP_BYTES = 20 * 1024 * 1024
const MAX_SEGMENTS = 1_000_000
const MAX_ENTRIES = 1_000_000
const base64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const base64Values = new Map([...base64].map((character, index) => [character, index]))
const requiredKeys = new Set(['version', 'sources', 'names', 'mappings'])
const allowedKeys = new Set([...requiredKeys, 'file', 'sourceRoot', 'sourcesContent'])

export class SourceMapError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'SourceMapError'
    this.code = code
  }
}

function fail(code, message) {
  throw new SourceMapError(code, message)
}

function invalid(message) {
  fail('SOURCE_MAP_INVALID', message)
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function addSafe(left, right, label) {
  const result = left + right
  if (!Number.isSafeInteger(result)) invalid(`${label} exceeds the safe integer range`)
  return result
}

function decodeSegment(text) {
  if (text.length === 0) invalid('source-map segments must not be empty')
  const values = []
  let encoded = 0
  let multiplier = 1
  let continuing = false
  for (const character of text) {
    const digit = base64Values.get(character)
    if (digit === undefined) invalid('source-map mappings contain a non-base64 character')
    const payload = digit % 32
    if (payload !== 0 && multiplier > Math.floor((Number.MAX_SAFE_INTEGER - encoded) / payload)) {
      invalid('source-map VLQ value exceeds the safe integer range')
    }
    encoded += payload * multiplier
    continuing = digit >= 32
    if (continuing) {
      if (multiplier > Math.floor(Number.MAX_SAFE_INTEGER / 32)) {
        invalid('source-map VLQ value exceeds the safe integer range')
      }
      multiplier *= 32
      continue
    }
    const negative = encoded % 2 === 1
    const magnitude = Math.floor(encoded / 2)
    values.push(negative ? -magnitude : magnitude)
    encoded = 0
    multiplier = 1
  }
  if (continuing) invalid('source-map VLQ value is truncated')
  if (values.length !== 1 && values.length !== 4 && values.length !== 5) {
    invalid('source-map segment field count is invalid')
  }
  return values
}

function parseMappings(mappings, sourceCount, nameCount) {
  const lines = []
  let previousSource = 0
  let previousOriginalLine = 0
  let previousOriginalColumn = 0
  let previousName = 0
  let segmentCount = 0

  for (const encodedLine of mappings.split(';')) {
    const line = []
    let previousGeneratedColumn = -1
    let generatedColumn = 0
    if (encodedLine !== '') {
      for (const encodedSegment of encodedLine.split(',')) {
        const values = decodeSegment(encodedSegment)
        generatedColumn = addSafe(generatedColumn, values[0], 'generated column')
        if (generatedColumn < 0 || generatedColumn <= previousGeneratedColumn) {
          invalid('source-map generated columns must be strictly increasing')
        }
        previousGeneratedColumn = generatedColumn
        segmentCount += 1
        if (segmentCount > MAX_SEGMENTS) invalid('source-map segment count exceeds its limit')

        if (values.length === 1) {
          line.push(Object.freeze({ generatedColumn }))
          continue
        }
        previousSource = addSafe(previousSource, values[1], 'source index')
        previousOriginalLine = addSafe(previousOriginalLine, values[2], 'original line')
        previousOriginalColumn = addSafe(previousOriginalColumn, values[3], 'original column')
        if (
          previousSource < 0 ||
          previousSource >= sourceCount ||
          previousOriginalLine < 0 ||
          previousOriginalColumn < 0
        ) {
          invalid('source-map mapping points outside its declared ranges')
        }
        const segment = {
          generatedColumn,
          source: previousSource,
          originalLine: previousOriginalLine,
          originalColumn: previousOriginalColumn,
        }
        if (values.length === 5) {
          previousName = addSafe(previousName, values[4], 'name index')
          if (previousName < 0 || previousName >= nameCount) {
            invalid('source-map mapping points outside its declared names')
          }
          segment.name = previousName
        }
        line.push(Object.freeze(segment))
      }
    }
    lines.push(Object.freeze(line))
  }
  return Object.freeze(lines)
}

function requireStringArray(value, label) {
  if (!Array.isArray(value) || value.length > MAX_ENTRIES || value.some(entry => typeof entry !== 'string')) {
    invalid(`${label} must be a bounded string array`)
  }
}

export function parseSourceMap(serialized) {
  if (
    typeof serialized !== 'string' ||
    serialized.length === 0 ||
    Buffer.byteLength(serialized, 'utf8') > MAX_SOURCE_MAP_BYTES
  ) {
    invalid('source map must be a bounded JSON string')
  }
  let value
  try {
    value = JSON.parse(serialized)
  } catch {
    invalid('source map is not valid JSON')
  }
  if (!isPlainObject(value)) invalid('source map must be an object')
  for (const key of Object.keys(value)) {
    if (!allowedKeys.has(key)) invalid('source map contains an unsupported field')
  }
  for (const key of requiredKeys) {
    if (!Object.hasOwn(value, key)) invalid('source map is missing a required field')
  }
  if (value.version !== 3) invalid('source map version must be 3')
  requireStringArray(value.sources, 'sources')
  requireStringArray(value.names, 'names')
  if (typeof value.mappings !== 'string') invalid('mappings must be a string')
  if (Object.hasOwn(value, 'file') && typeof value.file !== 'string') invalid('file must be a string')
  if (Object.hasOwn(value, 'sourceRoot') && typeof value.sourceRoot !== 'string') {
    invalid('sourceRoot must be a string')
  }
  if (Object.hasOwn(value, 'sourcesContent')) {
    if (
      !Array.isArray(value.sourcesContent) ||
      value.sourcesContent.length !== value.sources.length ||
      value.sourcesContent.some(entry => entry !== null && typeof entry !== 'string')
    ) {
      invalid('sourcesContent must align exactly with sources')
    }
  }

  const parsed = {
    version: 3,
    sources: Object.freeze([...value.sources]),
    names: Object.freeze([...value.names]),
    mappings: value.mappings,
    lines: parseMappings(value.mappings, value.sources.length, value.names.length),
  }
  if (Object.hasOwn(value, 'file')) parsed.file = value.file
  if (Object.hasOwn(value, 'sourceRoot')) parsed.sourceRoot = value.sourceRoot
  if (Object.hasOwn(value, 'sourcesContent')) {
    parsed.sourcesContent = Object.freeze([...value.sourcesContent])
  }
  return Object.freeze(parsed)
}

function encodeValue(value) {
  if (!Number.isSafeInteger(value)) invalid('composed source-map value is not a safe integer')
  let encoded = Math.abs(value) * 2 + (value < 0 ? 1 : 0)
  if (!Number.isSafeInteger(encoded)) invalid('composed source-map value exceeds the safe integer range')
  let output = ''
  do {
    let digit = encoded % 32
    encoded = Math.floor(encoded / 32)
    if (encoded > 0) digit += 32
    output += base64[digit]
  } while (encoded > 0)
  return output
}

function encodeMappings(lines) {
  let previousSource = 0
  let previousOriginalLine = 0
  let previousOriginalColumn = 0
  let previousName = 0
  return lines.map(line => {
    let previousGeneratedColumn = 0
    return line.map(segment => {
      const values = [segment.generatedColumn - previousGeneratedColumn]
      previousGeneratedColumn = segment.generatedColumn
      if (Object.hasOwn(segment, 'source')) {
        values.push(
          segment.source - previousSource,
          segment.originalLine - previousOriginalLine,
          segment.originalColumn - previousOriginalColumn,
        )
        previousSource = segment.source
        previousOriginalLine = segment.originalLine
        previousOriginalColumn = segment.originalColumn
        if (Object.hasOwn(segment, 'name')) {
          values.push(segment.name - previousName)
          previousName = segment.name
        }
      }
      return values.map(encodeValue).join('')
    }).join(',')
  }).join(';')
}

function greatestLowerBound(line, generatedColumn) {
  let lower = 0
  let upper = line.length - 1
  let match = null
  while (lower <= upper) {
    const middle = Math.floor((lower + upper) / 2)
    const segment = line[middle]
    if (segment.generatedColumn <= generatedColumn) {
      match = segment
      lower = middle + 1
    } else {
      upper = middle - 1
    }
  }
  return match
}

export function composeSourceMaps(options = {}) {
  if (
    !isPlainObject(options) ||
    Object.keys(options).sort().join(',') !== 'intermediateSourceUrl,providerMap,zigMap'
  ) {
    invalid('source-map composition options have unexpected or missing fields')
  }
  const { providerMap, zigMap, intermediateSourceUrl } = options
  if (typeof intermediateSourceUrl !== 'string' || intermediateSourceUrl.length === 0) {
    fail('SOURCE_MAP_INTERMEDIATE', 'intermediate source URL must be a non-empty string')
  }
  const provider = parseSourceMap(providerMap)
  const zig = parseSourceMap(zigMap)
  const intermediateIndexes = []
  for (let index = 0; index < zig.sources.length; index += 1) {
    if (zig.sources[index] === intermediateSourceUrl) intermediateIndexes.push(index)
  }
  if (intermediateIndexes.length !== 1) {
    fail('SOURCE_MAP_INTERMEDIATE', 'outer source map must name the intermediate source exactly once')
  }
  const intermediateIndex = intermediateIndexes[0]
  const composedLines = zig.lines.map(line => line.map(outer => {
    if (!Object.hasOwn(outer, 'source')) return { generatedColumn: outer.generatedColumn }
    if (outer.source !== intermediateIndex) {
      fail('SOURCE_MAP_INTERMEDIATE', 'outer mappings must point only at the intermediate source')
    }
    const providerLine = provider.lines[outer.originalLine]
    const inner = providerLine === undefined
      ? null
      : greatestLowerBound(providerLine, outer.originalColumn)
    if (inner === null || !Object.hasOwn(inner, 'source')) {
      return { generatedColumn: outer.generatedColumn }
    }
    const segment = {
      generatedColumn: outer.generatedColumn,
      source: inner.source,
      originalLine: inner.originalLine,
      originalColumn: inner.originalColumn,
    }
    if (Object.hasOwn(inner, 'name')) segment.name = inner.name
    return segment
  }))

  const output = { version: 3 }
  if (Object.hasOwn(zig, 'file')) output.file = zig.file
  if (Object.hasOwn(provider, 'sourceRoot')) output.sourceRoot = provider.sourceRoot
  output.sources = [...provider.sources]
  if (Object.hasOwn(provider, 'sourcesContent')) output.sourcesContent = [...provider.sourcesContent]
  output.names = [...provider.names]
  output.mappings = encodeMappings(composedLines)
  const serialized = JSON.stringify(output)
  if (Buffer.byteLength(serialized, 'utf8') > MAX_SOURCE_MAP_BYTES) {
    invalid('composed source map exceeds its byte limit')
  }
  return serialized
}
