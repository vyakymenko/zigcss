#!/usr/bin/env node

'use strict'

const crypto = require('crypto')
const fs = require('fs')
const https = require('https')
const path = require('path')
const { spawn, spawnSync } = require('child_process')
const { pipeline, Transform } = require('stream')

const VERSION = require('./package.json').version

const installLimits = Object.freeze({
  maximumArchiveBytes: 512 * 1024 * 1024,
  maximumBinaryBytes: 256 * 1024 * 1024,
  maximumManifestBytes: 64 * 1024,
  maximumRedirects: 5,
  maximumUrlBytes: 8 * 1024,
  requestTimeoutMs: 30 * 1000,
})

const targetPolicies = Object.freeze([
  Object.freeze({ platform: 'linux', arch: 'x64', target: 'x86_64-linux', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'linux', arch: 'arm64', target: 'aarch64-linux', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'darwin', arch: 'x64', target: 'x86_64-macos', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'darwin', arch: 'arm64', target: 'aarch64-macos', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'win32', arch: 'x64', target: 'x86_64-windows', binaryName: 'zigcss.exe', archiveExtension: 'zip' }),
])

const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/

function releaseDescriptor(version = VERSION, platform = process.platform, arch = process.arch) {
  if (typeof version !== 'string' || !semverPattern.test(version)) {
    throw new Error(`Release version is not canonical Semantic Versioning: ${JSON.stringify(version)}`)
  }
  const policy = targetPolicies.find(candidate => candidate.platform === platform && candidate.arch === arch)
  if (policy === undefined) {
    throw new Error(`Unsupported platform and architecture: ${platform} ${arch}`)
  }

  const base = `zigcss-v${version}-${policy.target}`
  const assets = Object.freeze({
    archive: `${base}.${policy.archiveExtension}`,
    sbom: `${base}.spdx.json`,
    checksums: `${base}.sha256`,
    provenanceBundle: `${base}.provenance.sigstore.jsonl`,
    sbomBundle: `${base}.sbom.sigstore.jsonl`,
  })
  const releaseUrl = `https://github.com/vyakymenko/zigcss/releases/download/v${version}`
  return Object.freeze({
    version,
    platform,
    arch,
    target: policy.target,
    binaryName: policy.binaryName,
    assets,
    archiveUrl: `${releaseUrl}/${assets.archive}`,
    checksumsUrl: `${releaseUrl}/${assets.checksums}`,
  })
}

function validateDownloadUrl(value) {
  if (typeof value !== 'string' || Buffer.byteLength(value) === 0 || Buffer.byteLength(value) > installLimits.maximumUrlBytes) {
    throw new Error('Release download URL is empty or exceeds its byte limit')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch (error) {
    throw new Error(`Release download URL is invalid: ${error.message}`)
  }
  if (parsed.protocol !== 'https:' || parsed.hostname.length === 0 || parsed.username !== '' || parsed.password !== '' || parsed.hash !== '') {
    throw new Error('Release download URL must use HTTPS without credentials or a fragment')
  }
  return parsed.href
}

function removePartial(filename) {
  try {
    fs.rmSync(filename, { force: true })
  } catch {
    // The original download error is more useful than a best-effort cleanup error.
  }
}

function boundedDownload(url, destination, maximumBytes, redirectCount = 0) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    return Promise.reject(new Error('Release download byte limit must be a positive safe integer'))
  }
  let validatedUrl
  try {
    validatedUrl = validateDownloadUrl(url)
  } catch (error) {
    return Promise.reject(error)
  }

  return new Promise((resolve, reject) => {
    let settled = false
    const succeed = () => {
      if (settled) return
      settled = true
      resolve()
    }
    const fail = error => {
      if (settled) return
      settled = true
      removePartial(destination)
      reject(error)
    }

    const request = https.get(validatedUrl, {
      headers: {
        Accept: 'application/octet-stream',
        'User-Agent': `zigcss-npm-installer/${VERSION}`,
      },
    }, response => {
      const status = response.statusCode ?? 0
      if ([301, 302, 303, 307, 308].includes(status)) {
        response.resume()
        if (redirectCount >= installLimits.maximumRedirects) {
          fail(new Error(`Release download exceeded ${installLimits.maximumRedirects} redirects`))
          return
        }
        const location = response.headers.location
        if (typeof location !== 'string' || location.length === 0) {
          fail(new Error(`Release download redirect ${status} did not include a location`))
          return
        }
        let redirected
        try {
          redirected = new URL(location, validatedUrl).href
          validateDownloadUrl(redirected)
        } catch (error) {
          fail(error)
          return
        }
        boundedDownload(redirected, destination, maximumBytes, redirectCount + 1).then(succeed, fail)
        return
      }

      if (status !== 200) {
        response.resume()
        fail(new Error(`Release download failed with HTTP ${status}`))
        return
      }

      const contentLength = response.headers['content-length']
      if (contentLength !== undefined) {
        if (!/^(?:0|[1-9]\d*)$/.test(contentLength)) {
          response.resume()
          fail(new Error('Release download returned an invalid Content-Length'))
          return
        }
        const advertised = Number(contentLength)
        if (!Number.isSafeInteger(advertised) || advertised > maximumBytes) {
          response.resume()
          fail(new Error(`Release download exceeds ${maximumBytes} bytes`))
          return
        }
      }

      let received = 0
      const limiter = new Transform({
        transform(chunk, _encoding, callback) {
          received += chunk.length
          if (received > maximumBytes) {
            callback(new Error(`Release download exceeds ${maximumBytes} bytes`))
          } else {
            callback(null, chunk)
          }
        },
      })
      const output = fs.createWriteStream(destination, { flags: 'wx', mode: 0o600 })
      pipeline(response, limiter, output, error => {
        if (error) fail(error)
        else succeed()
      })
    })

    request.setTimeout(installLimits.requestTimeoutMs, () => {
      request.destroy(new Error(`Release download timed out after ${installLimits.requestTimeoutMs} ms`))
    })
    request.on('error', fail)
  })
}

