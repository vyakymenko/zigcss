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
const maximumTraceLockAttempts = 5_000
const traceLockWait = new Int32Array(new SharedArrayBuffer(4))

function fail(message) {
  throw new Error(`Next Webpack offline preload: ${message}`)
}

if (process.env.ZIGCSS_NEXT_WEBPACK_OFFLINE !== '1') {
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

const traceRootInput = process.env.ZIGCSS_NEXT_WEBPACK_TRACE_ROOT
const traceInput = process.env.ZIGCSS_NEXT_WEBPACK_TRACE
const buildId = process.env.ZIGCSS_NEXT_WEBPACK_BUILD_ID
if (
  typeof traceRootInput !== 'string' || typeof traceInput !== 'string' ||
  typeof buildId !== 'string' || !/^[a-f0-9]{32}$/.test(buildId)
) {
  fail('trace root, trace file, and bounded build identity are required')
}
const traceRoot = fs.realpathSync(__dirname)
const temporaryRoot = fs.realpathSync(os.tmpdir())
const relativeTraceRoot = path.relative(temporaryRoot, traceRoot)
if (
  path.dirname(relativeTraceRoot) !== '.' ||
  !/^zigcss-next-webpack-(?:boundary-)?[A-Za-z0-9]{6}$/.test(relativeTraceRoot) ||
  traceRootInput !== traceRoot
) fail('trace root must be this preload\'s admitted temporary directory')
const buildTrace = path.join(traceRoot, 'build-trace.jsonl')
const boundaryTrace = path.join(traceRoot, 'trace.jsonl')
let trace
if (traceInput === buildTrace) trace = buildTrace
else if (traceInput === boundaryTrace) trace = boundaryTrace
else fail('trace file must use an admitted fixed filename')
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

function captureBinary(input, expectedRelative, label) {
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

const allowedBinary = captureBinary(
  process.env.ZIGCSS_NEXT_WEBPACK_ALLOWED_BINARY,
  path.join(
    'project',
    'node_modules',
    'zigcss',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  ),
  'allowed ZigCSS binary',
)
const nodeBinary = (() => {
  const canonical = fs.realpathSync(process.execPath)
  const stat = fs.lstatSync(canonical, { bigint: true })
  if (!stat.isFile() || stat.isSymbolicLink()) fail('Node executable must be a canonical regular file')
  return Object.freeze({
    path: canonical,
    ctimeNs: stat.ctimeNs,
    dev: stat.dev,
    ino: stat.ino,
    mode: stat.mode,
    mtimeNs: stat.mtimeNs,
    size: stat.size,
  })
})()
const inheritedEnvironment = Object.freeze(Object.fromEntries([
  'ZIGCSS_NEXT_WEBPACK_ALLOWED_BINARY',
  'ZIGCSS_NEXT_WEBPACK_BUILD_ID',
  'ZIGCSS_NEXT_WEBPACK_OFFLINE',
  'ZIGCSS_NEXT_WEBPACK_TRACE',
  'ZIGCSS_NEXT_WEBPACK_TRACE_ROOT',
].map(name => [name, process.env[name]])))
const nodeOptionsInput = process.env.NODE_OPTIONS
const requirePrefix = '--require='
const sourceMapsSuffix = ' --enable-source-maps'
if (typeof nodeOptionsInput !== 'string' || !nodeOptionsInput.startsWith(requirePrefix)) {
  fail('NODE_OPTIONS must contain only this preload')
}
const requireAndOptions = nodeOptionsInput.slice(requirePrefix.length)
const requireInput = requireAndOptions.endsWith(sourceMapsSuffix)
  ? requireAndOptions.slice(0, -sourceMapsSuffix.length)
  : requireAndOptions
let requiredPreload
try {
  requiredPreload = requireInput.startsWith('"') ? JSON.parse(requireInput) : requireInput
} catch {
  fail('NODE_OPTIONS preload argument is malformed')
}
if (
  typeof requiredPreload !== 'string' || requiredPreload.length === 0 ||
  /[\0\r\n]/.test(requiredPreload) || requiredPreload !== __filename
) fail('NODE_OPTIONS must name only this exact preload')
const formattedWorkerNodeOptions = `${requirePrefix}${
  requiredPreload.includes(' ') ? JSON.stringify(requiredPreload) : requiredPreload
}`
const allowedWorkerNodeOptions = new Set([
  nodeOptionsInput,
  formattedWorkerNodeOptions,
  `${formattedWorkerNodeOptions}${sourceMapsSuffix}`,
])

let deniedProcessAttempts = 0
let nativeSpawns = 0
let networkAttempts = 0
let nodeSpawns = 0

function record(event, details = {}) {
  withTraceLock(() => {
    const stat = fs.fstatSync(traceFd, { bigint: true })
    if (
      !stat.isFile() || stat.dev !== openedTrace.dev || stat.ino !== openedTrace.ino ||
      stat.nlink !== 1n || stat.size > BigInt(maximumTraceBytes)
    ) fail('trace changed identity or exceeded its byte limit')
    const line = `${JSON.stringify({
      buildId,
      deniedProcessAttempts,
      event,
      nativeSpawns,
      networkAttempts,
      nodeSpawns,
      pid: process.pid,
      ppid: process.ppid,
      ...details,
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

function stableBinary(command, expected) {
  if (typeof command !== 'string') return false
  let canonical
  try {
    canonical = fs.realpathSync(command)
  } catch {
    return false
  }
  if (canonical !== expected.path) return false
  try {
    const stat = fs.lstatSync(canonical, { bigint: true })
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1n &&
      stat.ctimeNs === expected.ctimeNs && stat.dev === expected.dev &&
      stat.ino === expected.ino && stat.mode === expected.mode &&
      stat.mtimeNs === expected.mtimeNs && stat.size === expected.size
  } catch {
    return false
  }
}

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

function isExactNativeSpawn(command, args, options) {
  return stableBinary(command, allowedBinary) &&
    exactDataArray(args, ['--internal-node-v1']) &&
    exactPlainOptions(options, ['shell', 'windowsHide', 'stdio']) &&
    options.shell === false && options.windowsHide === true &&
    exactDataArray(options.stdio, ['pipe', 'pipe', 'pipe'])
}

function offlineEnvironmentMismatch(options) {
  const env = options?.env ?? process.env
  if (env === null || typeof env !== 'object') return 'shape'
  if (!allowedWorkerNodeOptions.has(env.NODE_OPTIONS)) return 'env-NODE_OPTIONS'
  for (const [name, value] of Object.entries(inheritedEnvironment)) {
    if (env[name] !== value) return `env-${name}`
  }
  if (options?.execPath !== undefined && !stableBinary(options.execPath, nodeBinary)) return 'execPath'
  return null
}

function confinedNextModule(modulePath) {
  if (
    typeof modulePath !== 'string' || modulePath.length === 0 ||
    Buffer.byteLength(modulePath) > 4096 || !path.isAbsolute(modulePath)
  ) return null
  let canonical
  try {
    canonical = fs.realpathSync(modulePath)
  } catch {
    return null
  }
  const nextRoot = path.join(traceRoot, 'project', 'node_modules', 'next')
  const relative = path.relative(nextRoot, canonical)
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative) || path.extname(canonical) !== '.js') {
    return null
  }
  const stat = fs.lstatSync(canonical)
  if (!stat.isFile() || stat.isSymbolicLink()) return null
  return relative.split(path.sep).join('/')
}

function processError(operation) {
  deniedProcessAttempts += 1
  record(`process-denied:${operation}`)
  const error = new Error(`Next Webpack offline test blocked ${operation}`)
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

const originalSpawn = childProcess.spawn
const originalFork = childProcess.fork
const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
let admittedChildSpawn = false
immutable(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn(...args) {
  if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
  return Reflect.apply(originalChildSpawn, this, args)
})
immutable(childProcess, 'spawn', function guardedSpawn(command, args, options) {
  const native = isExactNativeSpawn(command, args, options)
  if (!native) return denyProcess('child_process.spawn')
  let child
  admittedChildSpawn = true
  try {
    child = Reflect.apply(originalSpawn, this, [command, args, options])
  } finally {
    admittedChildSpawn = false
  }
  nativeSpawns += 1
  record('native-spawn', { argv: ['--internal-node-v1'], command: allowedBinary.path })
  return child
})

immutable(childProcess, 'fork', function guardedFork(modulePath, args, options) {
  const actualArgs = Array.isArray(args) ? args : []
  const actualOptions = Array.isArray(args) ? options : args
  const relativeModule = confinedNextModule(modulePath)
  if (relativeModule !== 'dist/compiled/jest-worker/processChild.js') {
    return denyProcess('child_process.fork:module')
  }
  if (!exactDataArray(actualArgs, [])) return denyProcess('child_process.fork:arguments')
  if (!exactPlainOptions(actualOptions, ['cwd', 'env', 'execArgv', 'silent'])) {
    return denyProcess('child_process.fork:options')
  }
  if (
    actualOptions.cwd !== path.join(traceRoot, 'project') || actualOptions.silent !== true ||
    !exactDataArray(actualOptions.execArgv, [])
  ) return denyProcess('child_process.fork:options')
  const environmentMismatch = offlineEnvironmentMismatch(actualOptions)
  if (environmentMismatch !== null) {
    return denyProcess(`child_process.fork:environment:${environmentMismatch}`)
  }
  let child
  admittedChildSpawn = true
  try {
    child = Reflect.apply(originalFork, this, arguments)
  } finally {
    admittedChildSpawn = false
  }
  nodeSpawns += 1
  record('node-fork', { argv: [...actualArgs], module: relativeModule })
  return child
})

for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', '_forkChild']) {
  immutable(childProcess, name, function deniedChildProcess() {
    return denyProcess(`child_process.${name}`)
  })
}

function networkError(operation) {
  networkAttempts += 1
  record(`network-denied:${operation}`)
  const error = new Error(`Next Webpack offline test blocked ${operation}`)
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
immutable(http, 'createServer', deny('http.createServer'))
immutable(https, 'createServer', deny('https.createServer'))
immutable(http2, 'connect', deny('http2.connect'))
immutable(http2, 'createServer', deny('http2.createServer'))
immutable(http2, 'createSecureServer', deny('http2.createSecureServer'))
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
for (const name of Object.keys(dnsPromises)) {
  if (name !== 'Resolver' && name !== 'lookup' && typeof dnsPromises[name] === 'function') {
    immutable(dnsPromises, name, reject(`dns.promises.${name}`))
  }
}
immutable(dnsPromises, 'lookup', reject('dns.promises.lookup'))
immutable(dnsPromises, 'Resolver', class DisabledDnsPromisesResolver {
  constructor() {
    throw networkError('dns.promises.Resolver')
  }
})

let guardedFetch = reject('globalThis.fetch')
let admittedFetchAssignments = 0
const fetchDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'fetch')
Object.defineProperty(globalThis, 'fetch', {
  configurable: false,
  enumerable: fetchDescriptor?.enumerable ?? true,
  get() {
    return guardedFetch
  },
  set(value) {
    const admitted = admittedFetchAssignments === 0 && process.env.IS_NEXT_WORKER === 'true' &&
      typeof value === 'function' && value.name === 'fetch' && value.__nextPatched === true &&
      typeof value.__nextGetStaticStore === 'function' && typeof value._nextOriginalFetch === 'function'
    if (!admitted) throw networkError('globalThis.fetch-assignment')
    admittedFetchAssignments += 1
    guardedFetch = value
    record('next-fetch-wrapper-allowed')
  },
})
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
process.on('exit', () => record('runtime-summary'))
