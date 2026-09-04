import type { Diagnostic } from '../api'

export interface AdapterOptions {
  /** Pretty output by default; let the host bundler own final minification. */
  readonly format?: 'pretty' | 'minified'
  /** Enabled by default unless optimize is true. */
  readonly sourceMap?: boolean
  /** Verified fixed-point optimization; incompatible with sourceMap. */
  readonly optimize?: boolean
  /** Explicit ZigCSS target query; no Browserslist discovery is performed. */
  readonly browsers?: string | null
  /** One to sixteen confined native import roots. */
  readonly rootPaths?: readonly string[]
  readonly timeoutMs?: number
  /** Concurrent native processes, from 1 through 32; defaults to min(host CPUs, 8). */
  readonly maxWorkers?: number
}

export interface RollupStylePlugin {
  readonly name: string
  readonly enforce?: 'pre'
  resolveId(
    this: RollupPluginContext,
    source: string,
    importer?: string,
    options?: Readonly<Record<string, unknown>>,
  ): Promise<null | string | { readonly id: string; readonly moduleSideEffects: true }>
  load(
    this: RollupPluginContext,
    id: string,
  ): Promise<null | {
    readonly code: string
    readonly map: any
    readonly moduleSideEffects: true
  }>
}

export interface RollupPluginContext {
  resolve(
    source: string,
    importer?: string,
    options?: Readonly<Record<string, unknown>>,
  ): Promise<null | string | {
    readonly id: string
    readonly external?: boolean | 'absolute' | 'relative'
  }>
  addWatchFile?(filename: string): void
  warn?(warning: any): void
  error?(error: any): never
}

export interface EsbuildPlugin {
  readonly name: 'zigcss'
  setup(build: {
    onLoad(
      options: { readonly filter: RegExp; readonly namespace?: string },
      callback: (args: { readonly path: string; readonly namespace: string }) => Promise<Readonly<Record<string, unknown>>>,
    ): void
  }): void
}

export interface BunPlugin {
  readonly name: 'zigcss'
  setup(build: {
    onLoad(
      options: { readonly filter: RegExp; readonly namespace?: string },
      callback: (args: { readonly path: string; readonly namespace: string }) => Promise<Readonly<Record<string, unknown>>>,
    ): void
  }): void
}

export class ZigCssAdapterError extends Error {
  readonly code: string
  constructor(code: string, message: string, options?: ErrorOptions)
}

export function createVitePlugin(options?: AdapterOptions): RollupStylePlugin
export function createRollupPlugin(options?: AdapterOptions): RollupStylePlugin
export function createEsbuildPlugin(options?: AdapterOptions): EsbuildPlugin
export function createBunPlugin(options?: AdapterOptions): BunPlugin

declare const adapters: Readonly<{
  createVitePlugin: typeof createVitePlugin
  createRollupPlugin: typeof createRollupPlugin
  createEsbuildPlugin: typeof createEsbuildPlugin
  createBunPlugin: typeof createBunPlugin
  ZigCssAdapterError: typeof ZigCssAdapterError
}>

export default adapters

export type AdapterDiagnostic = Diagnostic
