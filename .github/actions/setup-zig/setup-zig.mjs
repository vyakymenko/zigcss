import crypto from 'node:crypto'
import fs from 'node:fs'
import fsPromises from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const zigVersion = '0.15.2'
export const maximumArchiveEntries = 25_000
export const maximumArchiveListingBytes = 8 * 1024 * 1024
export const maximumCacheBytes = 2 * 1024 * 1024 * 1024
const maximumCacheEntries = 1_000_000
const downloadAttempts = 3
const downloadTimeoutMilliseconds = 10 * 60 * 1000

export const artifactRecords = Object.freeze([
  Object.freeze({
    platform: 'darwin',
    arch: 'arm64',
    target: 'aarch64-macos',
    extension: '.tar.xz',
    size: 50_635_984,
    sha256: '3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b',
  }),
  Object.freeze({
    platform: 'darwin',
    arch: 'x64',
    target: 'x86_64-macos',
    extension: '.tar.xz',
    size: 55_800_460,
    sha256: '375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f',
  }),
  Object.freeze({
    platform: 'linux',
    arch: 'arm64',
    target: 'aarch64-linux',
    extension: '.tar.xz',
    size: 49_471_996,
    sha256: '958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f',
  }),
  Object.freeze({
    platform: 'linux',
    arch: 'x64',
    target: 'x86_64-linux',
    extension: '.tar.xz',
    size: 53_733_924,
    sha256: '02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239',
  }),
  Object.freeze({
    platform: 'win32',
    arch: 'x64',
    target: 'x86_64-windows',
    extension: '.zip',
    size: 92_614_574,
    sha256: '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c',
  }),
])

function fail(message) {
  throw new Error(`Zig setup integrity: ${message}`)
}

function safeEnvironmentPath(name) {
  const value = process.env[name]
  if (
    value === undefined
    || value.length === 0
    || value.includes('\0')
    || value.includes('\r')
    || value.includes('\n')
    || !path.isAbsolute(value)
  ) {
    fail(`${name} must be an absolute path without control characters`)
  }
  return path.resolve(value)
}

export function resolveArchiveCommand(platform, environment = process.env) {
  if (platform !== 'win32') return 'tar'

  // Git Bash prepends GNU tar, which cannot own the Windows ZIP contract.
  const systemRoot = environment.SystemRoot
  if (
    typeof systemRoot !== 'string'
    || systemRoot.length === 0
    || systemRoot.includes('\0')
    || systemRoot.includes('\r')
    || systemRoot.includes('\n')
    || !path.win32.isAbsolute(systemRoot)
    || !/^[A-Za-z]:[\\/]$/.test(path.win32.parse(systemRoot).root)
  ) {
    fail('SystemRoot must be an absolute local drive path without control characters')
  }
  const normalized = path.win32.normalize(systemRoot).replace(/[\\/]$/, '').toLowerCase()
  // Convert the environment value to one of a finite set of literal Windows
  // roots. The spawned command never contains bytes supplied by the runner.
  switch (normalized) {
    case 'a:\\windows': return 'A:\\Windows\\System32\\tar.exe'
    case 'b:\\windows': return 'B:\\Windows\\System32\\tar.exe'
    case 'c:\\windows': return 'C:\\Windows\\System32\\tar.exe'
    case 'd:\\windows': return 'D:\\Windows\\System32\\tar.exe'
    case 'e:\\windows': return 'E:\\Windows\\System32\\tar.exe'
    case 'f:\\windows': return 'F:\\Windows\\System32\\tar.exe'
    case 'g:\\windows': return 'G:\\Windows\\System32\\tar.exe'
    case 'h:\\windows': return 'H:\\Windows\\System32\\tar.exe'
    case 'i:\\windows': return 'I:\\Windows\\System32\\tar.exe'
    case 'j:\\windows': return 'J:\\Windows\\System32\\tar.exe'
    case 'k:\\windows': return 'K:\\Windows\\System32\\tar.exe'
    case 'l:\\windows': return 'L:\\Windows\\System32\\tar.exe'
    case 'm:\\windows': return 'M:\\Windows\\System32\\tar.exe'
    case 'n:\\windows': return 'N:\\Windows\\System32\\tar.exe'
    case 'o:\\windows': return 'O:\\Windows\\System32\\tar.exe'
    case 'p:\\windows': return 'P:\\Windows\\System32\\tar.exe'
    case 'q:\\windows': return 'Q:\\Windows\\System32\\tar.exe'
    case 'r:\\windows': return 'R:\\Windows\\System32\\tar.exe'
    case 's:\\windows': return 'S:\\Windows\\System32\\tar.exe'
    case 't:\\windows': return 'T:\\Windows\\System32\\tar.exe'
    case 'u:\\windows': return 'U:\\Windows\\System32\\tar.exe'
    case 'v:\\windows': return 'V:\\Windows\\System32\\tar.exe'
    case 'w:\\windows': return 'W:\\Windows\\System32\\tar.exe'
    case 'x:\\windows': return 'X:\\Windows\\System32\\tar.exe'
    case 'y:\\windows': return 'Y:\\Windows\\System32\\tar.exe'
    case 'z:\\windows': return 'Z:\\Windows\\System32\\tar.exe'
    default: fail('SystemRoot must identify a drive-root Windows directory')
  }
}

