import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

function read(relativePath) {
  return fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8')
}

function field(manifest, name) {
  const match = manifest.match(new RegExp(`\\.${name}\\s*=\\s*"([^"]+)"`))
  assert.ok(match, `missing ${name}`)
  return match[1]
}

function filesRecursive(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.isDirectory() && (
      entry.name.startsWith('.') ||
      entry.name === 'zig-out' ||
      entry.name === 'node_modules'
    )) return []
    const entryPath = path.join(directory, entry.name)
    return entry.isDirectory() ? filesRecursive(entryPath) : [entryPath]
  })
}

const maximumZigOutputBytes = 8 * 1024 * 1024
const zigCommandTimeoutMs = 15 * 60 * 1000

function exactZigTool() {
  const command = process.env.ZIG ?? (process.platform === 'win32' ? 'zig.exe' : 'zig')
  const result = spawnSync(command, ['version'], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024,
    timeout: 5_000,
    windowsHide: true,
  })
  if (result.error?.code === 'ENOENT') return null
  assert.equal(result.error, undefined, `Zig version probe failed: ${result.error?.message}`)
  assert.equal(result.signal, null, 'Zig version probe was terminated')
  assert.equal(result.status, 0, result.stderr || result.stdout)
  if (!['0.15.2\n', '0.15.2\r\n'].includes(result.stdout)) return null
  return command
}

function zigBuildEnvironment(workspace) {
  if (process.platform !== 'darwin') return process.env
  const sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
  if (!fs.existsSync(sdk)) return process.env
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
    ...process.env,
    MACOSX_DEPLOYMENT_TARGET: '15.4',
    PATH: `${wrapperDirectory}${path.delimiter}${process.env.PATH ?? ''}`,
  }
}

function runZig(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repositoryRoot,
    encoding: 'utf8',
    env: options.env ?? process.env,
    maxBuffer: maximumZigOutputBytes,
    timeout: zigCommandTimeoutMs,
    windowsHide: true,
  })
  assert.equal(result.error, undefined, `${options.label ?? 'Zig command'} failed to start: ${result.error?.message}`)
  assert.equal(result.signal, null, `${options.label ?? 'Zig command'} was terminated`)
  assert.equal(
    result.status,
    0,
    [options.label ?? 'Zig command', result.stdout, result.stderr].filter(Boolean).join('\n'),
  )
  return result
}

function verifyFetchedTree(root, expectedTopLevel) {
  const actualTopLevel = fs.readdirSync(root).sort()
  assert.deepEqual(actualTopLevel, [...expectedTopLevel].sort())
  const pending = [root]
  let entries = 0
  let bytes = 0
  while (pending.length > 0) {
    const directory = pending.pop()
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      entries += 1
      assert.equal(entries <= 2_000, true, 'fetched Zig package tree is unexpectedly large')
      const filename = path.join(directory, entry.name)
      const stat = fs.lstatSync(filename)
      assert.equal(stat.isSymbolicLink(), false, 'fetched Zig package must not contain symlinks')
      if (stat.isDirectory()) pending.push(filename)
      else {
        assert.equal(stat.isFile(), true, 'fetched Zig package entries must be regular files or directories')
        bytes += stat.size
        assert.equal(bytes <= 64 * 1024 * 1024, true, 'fetched Zig package bytes exceed the audit bound')
      }
    }
  }
  assert.equal(entries > expectedTopLevel.length, true, 'fetched Zig package must contain compiler sources')
}

test('Zig package identity version and minimum toolchain are pinned', () => {
  const manifest = read('build.zig.zon')
  const npmManifest = JSON.parse(read('package.json'))
  const vscodeManifest = JSON.parse(read('vscode-extension/package.json'))
  const main = read('src/main.zig')

  assert.match(manifest, /\.name\s*=\s*\.zigcss,/)
  assert.match(
    manifest,
    /\.fingerprint\s*=\s*0xae272a4871e93d07,\s*\/\/ Changing this has security and trust implications\./,
  )
  assert.equal(field(manifest, 'version'), npmManifest.version)
  assert.equal(vscodeManifest.version, npmManifest.version.split('-')[0])
  assert.equal(vscodeManifest.preview, true)
  assert.match(read('vscode-extension/scripts/verify-package.mjs'), /'--pre-release'/)
  assert.equal(field(manifest, 'minimum_zig_version'), '0.15.2')
  assert.match(manifest, /\.dependencies\s*=\s*\.\{\},/)
  assert.match(main, new RegExp(`const version = "${npmManifest.version.replaceAll('.', '\\.')}";`))
})

