import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const examplesRoot = path.join(repositoryRoot, 'examples', 'build-systems')

function readExample(name) {
  return fs.readFileSync(path.join(examplesRoot, name), 'utf8')
}

function occurrences(value, needle) {
  return value.split(needle).length - 1
}

test('build-system examples expose four bounded depfile integrations', () => {
  const makefile = readExample('Makefile')
  const ninja = readExample('build.ninja')
  const cmake = readExample('CMakeLists.txt')
  const meson = readExample('meson.build')
  const mesonOptions = readExample('meson_options.txt')
  const guide = readExample('README.md')
  const publicReadme = fs.readFileSync(path.join(repositoryRoot, 'README.md'), 'utf8')
  const changelog = fs.readFileSync(path.join(repositoryRoot, 'CHANGELOG.md'), 'utf8')
  const input = readExample('styles.scss')

  assert.match(input, /^@use "tokens";/m)
  assert.equal(readExample('_tokens.scss').trim(), '$accent: rebeccapurple;')
  for (const definition of [makefile, ninja, cmake, meson]) {
    assert.equal(occurrences(definition, '--depfile'), 1)
    assert.match(definition, /--syntax(?: scss|', 'scss')/)
    assert.match(definition, /--minify/)
    assert.doesNotMatch(definition, /_tokens\.scss/)
  }

  assert.match(makefile, /^ZIGCSS \?= zigcss$/m)
  assert.match(makefile, /^\$\(OUTPUT\): \$\(INPUT\)$/m)
  assert.match(makefile, /"\$\(ZIGCSS\)" .* -o "\$@" --depfile "\$\(DEPFILE\)"/)
  assert.match(makefile, /^-include \$\(DEPFILE\)$/m)

  assert.match(ninja, /^zigcss = zigcss$/m)
  assert.match(ninja, /^  command = "\$zigcss" .* -o "\$out" --depfile "\$out\.d"$/m)
  assert.match(ninja, /^  depfile = \$out\.d$/m)
  assert.match(ninja, /^  deps = gcc$/m)
  assert.match(ninja, /^build styles\.css: compile_zigcss styles\.scss$/m)

  assert.match(cmake, /set\(ZIGCSS "zigcss" CACHE FILEPATH/)
  assert.match(cmake, /COMMAND "\$\{ZIGCSS\}" "\$\{INPUT\}"/)
  assert.match(cmake, /-o "\$\{OUTPUT\}" --depfile "\$\{DEPFILE\}"/)
  assert.match(cmake, /^  DEPFILE "\$\{DEPFILE\}"$/m)
  assert.match(cmake, /^  DEPENDS "\$\{INPUT\}"$/m)

  assert.match(mesonOptions, /option\(\s*'zigcss',/)
  assert.match(meson, /zigcss = find_program\(get_option\('zigcss'\)\)/)
  assert.match(meson, /'-o', '@OUTPUT@'/)
  assert.match(meson, /'--depfile', '@DEPFILE@'/)
  assert.match(meson, /depfile: 'styles\.css\.d'/)
  assert.match(meson, /input: 'styles\.scss'/)

  for (const host of ['GNU Make', 'Ninja', 'CMake 3.20+', 'Meson 0.47+']) {
    assert.match(guide, new RegExp(host.replace(/[+.]/g, '\\$&')))
  }
  assert.match(guide, /unchanged second build is a no-op/)
  assert.match(guide, /reports unavailable builders as explicit skips/)
  assert.match(guide, /same scenario also runs through that exact compiler for GNU Make, Ninja, CMake, and Meson/)
  assert.match(guide, /current `Unreleased` checkout only/)
  assert.match(guide, /Published stable ZigCSS 0\.6\.0 has no `--depfile` option/)
  assert.match(guide, /Build the current source with Zig 0\.15\.2/)
  for (const publicSurface of [publicReadme, changelog]) {
    assert.match(publicSurface, /mandatory real-ZigCSS incremental rebuilds for GNU Make, Ninja, CMake, and Meson/)
  }
})

function fakeCompilerMain() {
  'use strict'
  const fs = require('node:fs')
  const path = require('node:path')

  function fail(message) {
    process.stderr.write(`${message}\n`)
    process.exit(2)
  }

  let input = null
  let output = null
  let depfile = null
  let syntax = null
  let minify = false
  const args = process.argv.slice(2)
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index]
    if (argument === '--syntax') {
      syntax = args[++index]
    } else if (argument === '--minify') {
      minify = true
    } else if (argument === '-o' || argument === '--output') {
      output = args[++index]
    } else if (argument === '--depfile') {
      depfile = args[++index]
    } else if (argument?.startsWith('-')) {
      fail(`unexpected option: ${argument}`)
    } else if (input === null) {
      input = argument
    } else {
      fail(`unexpected input: ${argument}`)
    }
  }
  if (!input || !output || !depfile || syntax !== 'scss' || !minify) {
    fail('fixture requires one SCSS input, --minify, -o, and --depfile')
  }

  const source = fs.readFileSync(input, 'utf8')
  if (!source.includes('@use "tokens";')) fail('fixture input lost its native dependency')
  const dependencyPath = path.join(path.dirname(path.resolve(input)), '_tokens.scss')
  const dependency = fs.readFileSync(dependencyPath, 'utf8')
  const match = dependency.match(/\$accent:\s*([^;]+);/)
  if (!match) fail('fixture dependency is invalid')

  function escapeDepfilePath(value) {
    let escaped = ''
    for (const character of value) {
      if (character === '$') escaped += '$$'
      else if (character === ' ' || character === '#' || character === ':' || character === '\\') {
        escaped += `\\${character}`
      } else escaped += character
    }
    return escaped
  }

  fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true })
  fs.mkdirSync(path.dirname(path.resolve(depfile)), { recursive: true })
  fs.writeFileSync(output, `.card{color:${match[1].trim()}}\n`)
  const prerequisites = [fs.realpathSync(input), fs.realpathSync(dependencyPath)]
  fs.writeFileSync(
    depfile,
    `${escapeDepfilePath(output)}: ${prerequisites.map(escapeDepfilePath).join(' ')}\n`,
  )
  const log = process.env.ZIGCSS_FIXTURE_LOG
  if (!log) fail('ZIGCSS_FIXTURE_LOG is required')
  fs.appendFileSync(log, `${JSON.stringify({ input, output, depfile })}\n`)
}