export function resolveArtifact(platform, arch, version) {
  if (version !== zigVersion) fail(`only Zig ${zigVersion} is admitted, received ${JSON.stringify(version)}`)
  const record = artifactRecords.find(candidate => candidate.platform === platform && candidate.arch === arch)
  if (record === undefined) fail(`unsupported Zig host ${platform}/${arch}`)
  const root = `zig-${record.target}-${zigVersion}`
  const filename = `${root}${record.extension}`
  return Object.freeze({
    ...record,
    root,
    filename,
    url: `https://ziglang.org/download/${zigVersion}/${filename}`,
    binaryName: platform === 'win32' ? 'zig.exe' : 'zig',
  })
}

async function requireDirectory(directory, label, create = false) {
  if (!path.isAbsolute(directory) || directory.includes('\0') || directory.includes('\r') || directory.includes('\n')) {
    fail(`${label} must be an absolute path without control characters`)
  }
  if (create) await fsPromises.mkdir(directory, { recursive: true, mode: 0o700 })
  let stat
  try {
    stat = await fsPromises.lstat(directory)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink directory`)
  return fsPromises.realpath(directory)
}

async function requireCommandFile(filename, label) {
  if (!path.isAbsolute(filename) || filename.includes('\0') || filename.includes('\r') || filename.includes('\n')) {
    fail(`${label} must be an absolute path without control characters`)
  }
  let stat
  try {
    stat = await fsPromises.lstat(filename)
  } catch (error) {
    fail(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if (stat.size > 1024 * 1024) fail(`${label} exceeds its 1 MiB command-file limit`)
  return filename
}

export async function verifyArchive(filename, expected) {
  let stat
  try {
    stat = await fsPromises.lstat(filename)
  } catch (error) {
    fail(`Zig archive is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) fail('Zig archive must be a regular non-symlink file')
  if (stat.size !== expected.size) {
    fail(`Zig archive size must be ${expected.size} bytes, received ${stat.size}`)
  }

  const digest = crypto.createHash('sha256')
  for await (const chunk of fs.createReadStream(filename)) digest.update(chunk)
  const actual = digest.digest('hex')
  if (actual !== expected.sha256) {
    fail(`Zig archive SHA-256 must be ${expected.sha256}, received ${actual}`)
  }
  return { bytes: stat.size, sha256: actual }
}

async function downloadArchive(artifact, destination) {
  const temporary = `${destination}.part-${process.pid}-${crypto.randomUUID()}`
  let handle
  try {
    const response = await fetch(artifact.url, {
      redirect: 'error',
      signal: AbortSignal.timeout(downloadTimeoutMilliseconds),
      headers: { 'user-agent': 'zigcss-repository-setup-zig/1' },
    })
    if (response.status !== 200 || response.body === null) {
      fail(`download returned HTTP ${response.status}`)
    }
    const declaredLength = response.headers.get('content-length')
    if (declaredLength !== null && declaredLength !== String(artifact.size)) {
      fail(`download Content-Length must be ${artifact.size}, received ${declaredLength}`)
    }

    handle = await fsPromises.open(temporary, 'wx', 0o600)
    const digest = crypto.createHash('sha256')
    let bytes = 0
    for await (const chunk of response.body) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      bytes += buffer.byteLength
      if (bytes > artifact.size) fail(`download exceeded ${artifact.size} bytes`)
      digest.update(buffer)
      let offset = 0
      while (offset < buffer.length) {
        const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset)
        if (bytesWritten === 0) fail('download archive write made no progress')
        offset += bytesWritten
      }
    }
    await handle.sync()
    await handle.close()
    handle = undefined
    if (bytes !== artifact.size) fail(`download size must be ${artifact.size} bytes, received ${bytes}`)
    const actual = digest.digest('hex')
    if (actual !== artifact.sha256) {
      fail(`download SHA-256 must be ${artifact.sha256}, received ${actual}`)
    }

    try {
      await fsPromises.rename(temporary, destination)
    } catch (error) {
      if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error
      await verifyArchive(destination, artifact)
      await fsPromises.rm(temporary, { force: true })
    }
  } catch (error) {
    if (handle !== undefined) await handle.close().catch(() => {})
    await fsPromises.rm(temporary, { force: true }).catch(() => {})
    throw error
  }
}

