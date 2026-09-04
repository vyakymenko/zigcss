'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const { fileURLToPath } = require('node:url');
const api = require('../api.cjs');

const MAX_QUEUE = 4096;
const MAX_VIRTUAL_MODULES = 16384;
const MAX_ID_BYTES = 8192;
const MAX_PATH_BYTES = 4096;
const MAX_BROWSERS_BYTES = 4096;
const MAX_WORKERS = 32;
const MAX_DIAGNOSTIC_SOURCE_BYTES = 10 * 1024 * 1024;
const STYLE_FILTER = /\.(?:css|scss|sass|less|styl|stylus)$/i;
const MODULE_STYLE_FILTER = /\.module\.(?:css|scss|sass|less|styl|stylus)$/i;
const allowedOptionNames = new Set([
  'format',
  'sourceMap',
  'optimize',
  'browsers',
  'rootPaths',
  'timeoutMs',
  'maxWorkers',
]);
const fatalUtf8 = new TextDecoder('utf-8', { fatal: true });

class ZigCssAdapterError extends Error {
  constructor(code, message, options = undefined) {
    super(message, options);
    this.name = 'ZigCssAdapterError';
    this.code = code;
  }
}

function adapterFailure(code, message, options = undefined) {
  throw new ZigCssAdapterError(code, message, options);
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isWellFormedUnicode(value) {
  return Buffer.from(value, 'utf8').toString('utf8') === value;
}

function canonicalRootPath(value, index) {
  if (typeof value !== 'string' || value.length === 0 ||
      !isWellFormedUnicode(value) || Buffer.byteLength(value) > MAX_PATH_BYTES || /[\0\r\n]/.test(value)) {
    adapterFailure('ADAPTER_OPTIONS', `rootPaths[${index}] must be a bounded local path`);
  }
  try {
    const canonical = fs.realpathSync.native(path.resolve(value));
    if (!fs.statSync(canonical).isDirectory()) throw new Error('not a directory');
    return canonical;
  } catch (error) {
    adapterFailure('ADAPTER_OPTIONS', `rootPaths[${index}] must identify an existing directory`, {
      cause: error,
    });
  }
}

function defaultWorkerCount() {
  const available = typeof os.availableParallelism === 'function'
    ? os.availableParallelism()
    : os.cpus().length;
  return Math.max(1, Math.min(8, available));
}

function normalizeOptions(value = undefined, defaults = undefined) {
  const options = value === undefined ? {} : value;
  if (!isPlainObject(options)) adapterFailure('ADAPTER_OPTIONS', 'adapter options must be an object');
  for (const key of Object.keys(options)) {
    if (!allowedOptionNames.has(key)) {
      adapterFailure('ADAPTER_OPTIONS', `unknown adapter option: ${key}`);
    }
  }

  const optimize = options.optimize ?? false;
  if (typeof optimize !== 'boolean') adapterFailure('ADAPTER_OPTIONS', 'optimize must be boolean');
  const sourceMap = options.sourceMap ?? defaults?.sourceMap ?? !optimize;
  if (typeof sourceMap !== 'boolean') adapterFailure('ADAPTER_OPTIONS', 'sourceMap must be boolean');
  if (sourceMap && optimize) {
    adapterFailure('ADAPTER_OPTIONS', 'sourceMap cannot be combined with fixed-point optimization');
  }

  const format = options.format ?? 'pretty';
  if (format !== 'pretty' && format !== 'minified') {
    adapterFailure('ADAPTER_OPTIONS', 'format must be pretty or minified');
  }
  const browsers = options.browsers ?? null;
  if (browsers !== null && (
    typeof browsers !== 'string' || browsers.length === 0 ||
    !isWellFormedUnicode(browsers) || Buffer.byteLength(browsers) > MAX_BROWSERS_BYTES
  )) {
    adapterFailure('ADAPTER_OPTIONS', 'browsers must be null or a non-empty bounded target query');
  }
  const timeoutMs = options.timeoutMs ?? 30_000;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000) {
    adapterFailure('ADAPTER_OPTIONS', 'timeoutMs must be an integer from 1 through 120000');
  }
  const maxWorkers = options.maxWorkers ?? defaultWorkerCount();
  if (!Number.isSafeInteger(maxWorkers) || maxWorkers < 1 || maxWorkers > MAX_WORKERS) {
    adapterFailure('ADAPTER_OPTIONS', `maxWorkers must be an integer from 1 through ${MAX_WORKERS}`);
  }

  let rootPaths;
  if (options.rootPaths !== undefined) {
    if (!Array.isArray(options.rootPaths) || options.rootPaths.length < 1 || options.rootPaths.length > 16) {
      adapterFailure('ADAPTER_OPTIONS', 'rootPaths must contain from 1 through 16 paths');
    }
    rootPaths = options.rootPaths.map(canonicalRootPath);
    if (new Set(rootPaths).size !== rootPaths.length) {
      adapterFailure('ADAPTER_OPTIONS', 'rootPaths must be unique after resolution');
    }
    rootPaths = Object.freeze(rootPaths);
  }

  return Object.freeze({
    format,
    sourceMap,
    optimize,
    browsers,
    rootPaths,
    timeoutMs,
    maxWorkers,
  });
}

