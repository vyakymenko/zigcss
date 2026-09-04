import { defineConfig, type Plugin } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import fs from 'fs'
import path from 'path'

const externalDevServer = process.env.ZIGCSS_DOCS_DEV_EXTERNAL === '1'
const productionContentSecurityPolicy = "default-src 'self'; base-uri 'none'; connect-src 'none'; font-src 'self'; form-action 'none'; img-src 'self' data:; manifest-src 'self'; media-src 'none'; object-src 'none'; script-src 'self' 'sha256-j1aRjsZaWStLBwznKqdiTDfW2Azet3THlNvhDl0jCag='; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; worker-src 'none'"
const developmentContentSecurityPolicy = productionContentSecurityPolicy
  .replace("connect-src 'none'", "connect-src 'self' ws://127.0.0.1:* ws://localhost:*")
  .replace("style-src 'self'", "style-src 'self' 'unsafe-inline'")

function localDevelopmentContentSecurityPolicyPlugin(): Plugin {
  return {
    name: 'zigcss-local-development-csp',
    apply: 'serve',
    transformIndexHtml(html) {
      const productionAttribute = `content="${productionContentSecurityPolicy}"`
      if (html.split(productionAttribute).length !== 2) {
        throw new Error('expected exactly one production Content-Security-Policy meta tag')
      }
      return html.replace(productionAttribute, `content="${developmentContentSecurityPolicy}"`)
    },
  }
}

/**
 * Watches the zigcss binary for changes (i.e. after a Zig rebuild) and
 * triggers a full page reload so the playground picks up the new engine.
 */
function zigBinaryWatchPlugin() {
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss'
  const configuredBinDirectory = process.env.ZIGCSS_DEV_BIN_DIRECTORY
  if (configuredBinDirectory !== undefined && (
    !path.isAbsolute(configuredBinDirectory) || path.resolve(configuredBinDirectory) !== configuredBinDirectory
  )) {
    throw new Error('ZIGCSS_DEV_BIN_DIRECTORY must be an absolute normalized path')
  }
  const binDirectory = configuredBinDirectory ?? path.resolve(import.meta.dirname, '..', 'bin')
  return {
    name: 'zigcss-binary-watch',
    configureServer(server) {
      let directory
      try {
        directory = fs.lstatSync(binDirectory)
      } catch (error) {
        if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return
        server.config.logger.error(`zigcss binary directory inspection failed: ${String(error)}`, { timestamp: true })
        void server.close()
        return
      }
      if (!directory.isDirectory() || directory.isSymbolicLink()) {
        server.config.logger.error('zigcss binary directory must be a real directory', { timestamp: true })
        void server.close()
        return
      }

      let debounce: ReturnType<typeof setTimeout> | null = null
      let watcher: fs.FSWatcher
      try {
        watcher = fs.watch(binDirectory, (_event, filename) => {
          if (filename !== binaryName) return
          if (debounce) clearTimeout(debounce)
          debounce = setTimeout(() => {
            server.config.logger.info('zigcss binary changed – reloading…', { timestamp: true })
            server.ws.send({ type: 'full-reload' })
          }, 500)
        })
      } catch (error) {
        server.config.logger.error(`zigcss binary watcher failed to start: ${String(error)}`, { timestamp: true })
        void server.close()
        return
      }
      watcher.on('error', error => {
        server.config.logger.error(`zigcss binary watcher failed: ${error.message}`, { timestamp: true })
        void server.close()
      })
      server.httpServer?.once('close', () => {
        if (debounce) clearTimeout(debounce)
        watcher.close()
      })
    },
  }
}

export default defineConfig({
  base: '/zigcss/',
  plugins: [localDevelopmentContentSecurityPolicyPlugin(), react(), tailwindcss(), zigBinaryWatchPlugin()],
  resolve: {
    // Live docs sources are symlinked from the read-only checkout in Docker.
    // Preserve their /app identity so dependencies stay in the isolated volume.
    preserveSymlinks: true,
  },
  server: {
    host: externalDevServer ? '0.0.0.0' : '127.0.0.1',
    allowedHosts: ['localhost', '127.0.0.1'],
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
    manifest: true,
    rollupOptions: {
      output: {
        manualChunks: {
          'react-vendor': ['react', 'react-dom', 'react-router'],
        },
      },
    },
    cssMinify: true,
  },
})
