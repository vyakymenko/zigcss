import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { setTimeout as wait } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)
const registry = 'https://registry.npmjs.org/'
const maximumResponseBytes = 256 * 1024
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

export function validateNpmPublicationReadback(version, versionSource, tagsSource) {
  const parsedVersion = parseReleaseVersion(version, 'npm publication version')
  if (parsedVersion.prerelease === null) {
    fail('the next channel accepts only a canonical prerelease version')
  }

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
  if (tags.next !== version) {
    fail(`next tag must be ${version}, received ${JSON.stringify(tags.next)}`)
  }
  if (!parsedTags.has('latest') || parsedTags.get('latest').prerelease !== null) {
    fail('prerelease publication must retain a stable latest tag')
  }
  return { version, channel: 'next' }
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
  }
}

export async function verifyNpmPublication(version, options = {}) {
  const parsedVersion = parseReleaseVersion(version, 'npm publication version')
  if (parsedVersion.prerelease === null) {
    fail('the next channel accepts only a canonical prerelease version')
  }
  const attempts = options.attempts ?? npmPublicationReadbackPolicy.attempts
  const delayMs = options.delayMs ?? npmPublicationReadbackPolicy.delayMs
  const read = options.read ?? readRegistry
  const sleep = options.wait ?? wait
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
      )
      return { ...result, attempts: attempt }
    } catch (error) {
      lastError = error
    }
    if (attempt < attempts) await sleep(delayMs)
  }
  fail(`registry did not converge after ${attempts} attempts: ${lastError?.message ?? 'unknown error'}`)
}

function parseArgs(args) {
  if (args.length !== 2 || args[0] !== '--version' || args[1].length === 0) {
    fail('usage: --version semver')
  }
  return args[1]
}

async function main() {
  const result = await verifyNpmPublication(parseArgs(process.argv.slice(2)))
  process.stdout.write(
    `npm publication verified: ${result.version} is visible on ${result.channel} after ${result.attempts} attempt(s).\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main().catch(error => {
    console.error(error.message)
    process.exitCode = 1
  })
}
