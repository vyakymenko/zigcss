import type { AdapterOptions } from './index.mjs'

export interface RspackLoaderContext {
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
  this: RspackLoaderContext,
  source: string | Uint8Array,
  inputSourceMap?: unknown,
): void

declare namespace loader {
  const raw: true
}

export default loader
