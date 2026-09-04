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
const path = require('node:path')
const tls = require('node:tls')
const workerThreads = require('node:worker_threads')

const maximumBinaryBytes = 256 * 1024 * 1024
const maximumTraceBytes = 256 * 1024

function fail(message) {
  throw new Error(`Turbopack offline preload: ${message}`)
}

if (process.env.ZIGCSS_TURBOPACK_OFFLINE !== '1') {
  fail('explicit offline-test authority is required')
}

const traceRootInput = process.env.ZIGCSS_TURBOPACK_TRACE_ROOT
const traceInput = process.env.ZIGCSS_TURBOPACK_TRACE
if (typeof traceRootInput !== 'string' || typeof traceInput !== 'string') {
  fail('trace root and trace file are required')
}
const traceRootStat = fs.lstatSync(traceRootInput, { bigint: true })
if (!traceRootStat.isDirectory() || traceRootStat.isSymbolicLink()) {
  fail('trace root must be a regular non-symlink directory')
}
const traceRoot = fs.realpathSync(traceRootInput)
const traceStat = fs.lstatSync(traceInput, { bigint: true })
if (
  !traceStat.isFile() || traceStat.isSymbolicLink() || traceStat.nlink !== 1n ||
  traceStat.size > BigInt(maximumTraceBytes)
) fail('trace must be a bounded singly-linked regular non-symlink file')
const trace = fs.realpathSync(traceInput)
if (path.dirname(trace) !== traceRoot) fail('trace file escapes its root')
const traceFd = fs.openSync(
  trace,
  fs.constants.O_WRONLY | fs.constants.O_APPEND | (fs.constants.O_NOFOLLOW ?? 0),
)
const openedTrace = fs.fstatSync(traceFd, { bigint: true })
if (
  !openedTrace.isFile() || openedTrace.dev !== traceStat.dev || openedTrace.ino !== traceStat.ino ||
  openedTrace.nlink !== 1n
) {
  fs.closeSync(traceFd)
  fail('trace identity changed while opening')
}

function captureAllowedBinary(input) {
  if (input === undefined) return null
  if (
    typeof input !== 'string' || input.length === 0 || !path.isAbsolute(input) ||
    path.resolve(input) !== input || Buffer.byteLength(input) > 4096 || /[\0\r\n]/.test(input)
  ) fail('allowed ZigCSS binary must be a bounded normalized absolute path')
  const expected = path.join(
    'project', 'node_modules', 'zigcss', 'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  )
  if (path.relative(traceRoot, input) !== expected) {
    fail('allowed ZigCSS binary must use its exact staged path')
  }
  const stat = fs.lstatSync(input, { bigint: true })
  if (
    !stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1n || stat.size <= 0n ||
    stat.size > BigInt(maximumBinaryBytes) || fs.realpathSync(input) !== input
  ) fail('allowed ZigCSS binary must be a bounded canonical singly-linked regular file')
  if (process.platform !== 'win32' && (stat.mode & 0o111n) === 0n) {
    fail('allowed ZigCSS binary must be executable')
  }
  return Object.freeze({
    path: input,
    ctimeNs: stat.ctimeNs,
    dev: stat.dev,
    ino: stat.ino,
    mode: stat.mode,
    mtimeNs: stat.mtimeNs,
    size: stat.size,
  })
}

const allowedBinary = captureAllowedBinary(process.env.ZIGCSS_TURBOPACK_ALLOWED_BINARY)
const preloadFile = fs.realpathSync(__filename)
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
  typeof requiredPreload !== 'string' || requiredPreload.length === 0 || /[\0\r\n]/.test(requiredPreload) ||
  fs.realpathSync(requiredPreload) !== preloadFile
) fail('NODE_OPTIONS must resolve only to this preload')
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
let workerSpawns = 0

function record(event) {
  const stat = fs.fstatSync(traceFd, { bigint: true })
  if (
    !stat.isFile() || stat.dev !== openedTrace.dev || stat.ino !== openedTrace.ino ||
    stat.nlink !== 1n || stat.size > BigInt(maximumTraceBytes)
  ) fail('trace changed identity or exceeded its byte limit')
  const line = `${JSON.stringify({
    deniedProcessAttempts,
    event,
    nativeSpawns,
    networkAttempts,
    nodeSpawns,
    pid: process.pid,
    ppid: process.ppid,
    workerSpawns,
  })}\n`
  const bytes = Buffer.byteLength(line)
  if (stat.size + BigInt(bytes) > BigInt(maximumTraceBytes)) fail('trace exceeds its byte limit')
  if (fs.writeSync(traceFd, line, null, 'utf8') !== bytes) fail('trace write was incomplete')
}