function probe(command, args, accepts = () => true) {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  return !result.error && result.status === 0 && accepts(`${result.stdout}${result.stderr}`)
}

function firstAvailable(candidates) {
  for (const candidate of candidates) {
    if (candidate && probe(candidate, ['--version'], output => /GNU Make/i.test(output))) {
      return candidate
    }
  }
  return null
}

function versionAtLeast(value, minimum) {
  const actual = value.split('.').map(part => Number.parseInt(part, 10))
  for (let index = 0; index < minimum.length; index += 1) {
    const difference = (actual[index] || 0) - minimum[index]
    if (difference !== 0) return difference > 0
  }
  return true
}

function versionedTool(command, args, pattern, minimum) {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  if (result.error || result.status !== 0) return null
  const match = `${result.stdout}${result.stderr}`.match(pattern)
  return match && versionAtLeast(match[1], minimum) ? command : null
}

const makeTool = firstAvailable([process.env.MAKE, 'gmake', 'make'])
const ninjaTool = versionedTool('ninja', ['--version'], /(\d+(?:\.\d+)+)/, [1, 3])
const cmakeTool = versionedTool('cmake', ['--version'], /cmake version (\d+(?:\.\d+)+)/i, [3, 20])
const mesonTool = versionedTool('meson', ['--version'], /(\d+(?:\.\d+)+)/, [0, 47])

