'use strict'

const childProcess = require('node:child_process')
const cluster = require('node:cluster')
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
const tls = require('node:tls')
const workerThreads = require('node:worker_threads')

const maximumBinaryBytes = 256 * 1024 * 1024
const maximumTraceBytes = 256 * 1024
const maximumManifestBytes = 64 * 1024
const maximumTraceLockAttempts = 5_000
const traceLockWait = new Int32Array(new SharedArrayBuffer(4))

function fail(message) {
  throw new Error(`Astro offline preload: ${message}`)
}

if (process.env.ZIGCSS_ASTRO_OFFLINE !== '1') {
  fail('explicit offline-test authority is required')
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.mode === right.mode &&
    left.nlink === right.nlink
}

function sameIdentity(left, right) {
  return sameFileIdentity(left, right) && left.ctimeNs === right.ctimeNs &&
    left.mtimeNs === right.mtimeNs && left.size === right.size
}

function openBoundedRegularFile(
  filename,
  label,
  maximumBytes,
  flags,
  allowEmpty = false,
  mutableMetadata = false,
) {
  let descriptor
  try {
    descriptor = fs.openSync(
      filename,
      flags | (fs.constants.O_CLOEXEC ?? 0) | (fs.constants.O_NOFOLLOW ?? 0) |
        (fs.constants.O_NONBLOCK ?? 0),
    )
  } catch {
    fail(`${label} could not be opened safely`)
  }
  try {
    const opened = fs.fstatSync(descriptor, { bigint: true })
    const bound = fs.lstatSync(filename, { bigint: true })
    if (
      !opened.isFile() || !bound.isFile() || bound.isSymbolicLink() || opened.nlink !== 1n ||
      bound.nlink !== 1n || (!allowEmpty && opened.size === 0n) ||
      opened.size > BigInt(maximumBytes) || bound.size > BigInt(maximumBytes) ||
      !(mutableMetadata ? sameFileIdentity(opened, bound) : sameIdentity(opened, bound)) ||
      fs.realpathSync(filename) !== filename
    ) fail(`${label} must be a bounded canonical singly-linked regular non-symlink file`)
    return Object.freeze({ descriptor, stat: opened })
  } catch (error) {
    fs.closeSync(descriptor)
    throw error
  }
}

function readBoundedJson(filename, label) {
  const opened = openBoundedRegularFile(
    filename,
    label,
    maximumManifestBytes,
    fs.constants.O_RDONLY,
  )
  try {
    const bytes = Number(opened.stat.size)
    const content = Buffer.alloc(bytes)
    let offset = 0
    while (offset < bytes) {
      const count = fs.readSync(opened.descriptor, content, offset, bytes - offset, offset)
      if (count === 0) fail(`${label} ended before its declared size`)
      offset += count
    }
    const after = fs.fstatSync(opened.descriptor, { bigint: true })
    if (!sameIdentity(opened.stat, after)) fail(`${label} changed while reading`)
    return JSON.parse(content.toString('utf8'))
  } finally {
    fs.closeSync(opened.descriptor)
  }
}

function captureAllowedBinary(input, expectedRelative, label) {
  if (input === undefined) return null
  const expected = path.join(traceRoot, expectedRelative)
  if (input !== expected) fail(`${label} must equal its exact staged path`)
  const opened = openBoundedRegularFile(expected, label, maximumBinaryBytes, fs.constants.O_RDONLY)
  try {
    if (process.platform !== 'win32' && (opened.stat.mode & 0o111n) === 0n) {
      fail(`${label} must be executable`)
    }
    return Object.freeze({
      path: expected,
      ctimeNs: opened.stat.ctimeNs,
      dev: opened.stat.dev,
      ino: opened.stat.ino,
      mode: opened.stat.mode,
      mtimeNs: opened.stat.mtimeNs,
      size: opened.stat.size,
    })
  } finally {
    fs.closeSync(opened.descriptor)
  }
}

