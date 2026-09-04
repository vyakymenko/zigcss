import api = require('zigcss')
import adapters = require('zigcss/adapters')
import bun = require('zigcss/bun')
import esbuild = require('zigcss/esbuild')
import rollup = require('zigcss/rollup')
import rspackLoader = require('zigcss/rspack')
import vite = require('zigcss/vite')
import webpackLoader = require('zigcss/webpack')
import type { LoaderDefinitionFunction as RspackLoaderDefinitionFunction } from '@rspack/core'
import type { Plugin as EsbuildHostPlugin } from 'esbuild'
import type { Plugin as RollupHostPlugin } from 'rollup'
import type { Plugin as ViteHostPlugin } from 'vite' with { 'resolution-mode': 'import' }
import type { LoaderDefinitionFunction as WebpackLoaderDefinitionFunction } from 'webpack'

const options: adapters.AdapterOptions = {
  browsers: 'safari >= 17.2',
  maxWorkers: 2,
}

const result: Promise<api.CompileResult> = api.compile('a {}')
const viteHost: ViteHostPlugin = vite(options)
const rollupHost: RollupHostPlugin = rollup(options)
const esbuildHost: EsbuildHostPlugin = esbuild(options)
const webpackHost: WebpackLoaderDefinitionFunction<adapters.AdapterOptions> = webpackLoader
const rspackHost: RspackLoaderDefinitionFunction<adapters.AdapterOptions> = rspackLoader
const webpackRaw: true = webpackLoader.raw
const rspackRaw: true = rspackLoader.raw

const viteNamed = vite.zigcss(options)
const rollupNamed = rollup.zigcss(options)
const esbuildNamed = esbuild.zigcss(options)
const bunDefault = bun(options)
const bunNamed = bun.zigcss(options)
const adapterFactory = adapters.createVitePlugin(options)

// @ts-expect-error CommonJS module.exports has no phantom default property.
api.default
// @ts-expect-error CommonJS adapter module.exports has no phantom default property.
adapters.default
// @ts-expect-error CommonJS factory module.exports has no phantom default property.
vite.default
// @ts-expect-error CommonJS raw loader module.exports has no phantom default property.
webpackLoader.default

void [
  result,
  viteHost,
  rollupHost,
  esbuildHost,
  webpackHost,
  rspackHost,
  webpackRaw,
  rspackRaw,
  viteNamed,
  rollupNamed,
  esbuildNamed,
  bunDefault,
  bunNamed,
  adapterFactory,
]
