import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Playground } from './Playground'

describe('Playground', () => {
  it('shows the playground as unavailable', () => {
    render(<BrowserRouter><Playground /></BrowserRouter>)
    expect(screen.getByRole('heading', { name: /playground unavailable/i })).toBeInTheDocument()
    expect(screen.getByText(/public compile API is disabled/i)).toBeInTheDocument()
  })

  it('does not expose a compile control', () => {
    render(<BrowserRouter><Playground /></BrowserRouter>)
    expect(screen.queryByRole('button', { name: /compile/i })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: /read current status/i })).toHaveAttribute('href', '/docs/guide/status')
  })
})