test('Zig package contents are an explicit minimal allowlist', () => {
  const manifest = read('build.zig.zon')
  const block = manifest.match(/\.paths\s*=\s*\.\{([\s\S]*?)\n\s*\},/)
  assert.ok(block, 'missing package paths')
  const paths = [...block[1].matchAll(/"([^"]+)"/g)].map(match => match[1])

  assert.deepEqual(paths, [
    'build.zig',
    'build.zig.zon',
    'build_helpers.zig',
    'src',
    'README.md',
    'LICENSE',
  ])
  assert.ok(!paths.includes('tests'))
  assert.ok(!paths.includes('docs'))
})

test('build helpers declare cacheable inputs and outputs without custom make logic', () => {
  const helper = read('build_helpers.zig')
  const build = read('build.zig')

  assert.match(helper, /pub fn addCssCompile\(/)
  assert.match(helper, /run\.addFileArg\(options\.input\)/)
  assert.match(helper, /run\.addOutputFileArg\(options\.output_name\)/)
  assert.match(helper, /pub fn getOutput\(self: CssCompile\) Build\.LazyPath/)
  assert.match(helper, /run\.stdio_limit = \.limited\(1024 \* 1024\)/)
  assert.doesNotMatch(helper, /makeFn|@fieldParentPtr|\.step\.make|ArrayList/)
  assert.doesNotMatch(helper, /source_map|autoprefix|browsers/i)
  assert.match(build, /test-build-helpers/)
  assert.match(build, /pub const helpers = @import\("build_helpers\.zig"\)/)
  assert.match(build, /b\.addCheckFile\(helper_compilation\.getOutput\(\)/)
})

test('the committed consumer uses the package manager rather than a relative source import', () => {
  const manifest = read('tests/package-consumer/build.zig.zon')
  const build = read('tests/package-consumer/build.zig')
  const consumer = read('tests/package-consumer/consumer.zig')

  assert.equal(field(manifest, 'minimum_zig_version'), '0.15.2')
  assert.match(manifest, /\.zigcss\s*=\s*\.\{\s*\.path\s*=\s*"\.\.\/\.\."\s*\}/)
  assert.match(build, /b\.dependency\("zigcss"/)
  assert.match(build, /zigcss\.module\("zigcss"\)/)
  assert.match(build, /@import\("zigcss"\)/)
  assert.match(build, /zigcss_build\.helpers\.addCssCompile/)
  assert.match(consumer, /@import\("zigcss"\)/)
  assert.doesNotMatch(consumer, /@import\("\.\.\//)
})

const fetchedConsumerRequired = process.env.ZIGCSS_REQUIRE_FETCHED_ZIG_PACKAGE === '1'
  || process.env.GITHUB_ACTIONS === 'true'
const fetchedConsumerZig = exactZigTool()

test('a fresh isolated zig fetch cache copy compiles the external package consumer', {
  skip: fetchedConsumerZig === null && !fetchedConsumerRequired
    ? 'exact Zig 0.15.2 is not available; GitHub Actions makes this consumer mandatory'
    : false,
}, () => {
  assert.notEqual(fetchedConsumerZig, null, 'fresh fetched-cache consumer is mandatory on this host')
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-fetched-consumer-')))
  try {
    const expectedTopLevel = [
      'build.zig',
      'build.zig.zon',
      'build_helpers.zig',
      'src',
      'README.md',
      'LICENSE',
    ]
    const stagedPackage = path.join(temporary, 'source-package')
    fs.mkdirSync(stagedPackage)
    for (const relativePath of expectedTopLevel) {
      const source = path.join(repositoryRoot, relativePath)
      const stat = fs.lstatSync(source)
      assert.equal(stat.isSymbolicLink(), false, `${relativePath} cannot be a source-package symlink`)
      const destination = path.join(stagedPackage, relativePath)
      if (stat.isDirectory()) {
        fs.cpSync(source, destination, {
          dereference: false,
          errorOnExist: true,
          force: false,
          recursive: true,
        })
      } else {
        assert.equal(stat.isFile(), true, `${relativePath} must be a regular source-package entry`)
        fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL)
      }
    }
    verifyFetchedTree(stagedPackage, expectedTopLevel)

    const globalCache = path.join(temporary, 'global-cache')
    const fetched = runZig(fetchedConsumerZig, [
      'fetch', '.',
      '--global-cache-dir', globalCache,
    ], {
      cwd: stagedPackage,
      label: 'isolated zig fetch package copy',
    })
    assert.equal(fetched.stderr, '')
    const packageHash = fetched.stdout.trim()
    const version = field(read('build.zig.zon'), 'version')
    assert.match(
      packageHash,
      new RegExp(`^zigcss-${version.replaceAll('.', '\\.')}[-+][A-Za-z0-9_-]{20,}$`),
    )
    const packageRoot = path.join(globalCache, 'p', packageHash)
    const packageStat = fs.lstatSync(packageRoot)
    assert.equal(packageStat.isDirectory(), true)
    assert.equal(packageStat.isSymbolicLink(), false)
    const relativeToCheckout = path.relative(repositoryRoot, fs.realpathSync(packageRoot))
    assert.equal(path.isAbsolute(relativeToCheckout), false)
    assert.match(relativeToCheckout, /^\.\.(?:[/\\]|$)/)
    verifyFetchedTree(packageRoot, expectedTopLevel)

    const consumer = path.join(temporary, 'consumer')
    fs.cpSync(path.join(repositoryRoot, 'tests', 'package-consumer'), consumer, {
      errorOnExist: true,
      force: false,
      recursive: true,
    })
    const manifestPath = path.join(consumer, 'build.zig.zon')
    const manifest = fs.readFileSync(manifestPath, 'utf8')
    const fetchedPackagePath = path.relative(consumer, packageRoot).split(path.sep).join('/')
    assert.match(fetchedPackagePath, /^\.\.(?:\/|$)/)
    const isolatedManifest = manifest.replace(
      '.zigcss = .{ .path = "../.." },',
      `.zigcss = .{ .path = ${JSON.stringify(fetchedPackagePath)} },`,
    )
    assert.notEqual(isolatedManifest, manifest)
    fs.writeFileSync(manifestPath, isolatedManifest)

    const result = runZig(fetchedConsumerZig, [
      'build', 'test', '--summary', 'all',
      '--cache-dir', path.join(temporary, 'consumer-cache'),
      '--global-cache-dir', globalCache,
    ], {
      cwd: consumer,
      env: zigBuildEnvironment(temporary),
      label: 'fresh fetched-cache external Zig consumer',
    })
    assert.equal(`${result.stdout}\n${result.stderr}`.includes(repositoryRoot), false)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('every Zig example has an executable build gate', () => {
  const examples = filesRecursive(path.join(repositoryRoot, 'examples'))
    .filter(file => file.endsWith('.zig'))
    .map(file => path.relative(repositoryRoot, file))
    .sort()
  assert.deepEqual(examples, [
    'examples/build-integration/build.zig',
    'examples/build-integration/main.zig',
    'examples/css_modules.zig',
    'examples/native_api.zig',
    'examples/public_api.zig',
  ])

  const rootBuild = read('build.zig')
  const integrationBuild = read('examples/build-integration/build.zig')
  const integrationManifest = read('examples/build-integration/build.zig.zon')
  const workflow = read('.github/workflows/build.yml')
  assert.match(rootBuild, /examples\/public_api\.zig/)
  assert.match(rootBuild, /examples\/native_api\.zig/)
  assert.match(rootBuild, /examples\/css_modules\.zig/)
  assert.match(rootBuild, /test-documentation-examples/)
  assert.match(integrationManifest, /\.zigcss\s*=\s*\.\{\s*\.path\s*=\s*"\.\.\/\.\."\s*\}/)
  assert.match(integrationBuild, /const zigcss_build = @import\("zigcss"\)/)
  assert.match(integrationBuild, /\.target = b\.graph\.host/)
  assert.match(integrationBuild, /zigcss_build\.helpers\.addCssCompile/)
  assert.match(integrationBuild, /b\.addCheckFile\(css\.getOutput\(\)/)
  assert.match(workflow, /working-directory: examples\/build-integration/)
  assert.match(workflow, /zig build test -Doptimize=ReleaseSafe --summary all/)
})

test('the installed executable delegates CSS compilation to the public facade', () => {
  const build = read('build.zig')
  const main = read('src/main.zig')
  const api = read('src/api.zig')
  const profiling = read('src/profiling.zig')
  const testOnlyImports = main.indexOf('\nconst formats = @import("formats.zig");')
  assert.notEqual(testOnlyImports, -1, 'missing test-only CLI import boundary')
  const runtime = main.slice(0, testOnlyImports)
  const watch = runtime.match(/fn watchFile\([\s\S]*?\n}\n\nconst CompileError/)
  const parallel = runtime.match(/const BatchWorkQueue[\s\S]*?\n}\n\nconst CompileError/)
  const batch = runtime.match(/fn compileBatch\([\s\S]*?\n}\n\nfn experimentalFormatName/)

  assert.match(runtime, /pub fn main\(\) !void/)
  assert.match(runtime, /const zigcss = @import\("zigcss"\)/)
  assert.equal([...runtime.matchAll(/zigcss\.compile\(/g)].length, 1)
  assert.doesNotMatch(
    runtime,
    /css\/pipeline|verified_optimizer|const (?:formats|codegen|parser|optimizer|autoprefixer) =/,
  )
  assert.doesNotMatch(runtime, /const profiler = @import/)
  assert.match(runtime, /\.profile = profile/)
  assert.match(runtime, /result\.metrics orelse return error\.MissingProfileMetrics/)
  assert.match(api, /profile: bool = false/)
  assert.match(api, /profiling\.Session\.init\(allocator, options\.profile\)/)
  assert.match(api, /result\.metrics = profile\.finish\(\)/)
  assert.match(profiling, /pub const TrackingAllocator/)
  assert.match(profiling, /retained_result_bytes/)
  assert.match(build, /executable_module\.addImport\("zigcss", library_module\)/)
  assert.match(build, /test_module\.addImport\("zigcss", library_module\)/)
  assert.match(build, /audit_test_module\.addImport\("zigcss", library_module\)/)
  assert.ok(watch, 'missing watch implementation boundary')
  assert.match(watch[0], /const input = readInput\(allocator, config\.input_file\)/)
  assert.match(watch[0], /compileLoadedFile\(allocator, config, input\)/)
  assert.doesNotMatch(watch[0], /compileFile\(/)
  assert.ok(parallel, 'missing bounded parallel queue boundary')
  assert.ok(batch, 'missing owned batch lifetime boundary')
  assert.match(runtime, /const max_batch_workers = 8;/)
  assert.match(runtime, /GeneralPurposeAllocator\(\.\{ \.thread_safe = false \}\)/)
  assert.match(runtime, /fn compileTask\(task: \*CompileTask\) bool \{\s+const allocator = task\.allocator\(\)/)
  assert.match(parallel[0], /queue\.cancelForFailure\(\)/)
  assert.match(parallel[0], /threads\[0\.\.spawned\][\s\S]*thread\.join\(\)/)
  assert.doesNotMatch(parallel[0], /batch_size|tasks_slice|completed/)
  assert.match(batch[0], /for \(tasks\.items\) \|\*task\| task\.deinit\(allocator\)/)
  assert.match(read('.github/workflows/build.yml'), /npm run test:node-wrapper/)
})

test('active source and CI surfaces agree on the Zig 0.15.2 baseline', () => {
  const buildWorkflow = read('.github/workflows/build.yml')
  const releaseWorkflow = read('.github/workflows/release.yml')
  const versions = [
    ...buildWorkflow.matchAll(/zig-version:\s*([^\s]+)/g),
    ...buildWorkflow.matchAll(/version:\s*(0\.\d+\.\d+)/g),
    ...releaseWorkflow.matchAll(/zig-version:\s*([^\s]+)/g),
  ].map(match => match[1])

  assert.ok(versions.length > 0)
  assert.deepEqual(new Set(versions), new Set(['0.15.2']))
  assert.match(read('Dockerfile'), /ARG ZIG_VERSION=0\.15\.2/)
  assert.match(read('README.md'), /Use Zig 0\.15\.2:/)
  assert.match(read('README.md'), /`build\.zig\.zon` gives the source package stable identity/)
  assert.match(read('README.md'), /helpers\.addCssCompile/)
  assert.match(read('docs/src/content/docs/guide/build-from-source.md'), /- Zig 0\.15\.2/)
  assert.match(read('docs/src/content/docs/guide/build-from-source.md'), /tests\/package-consumer/)
  assert.match(read('docs/src/app/components/GettingStarted.tsx'), /Use Zig 0\.15\.2 and run:/)
  assert.doesNotMatch(read('install.js'), /Zig 0\.15\.2\+/)
  assert.match(
    buildWorkflow,
    /- name: Verify Zig package metadata\n\s+env:\n\s+ZIGCSS_REQUIRE_FETCHED_ZIG_PACKAGE: '1'\n\s+run: npm run test:zig-package/,
  )
})
