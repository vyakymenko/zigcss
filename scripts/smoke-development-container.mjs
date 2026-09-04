import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
export const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
export const maximumWaitMs = 240_000
export const writableMounts = Object.freeze([
  '/app/.zig-cache',
  '/app/bin',
  '/app/docs/node_modules',
  '/app/zig-cache',
  '/app/zig-out',
  '/home/node/.cache/zig',
])
const liveDirectories = Object.freeze(['src', 'docs/public', 'docs/src'])
const liveFiles = Object.freeze([
  'build.zig',
  'build.zig.zon',
  'build_helpers.zig',
  'docs/index.html',
  'docs/package.json',
  'docs/package-lock.json',
])

function fail(message) {
  throw new Error(`development container smoke: ${message}`)
}

export function expectedDevelopmentCompilerVersion(root = repositoryRoot) {
  const versionFile = path.join(root, 'VERSION')
  let stat
  try {
    stat = fs.lstatSync(versionFile)
  } catch (error) {
    fail(`VERSION is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail('VERSION must be a regular non-symlink file')
  const source = fs.readFileSync(versionFile, 'utf8')
  if (source !== `${source.trim()}\n`) fail('VERSION must contain one canonical newline-terminated value')
  return `zigcss ${parseReleaseVersion(source.trim(), 'development container version').value}`
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    timeout: options.timeout ?? 60_000,
    windowsHide: true,
    ...options,
  })
  if (result.error !== undefined) fail(`${command} failed to start: ${result.error.message}`)
  if (result.signal !== null) fail(`${command} terminated by ${result.signal}`)
  if (result.status !== 0) {
    fail(`${command} exited ${result.status}: ${(result.stderr || result.stdout).trim()}`)
  }
  return result.stdout.trim()
}

function compose(project, args, options = {}) {
  return run('docker', [
    'compose',
    '--project-name', project,
    '--file', 'docker-compose.dev.yml',
    ...args,
  ], options)
}

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds))
}

export function createLiveWorkspace() {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-dev-smoke-workspace-'))
  try {
    // mkdtemp creates the directory with mode 0700. Linux bind mounts preserve
    // that mode, so the container's non-root node user cannot traverse the
    // workspace unless we explicitly grant read/execute access. The bind mount
    // itself remains read-only and the temporary workspace contains only the
    // finite public source inventory copied below.
    fs.chmodSync(workspace, 0o755)
    for (const relative of liveDirectories) {
      fs.cpSync(path.join(repositoryRoot, relative), path.join(workspace, relative), {
        recursive: true,
        verbatimSymlinks: true,
      })
    }
    for (const relative of liveFiles) {
      const destination = path.join(workspace, relative)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      fs.copyFileSync(path.join(repositoryRoot, relative), destination)
    }
    return workspace
  } catch (error) {
    fs.rmSync(workspace, { recursive: true, force: true })
    throw error
  }
}

export function validateContainerInspection(inspection) {
  assert.equal(inspection.State?.Running, true, 'development container must be running')
  assert.equal(inspection.State?.Health?.Status, 'healthy', 'development container must be healthy')
  assert.equal(inspection.Config?.User, 'node', 'development container must run as the node user')

  const mounts = new Map((inspection.Mounts ?? []).map(mount => [mount.Destination, mount]))
  const source = mounts.get('/workspace')
  assert.equal(source?.Type, 'bind', 'source checkout must be a bind mount')
  assert.equal(source?.RW, false, 'source checkout bind must be read-only')
  const viteConfig = mounts.get('/app/docs/vite.config.ts')
  assert.equal(viteConfig?.Type, 'bind', 'live Vite config must be a bind mount')
  assert.equal(viteConfig?.RW, false, 'live Vite config bind must be read-only')
  for (const destination of writableMounts) {
    const mount = mounts.get(destination)
    assert.equal(mount?.Type, 'volume', `${destination} must be an isolated volume`)
    assert.equal(mount?.RW, true, `${destination} must be writable`)
  }
  assert.equal(mounts.size, writableMounts.length + 2, 'development container mount inventory drifted')
  return true
}

export function finishSmoke(outcome, primaryError, cleanupError) {
  if (primaryError !== undefined && cleanupError !== undefined) {
    throw new AggregateError(
      [primaryError, cleanupError],
      `development container smoke failed and cleanup also failed: ${primaryError.message}; ${cleanupError.message}`,
    )
  }
  if (primaryError !== undefined) throw primaryError
  if (cleanupError !== undefined) throw cleanupError
  return outcome
}

async function waitForHealth(containerId, composeProject) {
  const deadline = Date.now() + maximumWaitMs
  while (Date.now() < deadline) {
    const state = run('docker', [
      'inspect',
      '--format',
      '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}',
      containerId,
    ])
    if (state === 'running healthy') return
    if (state.startsWith('exited ') || state.startsWith('dead ')) {
      const logs = composeProject(['logs', '--no-color', 'dev'])
      fail(`container stopped before becoming healthy:\n${logs}`)
    }
    await sleep(2_000)
  }
  const logs = composeProject(['logs', '--no-color', 'dev'])
  fail(`container did not become healthy within ${maximumWaitMs}ms:\n${logs}`)
}

export function hasObservedRootInputRebuild(logs) {
  const rebuilds = logs.match(/Rebuilt in \d+ms/g) ?? []
  return logs.includes('Changed: build.zig') && rebuilds.length >= 2
}

async function waitForRootInputRebuild(composeProject) {
  const deadline = Date.now() + maximumWaitMs
  while (Date.now() < deadline) {
    const logs = composeProject(['logs', '--no-color', 'dev'])
    if (hasObservedRootInputRebuild(logs)) return
    await sleep(500)
  }
  const logs = composeProject(['logs', '--no-color', 'dev'])
  fail(`root build input did not trigger a second successful build within ${maximumWaitMs}ms:\n${logs}`)
}

export async function smokeDevelopmentContainer() {
  const suffix = crypto.randomBytes(6).toString('hex')
  const project = `zigcss-dev-smoke-${process.pid}-${suffix}`.toLowerCase()
  const liveWorkspace = createLiveWorkspace()
  const expectedCompilerVersion = expectedDevelopmentCompilerVersion()
  const composeEnvironment = {
    ...process.env,
    ZIGCSS_DEV_SOURCE_DIRECTORY: liveWorkspace,
  }
  const composeProject = (args, options = {}) => compose(project, args, {
    ...options,
    env: composeEnvironment,
  })
  let cleanupStarted = false
  const cleanup = () => {
    if (cleanupStarted) return
    cleanupStarted = true
    let dockerError
    try {
      composeProject(['down', '--volumes', '--remove-orphans', '--rmi', 'local'], { timeout: 120_000 })
    } catch (error) {
      dockerError = error
    }
    let workspaceError
    try {
      fs.rmSync(liveWorkspace, { recursive: true, force: true })
    } catch (error) {
      workspaceError = error
    }
    if (dockerError !== undefined && workspaceError !== undefined) {
      throw new AggregateError([dockerError, workspaceError], 'Docker and temporary workspace cleanup failed')
    }
    if (dockerError !== undefined) throw dockerError
    if (workspaceError !== undefined) throw workspaceError
  }
  const handleSignal = (signal) => {
    try {
      cleanup()
    } catch (error) {
      process.stderr.write(`${error.stack ?? error}\n`)
    }
    process.exit(signal === 'SIGINT' ? 130 : 143)
  }
  const handleSigint = () => handleSignal('SIGINT')
  const handleSigterm = () => handleSignal('SIGTERM')
  process.once('SIGINT', handleSigint)
  process.once('SIGTERM', handleSigterm)
  let outcome
  let primaryError
  try {
    run('docker', ['version', '--format', '{{.Server.Version}}'])
    run('docker', ['compose', 'version', '--short'])
    composeProject(['build', '--progress', 'plain', 'dev'], { timeout: 600_000 })

    const imageReference = `${project}-dev:latest`
    const imageId = run('docker', ['image', 'inspect', '--format', '{{.Id}}', imageReference])
    if (!/^sha256:[a-f0-9]{64}$/.test(imageId)) fail(`unexpected image identity ${JSON.stringify(imageId)}`)
    run('docker', [
      'run', '--rm', '--network', 'none', '--entrypoint', '/bin/sh', imageId, '-ec',
      [
        'test "$(id -u)" = 1000',
        'test "$(node --version)" = v22.22.0',
        'test "$(zig version)" = 0.15.2',
        'test -f /app/tests/preprocessors/stylus/corpus/files/upstream/cases/import.lookup/node_modules/lookup-b/package.json',
        'test ! -e /app/vscode-extension/.vscode',
        'test ! -e /app/release-assets',
      ].join(' && '),
    ], { timeout: 60_000 })

    composeProject(['up', '--detach', '--no-build', 'dev'], { timeout: 60_000 })
    const containerId = composeProject(['ps', '--quiet', 'dev'])
    if (!/^[a-f0-9]{64}$/.test(containerId)) fail(`unexpected container identity ${JSON.stringify(containerId)}`)
    await waitForHealth(containerId, composeProject)

    const inspections = JSON.parse(run('docker', ['inspect', containerId]))
    if (!Array.isArray(inspections) || inspections.length !== 1) fail('docker inspect returned an invalid container inventory')
    validateContainerInspection(inspections[0])

    composeProject([
      'exec', '--no-TTY', 'dev', '/bin/sh', '-ec',
      [
        'test "$(id -u)" = 1000',
        'test "$(node --version)" = v22.22.0',
        'test "$(zig version)" = 0.15.2',
        'test -f /app/bin/.zigcss-dev-ready',
        'test -x /app/bin/zigcss',
        `test "$(/app/bin/zigcss --version)" = "${expectedCompilerVersion}"`,
        'test -f /app/docs/node_modules/.zigcss-docs-inputs.sha256',
        'test "$(readlink /app/src)" = /workspace/src',
        'test "$(readlink /app/docs/src)" = /workspace/docs/src',
        'test "$(readlink /app/docs/public)" = /workspace/docs/public',
        'test "$(readlink /app/build.zig)" = /workspace/build.zig',
        'test "$(readlink /app/docs/package-lock.json)" = /workspace/docs/package-lock.json',
        'if printf probe > /workspace/.zigcss-dev-write-probe 2>/dev/null; then rm -f /workspace/.zigcss-dev-write-probe; exit 51; fi',
        'printf probe > /app/zig-out/.zigcss-dev-volume-probe',
        'rm /app/zig-out/.zigcss-dev-volume-probe',
      ].join(' && '),
    ], { timeout: 60_000 })

    fs.appendFileSync(path.join(liveWorkspace, 'build.zig'), '\n// development-container hot-rebuild probe\n')
    await waitForRootInputRebuild(composeProject)
    composeProject([
      'exec', '--no-TTY', 'dev', '/bin/sh', '-ec',
      [
        'test -f /app/bin/.zigcss-dev-ready',
        'test -x /app/bin/zigcss',
        `test "$(/app/bin/zigcss --version)" = "${expectedCompilerVersion}"`,
      ].join(' && '),
    ], { timeout: 60_000 })

    outcome = { mounts: writableMounts.length + 2, project }
  } catch (error) {
    primaryError = error
  }
  let cleanupError
  try {
    cleanup()
  } catch (error) {
    cleanupError = error
  } finally {
    process.removeListener('SIGINT', handleSigint)
    process.removeListener('SIGTERM', handleSigterm)
  }
  const result = finishSmoke(outcome, primaryError, cleanupError)
  process.stdout.write('Development container smoke passed: pinned image, complete source context, compiler-first startup, hot root-input rebuild, healthy runtime, read-only source, isolated writable volumes.\n')
  return result
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  if (process.argv.length !== 2) fail('this command accepts no arguments')
  await smokeDevelopmentContainer()
}
