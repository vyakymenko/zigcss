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
    expect(status).toContain('this completes `LSP-007`')
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

  test('implements silent notifications and the bounded lifecycle state machine', () => {
    const main = read('src/main.zig')
    const lsp = read('src/lsp.zig')
    const audit = read('tests/regressions/audit.zig')
    const status = read('docs/src/content/docs/guide/status.md')

    expect(main).toContain('server.handleMessage')
    expect(main).toContain('.no_response => {}')
    expect(lsp).toContain('pre_initialize')
    expect(lsp).toContain('"Server not initialized"')
    expect(lsp).toContain('"textDocument/didClose"')
    expect(lsp).toContain('"$/cancelRequest"')
    expect(lsp).toContain('version <= document.version')
    expect(lsp).toContain('try json.objectField("openClose")')
    expect(audit).toContain('LSP notifications and lifecycle follow the shutdown protocol (LSP-003)')
    expect(audit).toContain('LSP exit without shutdown returns failure without a response (LSP-003)')
    expect(status).toContain('subsequent requests return `-32600`')
    expect(status).toContain('exit` terminates with status 0 only after shutdown or status 1 otherwise')
  })

  test('publishes and tests one UTF-16 position boundary', () => {
    const lsp = read('src/lsp.zig')
    const positions = read('src/lsp_position.zig')
    const build = read('build.zig')
    const audit = read('tests/regressions/audit.zig')
    const status = read('docs/src/content/docs/guide/status.md')

    expect(lsp).toContain('try json.objectField("positionEncoding")')
    expect(lsp).toContain('try json.write("utf-16")')
    expect(lsp).toContain('lsp_position.byteOffsetAtUtf16Position')
    expect(lsp).toContain('lsp_position.utf16PositionAtByteOffset')
    expect(positions).toContain('InvalidUtf16Boundary')
    expect(positions).toContain('position conversion rejects invalid UTF-8 deterministically')
    expect(build).toContain('src/lsp_position.zig')
    expect(build).toContain('run_lsp_position_tests')
    expect(audit).toContain('LSP executable converts non-BMP byte spans to UTF-16 positions (LSP-004)')
    expect(status).toContain('Initialization explicitly advertises `positionEncoding: utf-16`')
    expect(status).toContain('LF, CRLF, and lone CR')
  })

  test('uses standard pull diagnostics from the public compiler facade', () => {
    const lsp = read('src/lsp.zig')
    const build = read('build.zig')
    const audit = read('tests/regressions/audit.zig')
    const status = read('docs/src/content/docs/guide/status.md')
    const extension = read('vscode-extension/README.md')

    expect(lsp).toContain('const compiler = @import("zigcss")')
    expect(lsp).not.toContain('const parser = @import("parser.zig")')
    expect(lsp).not.toContain('const error_module = @import("error.zig")')
    expect(lsp).toContain('std.mem.eql(u8, method, "textDocument/diagnostic")')
    expect(lsp).not.toContain('std.mem.eql(u8, method, "textDocument/diagnostics")')
    expect(lsp).toContain('compiler.compile(self.allocator, uri, doc.text, .{})')
    expect(lsp).toContain('try json.write("full")')
    expect(lsp).toContain('diagnostic.code.label()')
    expect(build).toContain('lsp_test_module.addImport("zigcss", library_module)')
    expect(audit).toContain('LSP executable returns full recoverable compiler diagnostics (LSP-005)')
    expect(status).toContain('The standard singular')
    expect(status).toContain('Removed, library-only, and unknown formats never fall back to CSS')
    expect(extension).toContain('Compiler-backed diagnostics')
  })

  test('publishes bounded syntax-aware open-document workspace features', () => {
    const lsp = read('src/lsp.zig')
    const index = read('src/lsp_index.zig')
    const build = read('build.zig')
    const audit = read('tests/regressions/audit.zig')
    const status = read('docs/src/content/docs/guide/status.md')
    const extension = read('vscode-extension/README.md')

    expect(lsp).toContain('std.mem.eql(u8, method, "textDocument/documentSymbol")')
    expect(lsp).toContain('std.mem.eql(u8, method, "workspace/symbol")')
    expect(lsp).toContain('try json.objectField("workspaceSymbolProvider")')
    expect(lsp).toContain('fn workspaceDocuments(self: *LspServer)')
    expect(lsp).toContain('max_workspace_text_bytes: usize = 256 * 1024 * 1024')
    expect(lsp).toContain('max_workspace_index_bytes: usize = 128 * 1024 * 1024')
    expect(lsp).toContain('max_editor_response_bytes: usize = 16 * 1024 * 1024')
    expect(lsp).toContain('const WorkspaceQueryMatcher = struct')
    expect(lsp).toContain('compiler.css.emitter.serializeIdentifierAlloc')
    expect(index).toContain('zigcss.css.pipeline.parse')
    expect(index).toContain('fn indexOpaqueTokens')
    expect(index).toContain('max_symbols: usize = 100_000')
    expect(index).toContain('max_allocated_bytes: usize = 32 * 1024 * 1024')
    expect(build).toContain('src/lsp_index.zig')
    expect(build).toContain('run_lsp_index_tests')
    expect(audit).toContain(
      'LSP executable serves syntax-aware deterministic workspace features (LSP-006)',
    )
    expect(status).toContain('only currently open CSS documents')
    expect(status).toContain('never scan the filesystem')
    expect(status).toContain('256 MiB of synchronized text')
    expect(status).toContain('allocator-measured cached index storage')
    expect(status).toContain('16 MiB escaped-JSON budget')
    expect(status).toContain('rejected update retains the previous version')
    expect(status).toContain('Class and ID selectors represent external DOM names')
    expect(extension).toContain('Syntax-aware editing')
    expect(extension).toContain('Bounded open-document workspace')
  })

  test('publishes the final large Unicode protocol and leak stress gate', () => {
    const lsp = read('src/lsp.zig')
    const audit = read('tests/regressions/audit.zig')
    const status = read('docs/src/content/docs/guide/status.md')
    const readme = read('README.md')
    const extension = read('vscode-extension/README.md')

    expect(lsp).toContain('LSP repeated Unicode index lifecycle is balanced and leak-free')
    expect(lsp).toContain('for (0..64)')
    expect(audit).toContain(
      'LSP executable survives large Unicode and malformed protocol transcript (LSP-007)',
    )
    expect(audit).toContain("appendNTimes(allocator, 'x', 1024 * 1024)")
    expect(status).toContain('synchronizes more than 1 MiB of CSS')
    expect(status).toContain('response output remains below 64 KiB')
    expect(status).toContain('return to zero after every cycle')
    expect(readme).toContain('pass large-document, Unicode, malformed-request, leak, and editor-integration gates')
    expect(extension).toContain('Protocol stress coverage')
  })
})
