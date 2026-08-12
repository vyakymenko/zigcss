import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(import.meta.url)

// Public check annotations expose at most 4 KiB of message text even though the
// workflow-command transport accepts more. Retaining the first 3 KiB keeps the
// causal diagnostic and leaves room for the bounded status and truncation note.
export const failureHeadBytes = 3 * 1024

const modes = Object.freeze({
  Debug: Object.freeze(['build', 'test', '--summary', 'all']),
  ReleaseSafe: Object.freeze(['build', 'test', '-Doptimize=ReleaseSafe', '--summary', 'all']),
})

export function suiteArguments(mode) {
  const args = modes[mode]
  if (args === undefined) throw new Error(`unsupported Zig test suite mode: ${mode}`)
  return [...args]
}

function workflowCommandData(value) {
  return value
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A')
}

function boundedHead(maxBytes) {
  let head = Buffer.alloc(0)
  let truncated = false

  return {
    append(chunk) {
      const incoming = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      if (incoming.length === 0) return
      const remaining = maxBytes - head.length
      if (remaining === 0) {
        truncated = true
        return
      }
      if (incoming.length > remaining) {
        head = Buffer.concat([head, incoming.subarray(0, remaining)])
        truncated = true
      } else {
        head = Buffer.concat([head, incoming])
      }
    },
    diagnostic() {
      return {
        output: head.toString('utf8'),
        truncated,
      }
    },
  }
}

function emitFailure(annotation, status, capture) {
  const diagnostic = capture.diagnostic()
  const truncation = diagnostic.truncated
    ? `\n[diagnostic truncated after first ${failureHeadBytes} bytes]`
    : ''
  const detail = diagnostic.output.length === 0 ? '' : `\n${diagnostic.output}`
  const message = `zig build test ${status}${truncation}${detail}`
  annotation.write(`\n::error title=Zig test suite failed::${workflowCommandData(message)}\n`)
}

export async function runZigTestSuite({
  mode,
  spawnProcess = spawn,
  stdout = process.stdout,
  stderr = process.stderr,
  annotation = stdout,
}) {
  const args = suiteArguments(mode)
  const capture = boundedHead(failureHeadBytes)

  return new Promise(resolve => {
    let child
    try {
      child = spawnProcess('zig', args, {
        stdio: ['inherit', 'pipe', 'pipe'],
        windowsHide: true,
      })
    } catch (error) {
      emitFailure(annotation, `could not start: ${error.message}`, capture)
      resolve(1)
      return
    }

    let settled = false
    child.stdout.on('data', chunk => {
      stdout.write(chunk)
      capture.append(chunk)
    })
    child.stderr.on('data', chunk => {
      stderr.write(chunk)
      capture.append(chunk)
    })
    child.on('error', error => {
      if (settled) return
      settled = true
      emitFailure(annotation, `could not start: ${error.message}`, capture)
      resolve(1)
    })
    child.on('close', (code, signal) => {
      if (settled) return
      settled = true
      if (code === 0 && signal === null) {
        resolve(0)
        return
      }
      const status = signal === null
        ? `failed with exit code ${code ?? 'unknown'}`
        : `terminated by signal ${signal}`
      emitFailure(annotation, status, capture)
      resolve(Number.isInteger(code) && code > 0 ? code : 1)
    })
  })
}

function parseMode(argv) {
  if (argv.length !== 2 || argv[0] !== '--mode') {
    throw new Error('usage: node scripts/run-zig-test-suite.mjs --mode Debug|ReleaseSafe')
  }
  suiteArguments(argv[1])
  return argv[1]
}

async function main() {
  const mode = parseMode(process.argv.slice(2))
  process.exitCode = await runZigTestSuite({ mode })
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === scriptPath) {
  main().catch(error => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}
