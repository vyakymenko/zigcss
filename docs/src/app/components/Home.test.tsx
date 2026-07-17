import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Home } from './Home'

function renderHome() {
  render(<BrowserRouter><Home /></BrowserRouter>)
}

describe('Home', () => {
  it('introduces the five-language compiler and identifies the source snapshot honestly', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /five languages in\. one deterministic compiler out/i })).toBeInTheDocument()
    expect(screen.getByText(/0\.5 development snapshot.*experimental/i)).toBeInTheDocument()
    expect(screen.getByText(/evaluate before production/i)).toBeInTheDocument()
    expect(screen.getByText(/css, scss, sass, less, and stylus/i)).toBeInTheDocument()
  })

  it('leads with installation and links to package documentation', () => {
    renderHome()
    expect(screen.getByText('npm install --save-dev zigcss@next')).toBeInTheDocument()
    expect(screen.getByText('node index.js input.scss -o output.css --minify')).toBeInTheDocument()
    expect(screen.queryByText('npx zigcss input.scss -o output.css --minify')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: /get started/i })).toHaveAttribute('href', '/getting-started')
    expect(screen.getByRole('link', { name: /explore language support/i })).toHaveAttribute('href', '/features')
  })

  it('publishes the five canonical input tabs and exact boundary', () => {
    renderHome()
    expect(screen.getByRole('heading', { name: /five syntaxes\. one compiler contract/i })).toBeInTheDocument()
    for (const format of ['CSS', 'SCSS', 'Sass', 'Less', 'Stylus']) {
      expect(screen.getByRole('tab', { name: format })).toBeInTheDocument()
    }
    expect(screen.getByText(/semantics before speed/i)).toBeInTheDocument()
  })
})
