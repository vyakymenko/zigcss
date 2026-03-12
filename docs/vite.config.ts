import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { zigcssCompilePlugin } from './scripts/compile-api-plugin.js'
import fs from 'fs'
import path from 'path'

/**
 * Watches the zigcss binary for changes (i.e. after a Zig rebuild) and
 * triggers a full page reload so the playground picks up the new engine.
 */
function zigBinaryWatchPlugin() {
  const binPath = path.resolve(import.meta.dirname, '..', 'bin', 'zigcss')
  return {
    name: 'zigcss-binary-watch',
    configureServer(server) {
      try {
        let debounce: ReturnType<typeof setTimeout> | null = null
        fs.watch(binPath, () => {
          if (debounce) clearTimeout(debounce)
          debounce = setTimeout(() => {
            server.config.logger.info('zigcss binary changed – reloading…', { timestamp: true })
            server.ws.send({ type: 'full-reload' })
          }, 500)
        })
      } catch {
        // Binary doesn't exist yet or watch fails – not fatal
      }
    },
  }
}

export default defineConfig({
  base: '/',
  plugins: [react(), tailwindcss(), zigcssCompilePlugin(), zigBinaryWatchPlugin()],
  server: {
    host: true,            // listen on 0.0.0.0 (required inside Docker)
    allowedHosts: true,    // allow all hosts (Traefik proxies with real domain)
    watch: {
      usePolling: true,    // reliable file-watching inside Docker volumes
      interval: 500,
    },
  },
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