async function ensureArchive(artifact, archiveDirectory) {
  const entries = await fsPromises.readdir(archiveDirectory, { withFileTypes: true })
  for (const entry of entries) {
    if (entry.name === artifact.filename) continue
    if (entry.name.startsWith(`${artifact.filename}.part-`) && entry.isFile()) {
      await fsPromises.rm(path.join(archiveDirectory, entry.name), { force: true })
      continue
    }
    fail(`archive cache contains unexpected entry ${JSON.stringify(entry.name)}`)
  }

  const destination = path.join(archiveDirectory, artifact.filename)
  if (fs.existsSync(destination)) {
    try {
      await verifyArchive(destination, artifact)
      process.stdout.write(`Using checksum-verified cached ${artifact.filename}.\n`)
      return destination
    } catch (error) {
      process.stdout.write(`Discarding invalid cached ${artifact.filename}: ${error.message}\n`)
      await fsPromises.rm(destination, { force: true })
    }
  }

  let lastError
  for (let attempt = 1; attempt <= downloadAttempts; attempt += 1) {
    try {
      process.stdout.write(`Downloading ${artifact.filename} from the pinned official URL (attempt ${attempt}/${downloadAttempts}).\n`)
      await downloadArchive(artifact, destination)
      await verifyArchive(destination, artifact)
      return destination
    } catch (error) {
      lastError = error
      await fsPromises.rm(destination, { force: true }).catch(() => {})
    }
  }
  fail(`failed to retrieve ${artifact.filename} after ${downloadAttempts} attempts: ${lastError.message}`)
}

export function validateArchiveEntries(entries, expectedRoot) {
  if (!Array.isArray(entries) || entries.length === 0) fail('archive entry inventory must not be empty')
  if (entries.length > maximumArchiveEntries) {
    fail(`archive entry limit is ${maximumArchiveEntries}, received ${entries.length}`)
  }
  let bytes = 0
  for (const entry of entries) {
    if (typeof entry !== 'string' || entry.length === 0) fail('archive entry must be a nonempty string')
    bytes += Buffer.byteLength(entry, 'utf8') + 1
    if (bytes > maximumArchiveListingBytes) {
      fail(`archive entry listing exceeds ${maximumArchiveListingBytes} bytes`)
    }
    if (
      entry.includes('\0')
      || entry.includes('\\')
      || entry.startsWith('/')
      || path.win32.isAbsolute(entry)
    ) {
      fail(`archive entry is unsafe: ${JSON.stringify(entry)}`)
    }
    const parts = entry.split('/')
    if (parts[0] !== expectedRoot) fail(`archive entry leaves ${expectedRoot}: ${JSON.stringify(entry)}`)
    for (const [index, part] of parts.entries()) {
      const terminalDirectoryMarker = index === parts.length - 1 && part === ''
      if (terminalDirectoryMarker) continue
      if (part === '' || part === '.' || part === '..') {
        fail(`archive entry contains an unsafe path component: ${JSON.stringify(entry)}`)
      }
    }
  }
  return { entries: entries.length }
}

