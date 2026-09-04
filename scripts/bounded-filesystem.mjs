import crypto from 'node:crypto'
import fs from 'node:fs'
import { TextDecoder } from 'node:util'

function abort(reject, message) {
  if (typeof reject === 'function') reject(message)
  throw new Error(message)
}

function identity(stat) {
  return [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs]
}

function sameIdentity(left, right) {
  const expected = identity(left)
  return identity(right).every((value, index) => value === expected[index])
}

function boundedFileOptions(options) {
  const {
    allowEmpty = false,
    allowMissing = false,
    label = 'file',
    maximumBytes,
    reject,
  } = options ?? {}
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    abort(reject, `${label} byte limit is invalid`)
  }
  return { allowEmpty, allowMissing, label, maximumBytes, reject }
}

function openStableRegularFile(filename, options) {
  const { allowEmpty, allowMissing, label, maximumBytes, reject } = boundedFileOptions(options)
  let descriptor
  try {
    descriptor = fs.openSync(
      filename,
      fs.constants.O_RDONLY
        | (fs.constants.O_NONBLOCK ?? 0)
        | (fs.constants.O_NOFOLLOW ?? 0)
        | (fs.constants.O_CLOEXEC ?? 0),
    )
  } catch (error) {
    if (allowMissing && error.code === 'ENOENT') return null
    if (error.code === 'ELOOP') {
      abort(reject, `${label} must be a regular non-symlink file`)
    }
    abort(reject, `${label} could not be opened safely: ${error.message}`)
  }
  try {
    const opened = fs.fstatSync(descriptor, { bigint: true })
    if (!opened.isFile()) {
      abort(reject, `${label} must be a regular non-symlink file`)
    }
    if ((!allowEmpty && opened.size === 0n) || opened.size > BigInt(maximumBytes)) {
      abort(reject, `${label} must contain ${allowEmpty ? '0' : '1'} through ${maximumBytes} bytes`)
    }
    let boundPath
    try {
      boundPath = fs.lstatSync(filename, { bigint: true })
    } catch (error) {
      abort(reject, `${label} changed before it was read: ${error.message}`)
    }
    if (
      !boundPath.isFile()
      || boundPath.isSymbolicLink()
      || !sameIdentity(boundPath, opened)
    ) {
      abort(reject, `${label} changed before it was read or is a symlink`)
    }
    return { descriptor, opened, size: Number(opened.size), label, reject }
  } catch (error) {
    fs.closeSync(descriptor)
    throw error
  }
}

function finishStableRead(openedFile) {
  const after = fs.fstatSync(openedFile.descriptor, { bigint: true })
  if (!sameIdentity(openedFile.opened, after)) {
    abort(openedFile.reject, `${openedFile.label} changed while it was read`)
  }
}

export function readStableRegularFile(filename, options) {
  const openedFile = openStableRegularFile(filename, options)
  if (openedFile === null) return null
  try {
    const bytes = Buffer.allocUnsafe(openedFile.size)
    let offset = 0
    while (offset < bytes.length) {
      const count = fs.readSync(
        openedFile.descriptor,
        bytes,
        offset,
        bytes.length - offset,
        offset,
      )
      if (count === 0) abort(openedFile.reject, `${openedFile.label} ended before its advertised size`)
      offset += count
    }
    finishStableRead(openedFile)
    return bytes
  } finally {
    fs.closeSync(openedFile.descriptor)
  }
}

export function readStableUtf8File(filename, options) {
  const bytes = readStableRegularFile(filename, options)
  if (bytes === null) return null
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch (error) {
    const label = options?.label ?? 'file'
    abort(options?.reject, `${label} is not valid UTF-8: ${error.message}`)
  }
}

export function hashStableRegularFile(filename, options) {
  const openedFile = openStableRegularFile(filename, options)
  if (openedFile === null) return null
  try {
    const hash = crypto.createHash('sha256')
    const buffer = Buffer.allocUnsafe(64 * 1024)
    let offset = 0
    while (offset < openedFile.size) {
      const count = fs.readSync(
        openedFile.descriptor,
        buffer,
        0,
        Math.min(buffer.length, openedFile.size - offset),
        offset,
      )
      if (count === 0) abort(openedFile.reject, `${openedFile.label} ended before its advertised size`)
      hash.update(buffer.subarray(0, count))
      offset += count
    }
    finishStableRead(openedFile)
    return hash.digest('hex')
  } finally {
    fs.closeSync(openedFile.descriptor)
  }
}

export function readBoundedDirectory(directory, options) {
  const {
    allowFile = false,
    allowMissing = false,
    label = 'directory',
    maximumEntries,
    reject,
  } = options ?? {}
  if (!Number.isSafeInteger(maximumEntries) || maximumEntries < 0) {
    abort(reject, `${label} entry limit is invalid`)
  }

  let handle
  try {
    handle = fs.opendirSync(directory)
  } catch (error) {
    if (allowMissing && error.code === 'ENOENT') return null
    if (allowFile && error.code === 'ENOTDIR') return null
    abort(reject, `${label} could not be opened safely: ${error.message}`)
  }

  let before
  try {
    before = fs.lstatSync(directory, { bigint: true })
  } catch (error) {
    handle.closeSync()
    abort(reject, `${label} changed before it was enumerated: ${error.message}`)
  }
  if (!before.isDirectory() || before.isSymbolicLink()) {
    handle.closeSync()
    abort(reject, `${label} must be a regular non-symlink directory`)
  }
  const entries = []
  try {
    while (true) {
      const entry = handle.readSync()
      if (entry === null) break
      if (entries.length === maximumEntries) {
        abort(reject, `${label} exceeds ${maximumEntries} entries`)
      }
      entries.push(entry)
    }
  } finally {
    handle.closeSync()
  }
  let after
  try {
    after = fs.lstatSync(directory, { bigint: true })
  } catch (error) {
    abort(reject, `${label} changed while it was enumerated: ${error.message}`)
  }
  if (!after.isDirectory() || after.isSymbolicLink() || !sameIdentity(before, after)) {
    abort(reject, `${label} changed while it was enumerated`)
  }
  return entries
}
