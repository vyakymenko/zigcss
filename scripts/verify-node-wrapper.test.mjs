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
  assert.deepEqual(manifest.bin, { zigcss: 'index.js', 'zigcss-install': 'install.js' })
  assert.deepEqual(lock.packages[''].bin, manifest.bin)
  assert.deepEqual(manifest.repository, {
    type: 'git',
    url: 'git+https://github.com/vyakymenko/zigcss.git',
  })
})

test('npm wrapper gives package-manager-neutral recovery when lifecycle scripts are disabled', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-wrapper-missing-'))
  try {
    fs.copyFileSync(path.join(repositoryRoot, 'index.js'), path.join(directory, 'index.js'))
    const result = spawnSync(process.execPath, [path.join(directory, 'index.js'), '--version'], {
      encoding: 'utf8',
    })
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /Lifecycle scripts may have been disabled/)
    assert.match(result.stderr, /zigcss-install/)
    assert.doesNotMatch(result.stderr, /npm install/)
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

test('javascript wrapper selects only a marker-verified confined source-checkout binary', {
  skip: process.platform === 'win32',
}, t => {
  const sourceRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-wrapper-source-')))
  const externalRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-wrapper-external-')))
  t.after(() => {
    fs.rmSync(sourceRoot, { recursive: true, force: true })
    fs.rmSync(externalRoot, { recursive: true, force: true })
  })

  const wrapper = path.join(sourceRoot, 'index.js')
  fs.copyFileSync(path.join(repositoryRoot, 'index.js'), wrapper)
  fs.writeFileSync(path.join(sourceRoot, 'build.zig'), '// source-checkout marker\n')
  const sourceDirectory = path.join(sourceRoot, 'src')
  fs.mkdirSync(sourceDirectory)
  const protocolMarker = path.join(sourceDirectory, 'node_protocol.zig')
  fs.writeFileSync(protocolMarker, '// source-checkout protocol marker\n')
  const zigOut = path.join(sourceRoot, 'zig-out')
  const binaryDirectory = path.join(zigOut, 'bin')
  fs.mkdirSync(binaryDirectory, { recursive: true })
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const sourceBinary = path.join(binaryDirectory, binaryName)
  const binarySource = `#!/usr/bin/env node
process.stdout.write(JSON.stringify(process.argv.slice(2)))
`
  fs.writeFileSync(sourceBinary, binarySource, { mode: 0o755 })
  fs.chmodSync(sourceBinary, 0o755)

  const invokeWrapper = () => spawnSync(process.execPath, [wrapper, '--source-route'], { encoding: 'utf8' })
  const assertRejected = result => {
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /binary is missing or not executable/)
  }

  const selected = invokeWrapper()
  assert.equal(selected.status, 0, selected.stderr)
  assert.equal(selected.stderr, '')
  assert.equal(selected.stdout, '["--source-route"]')

  const parkedMarker = `${protocolMarker}.regular`
  fs.renameSync(protocolMarker, parkedMarker)
  assertRejected(invokeWrapper())
  fs.symlinkSync(path.basename(parkedMarker), protocolMarker)
  assertRejected(invokeWrapper())
  fs.unlinkSync(protocolMarker)
  fs.renameSync(parkedMarker, protocolMarker)

  const parkedBinary = `${sourceBinary}.regular`
  fs.renameSync(sourceBinary, parkedBinary)
  fs.symlinkSync(path.basename(parkedBinary), sourceBinary)
  assertRejected(invokeWrapper())
  fs.unlinkSync(sourceBinary)
  fs.renameSync(parkedBinary, sourceBinary)

  fs.rmSync(zigOut, { recursive: true, force: true })
  const escapedZigOut = path.join(externalRoot, 'zig-out')
  const escapedBinaryDirectory = path.join(escapedZigOut, 'bin')
  fs.mkdirSync(escapedBinaryDirectory, { recursive: true })
  const escapedBinary = path.join(escapedBinaryDirectory, binaryName)
  fs.writeFileSync(escapedBinary, binarySource, { mode: 0o755 })
  fs.chmodSync(escapedBinary, 0o755)
  fs.symlinkSync(escapedZigOut, zigOut, 'dir')
  assertRejected(invokeWrapper())
})

