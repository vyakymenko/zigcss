'use strict'

const { EventEmitter } = require('node:events')
const childProcess = require('node:child_process')
const cluster = require('node:cluster')
const crypto = require('node:crypto')
const dgram = require('node:dgram')
const dns = require('node:dns')
const dnsPromises = require('node:dns/promises')
const fs = require('node:fs')
const http = require('node:http')
const http2 = require('node:http2')
const https = require('node:https')
const inspector = require('node:inspector')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const { Readable } = require('node:stream')
const tls = require('node:tls')
const { pathToFileURL } = require('node:url')
const workerThreads = require('node:worker_threads')

const maximumTraceBytes = 64 * 1024
const maximumManifestBytes = 64 * 1024
const maximumArchiveBytes = 512 * 1024 * 1024
const maximumAssetEntries = 16
const requestTimeoutMs = 30 * 1000
const posixArchivePolicies = Object.freeze({
  darwin: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar']),
    resolved: Object.freeze(['/usr/bin/tar', '/usr/bin/bsdtar']),
  }),
  linux: Object.freeze({
    candidates: Object.freeze(['/usr/bin/tar', '/bin/tar']),
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
const repositoryRoot = path.resolve(__dirname, '..')
const assetTemporaryRootPattern = /^(?:zigcss-package-manager-matrix-[A-Za-z0-9]{6}\/preloaded-release|zigcss-release-lifecycle-[A-Za-z0-9]{6}\/release|zigcss-release-(?:node-api-trace|preload(?:-pnp)?|runtime-(?:denial|trace))-[A-Za-z0-9]{6})$/
const traceTemporaryRootPattern = /^(?:zigcss-native-release-smoke|zigcss-release-(?:node-api-trace|preload|runtime-(?:denial|trace)))-[A-Za-z0-9]{6}$/
const lifecycleTemporaryRootPattern = /^(?:zigcss-(?:native-release-smoke|release-lifecycle)-[A-Za-z0-9]{6}\/consumer\/node_modules\/zigcss|zigcss-package-manager-matrix-[A-Za-z0-9]{6}\/yarn-modern-pnp\/consumer\/\.yarn\/unplugged\/[A-Za-z0-9][A-Za-z0-9._-]{0,254}\/node_modules\/zigcss)$/
const runtimeTraceNames = Object.freeze([
  'direct-runtime-trace.jsonl',
  'node-api-runtime-trace.jsonl',
  'offline-runtime-trace.jsonl',
  'runtime-trace.jsonl',
])

function fail(message) {
  throw new Error(`release smoke preload: ${message}`)
}

function boundaryError(code, message) {
  const error = new Error(message)
  error.code = code
  return error
}

function immutableFunction(target, name, value) {
  if (typeof target[name] !== 'function') return
  const descriptor = Object.getOwnPropertyDescriptor(target, name)
  Object.defineProperty(target, name, {
    configurable: false,
    enumerable: descriptor?.enumerable ?? true,
    value,
    writable: false,
  })
}

function immutableValue(target, name, value, enumerable = true) {
  Object.defineProperty(target, name, {
    configurable: false,
    enumerable,
    value,
    writable: false,
  })
}

function installProcessEscapeBoundary(denyProcess, networkError) {
  if (typeof process.execve === 'function') {
    immutableFunction(process, 'execve', () => denyProcess('process.execve'))
  }
  if (typeof process._debugProcess === 'function') {
    immutableFunction(process, '_debugProcess', () => denyProcess('process._debugProcess'))
  }
  if (typeof process._kill === 'function') {
    immutableFunction(process, '_kill', () => denyProcess('process._kill'))
  }
  if (typeof process.dlopen === 'function') {
    immutableFunction(process, 'dlopen', () => denyProcess('process.dlopen'))
  }
  immutableFunction(process, 'kill', () => denyProcess('process.kill'))

  immutableFunction(cluster, 'fork', function deniedClusterFork() {
    return denyProcess('cluster.fork')
  })
  immutableValue(workerThreads, 'Worker', class DisabledWorker {
    constructor() {
      return denyProcess('worker_threads.Worker')
    }
  })

  const blockedProcessBindings = new Set(['process_wrap', 'spawn_sync'])
  const blockedNetworkBindings = new Set([
    'cares_wrap',
    'inspector',
    'pipe_wrap',
    'tcp_wrap',
    'tls_wrap',
    'udp_wrap',
  ])
  const originalProcessBinding = process.binding.bind(process)
  Object.defineProperty(process, 'binding', {
    configurable: false,
    enumerable: true,
    value(name) {
      if (typeof name !== 'string') return denyProcess('process.binding:invalid')
      const label = /^[a-z0-9_]{1,64}$/.test(name) ? name : 'invalid'
      if (label === 'invalid') return denyProcess('process.binding:invalid')
      if (blockedProcessBindings.has(name)) return denyProcess(`process.binding:${label}`)
      if (blockedNetworkBindings.has(name)) throw networkError(`process.binding:${label}`)
      return Reflect.apply(originalProcessBinding, process, [name])
    },
    writable: false,
  })
  Object.defineProperty(process, '_linkedBinding', {
    configurable: false,
    enumerable: true,
    value() {
      return denyProcess('process._linkedBinding')
    },
    writable: false,
  })
  immutableFunction(inspector, 'open', () => { throw networkError('inspector.open') })
}

function installNetworkBoundary(networkError, { allowedHttpsGet } = {}) {
  function deniedRequest(operation) {
    const request = new EventEmitter()
    request.setTimeout = () => request
    request.end = () => request
    request.write = () => false
    request.abort = () => request
    request.destroy = () => request
    queueMicrotask(() => request.emit('error', networkError(operation)))
    return request
  }
  const deny = operation => function deniedNetworkOperation() {
    throw networkError(operation)
  }

  immutableFunction(http, 'request', () => deniedRequest('http.request'))
  immutableFunction(http, 'get', () => deniedRequest('http.get'))
  immutableFunction(https, 'request', () => deniedRequest('https.request'))
  immutableFunction(https, 'get', allowedHttpsGet ?? (() => deniedRequest('https.get')))
  immutableValue(http, 'ClientRequest', class DisabledClientRequest {
    constructor() {
      throw networkError('http.ClientRequest')
    }
  })
  immutableFunction(http.Agent.prototype, 'createConnection', deny('http.Agent.createConnection'))
  immutableFunction(https.Agent.prototype, 'createConnection', deny('https.Agent.createConnection'))
  immutableFunction(net, 'connect', () => deniedRequest('net.connect'))
  immutableFunction(net, 'createConnection', () => deniedRequest('net.createConnection'))
  immutableFunction(net.Socket.prototype, 'connect', () => deniedRequest('net.Socket.connect'))
  immutableFunction(net.Server.prototype, 'listen', deny('net.Server.listen'))
  immutableFunction(net, 'createServer', deny('net.createServer'))
  immutableFunction(net, '_createServerHandle', deny('net._createServerHandle'))
  immutableValue(net.Server.prototype, '_listen2', deny('net.Server._listen2'), false)
  immutableFunction(http, 'createServer', deny('http.createServer'))
  immutableFunction(https, 'createServer', deny('https.createServer'))
  immutableFunction(http, '_connectionListener', deny('http._connectionListener'))
  immutableFunction(tls, 'connect', () => deniedRequest('tls.connect'))
  immutableFunction(tls, 'createServer', deny('tls.createServer'))
  immutableFunction(http2, 'connect', () => deniedRequest('http2.connect'))
  immutableFunction(http2, 'createServer', deny('http2.createServer'))
  immutableFunction(http2, 'createSecureServer', deny('http2.createSecureServer'))
  immutableFunction(http2, 'performServerHandshake', deny('http2.performServerHandshake'))
  immutableFunction(dgram, 'createSocket', deny('dgram.createSocket'))
  immutableFunction(dgram, '_createSocketHandle', deny('dgram._createSocketHandle'))
  immutableValue(dgram, 'Socket', class DisabledDatagramSocket {
      constructor() {
        throw networkError('dgram.Socket')
      }
  })

  const allowedDnsConfigurationFunctions = new Set([
    'getDefaultResultOrder',
    'getServers',
    'setDefaultResultOrder',
  ])
  function denyDnsCallback(operation) {
    return function deniedDnsOperation(...args) {
      const callback = args.at(-1)
      const error = networkError(operation)
      if (typeof callback === 'function') queueMicrotask(() => callback(error))
      else throw error
    }
  }
  for (const name of Object.keys(dns)) {
    if (
      name !== 'Resolver' && !allowedDnsConfigurationFunctions.has(name) &&
      typeof dns[name] === 'function'
    ) immutableFunction(dns, name, denyDnsCallback(`dns.${name}`))
  }
  immutableValue(dns, 'Resolver', class DisabledDnsResolver {
    constructor() {
      throw networkError('dns.Resolver')
    }
  })
  for (const name of Object.keys(dnsPromises)) {
    if (
      name !== 'Resolver' && !allowedDnsConfigurationFunctions.has(name) &&
      typeof dnsPromises[name] === 'function'
    ) immutableFunction(dnsPromises, name, name === 'setServers'
      ? (..._args) => { throw networkError(`dns.promises.${name}`) }
      : (..._args) => Promise.reject(networkError(`dns.promises.${name}`)))
  }
  immutableValue(dnsPromises, 'Resolver', class DisabledDnsPromisesResolver {
    constructor() {
      throw networkError('dns.promises.Resolver')
    }
  })

  immutableValue(
    globalThis,
    'fetch',
    (..._args) => Promise.reject(networkError('globalThis.fetch')),
  )
  const DisabledWebSocket = class DisabledWebSocket {
    constructor() {
      throw networkError('WebSocket')
    }
  }
  if (typeof http.WebSocket === 'function') {
    immutableValue(http, 'WebSocket', DisabledWebSocket)
  }
  if (typeof globalThis.WebSocket === 'function') {
    immutableValue(globalThis, 'WebSocket', DisabledWebSocket)
  }
}

function isPlainDenseArray(value, maximumLength) {
  if (
    !Array.isArray(value)
    || Object.getPrototypeOf(value) !== Array.prototype
    || value.length > maximumLength
  ) return false
  const keys = Reflect.ownKeys(value)
  if (keys.length !== value.length + 1 || keys.at(-1) !== 'length') return false
  return keys.slice(0, -1).every((key, index) => {
    if (key !== String(index)) return false
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    return descriptor !== undefined && Object.hasOwn(descriptor, 'value')
  })
}

function exactDataArray(value, expected) {
  return isPlainDenseArray(value, expected.length) && value.length === expected.length &&
    expected.every((item, index) => value[index] === item)
}

function exactPlainOptions(value, expectedKeys) {
  if (value === null || typeof value !== 'object' || Object.getPrototypeOf(value) !== Object.prototype) {
    return false
  }
  const keys = Reflect.ownKeys(value)
  if (keys.length !== expectedKeys.length || expectedKeys.some(name => !keys.includes(name))) return false
  return keys.every(name => {
    if (typeof name !== 'string') return false
    const descriptor = Object.getOwnPropertyDescriptor(value, name)
    return descriptor !== undefined && Object.hasOwn(descriptor, 'value')
  })
}

function boundedStringEnvironment(environment) {
  if (
    environment === null || typeof environment !== 'object' ||
    (environment !== process.env && Object.getPrototypeOf(environment) !== Object.prototype)
  ) return false
  const keys = Reflect.ownKeys(environment)
  if (keys.length > 512) return false
  return keys.every(name => {
    if (typeof name !== 'string' || name.length === 0 || name.length > 256 || /[=\0]/.test(name)) return false
    const descriptor = Object.getOwnPropertyDescriptor(environment, name)
    return descriptor !== undefined && Object.hasOwn(descriptor, 'value') &&
      typeof descriptor.value === 'string' && Buffer.byteLength(descriptor.value) <= 64 * 1024
  })
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.mode === right.mode &&
    left.nlink === right.nlink
}

function sameStableIdentity(left, right) {
  return sameFileIdentity(left, right) && left.size === right.size &&
    left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs
}

function sameLocalPath(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false
  return process.platform === 'win32'
    ? path.win32.normalize(left).toLowerCase() === path.win32.normalize(right).toLowerCase()
    : left === right
}

function exactTemporaryRelative(rootInput, label) {
  const temporaryRoot = path.resolve(os.tmpdir())
  const relative = path.relative(temporaryRoot, rootInput).split(path.sep).join('/')
  const pattern = label === 'asset root'
    ? assetTemporaryRootPattern
    : label === 'runtime trace root'
      ? traceTemporaryRootPattern
      : null
  if (
    relative.length === 0 || relative.startsWith('../') || path.posix.isAbsolute(relative) ||
    pattern === null || !pattern.test(relative)
  ) return null
  return Object.freeze({ relative, temporaryRoot })
}

function canonicalSmokeDirectory(rootInput, label, allowRepositoryAssets = false) {
  if (typeof rootInput !== 'string' || rootInput.includes('\0') || !path.isAbsolute(rootInput)) {
    fail(`${label} must be an absolute local path`)
  }
  const repositoryAssets = path.join(repositoryRoot, 'release-assets')
  let candidate
  let temporaryAdmission = null
  if (sameLocalPath(rootInput, repositoryAssets)) {
    if (!allowRepositoryAssets) fail(`${label} must remain inside the smoke temporary root`)
    candidate = repositoryAssets
  } else {
    temporaryAdmission = exactTemporaryRelative(rootInput, label)
    if (temporaryAdmission === null) {
      fail(allowRepositoryAssets
        ? `${label} must be the repository assets or remain inside the smoke temporary root`
        : `${label} must remain inside the smoke temporary root`)
    }
    candidate = path.join(
      temporaryAdmission.temporaryRoot,
      ...temporaryAdmission.relative.split('/'),
    )
    if (!sameLocalPath(candidate, rootInput)) fail(`${label} must use its exact admitted path`)
  }
  let handle
  try {
    handle = fs.opendirSync(candidate)
    const lexical = fs.lstatSync(candidate, { bigint: true })
    const canonical = fs.realpathSync(candidate)
    const bound = fs.lstatSync(canonical, { bigint: true })
    if (
      !lexical.isDirectory() || lexical.isSymbolicLink() || !bound.isDirectory() ||
      bound.isSymbolicLink() || !sameStableIdentity(lexical, bound)
    ) {
      fail(`${label} changed during directory-handle admission`)
    }
    if (temporaryAdmission === null) {
      if (canonical !== fs.realpathSync(repositoryAssets)) fail(`${label} escapes the repository assets`)
    } else {
      const canonicalTemporary = fs.realpathSync(temporaryAdmission.temporaryRoot)
      const canonicalRelative = path.relative(canonicalTemporary, canonical).split(path.sep).join('/')
      if (!sameLocalPath(canonicalRelative, temporaryAdmission.relative)) fail(`${label} escapes its admitted root`)
    }
    const admittedHandle = handle
    handle = undefined
    return Object.freeze({ handle: admittedHandle, path: canonical, stat: bound })
  } finally {
    if (handle !== undefined) handle.closeSync()
  }
}

function fileSha256(filename) {
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0))
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

function canonicalLifecyclePackage(
  rootInput,
  environment,
  requireInstallerArgv,
  requireNpmLifecycle = true,
) {
  if (
    typeof rootInput !== 'string' || rootInput.includes('\0') || !path.isAbsolute(rootInput) ||
    !boundedStringEnvironment(environment)
  ) return null
  try {
    const temporaryRoot = path.resolve(os.tmpdir())
    const canonicalTemporaryRoot = fs.realpathSync(temporaryRoot)
    // Admit only the finite consumer layouts before probing a caller path.
    // npm may already canonicalize /var to /private/var on macOS.
    let candidate = null
    for (const base of [temporaryRoot, canonicalTemporaryRoot]) {
      const relative = path.relative(base, rootInput).split(path.sep).join('/')
      if (!lifecycleTemporaryRootPattern.test(relative)) continue
      if (!sameLocalPath(path.join(base, ...relative.split('/')), rootInput)) continue
      candidate = path.join(canonicalTemporaryRoot, ...relative.split('/'))
      break
    }
    if (candidate === null) return null
    const rootStat = fs.lstatSync(candidate, { bigint: true })
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) return null
    const root = fs.realpathSync(candidate)
    if (!sameLocalPath(root, candidate)) return null
    const canonicalStat = fs.lstatSync(root, { bigint: true })
    if (
      !canonicalStat.isDirectory() || canonicalStat.isSymbolicLink() ||
      !sameStableIdentity(rootStat, canonicalStat)
    ) return null
    const manifestFile = path.join(root, 'package.json')
    const installerFile = path.join(root, 'install.js')
    for (const [filename, maximumBytes] of [[manifestFile, maximumManifestBytes], [installerFile, 2 * 1024 * 1024]]) {
      const stat = fs.lstatSync(filename)
      if (
        !stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > maximumBytes ||
        !sameLocalPath(fs.realpathSync(filename), filename)
      ) return null
    }
    const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
    if (
      manifest.name !== 'zigcss' || manifest.version !== version ||
      manifest.scripts?.postinstall !== 'node install.js'
    ) return null
    const repositoryInstaller = path.resolve(__dirname, '..', 'install.js')
    if (fileSha256(installerFile) !== fileSha256(repositoryInstaller)) return null
    if (
      environment.ZIGCSS_RELEASE_SMOKE !== '1' ||
      environment.ZIGCSS_RELEASE_SMOKE_ARCHIVE !== archiveName ||
      environment.ZIGCSS_RELEASE_SMOKE_ASSET_ROOT !== assetRootInput ||
      environment.ZIGCSS_RELEASE_SMOKE_CHECKSUMS !== checksumsName ||
      environment.ZIGCSS_RELEASE_SMOKE_VERSION !== version
    ) return null
    if (
      requireNpmLifecycle && (
        environment.npm_lifecycle_event !== 'postinstall' ||
        environment.npm_lifecycle_script !== 'node install.js' ||
        environment.npm_package_name !== 'zigcss' ||
        environment.npm_package_version !== version ||
        !sameLocalPath(path.resolve(environment.npm_package_json ?? ''), manifestFile) ||
        environment.NODE_OPTIONS !== process.env.NODE_OPTIONS
      )
    ) return null
    if (requireInstallerArgv) {
      if (
        process.argv.length !== 2 ||
        !sameLocalPath(fs.realpathSync(process.argv[1]), installerFile)
      ) return null
    }
    return Object.freeze({ installerFile, manifestFile, root })
  } catch {
    return null
  }
}

