'use strict'

const { EventEmitter } = require('node:events')
const childProcess = require('node:child_process')
const dgram = require('node:dgram')
const dns = require('node:dns')
const dnsPromises = require('node:dns/promises')
const fs = require('node:fs')
const http = require('node:http')
const http2 = require('node:http2')
const https = require('node:https')
const net = require('node:net')
const path = require('node:path')
const tls = require('node:tls')

const maximumTraceBytes = 64 * 1024

function fail(message) {
  throw new Error(`release smoke preload: ${message}`)
}

function boundaryError(code, message) {
  const error = new Error(message)
  error.code = code
  return error
}

if (process.env.ZIGCSS_RELEASE_SMOKE !== '1') fail('explicit smoke authority is required')

const assetRootInput = process.env.ZIGCSS_RELEASE_SMOKE_ASSET_ROOT
const version = process.env.ZIGCSS_RELEASE_SMOKE_VERSION
const archiveName = process.env.ZIGCSS_RELEASE_SMOKE_ARCHIVE
const checksumsName = process.env.ZIGCSS_RELEASE_SMOKE_CHECKSUMS
if (typeof assetRootInput !== 'string' || typeof version !== 'string') fail('asset root and version are required')
if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.test(version)) fail('version is invalid')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(archiveName ?? '')) fail('archive name is invalid')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(checksumsName ?? '')) fail('checksum name is invalid')

const inputRootStat = fs.lstatSync(assetRootInput)
if (!inputRootStat.isDirectory() || inputRootStat.isSymbolicLink()) fail('asset root must be a regular non-symlink directory')
const assetRoot = fs.realpathSync(assetRootInput)

const allowed = new Map([archiveName, checksumsName].map(name => {
  const filename = path.join(assetRoot, name)
  const stat = fs.lstatSync(filename)
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) fail(`${name} must be a nonempty regular file`)
  if (path.dirname(fs.realpathSync(filename)) !== assetRoot) fail(`${name} escapes the asset root`)
  return [
    `https://github.com/vyakymenko/zigcss/releases/download/v${version}/${name}`,
    Object.freeze({ filename, size: stat.size }),
  ]
}))

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
      const response = fs.createReadStream(asset.filename)
      response.statusCode = 200
      response.headers = { 'content-length': String(asset.size) }
      callback(response)
    })
    return request
  }
}