const traceRootInput = process.env.ZIGCSS_ASTRO_TRACE_ROOT
const traceInput = process.env.ZIGCSS_ASTRO_TRACE
if (typeof traceRootInput !== 'string' || typeof traceInput !== 'string') {
  fail('trace root and trace file are required')
}
const traceRoot = fs.realpathSync(__dirname)
const temporaryRoot = fs.realpathSync(os.tmpdir())
const relativeTraceRoot = path.relative(temporaryRoot, traceRoot)
if (
  path.dirname(relativeTraceRoot) !== '.' ||
  !/^zigcss-astro-(?:boundary-)?[A-Za-z0-9]{6}$/.test(relativeTraceRoot) ||
  traceRootInput !== traceRoot
) fail('trace root must be this preload\'s admitted temporary directory')
const trace = path.join(traceRoot, 'offline-trace.jsonl')
if (traceInput !== trace) fail('trace file must use the admitted fixed filename')
const openedTraceFile = openBoundedRegularFile(
  trace,
  'trace',
  maximumTraceBytes,
  fs.constants.O_WRONLY | fs.constants.O_APPEND,
  true,
  true,
)
const traceFd = openedTraceFile.descriptor
const openedTrace = openedTraceFile.stat
const traceLock = path.join(traceRoot, '.zigcss-trace.lock')

function acquireTraceLock() {
  for (let attempt = 0; attempt < maximumTraceLockAttempts; attempt += 1) {
    let descriptor
    try {
      descriptor = fs.openSync(
        traceLock,
        fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
          (fs.constants.O_CLOEXEC ?? 0) | (fs.constants.O_NOFOLLOW ?? 0),
        0o600,
      )
    } catch (error) {
      if (error?.code !== 'EEXIST') fail('trace lock could not be created safely')
      Atomics.wait(traceLockWait, 0, 0, 1)
      continue
    }
    const opened = fs.fstatSync(descriptor, { bigint: true })
    if (!opened.isFile() || opened.nlink !== 1n) {
      fs.closeSync(descriptor)
      fs.unlinkSync(traceLock)
      fail('trace lock must be a singly-linked regular file')
    }
    return descriptor
  }
  fail('trace lock acquisition timed out')
}

function withTraceLock(action) {
  const descriptor = acquireTraceLock()
  try {
    return action()
  } finally {
    fs.closeSync(descriptor)
    fs.unlinkSync(traceLock)
  }
}

let deniedProcessAttempts = 0
let esbuildSpawns = 0
let nativeSpawns = 0
let networkAttempts = 0

const allowedBinaryIdentity = captureAllowedBinary(
  process.env.ZIGCSS_ASTRO_ALLOWED_BINARY,
  path.join(
    'project',
    'node_modules',
    'zigcss',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  ),
  'allowed native binary',
)
const allowedBinary = allowedBinaryIdentity?.path ?? null