function trustedArchiveExecutable(command) {
  if (typeof command !== 'string' || command.includes('\0')) return false
  if (process.platform === 'win32') {
    const systemRoot = process.env.SystemRoot
    if (
      typeof systemRoot !== 'string' || systemRoot.includes('\0') ||
      !/^[A-Za-z]:[\\/]/.test(systemRoot) || !path.win32.isAbsolute(systemRoot)
    ) return false
    return path.win32.normalize(command).toLowerCase() ===
      path.win32.normalize(path.win32.join(systemRoot, 'System32', 'tar.exe')).toLowerCase()
  }
  const policy = posixArchivePolicies[process.platform]
  if (policy === undefined || !policy.candidates.includes(command)) return false
  let descriptor
  try {
    const resolved = fs.realpathSync(command)
    if (!policy.resolved.includes(resolved)) return false
    descriptor = fs.openSync(
      resolved,
      fs.constants.O_RDONLY |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
    )
    const opened = fs.fstatSync(descriptor)
    const after = fs.lstatSync(resolved)
    return opened.isFile() && after.isFile() && !after.isSymbolicLink() &&
      opened.uid === 0 && (opened.mode & 0o022) === 0 && (opened.mode & 0o111) !== 0 &&
      after.dev === opened.dev && after.ino === opened.ino && after.mode === opened.mode &&
      after.uid === opened.uid && after.size === opened.size && after.mtimeMs === opened.mtimeMs &&
      fs.realpathSync(command) === resolved
  } catch {
    return false
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

function lifecycleArchivePath(filename, packageRoot) {
  if (typeof filename !== 'string' || filename.includes('\0') || !path.isAbsolute(filename)) return null
  try {
    const archiveStat = fs.lstatSync(filename)
    if (
      !archiveStat.isFile() || archiveStat.isSymbolicLink() || archiveStat.size <= 0 ||
      archiveStat.size > maximumArchiveBytes ||
      !sameLocalPath(fs.realpathSync(filename), filename) ||
      path.basename(filename) !== archiveName
    ) return null
    const temporary = path.dirname(filename)
    const temporaryStat = fs.lstatSync(temporary)
    const name = path.basename(temporary)
    if (
      !temporaryStat.isDirectory() || temporaryStat.isSymbolicLink() ||
      !/^\.install-[A-Za-z0-9]{6}$/.test(name) ||
      !sameLocalPath(fs.realpathSync(path.dirname(temporary)), path.join(packageRoot, 'bin'))
    ) return null
    return filename
  } catch {
    return null
  }
}

function exactArchiveEnvironment(environment) {
  if (process.platform === 'win32') return environment === process.env
  return exactPlainOptions(environment, ['LANG', 'LC_ALL', 'PATH']) &&
    environment.LANG === posixArchiveEnvironment.LANG &&
    environment.LC_ALL === posixArchiveEnvironment.LC_ALL &&
    environment.PATH === posixArchiveEnvironment.PATH
}

function trustedLifecycleShell() {
  const configured = process.env.npm_config_script_shell
  if (process.platform === 'win32') {
    const systemRoot = process.env.SystemRoot
    if (typeof systemRoot !== 'string' || systemRoot.includes('\0')) return null
    const expected = path.win32.join(systemRoot, 'System32', 'cmd.exe')
    return typeof configured === 'string' &&
      path.win32.normalize(configured).toLowerCase() === path.win32.normalize(expected).toLowerCase()
      ? configured
      : null
  }
  if (configured !== '/bin/sh') return null
  try {
    const resolved = fs.realpathSync(configured)
    const stat = fs.lstatSync(resolved)
    return stat.isFile() && !stat.isSymbolicLink() && stat.uid === 0 &&
      (stat.mode & 0o022) === 0 && (stat.mode & 0o111) !== 0
      ? configured
      : null
  } catch {
    return null
  }
}

function stableCurrentNode(command) {
  if (!sameLocalPath(command, process.execPath)) return false
  try {
    const stat = fs.lstatSync(command)
    return stat.isFile() && !stat.isSymbolicLink() && stat.size > 0 &&
      stat.size <= 256 * 1024 * 1024 && sameLocalPath(fs.realpathSync(command), command) &&
      (process.platform === 'win32' || (stat.mode & 0o111) !== 0)
  } catch {
    return false
  }
}

function isConfinedYarnPnpPackage(packageRoot, consumerRoot) {
  try {
    const consumerStat = fs.lstatSync(consumerRoot)
    if (!consumerStat.isDirectory() || consumerStat.isSymbolicLink()) return false
    const canonicalConsumer = fs.realpathSync(consumerRoot)
    const relative = path.relative(canonicalConsumer, packageRoot).split(path.sep).join('/')
    return /^\.yarn\/unplugged\/[A-Za-z0-9._-]{1,255}\/node_modules\/zigcss$/.test(relative)
  } catch {
    return false
  }
}

function exactYarnPnpNodeOptions(environment, consumerRoot) {
  if (typeof environment?.NODE_OPTIONS !== 'string' || typeof process.env.NODE_OPTIONS !== 'string') {
    return false
  }
  try {
    const canonicalConsumer = fs.realpathSync(consumerRoot)
    const pnpLoader = path.join(canonicalConsumer, '.pnp.cjs')
    const esmLoader = path.join(canonicalConsumer, '.pnp.loader.mjs')
    for (const filename of [pnpLoader, esmLoader]) {
      const stat = fs.lstatSync(filename)
      if (
        !stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > 16 * 1024 * 1024 ||
        fs.realpathSync(filename) !== filename || /[\0\r\n\s]/.test(filename)
      ) return false
    }
    return environment.NODE_OPTIONS === [
      `--require ${pnpLoader}`,
      `--experimental-loader ${pathToFileURL(esmLoader).href}`,
      process.env.NODE_OPTIONS,
    ].join(' ')
  } catch {
    return false
  }
}

function installAssetProcessBoundary(denyProcess) {
  const originalSpawn = childProcess.spawn
  const originalSpawnSync = childProcess.spawnSync
  const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
  let admittedChildSpawn = false
  let admittedOperations = 0
  let admittedArchive = null
  const lifecycleRequested = process.env.npm_lifecycle_event === 'postinstall' ||
    process.env.npm_lifecycle_script === 'node install.js'
  const npmLifecycle = lifecycleRequested
    ? canonicalLifecyclePackage(process.cwd(), process.env, true)
    : null
  if (lifecycleRequested && npmLifecycle === null) fail('installer lifecycle identity is invalid')
  const directInstallerRequested = process.argv.length === 2 &&
    path.basename(process.argv[1] ?? '') === 'install.js'
  const directInstaller = !lifecycleRequested && directInstallerRequested
    ? canonicalLifecyclePackage(path.dirname(process.argv[1]), process.env, true, false)
    : null
  if (directInstallerRequested && npmLifecycle === null && directInstaller === null) {
    fail('recovery installer identity is invalid')
  }
  const lifecycle = npmLifecycle ?? directInstaller

  immutableFunction(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn(...args) {
    if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
    return Reflect.apply(originalChildSpawn, this, args)
  })

  if (lifecycle !== null) {
    process.once('exit', code => {
      if (code !== 0) {
        fs.writeSync(2, `release smoke preload: installer stopped after ${admittedOperations} of 2 admitted archive operations\n`)
      }
    })
    immutableFunction(childProcess, 'spawnSync', function guardedArchiveListing(command, args, options) {
      const archive = Array.isArray(args) ? lifecycleArchivePath(args[1], lifecycle.root) : null
      if (
        admittedOperations !== 0 || archive === null || !trustedArchiveExecutable(command) ||
        !exactDataArray(args, ['-tf', archive]) ||
        !exactPlainOptions(options, [
          'cwd', 'encoding', 'env', 'killSignal', 'maxBuffer', 'timeout', 'windowsHide',
        ]) ||
        !sameLocalPath(options.cwd, path.dirname(archive)) || options.encoding !== 'utf8' ||
        !exactArchiveEnvironment(options.env) || options.killSignal !== 'SIGKILL' ||
        options.maxBuffer !== maximumManifestBytes || options.timeout !== requestTimeoutMs ||
        options.windowsHide !== true
      ) return denyProcess('child_process.spawnSync')
      admittedOperations += 1
      admittedArchive = archive
      return Reflect.apply(originalSpawnSync, this, [command, args, options])
    })
    immutableFunction(childProcess, 'spawn', function guardedArchiveExtraction(command, args, options) {
      const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
      if (
        admittedOperations !== 1 || !trustedArchiveExecutable(command) ||
        !exactDataArray(args, ['-xOf', admittedArchive, binaryName]) ||
        !exactPlainOptions(options, ['cwd', 'env', 'stdio', 'windowsHide']) ||
        !sameLocalPath(options.cwd, path.dirname(admittedArchive)) ||
        !exactArchiveEnvironment(options.env) ||
        !exactDataArray(options.stdio, ['ignore', 'pipe', 'pipe']) || options.windowsHide !== true
      ) return denyProcess('child_process.spawn')
      admittedOperations += 1
      admittedChildSpawn = true
      try {
        return Reflect.apply(originalSpawn, this, [command, args, options])
      } finally {
        admittedChildSpawn = false
      }
    })
  } else {
    let lifecycleSpawnStage = 'not-attempted'
    process.once('exit', code => {
      if (code !== 0 && lifecycleSpawnStage.startsWith('rejected-')) {
        fs.writeSync(2, `release smoke preload: lifecycle child ${lifecycleSpawnStage}\n`)
      }
    })
    immutableFunction(childProcess, 'spawnSync', () => denyProcess('child_process.spawnSync'))
    immutableFunction(childProcess, 'spawn', function guardedLifecycleSpawn(command, args, options) {
      lifecycleSpawnStage = 'checking'
      const expectedShell = trustedLifecycleShell()
      const optionKeys = process.platform === 'win32'
        ? ['env', 'stdioString', 'stdio', 'cwd', 'shell', 'windowsVerbatimArguments']
        : ['env', 'stdioString', 'stdio', 'cwd', 'shell']
      const lifecyclePackage = options !== null && typeof options === 'object'
        ? canonicalLifecyclePackage(options.cwd, options.env, false)
        : null
      const expectedArgs = process.platform === 'win32'
        ? ['/d', '/s', '/c', 'node install.js']
        : ['-c', 'node install.js']
      const lifecycleChecks = Object.freeze({
        shell: expectedShell !== null && sameLocalPath(command, expectedShell),
        package: lifecyclePackage !== null,
        arguments: exactDataArray(args, expectedArgs),
        options: exactPlainOptions(options, optionKeys),
        shellDisabled: options?.shell === false,
        stdio: options?.stdio === 'inherit',
        stdioString: [undefined, true].includes(options?.stdioString),
        windowsArguments: process.platform !== 'win32' || options?.windowsVerbatimArguments === true,
        node: stableCurrentNode(process.execPath),
      })
      const lifecycleRejection = Object.entries(lifecycleChecks)
        .find(([, admitted]) => !admitted)?.[0] ?? null
      const npmLifecycleAdmitted = lifecycleRejection === null
      const directInstaller = isPlainDenseArray(args, 1) && args.length === 1 &&
        typeof args[0] === 'string'
        ? canonicalLifecyclePackage(path.dirname(args[0]), options?.env, false, false)
        : null
      const yarnPnpAdmitted = directInstaller !== null && stableCurrentNode(command) &&
        exactDataArray(args, [directInstaller.installerFile]) &&
        exactPlainOptions(options, ['cwd', 'env', 'stdio']) &&
        sameLocalPath(options.cwd, process.cwd()) &&
        exactDataArray(options.stdio, [process.stdin, process.stdout, process.stderr]) &&
        isConfinedYarnPnpPackage(directInstaller.root, options.cwd) &&
        exactYarnPnpNodeOptions(options.env, options.cwd) &&
        options.env.COREPACK_ENABLE_NETWORK === '0' &&
        options.env.YARN_ENABLE_NETWORK === 'false' &&
        options.env.npm_config_offline === 'true' &&
        options.env.npm_config_registry === 'http://127.0.0.1:9/' &&
        options.env.npm_config_proxy === 'http://127.0.0.1:9' &&
        options.env.npm_config_https_proxy === 'http://127.0.0.1:9'
      if (admittedOperations !== 0 || (!npmLifecycleAdmitted && !yarnPnpAdmitted)) {
        lifecycleSpawnStage = admittedOperations !== 0
          ? 'rejected-operation-count'
          : `rejected-${lifecycleRejection ?? 'recovery-shape'}`
        return denyProcess(`child_process.spawn:${lifecycleSpawnStage}`)
      }
      admittedOperations += 1
      lifecycleSpawnStage = 'admitted'
      admittedChildSpawn = true
      try {
        if (npmLifecycleAdmitted) {
          return Reflect.apply(originalSpawn, this, [
            process.execPath,
            [lifecyclePackage.installerFile],
            {
              cwd: lifecyclePackage.root,
              env: options.env,
              stdio: 'inherit',
              windowsHide: true,
            },
          ])
        }
        return Reflect.apply(originalSpawn, this, [command, args, options])
      } finally {
        admittedChildSpawn = false
      }
    })
  }

  for (const name of ['exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']) {
    immutableFunction(childProcess, name, () => denyProcess(`child_process.${name}`))
  }
}

if (process.env.ZIGCSS_RELEASE_SMOKE !== '1') fail('explicit smoke authority is required')

const assetRootInput = process.env.ZIGCSS_RELEASE_SMOKE_ASSET_ROOT
const version = process.env.ZIGCSS_RELEASE_SMOKE_VERSION
const archiveName = process.env.ZIGCSS_RELEASE_SMOKE_ARCHIVE
const checksumsName = process.env.ZIGCSS_RELEASE_SMOKE_CHECKSUMS
if (typeof assetRootInput !== 'string' || typeof version !== 'string') fail('asset root and version are required')
if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.test(version)) fail('version is invalid')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(archiveName ?? '')) fail('archive name is invalid')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(checksumsName ?? '')) fail('checksum name is invalid')
if (archiveName === checksumsName) fail('archive and checksum names must be distinct')

