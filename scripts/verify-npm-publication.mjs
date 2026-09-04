import { spawnSync } from 'node:child_process'
import https from 'node:https'
import path from 'node:path'
import { setTimeout as wait } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import {
  inspectNpmPackageArchive,
  inspectNpmPackageBytes,
  npmPackageArtifactLimits,
} from './npm-package-artifact.mjs'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const registry = 'https://registry.npmjs.org/'
const maximumResponseBytes = 256 * 1024
const downloadTimeoutMs = 30_000
export const npmPublicationReadbackPolicy = Object.freeze({
  attempts: 12,
  delayMs: 5_000,
})

function fail(message) {
  throw new Error(`npm publication readback: ${message}`)
}

function parseJson(source, label) {
  if (typeof source !== 'string' || source.length === 0 || source.length > maximumResponseBytes) {
    fail(`${label} is empty or oversized`)
  }
  try {
    return JSON.parse(source)
  } catch (error) {
    fail(`${label} is not JSON: ${error.message}`)
  }
}

function validateExpectedPackage(value, version) {
  if (
    value === null
    || typeof value !== 'object'
    || Array.isArray(value)
    || value.name !== 'zigcss'
    || value.version !== version
    || value.filename !== `zigcss-${version}.tgz`
    || !/^[0-9a-f]{40}$/.test(value.shasum)
    || !/^sha512-[A-Za-z0-9+/]+={0,2}$/.test(value.integrity)
  ) {
    fail('tested package artifact identity is invalid')
  }
  const digest = Buffer.from(value.integrity.slice('sha512-'.length), 'base64')
  if (digest.length !== 64) fail('tested package artifact integrity is malformed')
  return value
}

function validateTarballUrl(value, version, filename) {
  if (typeof value !== 'string' || Buffer.byteLength(value) > 8 * 1024) {
    fail('published tarball URL is empty or oversized')
  }
  let parsed
  try {
    parsed = new URL(value)
  } catch (error) {
    fail(`published tarball URL is invalid: ${error.message}`)
  }
  const expected = `/zigcss/-/${filename}`
  if (
    parsed.protocol !== 'https:'
    || parsed.hostname !== 'registry.npmjs.org'
    || parsed.port !== ''
    || parsed.pathname !== expected
    || parsed.username !== ''
    || parsed.password !== ''
    || parsed.search !== ''
    || parsed.hash !== ''
  ) {
    fail(`published tarball URL must be https://registry.npmjs.org${expected}`)
  }
  parseReleaseVersion(version, 'published tarball version')
  return parsed.href
}

export function validateNpmPublicationReadback(
  version,
  versionSource,
  tagsSource,
  distSource,
  expectedPackage,
) {
  const parsedVersion = parseReleaseVersion(version, 'npm publication version')
  const channel = parsedVersion.prerelease === null ? 'latest' : 'next'
  const expected = validateExpectedPackage(expectedPackage, version)

  const publishedVersion = parseJson(versionSource, 'published version response')
  if (publishedVersion !== version) {
    fail(`published version must be ${version}, received ${JSON.stringify(publishedVersion)}`)
  }

  const tags = parseJson(tagsSource, 'distribution-tag response')
  if (tags === null || typeof tags !== 'object' || Array.isArray(tags)) {
    fail('distribution tags must be a JSON object')
  }
  const entries = Object.entries(tags)
  if (entries.length === 0 || entries.length > 100) {
    fail('distribution tags must be a bounded non-empty object')
  }
  const parsedTags = new Map()
  for (const [name, value] of entries) {
    if (!/^[a-z][a-z0-9._-]{0,63}$/.test(name) || typeof value !== 'string') {
      fail('distribution tags contain an invalid name or non-string version')
    }
    parsedTags.set(name, parseReleaseVersion(value, `npm distribution tag ${name}`))
  }
  if (tags[channel] !== version) {
    fail(`${channel} tag must be ${version}, received ${JSON.stringify(tags[channel])}`)
  }
  if (channel === 'next') {
    if (!parsedTags.has('latest') || parsedTags.get('latest').prerelease !== null) {
      fail('prerelease publication must retain a stable latest tag')
    }
  } else if (!parsedTags.has('next') || parsedTags.get('next').prerelease === null) {
    fail('stable publication must retain a prerelease next tag')
  }

  const dist = parseJson(distSource, 'distribution metadata response')
  if (dist === null || typeof dist !== 'object' || Array.isArray(dist)) {
    fail('distribution metadata must be a JSON object')
  }
  const distKeys = Object.keys(dist)
  if (distKeys.length < 3 || distKeys.length > 32) {
    fail('distribution metadata must be a bounded object')
  }
  if (dist.shasum !== expected.shasum) {
    fail(`published shasum must be ${expected.shasum}, received ${JSON.stringify(dist.shasum)}`)
  }
  if (dist.integrity !== expected.integrity) {
    fail(`published integrity must be ${expected.integrity}, received ${JSON.stringify(dist.integrity)}`)
  }
  const tarballUrl = validateTarballUrl(dist.tarball, version, expected.filename)
  return { version, channel, tarballUrl }
}

