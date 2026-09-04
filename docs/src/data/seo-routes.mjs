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
    title: 'ZigCSS capability and release status',
    description: 'Review the evidence-backed ZigCSS capability matrix, stable and experimental boundaries, release artifacts, and verification gates.',
  },
  {
    canonicalPath: '/docs/guide/css-compatibility/',
    title: 'ZigCSS Unreleased CSS compatibility matrix',
    description: 'Review current-source ZigCSS parser, optimizer, prefixing, and extraction boundaries—not published stable 0.6.0 behavior.',
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
    title: 'ZigCSS Unreleased builder and framework proofs',
    description: 'Run current-source ZigCSS proofs for pinned JavaScript builders, frameworks, native build systems, and package managers—not stable 0.6.0 delivery.',
    sourceOnly: true,
  },
  {
    canonicalPath: '/docs/guide/recovery-cli/',
    title: 'ZigCSS Unreleased CLI and recovery contract',
    description: 'Inspect the current-source ZigCSS CLI and future package recovery contract, with explicit boundaries from published stable 0.6.0.',
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
