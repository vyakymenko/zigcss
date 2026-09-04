'use strict';

const core = require('./core.cjs');

module.exports = Object.freeze({
  createBunPlugin: core.createBunPlugin,
  createEsbuildPlugin: core.createEsbuildPlugin,
  createRollupPlugin: core.createRollupPlugin,
  createVitePlugin: core.createVitePlugin,
  ZigCssAdapterError: core.ZigCssAdapterError,
});