async function runBounded(command, arguments_, maximumOutputBytes) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, arguments_, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
    const stdout = []
    const stderr = []
    let stdoutBytes = 0
    let stderrBytes = 0
    let settled = false

    function abort(message) {
      if (settled) return
      settled = true
      child.kill()
      reject(new Error(message))
    }

    child.stdout.on('data', chunk => {
      stdoutBytes += chunk.length
      if (stdoutBytes > maximumOutputBytes) return abort(`${command} stdout exceeded ${maximumOutputBytes} bytes`)
      stdout.push(chunk)
    })
    child.stderr.on('data', chunk => {
      stderrBytes += chunk.length
      if (stderrBytes > maximumOutputBytes) return abort(`${command} stderr exceeded ${maximumOutputBytes} bytes`)
      stderr.push(chunk)
    })
    child.on('error', error => abort(`${command} could not start: ${error.message}`))
    child.on('close', (code, signal) => {
      if (settled) return
      settled = true
      const output = {
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      }
      if (code !== 0 || signal !== null) {
        reject(new Error(`${command} failed with code ${code ?? 'null'} signal ${signal ?? 'none'}: ${output.stderr.trim()}`))
        return
      }
      resolve(output)
    })
  })
}

async function inspectExtractedTree(root) {
  const pending = [root]
  let entries = 0
  while (pending.length > 0) {
    const directory = pending.pop()
    for (const entry of await fsPromises.readdir(directory, { withFileTypes: true })) {
      entries += 1
      if (entries > maximumArchiveEntries) fail(`extracted Zig tree exceeds ${maximumArchiveEntries} entries`)
      const candidate = path.join(directory, entry.name)
      const stat = await fsPromises.lstat(candidate)
      if (stat.isSymbolicLink()) fail(`extracted Zig tree contains symlink ${JSON.stringify(entry.name)}`)
      if (stat.isDirectory()) {
        pending.push(candidate)
      } else if (!stat.isFile()) {
        fail(`extracted Zig tree contains a special file ${JSON.stringify(entry.name)}`)
      }
    }
  }
  return entries
}

async function extractArchive(artifact, archive, runnerTemporary) {
  const extractionParent = path.join(runnerTemporary, 'zigcss-zig-tool')
  await fsPromises.rm(extractionParent, { recursive: true, force: true })
  await fsPromises.mkdir(extractionParent, { recursive: false, mode: 0o700 })

  try {
    const archiveCommand = resolveArchiveCommand(process.platform)
    if (process.platform === 'win32') {
      await requireCommandFile(archiveCommand, 'Windows archive tool')
    }
    const listing = await runBounded(archiveCommand, ['-tf', archive], maximumArchiveListingBytes)
    const entries = listing.stdout.split(/\r?\n/).filter(Boolean)
    validateArchiveEntries(entries, artifact.root)
    await runBounded(archiveCommand, ['-xf', archive, '-C', extractionParent], 256 * 1024)

    const topLevel = await fsPromises.readdir(extractionParent)
    if (topLevel.length !== 1 || topLevel[0] !== artifact.root) {
      fail(`extracted Zig tree must contain only ${artifact.root}`)
    }
    const toolDirectory = path.join(extractionParent, artifact.root)
    await requireDirectory(toolDirectory, 'extracted Zig tool directory')
    await inspectExtractedTree(toolDirectory)

    const binary = path.join(toolDirectory, artifact.binaryName)
    const binaryStat = await fsPromises.lstat(binary)
    if (!binaryStat.isFile() || binaryStat.isSymbolicLink()) {
      fail('extracted Zig executable must be a regular non-symlink file')
    }
    const version = await runBounded(binary, ['version'], 64 * 1024)
    if (version.stdout.trim() !== zigVersion || version.stderr.trim() !== '') {
      fail(`extracted Zig executable reported unexpected version output ${JSON.stringify(version.stdout.trim())}`)
    }
    return toolDirectory
  } catch (error) {
    await fsPromises.rm(extractionParent, { recursive: true, force: true }).catch(() => {})
    throw error
  }
}

export async function measureCacheDirectory(directory, maximumBytes = maximumCacheBytes) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 0) fail('cache byte limit must be a nonnegative safe integer')
  await requireDirectory(directory, 'Zig cache directory')
  const pending = [directory]
  let bytes = 0
  let entries = 0
  while (pending.length > 0) {
    const current = pending.pop()
    for (const entry of await fsPromises.readdir(current, { withFileTypes: true })) {
      entries += 1
      if (entries > maximumCacheEntries) return { bytes, overLimit: true }
      const candidate = path.join(current, entry.name)
      const stat = await fsPromises.lstat(candidate)
      if (stat.isDirectory() && !stat.isSymbolicLink()) {
        pending.push(candidate)
      } else if (stat.isFile() && !stat.isSymbolicLink()) {
        bytes += stat.size
      } else {
        return { bytes, overLimit: true }
      }
    }
  }
  return { bytes, overLimit: bytes > maximumBytes }
}

