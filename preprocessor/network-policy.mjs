import cluster from 'node:cluster'
import dgram from 'node:dgram'
import dns from 'node:dns'
import dnsPromises from 'node:dns/promises'
import http from 'node:http'
import http2 from 'node:http2'
import https from 'node:https'
import inspector from 'node:inspector'
import { syncBuiltinESMExports } from 'node:module'
import net from 'node:net'
import tls from 'node:tls'
import workerThreads from 'node:worker_threads'

const NETWORK_DISABLED_CODE = 'ZIGCSS_NETWORK_DISABLED'
const PROCESS_DISABLED_CODE = 'ZIGCSS_PROCESS_DISABLED'

const networkBindings = new Set([
  'cares_wrap',
  'pipe_wrap',
  'tcp_wrap',
  'tls_wrap',
  'udp_wrap',
])
const processBindings = new Set([
  'fs',
  'fs_dir',
  'fs_event_wrap',
  'inspector',
  'process_wrap',
  'signal_wrap',
  'spawn_sync',
  'tty_wrap',
  'worker',
])
const networkBuiltins = new Set([
  'dgram',
  'dns',
  'dns/promises',
  'http',
  'http2',
  'https',
  'net',
  'tls',
])
const processBuiltins = new Set([
  'child_process',
  'cluster',
  'inspector',
  'inspector/promises',
  'worker_threads',
])

let installed = false

const childProcess = typeof process.getBuiltinModule === 'function'
  ? process.getBuiltinModule('child_process')
  : null
const inspectorPromises = typeof process.getBuiltinModule === 'function'
  ? process.getBuiltinModule('inspector/promises')
  : null

function boundaryError(code, message) {
  const error = new Error(message)
  error.code = code
  return error
}

function networkDenied() {
  return boundaryError(
    NETWORK_DISABLED_CODE,
    'Network access is disabled in the ZigCSS canonical preprocessor host',
  )
}

function processDenied() {
  return boundaryError(
    PROCESS_DISABLED_CODE,
    'Process escape is disabled in the ZigCSS canonical preprocessor host',
  )
}

function throwNetworkDenied() {
  throw networkDenied()
}

function rejectNetworkDenied() {
  return Promise.reject(networkDenied())
}

function throwProcessDenied() {
  throw processDenied()
}

function immutableValue(target, name, value) {
  if (target === null || target === undefined) return
  const descriptor = Object.getOwnPropertyDescriptor(target, name)
  if (descriptor === undefined) return
  if (descriptor.configurable === false) {
    if (
      !('value' in descriptor) ||
      descriptor.value !== value ||
      descriptor.writable !== false
    ) {
      throw new Error(`Cannot install the canonical host boundary for ${String(name)}`)
    }
    return
  }
  Object.defineProperty(target, name, {
    configurable: false,
    enumerable: descriptor.enumerable,
    value,
    writable: false,
  })
}

function immutableFunction(target, name, replacement) {
  if (target === null || target === undefined || typeof target[name] !== 'function') return
  immutableValue(target, name, replacement)
}

function installProcessBoundary() {
  if (childProcess === null) {
    throw new Error('Cannot install the canonical host child-process boundary')
  }
  for (const method of [
    '_forkChild',
    'exec',
    'execFile',
    'execFileSync',
    'execSync',
    'fork',
    'spawn',
    'spawnSync',
  ]) {
    immutableFunction(childProcess, method, throwProcessDenied)
  }
  immutableFunction(childProcess.ChildProcess?.prototype, 'spawn', throwProcessDenied)
  immutableFunction(childProcess.ChildProcess?.prototype, 'kill', throwProcessDenied)
  immutableFunction(childProcess, 'ChildProcess', throwProcessDenied)

  for (const method of ['execve', '_debugEnd', '_debugProcess', '_kill', 'kill', 'dlopen']) {
    immutableFunction(process, method, throwProcessDenied)
  }

  const originalBinding = process.binding
  immutableFunction(process, 'binding', function guardedBinding(name) {
    if (typeof name !== 'string') throw processDenied()
    if (networkBindings.has(name)) throw networkDenied()
    if (processBindings.has(name)) throw processDenied()
    return Reflect.apply(originalBinding, process, [name])
  })
  immutableFunction(process, '_linkedBinding', throwProcessDenied)

  if (typeof process.getBuiltinModule === 'function') {
    const originalGetBuiltinModule = process.getBuiltinModule
    immutableFunction(process, 'getBuiltinModule', function guardedGetBuiltinModule(specifier) {
      if (typeof specifier !== 'string') throw processDenied()
      const normalized = specifier.replace(/^node:/, '')
      if (networkBuiltins.has(normalized)) throw networkDenied()
      if (processBuiltins.has(normalized)) throw processDenied()
      return Reflect.apply(originalGetBuiltinModule, process, [specifier])
    })
  }

  for (const method of ['fork', 'setupMaster', 'setupPrimary']) {
    immutableFunction(cluster, method, throwProcessDenied)
  }
  immutableFunction(workerThreads, 'Worker', throwProcessDenied)
  for (const method of ['close', 'open', 'waitForDebugger']) {
    immutableFunction(inspector, method, throwProcessDenied)
    immutableFunction(inspectorPromises, method, throwProcessDenied)
  }
  immutableFunction(inspector.Session?.prototype, 'connect', throwProcessDenied)
  immutableFunction(inspector.Session?.prototype, 'connectToMainThread', throwProcessDenied)
  immutableFunction(inspectorPromises?.Session?.prototype, 'connect', throwProcessDenied)
  immutableFunction(inspectorPromises?.Session?.prototype, 'connectToMainThread', throwProcessDenied)
  immutableFunction(inspector, 'Session', throwProcessDenied)
  immutableFunction(inspectorPromises, 'Session', throwProcessDenied)
}

