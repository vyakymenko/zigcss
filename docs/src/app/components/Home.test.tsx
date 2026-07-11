import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Home } from './Home'

function renderHome() {
  render(<BrowserRouter><Home /></BrowserRouter>)
}

describe('Home', () => {
  it('identifies the recovery build as experimental', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: 'ZigCSS' })).toBeInTheDocument()
    expect(screen.getByText(/experimental recovery build/i)).toBeInTheDocument()
    expect(screen.getByText(/not production use/i)).toBeInTheDocument()
  })

  it('links to current status and source-build instructions', () => {
    renderHome()
    expect(screen.getByRole('link', { name: /read current status/i })).toHaveAttribute('href', '/docs/guide/status')
    expect(screen.getByRole('link', { name: /build from source/i })).toHaveAttribute('href', '/getting-started')
  })

  it('describes correctness-first recovery priorities', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /recovery priorities/i })).toBeInTheDocument()
    expect(screen.getByText(/contain unsafe surfaces/i)).toBeInTheDocument()
    expect(screen.getByText(/make failures executable/i)).toBeInTheDocument()
  })
})
