'use strict';

const { fileURLToPath } = require('node:url');
const ThrowableDiagnostic = require('@parcel/diagnostic').default;
const { escapeMarkdown } = require('@parcel/diagnostic');
const { Transformer } = require('@parcel/plugin');
const ParcelSourceMap = require('@parcel/source-map').default;
const {
  compileSourceAsset,
  createScheduler,
  normalizeOptions,
} = require('../../adapters/core.cjs');

const compilerOptions = normalizeOptions({
  format: 'pretty',
  sourceMap: true,
});
const scheduler = createScheduler(compilerOptions.maxWorkers);

function sourceFile(value) {
  if (typeof value !== 'string' || !value.startsWith('file:')) return null;
  try {
    return fileURLToPath(value);
  } catch {
    return null;
  }
}

function parcelDiagnostic(diagnostic, asset, source) {
  const code = typeof diagnostic?.code === 'string' ? diagnostic.code : 'ZIGCSS';
  const message = typeof diagnostic?.message === 'string'
    ? diagnostic.message
    : 'stylesheet compilation failed';
  const result = {
    message: `[${escapeMarkdown(code)}] ${escapeMarkdown(message)}`,
  };

  const filePath = sourceFile(diagnostic?.sourceUrl);
  const line = diagnostic?.line;
  const zeroBasedColumn = diagnostic?.column;
  if (
    filePath !== null &&
    Number.isSafeInteger(line) && line >= 1 &&
    Number.isSafeInteger(zeroBasedColumn) && zeroBasedColumn >= 0
  ) {
    const location = { line, column: zeroBasedColumn + 1 };
    const frame = {
      filePath,
      codeHighlights: [{ start: location, end: location }],
    };
    if (filePath === asset.filePath) frame.code = source;
    result.codeFrames = [frame];
  }
  return result;
}

module.exports = new Transformer({
  async transform({ asset, logger, options }) {
    const source = await asset.getCode();
    let result;
    try {
      result = await compileSourceAsset(source, asset.filePath, compilerOptions, scheduler);
    } catch (error) {
      const diagnostics = Array.isArray(error?.diagnostics) && error.diagnostics.length > 0
        ? error.diagnostics.map(diagnostic => parcelDiagnostic(diagnostic, asset, source))
        : [{ message: escapeMarkdown(error instanceof Error ? error.message : String(error)) }];
      throw new ThrowableDiagnostic({ diagnostic: diagnostics });
    }

    for (const dependency of result.watchFiles.slice(1)) {
      asset.invalidateOnFileChange(dependency);
    }
    const warnings = result.diagnostics
      .filter(diagnostic => diagnostic.severity !== 'error')
      .map(diagnostic => parcelDiagnostic(diagnostic, asset, source));
    if (warnings.length > 0) logger.warn(warnings);

    asset.type = 'css';
    asset.setCode(result.code);
    if (result.map === null) {
      asset.setMap(null);
    } else {
      const sourceMap = new ParcelSourceMap(options.projectRoot);
      sourceMap.addVLQMap(result.map);
      asset.setMap(sourceMap);
    }
    return [asset];
  },
});
