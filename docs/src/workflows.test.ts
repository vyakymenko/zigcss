// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const workflowsDir = path.resolve(import.meta.dirname, '..', '..', '.github', 'workflows')

describe('documentation workflow', () => {
  const workflow = fs.readFileSync(path.join(workflowsDir, 'docs.yml'), 'utf8')

  test('validates documentation on pull requests', () => {
    expect(workflow).toContain('pull_request:')
    expect(workflow).toContain('npm run test:run')
    expect(workflow).toContain('npm run build')
  })

  test('uploads the verified Vite output', () => {
    expect(workflow).toContain('path: docs/dist')
    expect(workflow).not.toContain('docs/.vitepress/dist')
  })

  test('keeps deployment out of pull-request validation', () => {
    expect(workflow).toContain("if: github.event_name != 'pull_request'")
    expect(workflow).toContain('needs: build')
  })
})