function createScheduler(maxWorkers) {
  let active = 0;
  const queue = [];

  const pump = () => {
    while (active < maxWorkers && queue.length > 0) {
      const item = queue.shift();
      active += 1;
      Promise.resolve()
        .then(item.task)
        .then(item.resolve, item.reject)
        .finally(() => {
          active -= 1;
          pump();
        });
    }
  };

  return Object.freeze({
    run(task) {
      if (typeof task !== 'function') adapterFailure('ADAPTER_INTERNAL', 'scheduled task must be a function');
      if (queue.length >= MAX_QUEUE) {
        return Promise.reject(new ZigCssAdapterError(
          'ADAPTER_QUEUE_LIMIT',
          `adapter queue exceeds ${MAX_QUEUE} pending stylesheets`,
        ));
      }
      return new Promise((resolve, reject) => {
        queue.push({ task, resolve, reject });
        pump();
      });
    },
  });
}

function splitId(id) {
  if (typeof id !== 'string' || id.length === 0 || Buffer.byteLength(id) > MAX_ID_BYTES) return null;
  let boundary = id.length;
  for (const delimiter of ['?', '#']) {
    const index = id.indexOf(delimiter);
    if (index !== -1) boundary = Math.min(boundary, index);
  }
  return { clean: id.slice(0, boundary), suffix: id.slice(boundary) };
}

function isSupportedPath(filename) {
  return typeof filename === 'string' && STYLE_FILTER.test(filename);
}

function isModulePath(filename) {
  return typeof filename === 'string' && MODULE_STYLE_FILTER.test(filename);
}

function physicalPath(value) {
  const parts = splitId(value);
  if (parts === null || parts.clean.includes('\0')) return null;
  let filename = parts.clean;
  if (filename.startsWith('file:')) {
    try {
      filename = fileURLToPath(filename);
    } catch {
      return null;
    }
  } else if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(filename) && !path.win32.isAbsolute(filename)) {
    return null;
  }
  if (!path.isAbsolute(filename) || !isSupportedPath(filename)) return null;
  return { filename, suffix: parts.suffix };
}

function canonicalInputPath(filename) {
  try {
    const canonical = fs.realpathSync.native(filename);
    const stat = fs.statSync(canonical);
    if (!stat.isFile()) adapterFailure('ADAPTER_INPUT', 'stylesheet input must be a regular file');
    return canonical;
  } catch (error) {
    if (error instanceof ZigCssAdapterError) throw error;
    adapterFailure('ADAPTER_INPUT', `stylesheet input is unavailable: ${filename}`, { cause: error });
  }
}

function canonicalLogicalPath(filename) {
  if (typeof filename !== 'string' || filename.length === 0) {
    adapterFailure('ADAPTER_INPUT', 'stylesheet filename must be a non-empty path');
  }
  const resolved = path.resolve(filename);
  try {
    return fs.realpathSync.native(resolved);
  } catch {
    try {
      return path.join(fs.realpathSync.native(path.dirname(resolved)), path.basename(resolved));
    } catch (error) {
      adapterFailure('ADAPTER_INPUT', `stylesheet parent is unavailable: ${filename}`, { cause: error });
    }
  }
}

