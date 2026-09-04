#!/usr/bin/env node

import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { releaseAssetsFor, releaseTargets } from './generate-release-metadata.mjs'
import { assertArtifactMatchesTarget } from './verify-artifact-target.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const repositoryRoot = path.resolve(path.dirname(scriptPath), '..')
const version = fs.readFileSync(path.join(repositoryRoot, 'VERSION'), 'utf8').trim()
const maximumOutputBytes = 8 * 1024 * 1024
const defaultTimeoutMs = 5 * 60 * 1000

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repositoryRoot,
    encoding: 'utf8',
    env: { ...process.env, ...options.env },
    input: options.input,
    maxBuffer: maximumOutputBytes,
    timeout: options.timeoutMs ?? defaultTimeoutMs,
  })
  if (result.error !== undefined) {
    throw new Error(`${command} failed to start: ${result.error.message}`)
  }
  if (result.status !== 0 || result.signal !== null) {
    throw new Error([
      `${command} ${args.join(' ')} failed with ${result.signal ?? `exit ${result.status}`}`,
      result.stdout,
      result.stderr,
    ].filter(Boolean).join('\n'))
  }
  return result.stdout
}

export function finishReleaseContainerSmoke(outcome, primaryError, cleanupErrors = []) {
  const failures = [primaryError, ...cleanupErrors].filter(error => error !== undefined)
  if (failures.length === 1) throw failures[0]
  if (failures.length > 1) {
    throw new AggregateError(
      failures,
      `release container verification failed and cleanup also failed: ${failures.map(error => error.message).join('; ')}`,
    )
  }
  return outcome
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex')
}

function copyContextFile(context, relativePath) {
  const destination = path.join(context, relativePath)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.copyFileSync(path.join(repositoryRoot, relativePath), destination, fs.constants.COPYFILE_EXCL)
}

function executable(filename) {
  try {
    const stat = fs.lstatSync(filename)
    fs.accessSync(filename, fs.constants.X_OK)
    return stat.isFile() && !stat.isSymbolicLink()
  } catch {
    return false
  }
}

function findZig() {
  const pathEntries = (process.env.PATH ?? '').split(path.delimiter)
  for (const entry of pathEntries.slice(0, 1024)) {
    if (entry.length === 0 || !path.isAbsolute(entry)) continue
    const candidate = path.join(entry, process.platform === 'win32' ? 'zig.exe' : 'zig')
    if (executable(candidate)) return candidate
  }

  const localRoot = path.join(os.homedir(), '.local', 'share', 'zig')
  let entries = []
  try {
    entries = fs.readdirSync(localRoot, { withFileTypes: true })
  } catch {
    // The required tool error below is more useful than an optional fallback error.
  }
  for (const entry of entries.filter(item => item.isDirectory()).sort((left, right) => left.name.localeCompare(right.name))) {
    const candidate = path.join(localRoot, entry.name, process.platform === 'win32' ? 'zig.exe' : 'zig')
    if (executable(candidate) && run(candidate, ['version']).trim() === '0.15.2') return candidate
  }
  throw new Error('tested Zig 0.15.2 executable is unavailable')
}

function findBuildxPlugin() {
  const candidates = [
    path.join(os.homedir(), '.docker', 'cli-plugins', 'docker-buildx'),
    '/Applications/Docker.app/Contents/Resources/cli-plugins/docker-buildx',
    '/usr/local/lib/docker/cli-plugins/docker-buildx',
    '/usr/local/libexec/docker/cli-plugins/docker-buildx',
    '/usr/lib/docker/cli-plugins/docker-buildx',
    '/usr/libexec/docker/cli-plugins/docker-buildx',
  ]
  for (const candidate of candidates) {
    let canonical
    try {
      canonical = fs.realpathSync(candidate)
    } catch {
      continue
    }
    if (executable(canonical)) return canonical
  }
  throw new Error('Docker Buildx plugin is unavailable')
}

function dockerPolicy() {
  const architecture = run('docker', ['info', '--format', '{{.Architecture}}']).trim()
  const policy = {
    amd64: { dockerPlatform: 'linux/amd64', target: 'x86_64-linux' },
    x86_64: { dockerPlatform: 'linux/amd64', target: 'x86_64-linux' },
    arm64: { dockerPlatform: 'linux/arm64', target: 'aarch64-linux' },
    aarch64: { dockerPlatform: 'linux/arm64', target: 'aarch64-linux' },
  }[architecture]
  if (policy === undefined) throw new Error(`unsupported Docker daemon architecture ${JSON.stringify(architecture)}`)
  return policy
}

