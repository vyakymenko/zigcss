#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const maximumFormulaBytes = 32 * 1024
const maximumArchiveBytes = 64 * 1024 * 1024
const maximumArchiveEntries = 10_000
const commandTimeoutMs = 10 * 60 * 1000

function fail(message) {
  throw new Error(`Homebrew release verification: ${message}`)
}

function singleCapture(source, expression, label) {
  const matches = [...source.matchAll(expression)]
  if (matches.length !== 1) fail(`${label} must occur exactly once, received ${matches.length}`)
  return matches[0][1]
}

function literalCount(source, literal, expected, label) {
  const actual = source.split(literal).length - 1
  if (actual !== expected) fail(`${label} must occur ${expected} times, received ${actual}`)
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: 'utf8',
    env: { ...process.env, ...options.env },
    maxBuffer: 4 * 1024 * 1024,
    timeout: options.timeout ?? commandTimeoutMs,
  })
  if (result.error !== undefined) fail(`${command} failed: ${result.error.message}`)
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout).trim()
    fail(`${command} exited ${result.status}${detail.length === 0 ? '' : `: ${detail}`}`)
  }
  return result.stdout
}

function regularFile(filename, label, maximumBytes) {
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size <= 0 || stat.size > maximumBytes) fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  return stat
}

function sha256(filename) {
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(filename, 'r')
  const buffer = Buffer.allocUnsafe(64 * 1024)
  try {
    while (true) {
      const length = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (length === 0) break
      hash.update(buffer.subarray(0, length))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return hash.digest('hex')
}

export function parseHomebrewFormula(source) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > maximumFormulaBytes) {
    fail('formula is missing or oversized')
  }
  const url = singleCapture(source, /^  url "([^"]+)"$/gm, 'source URL')
  const parsedUrl = new URL(url)
  if (
    parsedUrl.protocol !== 'https:' ||
    parsedUrl.hostname !== 'github.com' ||
    parsedUrl.port !== '' ||
    parsedUrl.username !== '' ||
    parsedUrl.password !== '' ||
    parsedUrl.search !== '' ||
    parsedUrl.hash !== ''
  ) {
    fail('source URL must be credential-free HTTPS on github.com')
  }
  const match = parsedUrl.pathname.match(/^\/vyakymenko\/zigcss\/archive\/([0-9a-f]{40})\.tar\.gz$/)
  if (match === null) fail('source URL must pin one full lowercase commit identity')

  const version = singleCapture(source, /^  version "([^"]+)"$/gm, 'formula version')
  parseReleaseVersion(version, 'Homebrew formula version')
  const digest = singleCapture(source, /^  sha256 "([0-9a-f]{64})"$/gm, 'source SHA-256')
  literalCount(source, '  depends_on "zig@0.15" => :build', 1, 'Zig 0.15 build dependency')
  literalCount(
    source,
    '    system Formula["zig@0.15"].opt_bin/"zig", "build", "-Doptimize=ReleaseFast"',
    1,
    'toolchain-pinned build command',
  )
  literalCount(source, '    bin.install "zig-out/bin/zigcss"', 1, 'binary installation')
  literalCount(
    source,
    '    assert_equal "zigcss #{version}\\n", shell_output("#{bin}/zigcss --version")',
    1,
    'version smoke assertion',
  )
  literalCount(
    source,
    '    assert_equal ".test{color:red}", shell_output("#{bin}/zigcss test.css --minify")',
    1,
    'compile smoke assertion',
  )
  if (/^\s*head\s/m.test(source)) fail('formula must not expose an unverified head build')
  if (/\b(?:curl|wget)\b|https?:\/\/.+https?:\/\//.test(source)) fail('formula install must not perform a second download')
  return Object.freeze({ digest, sourceCommit: match[1], url, version })
}

function readFormula(root = repositoryRoot) {
  const canonicalRoot = fs.realpathSync(root)
  const filename = path.join(canonicalRoot, 'Formula', 'zigcss.rb')
  regularFile(filename, 'Homebrew formula', maximumFormulaBytes)
  const canonical = fs.realpathSync(filename)
  const relative = path.relative(canonicalRoot, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail('Homebrew formula escapes the repository')
  }
  return fs.readFileSync(canonical, 'utf8')
}

function inspectArchive(archive, policy) {
  regularFile(archive, 'downloaded source archive', maximumArchiveBytes)
  const expectedRoot = `zigcss-${policy.sourceCommit}`
  const entries = run('tar', ['-tzf', archive]).trimEnd().split('\n')
  if (entries.length === 0 || entries.length > maximumArchiveEntries) {
    fail(`source archive must contain 1 through ${maximumArchiveEntries} entries`)
  }
  if (entries[0] !== `${expectedRoot}/` || new Set(entries).size !== entries.length) {
    fail('source archive must have one canonical root and no duplicate entries')
  }
  for (const entry of entries) {
    if (entry.includes('\0') || !entry.startsWith(`${expectedRoot}/`)) fail('source archive entry escapes its canonical root')
    const relative = entry.slice(expectedRoot.length + 1)
    if (relative.startsWith('/') || relative.split('/').includes('..')) fail('source archive entry escapes its canonical root')
  }
  for (const required of ['VERSION', 'build.zig', 'build.zig.zon', 'src/main.zig']) {
    if (!entries.includes(`${expectedRoot}/${required}`)) fail(`source archive is missing ${required}`)
  }
  const verbose = run('tar', ['-tvzf', archive]).trimEnd().split('\n')
  if (verbose.length !== entries.length || verbose.some(line => !['-', 'd'].includes(line[0]))) {
    fail('source archive must contain only regular files and directories')
  }
  return expectedRoot
}