const esbuildPlatformPackages = Object.freeze({
  'aix-ppc64-BE': '@esbuild/aix-ppc64',
  'darwin-arm64-LE': '@esbuild/darwin-arm64',
  'darwin-x64-LE': '@esbuild/darwin-x64',
  'freebsd-arm64-LE': '@esbuild/freebsd-arm64',
  'freebsd-x64-LE': '@esbuild/freebsd-x64',
  'linux-arm-LE': '@esbuild/linux-arm',
  'linux-arm64-LE': '@esbuild/linux-arm64',
  'linux-ia32-LE': '@esbuild/linux-ia32',
  'linux-loong64-LE': '@esbuild/linux-loong64',
  'linux-mips64el-LE': '@esbuild/linux-mips64el',
  'linux-ppc64-LE': '@esbuild/linux-ppc64',
  'linux-riscv64-LE': '@esbuild/linux-riscv64',
  'linux-s390x-BE': '@esbuild/linux-s390x',
  'linux-x64-LE': '@esbuild/linux-x64',
  'netbsd-arm64-LE': '@esbuild/netbsd-arm64',
  'netbsd-x64-LE': '@esbuild/netbsd-x64',
  'openbsd-arm64-LE': '@esbuild/openbsd-arm64',
  'openbsd-x64-LE': '@esbuild/openbsd-x64',
  'sunos-x64-LE': '@esbuild/sunos-x64',
  'win32-arm64-LE': '@esbuild/win32-arm64',
  'win32-ia32-LE': '@esbuild/win32-ia32',
  'win32-x64-LE': '@esbuild/win32-x64',
})
const esbuildPlatformPackage = esbuildPlatformPackages[`${process.platform}-${process.arch}-${os.endianness()}`]
const allowedEsbuildInput = process.env.ZIGCSS_ASTRO_ALLOWED_ESBUILD_BINARY
let allowedEsbuild = null
let allowedEsbuildIdentity = null
if (allowedEsbuildInput !== undefined) {
  if (esbuildPlatformPackage === undefined) fail('the current platform has no reviewed native esbuild package')
  if (process.env.ESBUILD_BINARY_PATH !== allowedEsbuildInput) {
    fail('ESBUILD_BINARY_PATH must equal the reviewed esbuild binary')
  }
  const esbuildSubpath = process.platform === 'win32' ? 'esbuild.exe' : path.join('bin', 'esbuild')
  const expectedRelative = path.join(
    'project',
    'node_modules',
    ...esbuildPlatformPackage.split('/'),
    esbuildSubpath,
  )
  allowedEsbuildIdentity = captureAllowedBinary(
    allowedEsbuildInput,
    expectedRelative,
    'allowed esbuild binary',
  )
  allowedEsbuild = allowedEsbuildIdentity.path
  const manifestFile = path.join(
    traceRoot,
    'project',
    'node_modules',
    ...esbuildPlatformPackage.split('/'),
    'package.json',
  )
  const manifest = readBoundedJson(manifestFile, 'esbuild platform manifest')
  if (
    manifest.name !== esbuildPlatformPackage || manifest.version !== '0.28.2' ||
    !Array.isArray(manifest.os) || manifest.os.length !== 1 || manifest.os[0] !== process.platform ||
    !Array.isArray(manifest.cpu) || manifest.cpu.length !== 1 || manifest.cpu[0] !== process.arch
  ) fail('esbuild platform package must match the reviewed platform and lock version 0.28.2')
} else if (process.env.ESBUILD_BINARY_PATH !== undefined && process.env.ESBUILD_BINARY_PATH !== '') {
  fail('ESBUILD_BINARY_PATH requires an explicitly reviewed esbuild binary')
}

function record(event) {
  withTraceLock(() => {
    const stat = fs.fstatSync(traceFd, { bigint: true })
    if (
      !stat.isFile() || stat.dev !== openedTrace.dev || stat.ino !== openedTrace.ino ||
      stat.nlink !== 1n || stat.size > BigInt(maximumTraceBytes)
    ) fail('trace changed identity or exceeded its byte limit')
    const line = `${JSON.stringify({
      deniedProcessAttempts,
      esbuildSpawns,
      event,
      nativeSpawns,
      networkAttempts,
      pid: process.pid,
    })}\n`
    const bytes = Buffer.byteLength(line)
    if (stat.size + BigInt(bytes) > BigInt(maximumTraceBytes)) fail('trace exceeds its byte limit')
    const written = fs.writeSync(traceFd, line, null, 'utf8')
    if (written !== bytes) fail('trace write was incomplete')
    const after = fs.fstatSync(traceFd, { bigint: true })
    if (
      after.dev !== stat.dev || after.ino !== stat.ino || after.nlink !== 1n ||
      after.size !== stat.size + BigInt(bytes)
    ) fail('trace changed unexpectedly while writing')
  })
}

function processError(operation) {
  deniedProcessAttempts += 1
  record(`process-denied:${operation}`)
  const error = new Error(`Astro offline test blocked ${operation}`)
  error.code = 'ZIGCSS_PROCESS_DISABLED'
  return error
}

function denyProcess(operation) {
  throw processError(operation)
}

function immutable(target, name, value) {
  const descriptor = Object.getOwnPropertyDescriptor(target, name)
  Object.defineProperty(target, name, {
    configurable: false,
    enumerable: descriptor?.enumerable ?? true,
    value,
    writable: false,
  })
}

if (typeof process.execve === 'function') {
  immutable(process, 'execve', function deniedExecve() {
    return denyProcess('process.execve')
  })
}
if (typeof process._debugProcess === 'function') {
  immutable(process, '_debugProcess', function deniedDebugProcess() {
    throw networkError('process._debugProcess')
  })
}
if (typeof process._kill === 'function') {
  immutable(process, '_kill', function deniedPrivateKill() {
    throw networkError('process._kill')
  })
}
immutable(process, 'kill', function deniedKill() {
  return denyProcess('process.kill')
})

