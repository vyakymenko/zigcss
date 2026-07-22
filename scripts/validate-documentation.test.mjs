import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  extractFences,
  extractLinks,
  extractSiteCodeFences,
  repositoryRoot,
  validateInternalLink,
  validateFencePolicy,
  validateExecutableFences,
  validateRepositoryDocumentation,
} from './validate-documentation.mjs'

test('fence parser handles marker length, indentation, and unterminated input', () => {
  const fences = extractFences('  ~~~~json\n{"ok":true}\n  ~~~~\n\n```bash\nprintf ok\n```', 'fixture.md')
  assert.deepEqual(fences.map(fence => [fence.language, fence.content, fence.startLine]), [
    ['json', '{"ok":true}', 1],
    ['bash', 'printf ok', 5],
  ])
  assert.throws(() => extractFences('```css\na{}', 'broken.md'), /unterminated fence/)
})

test('link parser ignores code while retaining inline, reference, and HTML targets', () => {
  const links = extractLinks([
    '[inline](guide/page.md#heading)',
    '`[ignored](missing.md)`',
    '[resolved][reference]',
    '[reference]: <other.md>',
    '<a href="/features">Feature</a>',
    '```text',
    '[also ignored](missing.md)',
    '```',
  ].join('\n'), 'fixture.md')
  assert.deepEqual(links.map(link => link.destination), ['guide/page.md#heading', 'other.md', '/features'])
  assert.throws(() => extractLinks('[broken][missing]', 'fixture.md'), /missing link label/)
  assert.deepEqual(extractLinks('[unused]: missing.md', 'fixture.md').map(link => link.destination), ['missing.md'])
})

test('internal link validation rejects missing targets, bad fragments, and symlink escapes', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-doc-links-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-doc-outside-'))
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  })
  fs.mkdirSync(path.join(root, 'docs'))
  fs.mkdirSync(path.join(root, 'docs', 'src', 'app', 'components'), { recursive: true })
  fs.writeFileSync(path.join(root, 'docs', 'page.md'), '# Real heading\n')
  fs.writeFileSync(path.join(root, 'docs', 'component.tsx'), '<section id="real-panel" />\n')
  fs.writeFileSync(path.join(root, 'docs', 'src', 'app', 'components', 'Home.tsx'), '<section id="site-panel" />\n')
  fs.writeFileSync(path.join(outside, 'secret.md'), '# Secret\n')
  fs.symlinkSync(outside, path.join(root, 'docs', 'escape'), process.platform === 'win32' ? 'junction' : 'dir')

  assert.equal(validateInternalLink({ source: 'docs/source.md', line: 1, destination: 'page.md#real-heading' }, root), true)
  assert.throws(() => validateInternalLink({ source: 'docs/source.md', line: 2, destination: 'missing.md' }, root), /missing target/)
  assert.throws(() => validateInternalLink({ source: 'docs/source.md', line: 3, destination: 'page.md#invented' }, root), /missing heading/)
  assert.throws(() => validateInternalLink({ source: 'docs/source.md', line: 4, destination: 'escape/secret.md' }, root), /escapes the repository/)
  assert.throws(() => validateInternalLink({ source: 'docs/source.md', line: 5, destination: '/invented' }, root), /unknown site route/)
  assert.equal(validateInternalLink({ source: 'docs/component.tsx', line: 6, destination: '#real-panel' }, root), true)
  assert.throws(() => validateInternalLink({ source: 'docs/component.tsx', line: 7, destination: '#invented-panel' }, root), /missing element id/)
  assert.equal(validateInternalLink({ source: 'docs/component.tsx', line: 8, destination: '/#site-panel' }, root), true)
  assert.throws(() => validateInternalLink({ source: 'docs/component.tsx', line: 9, destination: '/#invented-site-panel' }, root), /missing site element id/)
})

test('documentation policy paths cannot escape the repository', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-doc-policy-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'docs'))
  fs.writeFileSync(path.join(root, 'build.zig'), '')
  fs.writeFileSync(path.join(root, 'docs', 'documentation-validation.json'), JSON.stringify({
    schemaVersion: 1,
    executableZigExamples: ['../outside.zig'],
    cssModuleDocuments: [],
    nonExecutableFences: [],
  }))

  assert.throws(() => validateFencePolicy([], root), /repository-relative path/)
})

test('every tracked internal link and code fence has an owned validation path', () => {
  const summary = validateRepositoryDocumentation(repositoryRoot)
  assert.ok(summary.markdownFiles >= 30)
  assert.ok(summary.fences >= 50)
  assert.ok(summary.internalLinks >= 25)
  assert.ok(summary.literalRoutes >= 10)
  assert.equal(summary.siteFences, 8)
  const siteFences = extractSiteCodeFences(repositoryRoot)
  assert.deepEqual(
    siteFences.map(fence => fence.language),
    ['text', 'text', 'bash', 'bash', 'bash', 'css', 'bash', 'text'],
  )
  assert.equal(siteFences[0].content, '{selected.input}')
  assert.equal(siteFences[1].content, '{selected.output}')
  assert.match(
    fs.readFileSync(path.join(repositoryRoot, 'tests/preprocessors/product/site-examples.test.mjs'), 'utf8'),
    /exact executable evidence for all five syntaxes/,
  )
})

test('executable fence validation fails closed on invalid shell, JSON, CSS, Lua, and Vim input', () => {
  const policy = { cssModuleDocuments: [] }
  const fence = (language, content) => ({
    source: 'invalid.md',
    startLine: 1,
    language,
    content,
  })

  assert.throws(() => validateExecutableFences([fence('bash', 'if then')], policy, repositoryRoot), /bash syntax exited/)
  assert.throws(() => validateExecutableFences([fence('json', '{')], policy, repositoryRoot), /JSON syntax/)
  assert.throws(() => validateExecutableFences([fence('css', '.broken { color }')], policy, repositoryRoot), /CSS example exited/)
  assert.throws(() => validateExecutableFences([fence('lua', 'local =')], policy, repositoryRoot), /Lua syntax exited/)
  assert.throws(() => validateExecutableFences([fence('vim', ':definitely-not-a-command')], policy, repositoryRoot), /Vim command syntax exited/)
})

test('every executable documentation fence passes its real syntax or compiler gate', () => {
  const summary = validateRepositoryDocumentation(repositoryRoot, { execute: true })
  assert.ok(summary.executableFences >= 40)
})
