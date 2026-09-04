'use strict'

const dgram = require('node:dgram')
const childProcess = require('node:child_process')
const cluster = require('node:cluster')
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

function fail(message) {
  throw new Error(`Nuxt offline preload: ${message}`)
}

if (process.env.ZIGCSS_NUXT_OFFLINE !== '1') {
  fail('explicit offline-test authority is required')
}

const traceRootInput = process.env.ZIGCSS_NUXT_TRACE_ROOT
const traceInput = process.env.ZIGCSS_NUXT_TRACE
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
) {
  fail('trace must be a bounded singly-linked regular non-symlink file')
}
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

let networkAttempts = 0
let deniedProcessAttempts = 0
let nativeSpawns = 0
let esbuildSpawns = 0

function captureAllowedBinary(input, expectedRelative, label) {
  if (input === undefined) return null
  if (
    typeof input !== 'string' || input.length === 0 || !path.isAbsolute(input) ||
    path.resolve(input) !== input || Buffer.byteLength(input) > 4096 || /[\0\r\n]/.test(input)
  ) fail(`${label} must be a bounded normalized absolute path`)
  if (path.relative(traceRoot, input) !== expectedRelative) {
    fail(`${label} must use its exact path under the temporary project`)
  }
  const stat = fs.lstatSync(input, { bigint: true })
  if (
    !stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1n || stat.size <= 0n ||
    stat.size > BigInt(maximumBinaryBytes) || fs.realpathSync(input) !== input
  ) {
    fail(`${label} must be a bounded canonical singly-linked regular non-symlink file`)
  }
  if (process.platform !== 'win32' && (stat.mode & 0o111n) === 0n) {
    fail(`${label} must be executable`)
  }
  return Object.freeze({
    path: input,
    dev: stat.dev,
    ino: stat.ino,
    mode: stat.mode,
    size: stat.size,
    mtimeNs: stat.mtimeNs,
    ctimeNs: stat.ctimeNs,
  })
}

const allowedBinary = captureAllowedBinary(
  process.env.ZIGCSS_NUXT_ALLOWED_BINARY,
  path.join(
    'project',
    'node_modules',
    'zigcss',
    'bin',
    process.platform === 'win32' ? 'zigcss.exe' : 'zigcss',
  ),
  'allowed ZigCSS binary',
)

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
const allowedEsbuildInput = process.env.ZIGCSS_NUXT_ALLOWED_ESBUILD_BINARY
if (allowedEsbuildInput !== undefined && esbuildPlatformPackage === undefined) {
  fail('the current platform has no reviewed native esbuild package')
}
if (
  allowedEsbuildInput !== undefined &&
  process.env.ESBUILD_BINARY_PATH !== allowedEsbuildInput
) fail('ESBUILD_BINARY_PATH must equal the reviewed esbuild binary')
const esbuildSubpath = process.platform === 'win32' ? 'esbuild.exe' : path.join('bin', 'esbuild')
const allowedEsbuild = allowedEsbuildInput === undefined ? null : captureAllowedBinary(
  allowedEsbuildInput,
  path.join('project', 'node_modules', ...esbuildPlatformPackage.split('/'), esbuildSubpath),
  'allowed esbuild binary',
)
if (allowedEsbuild !== null) {
  const manifestFile = path.join(traceRoot, 'project', 'node_modules', ...esbuildPlatformPackage.split('/'), 'package.json')
  const manifestStat = fs.lstatSync(manifestFile)
  if (
    !manifestStat.isFile() || manifestStat.isSymbolicLink() || manifestStat.size < 1 ||
    manifestStat.size > 64 * 1024 || fs.realpathSync(manifestFile) !== manifestFile
  ) fail('esbuild platform manifest must be a bounded canonical regular file')
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
  if (
    manifest.name !== esbuildPlatformPackage || manifest.version !== '0.28.2' ||
    !Array.isArray(manifest.os) || manifest.os.length !== 1 || manifest.os[0] !== process.platform ||
    !Array.isArray(manifest.cpu) || manifest.cpu.length !== 1 || manifest.cpu[0] !== process.arch
  ) {
    fail('esbuild platform package must match the reviewed lock version 0.28.2')
  }
} else if (process.env.ESBUILD_BINARY_PATH !== undefined && process.env.ESBUILD_BINARY_PATH !== '') {
  fail('ESBUILD_BINARY_PATH requires an explicitly reviewed esbuild binary')
}

function record(event) {
  const stat = fs.fstatSync(traceFd, { bigint: true })
  if (
    !stat.isFile() || stat.dev !== openedTrace.dev || stat.ino !== openedTrace.ino ||
    stat.nlink !== 1n || stat.size > BigInt(maximumTraceBytes)
  ) {
    fail('trace changed identity or exceeded its byte limit')
  }
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
}

function processError(operation) {
  deniedProcessAttempts += 1
  record(`process-denied:${operation}`)
  const error = new Error(`Nuxt offline test blocked ${operation}`)
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

function stableAllowedBinary(command, expected) {
  if (expected === null || command !== expected.path) return false
  try {
    const stat = fs.lstatSync(command, { bigint: true })
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1n &&
      fs.realpathSync(command) === expected.path &&
      stat.dev === expected.dev && stat.ino === expected.ino && stat.size === expected.size &&
      stat.mode === expected.mode && stat.mtimeNs === expected.mtimeNs && stat.ctimeNs === expected.ctimeNs
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
  const zigcssAdmitted = stableAllowedBinary(command, allowedBinary) &&
    exactDataArray(args, ['--internal-node-v1']) &&
    exactPlainOptions(options, ['shell', 'windowsHide', 'stdio']) &&
    options.shell === false && options.windowsHide === true &&
    exactDataArray(options.stdio, ['pipe', 'pipe', 'pipe'])
  const esbuildAdmitted = esbuildSpawns === 0 &&
    stableAllowedBinary(command, allowedEsbuild) &&
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
  const error = new Error(`Nuxt offline test blocked ${operation}`)
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
