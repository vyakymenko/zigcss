import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { runProductCli } from '../../../preprocessor/product-cli.mjs'
import { loadFileForCompilation } from '../../../preprocessor/product-api.mjs'
import { runZigCssCore } from '../../../preprocessor/core-runner.mjs'
import { runPreprocessorHost } from '../../../preprocessor/runner.mjs'
import { parseSourceMap } from '../../../preprocessor/source-map.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const binaryPath = path.join(
  repositoryRoot,
  'zig-out',
  'bin',
  process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
)
const runtime = Object.freeze({ binaryPath, runCore: runZigCssCore, runHost: runPreprocessorHost })

function writeDevelopmentProductLauncher(fixture) {
  fs.cpSync(path.join(repositoryRoot, 'preprocessor'), path.join(fixture, 'preprocessor'), {
    recursive: true,
  })
  const launcher = path.join(fixture, 'development-product-launcher.mjs')
  fs.writeFileSync(launcher, [
    "import { mainProductCli } from './preprocessor/product-cli.mjs'",
    'await mainProductCli()',
    '',
  ].join('\n'))
  return launcher
}

test('npm launcher contains no route into the development provider CLI', () => {
  const source = fs.readFileSync(path.join(repositoryRoot, 'index.js'), 'utf8')
  assert.doesNotMatch(source, /shouldUseProductCli/)
  assert.doesNotMatch(source, /preprocessor\//)
  assert.doesNotMatch(source, /product-cli\.mjs/)
  assert.match(source, /runNative\(binaryPath, args\);/)
})

test('development provider CLI reaches the canonical reference pipeline', () => {
  const fixture = fs.mkdtempSync(path.join(repositoryRoot, '.zigcss-product-launcher-'))
  try {
    const launcher = writeDevelopmentProductLauncher(fixture)
    fs.mkdirSync(path.join(fixture, 'bin'))
    const fixtureBinary = path.join(
      fixture,
      'bin',
      process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
    )
    fs.copyFileSync(binaryPath, fixtureBinary)
    if (process.platform !== 'win32') fs.chmodSync(fixtureBinary, 0o755)
    fs.writeFileSync(
      path.join(fixture, 'input.scss'),
      '$color: red; .card { color: $color; }',
    )

    const result = spawnSync(process.execPath, [
      launcher,
      'input.scss',
      '--minify',
    ], {
      cwd: fixture,
      encoding: 'utf8',
    })
    assert.equal(result.error, undefined)
    assert.equal(result.signal, null)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, '.card{color:red}')
    assert.equal(result.stderr, '')

    const stdinResult = spawnSync(process.execPath, [
      launcher,
      '-',
      '--syntax',
      'sass',
      '--minify',
    ], {
      cwd: fixture,
      encoding: 'utf8',
      input: '$color: blue\n.card\n  color: $color\n',
    })
    assert.equal(stdinResult.error, undefined)
    assert.equal(stdinResult.signal, null)
    assert.equal(stdinResult.status, 0, stdinResult.stderr)
    assert.equal(stdinResult.stdout, '.card{color:blue}')
    assert.equal(stdinResult.stderr, '')
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true })
  }
})

async function invoke(cwd, argv, stdin = '') {
  let stdout = ''
  let stderr = ''
  const status = await runProductCli(argv, {
    cwd,
    readStdin: async () => stdin,
    writeStdout: value => { stdout += value },
    writeStderr: value => { stderr += value },
    runtime,
  })
  return { status, stdout, stderr }
}

async function invokeWithOptions(cwd, argv, options = {}) {
  let stdout = ''
  let stderr = ''
  const status = await runProductCli(argv, {
    cwd,
    readStdin: async () => '',
    writeStdout: value => { stdout += value },
    writeStderr: value => { stderr += value },
    runtime,
    ...options,
  })
  return { status, stdout, stderr }
}

test('npm CLI compiles explicit preprocessor stdin to stdout', async () => {
  const result = await invoke(
    process.cwd(),
    ['-', '--syntax', 'scss', '--minify'],
    '$color: red; .card { color: $color; }',
  )
  assert.equal(result.status, 0)
  assert.equal(result.stdout, '.card{color:red}')
  assert.equal(result.stderr, '')
})

