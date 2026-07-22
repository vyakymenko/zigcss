import { describe, expect, it } from 'vitest'
import { deterministicDigest, reductionPercent, utf8Bytes } from './compilerEvidence'

describe('compiler evidence helpers', () => {
  it('counts UTF-8 bytes rather than JavaScript code units', () => {
    expect(utf8Bytes('a')).toBe(1)
    expect(utf8Bytes('é')).toBe(2)
    expect(utf8Bytes('🟢')).toBe(4)
  })

  it('produces stable labeled digests and reductions from the exact fixture bytes', () => {
    const input = ':root { --accent: #b7f34a; }'
    const output = ':root{--accent:#b7f34a}'

    expect(deterministicDigest(output)).toMatch(/^fnv1a:[0-9a-f]{8}$/)
    expect(deterministicDigest(output)).toBe(deterministicDigest(output))
    expect(reductionPercent(input, output)).toBe(18)
  })
})
