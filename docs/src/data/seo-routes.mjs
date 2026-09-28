export const siteOrigin = 'https://vyakymenko.github.io/zigcss'

export const publishedSoftwareMetadataJson = `
      {
        "@context": "https://schema.org",
        "@type": "SoftwareSourceCode",
        "name": "ZigCSS",
        "alternateName": "zigcss",
        "version": "0.6.0",
        "description": "A self-contained native compiler for CSS, SCSS, indented Sass, Less, and Stylus.",
        "url": "https://vyakymenko.github.io/zigcss/",
        "codeRepository": "https://github.com/vyakymenko/zigcss",
        "downloadUrl": "https://www.npmjs.com/package/zigcss",
        "programmingLanguage": "Zig",
        "runtimePlatform": ["Linux x64", "Linux arm64", "macOS x64", "macOS arm64", "Windows x64"],
        "license": "https://spdx.org/licenses/MIT.html"
      }
    `

const parsedPublishedSoftwareMetadata = JSON.parse(publishedSoftwareMetadataJson)
parsedPublishedSoftwareMetadata.runtimePlatform = Object.freeze(parsedPublishedSoftwareMetadata.runtimePlatform)
export const publishedSoftwareMetadata = Object.freeze(parsedPublishedSoftwareMetadata)

export const routeMetadata = Object.freeze([
  {
    canonicalPath: '/',
    title: 'ZigCSS — Native CSS, SCSS, Sass, Less & Stylus compiler',
    description: 'Compile CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig frontends with deterministic, fail-closed output.',
  },
  {
    canonicalPath: '/getting-started/',
    title: 'Install and run ZigCSS 0.6.0',
    description: 'Install ZigCSS, compile five stylesheet syntaxes, and learn the explicit native CLI, package, and source-build paths.',
  },
  {
    canonicalPath: '/features/',
    title: 'ZigCSS compiler guarantees and features',
    description: 'Explore ZigCSS deterministic output, atomic failures, confined imports, semantics-preserving transforms, and five native syntax frontends.',
  },
  {
    canonicalPath: '/docs/guide/status/',
    title: 'ZigCSS 0.7.0-rc.2 release status',
    description: 'ZigCSS 0.7.0-rc.2 release attempt failed; GitHub and npm surfaces are absent. Stable 0.6.0 remains published.',
    sourceOnly: true,
  },
  {
    canonicalPath: '/docs/guide/css-compatibility/',
    title: 'ZigCSS source-only CSS compatibility',
    description: 'Source-only CSS compatibility after failed ZigCSS 0.7.0-rc.2 publication. Stable 0.6.0 has a separate contract.',
    sourceOnly: true,
  },
  {
    canonicalPath: '/docs/guide/format-compatibility/',
    title: 'CSS, SCSS, Sass, Less and Stylus compatibility',
    description: 'Compare the verified native CSS, SCSS, indented Sass, Less, and Stylus language surfaces and their explicit plugin limitations.',
  },
  {
    canonicalPath: '/docs/guide/css-modules/',
    title: 'ZigCSS CSS Modules subset',
    description: 'Read the exact experimental CSS Modules subset, deterministic class mapping, composition, and failure behavior supported by ZigCSS.',
  },
  {
    canonicalPath: '/docs/guide/build-from-source/',
    title: 'Build ZigCSS from source with Zig 0.15.2',
    description: 'Build and verify ZigCSS from source, consume its Zig package, and reproduce the supported compiler and example gates.',
  },
  {
    canonicalPath: '/docs/guide/builder-integrations/',
    title: 'ZigCSS source-only builder and framework proofs',
    description: 'Current-source ZigCSS builder and package-manager proofs after failed 0.7.0-rc.2 publication; stable 0.6.0 is separate.',
    sourceOnly: true,
  },
  {
    canonicalPath: '/docs/guide/recovery-cli/',
    title: 'ZigCSS source-only CLI and recovery contract',
    description: 'Source-only ZigCSS CLI and recovery contract after failed 0.7.0-rc.2 publication. Stable 0.6.0 remains available.',
    sourceOnly: true,
  },
])

export const routeAliases = Object.freeze([
  {
    outputPath: '/docs/',
    canonicalPath: '/docs/guide/status/',
    title: 'ZigCSS documentation',
    description: 'Open the evidence-backed ZigCSS documentation and current capability status.',
  },
])