function compileOptions(options, extra = undefined) {
  const value = {
    format: options.format,
    sourceMap: options.sourceMap,
    optimize: options.optimize,
    browsers: options.browsers,
    timeoutMs: options.timeoutMs,
    ...extra,
  };
  if (options.rootPaths !== undefined) value.rootPaths = options.rootPaths;
  return value;
}

function compareBytes(left, right) {
  return Buffer.from(left).compare(Buffer.from(right));
}

function dependencyPath(dependency) {
  if (!dependency || typeof dependency !== 'object' || typeof dependency.url !== 'string') return null;
  if (!['import', 'use', 'forward', 'reference'].includes(dependency.kind)) return null;
  try {
    const filename = fileURLToPath(dependency.url);
    return path.isAbsolute(filename) ? filename : null;
  } catch {
    return null;
  }
}

function watchFilesFor(entry, dependencies) {
  const found = new Set();
  for (const dependency of dependencies) {
    const filename = dependencyPath(dependency);
    if (filename !== null && filename !== entry) found.add(filename);
  }
  return Object.freeze([entry, ...[...found].sort(compareBytes)]);
}

function mutableSourceMapForHost(sourceMap) {
  // The public Node API deliberately returns deeply frozen snapshots. Build
  // hosts are different: Vite 8/Rolldown, Rollup, Webpack, and Rspack may
  // normalize a loader/plugin source map in place. Never hand those hosts the
  // API-owned object; give every compilation its own mutable structured clone.
  return sourceMap === null ? null : structuredClone(sourceMap);
}

function adaptResult(entry, result) {
  return Object.freeze({
    code: result.css,
    map: mutableSourceMapForHost(result.sourceMap),
    diagnostics: result.diagnostics,
    dependencies: result.dependencies,
    watchFiles: watchFilesFor(entry, result.dependencies),
  });
}

async function compileFileAsset(filename, options, scheduler) {
  const entry = canonicalInputPath(filename);
  const result = await scheduler.run(() => api.compileFile(entry, compileOptions(options)));
  return adaptResult(entry, result);
}

function decodeSource(value) {
  if (typeof value === 'string') return value;
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
    try {
      return fatalUtf8.decode(value);
    } catch (error) {
      adapterFailure('ADAPTER_INPUT_ENCODING', 'stylesheet input is not valid UTF-8', { cause: error });
    }
  }
  adapterFailure('ADAPTER_INPUT', 'stylesheet input must be a string or byte buffer');
}

async function compileSourceAsset(source, filename, options, scheduler) {
  const entry = canonicalLogicalPath(filename);
  const result = await scheduler.run(() => api.compile(decodeSource(source), compileOptions(options, {
    sourcePath: entry,
  })));
  return adaptResult(entry, result);
}

function sourceFileFromUrl(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  let filename;
  if (value.startsWith('file:')) {
    try {
      filename = fileURLToPath(value);
    } catch {
      return null;
    }
  } else {
    filename = path.isAbsolute(value) ? value : null;
  }
  if (
    filename === null || !path.isAbsolute(filename) || !isWellFormedUnicode(filename) ||
    Buffer.byteLength(filename) > MAX_PATH_BYTES || /[\0\r\n]/.test(filename)
  ) return null;
  return filename;
}

function sameDiagnosticFile(left, right) {
  return (
    left.isFile() && right.isFile() &&
    !left.isSymbolicLink() && !right.isSymbolicLink() &&
    left.dev === right.dev &&
    left.ino === right.ino &&
    left.size === right.size &&
    left.mtimeNs === right.mtimeNs &&
    left.ctimeNs === right.ctimeNs
  );
}

