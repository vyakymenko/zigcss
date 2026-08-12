import assert from 'node:assert/strict'
import fs from 'node:fs'
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

test('every Zig example has an executable build gate', () => {
  const examples = filesRecursive(path.join(repositoryRoot, 'examples'))
    .filter(file => file.endsWith('.zig'))
    .map(file => path.relative(repositoryRoot, file))
    .sort()
  assert.deepEqual(examples, [
    'examples/build-integration/build.zig',
    'examples/build-integration/main.zig',
    'examples/css_modules.zig',
    'examples/public_api.zig',
  ])

  const rootBuild = read('build.zig')
  const integrationBuild = read('examples/build-integration/build.zig')
  const integrationManifest = read('examples/build-integration/build.zig.zon')
  const workflow = read('.github/workflows/build.yml')
  assert.match(rootBuild, /examples\/public_api\.zig/)
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
  const runtime = main.split('\ntest "')[0]
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
})