const assetDirectory = canonicalSmokeDirectory(assetRootInput, 'asset root', true)
const assetRoot = assetDirectory.path

function readBoundedAssetEntries() {
  const entries = []
  try {
    while (true) {
      const entry = assetDirectory.handle.readSync()
      if (entry === null) break
      if (entries.length === maximumAssetEntries) {
        fail(`asset root must contain at most ${maximumAssetEntries} entries`)
      }
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(entry.name)) {
        fail('asset root contains a noncanonical entry name')
      }
      entries.push(entry)
    }
  } finally {
    assetDirectory.handle.closeSync()
  }
  const after = fs.lstatSync(assetRoot, { bigint: true })
  if (!after.isDirectory() || !sameStableIdentity(assetDirectory.stat, after)) {
    fail('asset root changed while its bounded inventory was admitted')
  }
  return entries
}

const assetEntries = readBoundedAssetEntries()

function openReleaseAsset(requestedName, maximumBytes) {
  const entry = assetEntries.find(candidate => candidate.name === requestedName)
  if (entry === undefined || !entry.isFile() || entry.isSymbolicLink()) {
    fail(`${requestedName} must be a nonempty regular file`)
  }
  const name = entry.name
  const filename = path.join(assetRoot, name)
  let descriptor
  try {
    try {
      descriptor = fs.openSync(
        filename,
        fs.constants.O_RDONLY |
          (fs.constants.O_NOFOLLOW ?? 0) |
          (fs.constants.O_NONBLOCK ?? 0) |
          (fs.constants.O_CLOEXEC ?? 0),
      )
    } catch (error) {
      fail(`${name} is unavailable: ${error.message}`)
    }
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const canonical = fs.realpathSync(filename)
    const pathStat = fs.lstatSync(canonical, { bigint: true })
    if (
      !opened.isFile() || !pathStat.isFile() || pathStat.isSymbolicLink() ||
      opened.nlink !== 1n || !sameStableIdentity(opened, pathStat) ||
      !sameLocalPath(canonical, filename) || opened.size <= 0n ||
      opened.size > BigInt(maximumBytes)
    ) fail(`${name} must be a bounded stable regular file inside the asset root`)
    const asset = Object.freeze({
      ctimeNs: opened.ctimeNs,
      descriptor,
      dev: opened.dev,
      ino: opened.ino,
      mtimeNs: opened.mtimeNs,
      size: Number(opened.size),
    })
    descriptor = undefined
    return { asset, name }
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

const allowed = new Map()
try {
  for (const [requestedName, maximumBytes] of [
    [archiveName, maximumArchiveBytes],
    [checksumsName, maximumManifestBytes],
  ]) {
    const { asset, name } = openReleaseAsset(requestedName, maximumBytes)
    allowed.set(
      `https://github.com/vyakymenko/zigcss/releases/download/v${version}/${name}`,
      asset,
    )
  }
  const after = fs.lstatSync(assetRoot, { bigint: true })
  if (!after.isDirectory() || !sameStableIdentity(assetDirectory.stat, after)) {
    fail('asset root changed while its fixed release files were opened')
  }
} catch (error) {
  for (const asset of allowed.values()) fs.closeSync(asset.descriptor)
  throw error
}

function createAssetReadStream(asset) {
  let offset = 0
  return new Readable({
    read() {
      if (offset === asset.size) {
        this.push(null)
        return
      }

      try {
        const current = fs.fstatSync(asset.descriptor, { bigint: true })
        if (
          !current.isFile() || current.dev !== asset.dev || current.ino !== asset.ino ||
          current.size !== BigInt(asset.size) || current.mtimeNs !== asset.mtimeNs ||
          current.ctimeNs !== asset.ctimeNs
        ) fail('release asset changed after descriptor admission')

        const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, asset.size - offset))
        const bytesRead = fs.readSync(
          asset.descriptor,
          chunk,
          0,
          chunk.length,
          offset,
        )
        if (bytesRead <= 0) fail('release asset descriptor ended before its admitted size')
        offset += bytesRead
        this.push(bytesRead === chunk.length ? chunk : chunk.subarray(0, bytesRead))
      } catch (error) {
        this.destroy(error)
      }
    },
  })
}