function readDiagnosticSource(filename) {
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY |
      (fs.constants.O_NOFOLLOW ?? 0) |
      (fs.constants.O_NONBLOCK ?? 0) |
      (fs.constants.O_CLOEXEC ?? 0);
    descriptor = fs.openSync(filename, flags);

    const before = fs.fstatSync(descriptor, { bigint: true });
    const openedPathStat = fs.lstatSync(filename, { bigint: true });
    if (
      !sameDiagnosticFile(before, openedPathStat) ||
      before.size > BigInt(MAX_DIAGNOSTIC_SOURCE_BYTES)
    ) return null;

    const chunks = [];
    const buffer = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_DIAGNOSTIC_SOURCE_BYTES + 1));
    let total = 0;
    while (true) {
      const remaining = MAX_DIAGNOSTIC_SOURCE_BYTES + 1 - total;
      if (remaining <= 0) return null;
      const bytesRead = fs.readSync(
        descriptor,
        buffer,
        0,
        Math.min(buffer.length, remaining),
        total,
      );
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > MAX_DIAGNOSTIC_SOURCE_BYTES) return null;
      chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    }

    const after = fs.fstatSync(descriptor, { bigint: true });
    const finalPathStat = fs.lstatSync(filename, { bigint: true });
    if (
      !sameDiagnosticFile(before, after) ||
      !sameDiagnosticFile(after, finalPathStat) ||
      BigInt(total) !== before.size
    ) return null;

    try {
      return fatalUtf8.decode(Buffer.concat(chunks, total));
    } catch {
      return null;
    }
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor);
      } catch {
        // A diagnostic location is optional; never replace the compiler result
        // with a cleanup failure.
      }
    }
  }
}

function lineAt(filename, lineNumber, sourceOverride = undefined, sourceOverridePath = undefined) {
  if (!Number.isSafeInteger(lineNumber) || lineNumber < 1) return null;
  let source;
  if (sourceOverride !== undefined && (sourceOverridePath === undefined || sourceOverridePath === filename)) {
    source = sourceOverride;
  } else {
    source = readDiagnosticSource(filename);
    if (source === null) return null;
  }
  const lines = source.split(/\r\n|\n|\r/);
  return lines[lineNumber - 1] ?? null;
}

function validUtf16Column(lineText, column) {
  if (!Number.isSafeInteger(column) || column < 0 || column > lineText.length) return null;
  if (column > 0 && column < lineText.length) {
    const current = lineText.charCodeAt(column);
    const previous = lineText.charCodeAt(column - 1);
    if (current >= 0xdc00 && current <= 0xdfff && previous >= 0xd800 && previous <= 0xdbff) return null;
  }
  return column;
}

function diagnosticColumn(lineText, column, units) {
  const utf16Column = validUtf16Column(lineText, column);
  if (utf16Column === null) return null;
  return units === 'utf16'
    ? utf16Column
    : Buffer.byteLength(lineText.slice(0, utf16Column));
}

function hostDiagnostic(
  diagnostic,
  sourceOverride = undefined,
  sourceOverridePath = undefined,
  columnUnits = 'utf8',
) {
  const filename = sourceFileFromUrl(diagnostic?.sourceUrl);
  const line = diagnostic?.line;
  const column = diagnostic?.column;
  let location = null;
  if (filename !== null) {
    const lineText = lineAt(filename, line, sourceOverride, sourceOverridePath);
    if (lineText !== null) {
      const hostColumn = diagnosticColumn(lineText, column, columnUnits);
      if (hostColumn !== null) {
        location = { file: filename, line, column: hostColumn, lineText };
      }
    }
  }
  return {
    text: `[${diagnostic?.code ?? 'ZIGCSS'}] ${diagnostic?.message ?? 'stylesheet compilation failed'}`,
    location,
    detail: diagnostic,
  };
}

function compilerMessages(
  error,
  sourceOverride = undefined,
  sourceOverridePath = undefined,
  columnUnits = 'utf8',
) {
  if (error && Array.isArray(error.diagnostics) && error.diagnostics.length > 0) {
    return error.diagnostics.map(diagnostic => (
      hostDiagnostic(diagnostic, sourceOverride, sourceOverridePath, columnUnits)
    ));
  }
  return [{ text: error instanceof Error ? error.message : String(error), location: null, detail: error }];
}

function warningMessages(
  diagnostics,
  sourceOverride = undefined,
  sourceOverridePath = undefined,
  columnUnits = 'utf8',
) {
  return diagnostics
    .filter(diagnostic => diagnostic.severity !== 'error')
    .map(diagnostic => hostDiagnostic(
      diagnostic,
      sourceOverride,
      sourceOverridePath,
      columnUnits,
    ));
}

