import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { BootSequence } from './BootSequence'

describe('BootSequence', () => {
  beforeEach(() => window.sessionStorage.clear())
  afterEach(() => vi.unstubAllGlobals())

  it('runs once per session and is click-to-skip', () => {
    const first = render(<BootSequence />)
    const boot = screen.getByRole('dialog', { name: /zigcss boot sequence/i })

    fireEvent.click(boot)
    expect(screen.queryByRole('dialog', { name: /zigcss boot sequence/i })).not.toBeInTheDocument()
    first.unmount()

    render(<BootSequence />)
    expect(screen.queryByRole('dialog', { name: /zigcss boot sequence/i })).not.toBeInTheDocument()
  })

  it('skips entirely when reduced motion is requested', () => {
    vi.stubGlobal('matchMedia', vi.fn().mockReturnValue({ matches: true }))
    render(<BootSequence />)
    expect(screen.queryByRole('dialog', { name: /zigcss boot sequence/i })).not.toBeInTheDocument()
  })
})
