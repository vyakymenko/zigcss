'use strict'

const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const https = require('node:https')
const path = require('node:path')

function fail(message) {
  throw new Error(`release smoke preload: ${message}`)
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

if (process.env.ZIGCSS_RELEASE_SMOKE_RUNTIME === '1') allowed.clear()

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
