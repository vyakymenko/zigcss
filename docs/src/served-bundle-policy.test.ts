// @vitest-environment node

import crypto from 'node:crypto'
import { describe, expect, test } from 'vitest'
import { inspectServedHtml } from '../scripts/check-served-bundle.mjs'

function fixturePolicy(source: string) {
  const hash = `sha256-${crypto.createHash('sha256').update(source).digest('base64')}`
  return `default-src 'self'; script-src 'self' '${hash}'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'`
}

describe('served HTML parser policy', () => {
  test('accepts only inline scripts bound to both response and meta CSP', () => {
    const source = 'globalThis.__zigcssBootstrap = true'
    const policy = fixturePolicy(source)
    expect(() => inspectServedHtml(
      `<meta http-equiv="Content-Security-Policy" content="${policy}"><script>${source}</script>`,
      { expectedMetaPolicy: policy, relative: 'fixture.html', responsePolicy: policy },
    )).not.toThrow()
  })

  test('parses malformed script end tags like a browser and rejects the hidden script', () => {
    const admitted = 'globalThis.__admitted = true'
    const policy = fixturePolicy(admitted)
    const html = [
      `<meta http-equiv="Content-Security-Policy" content="${policy}">`,
      `<script>${admitted}</script\t\n data-parser-error="still-closes">`,
      '<script>globalThis.__untrusted = true</script>',
    ].join('')

    expect(() => inspectServedHtml(
      html,
      { expectedMetaPolicy: policy, relative: 'malformed.html', responsePolicy: policy },
    )).toThrow(/unhashed inline script/)
  })

  test('rejects parsed style elements and attributes regardless of source spelling', () => {
    const policy = fixturePolicy('')
    expect(() => inspectServedHtml(
      `<meta http-equiv="Content-Security-Policy" content="${policy}"><STYLE>body{display:none}</STYLE>`,
      { expectedMetaPolicy: policy, relative: 'style.html', responsePolicy: policy },
    )).toThrow(/inline style element/)
    expect(() => inspectServedHtml(
      `<meta http-equiv="Content-Security-Policy" content="${policy}"><p STYLE="display:none">hidden</p>`,
      { expectedMetaPolicy: policy, relative: 'attribute.html', responsePolicy: policy },
    )).toThrow(/inline style attribute/)
  })
})
