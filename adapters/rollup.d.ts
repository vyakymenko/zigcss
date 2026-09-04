import type { AdapterOptions, RollupStylePlugin } from './index'

declare function zigcss(options?: AdapterOptions): RollupStylePlugin

export { zigcss }
export default zigcss
