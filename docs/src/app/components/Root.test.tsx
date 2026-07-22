import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Root } from './Root'

describe('Root chrome', () => {
  it('keeps the scroll-story anchors and package destinations reachable', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByRole('link', { name: 'Convergence' })).toHaveAttribute('href', '/#convergence')
    expect(screen.getByRole('link', { name: 'Manifesto' })).toHaveAttribute('href', '/#manifesto')
    expect(screen.getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/#formats')
    expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs')
    expect(screen.getByRole('link', { name: 'Install' })).toHaveAttribute('href', '/getting-started')
  })

  it('closes with the canonical honesty line and experimental status', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByText('Compile CSS.').closest('p')).toHaveTextContent('Compile CSS. Keep the meaning.')
    expect(screen.getByText(/mit · deterministic · fail-closed/i)).toBeInTheDocument()
    expect(screen.getByText(/experimental · evaluate before production/i)).toBeInTheDocument()
  })
})