function processError(operation) {
  deniedProcessAttempts += 1
  record(`process-denied:${operation}`)
  const error = new Error(`Turbopack offline test blocked ${operation}`)
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

function stableAllowedBinary(command) {
  if (allowedBinary === null || command !== allowedBinary.path) return false
  try {
    const stat = fs.lstatSync(command, { bigint: true })
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1n &&
      fs.realpathSync(command) === allowedBinary.path &&
      stat.ctimeNs === allowedBinary.ctimeNs && stat.dev === allowedBinary.dev &&
      stat.ino === allowedBinary.ino && stat.mode === allowedBinary.mode &&
      stat.mtimeNs === allowedBinary.mtimeNs && stat.size === allowedBinary.size
  } catch {
    return false
  }
}

const originalSpawn = childProcess.spawn
const originalFork = childProcess.fork
const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
let admittedChildSpawn = false
immutable(childProcess.ChildProcess.prototype, 'spawn', function guardedChildSpawn(...args) {
  if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
  return Reflect.apply(originalChildSpawn, this, args)
})
immutable(childProcess, 'spawn', function guardedSpawn(command, args, options) {
  const admitted = stableAllowedBinary(command) &&
    exactDataArray(args, ['--internal-node-v1']) &&
    exactPlainOptions(options, ['shell', 'windowsHide', 'stdio']) &&
    options.shell === false && options.windowsHide === true &&
    exactDataArray(options.stdio, ['pipe', 'pipe', 'pipe'])
  if (!admitted) return denyProcess('child_process.spawn')
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
function confinedNextForkModule(modulePath) {
  if (
    typeof modulePath !== 'string' || modulePath.length === 0 || Buffer.byteLength(modulePath) > 4096 ||
    !path.isAbsolute(modulePath) || /[\0\r\n]/.test(modulePath)
  ) return false
  let canonical
  try {
    canonical = fs.realpathSync(modulePath)
  } catch {
    return false
  }
  const nextRoot = path.join(traceRoot, 'project', 'node_modules', 'next')
  if (path.relative(nextRoot, canonical) !== path.join('dist', 'compiled', 'jest-worker', 'processChild.js')) {
    return false
  }
  const stat = fs.lstatSync(canonical)
  return stat.isFile() && !stat.isSymbolicLink()
}
function exactNextForkEnvironment(env) {
  if (env === null || typeof env !== 'object' || Object.getPrototypeOf(env) !== Object.prototype) return 'shape'
  const keys = Reflect.ownKeys(env)
  if (keys.some(key => typeof key !== 'string')) return 'symbol-key'
  const expected = new Set([
    ...Object.keys(process.env),
    'IS_NEXT_WORKER',
    'NODE_OPTIONS',
    '__NEXT_PRERENDER_CLIENT_ASSET_SUFFIX',
  ])
  const extra = keys.filter(key => !expected.has(key))
  const missing = [...expected].filter(key => !keys.includes(key))
  if (extra.length !== 0 || missing.length !== 0) {
    const label = [...extra.map(key => `extra-${key}`), ...missing.map(key => `missing-${key}`)].join(',')
    return `keys-${label.slice(0, 256)}`
  }
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(env, key)
    if (descriptor === undefined || !Object.hasOwn(descriptor, 'value')) return `descriptor-${key}`
    if (key === 'NODE_OPTIONS') {
      if (!allowedWorkerNodeOptions.has(descriptor.value)) return 'value-NODE_OPTIONS'
    } else if (key === 'IS_NEXT_WORKER') {
      if (descriptor.value !== 'true') return 'value-IS_NEXT_WORKER'
    } else if (key === '__NEXT_PRERENDER_CLIENT_ASSET_SUFFIX') {
      if (descriptor.value !== '') return 'value-__NEXT_PRERENDER_CLIENT_ASSET_SUFFIX'
    } else if (descriptor.value !== process.env[key]) {
      return `value-${key}`
    }
  }
  return null
}
immutable(childProcess, 'fork', function guardedFork(modulePath, args, options) {
  const actualArgs = Array.isArray(args) ? args : []
  const actualOptions = Array.isArray(args) ? options : args
  if (!confinedNextForkModule(modulePath)) return denyProcess('child_process.fork:module')
  if (!exactDataArray(actualArgs, [])) return denyProcess('child_process.fork:arguments')
  if (!exactPlainOptions(actualOptions, ['cwd', 'env', 'execArgv', 'silent'])) {
    return denyProcess('child_process.fork:options-shape')
  }
  if (actualOptions.cwd !== path.join(traceRoot, 'project')) return denyProcess('child_process.fork:cwd')
  if (actualOptions.silent !== true) return denyProcess('child_process.fork:silent')
  if (!exactDataArray(actualOptions.execArgv, [])) return denyProcess('child_process.fork:execArgv')
  const environmentMismatch = exactNextForkEnvironment(actualOptions.env)
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
  record('next-node-fork')
  return child
})
for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', '_forkChild']) {
  immutable(childProcess, name, function deniedChildProcess() {
    return denyProcess(`child_process.${name}`)
  })
}
immutable(cluster, 'fork', function deniedClusterFork() {
  return denyProcess('cluster.fork')
})
const originalWorker = workerThreads.Worker
function confinedNextWorker(filename) {
  if (
    typeof filename !== 'string' || filename.length === 0 || Buffer.byteLength(filename) > 4096 ||
    !path.isAbsolute(filename) || /[\0\r\n]/.test(filename)
  ) return false
  let canonical
  try {
    canonical = fs.realpathSync(filename)
  } catch {
    return false
  }
  const nextRoot = path.join(traceRoot, 'project', 'node_modules', 'next')
  if (path.relative(nextRoot, canonical) !== path.join('dist', 'compiled', 'jest-worker', 'threadChild.js')) {
    return false
  }
  const stat = fs.lstatSync(canonical)
  if (!stat.isFile() || stat.isSymbolicLink()) return false
  try {
    const manifestFile = path.join(nextRoot, 'package.json')
    const manifestStat = fs.lstatSync(manifestFile)
    if (
      !manifestStat.isFile() || manifestStat.isSymbolicLink() || manifestStat.size < 1 ||
      manifestStat.size > 64 * 1024 || fs.realpathSync(manifestFile) !== manifestFile
    ) return false
    const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
    return manifest.name === 'next' && manifest.version === '16.3.4'
  } catch {
    return false
  }
}
function exactNextWorkerEnvironment(env) {
  if (env === null || typeof env !== 'object' || Object.getPrototypeOf(env) !== Object.prototype) return false
  const keys = Reflect.ownKeys(env)
  if (keys.some(key => typeof key !== 'string')) return false
  const overrides = Object.freeze({
    IS_NEXT_WORKER: 'true',
    NEXT_PRIVATE_BUILD_WORKER: '1',
  })
  const expected = new Set([...Object.keys(process.env), ...Object.keys(overrides)])
  if (keys.length !== expected.size || keys.some(key => !expected.has(key))) return false
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(env, key)
    if (descriptor === undefined || !Object.hasOwn(descriptor, 'value')) return false
    if (key === 'NODE_OPTIONS') {
      if (!allowedWorkerNodeOptions.has(descriptor.value)) return false
    } else {
      const value = Object.hasOwn(overrides, key) ? overrides[key] : process.env[key]
      if (descriptor.value !== value) return false
    }
  }
  return true
}
immutable(workerThreads, 'Worker', class GuardedWorker extends originalWorker {
  constructor(filename, options) {
    const admitted = confinedNextWorker(filename) &&
      exactPlainOptions(options, [
        'eval', 'resourceLimits', 'stderr', 'stdout', 'workerData', 'env', 'execArgv',
      ]) &&
      options.eval === false && options.stderr === true && options.stdout === true &&
      options.workerData === undefined && exactPlainOptions(options.resourceLimits, []) &&
      exactDataArray(options.execArgv, []) && exactNextWorkerEnvironment(options.env)
    if (!admitted) return denyProcess('worker_threads.Worker')
    super(filename, options)
    workerSpawns += 1
    record('next-turbopack-worker')
  }
})
if (typeof process.execve === 'function') {
  immutable(process, 'execve', function deniedExecve() {
    return denyProcess('process.execve')
  })
}
if (typeof process._debugProcess === 'function') {
  immutable(process, '_debugProcess', function deniedDebugProcess() {
    return denyProcess('process._debugProcess')
  })
}
if (typeof process._kill === 'function') {
  immutable(process, '_kill', function deniedPrivateKill() {
    return denyProcess('process._kill')
  })
}
immutable(process, 'kill', function deniedKill() {
  return denyProcess('process.kill')
})