function zigBuildEnvironment(workspace) {
  if (process.platform !== 'darwin') return {}
  const sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
  if (!fs.existsSync(sdk)) return {}
  const wrapperDirectory = path.join(workspace, 'sdk-wrapper')
  fs.mkdirSync(wrapperDirectory)
  const wrapper = path.join(wrapperDirectory, 'xcrun')
  fs.writeFileSync(wrapper, [
    '#!/bin/sh',
    'if [ "$#" -eq 3 ] && [ "$1" = "--sdk" ] && [ "$2" = "macosx" ] && [ "$3" = "--show-sdk-path" ]; then',
    `  echo ${sdk}`,
    '  exit 0',
    'fi',
    'exec /usr/bin/xcrun "$@"',
    '',
  ].join('\n'), { mode: 0o755 })
  return {
    MACOSX_DEPLOYMENT_TARGET: '15.4',
    PATH: `${wrapperDirectory}${path.delimiter}${process.env.PATH ?? ''}`,
  }
}

export function checkHomebrewFormula(root = repositoryRoot) {
  const policy = parseHomebrewFormula(readFormula(root))
  const canonicalVersion = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim()
  if (policy.version !== canonicalVersion) fail('formula version does not match VERSION')
  run('git', ['cat-file', '-e', `${policy.sourceCommit}^{commit}`], { cwd: root })
  run('git', ['merge-base', '--is-ancestor', policy.sourceCommit, 'HEAD'], { cwd: root })
  return policy
}

export function smokeHomebrewFormula(root = repositoryRoot) {
  const policy = checkHomebrewFormula(root)
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-homebrew-release-'))
  try {
    const archive = path.join(temporary, 'source.tar.gz')
    run('curl', [
      '--fail',
      '--location',
      '--silent',
      '--show-error',
      '--proto', '=https',
      '--proto-redir', '=https',
      '--max-redirs', '5',
      '--connect-timeout', '10',
      '--max-time', '60',
      '--max-filesize', String(maximumArchiveBytes),
      '--output', archive,
      policy.url,
    ], { timeout: 70_000 })
    if (sha256(archive) !== policy.digest) fail('downloaded source archive SHA-256 does not match the formula')

    const expectedRoot = inspectArchive(archive, policy)
    const extraction = path.join(temporary, 'source')
    fs.mkdirSync(extraction)
    run('tar', ['-xzf', archive, '-C', extraction])
    const sourceRoot = path.join(extraction, expectedRoot)
    const sourceStat = fs.lstatSync(sourceRoot)
    if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) fail('extracted source root is not a regular directory')
    if (fs.readFileSync(path.join(sourceRoot, 'VERSION'), 'utf8') !== `${policy.version}\n`) {
      fail('downloaded source version does not match the formula')
    }

    const zig = process.env.ZIG ?? 'zig'
    if (run(zig, ['version']).trim() !== '0.15.2') fail('formula smoke requires the reviewed Zig 0.15.2 toolchain')
    const buildEnvironment = zigBuildEnvironment(temporary)
    run(zig, [
      'build',
      '-Doptimize=ReleaseFast',
      '--cache-dir', path.join(temporary, 'zig-cache'),
      '--global-cache-dir', path.join(temporary, 'zig-global-cache'),
      '--summary', 'all',
    ], { cwd: sourceRoot, env: buildEnvironment })

    const binary = path.join(sourceRoot, 'zig-out', 'bin', 'zigcss')
    regularFile(binary, 'formula-built binary', 256 * 1024 * 1024)
    const versionOutput = run(binary, ['--version'])
    if (versionOutput !== `zigcss ${policy.version}\n`) fail('formula-built binary reports the wrong version')

    const testDirectory = path.join(temporary, 'test')
    fs.mkdirSync(testDirectory)
    fs.writeFileSync(path.join(testDirectory, 'test.css'), '.test { color: red; }\n')
    const compiled = spawnSync(binary, ['test.css', '--minify'], {
      cwd: testDirectory,
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      timeout: 30_000,
    })
    if (compiled.error !== undefined || compiled.status !== 0) fail('formula-built compiler smoke failed')
    if (compiled.stdout !== '.test{color:red}') fail('formula-built compiler emitted unexpected CSS')
    if (!compiled.stderr.includes(`ZigCSS ${policy.version} is an experimental release candidate`)) {
      fail('formula-built compiler omitted its experimental warning')
    }
    return policy
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function main(args) {
  if (args.length !== 1 || !['--check', '--smoke'].includes(args[0])) fail('expected exactly --check or --smoke')
  const policy = args[0] === '--check' ? checkHomebrewFormula() : smokeHomebrewFormula()
  process.stdout.write(
    `Verified Homebrew formula ${policy.version} at ${policy.sourceCommit} (${policy.digest}).\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  try {
    main(process.argv.slice(2))
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