function zigBuildEnvironment(workspace) {
  if (process.platform !== 'darwin') return {}
  const sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
  if (!fs.existsSync(sdk)) return {}
  const wrapperDirectory = path.join(workspace, 'sdk-wrapper')
  const wrapper = path.join(wrapperDirectory, 'xcrun')
  fs.mkdirSync(wrapperDirectory)
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

function buildFixture(context, policy) {
  const workspace = path.dirname(context)
  const prefix = path.join(workspace, 'zig-prefix')
  run(findZig(), [
    'build',
    `-Dtarget=${policy.target}`,
    '-Doptimize=ReleaseFast',
    '--prefix',
    prefix,
    '--cache-dir',
    path.join(workspace, 'zig-cache'),
    '--global-cache-dir',
    path.join(workspace, 'zig-global-cache'),
    '--summary',
    'none',
  ], { env: zigBuildEnvironment(workspace) })
  const binary = path.join(prefix, 'bin', 'zigcss')
  assert.deepEqual(assertArtifactMatchesTarget(fs.readFileSync(binary), policy.target), {
    arch: policy.target.split('-')[0],
    format: 'elf',
  })

  const releaseAssets = path.join(context, 'release-assets')
  const staging = path.join(workspace, 'archive-staging')
  fs.mkdirSync(releaseAssets)
  fs.mkdirSync(staging)
  fs.copyFileSync(binary, path.join(staging, 'zigcss'))
  fs.chmodSync(path.join(staging, 'zigcss'), 0o755)

  const assets = releaseAssetsFor(version, policy.target)
  const archive = path.join(releaseAssets, assets.archive)
  run('tar', ['-czf', archive, '-C', staging, 'zigcss'], {
    env: { COPYFILE_DISABLE: '1' },
  })
  const sbom = Buffer.from('{"spdxVersion":"SPDX-2.3"}\n')
  const archiveDigest = sha256(fs.readFileSync(archive))
  fs.writeFileSync(path.join(context, 'native-integrity.json'), `${JSON.stringify({
    schemaVersion: 1,
    package: 'zigcss',
    version,
    sourceDateEpoch: 1_700_000_000,
    archives: releaseTargets.map(target => ({
      target: target.target,
      filename: releaseAssetsFor(version, target.target).archive,
      sha256: target.target === policy.target ? archiveDigest : '0'.repeat(64),
    })),
  }, null, 2)}\n`)
  fs.writeFileSync(path.join(releaseAssets, assets.sbom), sbom)
  fs.writeFileSync(path.join(releaseAssets, assets.checksums), [
    `${archiveDigest}  ${assets.archive}`,
    `${sha256(sbom)}  ${assets.sbom}`,
    '',
  ].join('\n'))
  fs.writeFileSync(path.join(releaseAssets, assets.provenanceBundle), '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n')
  fs.writeFileSync(path.join(releaseAssets, assets.sbomBundle), '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n')
}

function main() {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-image-'))
  const context = path.join(temporary, 'context')
  const dockerConfig = path.join(temporary, 'docker-config')
  const buildxConfig = path.join(temporary, 'buildx-config')
  const image = `zigcss-release-contract:${process.pid}-${crypto.randomBytes(4).toString('hex')}`
  let imageCreated = false
  let outcome
  let primaryError
  try {
    fs.mkdirSync(context)
    fs.mkdirSync(dockerConfig)
    fs.mkdirSync(buildxConfig)
    const pluginDirectory = path.join(dockerConfig, 'cli-plugins')
    fs.mkdirSync(pluginDirectory)
    fs.symlinkSync(findBuildxPlugin(), path.join(pluginDirectory, 'docker-buildx'))
    const dockerEnvironment = {
      BUILDX_CONFIG: buildxConfig,
      DOCKER_BUILDKIT: '1',
      DOCKER_CONFIG: dockerConfig,
    }
    for (const relativePath of [
      'Dockerfile.release',
      'Dockerfile.release.dockerignore',
      'install.js',
      'package.json',
      'scripts/prepare-release-container.mjs',
    ]) {
      copyContextFile(context, relativePath)
    }

    const policy = dockerPolicy()
    buildFixture(context, policy)
    run('docker', [
      'build',
      '--quiet',
      '--platform',
      policy.dockerPlatform,
      '--build-arg',
      `ZIGCSS_VERSION=${version}`,
      '--tag',
      image,
      '--file',
      path.join(context, 'Dockerfile.release'),
      context,
    ], { env: dockerEnvironment })
    imageCreated = true

    assert.equal(
      run('docker', ['run', '--rm', '--network', 'none', image, '--version'], { env: dockerEnvironment }),
      `zigcss ${version}\n`,
    )
    const [inspection] = JSON.parse(run('docker', ['image', 'inspect', image], { env: dockerEnvironment }))
    assert.equal(inspection.Architecture, policy.dockerPlatform.split('/')[1])
    assert.equal(inspection.Os, 'linux')
    assert.equal(inspection.Config.User, '65532:65532')
    assert.deepEqual(inspection.Config.Entrypoint, ['/usr/local/bin/zigcss'])
    assert.deepEqual(inspection.Config.Cmd, ['--help'])
    assert.equal(inspection.Config.Labels['org.opencontainers.image.version'], version)
    assert.equal(inspection.Config.Labels['org.opencontainers.image.source'], 'https://github.com/vyakymenko/zigcss')
    assert.equal(inspection.RootFS.Layers.length, 1)
    outcome = { dockerPlatform: policy.dockerPlatform }
  } catch (error) {
    primaryError = error
  }

  const cleanupErrors = []
  if (imageCreated) {
    try {
      run('docker', ['image', 'rm', '--force', image], {
        env: { BUILDX_CONFIG: buildxConfig, DOCKER_CONFIG: dockerConfig },
      })
    } catch (error) {
      cleanupErrors.push(error)
    }
  }
  try {
    fs.rmSync(temporary, { recursive: true, force: true })
  } catch (error) {
    cleanupErrors.push(error)
  }
  const result = finishReleaseContainerSmoke(outcome, primaryError, cleanupErrors)
  process.stdout.write(`Verified local ${result.dockerPlatform} release image from the canonical archive and manifest.\n`)
  return result
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  try {
    main()
  } catch (error) {
    console.error(`release container verification failed: ${error.message}`)
    process.exitCode = 1
  }
}