function installAssetService() {
  https.get = function smokeGet(url, options, callback) {
    if (typeof options === 'function' && callback === undefined) callback = options
    if (typeof callback !== 'function') fail('HTTPS callback is required')
    const request = new EventEmitter()
    request.setTimeout = () => request
    request.destroy = error => queueMicrotask(() => request.emit('error', error))

    queueMicrotask(() => {
      let requested
      try {
        requested = new URL(url).href
      } catch (error) {
        request.emit('error', error)
        return
      }
      const asset = allowed.get(requested)
      if (asset === undefined) {
        request.emit('error', new Error(`release smoke blocked unexpected HTTPS request ${requested}`))
        return
      }
      const response = createAssetReadStream(asset)
      response.statusCode = 200
      response.headers = { 'content-length': String(asset.size) }
      callback(response)
    })
    return request
  }

  const allowedHttpsGet = https.get
  const networkError = operation => boundaryError(
    'ZIGCSS_NETWORK_DISABLED',
    `release smoke blocked ${operation}`,
  )
  const denyProcess = operation => {
    throw boundaryError('ZIGCSS_PROCESS_DISABLED', `release smoke blocked ${operation}`)
  }
  installProcessEscapeBoundary(denyProcess, networkError)
  installAssetProcessBoundary(denyProcess)
  installNetworkBoundary(networkError, { allowedHttpsGet })
}

