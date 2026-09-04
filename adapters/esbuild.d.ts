import type { AdapterOptions, EsbuildPlugin } from './index'

declare function zigcss(options?: AdapterOptions): EsbuildPlugin

export { zigcss }
export default zigcss
