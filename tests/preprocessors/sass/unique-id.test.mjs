import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import * as sass from 'sass'

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../..',
)
const identifierPattern = /\bu[0-9a-z]{6}\b/g

const scss = [
  '@use "sass:map";',
  '@use "sass:meta";',
  '@use "sass:string";',
  '@use "sass:string" as text;',
  '@use "sass:string" as *;',
  '$function: meta.get-function("unique-id", $module: "string");',
  '$empty-list: ();',
  '$empty-map: map.remove((sentinel: true), sentinel);',
  '.probe {',
  '  direct: string.unique-id();',
  '  direct-alias: text.unique-id();',
  '  direct-unprefixed: unique-id();',
  '  direct-list-splat: string.unique-id($empty-list...);',
  '  direct-map-splat: string.unique-id($empty-map...);',
  '  reflected: meta.call($function);',
  '  reflected-list-splat: meta.call($function, $empty-list...);',
  '  reflected-map-splat: meta.call($function, $empty-map...);',
  '  interpolation: "#{string.unique-id()}";',
  '  type: meta.type-of(string.unique-id());',
  '}',
].join('\n')

const indented = [
  '@use "sass:map"',
  '@use "sass:meta"',
  '@use "sass:string"',
  '@use "sass:string" as text',
  '@use "sass:string" as *',
  '$function: meta.get-function("unique-id", $module: "string")',
  '$empty-list: ()',
  '$empty-map: map.remove((sentinel: true), sentinel)',
  '.probe',
  '  direct: string.unique-id()',
  '  direct-alias: text.unique-id()',
  '  direct-unprefixed: unique-id()',
  '  direct-list-splat: string.unique-id($empty-list...)',
  '  direct-map-splat: string.unique-id($empty-map...)',
  '  reflected: meta.call($function)',
  '  reflected-list-splat: meta.call($function, $empty-list...)',
  '  reflected-map-splat: meta.call($function, $empty-map...)',
  '  interpolation: "#{string.unique-id()}"',
  '  type: meta.type-of(string.unique-id())',
].join('\n')

function compile(source, syntax) {
  const warnings = []
  const result = sass.compileString(source, {
    syntax,
    style: 'compressed',
    logger: {
      warn(message, options) {
        warnings.push({
          message,
          deprecation: options.deprecationType?.id ?? null,
        })
      },
    },
  })
  return { css: result.css, warnings }
}

function ids(css) {
  return [...css.matchAll(identifierPattern)].map(match => match[0])
}

function normalized(css) {
  return css.replaceAll(identifierPattern, '<id>')
}

test('measures Dart Sass 1.101.0 unique-id call surfaces and nondeterminism', {
  timeout: 30_000,
}, async () => {
  const expected = '.probe{direct:<id>;direct-alias:<id>;direct-unprefixed:<id>;direct-list-splat:<id>;direct-map-splat:<id>;reflected:<id>;reflected-list-splat:<id>;reflected-map-splat:<id>;interpolation:"<id>";type:string}'

  for (const [syntax, source] of [['scss', scss], ['indented', indented]]) {
    const first = compile(source, syntax)
    const second = compile(source, syntax)
    const observed = [...ids(first.css), ...ids(second.css)]

    assert.equal(normalized(first.css), expected)
    assert.equal(normalized(second.css), expected)
    assert.equal(observed.length, 18)
    assert.equal(new Set(observed).size, observed.length)
    assert.notEqual(first.css, second.css)
    assert.deepEqual(first.warnings, [])
    assert.deepEqual(second.warnings, [])
  }

  const parallel = await Promise.all(
    Array.from({ length: 8 }, () => sass.compileStringAsync(scss, {
      style: 'compressed',
    })),
  )
  const parallelIds = parallel.flatMap(result => ids(result.css))
  assert.equal(parallelIds.length, 72)
  assert.equal(new Set(parallelIds).size, parallelIds.length)

  const childSource = [
    "import * as sass from 'sass'",
    "process.stdout.write(sass.compileString('@use \"sass:string\"; .a { value: string.unique-id(); }', {style: 'compressed'}).css)",
  ].join(';')
  const freshProcesses = Array.from({ length: 8 }, () => spawnSync(
    process.execPath,
    ['--input-type=module', '--eval', childSource],
    {
      cwd: repositoryRoot,
      encoding: 'utf8',
      timeout: 10_000,
    },
  ))
  for (const result of freshProcesses) {
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /^\.a\{value:u[0-9a-z]{6}\}$/)
  }
  assert.ok(new Set(freshProcesses.map(result => result.stdout)).size > 1)

  for (const [syntax, source] of [
    [
      'scss',
      '@use "sass:meta"; $function: meta.get-function("unique-id"); .a { direct: unique-id(); reflected: meta.call($function); type: meta.type-of(meta.call($function)); }',
    ],
    [
      'indented',
      '@use "sass:meta"\n$function: meta.get-function("unique-id")\n.a\n  direct: unique-id()\n  reflected: meta.call($function)\n  type: meta.type-of(meta.call($function))',
    ],
  ]) {
    const legacy = compile(source, syntax)
    assert.equal(
      normalized(legacy.css),
      '.a{direct:<id>;reflected:<id>;type:string}',
    )
    assert.equal(ids(legacy.css).length, 2)
    assert.deepEqual(
      legacy.warnings.map(warning => warning.deprecation),
      ['global-builtin', 'global-builtin', 'global-builtin'],
    )
  }
})

test('Dart Sass unique-id rejects arguments without CSS in both syntaxes', () => {
  for (const [syntax, source] of [
    ['scss', '@use "sass:string"; .a { value: string.unique-id(extra); }'],
    ['indented', '@use "sass:string"\n.a\n  value: string.unique-id(extra)'],
  ]) {
    assert.throws(
      () => compile(source, syntax),
      error => error.sassMessage === 'Only 0 arguments allowed, but 1 was passed.',
    )
  }
})
