import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { BrowserRouter, MemoryRouter } from 'react-router'
import { Root } from './Root'
import { routeMetadata } from '../../data/seo-routes.mjs'

function expectRouteMetadata(canonicalPath: string) {
  const metadata = routeMetadata.find(route => route.canonicalPath === canonicalPath)
  expect(metadata).toBeDefined()
  expect(document.title).toBe(metadata?.title)
  expect(document.head.querySelector('meta[name="description"]')).toHaveAttribute('content', metadata?.description)
  expect(document.head.querySelector('meta[name="robots"]')).toHaveAttribute('content', 'index,follow,max-image-preview:large')
  expect(document.head.querySelector('link[rel="canonical"]')).toHaveAttribute(
    'href',
    `https://vyakymenko.github.io/zigcss${canonicalPath}`,
  )
  expect(document.head.querySelector('meta[property="og:title"]')).toHaveAttribute('content', metadata?.title)
  expect(document.head.querySelector('meta[property="og:description"]')).toHaveAttribute('content', metadata?.description)
  expect(document.head.querySelector('meta[property="og:url"]')).toHaveAttribute(
    'content',
    `https://vyakymenko.github.io/zigcss${canonicalPath}`,
  )
  expect(document.head.querySelector('meta[name="twitter:title"]')).toHaveAttribute('content', metadata?.title)
  expect(document.head.querySelector('meta[name="twitter:description"]')).toHaveAttribute('content', metadata?.description)
}

describe('Root chrome', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('keeps the scroll-story anchors and package destinations reachable', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByRole('link', { name: 'Skip to content' })).toHaveAttribute('href', '#main-content')
    expect(screen.getByRole('main')).toHaveAttribute('id', 'main-content')
    expect(screen.getByRole('link', { name: 'Convergence' })).toHaveAttribute('href', '/#convergence')
    expect(screen.getByRole('link', { name: 'Manifesto' })).toHaveAttribute('href', '/#manifesto')
    expect(screen.getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/#formats')
    expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs/guide/status')
    expect(screen.getByRole('link', { name: 'Install' })).toHaveAttribute('href', '/getting-started')
  })

  it('keeps the canonical trailing slash before deploy-time hash fragments', () => {
    render(<MemoryRouter basename="/zigcss/" initialEntries={['/zigcss/']}><Root /></MemoryRouter>)

    expect(screen.getByRole('link', { name: 'ZigCSS home' })).toHaveAttribute('href', '/zigcss/')
    expect(screen.getByRole('link', { name: 'Convergence' })).toHaveAttribute('href', '/zigcss/#convergence')
    expect(screen.getByRole('link', { name: 'Manifesto' })).toHaveAttribute('href', '/zigcss/#manifesto')
    expect(screen.getByRole('link', { name: 'Lab' })).toHaveAttribute('href', '/zigcss/#formats')
  })

  it('keeps Docs active throughout the nested documentation routes', () => {
    render(<MemoryRouter initialEntries={['/docs/guide/css-compatibility']}><Root /></MemoryRouter>)

    expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute('aria-current', 'page')
  })

  it('updates every route-specific discovery field during client navigation', async () => {
    render(<MemoryRouter initialEntries={['/']}><Root /></MemoryRouter>)
    const primaryNavigation = screen.getByRole('navigation', { name: 'Primary navigation' })

    await waitFor(() => expectRouteMetadata('/'))

    fireEvent.click(within(primaryNavigation).getByRole('link', { name: 'Install' }))
    await waitFor(() => expectRouteMetadata('/getting-started/'))

    fireEvent.click(within(primaryNavigation).getByRole('link', { name: 'Docs' }))
    await waitFor(() => expectRouteMetadata('/docs/guide/status/'))
  })

  it('moves focus to the new page landmark during client navigation', async () => {
    vi.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      callback(0)
      return 1
    })
    vi.spyOn(window, 'cancelAnimationFrame').mockImplementation(() => undefined)
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined)

    render(<MemoryRouter initialEntries={['/']}><Root /></MemoryRouter>)
    const primaryNavigation = screen.getByRole('navigation', { name: 'Primary navigation' })
    fireEvent.click(within(primaryNavigation).getByRole('link', { name: 'Install' }))

    await waitFor(() => expect(screen.getByRole('main')).toHaveFocus())
  })

  it('closes with the canonical honesty line and experimental status', () => {
    render(<BrowserRouter><Root /></BrowserRouter>)

    expect(screen.getByText('Compile CSS.').closest('p')).toHaveTextContent('Compile CSS. Keep the meaning.')
    expect(screen.getByRole('link', { name: 'Capabilities' })).toHaveAttribute('href', '/features')
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
    expect(within(menu as HTMLElement).getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs/guide/status')
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
      expect(target).toHaveFocus()
      expect(target).toHaveAttribute('tabindex', '-1')
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
