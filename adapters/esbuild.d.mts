import type { AdapterOptions, EsbuildPlugin } from './index.mjs'

declare function zigcss(options?: AdapterOptions): EsbuildPlugin

export { zigcss }
export default zigcss
