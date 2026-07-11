// @vitest-environment node

import { describe, expect, test } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

const dockerfilePath = path.resolve(import.meta.dirname, '../../Dockerfile.docs')
const dockerfile = fs.readFileSync(dockerfilePath, 'utf8')
const dockerignore = fs.readFileSync(path.resolve(import.meta.dirname, '../../.dockerignore'), 'utf8')

function runtimeStage(): string {
  const marker = 'FROM node:22-alpine AS runtime'
  const start = dockerfile.indexOf(marker)
  expect(start).toBeGreaterThan(-1)
  return dockerfile.slice(start)
}

describe('documentation runtime container', () => {
  test('runs the server as the unprivileged node user on a high port', () => {
    const runtime = runtimeStage()

    expect(runtime).toContain('ENV PORT=8080')
    expect(runtime).toContain('EXPOSE 8080')
    expect(runtime.indexOf('USER node')).toBeGreaterThan(-1)
    expect(runtime.indexOf('USER node')).toBeLessThan(runtime.indexOf('CMD ["node", "server.js"]'))
  })

  test('contains only the built site and static server from the repository', () => {
    const runtime = runtimeStage()

    expect(runtime).toContain('COPY --from=builder /repo/docs/dist ./dist')
    expect(runtime).toContain('COPY --from=builder /repo/docs/server.js ./server.js')
    expect(runtime).not.toContain('COPY . .')
    expect(runtime).not.toContain('/usr/local/bin/zigcss')
    expect(dockerfile).not.toContain('curl -fSL')
    expect(dockerfile).not.toContain('zigcss-bin')
  })

  test('keeps repository state and generated files out of the build context', () => {
    expect(dockerfile).not.toContain('COPY . .')
    expect(dockerignore).toMatch(/^\.git$/m)
    expect(dockerignore).toMatch(/^\.zig-cache$/m)
    expect(dockerignore).toMatch(/^zig-out$/m)
    expect(dockerignore).toMatch(/^docs\/node_modules$/m)
    expect(dockerignore).toMatch(/^docs\/dist$/m)
    expect(dockerignore).toMatch(/^\.env\.\*$/m)
  })
})
