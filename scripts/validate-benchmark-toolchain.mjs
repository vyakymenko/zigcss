import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')

const competitors = [
  {
    id: 'esbuild',
    package: 'esbuild',
    version: '0.28.1',
    license: 'MIT',
    platformDirectory: path.join('node_modules', '@esbuild'),
    platformPrefix: '@esbuild/',
    executableCandidates: [path.join('bin', 'esbuild'), 'esbuild.exe'],
    versionOutput: '0.28.1',
  },
  {
    id: 'lightningcss',
    package: 'lightningcss-cli',
    version: '1.30.1',
    license: 'MPL-2.0',
    platformDirectory: 'node_modules',
    platformPrefix: 'lightningcss-cli-',
    executableCandidates: ['lightningcss', 'lightningcss.exe'],
    versionOutput: 'lightningcss 1.0.0-alpha.66',
  },
]

const manifest = {
  schemaVersion: 1,
  competitors: competitors.map(({ id, package: packageName, version, license, versionOutput }) => ({
    id,
    package: packageName,
    version,
    license,
    versionOutput,
  })),
}

const packageScripts = {
  'check:benchmark-tools': 'node scripts/validate-benchmark-toolchain.mjs --check',
  'test:benchmark-tools': 'node --test scripts/validate-benchmark-toolchain.test.mjs',
}

function fail(message) {
  throw new Error(`benchmark toolchain: ${message}`)
}

function compareAscii(left, right) {
  return left < right ? -1 : left > right ? 1 : 0
}

function requireRegularFile(file, label) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  return stat
}