function parseChecksumManifest(text, archiveName, sbomName) {
  if (typeof text !== 'string' || Buffer.byteLength(text) > installLimits.maximumManifestBytes) {
    throw new Error('Release checksum manifest is not bounded text')
  }
  for (const name of [archiveName, sbomName]) {
    if (typeof name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
      throw new Error('Release checksum manifest expected filename is invalid')
    }
  }
  if (text.includes('\r') || text.includes('\0')) {
    throw new Error('Release checksum manifest contains invalid control bytes')
  }
  const lines = text.split('\n')
  if (lines.length !== 3 || lines[2] !== '') {
    throw new Error('Release checksum manifest must contain exactly two canonical lines and a final newline')
  }
  const expectedNames = [archiveName, sbomName]
  const digests = []
  for (let index = 0; index < expectedNames.length; index += 1) {
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$/.exec(lines[index])
    if (match === null || match[2] !== expectedNames[index]) {
      throw new Error(`Release checksum manifest line ${index + 1} does not match ${expectedNames[index]}`)
    }
    digests.push(match[1])
  }
  return digests[0]
}

function regularFile(filename, label, maximumBytes) {
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    throw new Error(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink file`)
  if (stat.size <= 0 || stat.size > maximumBytes) throw new Error(`${label} must contain 1 through ${maximumBytes} bytes`)
  return stat
}

function hashFileSha256(filename) {
  regularFile(filename, 'Downloaded release archive', installLimits.maximumArchiveBytes)
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(filename, 'r')
  const buffer = Buffer.allocUnsafe(64 * 1024)
  try {
    while (true) {
      const length = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (length === 0) break
      hash.update(buffer.subarray(0, length))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return hash.digest('hex')
}

function equalDigest(actual, expected) {
  if (!/^[0-9a-f]{64}$/.test(actual) || !/^[0-9a-f]{64}$/.test(expected)) return false
  return crypto.timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'))
}

function validateArchiveListing(listing, binaryName) {
  if (typeof listing !== 'string' || Buffer.byteLength(listing) > installLimits.maximumManifestBytes) {
    throw new Error('Release archive entry listing exceeds its byte limit')
  }
  const normalized = listing.replace(/\r\n/g, '\n')
  const lines = normalized.endsWith('\n') ? normalized.slice(0, -1).split('\n') : normalized.split('\n')
  if (lines.length !== 1 || lines[0] !== binaryName) {
    throw new Error(`Release archive must contain exactly the ${binaryName} entry`)
  }
}

function listArchive(archivePath, binaryName) {
  const result = spawnSync('tar', ['-tf', archivePath], {
    encoding: 'utf8',
    maxBuffer: installLimits.maximumManifestBytes,
    timeout: installLimits.requestTimeoutMs,
    windowsHide: true,
  })
  if (result.error !== undefined) throw new Error(`Failed to inspect release archive: ${result.error.message}`)
  if (result.status !== 0 || result.signal !== null) {
    throw new Error(`Failed to inspect release archive: ${result.stderr || result.signal || `exit ${result.status}`}`)
  }
  validateArchiveListing(result.stdout, binaryName)
}

function extractArchiveBinary(archivePath, destination, binaryName) {
  listArchive(archivePath, binaryName)
  return new Promise((resolve, reject) => {
    const child = spawn('tar', ['-xOf', archivePath, binaryName], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    })
    let stderr = ''
    let stderrBytes = 0
    let timeoutError = null
    child.stderr.on('data', chunk => {
      stderrBytes += chunk.length
      if (stderrBytes <= installLimits.maximumManifestBytes) stderr += chunk.toString('utf8')
      if (stderrBytes > installLimits.maximumManifestBytes) child.kill()
    })

    let received = 0
    const limiter = new Transform({
      transform(chunk, _encoding, callback) {
        received += chunk.length
        if (received > installLimits.maximumBinaryBytes) {
          callback(new Error(`Extracted release binary exceeds ${installLimits.maximumBinaryBytes} bytes`))
        } else {
          callback(null, chunk)
        }
      },
    })
    const output = fs.createWriteStream(destination, { flags: 'wx', mode: 0o700 })
    const pipeResult = new Promise((pipeResolve, pipeReject) => {
      pipeline(child.stdout, limiter, output, error => {
        if (error) pipeReject(error)
        else pipeResolve()
      })
    })
    const exitResult = new Promise((exitResolve, exitReject) => {
      child.on('error', exitReject)
      child.on('close', (code, signal) => {
        if (timeoutError !== null) exitReject(timeoutError)
        else if (stderrBytes > installLimits.maximumManifestBytes) exitReject(new Error('Archive extractor diagnostic exceeded its byte limit'))
        else if (code !== 0 || signal !== null) exitReject(new Error(`Archive extraction failed: ${stderr || signal || `exit ${code}`}`))
        else exitResolve()
      })
    })
    const timer = setTimeout(() => {
      timeoutError = new Error(`Archive extraction timed out after ${installLimits.requestTimeoutMs} ms`)
      child.kill()
    }, installLimits.requestTimeoutMs)

    Promise.all([pipeResult, exitResult]).then(() => {
      clearTimeout(timer)
      resolve()
    }, async error => {
      clearTimeout(timer)
      child.kill()
      await exitResult.catch(() => {})
      removePartial(destination)
      reject(error)
    })
  })
}

function readHeader(filename) {
  const stat = regularFile(filename, 'Extracted release binary', installLimits.maximumBinaryBytes)
  const length = Math.min(stat.size, 4096)
  const header = Buffer.alloc(length)
  const descriptor = fs.openSync(filename, 'r')
  try {
    fs.readSync(descriptor, header, 0, header.length, 0)
  } finally {
    fs.closeSync(descriptor)
  }
  return header
}

function inspectBinary(header) {
  if (header.length >= 20 && header.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))) {
    if (header[5] !== 1) throw new Error('Release ELF binary is not little-endian')
    const machine = header.readUInt16LE(18)
    if (machine === 62) return { format: 'elf', arch: 'x86_64' }
    if (machine === 183) return { format: 'elf', arch: 'aarch64' }
    throw new Error(`Release ELF binary has unsupported machine ${machine}`)
  }
  if (header.length >= 8 && header.readUInt32LE(0) === 0xfeedfacf) {
    const cpu = header.readUInt32LE(4)
    if (cpu === 0x01000007) return { format: 'macho', arch: 'x86_64' }
    if (cpu === 0x0100000c) return { format: 'macho', arch: 'aarch64' }
    throw new Error(`Release Mach-O binary has unsupported CPU ${cpu}`)
  }
  if (header.length >= 64 && header[0] === 0x4d && header[1] === 0x5a) {
    const peOffset = header.readUInt32LE(0x3c)
    if (peOffset + 6 > header.length || header.toString('binary', peOffset, peOffset + 4) !== 'PE\0\0') {
      throw new Error('Release PE binary has an invalid header offset')
    }
    const machine = header.readUInt16LE(peOffset + 4)
    if (machine === 0x8664) return { format: 'pe', arch: 'x86_64' }
    if (machine === 0xaa64) return { format: 'pe', arch: 'aarch64' }
    throw new Error(`Release PE binary has unsupported machine ${machine}`)
  }
  throw new Error('Release binary format is unsupported')
}

function assertBinaryMatchesTarget(filename, target) {
  const expected = {
    'x86_64-linux': { format: 'elf', arch: 'x86_64' },
    'aarch64-linux': { format: 'elf', arch: 'aarch64' },
    'x86_64-macos': { format: 'macho', arch: 'x86_64' },
    'aarch64-macos': { format: 'macho', arch: 'aarch64' },
    'x86_64-windows': { format: 'pe', arch: 'x86_64' },
  }[target]
  const actual = inspectBinary(readHeader(filename))
  if (expected === undefined || actual.format !== expected.format || actual.arch !== expected.arch) {
    throw new Error(`Release binary ${actual.format}/${actual.arch} does not match target ${target}`)
  }
  return actual
}

function canonicalDirectory(directory, label) {
  let stat
  try {
    stat = fs.lstatSync(directory)
  } catch (error) {
    throw new Error(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink directory`)
  return fs.realpathSync(directory)
}

