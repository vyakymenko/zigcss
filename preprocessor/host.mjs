import { disableNetworkAccess } from './host-boundary.mjs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { sanitizeRuntimeEnvironment } from './environment.mjs'
import { processHostInput } from './host-core.mjs'
import {
  MAX_REQUEST_FRAME_BYTES,
} from './protocol.mjs'
import { createProductionRegistry } from './provider-registry.mjs'

async function readBoundedInput() {
  const chunks = []
  let total = 0
  for await (const chunk of process.stdin) {
    total += chunk.length
    if (total > MAX_REQUEST_FRAME_BYTES + 4) {
      const oversized = Buffer.alloc(4)
      oversized.writeUInt32BE(MAX_REQUEST_FRAME_BYTES + 1)
      return oversized
    }
    chunks.push(chunk)
  }
  return Buffer.concat(chunks, total)
}

export async function main() {
  process.env = sanitizeRuntimeEnvironment()
  disableNetworkAccess()
  const input = await readBoundedInput()
  const output = await processHostInput(input, {
    registry: createProductionRegistry(),
  })
  await new Promise((resolve, reject) => {
    process.stdout.once('error', reject)
    process.stdout.end(output, resolve)
  })
}

const invokedPath = process.argv[1] === undefined
  ? null
  : pathToFileURL(path.resolve(process.argv[1])).href

if (invokedPath === import.meta.url) {
  main().catch(() => {
    process.exitCode = 1
  })
}
