const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const { discoverServer } = require('../out/binaryDiscovery.js')

function options({
  platform = 'linux',
  extensionPath = '/extension',
  env = {},
  usable = [],
} = {}) {
  const files = new Set(usable)
  return {
    platform,
    extensionPath,
    env,
    isUsableFile: candidate => files.has(candidate),
  }
}

test('an explicit absolute executable wins without consulting PATH', () => {
  const result = discoverServer(
    '/configured/zigcss',
    options({
      env: { PATH: '/path' },
      usable: ['/configured/zigcss', '/path/zigcss'],
    }),
  )

  assert.equal(result.ok, true)
  assert.equal(result.command, '/configured/zigcss')
  assert.equal(result.source, 'configured-path')
  assert.deepEqual(result.checked, ['/configured/zigcss'])
})

test('an invalid explicit path fails closed instead of falling back', () => {
  const result = discoverServer(
    '/missing/zigcss',
    options({ env: { PATH: '/path' }, usable: ['/path/zigcss'] }),
  )

  assert.equal(result.ok, false)
  assert.match(result.message, /configured executable does not exist/i)
  assert.deepEqual(result.checked, ['/missing/zigcss'])
})

test('a configured path with separators must be absolute', () => {
  const result = discoverServer('./zig-out/bin/zigcss', options())

  assert.equal(result.ok, false)
  assert.match(result.message, /absolute path or a bare command name/i)
  assert.deepEqual(result.checked, [])

  for (const invalid of ['x'.repeat(65537), 'zig\0css']) {
    const bounded = discoverServer(invalid, options())
    assert.equal(bounded.ok, false)
    assert.match(bounded.message, /limits or contains NUL/i)
    assert.deepEqual(bounded.checked, [])
  }
})

test('automatic discovery prefers an extension-local binary over PATH', () => {
  const result = discoverServer(
    '',
    options({
      env: { PATH: '/path' },
      usable: ['/extension/bin/zigcss', '/path/zigcss'],
    }),
  )

  assert.equal(result.ok, true)
  assert.equal(result.command, '/extension/bin/zigcss')
  assert.equal(result.source, 'bundled')
})

test('PATH lookup is ordered and ignores empty or relative directories', () => {
  const result = discoverServer(
    undefined,
    options({
      env: { PATH: 'relative:/first::/second' },
      usable: ['/second/zigcss'],
    }),
  )

  assert.equal(result.ok, true)
  assert.equal(result.command, '/second/zigcss')
  assert.equal(result.source, 'path')
  assert.deepEqual(result.checked, [
    '/extension/bin/zigcss',
    '/first/zigcss',
    '/second/zigcss',
  ])
})

test('a configured bare command is resolved through absolute PATH entries', () => {
  const result = discoverServer(
    'custom-zigcss',
    options({
      env: { PATH: '/first:/second' },
      usable: ['/first/custom-zigcss'],
    }),
  )

  assert.equal(result.ok, true)
  assert.equal(result.command, '/first/custom-zigcss')
  assert.equal(result.source, 'configured-command')
})

test('Windows discovery honors Path, PATHEXT, and the .exe bundled name', () => {
  const result = discoverServer('', options({
    platform: 'win32',
    extensionPath: 'C:\\extension',
    env: {
      Path: 'relative;C:\\first;D:\\second',
      PATHEXT: '.EXE;.CMD',
    },
    usable: ['D:\\second\\zigcss.EXE'],
  }))

  assert.equal(result.ok, true)
  assert.equal(result.command, 'D:\\second\\zigcss.EXE')
  assert.equal(result.source, 'path')
  assert.equal(result.checked[0], 'C:\\extension\\bin\\zigcss.exe')
})

test('automatic failure explains the bounded discovery boundary', () => {
  const result = discoverServer('', options({ env: { PATH: '/one:/two' } }))

  assert.equal(result.ok, false)
  assert.match(result.message, /zigcss\.languageServerPath/)
  assert.match(result.message, /extension package and absolute PATH entries/i)
  assert.deepEqual(result.checked, [
    '/extension/bin/zigcss',
    '/one/zigcss',
    '/two/zigcss',
  ])
})

test('real POSIX discovery requires a regular executable file', {
  skip: process.platform === 'win32',
}, () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-discovery-'))
  try {
    const command = path.join(temporary, 'zigcss')
    fs.writeFileSync(command, '#!/bin/sh\nexit 0\n')
    fs.chmodSync(command, 0o644)
    const rejected = discoverServer('', {
      extensionPath: path.join(temporary, 'extension'),
      env: { PATH: temporary },
    })
    assert.equal(rejected.ok, false)

    fs.chmodSync(command, 0o755)
    const accepted = discoverServer('', {
      extensionPath: path.join(temporary, 'extension'),
      env: { PATH: temporary },
    })
    assert.equal(accepted.ok, true)
    assert.equal(accepted.command, command)
  } finally {
    fs.rmSync(temporary, { force: true, recursive: true })
  }
})