immutable(cluster, 'fork', function deniedClusterFork() {
  return denyProcess('cluster.fork')
})
if (typeof workerThreads.Worker !== 'function') fail('worker_threads.Worker must be available')
immutable(workerThreads, 'Worker', class DisabledWorker {
  constructor() {
    return denyProcess('worker_threads.Worker')
  }
})

function exactDataArray(value, expected) {
  if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype || value.length !== expected.length) {
    return false
  }
  const keys = Reflect.ownKeys(value)
  if (
    keys.length !== expected.length + 1 || keys.at(-1) !== 'length' ||
    keys.slice(0, -1).some((key, index) => key !== String(index))
  ) return false
  return expected.every((item, index) => {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index))
    return descriptor !== undefined && Object.hasOwn(descriptor, 'value') && descriptor.value === item
  })
}

function exactPlainOptions(value, expectedKeys) {
  if (value === null || typeof value !== 'object' || Object.getPrototypeOf(value) !== Object.prototype) return false
  const keys = Reflect.ownKeys(value)
  if (keys.length !== expectedKeys.length || expectedKeys.some(key => !keys.includes(key))) return false
  return keys.every(key => {
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    return typeof key === 'string' && descriptor !== undefined && Object.hasOwn(descriptor, 'value')
  })
}

function stableAllowedBinary(command, expectedPath, identity) {
  if (expectedPath === null || command !== expectedPath) return false
  try {
    const stat = fs.lstatSync(command, { bigint: true })
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1n &&
      fs.realpathSync(command) === expectedPath &&
      stat.ctimeNs === identity.ctimeNs && stat.dev === identity.dev &&
      stat.ino === identity.ino && stat.mode === identity.mode &&
      stat.mtimeNs === identity.mtimeNs && stat.size === identity.size
  } catch {
    return false
  }
}

const originalSpawn = childProcess.spawn
const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
let admittedChildSpawn = false
immutable(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn(...args) {
  if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
  return Reflect.apply(originalChildSpawn, this, args)
})
immutable(childProcess, 'spawn', function guardedNativeSpawn(command, args, options) {
  const zigcssAdmitted = stableAllowedBinary(command, allowedBinary, allowedBinaryIdentity) &&
    exactDataArray(args, ['--internal-node-v1']) &&
    exactPlainOptions(options, ['shell', 'windowsHide', 'stdio']) &&
    options.shell === false && options.windowsHide === true &&
    exactDataArray(options.stdio, ['pipe', 'pipe', 'pipe'])
  const esbuildAdmitted = esbuildSpawns === 0 &&
    stableAllowedBinary(command, allowedEsbuild, allowedEsbuildIdentity) &&
    exactDataArray(args, ['--service=0.28.2', '--ping']) &&
    exactPlainOptions(options, ['windowsHide', 'stdio', 'cwd']) &&
    options.windowsHide === true && options.cwd === path.join(traceRoot, 'project') &&
    exactDataArray(options.stdio, ['pipe', 'pipe', 'inherit'])
  if (!zigcssAdmitted && !esbuildAdmitted) return denyProcess('child_process.spawn')
  let child
  admittedChildSpawn = true
  try {
    child = Reflect.apply(originalSpawn, this, [command, args, options])
  } finally {
    admittedChildSpawn = false
  }
  if (zigcssAdmitted) {
    nativeSpawns += 1
    record('native-spawn')
  } else {
    esbuildSpawns += 1
    record('esbuild-spawn')
  }
  return child
})
for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']) {
  immutable(childProcess, name, function deniedChildProcess() {
    return denyProcess(`child_process.${name}`)
  })
}

function networkError(operation) {
  networkAttempts += 1
  record(`network-denied:${operation}`)
  const error = new Error(`Astro offline test blocked ${operation}`)
  error.code = 'ZIGCSS_NETWORK_DISABLED'
  return error
}

function deny(operation) {
  return function deniedNetworkOperation() {
    throw networkError(operation)
  }
}

function reject(operation) {
  return function rejectedNetworkOperation() {
    return Promise.reject(networkError(operation))
  }
}

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
immutable(process, 'binding', function guardedBinding(name) {
  if (typeof name !== 'string') return denyProcess('process.binding:invalid')
  const label = /^[a-z0-9_]{1,64}$/.test(name) ? name : 'invalid'
  if (label === 'invalid') return denyProcess('process.binding:invalid')
  if (blockedProcessBindings.has(name)) return denyProcess(`process.binding:${label}`)
  if (blockedNetworkBindings.has(name)) throw networkError(`process.binding:${label}`)
  return Reflect.apply(originalProcessBinding, process, [name])
})
immutable(process, '_linkedBinding', function deniedLinkedBinding() {
  return denyProcess('process._linkedBinding')
})

