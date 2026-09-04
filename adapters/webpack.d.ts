import type { AdapterOptions } from './webpack-types'

export interface WebpackLoaderContext {
  readonly resourcePath: string
  readonly sourceMap?: boolean
  readonly query?: AdapterOptions | string
  async(): (
    error: Error | null,
    content?: string,
    sourceMap?: any,
    meta?: any,
  ) => void
  getOptions?(): AdapterOptions
  cacheable?(value?: boolean): void
  addDependency?(filename: string): void
  emitWarning?(warning: Error): void
}

declare function loader(
  this: WebpackLoaderContext,
  source: string | Uint8Array,
  inputSourceMap?: unknown,
): void

declare namespace loader {
  const raw: true
}

export default loader
