import adapters from './index.cjs'

export const {
  createBunPlugin,
  createEsbuildPlugin,
  createRollupPlugin,
  createVitePlugin,
  ZigCssAdapterError,
} = adapters

export default adapters
