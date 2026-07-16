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
    expect(screen.getByRole('heading', { name: /compile css\. keep the meaning/i })).toBeInTheDocument()
    expect(screen.getByText(/0\.4\.0-rc\.3.*experimental/i)).toBeInTheDocument()
    expect(screen.getByText(/evaluate before production/i)).toBeInTheDocument()
    expect(screen.getByText(/native zig\. deterministic output/i)).toBeInTheDocument()
  })

  it('leads with installation and links to package documentation', () => {
    renderHome()
    expect(screen.getByText('npm install --save-dev zigcss@next')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /get started/i })).toHaveAttribute('href', '/getting-started')
    expect(screen.getByRole('link', { name: /explore css support/i })).toHaveAttribute('href', '/features')
  })

  it('states the language boundary without implying preprocessor support', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /five syntaxes\. one honest boundary/i })).toBeInTheDocument()
    for (const format of ['CSS', 'SCSS', 'Sass', 'Less', 'Stylus']) {
      expect(screen.getByRole('tab', { name: format })).toBeInTheDocument()
    }
    expect(screen.getByText(/semantics before speed/i)).toBeInTheDocument()
  })
})