async function clearCache(directory) {
  for (const entry of await fsPromises.readdir(directory)) {
    await fsPromises.rm(path.join(directory, entry), { recursive: true, force: true })
  }
}

export async function prepareCache(workspace) {
  const rootDirectory = await requireDirectory(
    path.join(workspace, '.zig-cache'),
    'Zig cache root directory',
    true,
  )
  const usage = await measureCacheDirectory(rootDirectory)
  if (usage.overLimit) {
    process.stdout.write(`Restored Zig cache exceeds ${maximumCacheBytes} bytes; clearing it before use.\n`)
    await clearCache(rootDirectory)
  } else {
    process.stdout.write(`Restored Zig cache contains ${usage.bytes} bytes.\n`)
  }
  const globalDirectory = await requireDirectory(
    path.join(rootDirectory, 'global'),
    'Zig global cache directory',
    true,
  )
  const localDirectory = await requireDirectory(
    path.join(rootDirectory, 'local'),
    'Zig local cache directory',
    true,
  )
  return { rootDirectory, globalDirectory, localDirectory }
}

async function appendCommand(filename, value) {
  if (value.includes('\0') || value.includes('\r') || value.includes('\n')) fail('workflow command value contains control characters')
  await fsPromises.appendFile(filename, `${value}${os.EOL}`, { encoding: 'utf8' })
}

async function install() {
  const version = process.env.ZIGCSS_SETUP_VERSION
  const artifact = resolveArtifact(process.platform, process.arch, version)
  const runnerTemporary = await requireDirectory(safeEnvironmentPath('RUNNER_TEMP'), 'RUNNER_TEMP')
  const workspace = await requireDirectory(safeEnvironmentPath('GITHUB_WORKSPACE'), 'GITHUB_WORKSPACE')
  const githubPath = await requireCommandFile(safeEnvironmentPath('GITHUB_PATH'), 'GITHUB_PATH')
  const githubEnvironment = await requireCommandFile(safeEnvironmentPath('GITHUB_ENV'), 'GITHUB_ENV')
  const archiveDirectory = await requireDirectory(
    path.join(runnerTemporary, 'zigcss-zig-tool-archive'),
    'Zig archive cache directory',
    true,
  )

  const archive = await ensureArchive(artifact, archiveDirectory)
  const toolDirectory = await extractArchive(artifact, archive, runnerTemporary)
  const cache = await prepareCache(workspace)
  await appendCommand(githubPath, toolDirectory)
  await appendCommand(githubEnvironment, `ZIG_GLOBAL_CACHE_DIR=${cache.globalDirectory}`)
  await appendCommand(githubEnvironment, `ZIG_LOCAL_CACHE_DIR=${cache.localDirectory}`)
  process.stdout.write(`Installed checksum-verified Zig ${zigVersion} for ${artifact.target}.\n`)
}

async function pruneCache() {
  const workspace = await requireDirectory(safeEnvironmentPath('GITHUB_WORKSPACE'), 'GITHUB_WORKSPACE')
  const directory = path.join(workspace, '.zig-cache')
  if (!fs.existsSync(directory)) {
    process.stdout.write('No Zig cache directory exists; nothing to preserve.\n')
    return
  }
  const usage = await measureCacheDirectory(directory)
  if (usage.overLimit) {
    process.stdout.write(`Zig cache exceeds ${maximumCacheBytes} bytes; clearing it before cache save.\n`)
    await clearCache(directory)
    return
  }
  process.stdout.write(`Zig cache is ${usage.bytes} bytes, within the ${maximumCacheBytes}-byte limit.\n`)
}

async function main() {
  if (process.argv.length !== 3 || !['--install', '--prune-cache'].includes(process.argv[2])) {
    fail('usage: node setup-zig.mjs <--install|--prune-cache>')
  }
  if (process.argv[2] === '--install') await install()
  else await pruneCache()
}

const scriptPath = fileURLToPath(import.meta.url)
if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main().catch(error => {
    process.stderr.write(`${error.stack ?? error.message}\n`)
    process.exitCode = 1
  })
}
