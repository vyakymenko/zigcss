import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { NotFound } from './NotFound'

describe('NotFound', () => {
  it('renders 404 heading', () => {
    render(
      <BrowserRouter>
        <NotFound />
      </BrowserRouter>
    )
    expect(screen.getByText(/404 · invalid route/i)).toHaveClass('text-[#879685]')
  })

  it('renders the route failure as a compiler diagnostic', () => {
    render(
      <BrowserRouter>
        <NotFound />
      </BrowserRouter>
    )
    expect(screen.getByRole('heading', { name: /error: route not found — exit 2/i })).toBeInTheDocument()
  })

  it('has Go Home link', () => {
    render(
      <BrowserRouter>
        <NotFound />
      </BrowserRouter>
    )
    expect(screen.getByRole('link', { name: /go home/i })).toBeInTheDocument()
  })
})
