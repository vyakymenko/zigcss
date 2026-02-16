import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'zigcss',
  description: 'The world\'s fastest CSS compiler - Built with Zig for uncompromising performance',
  base: '/zigcss/',
  
  head: [
    ['link', { rel: 'icon', href: '/zigcss/favicon.ico' }],
    ['meta', { name: 'theme-color', content: '#3eaf7c' }],
  ],

  themeConfig: {
    logo: '/logo.svg',
    
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'API', link: '/api/compile-options' },
      { text: 'Examples', link: '/examples/css-nesting' },
      { text: 'GitHub', link: 'https://github.com/vyakymenko/zigcss' },
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'Getting Started',
          items: [
            { text: 'Introduction', link: '/guide/getting-started' },
            { text: 'Installation', link: '/guide/installation' },
            { text: 'Quick Start', link: '/guide/quick-start' },
          ],
        },
        {
          text: 'Features',
          items: [
            { text: 'Preprocessors', link: '/guide/preprocessors' },
            { text: 'Optimization', link: '/guide/optimization' },
            { text: 'Performance', link: '/guide/performance' },
          ],
        },
        {
          text: 'Advanced',
          items: [
            { text: 'Plugin System', link: '/guide/plugins' },
            { text: 'Build Integration', link: '/guide/build-integration' },
            { text: 'LSP Support', link: '/guide/lsp' },
          ],
        },
      ],
      '/api/': [
        {
          text: 'API Reference',
          items: [
            { text: 'CompileOptions', link: '/api/compile-options' },
            { text: 'CompileResult', link: '/api/compile-result' },
            { text: 'Plugin API', link: '/api/plugin-api' },
          ],
        },
      ],
      '/examples/': [
        {
          text: 'Examples',
          items: [
            { text: 'CSS Nesting', link: '/examples/css-nesting' },
            { text: 'Custom Properties', link: '/examples/custom-properties' },
            { text: 'Media Queries', link: '/examples/media-queries' },
            { text: 'Container Queries', link: '/examples/container-queries' },
            { text: 'Tailwind @apply', link: '/examples/tailwind-apply' },
            { text: 'SCSS Features', link: '/examples/scss-features' },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/vyakymenko/zigcss' },
    ],

    footer: {
      message: 'Made with ⚡ for speed',
      copyright: 'Copyright © 2026 Valentyn Yakymenko',
    },

    search: {
      provider: 'local',
    },
  },
})
