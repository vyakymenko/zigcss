import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Features } from './Features'
import capabilityMetadata from '../../data/capabilities.json'

function renderFeatures() {
  return render(<BrowserRouter><Features /></BrowserRouter>)
}

describe('Features', () => {
  it('presents a current capability boundary rather than a comparison', () => {
    renderFeatures()
    expect(screen.getByRole('heading', { name: /current capability status/i })).toBeInTheDocument()
    expect(screen.getByText(/not a compatibility promise/i)).toBeInTheDocument()
    expect(screen.getByText(/separates published stable 0\.6\.0 delivery from bounded current-source evidence/i)).toBeInTheDocument()
    expect(screen.getByText(/REL-010 promotes only the stable 0\.6\.0 rows/i)).toBeInTheDocument()
    expect(screen.getByText(/rows whose contract says current, source-checkout, or Unreleased remain Unreleased/i)).toBeInTheDocument()
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
    expect(screen.getByText('JavaScript build-tool adapters')).toBeInTheDocument()
    expect(screen.getByText('Next.js Webpack host example')).toBeInTheDocument()
    expect(screen.getByText('Astro host example')).toBeInTheDocument()
    expect(screen.getByText('Nuxt host example')).toBeInTheDocument()
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

  it('renders admitted Markdown links as safe external links', () => {
    renderFeatures()
    const link = screen.getByRole('link', { name: "Yarn's official SDK guidance" })

    expect(link).toHaveAttribute('href', 'https://yarnpkg.com/getting-started/editor-sdks')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noopener noreferrer')
    expect(document.body.textContent).not.toContain("[Yarn's official SDK guidance]")
  })

  it('uses labeled cards on mobile while retaining the desktop table layout', () => {
    const { container } = renderFeatures()
    const table = screen.getByRole('table')
    const header = container.querySelector('thead')
    const body = container.querySelector('tbody')
    const labels = Array.from(container.querySelectorAll<HTMLElement>('[data-mobile-column-label]'))

    expect(table).toHaveClass('block', 'sm:table')
    expect(header).toHaveClass('hidden', 'sm:table-header-group')
    expect(body).toHaveClass('block', 'sm:table-row-group')
    expect(labels).toHaveLength(capabilityMetadata.capabilities.length * 3)
    expect(labels.every(label => label.classList.contains('sm:hidden'))).toBe(true)

    for (const column of ['Surface', 'Status', 'Current contract']) {
      expect(labels.filter(label => label.dataset.mobileColumnLabel === column)).toHaveLength(capabilityMetadata.capabilities.length)
    }
  })

  it('keeps small capability copy on WCAG AA contrast colors', () => {
    const { container } = renderFeatures()
    const intro = screen.getByText(/table mixes explicitly labeled published-stable rows/i)
    const mobileLabels = Array.from(container.querySelectorAll<HTMLElement>('[data-mobile-column-label]'))

    expect(intro).toHaveClass('text-[#677067]')
    expect(mobileLabels.every(label => label.classList.contains('text-[#6c736b]'))).toBe(true)
  })

  it('links to the tested CSS compatibility matrix', () => {
    renderFeatures()
    expect(screen.getByRole('link', { name: /read CSS compatibility/i })).toHaveAttribute('href', '/docs/guide/css-compatibility')
  })
})
