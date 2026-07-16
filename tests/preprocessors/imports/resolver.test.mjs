import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createConfinedResolver } from '../../../preprocessor/resolver.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')

function rejectsWithCode(code) {
  return error => error?.code === code
}

async function withFixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-resolver-'))
  const root = path.join(temporary, 'root')
  const outside = path.join(temporary, 'outside')
  fs.mkdirSync(root)
  fs.mkdirSync(outside)
  try {
    await run({ temporary, root, outside })
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function url(filename) {
  return pathToFileURL(filename).href
}

function canonicalUrl(filename) {
  return pathToFileURL(fs.realpathSync(filename)).href
}

test('loads owned bytes from regular local files and records deterministic first-seen dependencies', async () => {
  await withFixture(async ({ root }) => {
    const first = path.join(root, 'first.scss')
    const second = path.join(root, 'second.scss')
    fs.writeFileSync(first, 'a')
    fs.writeFileSync(second, 'bb')

    const resolver = createConfinedResolver({ roots: [root] })
    const session = resolver.createSession()
    const loadedSecond = await session.load(url(second), { kind: 'use', ancestry: [] })
    const loadedFirst = await session.load(url(first), { kind: 'import', ancestry: [] })
    const duplicateSecond = await session.load(url(path.join(root, '.', 'second.scss')), {
      kind: 'forward',
      ancestry: [],
    })

    assert.equal(loadedSecond.url, canonicalUrl(second))
    assert.equal(loadedSecond.contents.toString('utf8'), 'bb')
    assert.equal(loadedFirst.contents.toString('utf8'), 'a')
    assert.equal(duplicateSecond.contents.toString('utf8'), 'bb')
    assert.deepEqual(session.dependencies(), [
      { url: canonicalUrl(second), kind: 'use' },
      { url: canonicalUrl(first), kind: 'import' },
    ])
    assert.deepEqual(session.stats(), { reads: 3, files: 2, bytes: 5 })

    const replay = resolver.createSession()
    await replay.load(url(second), { kind: 'use', ancestry: [] })
    await replay.load(url(first), { kind: 'import', ancestry: [] })
    await replay.load(url(second), { kind: 'forward', ancestry: [] })
    assert.deepEqual(replay.dependencies(), session.dependencies())
    assert.deepEqual(replay.stats(), session.stats())
  })
})

test('rejects network schemes, malformed file URLs, query/fragment aliases, and lexical escapes', async () => {
  await withFixture(async ({ root, outside }) => {
    const inside = path.join(root, 'inside.scss')
    const escaped = path.join(outside, 'escaped.scss')
    fs.writeFileSync(inside, '.inside{}')
    fs.writeFileSync(escaped, '.escaped{}')
    const session = createConfinedResolver({ roots: [root] }).createSession()

    await assert.rejects(
      session.load('https://example.com/input.scss', { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_SCHEME'),
    )
    await assert.rejects(
      session.load(url(escaped), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_PATH_ESCAPE'),
    )
    await assert.rejects(
      session.load(`${url(inside)}?raw=1`, { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_URL_INVALID'),
    )
    await assert.rejects(
      session.load(`${url(inside)}#fragment`, { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_URL_INVALID'),
    )
    await assert.rejects(
      session.load(url(inside).replace('inside.scss', 'nested%2Finside.scss'), {
        kind: 'import',
        ancestry: [],
      }),
      rejectsWithCode('RESOLVER_URL_INVALID'),
    )
    assert.deepEqual(session.dependencies(), [])
  })
})

test('rejects missing paths, directories, invalid dependency kinds, and closed sessions', async () => {
  await withFixture(async ({ root }) => {
    const directory = path.join(root, 'directory')
    const file = path.join(root, 'file.scss')
    fs.mkdirSync(directory)
    fs.writeFileSync(file, '.file{}')
    const session = createConfinedResolver({ roots: [root] }).createSession()

    await assert.rejects(
      session.load(url(path.join(root, 'missing.scss')), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_MISSING'),
    )
    await assert.rejects(
      session.load(url(directory), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_NOT_REGULAR'),
    )
    await assert.rejects(
      session.load(url(file), { kind: 'plugin', ancestry: [] }),
      rejectsWithCode('RESOLVER_KIND_INVALID'),
    )
    await assert.rejects(
      session.load(url(file), { kind: 'import', ancestry: [], fallback: true }),
      rejectsWithCode('RESOLVER_LOAD_OPTIONS_INVALID'),
    )
    assert.deepEqual(session.dependencies(), [])
    session.close()
    await assert.rejects(
      session.load(url(file), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_SESSION_CLOSED'),
    )
  })
})

test('rejects symlink files whether they remain inside a root or escape it', {
  skip: process.platform === 'win32',
}, async () => {
  await withFixture(async ({ root, outside }) => {
    const inside = path.join(root, 'inside.scss')
    const outsideFile = path.join(outside, 'outside.scss')
    const insideLink = path.join(root, 'inside-link.scss')
    const outsideLink = path.join(root, 'outside-link.scss')
    const outsideDirectoryLink = path.join(root, 'outside-directory')
    fs.writeFileSync(inside, '.inside{}')
    fs.writeFileSync(outsideFile, '.outside{}')
    fs.symlinkSync(inside, insideLink)
    fs.symlinkSync(outsideFile, outsideLink)
    fs.symlinkSync(outside, outsideDirectoryLink)
    const session = createConfinedResolver({ roots: [root] }).createSession()

    await assert.rejects(
      session.load(url(insideLink), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_SYMLINK'),
    )
    await assert.rejects(
      session.load(url(outsideLink), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_SYMLINK'),
    )
    await assert.rejects(
      session.load(url(path.join(outsideDirectoryLink, 'outside.scss')), {
        kind: 'import',
        ancestry: [],
      }),
      rejectsWithCode('RESOLVER_SYMLINK'),
    )
    assert.deepEqual(session.dependencies(), [])
  })
})

test('rejects unreadable files without creating dependency facts', {
  skip: process.platform === 'win32' || process.getuid?.() === 0,
}, async () => {
  await withFixture(async ({ root }) => {
    const file = path.join(root, 'unreadable.scss')
    fs.writeFileSync(file, '.unreadable{}', { mode: 0o600 })
    fs.chmodSync(file, 0o000)
    try {
      const session = createConfinedResolver({ roots: [root] }).createSession()
      await assert.rejects(
        session.load(url(file), { kind: 'import', ancestry: [] }),
        rejectsWithCode('RESOLVER_UNREADABLE'),
      )
      assert.deepEqual(session.dependencies(), [])
    } finally {
      fs.chmodSync(file, 0o600)
    }
  })
})

test('enforces caller-supplied canonical ancestry for cycle and depth limits', async () => {
  await withFixture(async ({ root }) => {
    const first = path.join(root, 'first.scss')
    const second = path.join(root, 'second.scss')
    const third = path.join(root, 'third.scss')
    for (const file of [first, second, third]) fs.writeFileSync(file, path.basename(file))
    const session = createConfinedResolver({ roots: [root], limits: { maxDepth: 2 } }).createSession()

    await assert.rejects(
      session.load(url(first), { kind: 'import', ancestry: [canonicalUrl(first)] }),
      rejectsWithCode('RESOLVER_CYCLE'),
    )
    await assert.rejects(
      session.load(url(third), {
        kind: 'import',
        ancestry: [canonicalUrl(first), canonicalUrl(second)],
      }),
      rejectsWithCode('RESOLVER_DEPTH_LIMIT'),
    )
    await assert.rejects(
      session.load(url(first), { kind: 'import', ancestry: ['https://example.com/base.scss'] }),
      rejectsWithCode('RESOLVER_ANCESTRY_INVALID'),
    )
    await assert.rejects(
      session.load(url(third), {
        kind: 'import',
        ancestry: [canonicalUrl(first), canonicalUrl(first)],
      }),
      rejectsWithCode('RESOLVER_CYCLE'),
    )
    assert.deepEqual(session.dependencies(), [])
  })
})

test('enforces per-file, cumulative-byte, unique-file, and read-count limits', async () => {
  await withFixture(async ({ root }) => {
    const first = path.join(root, 'first.scss')
    const second = path.join(root, 'second.scss')
    fs.writeFileSync(first, 'abc')
    fs.writeFileSync(second, 'def')

    const perFile = createConfinedResolver({
      roots: [root],
      limits: { maxFileBytes: 2 },
    }).createSession()
    await assert.rejects(
      perFile.load(url(first), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_FILE_LIMIT'),
    )

    const cumulative = createConfinedResolver({
      roots: [root],
      limits: { maxTotalBytes: 5 },
    }).createSession()
    await cumulative.load(url(first), { kind: 'import', ancestry: [] })
    await assert.rejects(
      cumulative.load(url(second), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_TOTAL_LIMIT'),
    )
    assert.deepEqual(cumulative.dependencies(), [{ url: canonicalUrl(first), kind: 'import' }])

    const files = createConfinedResolver({
      roots: [root],
      limits: { maxFiles: 1 },
    }).createSession()
    await files.load(url(first), { kind: 'import', ancestry: [] })
    await assert.rejects(
      files.load(url(second), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_FILE_COUNT_LIMIT'),
    )

    const reads = createConfinedResolver({
      roots: [root],
      limits: { maxReads: 1 },
    }).createSession()
    await reads.load(url(first), { kind: 'import', ancestry: [] })
    await assert.rejects(
      reads.load(url(first), { kind: 'import', ancestry: [] }),
      rejectsWithCode('RESOLVER_READ_COUNT_LIMIT'),
    )
  })
})

test('rejects relative, duplicate, non-directory, and symlink roots', {
  skip: process.platform === 'win32',
}, async () => {
  await withFixture(async ({ root, outside }) => {
    const file = path.join(root, 'file.scss')
    const rootLink = path.join(outside, 'root-link')
    fs.writeFileSync(file, '.file{}')
    fs.symlinkSync(root, rootLink)

    assert.throws(() => createConfinedResolver({ roots: ['.'] }), rejectsWithCode('RESOLVER_ROOT_INVALID'))
    assert.throws(
      () => createConfinedResolver({ roots: [root], network: true }),
      rejectsWithCode('RESOLVER_OPTIONS_INVALID'),
    )
    assert.throws(
      () => createConfinedResolver({ roots: [root], limits: { maxDepth: 129 } }),
      rejectsWithCode('RESOLVER_LIMIT_INVALID'),
    )
    assert.throws(
      () => createConfinedResolver({ roots: [root], limits: { network: 1 } }),
      rejectsWithCode('RESOLVER_LIMIT_INVALID'),
    )
    assert.throws(
      () => createConfinedResolver({ roots: [root, root] }),
      rejectsWithCode('RESOLVER_ROOT_INVALID'),
    )
    assert.throws(
      () => createConfinedResolver({ roots: [file] }),
      rejectsWithCode('RESOLVER_ROOT_INVALID'),
    )
    assert.throws(
      () => createConfinedResolver({ roots: [rootLink] }),
      rejectsWithCode('RESOLVER_ROOT_INVALID'),
    )
  })
})

test('documents confinement without claiming language-specific resolution or public support', () => {
  const documentation = fs.readFileSync(path.join(repositoryRoot, 'preprocessor/README.md'), 'utf8')
  for (const statement of [
    'does **not** implement Sass partial/extension search',
    'pass the resulting absolute candidate URL through this loader',
    'rejects credentials, queries, fragments, encoded separators',
    'every symlink entry',
    '40 MiB across reads',
    'deduplicated by canonical URL',
    'does not make any preprocessor syntax available',
  ]) {
    assert.match(documentation, new RegExp(statement.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  }
})
