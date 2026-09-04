import type { AdapterOptions, BunPlugin } from './index.mjs'

declare function zigcss(options?: AdapterOptions): BunPlugin

export { zigcss }
export default zigcss
