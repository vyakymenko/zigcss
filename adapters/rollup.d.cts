import type adapters = require('./index.cjs')

declare function factory(options?: adapters.AdapterOptions): adapters.RollupStylePlugin

declare namespace factory {
  const zigcss: typeof factory
}

export = factory