function inlineSourceMap(code, map) {
  if (map === null) return code;
  const encoded = Buffer.from(JSON.stringify(map), 'utf8').toString('base64');
  return `${code}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,${encoded} */\n`;
}

function virtualModuleId(filename, moduleMode) {
  const digest = crypto.createHash('sha256').update(filename).digest('hex');
  const basename = `\0zigcss-${digest}${moduleMode ? '.module.css' : '.css'}`;
  return path.join(path.dirname(filename), basename);
}

function rollupLog(message) {
  const value = { message: message.text };
  if (message.location !== null) {
    value.id = message.location.file;
    value.loc = { line: message.location.line, column: message.location.column };
  }
  return value;
}

function createRollupLikePlugin(kind, value) {
  const options = normalizeOptions(value);
  const scheduler = createScheduler(options.maxWorkers);
  const originals = new Map();

  const plugin = {
    name: `zigcss:${kind}`,
    async resolveId(source, importer, hookOptions) {
      const sourceParts = splitId(source);
      if (sourceParts === null) return null;
      if (originals.has(sourceParts.clean)) return source;
      if (!isSupportedPath(sourceParts.clean) || sourceParts.clean.includes('\0')) return null;
      if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(sourceParts.clean)
          && !sourceParts.clean.startsWith('file:')
          && !path.win32.isAbsolute(sourceParts.clean)) return null;
      if (typeof this.resolve !== 'function') {
        adapterFailure('ADAPTER_HOST', `${kind} plugin context does not expose resolve()`);
      }
      const resolved = await this.resolve(sourceParts.clean, importer, {
        ...(hookOptions ?? {}),
        skipSelf: true,
      });
      if (resolved === null || resolved === undefined || resolved.external === true) return null;
      const resolvedId = typeof resolved === 'string' ? resolved : resolved.id;
      const physical = physicalPath(resolvedId);
      if (physical === null) return null;
      const generated = virtualModuleId(physical.filename, isModulePath(physical.filename));
      const previous = originals.get(generated);
      if (previous !== undefined && previous !== physical.filename) {
        adapterFailure('ADAPTER_INTERNAL', 'virtual stylesheet identity collision');
      }
      if (previous === undefined && originals.size >= MAX_VIRTUAL_MODULES) {
        adapterFailure('ADAPTER_MODULE_LIMIT', `adapter exceeds ${MAX_VIRTUAL_MODULES} stylesheet modules`);
      }
      originals.set(generated, physical.filename);
      return { id: `${generated}${sourceParts.suffix || physical.suffix}`, moduleSideEffects: true };
    },
    async load(id) {
      const parts = splitId(id);
      if (parts === null) return null;
      const filename = originals.get(parts.clean);
      if (filename === undefined) return null;
      try {
        const result = await compileFileAsset(filename, options, scheduler);
        if (typeof this.addWatchFile === 'function') {
          for (const watchFile of result.watchFiles) this.addWatchFile(watchFile);
        }
        if (typeof this.warn === 'function') {
          for (const warning of warningMessages(
            result.diagnostics,
            undefined,
            undefined,
            'utf16',
          )) this.warn(rollupLog(warning));
        }
        return {
          code: result.code,
          map: result.map,
          moduleSideEffects: true,
        };
      } catch (error) {
        const first = compilerMessages(error, undefined, undefined, 'utf16')[0];
        if (typeof this.error === 'function') return this.error(rollupLog(first));
        throw error;
      }
    },
  };
  if (kind === 'vite') plugin.enforce = 'pre';
  return plugin;
}

function createVitePlugin(options) {
  return createRollupLikePlugin('vite', options);
}

function createRollupPlugin(options) {
  return createRollupLikePlugin('rollup', options);
}

function createEsbuildPlugin(value) {
  const options = normalizeOptions(value);
  const scheduler = createScheduler(options.maxWorkers);
  return {
    name: 'zigcss',
    setup(build) {
      if (!build || typeof build.onLoad !== 'function') {
        adapterFailure('ADAPTER_HOST', 'esbuild plugin requires an onLoad-capable build object');
      }
      build.onLoad({ filter: STYLE_FILTER, namespace: 'file' }, async args => {
        try {
          const result = await compileFileAsset(args.path, options, scheduler);
          return {
            contents: inlineSourceMap(result.code, result.map),
            loader: isModulePath(args.path) ? 'local-css' : 'css',
            resolveDir: path.dirname(args.path),
            watchFiles: result.watchFiles,
            warnings: warningMessages(result.diagnostics),
          };
        } catch (error) {
          return { errors: compilerMessages(error) };
        }
      });
    },
  };
}

