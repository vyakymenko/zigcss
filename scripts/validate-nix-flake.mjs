import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { TextDecoder } from 'node:util'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

export const maximumNixFlakeBytes = 32 * 1024
export const maximumNixLockBytes = 8 * 1024
const maximumPathBytes = 4096
const utf8Decoder = new TextDecoder('utf-8', { fatal: true })

export const nixFlakePolicy = Object.freeze({
  inputUrl: 'github:NixOS/nixpkgs/5dfba6236110080a54247d6460bc2ff5dda939cc',
  lastModified: 1_788_187_754,
  narHash: 'sha256-bu1QxmXKmPuvBLN7bHP355OV9Qo13x9WCiRDH62CqRM=',
  revision: '5dfba6236110080a54247d6460bc2ff5dda939cc',
  systems: Object.freeze([
    'x86_64-linux',
    'aarch64-linux',
    'x86_64-darwin',
    'aarch64-darwin',
  ]),
  sourcePaths: Object.freeze([
    'build.zig',
    'build.zig.zon',
    'build_helpers.zig',
    'src',
    'VERSION',
    'README.md',
    'LICENSE',
  ]),
  zigVersion: '0.15.2',
})

const expectedFlakeSha256 = '208243ea0f37ab15a9b331ee709f774a3d8158d9b0d8a8e02619e5363d0e843f'
const lockRootKeys = Object.freeze(['nodes', 'root', 'version'])
const lockNodeKeys = Object.freeze(['nixpkgs', 'root'])
const lockedInputKeys = Object.freeze(['lastModified', 'narHash', 'owner', 'repo', 'rev', 'type'])
const originalInputKeys = Object.freeze(['owner', 'repo', 'rev', 'type'])

function fail(message) {
  throw new Error(`nix flake: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function exactObjectKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  if (!same(Object.keys(value), expected)) {
    fail(`${label} keys must be exactly ${expected.join(', ')}`)
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) {
    fail(`${label} must be ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`)
  }
}

function literalCount(source, literal, expected, label) {
  const actual = source.split(literal).length - 1
  if (actual !== expected) {
    fail(`${label} must occur ${expected} times, received ${actual}`)
  }
}

function singleCapture(source, expression, label) {
  const matches = [...source.matchAll(expression)]
  if (matches.length !== 1) fail(`${label} must occur exactly once, received ${matches.length}`)
  return matches[0][1]
}

function canonicalRoot(root) {
  if (typeof root !== 'string' || root.length === 0 || Buffer.byteLength(root) > maximumPathBytes) {
    fail('repository root must be a bounded nonempty path')
  }
  let stat
  try {
    stat = fs.lstatSync(root)
  } catch (error) {
    fail(`repository root is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('repository root must be a regular non-symlink directory')
  }
  return fs.realpathSync(root)
}

function openRegularFile(filename, label, maximumBytes) {
  let pathStat
  try {
    pathStat = fs.lstatSync(filename, { bigint: true })
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!pathStat.isFile() || pathStat.isSymbolicLink()) {
    fail(`${label} must be a regular non-symlink file`)
  }
  if (pathStat.size === 0n) fail(`${label} must not be empty`)
  if (pathStat.size > BigInt(maximumBytes)) fail(`${label} exceeds ${maximumBytes} bytes`)

  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  const closeOnExec = fs.constants.O_CLOEXEC ?? 0
  let descriptor
  try {
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | noFollow | closeOnExec)
  } catch (error) {
    fail(`${label} could not be opened safely: ${error.message}`)
  }

  try {
    const before = fs.fstatSync(descriptor, { bigint: true })
    const openedPathStat = fs.lstatSync(filename, { bigint: true })
    if (!before.isFile()
      || !openedPathStat.isFile()
      || openedPathStat.isSymbolicLink()
      || before.dev !== pathStat.dev
      || before.ino !== pathStat.ino
      || before.size !== pathStat.size
      || openedPathStat.dev !== before.dev
      || openedPathStat.ino !== before.ino
      || openedPathStat.size !== before.size) {
      fail(`${label} changed while it was being opened`)
    }
    return { descriptor, before }
  } catch (error) {
    fs.closeSync(descriptor)
    throw error
  }
}

