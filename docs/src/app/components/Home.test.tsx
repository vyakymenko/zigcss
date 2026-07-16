import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Home } from './Home'

function renderHome() {
  render(<BrowserRouter><Home /></BrowserRouter>)
}

describe('Home', () => {
  it('introduces the package and identifies the release candidate honestly', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /compile css with zig/i })).toBeInTheDocument()
    expect(screen.getByText(/0\.4\.0-rc\.3.*experimental/i)).toBeInTheDocument()
    expect(screen.getByText(/evaluate before production/i)).toBeInTheDocument()
  })

  it('leads with installation and links to package documentation', () => {
    renderHome()
    expect(screen.getByText('npm install --save-dev zigcss@next')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /get started/i })).toHaveAttribute('href', '/getting-started')
    expect(screen.getByRole('link', { name: /explore css support/i })).toHaveAttribute('href', '/features')
  })

  it('states the language boundary without implying preprocessor support', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /css in\. css out\./i })).toBeInTheDocument()
    expect(screen.getByText('SCSS / Sass')).toBeInTheDocument()
    expect(screen.getByText('Less')).toBeInTheDocument()
    expect(screen.getAllByText('Not supported')).toHaveLength(2)
    expect(screen.getByText(/semantics before speed/i)).toBeInTheDocument()
  })
})
