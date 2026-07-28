const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const extensionRoot = path.resolve(__dirname, '..')
const repositoryRoot = path.resolve(extensionRoot, '..')
const read = file => fs.readFileSync(path.join(extensionRoot, file), 'utf8')
const manifest = JSON.parse(read('package.json'))

test('extension identity and dependency versions are synchronized and exact', () => {
  const rootManifest = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'),
  )
  const zigManifest = fs.readFileSync(
    path.join(repositoryRoot, 'build.zig.zon'),
    'utf8',
  )
  const lock = JSON.parse(read('package-lock.json'))
  const languageClient = JSON.parse(
    fs.readFileSync(
      path.join(extensionRoot, 'node_modules/vscode-languageclient/package.json'),
      'utf8',
    ),
  )

  assert.equal(manifest.version, rootManifest.version.split('-')[0])
  assert.equal(manifest.preview, true)
  assert.match(read('scripts/verify-package.mjs'), /'--pre-release'/)
  assert.match(zigManifest, new RegExp(`\\.version = "${rootManifest.version.replaceAll('.', '\\.')}"`))
  assert.equal(lock.packages[''].version, manifest.version)
  assert.equal(manifest.engines.vscode, languageClient.engines.vscode)
  for (const version of [
    ...Object.values(manifest.dependencies),
    ...Object.values(manifest.devDependencies),
  ]) {
    assert.doesNotMatch(version, /^[~^]/)
  }

  const notices = read('THIRD_PARTY_NOTICES.md')
  for (const name of [
    'vscode-languageclient',
    'vscode-languageserver-protocol',
    'vscode-languageserver-textdocument',
    'vscode-languageserver-types',
    'vscode-jsonrpc',
    'minimatch',
    'semver',
    'brace-expansion',
    'balanced-match',
  ]) {
    const version = lock.packages[`node_modules/${name}`].version
    assert.ok(notices.includes(`| \`${name}\` | ${version} |`))
  }
})

test('manifest activates only the supported CSS surface and is trust-bounded', () => {
  assert.deepEqual(manifest.activationEvents, ['onLanguage:css'])
  assert.equal(manifest.contributes.languages, undefined)
  assert.equal(manifest.main, './dist/extension.js')
  assert.equal(manifest.private, true)
  assert.equal(manifest.preview, true)
  assert.deepEqual(manifest.extensionKind, ['workspace'])
  assert.equal(manifest.capabilities.untrustedWorkspaces.supported, false)
  assert.equal(manifest.capabilities.virtualWorkspaces.supported, false)

  const source = read('src/extension.ts')
  assert.doesNotMatch(source, /createFileSystemWatcher/)
  assert.doesNotMatch(source, /language: '(scss|sass|less|stylus)'/)
  assert.match(source, /discoverServer/)
  assert.match(source, /configuredArgs\.length > 16/)
  assert.match(source, /argument\.length <= 4096/)
  assert.match(source, /argument\.includes\('\\0'\)/)
})

test('compile, test, bundle, package, and clean scripts are explicit', () => {
  assert.equal(manifest.scripts.compile, 'tsc -p ./')
  assert.match(manifest.scripts.test, /node --test/)
  assert.match(manifest.scripts.bundle, /esbuild/)
  assert.match(manifest.scripts['package:check'], /verify-package\.mjs/)
  assert.match(manifest.scripts.clean, /clean\.mjs/)

  const ignored = read('.vscodeignore')
  for (const excluded of ['src/**', 'test/**', 'scripts/**', 'out/**', 'node_modules/**']) {
    assert.match(ignored, new RegExp(`^${excluded.replaceAll('*', '\\*')}$`, 'm'))
  }
  assert.match(ignored, /!dist\/extension\.js/)
})

test('CI installs from the lockfile and runs tests plus package verification', () => {
  const workflow = fs.readFileSync(
    path.join(repositoryRoot, '.github/workflows/build.yml'),
    'utf8',
  )
  const extensionJob = workflow.indexOf('working-directory: vscode-extension')
  assert.notEqual(extensionJob, -1)
  assert.notEqual(workflow.indexOf('npm ci --ignore-scripts', extensionJob), -1)
  assert.notEqual(workflow.indexOf('npm test', extensionJob), -1)
  assert.notEqual(workflow.indexOf('npm run package:check', extensionJob), -1)
})
