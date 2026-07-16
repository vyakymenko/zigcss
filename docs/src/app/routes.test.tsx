import { describe, it, expect } from 'vitest'
import { router } from './routes'

describe('router', () => {
  it('uses the GitHub Pages project basename', () => {
    expect(router.basename).toBe('/zigcss')
  })

  it('has root route with path /', () => {
    const root = router.routes[0]
    expect(root.path).toBe('/')
  })

  it('has index route', () => {
    const root = router.routes[0]
    const children = 'children' in root ? root.children : []
    const index = children?.find((r: { index?: boolean }) => r.index === true)
    expect(index).toBeDefined()
  })

  it('has playground route', () => {
    const root = router.routes[0]
    const children = 'children' in root ? root.children : []
    const playground = children?.find((r: { path?: string }) => r.path === 'playground')
    expect(playground).toBeDefined()
  })

  it('has docs route with nested children', () => {
    const root = router.routes[0]
    const children = 'children' in root ? root.children : []
    const docs = children?.find((r: { path?: string }) => r.path === 'docs')
    expect(docs).toBeDefined()
    const docsChildren = docs && 'children' in docs ? docs.children : []
    expect(docsChildren?.length).toBeGreaterThan(0)
  })

  it('has getting-started and features routes', () => {
    const root = router.routes[0]
    const children = 'children' in root ? root.children : []
    const gettingStarted = children?.find((r: { path?: string }) => r.path === 'getting-started')
    const features = children?.find((r: { path?: string }) => r.path === 'features')
    expect(gettingStarted).toBeDefined()
    expect(features).toBeDefined()
  })
})
