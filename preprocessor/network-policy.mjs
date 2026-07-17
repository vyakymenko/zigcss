import dgram from 'node:dgram'
import dns from 'node:dns'
import dnsPromises from 'node:dns/promises'
import http from 'node:http'
import https from 'node:https'
import net from 'node:net'
import tls from 'node:tls'

const NETWORK_DISABLED_CODE = 'ZIGCSS_NETWORK_DISABLED'

function denied() {
  const error = new Error('Network access is disabled in the ZigCSS canonical preprocessor host')
  error.code = NETWORK_DISABLED_CODE
  return error
}

function throwDenied() {
  throw denied()
}

function rejectDenied() {
  return Promise.reject(denied())
}

function replaceMethod(target, name, replacement) {
  if (target === null || target === undefined || typeof target[name] !== 'function') return
  Object.defineProperty(target, name, {
    configurable: true,
    enumerable: true,
    value: replacement,
    writable: true,
  })
}

export function disableNetworkAccess() {
  for (const client of [http, https]) {
    replaceMethod(client, 'get', throwDenied)
    replaceMethod(client, 'request', throwDenied)
  }
  for (const client of [net, tls]) {
    replaceMethod(client, 'connect', throwDenied)
    replaceMethod(client, 'createConnection', throwDenied)
  }
  replaceMethod(net.Socket?.prototype, 'connect', throwDenied)
  replaceMethod(tls.TLSSocket?.prototype, 'connect', throwDenied)
  replaceMethod(dgram.Socket?.prototype, 'bind', throwDenied)
  replaceMethod(dgram.Socket?.prototype, 'connect', throwDenied)
  replaceMethod(dgram.Socket?.prototype, 'send', throwDenied)

  for (const resolver of [dns, dnsPromises]) {
    for (const method of [
      'lookup',
      'lookupService',
      'resolve',
      'resolve4',
      'resolve6',
      'resolveAny',
      'resolveCaa',
      'resolveCname',
      'resolveMx',
      'resolveNaptr',
      'resolveNs',
      'resolvePtr',
      'resolveSoa',
      'resolveSrv',
      'resolveTxt',
      'reverse',
    ]) {
      replaceMethod(resolver, method, resolver === dnsPromises ? rejectDenied : throwDenied)
    }
  }

  if (typeof globalThis.fetch === 'function') {
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      value: rejectDenied,
      writable: true,
    })
  }
  if (typeof globalThis.WebSocket === 'function') {
    Object.defineProperty(globalThis, 'WebSocket', {
      configurable: true,
      value: class DisabledWebSocket {
        constructor() {
          throw denied()
        }
      },
      writable: true,
    })
  }
}

export { NETWORK_DISABLED_CODE }
