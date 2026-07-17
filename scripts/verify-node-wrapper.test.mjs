import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

test('npm package metadata is canonical before registry publication', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  const lock = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package-lock.json'), 'utf8'))
  assert.deepEqual(manifest.bin, { zigcss: 'index.js' })
  assert.deepEqual(lock.packages[''].bin, manifest.bin)
  assert.deepEqual(manifest.repository, {
    type: 'git',
    url: 'git+https://github.com/vyakymenko/zigcss.git',
  })
})

function withWrapperFixture(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-wrapper-'))
  try {
    fs.copyFileSync(path.join(repositoryRoot, 'index.js'), path.join(directory, 'index.js'))
    const binDirectory = path.join(directory, 'bin')
    fs.mkdirSync(binDirectory)
    const binary = path.join(binDirectory, process.platform === 'win32' ? 'zigcss.exe' : 'zigcss')
    fs.writeFileSync(binary, `#!/usr/bin/env node
const mode = process.argv[2]
if (mode === 'echo') {
  process.stdin.pipe(process.stdout)
} else if (mode === 'signal') {
  process.kill(process.pid, 'SIGTERM')
} else {
  process.exit(Number.parseInt(mode, 10))
}
`)
    fs.chmodSync(binary, 0o755)
    run(path.join(directory, 'index.js'))
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

test('npm wrapper forwards stdin/stdout and exact native exit statuses', () => {
  withWrapperFixture(wrapper => {
    for (const code of [0, 1, 2]) {
      const result = spawnSync(process.execPath, [wrapper, String(code)], { encoding: 'utf8' })
      assert.equal(result.error, undefined)
      assert.equal(result.signal, null)
      assert.equal(result.status, code)
    }

    const input = '.wrapper{color:red}'
    const streamed = spawnSync(process.execPath, [wrapper, 'echo'], {
      encoding: 'utf8',
      input,
    })
    assert.equal(streamed.status, 0)
    assert.equal(streamed.stderr, '')
    assert.equal(streamed.stdout, input)
  })
})

test('npm wrapper help publishes the combined five-language contract', () => {
  withWrapperFixture(wrapper => {
    const result = spawnSync(process.execPath, [wrapper, '--help'], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stderr, '')
    for (const expected of [
      '--syntax <css|scss|sass|less|stylus>',
      'Dart Sass 1.101.0',
      'Less 4.6.7',
      'Stylus 0.64.0',
      'project plugins, custom functions, custom importers, or JavaScript',
    ]) {
      assert.match(result.stdout, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
    }
  })
})

test('npm wrapper never converts a native signal into success', { skip: process.platform === 'win32' }, () => {
  withWrapperFixture(wrapper => {
    const result = spawnSync(process.execPath, [wrapper, 'signal'], { encoding: 'utf8' })
    assert.equal(result.error, undefined)
    assert.equal(result.status, null)
    assert.equal(result.signal, 'SIGTERM')
  })
})
