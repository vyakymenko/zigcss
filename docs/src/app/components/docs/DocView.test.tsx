import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { describe, expect, it } from 'vitest'
import { DocView } from './DocView'

function renderStatusGuide() {
  return render(
    <MemoryRouter initialEntries={['/docs/guide/status']}>
      <Routes>
        <Route path="/docs/*" element={<DocView />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('DocView', () => {
  it('keeps inline code semantic without typography-generated backticks', () => {
    const { container } = renderStatusGuide()
    const article = container.querySelector('article')
    const latest = screen.getAllByText('latest', { selector: 'code' })[0]

    expect(latest).toHaveTextContent(/^latest$/)
    expect(article).toHaveClass(
      'prose-code:before:content-none',
      'prose-code:after:content-none',
    )
  })

  it('does not leak react-markdown syntax nodes into rendered links', () => {
    renderStatusGuide()
    const links = screen.getAllByRole('link', { name: "Yarn's official SDK guidance" })

    expect(links.length).toBeGreaterThan(0)
    for (const link of links) {
      expect(link).not.toHaveAttribute('node')
      expect(link).toHaveAttribute('target', '_blank')
      expect(link).toHaveAttribute('rel', 'noopener noreferrer')
    }
  })
})
