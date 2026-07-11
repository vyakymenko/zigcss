import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Features } from './Features'

function renderFeatures() {
  render(<BrowserRouter><Features /></BrowserRouter>)
}

describe('Features', () => {
  it('presents a current capability boundary rather than a comparison', () => {
    renderFeatures()
    expect(screen.getByRole('heading', { name: /current capability status/i })).toBeInTheDocument()
    expect(screen.getByText(/not a compatibility promise/i)).toBeInTheDocument()
  })

  it('marks the core compiler and format adapters experimental', () => {
    renderFeatures()
    expect(screen.getByText('Basic CSS parsing and emission')).toBeInTheDocument()
    expect(screen.getByText('Alternate format adapters')).toBeInTheDocument()
    expect(screen.getAllByText(/experimental/i).length).toBeGreaterThan(1)
  })

  it('lists disabled and unavailable surfaces explicitly', () => {
    renderFeatures()
    expect(screen.getByText('Optimizer, prefixing, critical CSS')).toBeInTheDocument()
    expect(screen.getByText('Source maps and browser targets')).toBeInTheDocument()
    expect(screen.getByText('Public compile API and playground')).toBeInTheDocument()
  })
})
