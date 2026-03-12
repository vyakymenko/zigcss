import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Home } from './Home'

function wrap(ui: React.ReactElement) {
  return <BrowserRouter>{ui}</BrowserRouter>
}

describe('Home', () => {
  it('renders ZigCSS heading', () => {
    render(wrap(<Home />))
    expect(screen.getByText('ZigCSS')).toBeInTheDocument()
  })

  it('renders Get Started link', () => {
    render(wrap(<Home />))
    expect(screen.getByRole('link', { name: /get started/i })).toBeInTheDocument()
  })

  it('renders Try Playground link', () => {
    render(wrap(<Home />))
    expect(screen.getByRole('link', { name: /try playground/i })).toBeInTheDocument()
  })

  it('renders Why ZigCSS section', () => {
    render(wrap(<Home />))
    expect(screen.getByText(/Why ZigCSS\?/)).toBeInTheDocument()
  })

  it('shows install command', () => {
    render(wrap(<Home />))
    expect(screen.getByText(/\$ npm install -g zigcss/)).toBeInTheDocument()
  })
})
