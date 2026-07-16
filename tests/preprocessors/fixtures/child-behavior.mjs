import {
  MAX_REQUEST_FRAME_BYTES,
  decodeSingleFrame,
  encodeFrame,
  validateRequest,
} from '../../../preprocessor/protocol.mjs'
import { sanitizeRuntimeEnvironment } from '../../../preprocessor/environment.mjs'

const mode = process.argv[2]
sanitizeRuntimeEnvironment()

if (mode === 'hang') {
  process.stdin.resume()
  setInterval(() => {}, 1000)
} else if (mode === 'flood') {
  process.stdin.resume()
  const chunk = Buffer.alloc(64 * 1024, 120)
  const write = () => {
    process.stdout.write(chunk)
    setImmediate(write)
  }
  write()
} else if (mode === 'exit') {
  process.exit(7)
} else {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const input = Buffer.concat(chunks)
  if (mode === 'malformed') {
    const invalid = Buffer.from('{', 'utf8')
    const header = Buffer.alloc(4)
    header.writeUInt32BE(invalid.length)
    process.stdout.end(Buffer.concat([header, invalid]))
  } else {
    const request = validateRequest(
      decodeSingleFrame(input, { maxBytes: MAX_REQUEST_FRAME_BYTES }),
    )
    const css = mode === 'environment'
      ? JSON.stringify(process.env)
      : request.source
    const response = encodeFrame({
      protocol: request.protocol,
      requestId: mode === 'wrong-id' ? 'different-request' : request.requestId,
      ok: true,
      result: {
        css,
        sourceMap: null,
        diagnostics: [],
        dependencies: [],
      },
    })
    if (mode === 'stderr') process.stderr.write('unexpected provider stderr')
    if (mode === 'extra') process.stdout.end(Buffer.concat([response, response]))
    else process.stdout.end(response)
  }
}