immutable(http, 'request', deny('http.request'))
immutable(http, 'get', deny('http.get'))
immutable(https, 'request', deny('https.request'))
immutable(https, 'get', deny('https.get'))
immutable(http, 'ClientRequest', class DisabledClientRequest {
  constructor() {
    throw networkError('http.ClientRequest')
  }
})
immutable(http.Agent.prototype, 'createConnection', deny('http.Agent.createConnection'))
immutable(https.Agent.prototype, 'createConnection', deny('https.Agent.createConnection'))
immutable(http, 'createServer', deny('http.createServer'))
immutable(https, 'createServer', deny('https.createServer'))
immutable(http, '_connectionListener', deny('http._connectionListener'))
immutable(http2, 'connect', deny('http2.connect'))
immutable(http2, 'createServer', deny('http2.createServer'))
immutable(http2, 'createSecureServer', deny('http2.createSecureServer'))
if (typeof http2.performServerHandshake === 'function') {
  immutable(http2, 'performServerHandshake', deny('http2.performServerHandshake'))
}
immutable(inspector, 'open', deny('inspector.open'))
immutable(net, 'connect', deny('net.connect'))
immutable(net, 'createConnection', deny('net.createConnection'))
immutable(net, '_createServerHandle', deny('net._createServerHandle'))
immutable(net.Socket.prototype, 'connect', deny('net.Socket.connect'))
immutable(net.Server.prototype, 'listen', deny('net.Server.listen'))
immutable(net.Server.prototype, '_listen2', deny('net.Server._listen2'))
immutable(tls, 'connect', deny('tls.connect'))
immutable(tls, 'createServer', deny('tls.createServer'))
immutable(dgram, 'createSocket', deny('dgram.createSocket'))
immutable(dgram, '_createSocketHandle', deny('dgram._createSocketHandle'))
immutable(dgram, 'Socket', class DisabledDatagramSocket {
  constructor() {
    throw networkError('dgram.Socket')
  }
})

const allowedDnsConfigurationFunctions = new Set([
  'getDefaultResultOrder',
  'getServers',
  'setDefaultResultOrder',
])
if (typeof dns.setDefaultResultOrder === 'function') dns.setDefaultResultOrder('verbatim')
for (const name of Object.keys(dns)) {
  if (
    name !== 'Resolver' && !allowedDnsConfigurationFunctions.has(name) &&
    typeof dns[name] === 'function'
  ) immutable(dns, name, deny(`dns.${name}`))
}
immutable(dns, 'Resolver', class DisabledDnsResolver {
  constructor() {
    throw networkError('dns.Resolver')
  }
})
const allowedDnsPromisesConfigurationFunctions = new Set([
  'getDefaultResultOrder',
  'getServers',
  'setDefaultResultOrder',
])
for (const name of Object.keys(dnsPromises)) {
  if (
    name !== 'Resolver' && name !== 'lookup' &&
    !allowedDnsPromisesConfigurationFunctions.has(name) &&
    typeof dnsPromises[name] === 'function'
  ) {
    immutable(dnsPromises, name, reject(`dns.promises.${name}`))
  }
}
immutable(dnsPromises, 'lookup', reject('dns.promises.lookup'))
immutable(dnsPromises, 'Resolver', class DisabledDnsPromisesResolver {
  constructor() {
    throw networkError('dns.promises.Resolver')
  }
})

immutable(globalThis, 'fetch', reject('globalThis.fetch'))
const DisabledWebSocket = class DisabledWebSocket {
  constructor() {
    throw networkError('WebSocket')
  }
}
if (typeof http.WebSocket === 'function') {
  immutable(http, 'WebSocket', DisabledWebSocket)
}
if (typeof globalThis.WebSocket === 'function') {
  immutable(globalThis, 'WebSocket', DisabledWebSocket)
}

record('runtime-start')
process.on('exit', () => {
  record('runtime-summary')
  fs.closeSync(traceFd)
})
