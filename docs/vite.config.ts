import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { zigcssCompilePlugin } from './scripts/compile-api-plugin.js'

export default defineConfig({
  base: '/zigcss/',
  plugins: [react(), tailwindcss(), zigcssCompilePlugin()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
  },
  build: {
    target: 'es2022',
    rollupOptions: {
      output: {
        manualChunks: {
          'react-vendor': ['react', 'react-dom', 'react-router'],
          'markdown': ['react-markdown', 'remark-gfm'],
        },
      },
    },
    cssMinify: true,
  },
})
