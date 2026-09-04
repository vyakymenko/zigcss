#!/usr/bin/env node

'use strict'

const crypto = require('crypto')
const fs = require('fs')
const https = require('https')
const path = require('path')
const { spawn, spawnSync } = require('child_process')
const { performance } = require('perf_hooks')
const { pipeline, Transform } = require('stream')

const VERSION = require('./package.json').version

const installLimits = Object.freeze({
  archiveForceKillWaitMs: 1_000,
  archiveTerminationGraceMs: 1_000,
  maximumArchiveBytes: 512 * 1024 * 1024,
  maximumBinaryBytes: 256 * 1024 * 1024,
  maximumManifestBytes: 64 * 1024,
  maximumRedirects: 5,
  maximumUrlBytes: 8 * 1024,
  downloadDeadlineMs: 2 * 60 * 1000,
  requestTimeoutMs: 30 * 1000,
})

const targetPolicies = Object.freeze([
  Object.freeze({ platform: 'linux', arch: 'x64', target: 'x86_64-linux', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'linux', arch: 'arm64', target: 'aarch64-linux', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'darwin', arch: 'x64', target: 'x86_64-macos', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'darwin', arch: 'arm64', target: 'aarch64-macos', binaryName: 'zigcss', archiveExtension: 'tar.gz' }),
  Object.freeze({ platform: 'win32', arch: 'x64', target: 'x86_64-windows', binaryName: 'zigcss.exe', archiveExtension: 'zip' }),
])

const posixArchivePolicies = Object.freeze({
  darwin: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar']),
    resolved: Object.freeze(['/usr/bin/tar', '/usr/bin/bsdtar']),
  }),
  linux: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar', '/bin/tar']),
    // Alpine exposes tar as a root-owned /bin/tar -> /bin/busybox applet.
    // Keep the invocation path so BusyBox receives the required tar argv[0].
    resolved: Object.freeze([
      '/usr/bin/tar',
      '/bin/tar',
      '/usr/bin/bsdtar',
      '/bin/bsdtar',
      '/usr/bin/gtar',
      '/bin/gtar',
      '/usr/bin/busybox',
      '/bin/busybox',
    ]),
  }),
})

const posixArchiveEnvironment = Object.freeze({
  LANG: 'C',
  LC_ALL: 'C',
  PATH: '/usr/bin:/bin',
})

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

function boundedDownload(url, destination, maximumBytes, options = undefined) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    return Promise.reject(new Error('Release download byte limit must be a positive safe integer'))
  }
  if (options !== undefined && (options === null || typeof options !== 'object' || Array.isArray(options))) {
    return Promise.reject(new Error('Release download options must be an object'))
  }
  const deadlineMs = options?.deadlineMs ?? installLimits.downloadDeadlineMs
  if (!Number.isSafeInteger(deadlineMs) || deadlineMs <= 0 || deadlineMs > installLimits.downloadDeadlineMs) {
    return Promise.reject(new Error(
      `Release download deadline must be an integer from 1 through ${installLimits.downloadDeadlineMs} ms`,
    ))
  }
  return boundedDownloadStep(
    url,
    destination,
    maximumBytes,
    0,
    performance.now() + deadlineMs,
    deadlineMs,
  )
}