const blockedProcessBindings = new Set(['process_wrap', 'spawn_sync'])
const blockedNetworkBindings = new Set([
  'cares_wrap', 'inspector', 'pipe_wrap', 'tcp_wrap', 'tls_wrap', 'udp_wrap',
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

function networkError(operation) {
  networkAttempts += 1
  record(`network-denied:${operation}`)
  const error = new Error(`Turbopack offline test blocked ${operation}`)
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

function isLoopbackHost(hostname) {
  return typeof hostname === 'string' && (
    hostname.toLowerCase() === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname === '::1'
  )
}

function localLookupResult(hostname, options) {
  const family = typeof options === 'number' ? options : options?.family
  const result = hostname === '::1' || (hostname.toLowerCase() === 'localhost' && family === 6)
    ? { address: '::1', family: 6 }
    : { address: '127.0.0.1', family: 4 }
  return typeof options === 'object' && options !== null && options.all === true ? [result] : result
}

function localLookup(hostname, options, callback) {
  if (!isLoopbackHost(hostname)) throw networkError('dns.lookup')
  const actualOptions = typeof options === 'function' ? undefined : options
  const actualCallback = typeof options === 'function' ? options : callback
  if (typeof actualCallback !== 'function') throw new TypeError('dns.lookup callback is required')
  const result = localLookupResult(hostname, actualOptions)
  record('localhost-resolution-allowed:dns.lookup')
  process.nextTick(() => {
    if (Array.isArray(result)) actualCallback(null, result)
    else actualCallback(null, result.address, result.family)
  })
}

function localPromisesLookup(hostname, options) {
  if (!isLoopbackHost(hostname)) return Promise.reject(networkError('dns.promises.lookup'))
  record('localhost-resolution-allowed:dns.promises.lookup')
  return Promise.resolve(localLookupResult(hostname, options))
}

function confinedIpcPath(value) {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > 4096 || /[\0\r\n]/.test(value)) {
    return false
  }
  if (process.platform === 'win32' && value.startsWith('\\\\.\\pipe\\')) return false
  if (!path.isAbsolute(value) || path.resolve(value) !== value) return false
  const relative = path.relative(traceRoot, value)
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative)
}

function localIpcArguments(args) {
  const normalized = Array.isArray(args[0]) ? args[0] : args
  const first = normalized[0]
  const localPath = typeof first === 'string' ? first : first?.path
  if (confinedIpcPath(localPath)) return true

  const port = first !== null && typeof first === 'object' ? first.port : first
  const host = first !== null && typeof first === 'object' ? first.host : normalized[1]
  return (
    (Number.isSafeInteger(port) || (typeof port === 'string' && /^\d+$/.test(port))) &&
    Number(port) > 0 &&
    Number(port) <= 65535 &&
    (host === undefined || host === 'localhost' || host === '127.0.0.1' || host === '::1')
  )
}

function localListenArguments(args) {
  const first = args[0]
  const localPath = typeof first === 'string' ? first : first?.path
  if (confinedIpcPath(localPath)) return args

  const port = first !== null && typeof first === 'object' ? first.port : first
  if (
    !(Number.isSafeInteger(port) || (typeof port === 'string' && /^\d+$/.test(port))) ||
    Number(port) < 0 ||
    Number(port) > 65535
  ) return null

  if (first !== null && typeof first === 'object') {
    const host = first.host
    if (host === '127.0.0.1' || host === '::1') return args
    if (host === undefined || host === null || host === 'localhost') {
      return [{ ...first, host: '127.0.0.1' }, ...args.slice(1)]
    }
    return null
  }

  const host = args[1]
  if (host === '127.0.0.1' || host === '::1') return args
  if (host === undefined || host === null || host === 'localhost' ||
      typeof host === 'function' || Number.isSafeInteger(host)) {
    return [first, '127.0.0.1', ...args.slice(1)]
  }
  return null
}

function localInternalListenArguments(args) {
  if (confinedIpcPath(args[0]) && (args[1] === -1 || args[1] === undefined)) return true
  const host = args[0]
  const port = args[1]
  return (host === '127.0.0.1' || host === '::1') &&
    Number.isSafeInteger(port) && port >= 0 && port <= 65535
}

function allowLocalIpc(operation, implementation) {
  return function localIpcOrDeniedNetwork(...args) {
    if (!localIpcArguments(args)) throw networkError(operation)
    record(`local-ipc-allowed:${operation}`)
    return Reflect.apply(implementation, this, args)
  }
}

function allowLocalListen(operation, implementation) {
  return function loopbackListenOrDeniedNetwork(...args) {
    const localArgs = localListenArguments(args)
    if (localArgs === null) throw networkError(operation)
    record(`local-ipc-allowed:${operation}`)
    return Reflect.apply(implementation, this, localArgs)
  }
}

function allowInternalLocalListen(operation, implementation) {
  return function internalLocalListenOrDeniedNetwork(...args) {
    if (!localInternalListenArguments(args)) throw networkError(operation)
    record(`local-ipc-allowed:${operation}`)
    return Reflect.apply(implementation, this, args)
  }
}

const originalNetConnect = net.connect
const originalNetCreateConnection = net.createConnection
const originalSocketConnect = net.Socket.prototype.connect
const originalServerListen = net.Server.prototype.listen
const originalServerListen2 = net.Server.prototype._listen2
immutable(net, 'connect', allowLocalIpc('net.connect', originalNetConnect))
immutable(net, 'createConnection', allowLocalIpc('net.createConnection', originalNetCreateConnection))
immutable(net.Socket.prototype, 'connect', allowLocalIpc('net.Socket.connect', originalSocketConnect))
immutable(net.Server.prototype, 'listen', allowLocalListen('net.Server.listen', originalServerListen))
immutable(net, '_createServerHandle', deny('net._createServerHandle'))
immutable(net.Server.prototype, '_listen2', allowInternalLocalListen('net.Server._listen2', originalServerListen2))

immutable(http, 'request', deny('http.request'))
immutable(http, 'get', deny('http.get'))
immutable(https, 'request', deny('https.request'))
immutable(https, 'get', deny('https.get'))
immutable(http, 'createServer', deny('http.createServer'))
immutable(https, 'createServer', deny('https.createServer'))
immutable(http.Server.prototype, 'listen', deny('http.Server.listen'))
immutable(https.Server.prototype, 'listen', deny('https.Server.listen'))
immutable(http.Agent.prototype, 'createConnection', deny('http.Agent.createConnection'))
immutable(https.Agent.prototype, 'createConnection', deny('https.Agent.createConnection'))
immutable(http2, 'connect', deny('http2.connect'))
immutable(http2, 'createServer', deny('http2.createServer'))
immutable(http2, 'createSecureServer', deny('http2.createSecureServer'))
immutable(inspector, 'open', deny('inspector.open'))
immutable(tls, 'connect', deny('tls.connect'))
immutable(tls, 'createServer', deny('tls.createServer'))
immutable(tls.Server.prototype, 'listen', deny('tls.Server.listen'))
if (typeof tls.TLSSocket?.prototype?.connect === 'function') {
  immutable(tls.TLSSocket.prototype, 'connect', deny('tls.TLSSocket.connect'))
}
immutable(dgram, 'createSocket', deny('dgram.createSocket'))
immutable(dgram, '_createSocketHandle', deny('dgram._createSocketHandle'))
immutable(dgram, 'Socket', class DisabledDatagramSocket {
  constructor() {
    throw networkError('dgram.Socket')
  }
})

const allowedDnsConfigurationFunctions = new Set([
  'getDefaultResultOrder', 'getServers', 'setDefaultResultOrder',
])
for (const name of Object.keys(dns)) {
  if (
    name !== 'Resolver' && name !== 'lookup' && !allowedDnsConfigurationFunctions.has(name) &&
    typeof dns[name] === 'function'
  ) immutable(dns, name, deny(`dns.${name}`))
}
immutable(dns, 'lookup', localLookup)
immutable(dns, 'Resolver', class DisabledDnsResolver {
  constructor() {
    throw networkError('dns.Resolver')
  }
})
for (const name of Object.keys(dnsPromises)) {
  if (
    name !== 'Resolver' && name !== 'lookup' && !allowedDnsConfigurationFunctions.has(name) &&
    typeof dnsPromises[name] === 'function'
  ) {
    immutable(dnsPromises, name, reject(`dns.promises.${name}`))
  }
}
immutable(dnsPromises, 'lookup', localPromisesLookup)
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
if (typeof http.WebSocket === 'function') immutable(http, 'WebSocket', DisabledWebSocket)
if (typeof globalThis.WebSocket === 'function') immutable(globalThis, 'WebSocket', DisabledWebSocket)

record('runtime-start')
process.on('exit', () => {
  record('runtime-summary')
  fs.closeSync(traceFd)
})
