#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)
const require = createRequire(import.meta.url)
const installer = require('../install.js')

const linuxTargets = Object.freeze({
  'x86_64-linux': Object.freeze({ platform: 'linux', arch: 'x64' }),
  'aarch64-linux': Object.freeze({ platform: 'linux', arch: 'arm64' }),
})
const maximumMetadataBytes = 16 * 1024 * 1024

function fail(message) {
  throw new Error(`release container preparation: ${message}`)
}

function canonicalDirectory(directory, label) {
  if (typeof directory !== 'string' || directory.length === 0 || directory.includes('\0')) {
    fail(`${label} must be a nonempty path without NUL bytes`)
  }
  let stat
  try {
    stat = fs.lstatSync(directory)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink directory`)
  return fs.realpathSync(directory)
}

function confinedRegularFile(root, filename, label, maximumBytes) {
  const candidate = path.join(root, filename)
  let stat
  try {
    stat = fs.lstatSync(candidate)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size <= 0 || stat.size > maximumBytes) fail(`${label} must contain 1 through ${maximumBytes} bytes`)
  const canonical = fs.realpathSync(candidate)
  const relative = path.relative(root, canonical)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes the release asset directory`)
  }
  return { path: canonical, size: stat.size }
}

function packageVersion(root) {
  const manifest = confinedRegularFile(root, 'package.json', 'package manifest', 1024 * 1024)
  let parsed
  try {
    parsed = JSON.parse(fs.readFileSync(manifest.path, 'utf8'))
  } catch (error) {
    fail(`package manifest is invalid JSON: ${error.message}`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed) || typeof parsed.version !== 'string') {
    fail('package manifest must contain a string version')
  }
  return parsed.version
}

function outputPath(root, relativePath) {
  if (typeof relativePath !== 'string' || !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(relativePath)) {
    fail('output directory must be one portable relative basename of at most 64 bytes')
  }
  const output = path.join(root, relativePath)
  try {
    fs.lstatSync(output)
  } catch (error) {
    if (error.code === 'ENOENT') return output
    fail(`output directory cannot be inspected: ${error.message}`)
  }
  fail('output directory must not already exist')
}

function exactEntries(directory, expected, label) {
  const actual = fs.readdirSync(directory).sort()
  const sortedExpected = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(sortedExpected)) {
    fail(`${label} must contain exactly ${sortedExpected.join(', ')}`)
  }
}

function sha256(filename) {
  return crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex')
}

export async function prepareReleaseContainer(options) {
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    fail('options must be an object')
  }
  const root = canonicalDirectory(options.root, 'release container root')
  const policy = linuxTargets[options.target]
  if (policy === undefined) fail(`target must be one of ${Object.keys(linuxTargets).join(', ')}`)
  if (packageVersion(root) !== options.version) fail('requested version must match the package manifest')

  const descriptor = installer.releaseDescriptor(options.version, policy.platform, policy.arch)
  if (descriptor.target !== options.target || descriptor.binaryName !== 'zigcss') {
    fail('release descriptor does not match the requested Linux target')
  }

  const assetsRoot = canonicalDirectory(path.join(root, 'release-assets'), 'release asset directory')
  const sbom = confinedRegularFile(assetsRoot, descriptor.assets.sbom, 'release SBOM', maximumMetadataBytes)
  confinedRegularFile(assetsRoot, descriptor.assets.provenanceBundle, 'release provenance bundle', maximumMetadataBytes)
  confinedRegularFile(assetsRoot, descriptor.assets.sbomBundle, 'release SBOM bundle', maximumMetadataBytes)
  const checksums = confinedRegularFile(
    assetsRoot,
    descriptor.assets.checksums,
    'release checksum manifest',
    installer.installLimits.maximumManifestBytes,
  )
  const checksumText = fs.readFileSync(checksums.path, 'utf8')
  installer.parseChecksumManifest(checksumText, descriptor.assets.archive, descriptor.assets.sbom)
  const expectedSbomDigest = checksumText.split('\n')[1].slice(0, 64)
  if (sha256(sbom.path) !== expectedSbomDigest) fail('release SBOM checksum does not match its manifest')
  const localAssets = new Map([
    [
      descriptor.checksumsUrl,
      checksums,
    ],
    [
      descriptor.archiveUrl,
      confinedRegularFile(
        assetsRoot,
        descriptor.assets.archive,
        'release archive',
        installer.installLimits.maximumArchiveBytes,
      ),
    ],
  ])
  exactEntries(
    assetsRoot,
    Object.values(descriptor.assets),
    'release asset directory',
  )

  const output = outputPath(root, options.outputDirectory)
  fs.mkdirSync(output, { mode: 0o755 })
  try {
    const downloaded = []
    const result = await installer.install({
      version: options.version,
      platform: policy.platform,
      arch: policy.arch,
      packageRoot: output,
      downloadFile: async (url, destination, maximumBytes) => {
        const source = localAssets.get(url)
        if (source === undefined) fail(`installer requested unexpected asset ${url}`)
        if (source.size > maximumBytes) fail(`installer limit for ${path.basename(source.path)} is too small`)
        fs.copyFileSync(source.path, destination, fs.constants.COPYFILE_EXCL)
        downloaded.push(url)
      },
      log() {},
    })
    if (result.target !== descriptor.target) fail('installer returned the wrong release target')
    if (JSON.stringify(downloaded) !== JSON.stringify([descriptor.checksumsUrl, descriptor.archiveUrl])) {
      fail('installer did not consume the checksum manifest before the archive')
    }

    const binDirectory = path.join(output, 'bin')
    const binary = path.join(binDirectory, descriptor.binaryName)
    exactEntries(output, ['bin'], 'release container root')
    exactEntries(binDirectory, [descriptor.binaryName], 'release container binary directory')
    installer.assertBinaryMatchesTarget(binary, descriptor.target)
    fs.chmodSync(binary, 0o555)
    return Object.freeze({
      binary,
      outputDirectory: output,
      target: descriptor.target,
      version: descriptor.version,
    })
  } catch (error) {
    fs.rmSync(output, { recursive: true, force: true })
    throw error
  }
}

function parseOptions(args) {
  const allowed = new Set(['--root', '--output-directory', '--target', '--version'])
  if (args.length !== allowed.size * 2) fail('CLI requires root, output directory, target, and version')
  const values = {}
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!allowed.has(name) || value === undefined || Object.hasOwn(values, name)) {
      fail(`invalid or repeated option ${name}`)
    }
    values[name] = value
  }
  return {
    root: values['--root'],
    outputDirectory: values['--output-directory'],
    target: values['--target'],
    version: values['--version'],
  }
}

async function main() {
  try {
    const result = await prepareReleaseContainer(parseOptions(process.argv.slice(2)))
    process.stdout.write(`Prepared verified ZigCSS ${result.version} container root for ${result.target}.\n`)
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) await main()
