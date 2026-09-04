import type { AdapterOptions, BunPlugin } from './index'

declare function zigcss(options?: AdapterOptions): BunPlugin

export { zigcss }
export default zigcss
