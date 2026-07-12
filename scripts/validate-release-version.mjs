import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const homebrewSourceCommit = '3fada2359ab1fa262b782a33e9ab2a7bab2c46ca'
const homebrewSourceSha256 = '2fc630a41af5b5fef1d1e4db551604deac048c1b02ff249d5abbb061ebd5c906'

export const releaseSourcePaths = Object.freeze([
  '.github/workflows/build.yml',
  '.github/workflows/release.yml',
  'CHANGELOG.md',
  'DEVELOPMENT_PLAN.md',
  'Dockerfile',
  'Dockerfile.docs',
  'Dockerfile.release',
  'Formula/zigcss.rb',
  'README.md',
  'VERSION',
  'build.zig.zon',
  'docs/package-lock.json',
  'docs/package.json',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Home.tsx',
  'docs/src/content/docs/guide/build-from-source.md',
  'docs/src/content/docs/guide/status.md',
  'docs/src/data/capabilities.json',
  'install.js',
  'neovim-config/README.md',
  'package-lock.json',
  'package.json',
  'src/main.zig',
  'tests/regressions/audit.zig',
  'vscode-extension/package-lock.json',
  'vscode-extension/package.json',
  'vscode-extension/scripts/verify-package.mjs',
])

const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/

function fail(message) {
  throw new Error(`release version integrity: ${message}`)
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

export function parseReleaseVersion(value, label = 'version') {
  if (typeof value !== 'string') fail(`${label} must be a string`)
  const match = value.match(semverPattern)
  if (match === null) fail(`${label} is not canonical Semantic Versioning: ${JSON.stringify(value)}`)
  return {
    value,
    base: `${match[1]}.${match[2]}.${match[3]}`,
    prerelease: match[4] ?? null,
    build: match[5] ?? null,
  }
}

export function validateReleaseTag(version, tag) {
  const expected = `v${version}`
  if (tag !== expected) fail(`release tag must be ${expected}, received ${JSON.stringify(tag)}`)
  return true
}

function parseJson(sources, filename) {
  try {
    return JSON.parse(sources.get(filename))
  } catch (error) {
    fail(`${filename} is not valid JSON: ${error.message}`)
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label} must be ${expected}, received ${JSON.stringify(actual)}`)
}

function expectContains(source, fragment, label) {
  if (!source.includes(fragment)) fail(`${label} is missing ${JSON.stringify(fragment)}`)
}

function expectLiteralCount(source, literal, expected, label) {
  const actual = source.split(literal).length - 1
  if (actual !== expected) fail(`${label} must contain ${JSON.stringify(literal)} ${expected} times, received ${actual}`)
}

function singleCapture(source, expression, label) {
  const matches = [...source.matchAll(expression)]
  if (matches.length !== 1) fail(`${label} must occur exactly once, received ${matches.length}`)
  return matches[0][1]
}

export function validateReleaseSources(sources) {
  const actualPaths = [...sources.keys()].sort()
  const expectedPaths = [...releaseSourcePaths].sort()
  if (!same(actualPaths, expectedPaths)) {
    fail(`release surface inventory changed: expected ${JSON.stringify(expectedPaths)}, received ${JSON.stringify(actualPaths)}`)
  }

  const canonicalText = sources.get('VERSION')
  if (!canonicalText.endsWith('\n') || canonicalText.trim() + '\n' !== canonicalText) {
    fail('VERSION must contain exactly one canonical version and a final newline')
  }
  const parsed = parseReleaseVersion(canonicalText.trim(), 'VERSION')
  const version = parsed.value
  const vscodeVersion = parsed.base

  const planTarget = singleCapture(
    sources.get('DEVELOPMENT_PLAN.md'),
    /## Milestone 7:[\s\S]*?\nTarget: `([^`]+)`/g,
    'Milestone 7 release target',
  )
  parseReleaseVersion(planTarget, 'Milestone 7 target')
  expectEqual(version, planTarget, 'VERSION')

  const rootManifest = parseJson(sources, 'package.json')
  const rootLock = parseJson(sources, 'package-lock.json')
  const docsManifest = parseJson(sources, 'docs/package.json')
  const docsLock = parseJson(sources, 'docs/package-lock.json')
  const vscodeManifest = parseJson(sources, 'vscode-extension/package.json')
  const vscodeLock = parseJson(sources, 'vscode-extension/package-lock.json')

  expectEqual(rootManifest.name, 'zigcss', 'root npm package name')
  expectEqual(rootManifest.version, version, 'root npm package version')
  expectEqual(rootLock.version, version, 'root npm lock version')
  expectEqual(rootLock.packages?.['']?.version, version, 'root npm lock package version')
  expectEqual(docsManifest.dependencies?.zigcss, 'file:..', 'documentation ZigCSS dependency')
  expectEqual(docsLock.packages?.['..']?.version, version, 'documentation linked ZigCSS version')
  expectEqual(vscodeManifest.version, vscodeVersion, 'VS Code Marketplace package version')
  expectEqual(vscodeManifest.preview, true, 'VS Code preview marker')
  expectEqual(vscodeLock.version, vscodeVersion, 'VS Code lock version')
  expectEqual(vscodeLock.packages?.['']?.version, vscodeVersion, 'VS Code lock package version')

  expectEqual(
    rootManifest.scripts?.['check:version'],
    'node scripts/validate-release-version.mjs --check',
    'version check script',
  )
  expectEqual(
    rootManifest.scripts?.['test:version'],
    'node --test scripts/validate-release-version.test.mjs',
    'version test script',
  )

  const zigVersion = singleCapture(sources.get('build.zig.zon'), /^\s*\.version\s*=\s*"([^"]+)",$/gm, 'Zig package version')
  expectEqual(zigVersion, version, 'Zig package version')

  const main = sources.get('src/main.zig')
  const cliVersion = singleCapture(main, /^const version = "([^"]+)";$/gm, 'CLI version constant')
  expectEqual(cliVersion, version, 'CLI version constant')
  expectContains(main, '"Warning: ZigCSS {s} is an experimental release candidate', 'CLI warning')
  expectContains(main, 'std.fmt.comptimePrint("ZigCSS {s} recovery CLI', 'CLI help')
  expectContains(sources.get('tests/regressions/audit.zig'), `"zigcss ${version}\\n"`, 'CLI version regression')
  expectContains(sources.get('install.js'), "const VERSION = require('./package.json').version", 'npm installer')

  const formula = sources.get('Formula/zigcss.rb')
  const formulaCommit = singleCapture(
    formula,
    /url "https:\/\/github\.com\/vyakymenko\/zigcss\/archive\/([0-9a-f]{40})\.tar\.gz"/g,
    'Homebrew source commit',
  )
  const formulaVersion = singleCapture(formula, /^\s*version "([^"]+)"$/gm, 'Homebrew formula version')
  const formulaSha256 = singleCapture(formula, /^\s*sha256 "([0-9a-f]{64})"$/gm, 'Homebrew source SHA-256')
  expectEqual(formulaCommit, homebrewSourceCommit, 'Homebrew source commit')
  expectEqual(formulaVersion, version, 'Homebrew formula version')
  expectEqual(formulaSha256, homebrewSourceSha256, 'Homebrew source SHA-256')
  expectLiteralCount(formula, '  depends_on "zig@0.15" => :build', 1, 'Homebrew Zig dependency')
  expectLiteralCount(
    formula,
    '    system Formula["zig@0.15"].opt_bin/"zig", "build", "-Doptimize=ReleaseFast"',
    1,
    'Homebrew build command',
  )
  expectContains(formula, 'assert_equal "zigcss #{version}\\n", shell_output("#{bin}/zigcss --version")', 'Homebrew version test')
  expectContains(formula, 'assert_equal ".test{color:red}", shell_output("#{bin}/zigcss test.css --minify")', 'Homebrew compile test')
  if (/^\s*head\s/m.test(formula)) fail('Homebrew formula must not expose an unverified head build')

  for (const filename of ['Dockerfile', 'Dockerfile.docs', 'Dockerfile.release']) {
    const dockerfile = sources.get(filename)
    const dockerVersion = singleCapture(dockerfile, /^ARG ZIGCSS_VERSION=(\S+)$/gm, `${filename} product version`)
    expectEqual(dockerVersion, version, `${filename} product version`)
    expectContains(dockerfile, 'org.opencontainers.image.version="${ZIGCSS_VERSION}"', `${filename} OCI label`)
  }

  const capabilityMetadata = parseJson(sources, 'docs/src/data/capabilities.json')
  const capabilityById = new Map(capabilityMetadata.capabilities.map(capability => [capability.id, capability]))
  expectContains(capabilityById.get('zig-package')?.behavior ?? '', `Package \`zigcss\` ${version}`, 'Zig package capability')
  const vscodeBehavior = capabilityById.get('vscode')?.behavior ?? ''
  expectContains(vscodeBehavior, `Marketplace version ${vscodeVersion}`, 'VS Code capability')
  expectContains(vscodeBehavior, `core ${version}`, 'VS Code capability')
  expectContains(vscodeBehavior, 'pre-release marker', 'VS Code capability')
  expectEqual(capabilityMetadata.gates?.['release-version']?.command, 'npm run check:version', 'release-version evidence gate')

  const readme = sources.get('README.md')
  const status = sources.get('docs/src/content/docs/guide/status.md')
  expectLiteralCount(readme, version, 4, 'README release claims')
  expectLiteralCount(status, version, 5, 'status guide release claims')
  expectLiteralCount(sources.get('docs/src/content/docs/guide/build-from-source.md'), version, 1, 'build guide release claims')
  expectLiteralCount(sources.get('docs/src/app/components/GettingStarted.tsx'), version, 1, 'getting-started release claims')
  expectLiteralCount(sources.get('docs/src/app/components/Home.tsx'), version, 1, 'homepage release claims')
  expectLiteralCount(sources.get('neovim-config/README.md'), version, 2, 'Neovim release claims')
  expectContains(readme, `Marketplace version ${vscodeVersion}`, 'README VS Code mapping')
  expectContains(status, `Marketplace version ${vscodeVersion}`, 'status VS Code mapping')

  const changelog = sources.get('CHANGELOG.md')
  expectContains(changelog, `Target release: \`${version}\` (not published).`, 'unreleased changelog target')
  if (/ZigCSS 0\.3 (?:is|and)/.test(changelog)) fail('changelog recovery note still claims the 0.3 line is current')

  const buildWorkflow = sources.get('.github/workflows/build.yml')
  const workflowGate = buildWorkflow.indexOf('npm run test:workflows && npm run check:workflows')
  const versionStep = buildWorkflow.indexOf('- name: Verify release version policy', workflowGate)
  const versionGate = buildWorkflow.indexOf('npm run test:version && npm run check:version', versionStep)
  const install = buildWorkflow.indexOf('- name: Install independent validator', versionGate)
  if (workflowGate === -1 || versionStep <= workflowGate || versionGate <= versionStep || install <= versionGate) {
    fail('build workflow must validate the release version after workflow policy and before npm installation')
  }

  const releaseWorkflow = sources.get('.github/workflows/release.yml')
  const setupNode = releaseWorkflow.indexOf('- name: Setup Node.js')
  const releaseGate = releaseWorkflow.indexOf('npm run check:version -- --tag "$GITHUB_REF_NAME"', setupNode)
  const releaseBuild = releaseWorkflow.indexOf('- name: Build Release Binary', releaseGate)
  if (setupNode === -1 || releaseGate <= setupNode || releaseBuild <= releaseGate) {
    fail('release workflow must reject a mismatched tag before building any release artifact')
  }
  if (/ZigCSS 0\.\d/.test(releaseWorkflow)) fail('release workflow body must use its computed version instead of a hard-coded product line')

  const vscodeVerifier = sources.get('vscode-extension/scripts/verify-package.mjs')
  expectContains(vscodeVerifier, "'--pre-release'", 'VS Code package verifier')

  return { version, vscodeVersion, surfaces: releaseSourcePaths.length }
}

