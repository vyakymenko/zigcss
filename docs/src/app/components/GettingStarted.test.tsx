import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { GettingStarted } from './GettingStarted'

function renderGettingStarted() {
  render(<BrowserRouter><GettingStarted /></BrowserRouter>)
}

describe('GettingStarted', () => {
  it('starts with the npm prerelease installation path', () => {
    renderGettingStarted()
    expect(screen.getByRole('heading', { name: /start with any of five stylesheet languages/i })).toBeInTheDocument()
    expect(screen.getByText('npm install --save-dev zigcss@next')).toBeInTheDocument()
    expect(screen.getAllByText(/release candidate/i)).toHaveLength(2)
  })

  it('shows the verified source build and test commands', () => {
    renderGettingStarted()
    expect(screen.getByText(/zig build test --summary all/)).toBeInTheDocument()
    expect(screen.getByText(/zig-out\/bin\/zigcss input\.css -o output\.css/)).toBeInTheDocument()
  })

  it('presents the exact canonical language and provider boundary', () => {
    renderGettingStarted()
    expect(screen.getByText(/css, scss, indented sass, less, and stylus/i)).toBeInTheDocument()
    expect(screen.getByText(/dart sass 1\.101\.0.*less 4\.6\.7.*stylus 0\.64\.0/i)).toBeInTheDocument()
    expect(screen.getByText(/does not enable arbitrary plugins/i)).toBeInTheDocument()
  })

  it('links to the current status', () => {
    renderGettingStarted()
    expect(screen.getByRole('link', { name: /review the current status/i })).toHaveAttribute('href', '/docs/guide/status')
  })
})
