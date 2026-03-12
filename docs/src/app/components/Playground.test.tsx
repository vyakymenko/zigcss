import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Playground } from './Playground'

describe('Playground', () => {
  it('renders ZigCSS Playground heading', () => {
    render(<Playground />)
    expect(screen.getByText('ZigCSS Playground')).toBeInTheDocument()
  })

  it('shows Compile button', () => {
    render(<Playground />)
    expect(screen.getByRole('button', { name: /compile/i })).toBeInTheDocument()
  })

  it('shows Reset button', () => {
    render(<Playground />)
    expect(screen.getByRole('button', { name: /reset/i })).toBeInTheDocument()
  })

  it('shows Copy CSS button', () => {
    render(<Playground />)
    expect(screen.getByRole('button', { name: /copy css/i })).toBeInTheDocument()
  })

  it('initial ZigCSS input contains .card', () => {
    render(<Playground />)
    const textareas = screen.getAllByRole('textbox')
    expect((textareas[0] as HTMLTextAreaElement).value).toContain('.card')
  })

  it('initial CSS output contains .card', () => {
    render(<Playground />)
    const textareas = screen.getAllByRole('textbox')
    expect((textareas[1] as HTMLTextAreaElement).value).toContain('.card')
  })

  it('output textarea is read-only', () => {
    render(<Playground />)
    const textareas = screen.getAllByRole('textbox')
    expect(textareas[1]).toHaveAttribute('readonly')
  })
})