function runNpmView(args, label) {
  const executable = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const result = spawnSync(executable, [...args, '--json', `--registry=${registry}`], {
    encoding: 'utf8',
    maxBuffer: maximumResponseBytes,
    timeout: 30_000,
  })
  if (result.error !== undefined) {
    throw new Error(`${label} failed to start: ${result.error.message}`)
  }
  if (result.signal !== null || result.status !== 0) {
    throw new Error(`${label} failed with ${result.signal ?? `exit ${result.status}`}`)
  }
  return result.stdout
}

function readRegistry(version) {
  return {
    versionSource: runNpmView(['view', `zigcss@${version}`, 'version'], 'published version lookup'),
    tagsSource: runNpmView(['view', 'zigcss', 'dist-tags'], 'distribution-tag lookup'),
    distSource: runNpmView(['view', `zigcss@${version}`, 'dist'], 'distribution metadata lookup'),
  }
}

function downloadRegistryTarball(url, maximumBytes = npmPackageArtifactLimits.archiveBytes) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0 || maximumBytes > npmPackageArtifactLimits.archiveBytes) {
    return Promise.reject(new Error('registry tarball byte limit is invalid'))
  }
  let validated
  try {
    const parsed = new URL(url)
    if (
      parsed.protocol !== 'https:'
      || parsed.hostname !== 'registry.npmjs.org'
      || parsed.port !== ''
      || parsed.username !== ''
      || parsed.password !== ''
      || parsed.search !== ''
      || parsed.hash !== ''
    ) {
      throw new Error('registry tarball URL must use the canonical npm registry origin')
    }
    validated = parsed.href
  } catch (error) {
    return Promise.reject(error)
  }

  return new Promise((resolve, reject) => {
    let settled = false
    let request
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (error) reject(error)
      else resolve(value)
    }
    const timer = setTimeout(() => {
      const error = new Error(`registry tarball download timed out after ${downloadTimeoutMs} ms`)
      request?.destroy(error)
      finish(error)
    }, downloadTimeoutMs)

    request = https.get(validated, {
      headers: {
        Accept: 'application/octet-stream',
        'User-Agent': 'zigcss-npm-publication-readback/1',
      },
    }, response => {
      if (response.statusCode !== 200) {
        response.resume()
        finish(new Error(`registry tarball download failed with HTTP ${response.statusCode ?? 0}`))
        return
      }
      const length = response.headers['content-length']
      if (length !== undefined) {
        if (!/^(?:0|[1-9]\d*)$/.test(length)) {
          response.resume()
          finish(new Error('registry tarball returned an invalid Content-Length'))
          return
        }
        const advertised = Number(length)
        if (!Number.isSafeInteger(advertised) || advertised <= 0 || advertised > maximumBytes) {
          response.resume()
          finish(new Error('registry tarball exceeds its byte limit'))
          return
        }
      }

      const chunks = []
      let received = 0
      response.on('data', chunk => {
        received += chunk.length
        if (received > maximumBytes) {
          response.destroy(new Error('registry tarball exceeds its byte limit'))
          return
        }
        chunks.push(chunk)
      })
      response.on('error', error => finish(error))
      response.on('end', () => {
        if (received <= 0) finish(new Error('registry tarball is empty'))
        else finish(null, Buffer.concat(chunks, received))
      })
    })
    request.on('error', error => finish(error))
  })
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

