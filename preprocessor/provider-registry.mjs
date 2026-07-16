import { createDartSassProvider } from './providers/dart-sass.mjs'

export const CANONICAL_PROVIDERS = Object.freeze({
  'dart-sass': Object.freeze({
    package: 'sass',
    version: '1.101.0',
    license: 'MIT',
    adapters: Object.freeze(['scss', 'sass']),
  }),
  less: Object.freeze({
    package: 'less',
    version: '4.6.7',
    license: 'Apache-2.0',
    adapters: Object.freeze(['less']),
  }),
  stylus: Object.freeze({
    package: 'stylus',
    version: '0.64.0',
    license: 'MIT',
    adapters: Object.freeze(['stylus']),
  }),
})

export const PROVIDER_SYNTAXES = Object.freeze({
  'dart-sass': Object.freeze(['scss', 'sass']),
  less: Object.freeze(['less']),
  stylus: Object.freeze(['stylus']),
})

export function createProductionRegistry() {
  return new Map(
    Object.keys(CANONICAL_PROVIDERS).map(providerId => {
      const implementation = providerId === 'dart-sass'
        ? createDartSassProvider()
        : { syntaxes: PROVIDER_SYNTAXES[providerId], compile: null }
      return [providerId, Object.freeze({
        metadata: CANONICAL_PROVIDERS[providerId],
        syntaxes: implementation.syntaxes,
        compile: implementation.compile,
      })]
    }),
  )
}