function requireBuildSystemToolchain(tools, required) {
  if (!required) return false
  for (const [name, executable] of Object.entries(tools)) {
    if (executable === null) {
      throw new Error(`required build-system tool is unavailable or below its minimum version: ${name}`)
    }
  }
  return true
}

test('CI-required build-system availability fails closed', () => {
  const requirement = process.env.ZIGCSS_REQUIRE_BUILD_SYSTEMS
  assert.ok(requirement === undefined || requirement === '1', 'ZIGCSS_REQUIRE_BUILD_SYSTEMS accepts only the exact value 1')
  assert.throws(
    () => requireBuildSystemToolchain({ make: null, ninja: 'ninja', cmake: 'cmake', meson: 'meson' }, true),
    /required build-system tool.*make/,
  )
  assert.equal(requireBuildSystemToolchain(
    { make: makeTool, ninja: ninjaTool, cmake: cmakeTool, meson: mesonTool },
    requirement === '1',
  ), requirement === '1')
})

function createFixture(name, realCompiler = null) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `zigcss-${name}-`)))
  const workspace = path.join(root, 'workspace with spaces')
  const bin = path.join(root, 'fixture bin')
  const log = path.join(root, 'invocations.jsonl')
  fs.cpSync(examplesRoot, workspace, { recursive: true })
  fs.mkdirSync(bin)

  let compiler
  if (process.platform === 'win32') {
    if (realCompiler === null) {
      const implementation = path.join(bin, 'zigcss-fixture.cjs')
      compiler = path.join(bin, 'zigcss.cmd')
      fs.writeFileSync(implementation, `#!/usr/bin/env node\n(${fakeCompilerMain.toString()})()\n`)
      fs.writeFileSync(
        compiler,
        `@echo off\r\n"${process.execPath}" "%~dp0zigcss-fixture.cjs" %*\r\n`,
      )
    } else {
      compiler = path.join(bin, 'zigcss.exe')
      fs.copyFileSync(realCompiler, compiler)
    }
  } else {
    compiler = path.join(bin, 'zigcss')
    if (realCompiler === null) {
      fs.writeFileSync(compiler, `#!/usr/bin/env node\n(${fakeCompilerMain.toString()})()\n`, { mode: 0o755 })
    } else {
      fs.copyFileSync(realCompiler, compiler)
    }
    fs.chmodSync(compiler, 0o755)
  }

  const env = { ...process.env, ZIGCSS: compiler, ZIGCSS_FIXTURE_LOG: log }
  const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') || 'PATH'
  env[pathKey] = `${bin}${path.delimiter}${env[pathKey] || ''}`
  delete env.MAKEFLAGS
  delete env.MFLAGS
  return { root, workspace, compiler, log, env }
}

function runChecked(command, args, cwd, env) {
  const result = spawnSync(command, args, { cwd, env, encoding: 'utf8' })
  assert.equal(
    result.status,
    0,
    [
      `command failed: ${command} ${args.join(' ')}`,
      result.error?.stack || '',
      result.stdout,
      result.stderr,
    ].filter(Boolean).join('\n'),
  )
}

function invocationCount(log) {
  if (!fs.existsSync(log)) return 0
  return fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).length
}

function prepareMake(fixture) {
  return {
    output: path.join(fixture.workspace, 'styles.css'),
    run() {
      runChecked(makeTool, [], fixture.workspace, fixture.env)
    },
  }
}

function prepareNinja(fixture) {
  return {
    output: path.join(fixture.workspace, 'styles.css'),
    run() {
      runChecked(ninjaTool, ['-f', 'build.ninja'], fixture.workspace, fixture.env)
    },
  }
}

