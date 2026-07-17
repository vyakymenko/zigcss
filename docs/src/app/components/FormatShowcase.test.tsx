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

  it('shows exact provider pipelines and real CSS output for every canonical preprocessor', () => {
    renderShowcase()

    const canonical = [
      ['SCSS', '.scss', 'SCSS → Dart Sass 1.101.0 → ZigCSS → compact CSS'],
      ['Sass', '.sass', 'Indented Sass → Dart Sass 1.101.0 → ZigCSS → compact CSS'],
      ['Less', '.less', 'Less → Less 4.6.7 → ZigCSS → compact CSS'],
      ['Stylus', '.styl', 'Stylus → Stylus 0.64.0 → ZigCSS → compact CSS'],
    ] as const

    for (const [label, extension, pipeline] of canonical) {
      fireEvent.click(screen.getByRole('tab', { name: label }))
      expect(screen.getByRole('tab', { name: label })).toHaveAttribute('aria-selected', 'true')
      expect(screen.getByText(new RegExp(`input \\${extension}$`, 'i'))).toBeInTheDocument()
      expect(screen.getByText('CSS emitted')).toBeInTheDocument()
      expect(screen.getByText('.button{background:#b7f34a}.button:hover{filter:brightness(1.08)}')).toBeInTheDocument()
      expect(screen.getByText(pipeline)).toBeInTheDocument()
    }
  })

  it('links the interactive examples to the authoritative format policy', () => {
    renderShowcase()
    expect(screen.getByRole('link', { name: /format policy/i })).toHaveAttribute('href', '/docs/guide/format-compatibility')
    expect(screen.getByText(/canonical language support is version-pinned/i)).toBeInTheDocument()
  })

  it('keeps long source and output lines contained at the mobile breakpoint', () => {
    renderShowcase()

    const panel = screen.getByRole('tabpanel')
    expect(panel).toHaveClass('min-w-0', 'grid-cols-1')
    expect(Array.from(panel.children)).toHaveLength(2)
    for (const column of Array.from(panel.children)) {
      expect(column).toHaveClass('min-w-0')
    }
  })
})