export function validateDownloadedNpmPackage(localPackage, downloadedPackage) {
  validateExpectedPackage(localPackage, localPackage.version)
  if (
    downloadedPackage.name !== localPackage.name
    || downloadedPackage.version !== localPackage.version
    || downloadedPackage.bytes !== localPackage.bytes
    || downloadedPackage.unpackedBytes !== localPackage.unpackedBytes
    || downloadedPackage.entryCount !== localPackage.entryCount
    || downloadedPackage.shasum !== localPackage.shasum
    || downloadedPackage.integrity !== localPackage.integrity
    || downloadedPackage.manifestText !== localPackage.manifestText
    || !same(downloadedPackage.files, localPackage.files)
  ) {
    fail('downloaded registry tarball differs from the exact tested package')
  }
  return true
}

export async function verifyNpmPublication(version, options = {}) {
  parseReleaseVersion(version, 'npm publication version')
  const localPackage = options.localPackage ?? (
    typeof options.archive === 'string'
      ? inspectNpmPackageArchive(options.archive, version)
      : null
  )
  validateExpectedPackage(localPackage, version)
  const attempts = options.attempts ?? npmPublicationReadbackPolicy.attempts
  const delayMs = options.delayMs ?? npmPublicationReadbackPolicy.delayMs
  const read = options.read ?? readRegistry
  const sleep = options.wait ?? wait
  const download = options.download ?? downloadRegistryTarball
  const inspectDownloaded = options.inspectDownloaded ?? ((bytes, expected) => (
    inspectNpmPackageBytes(bytes, version, Buffer.from(expected.manifestText))
  ))
  if (!Number.isSafeInteger(attempts) || attempts < 1 || attempts > npmPublicationReadbackPolicy.attempts) {
    fail(`attempt count must be an integer from 1 through ${npmPublicationReadbackPolicy.attempts}`)
  }
  if (!Number.isSafeInteger(delayMs) || delayMs < 0 || delayMs > npmPublicationReadbackPolicy.delayMs) {
    fail(`retry delay must be an integer from 0 through ${npmPublicationReadbackPolicy.delayMs} milliseconds`)
  }

  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await read(version, attempt)
      const result = validateNpmPublicationReadback(
        version,
        response.versionSource,
        response.tagsSource,
        response.distSource,
        localPackage,
      )
      const bytes = await download(result.tarballUrl, npmPackageArtifactLimits.archiveBytes)
      const downloadedPackage = inspectDownloaded(bytes, localPackage)
      validateDownloadedNpmPackage(localPackage, downloadedPackage)
      return { ...result, attempts: attempt, integrity: localPackage.integrity }
    } catch (error) {
      lastError = error
    }
    if (attempt < attempts) await sleep(delayMs)
  }
  fail(`registry did not converge after ${attempts} attempts: ${lastError?.message ?? 'unknown error'}`)
}

function parseArgs(args) {
  if (args.length !== 4) fail('usage: --version semver --archive absolute-path')
  const values = new Map()
  for (let index = 0; index < args.length; index += 2) {
    if (!['--version', '--archive'].includes(args[index]) || values.has(args[index]) || args[index + 1].length === 0) {
      fail('usage: --version semver --archive absolute-path')
    }
    values.set(args[index], args[index + 1])
  }
  if (!values.has('--version') || !values.has('--archive')) {
    fail('usage: --version semver --archive absolute-path')
  }
  return values
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const result = await verifyNpmPublication(args.get('--version'), { archive: args.get('--archive') })
  process.stdout.write(
    `npm publication verified: ${result.version} is visible on ${result.channel} with exact ${result.integrity} bytes after ${result.attempts} attempt(s).\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main().catch(error => {
    console.error(error.message)
    process.exitCode = 1
  })
}
