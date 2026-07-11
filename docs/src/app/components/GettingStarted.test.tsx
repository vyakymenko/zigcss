import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { GettingStarted } from './GettingStarted'

function renderGettingStarted() {
  render(<BrowserRouter><GettingStarted /></BrowserRouter>)
}

describe('GettingStarted', () => {
  it('labels the compiler as an evaluation-only prototype', () => {
    renderGettingStarted()
    expect(screen.getByRole('heading', { name: /build the experimental compiler/i })).toBeInTheDocument()
    expect(screen.getByText(/contribution and evaluation only/i)).toBeInTheDocument()
  })

  it('shows the verified source build and test commands', () => {
    renderGettingStarted()
    expect(screen.getByText(/zig build test --summary all/)).toBeInTheDocument()
    expect(screen.getByText(/zig-out\/bin\/zigcss input\.css -o output\.css/)).toBeInTheDocument()
  })

  it('links to the current status', () => {
    renderGettingStarted()
    expect(screen.getByRole('link', { name: /review the current status/i })).toHaveAttribute('href', '/docs/guide/status')
  })
})
