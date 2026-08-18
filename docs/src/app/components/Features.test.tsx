import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Features } from './Features'
import capabilityMetadata from '../../data/capabilities.json'

function renderFeatures() {
  render(<BrowserRouter><Features /></BrowserRouter>)
}

describe('Features', () => {
  it('presents a current capability boundary rather than a comparison', () => {
    renderFeatures()
    expect(screen.getByRole('heading', { name: /current capability status/i })).toBeInTheDocument()
    expect(screen.getByText(/not a compatibility promise/i)).toBeInTheDocument()
    expect(screen.getByText(/published stable 0\.6\.0 release/i)).toBeInTheDocument()
    expect(screen.getByText(/GitHub Release and npm latest publication are verified/i)).toBeInTheDocument()
  })

  it('marks the core compiler and format adapters experimental', () => {
    renderFeatures()
    expect(screen.getByText('.css parsing and emission')).toBeInTheDocument()
    expect(screen.getByText('Zig compile API')).toBeInTheDocument()
    expect(screen.getByText('Zig package metadata')).toBeInTheDocument()
    expect(screen.getByText('Zig build helper')).toBeInTheDocument()
    expect(screen.getByText('Native plugins')).toBeInTheDocument()
    expect(screen.getByText('SCSS input')).toBeInTheDocument()
    expect(screen.getByText('Indented Sass input')).toBeInTheDocument()
    expect(screen.getByText('Less input')).toBeInTheDocument()
    expect(screen.getByText('Stylus input')).toBeInTheDocument()
    expect(screen.getByText('Other ecosystem adapters')).toBeInTheDocument()
    expect(screen.getAllByText(/experimental/i).length).toBeGreaterThan(1)
  })

  it('lists acceptance-gated and library-only surfaces explicitly', () => {
    renderFeatures()
    expect(screen.getByText('Verified optimizer preset')).toBeInTheDocument()
    expect(screen.getByText('Dead-code and critical-CSS extraction')).toBeInTheDocument()
    expect(screen.getByText('Target prefix rewrite')).toBeInTheDocument()
    expect(screen.getByText('Source maps')).toBeInTheDocument()
    expect(screen.getByText('Browser target queries')).toBeInTheDocument()
    expect(screen.getByText('CSS Modules')).toBeInTheDocument()
    expect(screen.getByText('VS Code extension')).toBeInTheDocument()
    expect(screen.getByText('Neovim configuration')).toBeInTheDocument()
    expect(screen.getByText('Public compile API and playground')).toBeInTheDocument()
  })

  it('renders every evidence-linked metadata row without the stale LSP claim', () => {
    renderFeatures()
    for (const capability of capabilityMetadata.capabilities) {
      expect(screen.getByText(capability.surface)).toBeInTheDocument()
    }
    expect(screen.getAllByRole('row')).toHaveLength(capabilityMetadata.capabilities.length + 1)
    expect(screen.getByText(/pull diagnostics.*editor-integration gates/i)).toBeInTheDocument()
    expect(screen.queryByText(/parser migration remain later gates/i)).not.toBeInTheDocument()
  })

  it('renders canonical inline code markup without literal backticks', () => {
    renderFeatures()
    expect(screen.getAllByText('zigcss.compile', { selector: 'code' })).toHaveLength(2)
    expect(screen.getAllByText('--optimize', { selector: 'code' })).toHaveLength(2)
    expect(document.body.textContent).not.toContain('`')
  })

  it('links to the tested CSS compatibility matrix', () => {
    renderFeatures()
    expect(screen.getByRole('link', { name: /read CSS compatibility/i })).toHaveAttribute('href', '/docs/guide/css-compatibility')
  })
})