const runtimeSystemExecutables = new Set([
  '/bin/bash',
  '/bin/sh',
  '/bin/zsh',
  '/usr/bin/bash',
  '/usr/bin/sh',
  '/usr/bin/zsh',
])

function openRuntimeFile(
  filename,
  label,
  maximumBytes,
  permitEmpty,
  flags = fs.constants.O_RDONLY,
  allowSystemExecutable = false,
) {
  let descriptor
  try {
    descriptor = fs.openSync(
      filename,
      flags |
        (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0) |
        (fs.constants.O_CLOEXEC ?? 0),
    )
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const canonical = fs.realpathSync(filename)
    const pathStat = fs.lstatSync(canonical, { bigint: true })
    const admittedCanonicalSystemPath =
      allowSystemExecutable && runtimeSystemExecutables.has(canonical)
    if (
      !opened.isFile() || !pathStat.isFile() || pathStat.isSymbolicLink() ||
      !sameStableIdentity(opened, pathStat) ||
      (!admittedCanonicalSystemPath && !sameLocalPath(canonical, filename)) ||
      (!permitEmpty && opened.size === 0n) || opened.size > BigInt(maximumBytes)
    ) fail(`${label} must be a bounded stable regular file`)
    return { canonical, descriptor, stat: opened }
  } catch (error) {
    if (descriptor !== undefined) fs.closeSync(descriptor)
    throw error
  }
}

