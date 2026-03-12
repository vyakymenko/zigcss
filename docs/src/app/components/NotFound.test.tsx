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
    expect(screen.getByText('404')).toBeInTheDocument()
  })

  it('renders Page Not Found heading', () => {
    render(
      <BrowserRouter>
        <NotFound />
      </BrowserRouter>
    )
    expect(screen.getByRole('heading', { name: /page not found/i })).toBeInTheDocument()
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