function createBunPlugin(value) {
  const options = normalizeOptions(value);
  const scheduler = createScheduler(options.maxWorkers);
  return {
    name: 'zigcss',
    setup(build) {
      if (!build || typeof build.onLoad !== 'function') {
        adapterFailure('ADAPTER_HOST', 'Bun plugin requires an onLoad-capable build object');
      }
      build.onLoad({ filter: STYLE_FILTER, namespace: 'file' }, async args => {
        const result = await compileFileAsset(args.path, options, scheduler);
        return {
          contents: inlineSourceMap(result.code, result.map),
          loader: 'css',
        };
      });
    },
  };
}

const webpackSchedulers = new Map();

function webpackScheduler(maxWorkers) {
  let scheduler = webpackSchedulers.get(maxWorkers);
  if (scheduler === undefined) {
    scheduler = createScheduler(maxWorkers);
    webpackSchedulers.set(maxWorkers, scheduler);
  }
  return scheduler;
}

function webpackLoader(source, incomingMap) {
  if (!this || typeof this.async !== 'function') {
    adapterFailure('ADAPTER_HOST', 'Webpack/Rspack loader requires an async loader context');
  }
  const callback = this.async();
  if (typeof callback !== 'function') {
    adapterFailure('ADAPTER_HOST', 'Webpack/Rspack loader context did not return a callback');
  }
  if (incomingMap !== null && incomingMap !== undefined) {
    callback(new ZigCssAdapterError(
      'ADAPTER_INPUT_MAP',
      'incoming source maps are unsupported; place zigcss as the rightmost source loader',
    ));
    return;
  }

  let rawOptions = {};
  try {
    if (typeof this.getOptions === 'function') rawOptions = this.getOptions() ?? {};
    else if (isPlainObject(this.query)) rawOptions = this.query;
    if (rawOptions.sourceMap === undefined) {
      rawOptions = { ...rawOptions, sourceMap: this.sourceMap !== false };
    }
    const options = normalizeOptions(rawOptions);
    const filename = this.resourcePath;
    if (!isSupportedPath(filename)) {
      callback(new ZigCssAdapterError('ADAPTER_INPUT', 'loader resource has an unsupported stylesheet extension'));
      return;
    }
    if (typeof this.cacheable === 'function') this.cacheable(true);
    compileSourceAsset(source, filename, options, webpackScheduler(options.maxWorkers)).then(result => {
      if (typeof this.addDependency === 'function') {
        for (const watchFile of result.watchFiles.slice(1)) this.addDependency(watchFile);
      }
      if (typeof this.emitWarning === 'function') {
        for (const warning of warningMessages(
          result.diagnostics,
          decodeSource(source),
          result.watchFiles[0],
        )) {
          const emitted = new Error(warning.text);
          emitted.name = 'ZigCssWarning';
          this.emitWarning(emitted);
        }
      }
      callback(null, result.code, result.map, {
        zigcss: Object.freeze({
          dependencies: result.dependencies,
          diagnostics: result.diagnostics,
        }),
      });
    }, error => {
      const messages = compilerMessages(error, decodeSource(source), canonicalLogicalPath(filename));
      const failure = new Error(messages.map(message => message.text).join('\n'), { cause: error });
      failure.name = 'ZigCssLoaderError';
      failure.code = error?.code ?? 'ADAPTER_COMPILE';
      callback(failure);
    });
  } catch (error) {
    callback(error);
  }
}

webpackLoader.raw = true;

module.exports = Object.freeze({
  STYLE_FILTER,
  ZigCssAdapterError,
  compileFileAsset,
  compileSourceAsset,
  createBunPlugin,
  createEsbuildPlugin,
  createRollupPlugin,
  createScheduler,
  createVitePlugin,
  inlineSourceMap,
  isModulePath,
  isSupportedPath,
  normalizeOptions,
  splitId,
  webpackLoader,
});
