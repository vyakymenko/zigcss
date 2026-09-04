import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  maximumNixFlakeBytes,
  maximumNixLockBytes,
  nixFlakePolicy,
  parseNixFlakeArguments,
  readNixFlakeSources,
  validateNixFlake,
  validateNixFlakeSources,
} from './validate-nix-flake.mjs'

const scriptPath = fileURLToPath(new URL('./validate-nix-flake.mjs', import.meta.url))

function canonicalJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`
}

function changedFlake(transform) {
  const sources = readNixFlakeSources()
  sources.flake = transform(sources.flake)
  return sources
}

function changedLock(mutate) {
  const sources = readNixFlakeSources()
  const lock = JSON.parse(sources.lock)
  mutate(lock)
  sources.lock = canonicalJson(lock)
  return sources
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-nix-flake-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const sources = readNixFlakeSources()
  fs.writeFileSync(path.join(root, 'flake.nix'), sources.flake)
  fs.writeFileSync(path.join(root, 'flake.lock'), sources.lock)
  return root
}

test('accepts the exact repository-local Nix package contract', () => {
  const result = validateNixFlake()
  assert.deepEqual(result, {
    revision: nixFlakePolicy.revision,
    narHash: nixFlakePolicy.narHash,
    systems: [...nixFlakePolicy.systems],
    sourcePaths: [...nixFlakePolicy.sourcePaths],
    zigVersion: '0.15.2',
  })

  const checked = spawnSync(process.execPath, [scriptPath, '--check'], { encoding: 'utf8' })
  assert.equal(checked.status, 0, checked.stderr)
  assert.equal(
    checked.stdout,
    `Nix flake verified: 4 systems, Zig 0.15.2, nixpkgs ${nixFlakePolicy.revision}.\n`,
  )
  assert.equal(checked.stderr, '')
})

test('CLI is closed to exactly --check', () => {
  assert.deepEqual(parseNixFlakeArguments(['--check']), { mode: 'check' })
  for (const args of [
    [],
    ['check'],
    ['--smoke'],
    ['--check', '--extra'],
    ['--check', ''],
  ]) assert.throws(() => parseNixFlakeArguments(args), /nix flake: usage: --check/)

  const rejected = spawnSync(process.execPath, [scriptPath, '--check', '--extra'], { encoding: 'utf8' })
  assert.notEqual(rejected.status, 0)
  assert.equal(rejected.stdout, '')
  assert.match(rejected.stderr, /nix flake: usage: --check/)
})

test('lock schema, sole input, immutable revision, narHash, and timestamp fail closed', () => {
  const mutations = [
    lock => { lock.version = 8 },
    lock => { lock.root = 'nixpkgs' },
    lock => { lock.nodes.extra = structuredClone(lock.nodes.nixpkgs) },
    lock => { lock.nodes.root.inputs.extra = 'nixpkgs' },
    lock => { lock.nodes.root.inputs.nixpkgs = 'extra' },
    lock => { delete lock.nodes.nixpkgs.locked.narHash },
    lock => { lock.nodes.nixpkgs.locked.narHash = 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' },
    lock => { lock.nodes.nixpkgs.locked.lastModified += 1 },
    lock => { lock.nodes.nixpkgs.locked.owner = 'other' },
    lock => { lock.nodes.nixpkgs.locked.repo = 'other' },
    lock => { lock.nodes.nixpkgs.locked.type = 'git' },
    lock => { lock.nodes.nixpkgs.locked.rev = 'a'.repeat(40) },
    lock => { lock.nodes.nixpkgs.original.rev = 'main' },
    lock => { lock.nodes.nixpkgs.original.ref = 'main' },
    lock => { lock.nodes.nixpkgs.unlocked = {} },
  ]
  for (const mutate of mutations) {
    assert.throws(() => validateNixFlakeSources(changedLock(mutate)), /nix flake:/)
  }

  const sources = readNixFlakeSources()
  assert.throws(
    () => validateNixFlakeSources({ ...sources, lock: sources.lock.replace('  "nodes"', '    "nodes"') }),
    /canonical JSON representation/,
  )
  assert.throws(
    () => validateNixFlakeSources({ ...sources, lock: '{\n' }),
    /flake\.lock is not valid JSON/,
  )
})

test('flake input, four systems, Zig assertion, and source allowlist fail closed', () => {
  const mutations = [
    source => source.replace(nixFlakePolicy.inputUrl, 'github:NixOS/nixpkgs/main'),
    source => source.replace(
      '  inputs.nixpkgs.url =',
      `  inputs.extra.url = "github:example/extra/${'a'.repeat(40)}";\n  inputs.nixpkgs.url =`,
    ),
    source => source.replace('nixpkgs.lib.genAttrs', 'flake-utils.lib.eachSystem'),
    source => source.replace('        "x86_64-linux"\n', ''),
    source => source.replace(
      '        "x86_64-linux"\n        "aarch64-linux"',
      '        "aarch64-linux"\n        "x86_64-linux"',
    ),
    source => source.replace('pkgs.zig_0_15', 'pkgs.zig'),
    source => source.replace('assert zig.version == "0.15.2";', 'assert zig.version == "0.16.0";'),
    source => source.replace('(builtins.readFile ./VERSION)', '(builtins.getEnv "VERSION")'),
    source => source.replace('              ./build_helpers.zig\n', ''),
    source => source.replace('              ./src\n', '              ./src\n              ./tests\n'),
    source => source.replace('root = ./.;', 'root = ./src;'),
  ]
  for (const mutate of mutations) {
    assert.throws(() => validateNixFlakeSources(changedFlake(mutate)), /nix flake:/)
  }
})

test('package, app, check, build flags, and bounded CSS/SCSS smokes fail closed', () => {
  const mutations = [
    source => source.replace('strictDeps = true;', 'strictDeps = false;'),
    source => source.replace('-Dcpu=baseline', '-Dcpu=native'),
    source => source.replace('-Doptimize=ReleaseFast', '-Doptimize=ReleaseSafe'),
    source => source.replace('$TMPDIR/zig-cache', '/Users/example/zig-cache'),
    source => source.replace('      packages = forAllSystems', '      packaging = forAllSystems'),
    source => source.replace('/bin/zigcss";', '/bin/other";'),
    source => source.replace('package = self.packages.${system}.default;', 'package = null;'),
    source => source.replace('doInstallCheck = true;', 'doInstallCheck = false;'),
    source => source.replace('timeout --kill-after=2s 20s', 'timeout --kill-after=2s 200s'),
    source => source.replace('-le 128', '-le 1024'),
    source => source.replace('--syntax css', '--syntax less'),
    source => source.replace('--syntax scss', '--syntax sass'),
    source => source.replace("@use \"tokens\"; .card { color: tokens.$color; }", '.card { color: red; }'),
    source => source.replace("= '.card{color:red}'", "= '.card { color: red; }'"),
  ]
  for (const mutate of mutations) {
    assert.throws(() => validateNixFlakeSources(changedFlake(mutate)), /nix flake:/)
  }
})

test('impurity, mutable refs, host paths, network, fetchers, registries, and unknown drift are rejected', () => {
  const additions = [
    ['  value = builtins.getEnv "HOME";\n', /forbidden environment access/],
    ['  value = builtins.currentSystem;\n', /forbidden impure host builtin/],
    ['  value = "--impure";\n', /forbidden impure command mode/],
    ['  value = "github:NixOS/nixpkgs/master";\n', /forbidden mutable input reference/],
    ['  value = "github:NixOS/nixpkgs/nixos-26.05";\n', /forbidden mutable input reference/],
    ['  value = pkgs.fetchurl {};\n', /forbidden network fetcher/],
    ['  value = builtins.fetchTarball "https://example.invalid/source";\n', /forbidden network fetcher/],
    ['  value = "curl https://example.invalid";\n', /forbidden network command/],
    ['  value = "/home/builder/source";\n', /forbidden absolute host path/],
    ['  value = /opt/builder/source;\n', /forbidden absolute host path/],
    ['  nixConfig.substituters = [ "https://cache.example.invalid" ];\n', /registry or binary-cache/],
    ['  # unreviewed semantic drift\n', /canonical contract drifted/],
  ]
  for (const [addition, expression] of additions) {
    assert.throws(
      () => validateNixFlakeSources(changedFlake(source => source.replace(/}\n$/, `${addition}}\n`))),
      expression,
    )
  }
})

test('source set and canonical text are exact and bounded', () => {
  const sources = readNixFlakeSources()
  assert.throws(() => validateNixFlakeSources({ flake: sources.flake }), /source set keys/)
  assert.throws(() => validateNixFlakeSources({ ...sources, extra: '' }), /source set keys/)
  assert.throws(() => validateNixFlakeSources({ ...sources, flake: Buffer.from('') }), /flake\.nix source must be text/)
  assert.throws(() => validateNixFlakeSources({ ...sources, flake: sources.flake.replace(/\n$/, '\r\n') }), /canonical LF text/)
  assert.throws(() => validateNixFlakeSources({ ...sources, flake: `${sources.flake}\n` }), /canonical contract drifted/)
  assert.throws(
    () => validateNixFlakeSources({ ...sources, flake: `${' '.repeat(maximumNixFlakeBytes)}\n` }),
    /flake\.nix must contain 1 through/,
  )
  assert.throws(
    () => validateNixFlakeSources({ ...sources, lock: `${' '.repeat(maximumNixLockBytes)}\n` }),
    /flake\.lock must contain 1 through/,
  )
})

test('flake and lock must be stable bounded regular non-symlink UTF-8 files', t => {
  {
    const root = fixture(t)
    const flake = path.join(root, 'flake.nix')
    fs.rmSync(flake)
    fs.symlinkSync(path.join(root, 'flake.lock'), flake)
    assert.throws(() => validateNixFlake(root), /flake\.nix must be a regular non-symlink file/)
  }
  {
    const root = fixture(t)
    const lock = path.join(root, 'flake.lock')
    fs.rmSync(lock)
    fs.mkdirSync(lock)
    assert.throws(() => validateNixFlake(root), /flake\.lock must be a regular non-symlink file/)
  }
  {
    const root = fixture(t)
    fs.truncateSync(path.join(root, 'flake.nix'), maximumNixFlakeBytes + 1)
    assert.throws(() => validateNixFlake(root), /flake\.nix exceeds 32768 bytes/)
  }
  {
    const root = fixture(t)
    fs.truncateSync(path.join(root, 'flake.lock'), maximumNixLockBytes + 1)
    assert.throws(() => validateNixFlake(root), /flake\.lock exceeds 8192 bytes/)
  }
  {
    const root = fixture(t)
    fs.writeFileSync(path.join(root, 'flake.nix'), Buffer.from([0xff, 0xfe]))
    assert.throws(() => validateNixFlake(root), /flake\.nix is not valid UTF-8/)
  }
  {
    const root = fixture(t)
    const link = `${root}-link`
    fs.symlinkSync(root, link, 'dir')
    t.after(() => fs.rmSync(link, { force: true }))
    assert.throws(() => validateNixFlake(link), /repository root must be a regular non-symlink directory/)
  }
})
