'use strict';

const { createEsbuildPlugin } = require('./core.cjs');

module.exports = createEsbuildPlugin;
module.exports.zigcss = createEsbuildPlugin;
