import assert from 'node:assert/strict'
import test from 'node:test'
import {
  composeSourceMaps,
  parseSourceMap,
} from '../../../preprocessor/source-map.mjs'

const intermediateSourceUrl = 'file:///workspace/.zigcss-intermediate.css'

function providerMap(overrides = {}) {
  return JSON.stringify({
    version: 3,
    sourceRoot: '',
    sources: ['file:///workspace/input.scss'],
    sourcesContent: ['$token: red;\n.card { color: $token; }\n'],
    names: ['token'],
    mappings: 'AAAAA,KAAU',
    ...overrides,
  })
}

function zigMap(overrides = {}) {
  return JSON.stringify({
    version: 3,
    file: 'output.css',
    sources: [intermediateSourceUrl],
    names: [],
    mappings: 'AAAA,GAAO',
    ...overrides,
  })
}

function rejectsWithCode(code) {
  return error => error?.code === code
}

test('composes final columns through the provider map with greatest-lower-bound tracing', () => {
  const output = composeSourceMaps({
    providerMap: providerMap(),
    zigMap: zigMap(),
    intermediateSourceUrl,
  })
  assert.equal(output, composeSourceMaps({
    providerMap: providerMap(),
    zigMap: zigMap(),
    intermediateSourceUrl,
  }))
  assert.deepEqual(JSON.parse(output), {
    version: 3,
    file: 'output.css',
    sourceRoot: '',
    sources: ['file:///workspace/input.scss'],
    sourcesContent: ['$token: red;\n.card { color: $token; }\n'],
    names: ['token'],
    mappings: 'AAAAA,GAAU',
  })
})

test('preserves unmapped final segments and makes inner generated regions unmapped', () => {
  const outerUnmapped = JSON.parse(composeSourceMaps({
    providerMap: providerMap({ mappings: 'AAAA' }),
    zigMap: zigMap({ mappings: 'AAAA,G' }),
    intermediateSourceUrl,
  }))
  assert.equal(outerUnmapped.mappings, 'AAAA,G')

  const innerUnmapped = JSON.parse(composeSourceMaps({
    providerMap: providerMap({ mappings: 'AAAA,K' }),
    zigMap: zigMap({ mappings: 'AAAA,GAAO' }),
    intermediateSourceUrl,
  }))
  assert.equal(innerUnmapped.mappings, 'AAAA,G')

  const beforeNextInnerSegment = JSON.parse(composeSourceMaps({
    providerMap: providerMap({ mappings: 'AAAA,KAAU' }),
    zigMap: zigMap({ mappings: 'AAAA,GAAI' }),
    intermediateSourceUrl,
  }))
  assert.equal(beforeNextInnerSegment.mappings, 'AAAA,GAAA')
})

test('keeps UTF-16 source-map columns and line deltas exact', () => {
  const unicode = JSON.parse(composeSourceMaps({
    providerMap: providerMap({
      sourcesContent: ['😀x'],
      names: [],
      mappings: 'AAAE;AACA',
    }),
    zigMap: zigMap({ mappings: 'AAAA;AACA' }),
    intermediateSourceUrl,
  }))
  assert.equal(unicode.mappings, 'AAAE;AACA')
  assert.deepEqual(unicode.sourcesContent, ['😀x'])
})

test('preserves signed cross-line source, position, and name deltas', () => {
  const providerMappings = 'ACEIC,KDDFD;AAED'
  const composed = JSON.parse(composeSourceMaps({
    providerMap: providerMap({
      sources: ['file:///workspace/a.scss', 'file:///workspace/b.scss'],
      sourcesContent: ['a', 'b'],
      names: ['first', 'second'],
      mappings: providerMappings,
    }),
    zigMap: zigMap({ mappings: 'AAAA,KAAK;AACL' }),
    intermediateSourceUrl,
  }))

  assert.equal(composed.mappings, providerMappings)
  assert.deepEqual(composed.sources, [
    'file:///workspace/a.scss',
    'file:///workspace/b.scss',
  ])
  assert.deepEqual(composed.names, ['first', 'second'])
})

test('strict parser rejects malformed maps, indices, segment order, and extensions', () => {
  const invalidMaps = [
    JSON.stringify({ version: 2, sources: [], names: [], mappings: '' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: '!' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: 'AA' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: 'AAAAAA' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: 'AAAA' }),
    JSON.stringify({ version: 3, sources: ['a'], names: [], mappings: 'C,D' }),
    JSON.stringify({ version: 3, sources: [], sourcesContent: ['orphan'], names: [], mappings: '' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: 'ggggggggggggggggggggA' }),
    JSON.stringify({ version: 3, sources: [], names: [], mappings: '', sections: [] }),
  ]
  for (const map of invalidMaps) {
    assert.throws(() => parseSourceMap(map), rejectsWithCode('SOURCE_MAP_INVALID'))
  }
})

test('composition rejects outer mappings that do not point only at the named intermediate source', () => {
  assert.throws(
    () => composeSourceMaps({
      providerMap: providerMap(),
      zigMap: zigMap({ sources: ['file:///workspace/other.css'] }),
      intermediateSourceUrl,
    }),
    rejectsWithCode('SOURCE_MAP_INTERMEDIATE'),
  )
  assert.throws(
    () => composeSourceMaps({
      providerMap: providerMap(),
      zigMap: zigMap({ sources: [intermediateSourceUrl, intermediateSourceUrl] }),
      intermediateSourceUrl,
    }),
    rejectsWithCode('SOURCE_MAP_INTERMEDIATE'),
  )
})

test('composition rejects either missing map without manufacturing partial ownership', () => {
  assert.throws(
    () => composeSourceMaps({
      providerMap: null,
      zigMap: zigMap(),
      intermediateSourceUrl,
    }),
    rejectsWithCode('SOURCE_MAP_INVALID'),
  )
  assert.throws(
    () => composeSourceMaps({
      providerMap: providerMap(),
      zigMap: null,
      intermediateSourceUrl,
    }),
    rejectsWithCode('SOURCE_MAP_INVALID'),
  )
  assert.throws(
    () => composeSourceMaps({
      providerMap: providerMap(),
      zigMap: zigMap(),
      intermediateSourceUrl,
      unexpected: true,
    }),
    rejectsWithCode('SOURCE_MAP_INVALID'),
  )
})
