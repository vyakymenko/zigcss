import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { GettingStarted } from './GettingStarted'

function renderGettingStarted() {
  render(<BrowserRouter><GettingStarted /></BrowserRouter>)
}

describe('GettingStarted', () => {
  it('starts with the published stable installation path', () => {
    renderGettingStarted()
    expect(screen.getByRole('heading', { name: /start with any of five stylesheet languages/i })).toBeInTheDocument()
    expect(screen.getByText('npm install --save-dev zigcss')).toBeInTheDocument()
    expect(screen.getByText(/ZigCSS 0\.6\.0 is published on npm latest and as a non-prerelease GitHub Release/i)).toBeInTheDocument()
    expect(screen.getByText(/published RC remains unchanged on next/i)).toBeInTheDocument()
  })

  it('shows the verified source build and test commands', () => {
    renderGettingStarted()
    expect(screen.getByText(/zig build test --summary all/)).toBeInTheDocument()
    expect(screen.getAllByText(/zig-out\/bin\/zigcss --syntax scss input\.scss -o output\.css --minify/)).toHaveLength(2)
  })

  it('presents the exact native language and development-oracle boundary', () => {
    renderGettingStarted()
    expect(screen.getByText(/the source snapshot compiles css, scss, indented sass, less, and stylus through self-contained native zig frontends/i)).toBeInTheDocument()
    expect(screen.getByText(/dart sass 1\.101\.0.*less 4\.9\.0.*stylus 0\.64\.0.*development-only reference oracles.*frozen 4\.6\.7 native baseline/i)).toBeInTheDocument()
    expect(screen.getByText(/does not enable arbitrary plugins/i)).toBeInTheDocument()
  })

  it('links to the current status', () => {
    renderGettingStarted()
    expect(screen.getByRole('link', { name: /review the current status/i })).toHaveAttribute('href', '/docs/guide/status')
  })
})
