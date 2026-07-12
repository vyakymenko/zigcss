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

  test('publishes the exact completed and deferred LSP boundary', () => {
    const status = read('docs/src/content/docs/guide/status.md')
    expect(status).toContain('Headers are bounded to 8 KiB')
    expect(status).toContain('body to 16 MiB')
    expect(status).toContain('request above the former 8 KiB ceiling')
    expect(status).toContain('LSP-002` through `LSP-007')
  })
})
