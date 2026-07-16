// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const repoRoot = path.resolve(import.meta.dirname, '../..')
const read = (relativePath: string) =>
  fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')

describe('experimental Neovim integration', () => {
  test('uses the current built-in CSS-only configuration API', () => {
    const entry = read('neovim-config/init.lua')
    const config = read('neovim-config/lsp/zigcss.lua')

    expect(entry).toContain("vim.lsp.enable('zigcss')")
    expect(entry + config).not.toContain("require('lspconfig')")
    expect(config).toContain("cmd = { server_command(), '--lsp' }")
    expect(config).toContain("filetypes = { 'css' }")
    expect(config).toContain("root_markers = { '.git' }")
    expect(config).toContain('workspace_required = false')
    for (const filetype of ["'scss'", "'sass'", "'less'", "'stylus'"]) {
      expect(config).not.toContain(filetype)
    }
  })

  test('resolves one trusted executable and rejects relative configuration', () => {
    const config = read('neovim-config/lsp/zigcss.lua')
    const integration = read('scripts/test-neovim-integration.mjs')

    expect(config).toContain('ZIGCSS_LSP_PATH')
    expect(config).toContain('maximum_path_length = 65536')
    expect(config).toContain('maximum_path_entries = 1024')
    expect(config).toContain("stat.type ~= 'file'")
    expect(config).toContain('must resolve to an absolute path')
    expect(integration).toContain('NEOVIM_REJECTION_PASS')
  })

  test('pins a real Neovim capability and hover smoke in CI', () => {
    const workflow = read('.github/workflows/build.yml')
    const integration = read('neovim-config/test/integration.lua')
    const manifest = JSON.parse(read('package.json'))

    expect(workflow).toContain('install_neovim 0.11.7 38a7c6317f94503841096c00e8fde05ef04b9472fc9d7d62b6e033cecd6f7991')
    expect(workflow).toContain('install_neovim 0.12.4 012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628')
    expect(workflow).toContain('npm run test:neovim')
    expect(manifest.scripts['test:neovim']).toContain('test-neovim-integration.mjs')
    expect(integration).toContain("client.offset_encoding == 'utf-16'")
    expect(integration).toContain("client:request_sync('textDocument/diagnostic'")
    expect(integration).toContain("client:request_sync('textDocument/hover'")
    expect(integration).toContain("client:stop(false)")
  })

  test('publishes exact current capabilities and limitations', () => {
    const readme = read('neovim-config/README.md')
    const status = read('docs/src/content/docs/guide/status.md')
    const root = read('README.md')

    expect(readme).toContain('Neovim 0.11.7 or later')
    expect(readme).toContain('Pull diagnostics')
    expect(readme).toContain('Declaration, implementation, signature help, code actions, formatting')
    expect(status).toContain('The Neovim integration uses the built-in configuration API')
    expect(status).toContain('an invalid explicit path fails closed without fallback')
    expect(root).toContain('[Neovim configuration](neovim-config/README.md)')
    expect(root).toContain('Neither integration bundles a compiler binary.')
    expect(root).not.toContain('Neovim validation remain')
  })
})
