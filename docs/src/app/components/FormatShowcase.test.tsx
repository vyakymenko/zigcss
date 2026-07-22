import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { FormatShowcase } from './FormatShowcase'

function renderShowcase() {
  render(<BrowserRouter><FormatShowcase /></BrowserRouter>)
}

describe('FormatShowcase', () => {
  it('shows a recorded CSS fixture with true bytes, reduction, and digest', () => {
    renderShowcase()

    expect(screen.getByRole('tab', { name: 'CSS' })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByText(/input \.css/i)).toBeInTheDocument()
    expect(screen.getByText(/--accent: #b7f34a/)).toBeInTheDocument()
    expect(screen.getByText(':root{--accent:#b7f34a}.button{color:#101914;background:var(--accent)}')).toBeInTheDocument()
    expect(screen.getByText('recorded compiler output · deterministic')).toBeInTheDocument()
    expect(screen.getByText('90 bytes')).toBeInTheDocument()
    expect(screen.getByText('70 bytes')).toBeInTheDocument()
    expect(screen.getByText('22% smaller')).toBeInTheDocument()
    expect(screen.getByText(/^fnv1a:[0-9a-f]{8}$/)).toBeInTheDocument()
  })

  it('shows exact provider pipelines and executable CSS output for every preprocessor', () => {
    renderShowcase()

    const canonical = [
      ['SCSS', '.scss', 'Dart Sass 1.101.0', 'SCSS → Dart Sass 1.101.0 → ZigCSS → compact CSS'],
      ['Sass', '.sass', 'Dart Sass 1.101.0', 'Indented Sass → Dart Sass 1.101.0 → ZigCSS → compact CSS'],
      ['Less', '.less', 'Less 4.6.7', 'Less → Less 4.6.7 → ZigCSS → compact CSS'],
      ['Stylus', '.styl', 'Stylus 0.64.0', 'Stylus → Stylus 0.64.0 → ZigCSS → compact CSS'],
    ] as const

    for (const [label, extension, provider, pipeline] of canonical) {
      fireEvent.click(screen.getByRole('tab', { name: label }))
      expect(screen.getByRole('tab', { name: label })).toHaveAttribute('aria-selected', 'true')
      expect(screen.getByText(new RegExp(`input \\${extension}$`, 'i'))).toBeInTheDocument()
      expect(screen.getByText(provider)).toBeInTheDocument()
      expect(screen.getByText('recorded compiler output · deterministic')).toBeInTheDocument()
      expect(screen.getByText('.button{background:#b7f34a}.button:hover{filter:brightness(1.08)}')).toBeInTheDocument()
      expect(screen.getByText(pipeline)).toBeInTheDocument()
    }
  })

  it('implements roving keyboard tabs across all five syntaxes', () => {
    renderShowcase()
    const css = screen.getByRole('tab', { name: 'CSS' })
    const scss = screen.getByRole('tab', { name: 'SCSS' })

    css.focus()
    fireEvent.keyDown(css, { key: 'ArrowRight' })
    expect(scss).toHaveFocus()
    expect(scss).toHaveAttribute('aria-selected', 'true')

    fireEvent.keyDown(scss, { key: 'End' })
    expect(screen.getByRole('tab', { name: 'Stylus' })).toHaveFocus()
    expect(screen.getByRole('tab', { name: 'Stylus' })).toHaveAttribute('aria-selected', 'true')
  })

  it('links the instrument to the authoritative format policy and labels recorded evidence', () => {
    renderShowcase()
    expect(screen.getByRole('link', { name: /format policy/i })).toHaveAttribute('href', '/docs/guide/format-compatibility')
    expect(screen.getByText(/recorded compiler fixtures\. not a browser simulation/i)).toBeInTheDocument()
    expect(screen.getByText(/css is native.*canonical preprocessor behavior remains version-pinned/i)).toBeInTheDocument()
  })

  it('keeps long source and output lines contained at the mobile breakpoint', () => {
    renderShowcase()

    const panel = screen.getByRole('tabpanel')
    expect(panel).toHaveClass('min-w-0', 'grid-cols-1')
    expect(Array.from(panel.children)).toHaveLength(2)
    for (const column of Array.from(panel.children)) expect(column).toHaveClass('min-w-0')
  })
})
