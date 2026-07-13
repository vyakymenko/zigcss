// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import capabilityMetadata from './data/capabilities.json'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const startMarker = '<!-- capability-status:start -->'
const endMarker = '<!-- capability-status:end -->'
const read = (relativePath: string) =>
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

function generatedTable(content: string): string {
  const start = content.indexOf(startMarker)
  const end = content.indexOf(endMarker)
  expect(start).toBeGreaterThanOrEqual(0)
  expect(end).toBeGreaterThan(start)
  return content.slice(start + startMarker.length, end).trim()
}

describe('evidence-linked capability status metadata', () => {
  test('defines one closed row and status vocabulary', () => {
    expect(capabilityMetadata.schemaVersion).toBe(1)
    expect(capabilityMetadata.statusKinds).toEqual([
      'experimental',
      'verified',
      'unavailable',
      'disabled',
    ])
    expect(capabilityMetadata.capabilities).toHaveLength(21)
    expect(new Set(capabilityMetadata.capabilities.map(item => item.id)).size).toBe(21)
    expect(new Set(capabilityMetadata.capabilities.map(item => item.surface)).size).toBe(21)
  })

  test('anchors every row to a declared executable gate and real source text', () => {
    const used = new Set<string>()
    for (const capability of capabilityMetadata.capabilities) {
      expect(capability.evidence.length).toBeGreaterThan(0)
      for (const gateId of capability.evidence) {
        used.add(gateId)
        const gate = capabilityMetadata.gates[gateId as keyof typeof capabilityMetadata.gates]
        expect(gate).toBeDefined()
        expect(gate.command).toMatch(/^(npm|zig) /)
        for (const anchor of gate.anchors) {
          const content = read(anchor.path)
          for (const needle of anchor.contains) expect(content).toContain(needle)
        }
      }
    }
    expect([...used].sort()).toEqual(Object.keys(capabilityMetadata.gates).sort())
  })

  test('publishes one byte-identical generated table in both Markdown surfaces', () => {
    const rootTable = generatedTable(read('README.md'))
    const docsTable = generatedTable(read('docs/src/content/docs/guide/status.md'))

    expect(rootTable).toBe(docsTable)
    expect(rootTable.match(/^\| /gm)).toHaveLength(capabilityMetadata.capabilities.length + 1)
    for (const capability of capabilityMetadata.capabilities) {
      expect(rootTable).toContain(`| ${capability.surface} | ${capability.status} |`)
    }
  })

  test('keeps final editor and disabled-service boundaries current', () => {
    const byId = new Map(capabilityMetadata.capabilities.map(item => [item.id, item]))

    expect(byId.get('lsp')?.behavior).toContain('pull diagnostics')
    expect(byId.get('lsp')?.behavior).not.toMatch(/remain later|parser migration/i)
    expect(byId.get('vscode')?.behavior).toContain('no binary is bundled or published')
    expect(byId.get('neovim')?.behavior).toContain('0.11.7 and 0.12.4')
    expect(byId.get('release-artifacts')?.behavior).toContain('has not published a release')
    expect(byId.get('benchmark-report')?.statusKind).toBe('unavailable')
    expect(byId.get('benchmark-report')?.behavior).toContain('no archive is selected')
    expect(byId.get('public-compile')?.statusKind).toBe('disabled')
    expect(byId.get('public-compile')?.behavior).toContain('HTTP 503')
  })
})
