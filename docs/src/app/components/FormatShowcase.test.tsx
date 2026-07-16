import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { FormatShowcase } from './FormatShowcase'

function renderShowcase() {
  render(<BrowserRouter><FormatShowcase /></BrowserRouter>)
}

describe('FormatShowcase', () => {
  it('shows a real CSS input and minified ZigCSS output by default', () => {
    renderShowcase()

    expect(screen.getByRole('tab', { name: 'CSS' })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByText(/input \.css/i)).toBeInTheDocument()
    expect(screen.getByText(/--accent: #b7f34a/)).toBeInTheDocument()
    expect(screen.getByText(':root{--accent:#b7f34a}.button{color:#101914;background:var(--accent)}')).toBeInTheDocument()
    expect(screen.getByText('CSS emitted')).toBeInTheDocument()
    expect(screen.queryByText('No CSS emitted')).not.toBeInTheDocument()
  })

  it('shows explicit no-output boundaries for every unsupported preprocessor', () => {
    renderShowcase()

    const unsupported = [
      ['SCSS', '.scss', 'SCSS → Sass compiler → CSS → ZigCSS'],
      ['Sass', '.sass', 'Indented Sass → Sass compiler → CSS → ZigCSS'],
      ['Less', '.less', 'Less → Less compiler → CSS → ZigCSS'],
      ['Stylus', '.styl', 'Stylus → Stylus compiler → CSS → ZigCSS'],
    ] as const

    for (const [label, extension, pipeline] of unsupported) {
      fireEvent.click(screen.getByRole('tab', { name: label }))
      expect(screen.getByRole('tab', { name: label })).toHaveAttribute('aria-selected', 'true')
      expect(screen.getByText(new RegExp(`input \\${extension}$`, 'i'))).toBeInTheDocument()
      expect(screen.getByText('Not supported')).toBeInTheDocument()
      expect(screen.getByText('No CSS emitted')).toBeInTheDocument()
      expect(screen.getByText(pipeline)).toBeInTheDocument()
    }
  })

  it('links the interactive examples to the authoritative format policy', () => {
    renderShowcase()
    expect(screen.getByRole('link', { name: /format policy/i })).toHaveAttribute('href', '/docs/guide/format-compatibility')
    expect(screen.getByText(/not a bundled preprocessor stack/i)).toBeInTheDocument()
  })
})