test('npm CLI detects file syntax and atomically writes one inline mapped output', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-'))
  try {
    fs.writeFileSync(path.join(temporary, 'input.less'), '@color: red; .card { color: @color; }')
    const result = await invoke(temporary, [
      'input.less',
      '-o',
      'dist/output.css',
      '--minify',
      '--source-map',
    ])
    assert.equal(result.status, 0)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, 'Compiled: input.less -> dist/output.css\n')
    const output = fs.readFileSync(path.join(temporary, 'dist/output.css'), 'utf8')
    const match = output.match(/^\.card\{color:red\}\n\/\*# sourceMappingURL=data:application\/json;charset=utf-8;base64,([A-Za-z0-9+/=]+) \*\/$/)
    assert.notEqual(match, null)
    const map = Buffer.from(match[1], 'base64').toString('utf8')
    assert.equal(parseSourceMap(map).sources.length, 1)
    assert.deepEqual(fs.readdirSync(path.join(temporary, 'dist')), ['output.css'])
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI passes explicit confined load paths into file compilation', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-load-path-'))
  try {
    fs.mkdirSync(path.join(temporary, 'source'))
    fs.mkdirSync(path.join(temporary, 'shared'))
    fs.writeFileSync(
      path.join(temporary, 'source/input.less'),
      '@import "tokens"; .card { color: @color; }',
    )
    fs.writeFileSync(path.join(temporary, 'shared/tokens.less'), '@color: blue;')
    const result = await invoke(temporary, [
      'source/input.less',
      '--load-path',
      'shared',
      '-o',
      'output.css',
      '--minify',
    ])

    assert.equal(result.status, 0)
    assert.equal(result.stderr, 'Compiled: source/input.less -> output.css\n')
    assert.equal(fs.readFileSync(path.join(temporary, 'output.css'), 'utf8'), '.card{color:blue}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI compiles a mixed batch in argument order with deterministic names', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-batch-'))
  try {
    const fixtures = [
      ['first.scss', '$n: 1; .first { z-index: $n; }'],
      ['second.less', '@n: 2; .second { z-index: @n; }'],
      ['third.styl', 'n = 3\n.third\n  z-index n\n'],
      ['fourth.css', '.fourth { z-index: 4; }'],
    ]
    for (const [name, source] of fixtures) fs.writeFileSync(path.join(temporary, name), source)
    const result = await invoke(temporary, [
      ...fixtures.map(([name]) => name),
      '-o',
      'dist',
      '--output-dir',
      '--minify',
    ])
    assert.equal(result.status, 0)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, fixtures.map(([name]) => (
      `Compiled: ${name} -> ${path.join('dist', `${path.parse(name).name}.css`)}\n`
    )).join(''))
    assert.deepEqual(fs.readdirSync(path.join(temporary, 'dist')).sort(), [
      'first.css',
      'fourth.css',
      'second.css',
      'third.css',
    ])
    assert.equal(fs.readFileSync(path.join(temporary, 'dist/first.css'), 'utf8'), '.first{z-index:1}')
    assert.equal(fs.readFileSync(path.join(temporary, 'dist/second.css'), 'utf8'), '.second{z-index:2}')
    assert.equal(fs.readFileSync(path.join(temporary, 'dist/third.css'), 'utf8'), '.third{z-index:3}')
    assert.equal(fs.readFileSync(path.join(temporary, 'dist/fourth.css'), 'utf8'), '.fourth{z-index:4}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI gives colliding batch stems deterministic path-derived output names', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-names-'))
  try {
    for (const [directory, index] of [['one', 1], ['two', 2]]) {
      fs.mkdirSync(path.join(temporary, directory))
      fs.writeFileSync(
        path.join(temporary, directory, 'input.scss'),
        `$n: ${index}; .item-${index} { z-index: $n; }`,
      )
    }
    const argv = [
      path.join('one', 'input.scss'),
      path.join('two', 'input.scss'),
      '-o',
      'dist',
      '--output-dir',
      '--minify',
    ]
    const first = await invoke(temporary, argv)
    const names = fs.readdirSync(path.join(temporary, 'dist')).sort()
    const second = await invoke(temporary, argv)

    assert.equal(first.status, 0)
    assert.equal(second.status, 0)
    assert.equal(first.stderr, second.stderr)
    assert.equal(names.length, 2)
    assert.equal(new Set(names).size, 2)
    for (const name of names) assert.match(name, /^input-[0-9a-f]{16}\.css$/)
    assert.deepEqual(fs.readdirSync(path.join(temporary, 'dist')).sort(), names)
    assert.deepEqual(
      new Set(names.map(name => fs.readFileSync(path.join(temporary, 'dist', name), 'utf8'))),
      new Set(['.item-1{z-index:1}', '.item-2{z-index:2}']),
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI bounds parallel workers while committing batch progress in argument order', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-workers-'))
  try {
    const inputs = Array.from({ length: 12 }, (_, index) => `input-${index}.scss`)
    for (const [index, input] of inputs.entries()) {
      fs.writeFileSync(path.join(temporary, input), `$n: ${index}; .item-${index} { z-index: $n; }`)
    }
    let active = 0
    let peak = 0
    const boundedRuntime = Object.freeze({
      ...runtime,
      async runHost(request, options) {
        active += 1
        peak = Math.max(peak, active)
        const index = Number(request.source.match(/\.item-(\d+)/)[1])
        try {
          await new Promise(resolve => setTimeout(resolve, (12 - index) * 2))
          return await runPreprocessorHost(request, options)
        } finally {
          active -= 1
        }
      },
    })
    const result = await invokeWithOptions(temporary, [
      ...inputs,
      '-o',
      'dist',
      '--output-dir',
      '--minify',
    ], { runtime: boundedRuntime })

    assert.equal(result.status, 0)
    assert.equal(peak, 8)
    assert.deepEqual(
      result.stderr.trimEnd().split('\n'),
      inputs.map(input => `Compiled: ${input} -> ${path.join('dist', input.replace(/\.scss$/, '.css'))}`),
    )
    for (const [index, input] of inputs.entries()) {
      assert.equal(
        fs.readFileSync(path.join(temporary, 'dist', input.replace(/\.scss$/, '.css')), 'utf8'),
        `.item-${index}{z-index:${index}}`,
      )
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI batch compilation failure commits no output', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-failure-'))
  try {
    fs.writeFileSync(path.join(temporary, 'valid.less'), '@n: 1; .valid { z-index: @n; }')
    fs.writeFileSync(path.join(temporary, 'broken.scss'), '$n: ; .broken { z-index: $n; }')
    const result = await invoke(temporary, [
      'valid.less',
      'broken.scss',
      '-o',
      'dist',
      '--output-dir',
      '--minify',
    ])
    assert.equal(result.status, 1)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /broken\.scss:1:5: error sass\.compile: Expected expression\./)
    assert.equal(fs.existsSync(path.join(temporary, 'dist')), false)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI rejects usage and output collisions before compilation', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-usage-'))
  try {
    fs.writeFileSync(path.join(temporary, 'input.scss'), '.a{}')
    for (const argv of [
      ['input.scss', '-o', 'input.scss'],
      ['input.scss', '--unknown'],
      ['input.scss', '--source-map', '--optimize'],
      ['-', 'input.scss', '-o', 'dist', '--output-dir'],
      ['x'.repeat(4097)],
      [...Array.from({ length: 4097 }, (_, index) => `input-${index}.scss`), '-o', 'dist', '--output-dir'],
    ]) {
      const result = await invoke(temporary, argv, '.stdin{}')
      assert.equal(result.status, 2, argv.join(' '))
      assert.equal(result.stdout, '')
      assert.match(result.stderr, /^Error: /)
    }
    assert.equal(fs.readFileSync(path.join(temporary, 'input.scss'), 'utf8'), '.a{}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI watch recompiles once when an imported dependency changes', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-watch-'))
  try {
    fs.writeFileSync(path.join(temporary, 'input.scss'), (
      '@use "tokens"; .card { color: tokens.$color; }'
    ))
    fs.writeFileSync(path.join(temporary, '_tokens.scss'), '$color: red;')

    const result = await invokeWithOptions(temporary, [
      'input.scss',
      '-o',
      'output.css',
      '--watch',
      '--minify',
    ], {
      watchPollLimit: 1,
      waitForWatchPoll: async poll => {
        assert.equal(poll, 1)
        fs.writeFileSync(path.join(temporary, '_tokens.scss'), '$color: blue;')
      },
    })

    assert.equal(result.status, 0)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, [
      'Watching input.scss for changes... (Press Ctrl+C to stop)\n',
      'Compiled: input.scss -> output.css\n',
      'Source or dependency changed, recompiling...\n',
      'Compiled: input.scss -> output.css\n',
    ].join(''))
    assert.equal(fs.readFileSync(path.join(temporary, 'output.css'), 'utf8'), '.card{color:blue}')
    assert.deepEqual(fs.readdirSync(temporary).sort(), ['_tokens.scss', 'input.scss', 'output.css'])
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI watch compiles its one owned root snapshot without a duplicate read', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-watch-snapshot-'))
  const entry = path.join(temporary, 'input.scss')
  let entryLoads = 0
  try {
    fs.writeFileSync(entry, '$color: red; .card { color: $color; }')
    const result = await invokeWithOptions(temporary, [
      'input.scss',
      '-o',
      'output.css',
      '--watch',
      '--minify',
    ], {
      watchPollLimit: 0,
      async loadFileForWatch(filename, options) {
        entryLoads += 1
        const loaded = await loadFileForCompilation(filename, options)
        fs.unlinkSync(entry)
        return loaded
      },
    })

    assert.equal(result.status, 0)
    assert.equal(entryLoads, 1)
    assert.equal(fs.existsSync(entry), false)
    assert.equal(fs.readFileSync(path.join(temporary, 'output.css'), 'utf8'), '.card{color:red}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI watch invalidates dependencies for every admitted preprocessor syntax', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-watch-matrix-'))
  try {
    const cases = [
      {
        entry: 'input.scss',
        dependency: '_tokens.scss',
        source: '@use "tokens"; .card { color: tokens.$color; }',
        before: '$color: red;',
        after: '$color: blue;',
        expected: '.card{color:blue}',
      },
      {
        entry: 'input.sass',
        dependency: '_tokens.sass',
        source: '@use "tokens"\n.card\n  color: tokens.$color\n',
        before: '$color: red\n',
        after: '$color: blue\n',
        expected: '.card{color:blue}',
      },
      {
        entry: 'input.less',
        dependency: 'tokens.less',
        source: '@import "tokens"; .card { color: @color; }',
        before: '@color: red;',
        after: '@color: blue;',
        expected: '.card{color:blue}',
      },
      {
        entry: 'input.styl',
        dependency: 'tokens.styl',
        source: '@import "tokens"\n.card\n  color color\n',
        before: 'color = red\n',
        after: 'color = blue\n',
        expected: '.card{color:#00f}',
      },
    ]

    for (const [index, fixture] of cases.entries()) {
      const directory = path.join(temporary, String(index))
      fs.mkdirSync(directory)
      fs.writeFileSync(path.join(directory, fixture.entry), fixture.source)
      fs.writeFileSync(path.join(directory, fixture.dependency), fixture.before)
      const result = await invokeWithOptions(directory, [
        fixture.entry,
        '-o',
        'output.css',
        '--watch',
        '--minify',
      ], {
        watchPollLimit: 1,
        waitForWatchPoll: async () => {
          fs.writeFileSync(path.join(directory, fixture.dependency), fixture.after)
        },
      })
      assert.equal(result.status, 0, fixture.entry)
      assert.equal(result.stderr.match(/Compiled:/g)?.length, 2, fixture.entry)
      assert.equal(fs.readFileSync(path.join(directory, 'output.css'), 'utf8'), fixture.expected)
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI watch reports one dependency error, retains output, and recovers', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-watch-error-'))
  try {
    const dependency = path.join(temporary, '_tokens.scss')
    const output = path.join(temporary, 'output.css')
    fs.writeFileSync(path.join(temporary, 'input.scss'), (
      '@use "tokens"; .card { color: tokens.$color; }'
    ))
    fs.writeFileSync(dependency, '$color: red;')

    const result = await invokeWithOptions(temporary, [
      'input.scss',
      '-o',
      'output.css',
      '--watch',
      '--minify',
    ], {
      watchPollLimit: 3,
      waitForWatchPoll: async poll => {
        if (poll === 1) fs.unlinkSync(dependency)
        if (poll === 2) {
          assert.equal(fs.readFileSync(output, 'utf8'), '.card{color:red}')
        }
        if (poll === 3) fs.writeFileSync(dependency, '$color: blue;')
      },
    })

    assert.equal(result.status, 0)
    assert.equal(result.stdout, '')
    assert.equal(
      result.stderr.match(/sass\.compile: Can't find stylesheet to import\./g)?.length,
      1,
    )
    assert.equal(
      result.stderr.match(/Source or dependency changed, recompiling\.\.\./g)?.length,
      2,
    )
    assert.equal(
      result.stderr.match(/Compiled: input\.scss -> output\.css/g)?.length,
      2,
    )
    assert.equal(fs.readFileSync(output, 'utf8'), '.card{color:blue}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('npm CLI watch cancellation stops its polling loop without another compile', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-product-cli-watch-abort-'))
  try {
    fs.writeFileSync(path.join(temporary, 'input.less'), '@color: red; .card { color: @color; }')
    const controller = new AbortController()
    let waits = 0
    const result = await invokeWithOptions(temporary, [
      'input.less',
      '-o',
      'output.css',
      '--watch',
      '--minify',
    ], {
      signal: controller.signal,
      watchPollLimit: Number.POSITIVE_INFINITY,
      waitForWatchPoll: async () => {
        waits += 1
        controller.abort()
      },
    })

    assert.equal(result.status, 0)
    assert.equal(waits, 1)
    assert.equal(result.stderr.match(/Compiled:/g)?.length, 1)
    assert.equal(fs.readFileSync(path.join(temporary, 'output.css'), 'utf8'), '.card{color:red}')
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('development provider watch launcher preserves terminal signal ownership', {
  skip: process.platform === 'win32',
}, async () => {
  const fixture = fs.mkdtempSync(path.join(repositoryRoot, '.zigcss-product-watch-signal-'))
  let child = null
  try {
    const launcher = writeDevelopmentProductLauncher(fixture)
    fs.mkdirSync(path.join(fixture, 'bin'))
    const fixtureBinary = path.join(fixture, 'bin', 'zigcss')
    fs.copyFileSync(binaryPath, fixtureBinary)
    fs.chmodSync(fixtureBinary, 0o755)
    fs.writeFileSync(path.join(fixture, 'input.scss'), '$color: red; .card { color: $color; }')

    child = spawn(process.execPath, [
      launcher,
      'input.scss',
      '-o',
      'output.css',
      '--watch',
      '--minify',
    ], {
      cwd: fixture,
      stdio: ['ignore', 'ignore', 'pipe'],
    })
    let stderr = ''
    const compiled = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`watch did not compile:\n${stderr}`)), 10_000)
      child.stderr.on('data', chunk => {
        stderr += chunk.toString('utf8')
        if (stderr.includes('Compiled: input.scss -> output.css')) {
          clearTimeout(timeout)
          resolve()
        }
      })
      child.once('error', error => {
        clearTimeout(timeout)
        reject(error)
      })
    })
    await compiled
    const terminalPromise = new Promise(resolve => {
      child.once('exit', (code, signal) => resolve({ code, signal }))
    })
    assert.equal(child.kill('SIGTERM'), true)
    const terminal = await terminalPromise
    child = null
    assert.deepEqual(terminal, { code: null, signal: 'SIGTERM' })
    assert.equal(fs.readFileSync(path.join(fixture, 'output.css'), 'utf8'), '.card{color:red}')

    child = spawn(process.execPath, [
      launcher,
      '-',
      '--syntax',
      'scss',
      '--minify',
    ], {
      cwd: fixture,
      stdio: ['pipe', 'ignore', 'pipe'],
    })
    const stdinTerminalPromise = new Promise(resolve => {
      child.once('exit', (code, signal) => resolve({ code, signal }))
    })
    child.stdin.write('$color: blue;')
    await new Promise(resolve => setTimeout(resolve, 250))
    assert.equal(child.exitCode, null)
    assert.equal(child.kill('SIGTERM'), true)
    const stdinTerminal = await stdinTerminalPromise
    child = null
    assert.deepEqual(stdinTerminal, { code: null, signal: 'SIGTERM' })
  } finally {
    if (child !== null) child.kill('SIGKILL')
    fs.rmSync(fixture, { recursive: true, force: true })
  }
})
