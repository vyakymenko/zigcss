import adapter from '@sveltejs/adapter-static'
import { sveltekit } from '@sveltejs/kit/vite'
import { defineConfig } from 'vite'
import zigcss from 'zigcss/vite'

export default defineConfig({
  plugins: [
    zigcss({ maxWorkers: 2, sourceMap: true }),
    sveltekit({ adapter: adapter() }),
  ],
  build: {
    sourcemap: true,
  },
})
