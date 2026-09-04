import zigcss from 'zigcss/vite'

export default defineNuxtConfig({
  compatibilityDate: '2026-08-01',
  devtools: { enabled: false },
  nitro: {
    prerender: {
      routes: ['/'],
    },
  },
  sourcemap: {
    client: true,
    server: true,
  },
  telemetry: false,
  vite: {
    plugins: [zigcss({ maxWorkers: 2, sourceMap: true })],
    build: {
      assetsInlineLimit: 0,
      sourcemap: true,
    },
  },
})