function readRegularText(root, relativePath, label, maximumBytes) {
  const filename = path.join(root, relativePath)
  const { descriptor, before } = openRegularFile(filename, label, maximumBytes)
  try {
    const bytes = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor, { bigint: true })
    const finalPathStat = fs.lstatSync(filename, { bigint: true })
    if (!after.isFile()
      || !finalPathStat.isFile()
      || finalPathStat.isSymbolicLink()
      || after.dev !== before.dev
      || after.ino !== before.ino
      || after.size !== before.size
      || after.mtimeNs !== before.mtimeNs
      || after.ctimeNs !== before.ctimeNs
      || finalPathStat.dev !== after.dev
      || finalPathStat.ino !== after.ino
      || finalPathStat.size !== after.size
      || BigInt(bytes.length) !== before.size) {
      fail(`${label} changed while it was being read`)
    }
    try {
      return utf8Decoder.decode(bytes)
    } catch (error) {
      fail(`${label} is not valid UTF-8: ${error.message}`)
    }
  } finally {
    fs.closeSync(descriptor)
  }
}

function validateCanonicalText(source, label, maximumBytes) {
  if (typeof source !== 'string') fail(`${label} source must be text`)
  const bytes = Buffer.byteLength(source)
  if (bytes === 0 || bytes > maximumBytes) fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  if (!source.endsWith('\n') || source.includes('\r') || source.includes('\0')) {
    fail(`${label} must use canonical LF text with one final newline`)
  }
}

function parseJson(source, label) {
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function parseQuotedLines(block, label, prefix = '') {
  const values = []
  const residue = block.replace(/^\s*"([^"]+)"\s*$/gm, (_, value) => {
    values.push(`${prefix}${value}`)
    return ''
  })
  if (residue.trim() !== '') fail(`${label} must contain only quoted entries`)
  return values
}

function parseSourcePaths(block) {
  const values = []
  const residue = block.replace(/^\s*\.\/([A-Za-z0-9._/-]+)\s*$/gm, (_, value) => {
    values.push(value)
    return ''
  })
  if (residue.trim() !== '') fail('source allowlist must contain only repository-relative literal paths')
  return values
}

function validateLock(source) {
  const lock = parseJson(source, 'flake.lock')
  if (JSON.stringify(lock, null, 2) + '\n' !== source) {
    fail('flake.lock must use the canonical JSON representation')
  }
  exactObjectKeys(lock, lockRootKeys, 'flake.lock')
  expectEqual(lock.root, 'root', 'flake.lock root')
  expectEqual(lock.version, 7, 'flake.lock version')
  exactObjectKeys(lock.nodes, lockNodeKeys, 'flake.lock nodes')
  exactObjectKeys(lock.nodes.root, ['inputs'], 'root node')
  exactObjectKeys(lock.nodes.root.inputs, ['nixpkgs'], 'root inputs')
  expectEqual(lock.nodes.root.inputs.nixpkgs, 'nixpkgs', 'root nixpkgs input reference')

  const input = lock.nodes.nixpkgs
  exactObjectKeys(input, ['locked', 'original'], 'nixpkgs node')
  exactObjectKeys(input.locked, lockedInputKeys, 'locked nixpkgs input')
  exactObjectKeys(input.original, originalInputKeys, 'original nixpkgs input')

  for (const [label, value] of [
    ['locked owner', input.locked.owner],
    ['original owner', input.original.owner],
  ]) expectEqual(value, 'NixOS', label)
  for (const [label, value] of [
    ['locked repository', input.locked.repo],
    ['original repository', input.original.repo],
  ]) expectEqual(value, 'nixpkgs', label)
  for (const [label, value] of [
    ['locked input type', input.locked.type],
    ['original input type', input.original.type],
  ]) expectEqual(value, 'github', label)
  for (const [label, value] of [
    ['locked revision', input.locked.rev],
    ['original revision', input.original.rev],
  ]) expectEqual(value, nixFlakePolicy.revision, label)
  expectEqual(input.locked.lastModified, nixFlakePolicy.lastModified, 'locked lastModified')
  expectEqual(input.locked.narHash, nixFlakePolicy.narHash, 'locked narHash')
  return lock
}