function canonicalRuntimeFile(filename, label, maximumBytes, allowSystemExecutable = false) {
  const opened = openRuntimeFile(
    filename,
    label,
    maximumBytes,
    false,
    fs.constants.O_RDONLY,
    allowSystemExecutable,
  )
  fs.closeSync(opened.descriptor)
  return opened.canonical
}

function exactRuntimeTracePath(input, traceRootInput, traceRoot) {
  const admittedName = runtimeTraceNames
    .find(name => sameLocalPath(path.join(traceRootInput, name), input))
  if (admittedName === undefined) fail('runtime trace must use one exact admitted filename')
  return path.join(traceRoot, admittedName)
}

function exactRuntimeBinaryPath(input, traceRoot) {
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const fixtureName = process.platform === 'win32' ? 'native-fixture.exe' : 'sh'
  const localRelatives = [
    ['direct', binaryName],
    ['consumer', 'node_modules', 'zigcss', 'bin', binaryName],
    [fixtureName],
  ]
  const localRelative = localRelatives.find(segments => sameLocalPath(
    path.join(traceRoot, ...segments),
    input,
  ))
  if (localRelative !== undefined) {
    return Object.freeze({ path: path.join(traceRoot, ...localRelative), system: false })
  }
  const system = [...runtimeSystemExecutables].find(candidate => candidate === input)
  if (process.platform !== 'darwin' || system === undefined) {
    fail('runtime binary must use one exact admitted filename')
  }
  return Object.freeze({ path: system, system: true })
}

