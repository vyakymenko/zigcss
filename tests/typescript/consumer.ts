import api, {
  ZigCssCompileError,
  compile,
  compileFile,
  compileFileSync,
  compileSync,
  detectSyntax,
  type CompileResult,
  type Diagnostic,
  type SourceMap,
} from 'zigcss'
import adapters, {
  createBunPlugin,
  createEsbuildPlugin,
  createRollupPlugin,
  createVitePlugin,
  type AdapterOptions,
  type BunPlugin,
  type EsbuildPlugin,
  type RollupStylePlugin,
} from 'zigcss/adapters'
import bunDefault, { zigcss as bunNamed } from 'zigcss/bun'
import esbuildDefault, { zigcss as esbuildNamed } from 'zigcss/esbuild'
import rollupDefault, { zigcss as rollupNamed } from 'zigcss/rollup'
import rspackLoader, { type RspackLoaderContext } from 'zigcss/rspack'
import viteDefault, { zigcss as viteNamed } from 'zigcss/vite'
import webpackLoader, { type WebpackLoaderContext } from 'zigcss/webpack'

const options = {
  format: 'minified',
  sourceMap: true,
  browsers: 'safari >= 17.2',
  rootPaths: ['/project/styles'],
  timeoutMs: 10_000,
  maxWorkers: 4,
} satisfies AdapterOptions

const vite: RollupStylePlugin = createVitePlugin(options)
const rollup: RollupStylePlugin = createRollupPlugin(options)
const esbuild: EsbuildPlugin = createEsbuildPlugin(options)
const bun: BunPlugin = createBunPlugin(options)
const viteSubpath: RollupStylePlugin = viteDefault(options)
const viteNamedSubpath: RollupStylePlugin = viteNamed(options)
const rollupSubpath: RollupStylePlugin = rollupDefault(options)
const rollupNamedSubpath: RollupStylePlugin = rollupNamed(options)
const esbuildSubpath: EsbuildPlugin = esbuildDefault(options)
const esbuildNamedSubpath: EsbuildPlugin = esbuildNamed(options)
const bunSubpath: BunPlugin = bunDefault(options)
const bunNamedSubpath: BunPlugin = bunNamed(options)
const defaultCompile: typeof compile = api.compile
const defaultViteFactory: typeof createVitePlugin = adapters.createVitePlugin

const webpack: (
  this: WebpackLoaderContext,
  source: string | Uint8Array,
  inputSourceMap?: SourceMap | null,
) => void = webpackLoader
const rspack: (
  this: RspackLoaderContext,
  source: string | Uint8Array,
  inputSourceMap?: SourceMap | null,
) => void = rspackLoader

async function exerciseApi(): Promise<CompileResult> {
  const controller = new AbortController()
  const result = await compile('.card { color: red; }', {
    syntax: 'css',
    format: 'pretty',
    sourceMap: true,
    timeoutMs: 1_000,
    signal: controller.signal,
  })
  const fileResult = await compileFile('/project/styles/app.scss', {
    syntax: 'scss',
    optimize: true,
  })
  const syncResult = compileSync('.card { color: red; }')
  const syncFileResult = compileFileSync('/project/styles/app.less')
  const diagnostic: Diagnostic | undefined = result.diagnostics[0]
  const syntax = detectSyntax('theme.styl')
  const error = new ZigCssCompileError('TEST', 'typed failure', diagnostic ? [diagnostic] : [])

  // @ts-expect-error compile results are immutable snapshots.
  result.css = fileResult.css
  // @ts-expect-error nested diagnostics are immutable snapshots.
  result.diagnostics[0]!.message = 'changed'
  // @ts-expect-error sync compilation cannot accept AbortSignal.
  compileSync('a {}', { signal: controller.signal })
  // @ts-expect-error file compilation owns sourcePath.
  compileFile('/project/styles/app.scss', { sourcePath: '/other.scss' })

  void [syncResult, syncFileResult, syntax, error]
  return result
}

// @ts-expect-error adapter concurrency is numeric and bounded at runtime.
createVitePlugin({ maxWorkers: '4' })
// @ts-expect-error the adapter option surface is closed.
createRollupPlugin({ plugins: [] })

void [
  api,
  adapters,
  vite,
  rollup,
  esbuild,
  bun,
  viteSubpath,
  viteNamedSubpath,
  rollupSubpath,
  rollupNamedSubpath,
  esbuildSubpath,
  esbuildNamedSubpath,
  bunSubpath,
  bunNamedSubpath,
  defaultCompile,
  defaultViteFactory,
  webpack,
  rspack,
  viteDefault,
  viteNamed,
  rollupDefault,
  rollupNamed,
  esbuildDefault,
  esbuildNamed,
  bunDefault,
  bunNamed,
  exerciseApi,
]
