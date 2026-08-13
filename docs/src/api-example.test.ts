// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')

function read(relativePath: string): string {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

function example(markdown: string): string {
  const match = markdown.match(
    /<!-- api-example:start -->\s*```zig\n([\s\S]*?)\n```\s*<!-- api-example:end -->/,
  )
  if (!match) throw new Error('missing marked Zig API example')
  return match[1]
}

function nativeExample(markdown: string): string {
  const match = markdown.match(
    /<!-- native-api-example:start -->\s*```zig\n([\s\S]*?)\n```\s*<!-- native-api-example:end -->/,
  )
  if (!match) throw new Error('missing marked native Zig API example')
  return match[1]
}

describe('public Zig API example', () => {
  const compiled = read('examples/public_api.zig').trim()

  test.each([
    'README.md',
    'docs/src/content/docs/guide/build-from-source.md',
  ])('%s matches the compiled consumer', relativePath => {
    expect(example(read(relativePath))).toBe(compiled)
  })
})

describe('native stylesheet Zig API example', () => {
  const compiled = read('examples/native_api.zig').trim()

  test.each([
    'README.md',
    'docs/src/content/docs/guide/build-from-source.md',
  ])('%s matches the compiled finite native consumer', relativePath => {
    expect(nativeExample(read(relativePath))).toBe(compiled)
  })
})
