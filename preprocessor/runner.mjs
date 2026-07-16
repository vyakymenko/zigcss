import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEFAULT_PROCESS_TIMEOUT_MS,
  MAX_PROCESS_TIMEOUT_MS,
  MAX_REQUEST_FRAME_BYTES,
  MAX_RESPONSE_FRAME_BYTES,
  MAX_STDERR_BYTES,
  decodeSingleFrame,
  encodeFrame,
  validateRequest,
  validateResponse,
} from './protocol.mjs'
export { sanitizedHostEnvironment } from './environment.mjs'
import { sanitizedHostEnvironment } from './environment.mjs'

const productionHostPath = fileURLToPath(new URL('./host.mjs', import.meta.url))

export class HostProcessError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'HostProcessError'
    this.code = code
  }
}

function processError(code, message) {
  return new HostProcessError(code, message)
}

function validatePositiveInteger(value, maximum, code, label) {
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw processError(code, `${label} is outside its allowed range`)
  }
}

function validateHost(hostPath, hostArguments) {
  if (typeof hostPath !== 'string' || !path.isAbsolute(hostPath)) {
    throw processError('HOST_PATH_INVALID', 'host path must be absolute')
  }
  let stat
  try {
    stat = fs.lstatSync(hostPath)
  } catch {
    throw processError('HOST_PATH_INVALID', 'host path is unavailable')
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw processError('HOST_PATH_INVALID', 'host path must be a regular non-symlink file')
  }
  if (!Array.isArray(hostArguments) || hostArguments.length > 8) {
    throw processError('HOST_ARGUMENTS_INVALID', 'host arguments must be a bounded array')
  }
  for (const argument of hostArguments) {
    if (typeof argument !== 'string' || Buffer.byteLength(argument) > 256) {
      throw processError('HOST_ARGUMENTS_INVALID', 'host arguments must be bounded strings')
    }
  }
}

export async function runPreprocessorHost(
  requestValue,
  {
    hostPath = productionHostPath,
    hostArguments = [],
    timeoutMs = DEFAULT_PROCESS_TIMEOUT_MS,
    maxStdoutBytes = MAX_RESPONSE_FRAME_BYTES + 4,
    maxStderrBytes = MAX_STDERR_BYTES,
  } = {},
) {
  const request = validateRequest(requestValue)
  validateHost(hostPath, hostArguments)
  validatePositiveInteger(timeoutMs, MAX_PROCESS_TIMEOUT_MS, 'HOST_LIMIT_INVALID', 'timeout')
  validatePositiveInteger(
    maxStdoutBytes,
    MAX_RESPONSE_FRAME_BYTES + 4,
    'HOST_LIMIT_INVALID',
    'stdout limit',
  )
  validatePositiveInteger(maxStderrBytes, MAX_STDERR_BYTES, 'HOST_LIMIT_INVALID', 'stderr limit')
  const input = encodeFrame(request, { maxBytes: MAX_REQUEST_FRAME_BYTES })

  return await new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(process.execPath, [hostPath, ...hostArguments], {
        cwd: path.dirname(hostPath),
        env: sanitizedHostEnvironment(),
        shell: false,
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      })
    } catch {
      reject(processError('HOST_PROCESS_START', 'preprocessor host could not start'))
      return
    }

    const stdout = []
    const stderr = []
    let stdoutBytes = 0
    let stderrBytes = 0
    let failure = null

    const terminate = error => {
      if (failure !== null) return
      failure = error
      child.kill('SIGKILL')
    }

    const timer = setTimeout(() => {
      terminate(processError('HOST_PROCESS_TIMEOUT', 'preprocessor host exceeded its time limit'))
    }, timeoutMs)

    child.on('error', () => {
      terminate(processError('HOST_PROCESS_START', 'preprocessor host could not start'))
    })
    child.stdout.on('data', chunk => {
      stdoutBytes += chunk.length
      if (stdoutBytes > maxStdoutBytes) {
        terminate(processError('HOST_STDOUT_LIMIT', 'preprocessor host exceeded its stdout limit'))
        return
      }
      stdout.push(chunk)
    })
    child.stderr.on('data', chunk => {
      stderrBytes += chunk.length
      if (stderrBytes <= maxStderrBytes) stderr.push(chunk)
      terminate(processError('HOST_STDERR_OUTPUT', 'preprocessor host emitted unexpected stderr'))
    })
    child.stdin.on('error', () => {
      // Early close is resolved by the owned exit/signal/response checks below.
    })
    child.once('close', (code, signal) => {
      clearTimeout(timer)
      if (failure !== null) {
        reject(failure)
        return
      }
      if (code !== 0 || signal !== null) {
        reject(processError('HOST_PROCESS_EXIT', 'preprocessor host exited unsuccessfully'))
        return
      }
      if (stderrBytes !== 0 || stderr.length !== 0) {
        reject(processError('HOST_STDERR_OUTPUT', 'preprocessor host emitted unexpected stderr'))
        return
      }
      let response
      try {
        response = validateResponse(
          decodeSingleFrame(Buffer.concat(stdout, stdoutBytes), {
            maxBytes: MAX_RESPONSE_FRAME_BYTES,
          }),
        )
      } catch {
        reject(processError('HOST_RESPONSE_INVALID', 'preprocessor host returned an invalid response'))
        return
      }
      if (response.requestId !== request.requestId) {
        reject(processError('HOST_RESPONSE_INVALID', 'preprocessor response id does not match'))
        return
      }
      resolve(response)
    })
    child.stdin.end(input)
  })
}
