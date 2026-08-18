import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseReleaseVersion } from './validate-release-version.mjs'

const scriptPath = fileURLToPath(import.meta.url)

function fail(message) {
  throw new Error(`npm publication preflight: ${message}`)
}

export function checkNpmVersionAvailability(version, source) {
  const parsedVersion = parseReleaseVersion(version, 'npm publication version')
  const channel = parsedVersion.prerelease === null ? 'latest' : 'next'
  if (typeof source !== 'string' || source.length === 0 || source.length > 1024 * 1024) {
    fail('registry version inventory is empty or oversized')
  }

  let versions
  try {
    versions = JSON.parse(source)
  } catch (error) {
    fail(`registry version inventory is not JSON: ${error.message}`)
  }
  if (!Array.isArray(versions) || versions.length === 0 || versions.length > 10_000) {
    fail('registry version inventory must be a bounded non-empty array')
  }

  const seen = new Set()
  for (const candidate of versions) {
    if (typeof candidate !== 'string') fail('registry version inventory contains a non-string value')
    parseReleaseVersion(candidate, 'published npm version')
    if (seen.has(candidate)) fail(`registry version inventory repeats ${candidate}`)
    seen.add(candidate)
  }
  if (seen.has(version)) fail(`npm version ${version} is already published and immutable`)
  return {
    version,
    publishedVersions: versions.length,
    channel,
    githubPrerelease: parsedVersion.prerelease !== null,
  }
}

function readVersionsFile(filename) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename)) {
    fail('versions file must be an explicit absolute path')
  }
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`versions file is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0 || stat.size > 1024 * 1024) {
    fail('versions file must be a bounded regular non-symlink file')
  }
  return fs.readFileSync(filename, 'utf8')
}

function writeGithubOutput(filename, result) {
  if (typeof filename !== 'string' || !path.isAbsolute(filename)) {
    fail('GitHub output file must be an explicit absolute path')
  }
  let stat
  try {
    stat = fs.lstatSync(filename)
  } catch (error) {
    fail(`GitHub output file is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) {
    fail('GitHub output file must be a bounded regular non-symlink file')
  }
  fs.appendFileSync(
    filename,
    `channel=${result.channel}\ngithub_prerelease=${result.githubPrerelease}\n`,
    { encoding: 'utf8' },
  )
}

function parseArgs(args) {
  if (![4, 6].includes(args.length)) {
    fail('usage: --version semver --versions-file absolute-path [--github-output absolute-path]')
  }
  const values = {}
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!['--version', '--versions-file', '--github-output'].includes(name) || value === undefined || Object.hasOwn(values, name)) {
      fail('usage: --version semver --versions-file absolute-path [--github-output absolute-path]')
    }
    values[name] = value
  }
  if (values['--version'] === undefined || values['--versions-file'] === undefined) {
    fail('usage: --version semver --versions-file absolute-path [--github-output absolute-path]')
  }
  return values
}

function main() {
  const values = parseArgs(process.argv.slice(2))
  const result = checkNpmVersionAvailability(
    values['--version'],
    readVersionsFile(values['--versions-file']),
  )
  if (values['--github-output'] !== undefined) {
    writeGithubOutput(values['--github-output'], result)
  }
  process.stdout.write(
    `npm publication preflight verified: ${result.version} is absent from ${result.publishedVersions} immutable versions and will use ${result.channel}.\n`,
  )
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) main()
