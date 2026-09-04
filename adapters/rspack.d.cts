import type adapters = require('./index.cjs')

interface RspackLoaderContextShape {
  readonly resourcePath: string
  readonly sourceMap?: boolean
  readonly query?: adapters.AdapterOptions | string
  async(): (
    error: Error | null,
    content?: string,
    sourceMap?: any,
    meta?: any,
  ) => void
  getOptions?(): adapters.AdapterOptions
  cacheable?(value?: boolean): void
  addDependency?(filename: string): void
  emitWarning?(warning: Error): void
}

declare function loader(
  this: RspackLoaderContextShape,
  source: string | Uint8Array,
  inputSourceMap?: unknown,
): void

declare namespace loader {
  const raw: true
  type RspackLoaderContext = RspackLoaderContextShape
}

export = loader
