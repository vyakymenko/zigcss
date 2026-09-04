'use strict'

const path = require('node:path')

const webpackEntry = path.join(__dirname, 'app', 'styles.scss')

module.exports = {
  productionBrowserSourceMaps: true,
  experimental: {
    turbopackFileSystemCacheForBuild: true,
    turbopackUseBuiltinSass: false,
  },
  turbopack: {
    root: __dirname,
    rules: {
      '*.scss': {
        condition: { path: /(?:^|[\\/])app[\\/]styles\.scss$/ },
        loaders: [{
          loader: 'zigcss/webpack',
          options: {
            maxWorkers: 2,
            sourceMap: true,
          },
        }],
        type: 'css',
      },
    },
  },
  webpack(config) {
    config.module.rules.push({
      test(resource) {
        return typeof resource === 'string' && path.resolve(resource) === webpackEntry
      },
      enforce: 'pre',
      use: [{
        loader: 'zigcss/webpack',
        options: {
          maxWorkers: 2,
          sourceMap: true,
        },
      }],
    })
    return config
  },
}