function prepareCmake(fixture) {
  const buildDirectory = path.join(fixture.root, 'cmake build')
  runChecked(cmakeTool, [
    '-S', fixture.workspace,
    '-B', buildDirectory,
    '-G', cmakeGenerator[0],
    `-DZIGCSS:FILEPATH=${fixture.compiler}`,
  ], fixture.root, fixture.env)
  return {
    output: path.join(buildDirectory, 'styles.css'),
    run() {
      runChecked(cmakeTool, ['--build', buildDirectory], fixture.root, fixture.env)
    },
  }
}

function prepareMeson(fixture) {
  const buildDirectory = path.join(fixture.root, 'meson build')
  runChecked(mesonTool, [
    'setup', buildDirectory, fixture.workspace,
    '--backend', 'ninja',
    `-Dzigcss=${fixture.compiler}`,
  ], fixture.root, fixture.env)
  return {
    output: path.join(buildDirectory, 'styles.css'),
    run() {
      runChecked(mesonTool, ['compile', '-C', buildDirectory], fixture.root, fixture.env)
    },
  }
}

function exerciseIncrementalBuild(name, prepare) {
  const fixture = createFixture(name)
  try {
    const build = prepare(fixture)
    build.run()
    assert.equal(invocationCount(fixture.log), 1)
    assert.equal(fs.readFileSync(build.output, 'utf8'), '.card{color:rebeccapurple}\n')

    build.run()
    assert.equal(invocationCount(fixture.log), 1, 'an unchanged build must be a no-op')

    const dependency = path.join(fixture.workspace, '_tokens.scss')
    fs.writeFileSync(dependency, '$accent: hotpink;\n')
    const outputMtime = fs.statSync(build.output).mtimeMs
    const changedMtime = Math.max(Date.now(), outputMtime) + 5_000
    fs.utimesSync(dependency, changedMtime / 1_000, changedMtime / 1_000)

    build.run()
    assert.equal(invocationCount(fixture.log), 2, 'a native dependency change must rebuild')
    assert.equal(fs.readFileSync(build.output, 'utf8'), '.card{color:hotpink}\n')
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
}

function exerciseRealIncrementalBuild(name, prepare) {
  const fixture = createFixture(`real-${name}`, configuredRealCompiler)
  try {
    const build = prepare(fixture)
    build.run()
    const firstCss = fs.readFileSync(build.output)
    assert.match(firstCss.toString(), /\.card\{color:/)
    const firstMtime = fs.statSync(build.output, { bigint: true }).mtimeNs

    build.run()
    assert.deepEqual(fs.readFileSync(build.output), firstCss, 'an unchanged real build must preserve CSS bytes')
    assert.equal(
      fs.statSync(build.output, { bigint: true }).mtimeNs,
      firstMtime,
      'an unchanged real build must not rewrite the output',
    )

    const dependency = path.join(fixture.workspace, '_tokens.scss')
    fs.writeFileSync(dependency, '$accent: hotpink;\n')
    const changedMtime = Math.max(Date.now(), Number(firstMtime / 1_000_000n)) + 5_000
    fs.utimesSync(dependency, changedMtime / 1_000, changedMtime / 1_000)
    build.run()
    assert.notDeepEqual(fs.readFileSync(build.output), firstCss, 'a real native dependency rebuild must change CSS bytes')
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
}

test('GNU Make consumes the emitted native dependency graph', {
  skip: makeTool ? false : 'GNU Make is not installed',
}, () => exerciseIncrementalBuild('make', prepareMake))

const configuredRealCompiler = process.env.ZIGCSS_REAL_BINARY || null

test('real ZigCSS depfile drives GNU Make incremental rebuild', {
  skip: configuredRealCompiler ? false : 'ZIGCSS_REAL_BINARY is not configured',
}, () => {
  assert.notEqual(makeTool, null, 'GNU Make is required when ZIGCSS_REAL_BINARY is configured')
  assert.equal(path.isAbsolute(configuredRealCompiler), true, 'ZIGCSS_REAL_BINARY must be absolute')
  const compilerStat = fs.lstatSync(configuredRealCompiler)
  assert.equal(compilerStat.isFile(), true, 'ZIGCSS_REAL_BINARY must be a regular file')
  assert.equal(compilerStat.isSymbolicLink(), false, 'ZIGCSS_REAL_BINARY cannot be a symlink')
  if (process.platform !== 'win32') {
    assert.notEqual(compilerStat.mode & 0o111, 0, 'ZIGCSS_REAL_BINARY must be executable')
  }

  const fixture = createFixture('real-make')
  try {
    const environment = { ...fixture.env, ZIGCSS: configuredRealCompiler }
    const output = path.join(fixture.workspace, 'styles.css')
    const depfile = `${output}.d`
    runChecked(makeTool, [], fixture.workspace, environment)
    const firstCss = fs.readFileSync(output)
    const dependencyRule = fs.readFileSync(depfile, 'utf8')
    assert.match(dependencyRule, /styles\.scss/)
    assert.match(dependencyRule, /_tokens\.scss/)

    let query = spawnSync(makeTool, ['-q'], { cwd: fixture.workspace, env: environment, encoding: 'utf8' })
    assert.equal(query.status, 0, `unchanged real build is dirty: ${query.stderr || query.stdout}`)

    const dependency = path.join(fixture.workspace, '_tokens.scss')
    fs.writeFileSync(dependency, '$accent: hotpink;\n')
    const changedMtime = Date.now()
    const staleOutputMtime = changedMtime - 5_000
    fs.utimesSync(output, staleOutputMtime / 1_000, staleOutputMtime / 1_000)
    fs.utimesSync(dependency, changedMtime / 1_000, changedMtime / 1_000)
    query = spawnSync(makeTool, ['-q'], { cwd: fixture.workspace, env: environment, encoding: 'utf8' })
    assert.equal(query.status, 1, `native dependency change did not dirty the real build: ${query.stderr || query.stdout}`)

    runChecked(makeTool, [], fixture.workspace, environment)
    const secondCss = fs.readFileSync(output)
    assert.notDeepEqual(secondCss, firstCss, 'real native dependency rebuild must change CSS bytes')
    query = spawnSync(makeTool, ['-q'], { cwd: fixture.workspace, env: environment, encoding: 'utf8' })
    assert.equal(query.status, 0, `rebuilt real output remains dirty: ${query.stderr || query.stdout}`)
  } finally {
    fs.rmSync(fixture.root, { recursive: true, force: true })
  }
})

test('Ninja consumes the emitted native dependency graph', {
  skip: ninjaTool ? false : 'Ninja 1.3 or newer is not installed',
}, () => exerciseIncrementalBuild('ninja', prepareNinja))

const cmakeGenerator = ninjaTool
  ? ['Ninja']
  : makeTool
    ? ['Unix Makefiles']
    : null

test('CMake consumes the emitted native dependency graph', {
  skip: cmakeTool && cmakeGenerator ? false : 'CMake 3.20 and a supported backend are not installed',
}, () => exerciseIncrementalBuild('cmake', prepareCmake))

test('Meson consumes the emitted native dependency graph', {
  skip: mesonTool && ninjaTool ? false : 'Meson 0.47 and Ninja are not installed',
}, () => exerciseIncrementalBuild('meson', prepareMeson))

for (const [name, available, prepare] of [
  ['Ninja', Boolean(configuredRealCompiler && ninjaTool), prepareNinja],
  ['CMake', Boolean(configuredRealCompiler && cmakeTool && cmakeGenerator), prepareCmake],
  ['Meson', Boolean(configuredRealCompiler && mesonTool && ninjaTool), prepareMeson],
]) {
  test(`real ZigCSS depfile drives ${name} incremental rebuild`, {
    skip: available ? false : `ZIGCSS_REAL_BINARY and the ${name} toolchain are required`,
  }, () => exerciseRealIncrementalBuild(name.toLowerCase(), prepare))
}
