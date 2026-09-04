import { useEffect } from 'react'
import {
  publishedSoftwareMetadataJson,
  routeAliases,
  routeMetadata,
  siteOrigin,
} from '../../data/seo-routes.mjs'

type SeoMetadata = {
  canonicalPath: string
  title: string
  description: string
  robots: 'index,follow,max-image-preview:large' | 'noindex,follow'
  sourceOnly?: boolean
}

const indexRobots = 'index,follow,max-image-preview:large' as const
const noIndexRobots = 'noindex,follow' as const

function normalizedPath(pathname: string): string {
  if (pathname === '/') return '/'
  return `/${pathname.replace(/^\/+|\/+$/g, '')}/`
}

export function metadataForPathname(pathname: string): SeoMetadata {
  const normalized = normalizedPath(pathname)
  const canonical = routeMetadata.find(route => route.canonicalPath === normalized)
  if (canonical) return {
    ...canonical,
    robots: indexRobots,
    sourceOnly: 'sourceOnly' in canonical && canonical.sourceOnly === true,
  }

  const alias = routeAliases.find(route => route.outputPath === normalized)
  if (alias) return { ...alias, robots: noIndexRobots, sourceOnly: true }

  if (normalized === '/playground/') {
    return {
      canonicalPath: normalized,
      title: 'ZigCSS public compiler is unavailable',
      description: 'The public ZigCSS compile API and playground remain disabled until bounded request and process isolation is implemented.',
      robots: noIndexRobots,
      sourceOnly: true,
    }
  }

  return {
    canonicalPath: normalized,
    title: 'Page not found — ZigCSS',
    description: 'The requested ZigCSS page does not exist. Open the compiler documentation or return to the project home page.',
    robots: noIndexRobots,
    sourceOnly: true,
  }
}

function updateMeta(attribute: 'name' | 'property', key: string, content: string) {
  let element = document.head.querySelector<HTMLMetaElement>(`meta[${attribute}="${key}"]`)
  if (!element) {
    element = document.createElement('meta')
    element.setAttribute(attribute, key)
    document.head.appendChild(element)
  }
  element.setAttribute('content', content)
}

function updateCanonical(href: string) {
  let element = document.head.querySelector<HTMLLinkElement>('link[rel="canonical"]')
  if (!element) {
    element = document.createElement('link')
    element.setAttribute('rel', 'canonical')
    document.head.appendChild(element)
  }
  element.setAttribute('href', href)
}

function updatePublishedSoftwareMetadata(enabled: boolean) {
  const elements = [...document.head.querySelectorAll<HTMLScriptElement>('script#zigcss-software-metadata')]
  if (!enabled) {
    for (const element of elements) element.remove()
    return
  }

  const element = elements.shift() ?? document.createElement('script')
  for (const duplicate of elements) duplicate.remove()
  element.id = 'zigcss-software-metadata'
  element.type = 'application/ld+json'
  element.textContent = publishedSoftwareMetadataJson
  if (!element.isConnected) document.head.appendChild(element)
}

export function applyRouteMetadata(metadata: SeoMetadata) {
  const canonical = `${siteOrigin}${metadata.canonicalPath}`
  document.title = metadata.title
  updateMeta('name', 'description', metadata.description)
  updateMeta('name', 'robots', metadata.robots)
  updateCanonical(canonical)
  updateMeta('property', 'og:title', metadata.title)
  updateMeta('property', 'og:description', metadata.description)
  updateMeta('property', 'og:url', canonical)
  updateMeta('name', 'twitter:title', metadata.title)
  updateMeta('name', 'twitter:description', metadata.description)
  updatePublishedSoftwareMetadata(metadata.sourceOnly !== true)
}

export function RouteMetadata({ pathname }: { pathname: string }) {
  useEffect(() => {
    applyRouteMetadata(metadataForPathname(pathname))
  }, [pathname])
  return null
}