function withWrapperFixture(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-wrapper-'))
  try {
    fs.copyFileSync(path.join(repositoryRoot, 'index.js'), path.join(directory, 'index.js'))
    const binDirectory = path.join(directory, 'bin')
    fs.mkdirSync(binDirectory)
    const binary = path.join(binDirectory, process.platform === 'win32' ? 'zigcss.exe' : 'zigcss')
    fs.writeFileSync(binary, `#!/usr/bin/env node
const args = process.argv.slice(2)
if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
  process.stdout.write('ZigCSS native CLI\\n--syntax <syntax> Select css, scss, sass, less, or stylus\\nprovider plugins unavailable\\n')
  return
}
if (args.includes('--experimental-native')) {
  if (args.includes('--native-diagnostic-fixture')) {
    process.stderr.write('input.scss:0:12: error NATIVE0002: undefined Sass variable\\n')
    process.exit(1)
  }
  process.stdout.write(JSON.stringify(args))
  return
}
if (args.some(value => /\\.(?:scss|sass|less|styl)$/.test(value))) {
  process.stderr.write('native preprocessor syntax requires --experimental-native\\n')
  process.exit(2)
}
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

test('javascript wrapper routes the finite native syntax set through the installed binary', () => {
  const routeCases = [
    ['input.scss', 'scss'],
    ['input.sass', 'sass'],
    ['input.less', 'less'],
    ['input.styl', 'stylus'],
  ]

  withWrapperFixture(wrapper => {
    for (const [input, syntax] of routeCases) {
      const argv = [
        input,
        '--experimental-native',
        '--syntax',
        syntax,
        '--minify',
        '--source-map',
      ]
      const first = spawnSync(process.execPath, [wrapper, ...argv], { encoding: 'utf8' })
      const second = spawnSync(process.execPath, [wrapper, ...argv], { encoding: 'utf8' })

      assert.equal(first.error, undefined)
      assert.equal(first.signal, null)
      assert.equal(first.status, 0, first.stderr)
      assert.equal(first.stderr, '')
      assert.equal(first.stdout, JSON.stringify(argv))
      assert.equal(second.error, undefined)
      assert.equal(second.signal, first.signal)
      assert.equal(second.status, first.status)
      assert.equal(second.stderr, first.stderr)
      assert.equal(second.stdout, first.stdout)
    }
  })
})

test('javascript wrapper forwards native optimizer requests unchanged', () => {
  const routeCases = [
    ['input.scss', 'scss'],
    ['input.sass', 'sass'],
    ['input.less', 'less'],
    ['input.styl', 'stylus'],
  ]

  withWrapperFixture(wrapper => {
    for (const [input, syntax] of routeCases) {
      const argv = [
        input,
        '--experimental-native',
        '--syntax',
        syntax,
        '--optimize',
        '--minify',
      ]
      const result = spawnSync(process.execPath, [wrapper, ...argv], { encoding: 'utf8' })

      assert.equal(result.error, undefined)
      assert.equal(result.signal, null)
      assert.equal(result.status, 0, result.stderr)
      assert.equal(result.stderr, '')
      assert.equal(result.stdout, JSON.stringify(argv))
    }
  })
})

test('javascript wrapper forwards verified target prefix requests unchanged', () => {
  const routeCases = [
    ['input.scss', 'scss'],
    ['input.sass', 'sass'],
    ['input.less', 'less'],
    ['input.styl', 'stylus'],
  ]

  withWrapperFixture(wrapper => {
    for (const [input, syntax] of routeCases) {
      const argv = [
        input,
        '--experimental-native',
        '--syntax',
        syntax,
        '--autoprefix',
        '--browsers',
        'safari >= 7, ie >= 11',
        '--minify',
      ]
      const result = spawnSync(process.execPath, [wrapper, ...argv], { encoding: 'utf8' })

      assert.equal(result.error, undefined)
      assert.equal(result.signal, null)
      assert.equal(result.status, 0, result.stderr)
      assert.equal(result.stderr, '')
      assert.equal(result.stdout, JSON.stringify(argv))
    }
  })
})

test('javascript wrapper cannot reach the provider host', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'index.js'), 'utf8')
  assert.doesNotMatch(source, /preprocessor\//)
  assert.doesNotMatch(source, /shouldUseProductCli/)
  assert.doesNotMatch(source, /\bimport\s*\(/)
})

test('javascript wrapper keeps native routing explicit and ungated preprocessors fail closed', () => {
  withWrapperFixture(wrapper => {
    for (const input of ['input.scss', 'input.sass', 'input.less', 'input.styl']) {
      const result = spawnSync(process.execPath, [wrapper, input], { encoding: 'utf8' })
      assert.equal(result.error, undefined)
      assert.equal(result.signal, null)
      assert.equal(result.status, 2)
      assert.equal(result.stdout, '')
      assert.equal(result.stderr, 'native preprocessor syntax requires --experimental-native\n')
    }
  })
})

test('javascript wrapper preserves native diagnostic streams and exit status', () => {
  withWrapperFixture(wrapper => {
    const result = spawnSync(process.execPath, [
      wrapper,
      'input.scss',
      '--experimental-native',
      '--syntax',
      'scss',
      '--native-diagnostic-fixture',
    ], { encoding: 'utf8' })
    assert.equal(result.error, undefined)
    assert.equal(result.signal, null)
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.equal(
      result.stderr,
      'input.scss:0:12: error NATIVE0002: undefined Sass variable\n',
    )
  })
})

test('npm wrapper forwards stable native binary help', () => {
  withWrapperFixture(wrapper => {
    const result = spawnSync(process.execPath, [wrapper, '--help'], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stderr, '')
    for (const expected of [
      'native CLI',
      '--syntax <syntax> Select css, scss, sass, less, or stylus',
      'provider plugins unavailable',
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
