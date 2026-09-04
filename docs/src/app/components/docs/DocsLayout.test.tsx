import React from 'react'
import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { MemoryRouter } from 'react-router'
import { DocsLayout } from './DocsLayout'

describe('DocsLayout', () => {
  it.each([
    '/docs/guide/status',
    '/docs/guide/status/',
  ])('marks the canonical status route active at %s', pathname => {
    render(<MemoryRouter initialEntries={[pathname]}><DocsLayout /></MemoryRouter>)

    expect(screen.getByRole('link', { name: 'Current status' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'CSS compatibility' })).not.toHaveAttribute('aria-current')
  })

  it('marks the builder integration guide active without prefix collisions', () => {
    render(<MemoryRouter initialEntries={['/docs/guide/builder-integrations/']}><DocsLayout /></MemoryRouter>)

    expect(screen.getByRole('link', { name: 'Builder integrations' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Build from source' })).not.toHaveAttribute('aria-current')
  })
})
