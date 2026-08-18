import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { BrowserRouter } from 'react-router'
import { Home } from './Home'

function renderHome() {
  return render(<BrowserRouter><Home /></BrowserRouter>)
}

describe('Home', () => {
  beforeEach(() => window.sessionStorage.clear())

  it('opens as a terminal manifesto with an unavoidable release boundary', () => {
    renderHome()

    expect(screen.getByRole('dialog', { name: /zigcss boot sequence/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /exact in\. deterministic out\. denied by default/i })).toBeInTheDocument()
    expect(screen.getByText('Compile CSS. Keep the meaning.')).toBeInTheDocument()
    expect(screen.getByText(/0\.6\.0.*stable candidate.*zero runtime dependencies/i)).toBeInTheDocument()
    expect(screen.getByText(/stable source identity 0\.6\.0 is bound to one immutable promotion workflow/i)).toBeInTheDocument()
    expect(screen.getByText(/comparative speed claims remain locked until controlled Linux x64 evidence exists/i)).toBeInTheDocument()
    expect(screen.getByText(/^all five source inputs run through self-contained native zig frontends\. one self-contained compiler/i)).toBeInTheDocument()
  })

  it('puts the real install command and lab entry in the hero', () => {
    renderHome()

    expect(screen.getByRole('button', { name: /copy install command: npm install --save-dev zigcss@0\.6\.0/i })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /enter the lab/i })).toHaveAttribute('href', '#formats')
    expect(screen.getByRole('link', { name: /five inputs converge/i })).toHaveAttribute('href', '#convergence')
  })

  it('builds the eight-movement story from the five load-bearing truths', () => {
    const { container } = renderHome()

    expect(screen.getByRole('heading', { name: /five languages in\. one deterministic compiler out/i })).toBeInTheDocument()
    expect(container.querySelector('canvas[aria-hidden="true"]')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /your css toolchain should not be able to phone home/i })).toBeInTheDocument()
    expect(screen.getByText('NETWORK')).toBeInTheDocument()
    expect(screen.getAllByText('DENIED')).toHaveLength(3)
    expect(screen.getByRole('heading', { name: /same input\. same bytes\. every machine\. every time/i })).toBeInTheDocument()
    expect(screen.getByText('run 1 = run 2 = run 3')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /all output\. or no output/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /one path\. no parser drift/i })).toBeInTheDocument()
    expect(screen.getByText('OWNED COMPILE RESULT')).toBeInTheDocument()
  })

  it('marks the stable promotion as gated and exposes real deployment surfaces', () => {
    renderHome()

    expect(screen.getByText('STABLE PROMOTION · GATES ACTIVE')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /the providers are oracles/i })).toBeInTheDocument()
    expect(screen.getByText(/one self-contained compiler\. zero production package dependencies/i)).toBeInTheDocument()
    expect(screen.getByText(/REL-010.*0\.6\.0.*exact promotion evidence required/i)).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /choose your entry point/i })).toBeInTheDocument()
    for (const target of ['Linux x64', 'Linux arm64', 'macOS x64', 'macOS arm64', 'Windows x64']) {
      expect(screen.getByText(target)).toBeInTheDocument()
    }
    expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute('href', '/docs')
    expect(screen.getByRole('link', { name: 'npm' })).toHaveAttribute('href', 'https://www.npmjs.com/package/zigcss')
  })

  it('keeps benchmark hype evidence-locked and bans inflated marketing copy', () => {
    renderHome()
    const copy = document.body.textContent ?? ''

    expect(screen.getByRole('heading', { name: /native is the architecture\. evidence decides the ranking/i })).toBeInTheDocument()
    expect(copy).toMatch(/comparative rankings remain unpublished until the controlled pipeline lands/i)
    expect(copy).not.toMatch(/world.?s fastest|\d+\s*[x×]\s*faster/i)
    expect(copy).not.toMatch(/blazingly|supercharge|seamless|effortless|next-generation|game-changing|revolutionize/i)
    expect(copy).not.toContain('!')
  })
})
