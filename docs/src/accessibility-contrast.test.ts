import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'

const repoRoot = path.resolve(import.meta.dirname, '..', '..')
const theme = fs.readFileSync(path.join(repoRoot, 'docs/src/styles/theme.css'), 'utf8')
const convergence = fs.readFileSync(path.join(repoRoot, 'docs/src/app/components/Convergence.tsx'), 'utf8')

function luminance(hex: string) {
  const channels = hex.match(/[\da-f]{2}/gi)?.map(channel => Number.parseInt(channel, 16) / 255)
  if (!channels || channels.length !== 3) throw new Error(`invalid color ${hex}`)
  const [red, green, blue] = channels.map(channel => (
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
  ))
  return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
}

function contrast(foreground: string, background: string) {
  const values = [luminance(foreground), luminance(background)].sort((left, right) => right - left)
  return (values[0] + 0.05) / (values[1] + 0.05)
}

describe('site contrast contract', () => {
  it.each([
    ['evidence labels', '#879685', '#0c130e'],
    ['endgame labels', '#879685', '#0b110d'],
    ['convergence core label', '#879685', '#101914'],
  ])('%s remains above WCAG AA for small text', (_label, foreground, background) => {
    expect(theme + convergence).toContain(foreground)
    expect(contrast(foreground, background)).toBeGreaterThanOrEqual(4.5)
  })

  it('uses a two-tone focus indicator that contrasts on light and dark surfaces', () => {
    expect(theme).toMatch(/:focus-visible\s*{[^}]*outline:\s*3px solid #f7f3e8;[^}]*box-shadow:\s*0 0 0 7px #172019;/s)
    expect(contrast('#172019', '#f3f0e7')).toBeGreaterThanOrEqual(3)
    expect(contrast('#f7f3e8', '#0b110d')).toBeGreaterThanOrEqual(3)
  })
})