function installRuntimeTrace() {
  for (const asset of allowed.values()) fs.closeSync(asset.descriptor)
  allowed.clear()
  const traceRootInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT
  const traceInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE
  const binaryInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY
  if (typeof traceRootInput !== 'string') fail('runtime trace root is required')
  const traceDirectory = canonicalSmokeDirectory(traceRootInput, 'runtime trace root')
  const traceRoot = traceDirectory.path
  let openedTrace
  let expectedBinary
  try {
    openedTrace = openRuntimeFile(
      exactRuntimeTracePath(traceInput, traceRootInput, traceRoot),
      'runtime trace',
      maximumTraceBytes,
      true,
      fs.constants.O_RDWR | fs.constants.O_APPEND,
    )
    const admittedBinary = exactRuntimeBinaryPath(binaryInput, traceRoot)
    expectedBinary = canonicalRuntimeFile(
      admittedBinary.path,
      'runtime binary',
      256 * 1024 * 1024,
      admittedBinary.system,
    )
    const after = fs.lstatSync(traceRoot, { bigint: true })
    if (!after.isDirectory() || !sameStableIdentity(traceDirectory.stat, after)) {
      fail('runtime trace root changed during descriptor admission')
    }
  } catch (error) {
    if (openedTrace !== undefined) fs.closeSync(openedTrace.descriptor)
    throw error
  } finally {
    traceDirectory.handle.closeSync()
  }
  const traceDescriptor = openedTrace.descriptor

  let nativeSpawns = 0
  let networkAttempts = 0
  let deniedProcessAttempts = 0

  function record(event) {
    const before = fs.fstatSync(traceDescriptor, { bigint: true })
    if (!before.isFile() || before.size > BigInt(maximumTraceBytes)) {
      fail('runtime trace changed type or exceeded its byte limit')
    }
    const bytes = Buffer.from(`${JSON.stringify({ event, pid: process.pid })}\n`)
    if (before.size + BigInt(bytes.length) > BigInt(maximumTraceBytes)) {
      fail('runtime trace exceeds its byte limit')
    }
    let offset = 0
    while (offset < bytes.length) {
      const written = fs.writeSync(traceDescriptor, bytes, offset, bytes.length - offset, null)
      if (written === 0) fail('runtime trace write made no progress')
      offset += written
    }
    const after = fs.fstatSync(traceDescriptor, { bigint: true })
    if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino ||
        after.size !== before.size + BigInt(bytes.length)) {
      fail('runtime trace write changed identity or size')
    }
  }

  function denyProcess(operation) {
    deniedProcessAttempts += 1
    record('process-denied')
    throw boundaryError('ZIGCSS_PROCESS_DISABLED', `release smoke blocked ${operation}`)
  }

  function networkError(operation) {
    networkAttempts += 1
    record('network-denied')
    return boundaryError('ZIGCSS_NETWORK_DISABLED', `release smoke blocked ${operation}`)
  }

  installProcessEscapeBoundary(denyProcess, networkError)

  const originalSpawn = childProcess.spawn
  const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
  let admittedChildSpawn = false
  immutableFunction(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn(...args) {
    if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
    return Reflect.apply(originalChildSpawn, this, args)
  })
  immutableFunction(childProcess, 'spawn', function tracedNativeSpawn(command, args, options) {
    let canonicalCommand
    try {
      if (!sameLocalPath(command, expectedBinary)) {
        throw new Error('spawn command does not match the admitted binary')
      }
      canonicalCommand = canonicalRuntimeFile(
        expectedBinary,
        'spawn command',
        256 * 1024 * 1024,
        process.platform === 'darwin',
      )
    } catch {
      return denyProcess('unexpected child process')
    }
    const plainOptions = options !== null
      && typeof options === 'object'
      && Object.getPrototypeOf(options) === Object.prototype
    const optionKeys = plainOptions
      ? Reflect.ownKeys(options)
      : []
    const plainArgs = isPlainDenseArray(args, 64)
    const inheritedCliShape = (
      plainArgs
      && plainOptions
      && optionKeys.length === 2
      && optionKeys.includes('stdio')
      && optionKeys.includes('cwd')
      && options.stdio === 'inherit'
      && options.cwd === process.cwd()
    )
    const framedNodeApiShape = (
      plainArgs
      && args.length === 1
      && args[0] === '--internal-node-v1'
      && optionKeys.length === 3
      && optionKeys.includes('shell')
      && optionKeys.includes('windowsHide')
      && optionKeys.includes('stdio')
      && options.shell === false
      && options.windowsHide === true
      && isPlainDenseArray(options.stdio, 3)
      && options.stdio.length === 3
      && options.stdio.every(value => value === 'pipe')
    )
    if (
      !sameLocalPath(canonicalCommand, expectedBinary)
      || nativeSpawns !== 0
      || !plainArgs
      || args.some(arg => typeof arg !== 'string' || arg.includes('\0'))
      || !plainOptions
      || (!inheritedCliShape && !framedNodeApiShape)
    ) {
      return denyProcess('unexpected child process')
    }
    let child
    admittedChildSpawn = true
    try {
      child = Reflect.apply(originalSpawn, this, [command, args, options])
    } finally {
      admittedChildSpawn = false
    }
    nativeSpawns += 1
    record('native-spawn')
    return child
  })

  for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']) {
    immutableFunction(childProcess, name, function deniedChildProcess() {
      return denyProcess(`child_process.${name}`)
    })
  }

  installNetworkBoundary(networkError)

  record('runtime-start')
  process.on('exit', () => {
    const summary = `${JSON.stringify({
      event: 'runtime-summary',
      pid: process.pid,
      nativeSpawns,
      networkAttempts,
      deniedProcessAttempts,
    })}\n`
    const before = fs.fstatSync(traceDescriptor, { bigint: true })
    const bytes = Buffer.from(summary)
    if (!before.isFile() || before.size + BigInt(bytes.length) > BigInt(maximumTraceBytes)) {
      fail('runtime trace changed type or exceeded its byte limit')
    }
    try {
      let offset = 0
      while (offset < bytes.length) {
        const written = fs.writeSync(traceDescriptor, bytes, offset, bytes.length - offset, null)
        if (written === 0) fail('runtime summary write made no progress')
        offset += written
      }
      const after = fs.fstatSync(traceDescriptor, { bigint: true })
      if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino ||
          after.size !== before.size + BigInt(bytes.length)) {
        fail('runtime summary write changed identity or size')
      }
      fs.fsyncSync(traceDescriptor)
    } finally {
      fs.closeSync(traceDescriptor)
    }
  })
}

if (process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME === '1') installRuntimeTrace()
else installAssetService()