function canonicalRuntimeFile(filename, label, maximumBytes, permitEmpty = false) {
  if (typeof filename !== 'string' || filename.includes('\0') || !path.isAbsolute(filename)) {
    fail(`${label} must be an absolute local path`)
  }
  const stat = fs.lstatSync(filename)
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular non-symlink file`)
  if ((!permitEmpty && stat.size === 0) || stat.size > maximumBytes) fail(`${label} has an invalid size`)
  return fs.realpathSync(filename)
}

function installRuntimeTrace() {
  allowed.clear()
  const traceRootInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE_ROOT
  const traceInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_TRACE
  const binaryInput = process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME_BINARY
  if (typeof traceRootInput !== 'string') fail('runtime trace root is required')
  const traceRootStat = fs.lstatSync(traceRootInput)
  if (!traceRootStat.isDirectory() || traceRootStat.isSymbolicLink()) {
    fail('runtime trace root must be a regular non-symlink directory')
  }
  const traceRoot = fs.realpathSync(traceRootInput)
  const trace = canonicalRuntimeFile(traceInput, 'runtime trace', maximumTraceBytes, true)
  if (path.dirname(trace) !== traceRoot) fail('runtime trace escapes its root')
  const expectedBinary = canonicalRuntimeFile(binaryInput, 'runtime binary', 256 * 1024 * 1024)

  let nativeSpawns = 0
  let networkAttempts = 0
  let deniedProcessAttempts = 0

  function record(event) {
    const stat = fs.lstatSync(trace)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximumTraceBytes) {
      fail('runtime trace changed type or exceeded its byte limit')
    }
    const line = `${JSON.stringify({ event, pid: process.pid })}\n`
    if (stat.size + Buffer.byteLength(line) > maximumTraceBytes) fail('runtime trace exceeds its byte limit')
    fs.appendFileSync(trace, line, { encoding: 'utf8', flag: 'a' })
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

  const originalSpawn = childProcess.spawn
  const originalChildSpawn = childProcess.ChildProcess.prototype.spawn
  let admittedChildSpawn = false
  childProcess.ChildProcess.prototype.spawn = function guardedChildSpawn(...args) {
    if (!admittedChildSpawn) return denyProcess('child_process.ChildProcess.prototype.spawn')
    return Reflect.apply(originalChildSpawn, this, args)
  }
  childProcess.spawn = function tracedNativeSpawn(command, args, options) {
    let canonicalCommand
    try {
      canonicalCommand = canonicalRuntimeFile(command, 'spawn command', 256 * 1024 * 1024)
    } catch {
      return denyProcess('unexpected child process')
    }
    const optionKeys = options !== null && typeof options === 'object'
      ? Reflect.ownKeys(options)
      : []
    if (
      canonicalCommand !== expectedBinary
      || nativeSpawns !== 0
      || !Array.isArray(args)
      || args.some(arg => typeof arg !== 'string' || arg.includes('\0'))
      || options === null
      || typeof options !== 'object'
      || Object.getPrototypeOf(options) !== Object.prototype
      || optionKeys.length !== 2
      || !optionKeys.includes('stdio')
      || !optionKeys.includes('cwd')
      || options.stdio !== 'inherit'
      || options.cwd !== process.cwd()
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
  }

  for (const name of ['spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork', '_forkChild']) {
    childProcess[name] = function deniedChildProcess() {
      return denyProcess(`child_process.${name}`)
    }
  }

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

  http.request = () => deniedRequest('http.request')
  http.get = () => deniedRequest('http.get')
  https.request = () => deniedRequest('https.request')
  https.get = () => deniedRequest('https.get')
  net.connect = () => deniedRequest('net.connect')
  net.createConnection = () => deniedRequest('net.createConnection')
  net.Socket.prototype.connect = () => deniedRequest('net.Socket.connect')
  net.Server.prototype.listen = () => { throw networkError('net.Server.listen') }
  net.createServer = () => { throw networkError('net.createServer') }
  http.createServer = () => { throw networkError('http.createServer') }
  https.createServer = () => { throw networkError('https.createServer') }
  tls.connect = () => deniedRequest('tls.connect')
  tls.createServer = () => { throw networkError('tls.createServer') }
  http2.connect = () => deniedRequest('http2.connect')
  http2.createServer = () => { throw networkError('http2.createServer') }
  http2.createSecureServer = () => { throw networkError('http2.createSecureServer') }
  dgram.createSocket = () => { throw networkError('dgram.createSocket') }

  function denyDnsCallback(operation) {
    return function deniedDnsOperation(...args) {
      const callback = args.at(-1)
      const error = networkError(operation)
      if (typeof callback === 'function') queueMicrotask(() => callback(error))
      else throw error
    }
  }
  dns.lookup = denyDnsCallback('dns.lookup')
  for (const name of [
    'lookupService', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCaa',
    'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr',
    'resolveSoa', 'resolveSrv', 'resolveTxt', 'reverse',
  ]) {
    dns[name] = denyDnsCallback(`dns.${name}`)
  }
  dns.Resolver = class DisabledDnsResolver {
    constructor() {
      throw networkError('dns.Resolver')
    }
  }
  for (const name of Object.keys(dnsPromises)) {
    if (name !== 'Resolver' && typeof dnsPromises[name] === 'function') {
      dnsPromises[name] = (..._args) => Promise.reject(networkError(`dns.promises.${name}`))
    }
  }
  dnsPromises.Resolver = class DisabledDnsPromisesResolver {
    constructor() {
      throw networkError('dns.promises.Resolver')
    }
  }
  globalThis.fetch = (..._args) => Promise.reject(networkError('globalThis.fetch'))
  if (typeof globalThis.WebSocket === 'function') {
    globalThis.WebSocket = class DisabledWebSocket {
      constructor() {
        throw networkError('globalThis.WebSocket')
      }
    }
  }

  record('runtime-start')
  process.on('exit', () => {
    const stat = fs.lstatSync(trace)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maximumTraceBytes) {
      fail('runtime trace changed type or exceeded its byte limit')
    }
    const summary = `${JSON.stringify({
      event: 'runtime-summary',
      pid: process.pid,
      nativeSpawns,
      networkAttempts,
      deniedProcessAttempts,
    })}\n`
    if (stat.size + Buffer.byteLength(summary) > maximumTraceBytes) fail('runtime trace exceeds its byte limit')
    fs.appendFileSync(trace, summary, { encoding: 'utf8', flag: 'a' })
  })
}

if (process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME === '1') installRuntimeTrace()
else installAssetService()