function installDnsBoundary() {
  const allowed = new Set(['getDefaultResultOrder', 'getServers', 'setDefaultResultOrder'])
  for (const [resolver, asynchronous] of [
    [dns, false],
    [dnsPromises, true],
  ]) {
    for (const name of Object.getOwnPropertyNames(resolver)) {
      if (name === 'Resolver' || allowed.has(name) || typeof resolver[name] !== 'function') continue
      immutableFunction(
        resolver,
        name,
        asynchronous && name !== 'setServers' ? rejectNetworkDenied : throwNetworkDenied,
      )
    }
    immutableFunction(resolver, 'Resolver', throwNetworkDenied)
  }
}

function installNetworkBoundary() {
  for (const client of [http, https]) {
    for (const method of ['createServer', 'get', 'request']) {
      immutableFunction(client, method, throwNetworkDenied)
    }
  }
  for (const method of ['addRequest', 'createConnection', 'createSocket']) {
    immutableFunction(http.Agent?.prototype, method, throwNetworkDenied)
  }
  immutableFunction(https.Agent?.prototype, 'createConnection', throwNetworkDenied)
  immutableFunction(http.ClientRequest?.prototype, 'onSocket', throwNetworkDenied)
  immutableFunction(http, 'ClientRequest', throwNetworkDenied)
  immutableFunction(http, 'WebSocket', throwNetworkDenied)

  for (const method of ['connect', 'createConnection', 'createServer', '_createServerHandle']) {
    immutableFunction(net, method, throwNetworkDenied)
  }
  immutableFunction(net.Socket?.prototype, 'connect', throwNetworkDenied)
  immutableFunction(net.Server?.prototype, 'listen', throwNetworkDenied)
  immutableFunction(net.Server?.prototype, '_listen2', throwNetworkDenied)

  for (const method of ['connect', 'createServer']) {
    immutableFunction(tls, method, throwNetworkDenied)
  }
  immutableFunction(tls.TLSSocket?.prototype, 'connect', throwNetworkDenied)

  for (const method of ['connect', 'createServer', 'createSecureServer', 'performServerHandshake']) {
    immutableFunction(http2, method, throwNetworkDenied)
  }

  immutableFunction(dgram, 'createSocket', throwNetworkDenied)
  immutableFunction(dgram, '_createSocketHandle', throwNetworkDenied)
  for (const method of ['bind', 'connect', 'send', 'sendto']) {
    immutableFunction(dgram.Socket?.prototype, method, throwNetworkDenied)
  }
  immutableFunction(dgram, 'Socket', throwNetworkDenied)

  installDnsBoundary()

  if (typeof globalThis.fetch === 'function') {
    immutableValue(globalThis, 'fetch', rejectNetworkDenied)
  }
  if (typeof globalThis.WebSocket === 'function') {
    immutableValue(globalThis, 'WebSocket', throwNetworkDenied)
  }
}

export function disableNetworkAccess() {
  if (installed) return
  installProcessBoundary()
  installNetworkBoundary()
  syncBuiltinESMExports()
  installed = true
}

export { NETWORK_DISABLED_CODE, PROCESS_DISABLED_CODE }
