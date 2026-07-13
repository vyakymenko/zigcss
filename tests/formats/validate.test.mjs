import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { discoverLegacyAdapterSources } from './validate.mjs'

test('fresh checkouts represent removed adapter sources with an absent directory', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-format-inventory-'))
  try {
    assert.deepEqual(discoverLegacyAdapterSources(root), [])
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('legacy adapter discovery is closed, sorted, and rejects symlink substitution', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-format-inventory-'))
  try {
    const formats = path.join(root, 'src/formats')
    fs.mkdirSync(formats, { recursive: true })
    fs.writeFileSync(path.join(formats, 'zeta.zig'), '')
    fs.writeFileSync(path.join(formats, 'ignored.txt'), '')
    fs.writeFileSync(path.join(formats, 'alpha.zig'), '')
    fs.writeFileSync(path.join(root, 'src/tailwind.zig'), '')
    assert.deepEqual(discoverLegacyAdapterSources(root), [
      'src/formats/alpha.zig',
      'src/formats/zeta.zig',
      'src/tailwind.zig',
    ])

    fs.rmSync(formats, { recursive: true })
    fs.symlinkSync(path.join(root, 'src'), formats, 'dir')
    assert.throws(() => discoverLegacyAdapterSources(root), /src\/formats must be a regular directory/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
