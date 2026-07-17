import { decodeSingleFrame, encodeFrame } from '../../../preprocessor/protocol.mjs'

const mode = process.argv[2]
const chunks = []
for await (const chunk of process.stdin) chunks.push(chunk)
const request = decodeSingleFrame(Buffer.concat(chunks), { maxBytes: 21 * 1024 * 1024 })
const success = {
  protocol: 'zigcss-core-v1',
  requestId: mode === 'wrong-id' ? 'different-request' : request.requestId,
  ok: true,
  result: {
    css: '.fixture{}',
    sourceMap: null,
    diagnostics: [],
    dependencies: [],
  },
}

switch (mode) {
  case 'hang':
    await new Promise(resolve => setInterval(resolve, 60_000))
    break
  case 'stderr':
    process.stderr.write('unexpected')
    break
  case 'flood':
    process.stdout.write(Buffer.alloc(64 * 1024, 0x61))
    break
  case 'malformed':
    process.stdout.write('not-a-frame')
    break
  case 'extra':
    process.stdout.write(Buffer.concat([encodeFrame(success), Buffer.from([0])]))
    break
  case 'wrong-id':
    process.stdout.write(encodeFrame(success))
    break
  case 'exit':
    process.exitCode = 7
    break
  default:
    process.stdout.write(encodeFrame(success))
}
