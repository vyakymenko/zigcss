import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { BrowserRouter, MemoryRouter } from 'react-router'
import { Root } from './Root'

describe('Root chrome', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('keeps the scroll-story anchors and package destinations reachable', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByRole('link', { name: 'Convergence' })).toHaveAttribute('href', '/#convergence')
    expect(screen.getByRole('link', { name: 'Manifesto' })).toHaveAttribute('href', '/#manifesto')
    expect(screen.getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/#formats')
    expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs')
    expect(screen.getByRole('link', { name: 'Install' })).toHaveAttribute('href', '/getting-started')
  })

  it('keeps the canonical trailing slash before deploy-time hash fragments', () => {
    render(<MemoryRouter basename="/zigcss/" initialEntries={['/zigcss/']}><Root /></MemoryRouter>)

    expect(screen.getByRole('link', { name: 'ZigCSS home' })).toHaveAttribute('href', '/zigcss/')
    expect(screen.getByRole('link', { name: 'Convergence' })).toHaveAttribute('href', '/zigcss/#convergence')
    expect(screen.getByRole('link', { name: 'Manifesto' })).toHaveAttribute('href', '/zigcss/#manifesto')
    expect(screen.getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/zigcss/#formats')
  })

  it('closes with the canonical honesty line and experimental status', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByText('Compile CSS.').closest('p')).toHaveTextContent('Compile CSS. Keep the meaning.')
    expect(screen.getByText(/mit · deterministic · fail-closed/i)).toBeInTheDocument()
    expect(screen.getByText(/experimental · evaluate before production/i)).toBeInTheDocument()
  })

  it('provides every primary destination through an accessible mobile menu', () => {
    render(<MemoryRouter><Root /></MemoryRouter>)

    const toggle = screen.getByRole('button', { name: 'Open navigation' })
    const menuId = toggle.getAttribute('aria-controls')
    const menu = menuId ? document.getElementById(menuId) : null

    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(menu).toHaveAttribute('hidden')

    fireEvent.click(toggle)

    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    expect(menu).not.toHaveAttribute('hidden')
    expect(within(menu as HTMLElement).getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/#formats')
    expect(within(menu as HTMLElement).getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs')
    expect(within(menu as HTMLElement).getByRole('link', { name: 'Install' })).toHaveAttribute('href', '/getting-started')
    expect(within(menu as HTMLElement).getByRole('link', { name: /GitHub/i })).toHaveAttribute('href', 'https://github.com/vyakymenko/zigcss')

    fireEvent.keyDown(window, { key: 'Escape' })

    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(menu).toHaveAttribute('hidden')
    expect(toggle).toHaveFocus()
  })

  it('scrolls hash navigation targets below the sticky header', async () => {
    const target = document.createElement('section')
    target.id = 'convergence'
    target.scrollIntoView = vi.fn()
    document.body.appendChild(target)

    vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      callback(0)
      return 1
    })
    vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => undefined)

    render(<MemoryRouter><Root /></MemoryRouter>)
    fireEvent.click(screen.getByRole('link', { name: 'Convergence' }))

    await waitFor(() => {
      expect(target.scrollIntoView).toHaveBeenCalledWith({ block: 'start' })
    })

    target.remove()
  })

  it('returns to the top when Boot is selected on the landing page', () => {
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined)
    vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      callback(0)
      return 1
    })

    render(<MemoryRouter><Root /></MemoryRouter>)
    fireEvent.click(screen.getByRole('link', { name: 'Boot' }))

    expect(scrollTo).toHaveBeenCalledWith({ top: 0, left: 0, behavior: 'auto' })
  })
})
