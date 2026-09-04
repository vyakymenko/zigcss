import api, {
  compile,
  type CompileResult,
} from 'zigcss'
import adapters, {
  createBunPlugin,
  createEsbuildPlugin,
  createRollupPlugin,
  createVitePlugin,
  type AdapterOptions,
} from 'zigcss/adapters'
import bunDefault, { zigcss as bunNamed } from 'zigcss/bun'
import esbuildDefault, { zigcss as esbuildNamed } from 'zigcss/esbuild'
import rollupDefault, { zigcss as rollupNamed } from 'zigcss/rollup'
import rspackLoader, { type RspackLoaderContext } from 'zigcss/rspack'
import viteDefault, { zigcss as viteNamed } from 'zigcss/vite'
import webpackLoader, { type WebpackLoaderContext } from 'zigcss/webpack'
import type { LoaderDefinitionFunction as RspackLoaderDefinitionFunction } from '@rspack/core'
import type { Plugin as EsbuildHostPlugin } from 'esbuild'
import type { Plugin as RollupHostPlugin } from 'rollup'
import type { Plugin as ViteHostPlugin } from 'vite'
import type { LoaderDefinitionFunction as WebpackLoaderDefinitionFunction } from 'webpack'

const options = {
  format: 'pretty',
  sourceMap: true,
  maxWorkers: 2,
} satisfies AdapterOptions

const resultPromise: Promise<CompileResult> = compile('a {}')
const defaultCompile: typeof compile = api.compile
const defaultFactory: typeof createVitePlugin = adapters.createVitePlugin

const esbuildHost: EsbuildHostPlugin = createEsbuildPlugin(options)
const rollupHost: RollupHostPlugin = createRollupPlugin(options)
const viteHost: ViteHostPlugin = createVitePlugin(options)
const webpackHost: WebpackLoaderDefinitionFunction<AdapterOptions> = webpackLoader
const rspackHost: RspackLoaderDefinitionFunction<AdapterOptions> = rspackLoader
const webpackRaw: true = webpackLoader.raw
const rspackRaw: true = rspackLoader.raw

const vite = viteDefault(options)
const viteFromNamed = viteNamed(options)
const rollup = rollupDefault(options)
const rollupFromNamed = rollupNamed(options)
const esbuild = esbuildDefault(options)
const esbuildFromNamed = esbuildNamed(options)
const bun = bunDefault(options)
const bunFromNamed = bunNamed(options)
const bunFromAdapters = createBunPlugin(options)

// @ts-expect-error ESM defaults are the API value, not a namespace carrying another default.
api.default
// @ts-expect-error ESM adapter defaults are callable factories, not nested default namespaces.
viteDefault.default

void [
  resultPromise,
  defaultCompile,
  defaultFactory,
  esbuildHost,
  rollupHost,
  viteHost,
  webpackHost,
  rspackHost,
  webpackRaw,
  rspackRaw,
  vite,
  viteFromNamed,
  rollup,
  rollupFromNamed,
  esbuild,
  esbuildFromNamed,
  bun,
  bunFromNamed,
  bunFromAdapters,
]

declare const webpackContext: WebpackLoaderContext
declare const rspackContext: RspackLoaderContext
void [webpackContext, rspackContext]