function rejectForbiddenFlakeSource(source) {
  const forbidden = [
    [/\bflake-utils\b/i, 'flake-utils dependency'],
    [/\bbuiltins\.getEnv\b/, 'environment access'],
    [/\bbuiltins\.(?:currentSystem|currentTime)\b/, 'impure host builtin'],
    [/(?:^|[\s"'])--impure(?:[\s"']|$)/m, 'impure command mode'],
    [/\b(?:nixos-(?:unstable|[0-9]{2}\.[0-9]{2})|master|latest|HEAD)\b/, 'mutable input reference'],
    [/\?ref=/, 'mutable ref query'],
    [/\b(?:fetchurl|fetchFromGitHub|fetchgit|fetchTarball|fetchTree)\b/i, 'network fetcher'],
    [/\bbuiltins\.fetch(?:Git|Tarball|Tree|url)\b/i, 'builtin network fetcher'],
    [/\b(?:curl|wget|git\s+clone|ssh|scp|socat|nix-prefetch\S*)\b/i, 'network command'],
    [/(?:^|[="'([,\s])\/(?!\/)[A-Za-z0-9._~-]+(?:\/|$)|(?:^|[="'([,\s])[A-Za-z]:[\\/]|(?:^|[="'([,\s])\\\\/m, 'absolute host path'],
    [/\b(?:nixConfig|substituters|trusted-public-keys|registries)\b/, 'registry or binary-cache configuration'],
    [/\b(?:devShells|overlays|nixosModules|darwinModules|templates|hydraJobs)\b/, 'unreviewed flake output'],
  ]
  for (const [expression, label] of forbidden) {
    if (expression.test(source)) fail(`flake.nix contains forbidden ${label}`)
  }

  const urls = [...source.matchAll(/https?:\/\/[^"'\s]+/g)].map(match => match[0])
  if (!same(urls, ['https://github.com/vyakymenko/zigcss'])) {
    fail('flake.nix may contain only the package metadata HTTPS URL')
  }
}

function validateFlake(source, lock) {
  rejectForbiddenFlakeSource(source)

  const inputDeclarations = [
    ...source.matchAll(/^[ \t]*inputs(?:\.([A-Za-z0-9_-]+))?(?:\.[A-Za-z0-9_-]+)*[ \t]*=/gm),
  ]
  if (inputDeclarations.length !== 1 || inputDeclarations[0][1] !== 'nixpkgs') {
    fail('flake.nix must declare exactly one nixpkgs input')
  }
  const inputUrl = singleCapture(
    source,
    /^  inputs\.nixpkgs\.url = "([^"]+)";$/gm,
    'exact nixpkgs input URL',
  )
  expectEqual(inputUrl, nixFlakePolicy.inputUrl, 'nixpkgs input URL')
  expectEqual(lock.nodes.nixpkgs.original.rev, inputUrl.split('/').at(-1), 'flake and lock revision')

  const systemsBlock = singleCapture(
    source,
    /^      systems = \[\n([\s\S]*?)^      \];$/gm,
    'systems inventory',
  )
  const systems = parseQuotedLines(systemsBlock, 'systems inventory')
  if (!same(systems, nixFlakePolicy.systems)) fail('systems inventory drifted')
  literalCount(source, 'forAllSystems = nixpkgs.lib.genAttrs systems;', 1, 'explicit system mapper')

  literalCount(source, 'zig = pkgs.zig_0_15;', 1, 'Zig 0.15 package selection')
  literalCount(
    source,
    `assert zig.version == "${nixFlakePolicy.zigVersion}";`,
    1,
    'exact Zig version assertion',
  )
  literalCount(
    source,
    'version = lib.removeSuffix "\\n" (builtins.readFile ./VERSION);',
    1,
    'repository version binding',
  )

  literalCount(source, 'source = lib.fileset.toSource {', 1, 'fileset source construction')
  literalCount(source, 'root = ./.;', 1, 'fileset root')
  const sourceBlock = singleCapture(
    source,
    /^            fileset = lib\.fileset\.unions \[\n([\s\S]*?)^            \];$/gm,
    'source allowlist',
  )
  const sourcePaths = parseSourcePaths(sourceBlock)
  if (!same(sourcePaths, nixFlakePolicy.sourcePaths)) fail('source allowlist drifted')

  literalCount(source, 'pkgs.stdenv.mkDerivation {', 1, 'package derivation')
  literalCount(source, 'strictDeps = true;', 1, 'strict dependency mode')
  const nativeInputs = singleCapture(
    source,
    /^          nativeBuildInputs = \[\n([\s\S]*?)^          \];$/gm,
    'native build input inventory',
  ).trim().split(/\s+/)
  if (!same(nativeInputs, ['zig', 'pkgs.coreutils'])) fail('native build input inventory drifted')
  for (const setting of [
    'dontConfigure = true;',
    'dontBuild = true;',
    'dontUseZigConfigure = true;',
    'dontUseZigBuild = true;',
    'dontUseZigCheck = true;',
    'dontUseZigInstall = true;',
    'dontSetZigDefaultFlags = true;',
  ]) literalCount(source, setting, 1, setting)
  for (const buildFragment of [
    '--cache-dir "$TMPDIR/zig-cache"',
    '--global-cache-dir "$TMPDIR/zig-global-cache"',
    '-Dcpu=baseline',
    '-Doptimize=ReleaseFast',
    '--prefix "$out"',
    'test -x "$out/bin/zigcss"',
  ]) literalCount(source, buildFragment, 1, `build contract ${buildFragment}`)

  const outputNames = [...source.matchAll(/^      ([A-Za-z][A-Za-z0-9]*) = forAllSystems/gm)]
    .map(match => match[1])
  if (!same(outputNames, ['packages', 'apps', 'checks'])) fail('flake output inventory drifted')
  for (const outputFragment of [
    'default = mkPackage system;',
    'program = "${self.packages.${system}.default}/bin/zigcss";',
    'meta.description = "Run the repository-local ZigCSS source build";',
    'package = self.packages.${system}.default;',
  ]) literalCount(source, outputFragment, 1, `flake output ${outputFragment}`)

  literalCount(source, 'doInstallCheck = true;', 1, 'install-check enablement')
  literalCount(source, 'check_dir="$TMPDIR/zigcss-install-check"', 1, 'confined install-check directory')
  literalCount(source, 'timeout --kill-after=2s 20s', 3, 'bounded install-check timeout')
  literalCount(source, '-le 128', 5, 'install-check byte bound')
  for (const checkFragment of [
    'test "$version_output" = "zigcss ${version}"',
    "printf '%s\\n' '.card { color: red; }' > \"$check_dir/input.css\"",
    '"$out/bin/zigcss" --syntax css "$check_dir/input.css"',
    "printf '%s\\n' '$color: red;' > \"$check_dir/_tokens.scss\"",
    "printf '%s\\n' '@use \"tokens\"; .card { color: tokens.$color; }' > \"$check_dir/input.scss\"",
    '"$out/bin/zigcss" --syntax scss "$check_dir/input.scss"',
  ]) literalCount(source, checkFragment, 1, `install-check contract ${checkFragment}`)
  literalCount(source, "= '.card{color:red}'", 2, 'exact stylesheet result')

  const digest = crypto.createHash('sha256').update(source).digest('hex')
  if (digest !== expectedFlakeSha256) fail('flake.nix canonical contract drifted')
  return { systems, sourcePaths }
}

export function validateNixFlakeSources(sources) {
  exactObjectKeys(sources, ['flake', 'lock'], 'source set')
  validateCanonicalText(sources.flake, 'flake.nix', maximumNixFlakeBytes)
  validateCanonicalText(sources.lock, 'flake.lock', maximumNixLockBytes)
  const lock = validateLock(sources.lock)
  const flake = validateFlake(sources.flake, lock)
  return Object.freeze({
    revision: nixFlakePolicy.revision,
    narHash: nixFlakePolicy.narHash,
    systems: Object.freeze([...flake.systems]),
    sourcePaths: Object.freeze([...flake.sourcePaths]),
    zigVersion: nixFlakePolicy.zigVersion,
  })
}

export function readNixFlakeSources(root = repositoryRoot) {
  const canonical = canonicalRoot(root)
  return {
    flake: readRegularText(canonical, 'flake.nix', 'flake.nix', maximumNixFlakeBytes),
    lock: readRegularText(canonical, 'flake.lock', 'flake.lock', maximumNixLockBytes),
  }
}

export function validateNixFlake(root = repositoryRoot) {
  return validateNixFlakeSources(readNixFlakeSources(root))
}

export function parseNixFlakeArguments(args) {
  if (!Array.isArray(args) || args.length !== 1 || args[0] !== '--check') {
    fail('usage: --check')
  }
  return Object.freeze({ mode: 'check' })
}

function main() {
  parseNixFlakeArguments(process.argv.slice(2))
  const result = validateNixFlake()
  process.stdout.write(
    `Nix flake verified: ${result.systems.length} systems, Zig ${result.zigVersion}, nixpkgs ${result.revision}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  try {
    main()
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