function boundedDownloadStep(url, destination, maximumBytes, redirectCount, deadline, deadlineMs) {
  let validatedUrl
  try {
    validatedUrl = validateDownloadUrl(url)
  } catch (error) {
    return Promise.reject(error)
  }

  return new Promise((resolve, reject) => {
    let settled = false
    let deadlineTimer = null
    const succeed = () => {
      if (settled) return
      settled = true
      if (deadlineTimer !== null) clearTimeout(deadlineTimer)
      resolve()
    }
    const fail = error => {
      if (settled) return
      settled = true
      if (deadlineTimer !== null) clearTimeout(deadlineTimer)
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
        if (deadlineTimer !== null) {
          clearTimeout(deadlineTimer)
          deadlineTimer = null
        }
        boundedDownloadStep(
          redirected,
          destination,
          maximumBytes,
          redirectCount + 1,
          deadline,
          deadlineMs,
        ).then(succeed, fail)
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
    const remaining = Math.ceil(deadline - performance.now())
    if (remaining <= 0) {
      request.destroy(new Error(`Release download exceeded its ${deadlineMs} ms total deadline`))
    } else {
      deadlineTimer = setTimeout(() => {
        request.destroy(new Error(`Release download exceeded its ${deadlineMs} ms total deadline`))
      }, remaining)
    }
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

function exactObjectKeys(value, expected, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`)
  }
  const actual = Object.keys(value).sort()
  const required = [...expected].sort()
  if (JSON.stringify(actual) !== JSON.stringify(required)) {
    throw new Error(`${label} must contain exactly ${required.join(', ')}`)
  }
}

function parseNativeIntegrityManifest(text, descriptor) {
  if (
    typeof text !== 'string'
    || Buffer.byteLength(text) === 0
    || Buffer.byteLength(text) > installLimits.maximumManifestBytes
    || text.includes('\0')
    || text.includes('\r')
  ) {
    throw new Error('npm package native integrity manifest is not bounded canonical text')
  }
  if (
    descriptor === null
    || typeof descriptor !== 'object'
    || typeof descriptor.version !== 'string'
    || typeof descriptor.target !== 'string'
    || descriptor.assets === null
    || typeof descriptor.assets !== 'object'
    || typeof descriptor.assets.archive !== 'string'
  ) {
    throw new Error('npm package native integrity descriptor is invalid')
  }

  let manifest
  try {
    manifest = JSON.parse(text)
  } catch (error) {
    throw new Error(`npm package native integrity manifest is invalid JSON: ${error.message}`)
  }
  exactObjectKeys(
    manifest,
    ['schemaVersion', 'package', 'version', 'sourceDateEpoch', 'archives'],
    'npm package native integrity manifest',
  )
  if (manifest.schemaVersion !== 1 || manifest.package !== 'zigcss') {
    throw new Error('npm package native integrity manifest has an unsupported identity')
  }
  if (manifest.version !== descriptor.version || !semverPattern.test(manifest.version)) {
    throw new Error(`npm package native integrity manifest does not bind version ${descriptor.version}`)
  }
  if (!Number.isSafeInteger(manifest.sourceDateEpoch) || manifest.sourceDateEpoch < 0 || manifest.sourceDateEpoch > 0xffff_ffff) {
    throw new Error('npm package native integrity manifest sourceDateEpoch is invalid')
  }
  if (!Array.isArray(manifest.archives) || manifest.archives.length !== targetPolicies.length) {
    throw new Error(`npm package native integrity manifest must contain exactly ${targetPolicies.length} archives`)
  }

  let selectedDigest
  for (let index = 0; index < targetPolicies.length; index += 1) {
    const policy = targetPolicies[index]
    const archive = manifest.archives[index]
    exactObjectKeys(archive, ['target', 'filename', 'sha256'], `npm package native integrity archive ${index + 1}`)
    const expectedFilename = `zigcss-v${manifest.version}-${policy.target}.${policy.archiveExtension}`
    if (archive.target !== policy.target || archive.filename !== expectedFilename) {
      throw new Error(`npm package native integrity archive ${index + 1} does not bind ${expectedFilename}`)
    }
    if (typeof archive.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(archive.sha256)) {
      throw new Error(`npm package native integrity archive ${index + 1} has an invalid SHA-256 digest`)
    }
    if (archive.target === descriptor.target) {
      if (archive.filename !== descriptor.assets.archive) {
        throw new Error(`npm package native integrity manifest does not bind ${descriptor.assets.archive}`)
      }
      selectedDigest = archive.sha256
    }
  }
  if (selectedDigest === undefined) {
    throw new Error(`npm package native integrity manifest does not bind target ${descriptor.target}`)
  }
  return selectedDigest
}

function readNativeIntegrityManifest(filename = path.join(__dirname, 'native-integrity.json')) {
  const label = 'npm package native integrity manifest'
  let before
  try {
    before = fs.lstatSync(filename, { bigint: true })
  } catch (error) {
    throw new Error(`${label} is unavailable: ${error.message}`)
  }
  if (!before.isFile() || before.isSymbolicLink()) throw new Error(`${label} must be a regular non-symlink file`)
  if (before.size <= 0n || before.size > BigInt(installLimits.maximumManifestBytes)) {
    throw new Error(`${label} must contain 1 through ${installLimits.maximumManifestBytes} bytes`)
  }

  const noFollow = fs.constants.O_NOFOLLOW ?? 0
  let file
  try {
    file = fs.openSync(filename, fs.constants.O_RDONLY | noFollow)
  } catch (error) {
    throw new Error(`${label} could not be opened safely: ${error.message}`)
  }
  try {
    const opened = fs.fstatSync(file, { bigint: true })
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) {
      throw new Error(`${label} changed before it could be read`)
    }
    if (opened.size <= 0n || opened.size > BigInt(installLimits.maximumManifestBytes)) {
      throw new Error(`${label} must contain 1 through ${installLimits.maximumManifestBytes} bytes`)
    }
    const bytes = Buffer.alloc(Number(opened.size))
    let offset = 0
    while (offset < bytes.length) {
      const length = fs.readSync(file, bytes, offset, bytes.length - offset, offset)
      if (length === 0) break
      offset += length
    }
    const after = fs.fstatSync(file, { bigint: true })
    if (
      offset !== bytes.length
      || after.dev !== opened.dev
      || after.ino !== opened.ino
      || after.size !== opened.size
      || after.mtimeNs !== opened.mtimeNs
      || after.ctimeNs !== opened.ctimeNs
    ) {
      throw new Error(`${label} changed while it was being read`)
    }
    const text = bytes.toString('utf8')
    if (!Buffer.from(text, 'utf8').equals(bytes)) throw new Error(`${label} must be valid UTF-8`)
    return text
  } finally {
    fs.closeSync(file)
  }
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

function trustedPosixArchiveExecutable(platform, fileSystem = fs) {
  const policy = posixArchivePolicies[platform]
  if (policy === undefined) throw new Error(`Unsupported archive platform: ${platform}`)

  for (const candidate of policy.candidates) {
    let descriptor
    try {
      const resolved = fileSystem.realpathSync(candidate)
      if (!path.posix.isAbsolute(resolved) || !policy.resolved.includes(resolved)) continue
      const before = fileSystem.lstatSync(resolved)
      if (!trustedPosixExecutableStat(before)) continue
      fileSystem.accessSync(resolved, fs.constants.X_OK)
      descriptor = fileSystem.openSync(
        resolved,
        fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
      )
      const opened = fileSystem.fstatSync(descriptor)
      const after = fileSystem.lstatSync(resolved)
      const resolvedAfter = fileSystem.realpathSync(candidate)
      if (
        resolvedAfter !== resolved
        || !trustedPosixExecutableStat(opened)
        || !trustedPosixExecutableStat(after)
        || !samePosixExecutableIdentity(before, opened)
        || !samePosixExecutableIdentity(opened, after)
      ) {
        continue
      }
      return candidate
    } catch {
      // Try only the next finite system candidate; never consult PATH.
    } finally {
      if (descriptor !== undefined) fileSystem.closeSync(descriptor)
    }
  }
  throw new Error(`No trusted system tar executable is available for ${platform}`)
}

function trustedPosixExecutableStat(stat) {
  return stat.isFile()
    && !stat.isSymbolicLink()
    && stat.uid === 0
    && (stat.mode & 0o022) === 0
    && (stat.mode & 0o111) !== 0
}

function samePosixExecutableIdentity(left, right) {
  return left.dev === right.dev
    && left.ino === right.ino
    && left.mode === right.mode
    && left.uid === right.uid
    && left.size === right.size
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs
}

const maximumSystemExecutableBytes = 256 * 1024 * 1024

function normalizedWindowsPathKey(input) {
  if (typeof input !== 'string') return null
  const withoutNamespace = /^\\\\\?\\[A-Za-z]:\\/.test(input) ? input.slice(4) : input
  let normalized = path.win32.normalize(withoutNamespace)
  const root = path.win32.parse(normalized).root
  while (normalized.length > root.length && /[\\/]$/.test(normalized)) {
    normalized = normalized.slice(0, -1)
  }
  return normalized.toLowerCase()
}

function sameWindowsPath(left, right) {
  const leftKey = normalizedWindowsPathKey(left)
  return leftKey !== null && leftKey === normalizedWindowsPathKey(right)
}

function canonicalWindowsPath(fileSystem, candidate) {
  const nativeRealpath = fileSystem.realpathSync?.native
  const resolver = typeof nativeRealpath === 'function' ? nativeRealpath : fileSystem.realpathSync
  if (typeof resolver !== 'function') throw new Error('canonical path resolution is unavailable')
  return Reflect.apply(resolver, fileSystem, [candidate])
}

function trustedWindowsDirectoryStat(stat) {
  return stat !== null && typeof stat === 'object'
    && typeof stat.isDirectory === 'function' && stat.isDirectory()
    && typeof stat.isSymbolicLink === 'function' && !stat.isSymbolicLink()
}

function trustedWindowsExecutableStat(stat) {
  if (
    stat === null || typeof stat !== 'object' ||
    typeof stat.isFile !== 'function' || !stat.isFile() ||
    typeof stat.isSymbolicLink !== 'function' || stat.isSymbolicLink()
  ) return false
  const size = stat.size
  return typeof size === 'bigint'
    ? size > 0n && size <= BigInt(maximumSystemExecutableBytes)
    : Number.isSafeInteger(size) && size > 0 && size <= maximumSystemExecutableBytes
}

function sameWindowsStatFields(left, right, fields) {
  return fields.every(name => left[name] !== undefined && right[name] !== undefined && left[name] === right[name])
}

function sameWindowsDirectoryIdentity(left, right) {
  return sameWindowsStatFields(left, right, ['dev', 'ino', 'mode'])
}

function sameWindowsExecutableIdentity(left, right) {
  return sameWindowsStatFields(left, right, [
    'dev',
    'ino',
    'mode',
    'nlink',
    'size',
    'mtimeNs',
    'ctimeNs',
  ])
}

function trustedWindowsSystemExecutable(systemRoot, executableName, fileSystem = fs) {
  if (
    typeof systemRoot !== 'string' || systemRoot.length === 0 || systemRoot.length > 32_767 ||
    /[\0-\x1f"]/.test(systemRoot) || !/^[A-Za-z]:[\\/]/.test(systemRoot) ||
    !path.win32.isAbsolute(systemRoot) || systemRoot.slice(2).includes(':')
  ) {
    throw new Error('Windows system root must be an absolute local drive path')
  }
  const normalizedRoot = path.win32.normalize(systemRoot)
  const driveRoot = path.win32.parse(normalizedRoot).root
  if (
    sameWindowsPath(normalizedRoot, driveRoot) ||
    !sameWindowsPath(path.win32.dirname(normalizedRoot), driveRoot) ||
    path.win32.basename(normalizedRoot).toLowerCase() !== 'windows'
  ) {
    throw new Error('Windows system root must identify the Windows directory')
  }

  const system32Candidate = path.win32.join(normalizedRoot, 'System32')
  const executableCandidate = path.win32.join(system32Candidate, executableName)
  let descriptor
  try {
    const resolvedRoot = canonicalWindowsPath(fileSystem, normalizedRoot)
    if (!sameWindowsPath(resolvedRoot, normalizedRoot)) throw new Error('system root is redirected')
    const rootBefore = fileSystem.lstatSync(resolvedRoot, { bigint: true })
    if (!trustedWindowsDirectoryStat(rootBefore)) throw new Error('system root is not a regular directory')

    const resolvedSystem32 = canonicalWindowsPath(fileSystem, system32Candidate)
    if (
      !sameWindowsPath(resolvedSystem32, system32Candidate) ||
      !sameWindowsPath(path.win32.dirname(resolvedSystem32), resolvedRoot)
    ) throw new Error('System32 is redirected or is not a direct system-root child')
    const system32Before = fileSystem.lstatSync(resolvedSystem32, { bigint: true })
    if (!trustedWindowsDirectoryStat(system32Before)) throw new Error('System32 is not a regular directory')

    const resolvedExecutable = canonicalWindowsPath(fileSystem, executableCandidate)
    if (
      !sameWindowsPath(resolvedExecutable, executableCandidate) ||
      !sameWindowsPath(path.win32.dirname(resolvedExecutable), resolvedSystem32)
    ) throw new Error(`${executableName} is redirected or is not a direct System32 child`)
    const before = fileSystem.lstatSync(resolvedExecutable, { bigint: true })
    if (!trustedWindowsExecutableStat(before)) throw new Error(`${executableName} is not a bounded regular file`)
    fileSystem.accessSync(resolvedExecutable, fs.constants.R_OK)
    descriptor = fileSystem.openSync(
      resolvedExecutable,
      fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0),
    )
    const opened = fileSystem.fstatSync(descriptor, { bigint: true })
    const after = fileSystem.lstatSync(resolvedExecutable, { bigint: true })
    const system32After = fileSystem.lstatSync(resolvedSystem32, { bigint: true })
    const rootAfter = fileSystem.lstatSync(resolvedRoot, { bigint: true })
    if (
      !trustedWindowsExecutableStat(opened) || !trustedWindowsExecutableStat(after) ||
      !sameWindowsExecutableIdentity(before, opened) ||
      !sameWindowsExecutableIdentity(opened, after) ||
      !trustedWindowsDirectoryStat(system32After) ||
      !sameWindowsDirectoryIdentity(system32Before, system32After) ||
      !trustedWindowsDirectoryStat(rootAfter) ||
      !sameWindowsDirectoryIdentity(rootBefore, rootAfter) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, normalizedRoot), resolvedRoot) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, system32Candidate), resolvedSystem32) ||
      !sameWindowsPath(canonicalWindowsPath(fileSystem, executableCandidate), resolvedExecutable)
    ) throw new Error(`${executableName} or its system directory changed identity`)
    return executableCandidate
  } catch (error) {
    throw new Error(`No trusted Windows system ${executableName} is available: ${error.message}`)
  } finally {
    if (descriptor !== undefined) fileSystem.closeSync(descriptor)
  }
}

function archiveExecutable(
  platform = process.platform,
  systemRoot = process.env.SystemRoot,
  fileSystem = fs,
) {
  if (platform === 'linux' || platform === 'darwin') {
    return trustedPosixArchiveExecutable(platform, fileSystem)
  }
  if (platform !== 'win32') throw new Error(`Unsupported archive platform: ${platform}`)
  // Git Bash can shadow Windows' ZIP-capable bsdtar with GNU tar.
  return trustedWindowsSystemExecutable(systemRoot, 'tar.exe', fileSystem)
}

function archiveProcessEnvironment(platform = process.platform) {
  return platform === 'linux' || platform === 'darwin'
    ? posixArchiveEnvironment
    : process.env
}

function listArchive(archivePath, binaryName, executable = archiveExecutable()) {
  const result = spawnSync(executable, ['-tf', archivePath], {
    cwd: path.dirname(archivePath),
    encoding: 'utf8',
    env: archiveProcessEnvironment(),
    killSignal: 'SIGKILL',
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

function boundedCloseWait(closeResult, isClosed, milliseconds) {
  if (isClosed()) return Promise.resolve(true)
  return new Promise(resolve => {
    let settled = false
    let timer
    const finish = value => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    timer = setTimeout(() => finish(false), milliseconds)
    closeResult.then(() => finish(true))
  })
}

async function terminateArchiveChild(child, closeResult, isClosed, terminationGraceMs, forceKillWaitMs) {
  try {
    child.kill('SIGTERM')
  } catch {
    // The process may already have exited between the failed operation and cleanup.
  }
  if (await boundedCloseWait(closeResult, isClosed, terminationGraceMs)) return
  try {
    child.kill('SIGKILL')
  } catch {
    // Cleanup remains bounded even if the platform refuses the force-kill request.
  }
  await boundedCloseWait(closeResult, isClosed, forceKillWaitMs)
}

function archiveExecutionOptions(options) {
  if (options === undefined) {
    return {
      forceKillWaitMs: installLimits.archiveForceKillWaitMs,
      spawnProcess: spawn,
      terminationGraceMs: installLimits.archiveTerminationGraceMs,
      timeoutMs: installLimits.requestTimeoutMs,
    }
  }
  if (options === null || typeof options !== 'object' || Array.isArray(options)) {
    throw new Error('Archive extraction options must be an object')
  }
  const result = {
    forceKillWaitMs: options.forceKillWaitMs ?? installLimits.archiveForceKillWaitMs,
    spawnProcess: options.spawnProcess ?? spawn,
    terminationGraceMs: options.terminationGraceMs ?? installLimits.archiveTerminationGraceMs,
    timeoutMs: options.timeoutMs ?? installLimits.requestTimeoutMs,
  }
  for (const [name, maximum] of [
    ['forceKillWaitMs', installLimits.archiveForceKillWaitMs],
    ['terminationGraceMs', installLimits.archiveTerminationGraceMs],
    ['timeoutMs', installLimits.requestTimeoutMs],
  ]) {
    if (!Number.isSafeInteger(result[name]) || result[name] <= 0 || result[name] > maximum) {
      throw new Error(`Archive extraction ${name} must be an integer from 1 through ${maximum} ms`)
    }
  }
  if (typeof result.spawnProcess !== 'function') throw new Error('Archive extraction spawn dependency must be a function')
  return result
}

async function runArchiveExtractor(executable, archivePath, destination, binaryName, options = undefined) {
  if (typeof executable !== 'string' || !path.isAbsolute(executable)) {
    throw new Error('Archive extractor executable must be an absolute path')
  }
  if (!path.isAbsolute(archivePath) || !path.isAbsolute(destination)) {
    throw new Error('Archive extraction paths must be absolute')
  }
  const execution = archiveExecutionOptions(options)
  const child = execution.spawnProcess(executable, ['-xOf', archivePath, binaryName], {
    cwd: path.dirname(archivePath),
    env: archiveProcessEnvironment(),
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  })
  let closed = false
  let stderr = ''
  let stderrBytes = 0
  let rejectDiagnostic
  const diagnosticResult = new Promise((_resolve, reject) => {
    rejectDiagnostic = reject
  })
  child.stderr.on('data', chunk => {
    stderrBytes += chunk.length
    if (stderrBytes <= installLimits.maximumManifestBytes) stderr += chunk.toString('utf8')
    if (stderrBytes > installLimits.maximumManifestBytes) {
      rejectDiagnostic(new Error('Archive extractor diagnostic exceeded its byte limit'))
    }
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
  let outputClosed = false
  let resolveOutputClose
  const outputCloseResult = new Promise(resolve => {
    resolveOutputClose = resolve
  })
  output.once('close', () => {
    outputClosed = true
    resolveOutputClose()
  })
  const pipeResult = new Promise((resolve, reject) => {
    pipeline(child.stdout, limiter, output, error => {
      if (error) reject(error)
      else resolve()
    })
  })
  let resolveClose
  const closeResult = new Promise(resolve => {
    resolveClose = resolve
  })
  const exitResult = new Promise((resolve, reject) => {
    child.once('error', reject)
    child.once('close', (code, signal) => {
      closed = true
      resolveClose()
      if (code !== 0 || signal !== null) {
        reject(new Error(`Archive extraction failed: ${stderr || signal || `exit ${code}`}`))
      } else {
        resolve()
      }
    })
  })
  let timer
  const timeoutResult = new Promise((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new Error(`Archive extraction timed out after ${execution.timeoutMs} ms`))
    }, execution.timeoutMs)
  })

  try {
    await Promise.race([
      Promise.all([pipeResult, exitResult]),
      diagnosticResult,
      timeoutResult,
    ])
  } catch (error) {
    clearTimeout(timer)
    const termination = terminateArchiveChild(
      child,
      closeResult,
      () => closed,
      execution.terminationGraceMs,
      execution.forceKillWaitMs,
    )
    child.stdout.destroy()
    child.stderr.destroy()
    output.destroy()
    await termination
    await boundedCloseWait(
      outputCloseResult,
      () => outputClosed,
      execution.forceKillWaitMs,
    )
    removePartial(destination)
    if (fs.existsSync(destination)) {
      throw new Error(`${error.message}; partial archive extraction could not be removed`)
    }
    throw error
  }
  clearTimeout(timer)
}

async function extractArchiveBinary(archivePath, destination, binaryName) {
  const executable = archiveExecutable()
  listArchive(archivePath, binaryName, executable)
  await runArchiveExtractor(executable, archivePath, destination, binaryName)
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
  const integrityManifestText = options.integrityManifestText ?? readNativeIntegrityManifest()
  const trustedArchiveDigest = parseNativeIntegrityManifest(integrityManifestText, descriptor)

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
    if (!equalDigest(expectedDigest, trustedArchiveDigest)) {
      throw new Error('Release checksum manifest does not match the independently published npm package digest')
    }

    await downloadFile(descriptor.archiveUrl, archivePath, installLimits.maximumArchiveBytes)
    const actualDigest = hashFileSha256(archivePath)
    if (!equalDigest(actualDigest, trustedArchiveDigest)) {
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
    console.error('No unverified binary was installed. This release may not have an asset for the current platform yet.')
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
  archiveExecutable,
  assertBinaryMatchesTarget,
  boundedDownload,
  install,
  installLimits,
  parseChecksumManifest,
  parseNativeIntegrityManifest,
  readNativeIntegrityManifest,
  releaseDescriptor,
  runArchiveExtractor,
  validateArchiveListing,
  validateDownloadUrl,
}
