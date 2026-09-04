import { render, waitFor } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { RouteMetadata } from './RouteMetadata'
import { publishedSoftwareMetadata } from '../../data/seo-routes.mjs'

function head(attribute: string, value: string) {
  return document.head.querySelector<HTMLElement>(`${attribute}[${value}]`)
}

describe('RouteMetadata', () => {
  it('replaces the docs alias noindex policy after its canonical redirect', async () => {
    const { rerender } = render(<RouteMetadata pathname="/docs" />)

    await waitFor(() => {
      expect(head('meta', 'name="robots"')).toHaveAttribute('content', 'noindex,follow')
      expect(head('link', 'rel="canonical"')).toHaveAttribute(
        'href',
        'https://vyakymenko.github.io/zigcss/docs/guide/status/',
      )
    })

    rerender(<RouteMetadata pathname="/docs/guide/status" />)
    await waitFor(() => {
      expect(head('meta', 'name="robots"')).toHaveAttribute('content', 'index,follow,max-image-preview:large')
      expect(document.title).toBe('ZigCSS capability and release status')
    })
  })

  it('keeps the disabled playground and unknown routes honest and unindexed', async () => {
    const { rerender } = render(<RouteMetadata pathname="/playground" />)

    await waitFor(() => {
      expect(document.title).toBe('ZigCSS public compiler is unavailable')
      expect(head('meta', 'name="robots"')).toHaveAttribute('content', 'noindex,follow')
      expect(head('link', 'rel="canonical"')).toHaveAttribute(
        'href',
        'https://vyakymenko.github.io/zigcss/playground/',
      )
    })

    rerender(<RouteMetadata pathname="/docs/guide/missing" />)
    await waitFor(() => {
      expect(document.title).toBe('Page not found — ZigCSS')
      expect(head('meta', 'name="robots"')).toHaveAttribute('content', 'noindex,follow')
      expect(head('link', 'rel="canonical"')).toHaveAttribute(
        'href',
        'https://vyakymenko.github.io/zigcss/docs/guide/missing/',
      )
      expect(head('meta', 'property="og:url"')).toHaveAttribute(
        'content',
        'https://vyakymenko.github.io/zigcss/docs/guide/missing/',
      )
    })
  })

  it('removes stable structured data on source-only routes and restores it on stable routes', async () => {
    const { rerender } = render(<RouteMetadata pathname="/docs/guide/recovery-cli" />)

    await waitFor(() => {
      expect(document.head.querySelector('#zigcss-software-metadata')).toBeNull()
    })

    rerender(<RouteMetadata pathname="/getting-started" />)
    await waitFor(() => {
      const metadata = document.head.querySelector<HTMLScriptElement>('#zigcss-software-metadata')
      expect(metadata).not.toBeNull()
      expect(metadata?.type).toBe('application/ld+json')
      expect(JSON.parse(metadata?.textContent ?? '{}')).toEqual(publishedSoftwareMetadata)
    })

    rerender(<RouteMetadata pathname="/docs/guide/css-compatibility" />)
    await waitFor(() => {
      expect(document.head.querySelector('#zigcss-software-metadata')).toBeNull()
    })
  })
})