export function readReleaseSources(root = repositoryRoot) {
  const canonicalRoot = fs.realpathSync(root)
  return new Map(releaseSourcePaths.map(relativePath => {
    const candidate = path.resolve(canonicalRoot, relativePath)
    let stat
    try {
      stat = fs.lstatSync(candidate)
    } catch (error) {
      fail(`${relativePath} is missing: ${error.message}`)
    }
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`${relativePath} must be a regular non-symlink file`)
    const canonical = fs.realpathSync(candidate)
    const confinement = path.relative(canonicalRoot, canonical)
    if (confinement === '..' || confinement.startsWith(`..${path.sep}`) || path.isAbsolute(confinement)) {
      fail(`${relativePath} escapes the repository`)
    }
    return [relativePath, fs.readFileSync(canonical, 'utf8')]
  }))
}

export function validateReleaseVersion(root = repositoryRoot) {
  return validateReleaseSources(readReleaseSources(root))
}

function main() {
  const args = process.argv.slice(2)
  if (args[0] !== '--check' || (args.length !== 1 && (args.length !== 3 || args[1] !== '--tag'))) {
    throw new Error('usage: node scripts/validate-release-version.mjs --check [--tag vX.Y.Z]')
  }
  const result = validateReleaseVersion()
  if (args.length === 3) validateReleaseTag(result.version, args[2])
  process.stdout.write(
    `Release version verified: core ${result.version}, VS Code Marketplace ${result.vscodeVersion}, ${result.surfaces} synchronized surfaces${args.length === 3 ? `, tag ${args[2]}` : ''}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