function ensureBinDirectory(packageRoot) {
  const root = canonicalDirectory(packageRoot, 'npm package root')
  const binDirectory = path.join(root, 'bin')
  try {
    fs.mkdirSync(binDirectory, { mode: 0o755 })
  } catch (error) {
    if (error.code !== 'EEXIST') throw error
  }
  const bin = canonicalDirectory(binDirectory, 'npm binary directory')
  if (path.dirname(bin) !== root) throw new Error('npm binary directory escapes the package root')
  return bin
}

function replaceBinary(candidate, destination) {
  try {
    const stat = fs.lstatSync(destination)
    if (stat.isDirectory()) throw new Error('npm binary destination must not be a directory')
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  try {
    fs.renameSync(candidate, destination)
    return
  } catch (error) {
    if (process.platform !== 'win32' || !['EACCES', 'EEXIST', 'EPERM'].includes(error.code)) throw error
  }

  const backup = `${destination}.previous-${process.pid}-${crypto.randomBytes(6).toString('hex')}`
  let movedPrevious = false
  try {
    try {
      fs.renameSync(destination, backup)
      movedPrevious = true
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
    fs.renameSync(candidate, destination)
    if (movedPrevious) fs.rmSync(backup, { force: true })
  } catch (error) {
    if (movedPrevious) {
      try {
        fs.renameSync(backup, destination)
      } catch {
        // Report the original replacement failure; the backup remains beside the destination.
      }
    }
    throw error
  }
}

async function install(options = {}) {
  if (options === null || typeof options !== 'object') throw new Error('npm installer options must be an object')
  const descriptor = releaseDescriptor(
    options.version ?? VERSION,
    options.platform ?? process.platform,
    options.arch ?? process.arch,
  )
  const packageRoot = options.packageRoot ?? __dirname
  const downloadFile = options.downloadFile ?? boundedDownload
  const log = options.log ?? console.log
  if (typeof downloadFile !== 'function' || typeof log !== 'function') throw new Error('npm installer dependencies must be functions')

  const binDirectory = ensureBinDirectory(packageRoot)
  const temporary = fs.mkdtempSync(path.join(binDirectory, '.install-'))
  const manifestPath = path.join(temporary, descriptor.assets.checksums)
  const archivePath = path.join(temporary, descriptor.assets.archive)
  const candidate = path.join(temporary, `${descriptor.binaryName}.candidate`)
  const destination = path.join(binDirectory, descriptor.binaryName)

  log(`Downloading and verifying zigcss ${descriptor.version} for ${descriptor.target}...`)
  try {
    await downloadFile(descriptor.checksumsUrl, manifestPath, installLimits.maximumManifestBytes)
    regularFile(manifestPath, 'Release checksum manifest', installLimits.maximumManifestBytes)
    const expectedDigest = parseChecksumManifest(
      fs.readFileSync(manifestPath, 'utf8'),
      descriptor.assets.archive,
      descriptor.assets.sbom,
    )

    await downloadFile(descriptor.archiveUrl, archivePath, installLimits.maximumArchiveBytes)
    const actualDigest = hashFileSha256(archivePath)
    if (!equalDigest(actualDigest, expectedDigest)) {
      throw new Error('Release archive checksum does not match its SHA-256 manifest')
    }

    await extractArchiveBinary(archivePath, candidate, descriptor.binaryName)
    assertBinaryMatchesTarget(candidate, descriptor.target)
    if (descriptor.platform !== 'win32') fs.chmodSync(candidate, 0o755)
    replaceBinary(candidate, destination)
    log(`Verified and installed zigcss ${descriptor.version} for ${descriptor.target}`)
    return descriptor
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

async function main() {
  try {
    await install()
  } catch (error) {
    console.error(`zigcss installation failed: ${error.message}`)
    console.error('No unverified binary was installed. This prerelease may not have an asset for the current platform yet.')
    console.error('Build from source with the tested Zig 0.15.2 toolchain:')
    console.error('  git clone https://github.com/vyakymenko/zigcss.git')
    console.error('  cd zigcss && zig build -Doptimize=ReleaseFast')
    process.exitCode = 1
  }
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === __filename) {
  main()
}

module.exports = {
  assertBinaryMatchesTarget,
  boundedDownload,
  install,
  installLimits,
  parseChecksumManifest,
  releaseDescriptor,
  validateArchiveListing,
  validateDownloadUrl,
}
