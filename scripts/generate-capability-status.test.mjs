import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  endMarker,
  expectedTargets,
  generatedTargets,
  loadMetadata,
  renderTable,
  repositoryRoot,
  replaceGeneratedTable,
  startMarker,
  validateMetadata,
} from './generate-capability-status.mjs'

test('capability metadata is closed, unique, and anchored to executable evidence', () => {
  const metadata = validateMetadata(loadMetadata())

  assert.equal(metadata.capabilities.length, 19)
  assert.equal(Object.keys(metadata.gates).length, 14)
  assert.deepEqual(metadata.statusKinds, ['experimental', 'verified', 'unavailable', 'disabled'])
  assert.equal(new Set(metadata.capabilities.map(capability => capability.id)).size, 19)
  assert.ok(metadata.capabilities.every(capability => capability.evidence.length > 0))
})

test('metadata validation fails closed on duplicate rows and unknown evidence', () => {
  const duplicate = structuredClone(loadMetadata())
  duplicate.capabilities.push(structuredClone(duplicate.capabilities[0]))
  assert.throws(() => validateMetadata(duplicate), /duplicate capability id/)

  const unknown = structuredClone(loadMetadata())
  unknown.capabilities[0].evidence = ['invented-gate']
  assert.throws(() => validateMetadata(unknown), /unknown gate/)

  const inventedStep = structuredClone(loadMetadata())
  inventedStep.gates['public-api'].command = 'zig build invented --summary all'
  assert.throws(() => validateMetadata(inventedStep), /no Zig build step/)

  const malformedMarkup = structuredClone(loadMetadata())
  malformedMarkup.capabilities[0].behavior = 'An `unterminated code span.'
  assert.throws(() => validateMetadata(malformedMarkup), /invalid inline code markup/)
})

test('evidence anchors cannot escape through a symlink', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-capability-root-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-capability-outside-'))
  try {
    fs.mkdirSync(path.join(root, 'docs'))
    fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts: { evidence: 'true' } }))
    fs.writeFileSync(path.join(root, 'docs', 'package.json'), JSON.stringify({ scripts: { test: 'true' } }))
    fs.writeFileSync(path.join(outside, 'evidence.txt'), 'verified')
    fs.symlinkSync(outside, path.join(root, 'evidence-link'), process.platform === 'win32' ? 'junction' : 'dir')

    const metadata = {
      schemaVersion: 1,
      statusKinds: ['experimental', 'verified', 'unavailable', 'disabled'],
      gates: {
        evidence: {
          command: 'npm run evidence',
          anchors: [{ path: 'evidence-link/evidence.txt', contains: ['verified'] }],
        },
      },
      capabilities: [{
        id: 'example',
        surface: 'Example',
        status: 'Verified',
        statusKind: 'verified',
        behavior: 'Example behavior.',
        evidence: ['evidence'],
      }],
    }

    assert.throws(() => validateMetadata(metadata, root), /anchor escapes the repository/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  }
})

test('README and status guide contain the exact generated table', () => {
  const metadata = validateMetadata(loadMetadata())
  const table = renderTable(metadata)
  const targets = expectedTargets(metadata)

  assert.equal(targets.length, 2)
  for (const { target, content } of targets) {
    assert.equal(content, fs.readFileSync(target, 'utf8'), path.relative(repositoryRoot, target))
    assert.equal(content.split(startMarker).length, 2)
    assert.equal(content.split(endMarker).length, 2)
    assert.ok(content.includes(table))
  }
})

test('generator check is deterministic and the site consumes metadata directly', () => {
  const result = spawnSync(process.execPath, ['scripts/generate-capability-status.mjs', '--check'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /19 rows, 14 executable evidence gates, 2 Markdown tables/)

  const features = fs.readFileSync(path.join(repositoryRoot, 'docs/src/app/components/Features.tsx'), 'utf8')
  assert.match(features, /data\/capabilities\.json/)
  assert.match(features, /capabilities\.map/)
  assert.doesNotMatch(features, /const capabilities = \[/)
})

test('generated replacement rejects missing or duplicate marker authority', () => {
  assert.throws(() => replaceGeneratedTable('no markers', 'table'), /missing ordered markers/)
  assert.throws(
    () => replaceGeneratedTable(`${startMarker}\n${startMarker}\n${endMarker}`, 'table'),
    /duplicate markers/,
  )
})

test('public disabled and final LSP/editor boundaries cannot regress to stale claims', () => {
  const capabilities = validateMetadata(loadMetadata()).capabilities
  const byId = new Map(capabilities.map(capability => [capability.id, capability]))

  assert.equal(byId.get('public-compile').statusKind, 'disabled')
  assert.match(byId.get('public-compile').behavior, /HTTP 503/)
  assert.match(byId.get('lsp').behavior, /pull diagnostics/)
  assert.match(byId.get('lsp').behavior, /editor-integration gates/)
  assert.doesNotMatch(byId.get('lsp').behavior, /remain later|parser migration/i)
  assert.match(byId.get('vscode').behavior, /no binary is bundled or published/)
  assert.match(byId.get('neovim').behavior, /0\.11\.7 and 0\.12\.4/)
})