function readJson(file, label) {
  requireRegularFile(file, label)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`)
  }
}

function lockKey(packageName) {
  return `node_modules/${packageName}`
}

function validateRegistryArchive(record, packageName) {
  if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(record?.integrity ?? '')) {
    fail(`lockfile entry for ${packageName} must have a SHA-512 integrity`)
  }
  let resolved
  try {
    resolved = new URL(record.resolved)
  } catch {
    fail(`lockfile entry for ${packageName} must have a valid resolved URL`)
  }
  if (
    resolved.protocol !== 'https:' ||
    resolved.hostname !== 'registry.npmjs.org' ||
    resolved.username !== '' ||
    resolved.password !== '' ||
    resolved.search !== '' ||
    resolved.hash !== '' ||
    !resolved.pathname.endsWith('.tgz')
  ) {
    fail(`lockfile entry for ${packageName} must resolve to a checksum-bound npm registry archive`)
  }
}

function validateLockedPackage(lock, packageName, version, license, optional) {
  const record = lock.packages?.[lockKey(packageName)]
  if (record?.version !== version) fail(`lockfile must pin ${packageName} to ${version}`)
  if (record.license !== license) fail(`lockfile must record ${license} for ${packageName}`)
  if (optional && record.optional !== true) fail(`platform package ${packageName} must remain optional`)
  validateRegistryArchive(record, packageName)
  return record
}

function confinedRealPath(root, file, label) {
  const canonicalRoot = fs.realpathSync(root)
  const canonicalFile = fs.realpathSync(file)
  const relative = path.relative(canonicalRoot, canonicalFile)
  if (relative.startsWith('..') || path.isAbsolute(relative)) fail(`${label} escapes the repository`)
  return canonicalFile
}

export function validateToolchainContract(root = repositoryRoot) {
  const manifestPath = path.join(root, 'benchmarks', 'toolchain.json')
  const actualManifest = readJson(manifestPath, 'benchmarks/toolchain.json')
  const expectedBytes = `${JSON.stringify(manifest, null, 2)}\n`
  if (fs.readFileSync(manifestPath, 'utf8') !== expectedBytes) {
    fail('manifest does not match the closed competitor inventory')
  }

  const packageJson = readJson(path.join(root, 'package.json'), 'package.json')
  const lock = readJson(path.join(root, 'package-lock.json'), 'package-lock.json')
  if (lock.lockfileVersion !== 3 || lock.packages?.[''] === undefined) {
    fail('package-lock.json must use lockfileVersion 3 with a root package')
  }

  for (const [name, command] of Object.entries(packageScripts)) {
    if (packageJson.scripts?.[name] !== command) fail(`package.json is missing the exact ${name} command`)
  }

  for (const competitor of competitors) {
    if (packageJson.devDependencies?.[competitor.package] !== competitor.version) {
      fail(`package.json must pin ${competitor.package} to ${competitor.version}`)
    }
    if (lock.packages[''].devDependencies?.[competitor.package] !== competitor.version) {
      fail(`lockfile root must pin ${competitor.package} to ${competitor.version}`)
    }
    const direct = validateLockedPackage(
      lock,
      competitor.package,
      competitor.version,
      competitor.license,
      false,
    )
    const optionalPackages = Object.entries(direct.optionalDependencies ?? {}).sort(([left], [right]) => compareAscii(left, right))
    if (optionalPackages.length === 0) fail(`${competitor.package} must declare platform-native packages`)
    for (const [packageName, version] of optionalPackages) {
      if (version !== competitor.version) {
        fail(`${competitor.package} platform package ${packageName} is not pinned to ${competitor.version}`)
      }
      validateLockedPackage(lock, packageName, competitor.version, competitor.license, true)
    }
  }

  return actualManifest
}

function installedPlatformPackage(root, competitor) {
  const directory = path.join(root, competitor.platformDirectory)
  let entries
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true })
  } catch (error) {
    fail(`preinstalled ${competitor.id} platform directory is unavailable: ${error.message}`)
  }
  const candidates = entries
    .filter(entry => entry.isDirectory() && !entry.isSymbolicLink())
    .map(entry => competitor.platformPrefix.startsWith('@') ? `${competitor.platformPrefix}${entry.name}` : entry.name)
    .filter(packageName => packageName.startsWith(competitor.platformPrefix))
    .sort(compareAscii)
  if (candidates.length !== 1) {
    fail(`expected one preinstalled ${competitor.id} platform package, found ${candidates.join(', ') || 'none'}`)
  }

  const packageName = candidates[0]
  const lock = readJson(path.join(root, 'package-lock.json'), 'package-lock.json')
  const direct = lock.packages?.[lockKey(competitor.package)]
  if (direct?.optionalDependencies?.[packageName] !== competitor.version) {
    fail(`preinstalled ${packageName} is not an owned ${competitor.package} platform package`)
  }
  validateLockedPackage(lock, packageName, competitor.version, competitor.license, true)
  const packageDirectory = path.join(root, lockKey(packageName))
  const packageJson = readJson(path.join(packageDirectory, 'package.json'), `${packageName}/package.json`)
  if (packageJson.name !== packageName || packageJson.version !== competitor.version) {
    fail(`preinstalled ${packageName} identity does not match ${competitor.version}`)
  }
  if (packageJson.license !== competitor.license) fail(`preinstalled ${packageName} license drifted`)
  if (!packageJson.os?.includes(process.platform) || !packageJson.cpu?.includes(process.arch)) {
    fail(`preinstalled ${packageName} does not match ${process.platform}-${process.arch}`)
  }

  const executables = competitor.executableCandidates
    .map(relative => path.join(packageDirectory, relative))
    .filter(file => fs.existsSync(file))
  if (executables.length !== 1) {
    fail(`expected one native executable in ${packageName}, found ${executables.length}`)
  }
  const executable = executables[0]
  const stat = requireRegularFile(executable, `${competitor.id} executable`)
  if (process.platform !== 'win32' && (stat.mode & 0o111) === 0) {
    fail(`${competitor.id} executable is not executable`)
  }
  const canonical = confinedRealPath(path.join(root, 'node_modules'), executable, `${competitor.id} executable`)
  return { packageName, executable: canonical }
}

export function verifyInstalledToolchain(root = repositoryRoot) {
  validateToolchainContract(root)
  const reports = []
  for (const competitor of competitors) {
    const installed = installedPlatformPackage(root, competitor)
    const result = spawnSync(installed.executable, ['--version'], {
      cwd: root,
      encoding: 'utf8',
      env: { NO_COLOR: '1' },
      maxBuffer: 64 * 1024,
      timeout: 5_000,
    })
    if (result.error) fail(`${competitor.id} version check failed to run: ${result.error.message}`)
    if (result.status !== 0 || result.signal !== null || result.stderr !== '') {
      fail(`${competitor.id} version check failed with status ${result.status}, signal ${result.signal}, stderr ${JSON.stringify(result.stderr)}`)
    }
    if (result.stdout.trim() !== competitor.versionOutput) {
      fail(`${competitor.id} version output drifted: ${JSON.stringify(result.stdout.trim())}`)
    }
    reports.push({
      id: competitor.id,
      version: competitor.version,
      package: installed.packageName,
      executable: installed.executable,
    })
  }
  return reports
}

export function validateBenchmarkWorkflow(root = repositoryRoot) {
  const workflow = fs.readFileSync(path.join(root, '.github', 'workflows', 'build.yml'), 'utf8')
  const install = workflow.indexOf('npm ci --ignore-scripts')
  const corpora = workflow.indexOf('- name: Validate benchmark corpora')
  const toolchain = workflow.indexOf('- name: Validate benchmark toolchain')
  const execution = workflow.indexOf('- name: Run validated benchmark smoke')
  const exactCommand = workflow.indexOf('npm run test:benchmark-tools && npm run check:benchmark-tools', toolchain)
  if (
    install === -1 ||
    corpora <= install ||
    toolchain <= corpora ||
    exactCommand <= toolchain ||
    execution <= exactCommand
  ) {
    fail('build workflow must verify locked local benchmark tools after corpora and before the validated smoke')
  }
  return true
}

function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--check') {
    fail('usage: node scripts/validate-benchmark-toolchain.mjs --check')
  }
  const tools = verifyInstalledToolchain(repositoryRoot)
  validateBenchmarkWorkflow(repositoryRoot)
  process.stdout.write(
    `Benchmark toolchain verified: ${tools.map(tool => `${tool.id} ${tool.version}`).join(', ')}; ${tools.length} local checksum-locked executables.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
