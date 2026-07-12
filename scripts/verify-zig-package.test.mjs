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

test('Zig package identity version and minimum toolchain are pinned', () => {
  const manifest = read('build.zig.zon')
  const npmManifest = JSON.parse(read('package.json'))

  assert.match(manifest, /\.name\s*=\s*\.zigcss,/)
  assert.match(
    manifest,
    /\.fingerprint\s*=\s*0xae272a4871e93d07,\s*\/\/ Changing this has security and trust implications\./,
  )
  assert.equal(field(manifest, 'version'), npmManifest.version)
  assert.equal(field(manifest, 'minimum_zig_version'), '0.15.2')
  assert.match(manifest, /\.dependencies\s*=\s*\.\{\},/)
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
