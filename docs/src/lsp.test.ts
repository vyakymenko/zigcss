// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const read = (relativePath: string) =>
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

describe('experimental LSP transport', () => {
  test('uses the bounded dynamic frame reader in the executable and CI test graph', () => {
    const main = read('src/main.zig')
    const transport = read('src/lsp_transport.zig')
    const build = read('build.zig')

    expect(main).toContain('lsp_transport.readFrame')
    expect(main).toContain('lsp_transport.writeFrame')
    expect(main).not.toContain('return error.BufferTooSmall')
    expect(transport).toContain('default_max_message_bytes: usize = 16 * 1024 * 1024')
    expect(transport).toContain('max_header_bytes: usize = 8 * 1024')
    expect(transport).toContain('checkAllAllocationFailures')
    expect(build).toContain('src/lsp_transport.zig')
    expect(build).toContain('run_lsp_transport_tests')
  })

  test('publishes the completed transport and JSON-RPC boundaries', () => {
    const status = read('docs/src/content/docs/guide/status.md')
    expect(status).toContain('Headers are bounded to 8 KiB')
    expect(status).toContain('body to 16 MiB')
    expect(status).toContain('request above the former 8 KiB ceiling')
    expect(status).toContain('every reply is emitted through `std.json.Stringify`')
    expect(status).toContain('Malformed JSON returns `-32700`')
    expect(status).toContain('invalid request envelope returns `-32600`')
    expect(status).toContain('unknown method returns `-32601`')
    expect(status).toContain('invalid method parameters return `-32602`')
    expect(status).toContain('next frame is processed normally')
    expect(status).toContain('LSP-003` through `LSP-007')
  })

  test('uses standard JSON parsing and serialization with transcript regressions', () => {
    const lsp = read('src/lsp.zig')
    const audit = read('tests/regressions/audit.zig')

    expect(lsp).toContain('std.json.parseFromSliceLeaky')
    expect(lsp).toContain('const JsonWriter = std.json.Stringify')
    expect(lsp).toContain('"Parse error"')
    expect(lsp).toContain('"Invalid Request"')
    expect(lsp).toContain('"Method not found"')
    expect(lsp).toContain('"Invalid params"')
    expect(lsp).toContain('checkAllAllocationFailures')
    expect(audit).toContain('LSP returns parse errors and continues with the next frame (LSP-002)')
    expect(audit).toContain('LSP serializes hostile IDs and returns invalid-params errors (LSP-002)')
  })
})
