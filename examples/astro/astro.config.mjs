import { defineConfig } from 'astro/config'
import zigcss from 'zigcss/vite'

export default defineConfig({
  output: 'static',
  vite: {
    plugins: [zigcss({ maxWorkers: 2, sourceMap: true })],
    build: {
      assetsInlineLimit: 0,
      sourcemap: true,
    },
  },
})
