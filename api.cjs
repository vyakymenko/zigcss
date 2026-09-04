'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { TextDecoder } = require('node:util');

const PROTOCOL = 'zigcss-node-v1';
const INTERNAL_ARGUMENT = '--internal-node-v1';
const MAX_SOURCE_BYTES = 10 * 1024 * 1024;
const MAX_REQUEST_BYTES = 64 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 128 * 1024 * 1024;
const MAX_STDERR_BYTES = 4 * 1024 * 1024;
const MAX_SYNC_FRAME_BYTES = 4 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TIMEOUT_MS = 120_000;
const MAX_PATH_BYTES = 4096;
// Keep the JavaScript admission boundary identical to the native target-query
// parser so an oversized query is rejected before a child process is created.
const MAX_BROWSERS_BYTES = 4096;
const MAX_REQUEST_ID_BYTES = 64;

const supportedSyntaxes = Object.freeze(['css', 'scss', 'sass', 'less', 'stylus']);
const extensions = Object.freeze({
  '.css': 'css',
  '.scss': 'scss',
  '.sass': 'sass',
  '.less': 'less',
  '.styl': 'stylus',
  '.stylus': 'stylus',
});
const syntheticExtensions = Object.freeze({
  css: 'css',
  scss: 'scss',
  sass: 'sass',
  less: 'less',
  stylus: 'styl',
});
const allowedOptionNames = new Set([
  'syntax',
  'sourcePath',
  'rootPaths',
  'format',
  'sourceMap',
  'optimize',
  'browsers',
  'timeoutMs',
  'signal',
]);
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });
let requestSequence = 0;

class ZigCssCompileError extends Error {
  constructor(code, message, diagnostics = [], options = undefined) {
    super(message, options);
    this.name = 'ZigCssCompileError';
    this.code = code;
    this.diagnostics = cloneAndFreezeObjectArray(diagnostics, 'diagnostics');
  }
}

function fail(code, message, diagnostics = [], options = undefined) {
  throw new ZigCssCompileError(code, message, diagnostics, options);
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, expected, label) {
  if (!isPlainObject(value)) fail('API_PROTOCOL', `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail('API_PROTOCOL', `${label} has unexpected or missing fields`);
  }
}

function cloneJsonValue(value, label, depth = 0) {
  if (depth > 64) fail('API_PROTOCOL', `${label} exceeds the nesting limit`);
  if (value === null || typeof value === 'boolean') return value;
  if (typeof value === 'string') {
    if (!isWellFormedUtf8(value)) fail('API_PROTOCOL', `${label} is not well-formed Unicode`);
    return value;
  }
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (Array.isArray(value)) {
    return Object.freeze(value.map((item, index) => cloneJsonValue(item, `${label}[${index}]`, depth + 1)));
  }
  if (!isPlainObject(value)) fail('API_PROTOCOL', `${label} is not JSON-safe`);
  const clone = {};
  for (const [key, item] of Object.entries(value)) {
    Object.defineProperty(clone, key, {
      value: cloneJsonValue(item, `${label}.${key}`, depth + 1),
      enumerable: true,
      configurable: false,
      writable: false,
    });
  }
  return Object.freeze(clone);
}

function cloneAndFreezeObjectArray(value, label) {
  if (!Array.isArray(value)) fail('API_PROTOCOL', `${label} must be an array`);
  return Object.freeze(value.map((entry, index) => {
    if (!isPlainObject(entry)) fail('API_PROTOCOL', `${label}[${index}] must be an object`);
    return cloneJsonValue(entry, `${label}[${index}]`);
  }));
}

function isProtocolString(value, { nonEmpty = false } = {}) {
  return typeof value === 'string' &&
    (!nonEmpty || value.length !== 0) &&
    isWellFormedUtf8(value);
}

function validateDiagnostics(value, label) {
  if (!Array.isArray(value)) fail('API_PROTOCOL', `${label} must be an array`);
  for (const [index, diagnostic] of value.entries()) {
    const itemLabel = `${label}[${index}]`;
    if (!isPlainObject(diagnostic)) fail('API_PROTOCOL', `${itemLabel} must be an object`);
    for (const field of ['severity', 'code', 'message', 'sourceUrl', 'line', 'column']) {
      if (!Object.hasOwn(diagnostic, field)) {
        fail('API_PROTOCOL', `${itemLabel} is missing ${field}`);
      }
    }
    if (!['error', 'warning', 'note'].includes(diagnostic.severity)) {
      fail('API_PROTOCOL', `${itemLabel}.severity is invalid`);
    }
    if (!isProtocolString(diagnostic.code, { nonEmpty: true }) ||
        !/^[A-Z][A-Z0-9_]{1,63}$/.test(diagnostic.code)) {
      fail('API_PROTOCOL', `${itemLabel}.code is invalid`);
    }
    if (!isProtocolString(diagnostic.message, { nonEmpty: true })) {
      fail('API_PROTOCOL', `${itemLabel}.message is invalid`);
    }
    if (!isProtocolString(diagnostic.sourceUrl, { nonEmpty: true })) {
      fail('API_PROTOCOL', `${itemLabel}.sourceUrl is invalid`);
    }
    if (!Number.isSafeInteger(diagnostic.line) || diagnostic.line < 1 ||
        !Number.isSafeInteger(diagnostic.column) || diagnostic.column < 0) {
      fail('API_PROTOCOL', `${itemLabel} location is invalid`);
    }
  }
  return cloneAndFreezeObjectArray(value, label);
}

function validateDependencies(value) {
  const label = 'result.dependencies';
  if (!Array.isArray(value)) fail('API_PROTOCOL', `${label} must be an array`);
  for (const [index, dependency] of value.entries()) {
    const itemLabel = `${label}[${index}]`;
    if (!isPlainObject(dependency)) fail('API_PROTOCOL', `${itemLabel} must be an object`);
    if (dependency.kind === 'css-import' || dependency.kind === 'css-module') {
      exactKeys(dependency, ['kind', 'specifier', 'sourceUrl', 'start', 'end'], itemLabel);
      if (!isProtocolString(dependency.specifier, { nonEmpty: true }) ||
          !isProtocolString(dependency.sourceUrl, { nonEmpty: true })) {
        fail('API_PROTOCOL', `${itemLabel} paths are invalid`);
      }
      if (!Number.isSafeInteger(dependency.start) || dependency.start < 0 ||
          !Number.isSafeInteger(dependency.end) || dependency.end < dependency.start) {
        fail('API_PROTOCOL', `${itemLabel} span is invalid`);
      }
    } else if (['import', 'use', 'forward', 'reference'].includes(dependency.kind)) {
      exactKeys(dependency, ['kind', 'url'], itemLabel);
      if (!isProtocolString(dependency.url, { nonEmpty: true })) {
        fail('API_PROTOCOL', `${itemLabel}.url is invalid`);
      }
    } else {
      fail('API_PROTOCOL', `${itemLabel}.kind is invalid`);
    }
  }
  return cloneAndFreezeObjectArray(value, label);
}

function validateSourceMapShape(value) {
  if (
    !isPlainObject(value) ||
    value.version !== 3 ||
    !Array.isArray(value.sources) ||
    !value.sources.every(item => typeof item === 'string') ||
    !Array.isArray(value.names) ||
    !value.names.every(item => typeof item === 'string') ||
    typeof value.mappings !== 'string'
  ) {
    fail('API_PROTOCOL', 'result.sourceMap is not a Source Map v3 object');
  }
  if (value.file !== undefined && typeof value.file !== 'string') {
    fail('API_PROTOCOL', 'result.sourceMap.file must be a string');
  }
  if (value.sourceRoot !== undefined && typeof value.sourceRoot !== 'string') {
    fail('API_PROTOCOL', 'result.sourceMap.sourceRoot must be a string');
  }
  if (
    value.sourcesContent !== undefined &&
    (
      !Array.isArray(value.sourcesContent) ||
      value.sourcesContent.length !== value.sources.length ||
      !value.sourcesContent.every(item => item === null || typeof item === 'string')
    )
  ) {
    fail('API_PROTOCOL', 'result.sourceMap.sourcesContent must align with sources');
  }
}

function apiOptionsFailure(message) {
  fail('API_OPTIONS', message);
}

function isWellFormedUtf8(value) {
  return Buffer.from(value, 'utf8').toString('utf8') === value;
}

function validateBoundedPath(value, label) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    !isWellFormedUtf8(value) ||
    Buffer.byteLength(value) > MAX_PATH_BYTES ||
    /[\0\r\n]/.test(value)
  ) {
    apiOptionsFailure(`${label} must be a bounded local path`);
  }
  const resolved = path.resolve(value);
  if (process.platform === 'win32' && !/^[A-Za-z]:[\\/]/.test(resolved)) {
    apiOptionsFailure(`${label} must resolve to a drive-local path`);
  }
  return resolved;
}

function canonicalDirectory(value, label) {
  const resolved = validateBoundedPath(value, label);
  let canonical;
  try {
    canonical = fs.realpathSync.native(resolved);
    if (!fs.statSync(canonical).isDirectory()) {
      apiOptionsFailure(`${label} must identify an existing directory`);
    }
  } catch (error) {
    if (error instanceof ZigCssCompileError) throw error;
    apiOptionsFailure(`${label} must identify an existing directory`);
  }
  return validateBoundedPath(canonical, label);
}

function canonicalSourcePath(value, label) {
  const resolved = validateBoundedPath(value, label);
  const parent = canonicalDirectory(path.dirname(resolved), `${label} parent`);
  return validateBoundedPath(path.join(parent, path.basename(resolved)), label);
}

function canonicalInputFile(value) {
  const resolved = validateBoundedPath(value, 'filename');
  try {
    const canonical = validateBoundedPath(fs.realpathSync.native(resolved), 'filename');
    const stat = fs.lstatSync(canonical, { bigint: true });
    if (!stat.isFile() || stat.isSymbolicLink()) {
      fail('API_INPUT', 'filename must identify a regular file');
    }
    return Object.freeze({
      filename: canonical,
      device: stat.dev,
      inode: stat.ino,
    });
  } catch (error) {
    if (error instanceof ZigCssCompileError) throw error;
    fail('API_INPUT', `source file could not be resolved: ${error.message}`, [], { cause: error });
  }
}

function inputOpenFlags() {
  return fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0);
}

function validateOpenedInput(expected, stat, label) {
  if (!stat.isFile() || stat.isSymbolicLink() ||
      stat.dev !== expected.device || stat.ino !== expected.inode) {
    fail('API_INPUT', `${label} changed before it could be read safely`);
  }
  if (stat.size < 0n || stat.size > BigInt(MAX_SOURCE_BYTES)) {
    fail('API_INPUT', 'source exceeds the 10 MiB limit');
  }
}

function validateStableInput(before, after, bytesRead, label) {
  if (
    !after.isFile() ||
    after.dev !== before.dev ||
    after.ino !== before.ino ||
    after.size !== before.size ||
    after.mtimeNs !== before.mtimeNs ||
    after.ctimeNs !== before.ctimeNs ||
    BigInt(bytesRead) !== before.size
  ) {
    fail('API_INPUT', `${label} changed while it was being read`);
  }
}

function containsLocalPath(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}

function detectSyntax(filename) {
  if (
    typeof filename !== 'string' ||
    filename.length === 0 ||
    !isWellFormedUtf8(filename) ||
    /[\0\r\n]/.test(filename)
  ) {
    apiOptionsFailure('filename must be a local path with a supported extension');
  }
  const syntax = extensions[path.extname(filename).toLowerCase()];
  if (syntax === undefined) {
    apiOptionsFailure('filename must end in .css, .scss, .sass, .less, .styl, or .stylus');
  }
  return syntax;
}

function normalizeSignal(value, asyncMode) {
  if (value === undefined) return undefined;
  if (!asyncMode) apiOptionsFailure('signal is only available for asynchronous compilation');
  if (typeof AbortSignal === 'undefined' || !(value instanceof AbortSignal)) {
    apiOptionsFailure('signal must be an AbortSignal');
  }
  return value;
}

function normalizeOptions(optionValue, sourcePathOverride, asyncMode, inferRequired = false) {
  const options = optionValue === undefined ? {} : optionValue;
  if (!isPlainObject(options)) apiOptionsFailure('compile options must be an object');
  for (const key of Object.keys(options)) {
    if (!allowedOptionNames.has(key)) apiOptionsFailure(`unknown compile option: ${key}`);
  }
  if (sourcePathOverride !== undefined && options.sourcePath !== undefined) {
    apiOptionsFailure('compileFile does not accept sourcePath');
  }

  let syntax = options.syntax;
  if (syntax !== undefined && !supportedSyntaxes.includes(syntax)) {
    apiOptionsFailure(`unsupported syntax: ${String(syntax)}`);
  }

  let sourcePath;
  if (sourcePathOverride !== undefined) {
    sourcePath = canonicalSourcePath(sourcePathOverride, 'filename');
  } else if (options.sourcePath !== undefined) {
    sourcePath = canonicalSourcePath(options.sourcePath, 'sourcePath');
  }
  if (syntax === undefined && sourcePath !== undefined) syntax = detectSyntax(sourcePath);
  if (syntax === undefined) {
    if (inferRequired) apiOptionsFailure('syntax could not be inferred from the filename');
    syntax = 'css';
  }
  if (sourcePath === undefined) {
    sourcePath = canonicalSourcePath(
      path.resolve(process.cwd(), `.zigcss-input.${syntheticExtensions[syntax]}`),
      'sourcePath',
    );
  }

  const format = options.format ?? 'pretty';
  if (format !== 'pretty' && format !== 'minified') {
    apiOptionsFailure('format must be pretty or minified');
  }
  const sourceMap = options.sourceMap ?? false;
  const optimize = options.optimize ?? false;
  if (typeof sourceMap !== 'boolean' || typeof optimize !== 'boolean') {
    apiOptionsFailure('sourceMap and optimize must be boolean');
  }
  if (sourceMap && optimize) {
    apiOptionsFailure('source maps are unavailable with fixed-point optimization');
  }

  let browsers = options.browsers ?? null;
  if (
    browsers !== null &&
    (
      typeof browsers !== 'string' ||
      browsers.length === 0 ||
      !isWellFormedUtf8(browsers) ||
      Buffer.byteLength(browsers) > MAX_BROWSERS_BYTES
    )
  ) {
    apiOptionsFailure('browsers must be null or a non-empty bounded target query');
  }

  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > MAX_TIMEOUT_MS) {
    apiOptionsFailure(`timeoutMs must be an integer from 1 through ${MAX_TIMEOUT_MS}`);
  }
  const signal = normalizeSignal(options.signal, asyncMode);

  let rootPaths;
  if (options.rootPaths === undefined) {
    rootPaths = [path.dirname(sourcePath)];
  } else {
    if (!Array.isArray(options.rootPaths) || options.rootPaths.length < 1 || options.rootPaths.length > 16) {
      apiOptionsFailure('rootPaths must contain from 1 through 16 local paths');
    }
    rootPaths = Array.from(options.rootPaths, (rootPath, index) => (
      canonicalDirectory(rootPath, `rootPaths[${index}]`)
    ));
    if (new Set(rootPaths).size !== rootPaths.length) {
      apiOptionsFailure('rootPaths must be unique after resolution');
    }
  }
  if (!rootPaths.some(rootPath => containsLocalPath(rootPath, sourcePath))) {
    apiOptionsFailure('sourcePath must be contained by at least one rootPaths directory');
  }

  return Object.freeze({
    syntax,
    sourcePath,
    rootPaths: Object.freeze(rootPaths),
    format,
    sourceMap,
    optimize,
    browsers,
    timeoutMs,
    signal,
  });
}

function validateSource(source) {
  if (typeof source !== 'string') fail('API_INPUT', 'source must be a string');
  if (!isWellFormedUtf8(source)) fail('API_INPUT_ENCODING', 'source is not well-formed Unicode');
  if (Buffer.byteLength(source) > MAX_SOURCE_BYTES) {
    fail('API_INPUT', 'source exceeds the 10 MiB limit');
  }
  return source;
}

function nextRequestId() {
  requestSequence = (requestSequence + 1) % 0x1_0000_0000;
  const value = `node-${process.pid}-${Date.now().toString(36)}-${requestSequence.toString(36)}`;
  if (Buffer.byteLength(value) > MAX_REQUEST_ID_BYTES) fail('API_INTERNAL', 'request identifier overflow');
  return value;
}

function buildFrame(source, options) {
  const requestId = nextRequestId();
  const request = {
    protocol: PROTOCOL,
    requestId,
    operation: 'compile',
    source,
    sourcePath: options.sourcePath,
    rootPaths: options.rootPaths,
    options: {
      syntax: options.syntax,
      format: options.format,
      sourceMap: options.sourceMap,
      optimize: options.optimize,
      browsers: options.browsers,
    },
  };
  let body;
  try {
    body = Buffer.from(JSON.stringify(request), 'utf8');
  } catch (error) {
    fail('API_INPUT', 'request could not be encoded as JSON', [], { cause: error });
  }
  if (body.length === 0 || body.length > MAX_REQUEST_BYTES) {
    fail('API_INPUT', 'encoded request exceeds the 64 MiB limit');
  }
  const frame = Buffer.allocUnsafe(body.length + 4);
  frame.writeUInt32BE(body.length, 0);
  body.copy(frame, 4);
  return Object.freeze({ frame, requestId });
}

function regularExecutable(filename) {
  try {
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink() ||
        (process.platform !== 'win32' && (stat.mode & 0o111) === 0)) {
      return null;
    }
    return fs.realpathSync(filename);
  } catch {
    return null;
  }
}

function sourceCheckoutBinary(binaryName) {
  let root;
  try {
    root = fs.realpathSync(__dirname);
  } catch {
    return null;
  }
  for (const marker of ['build.zig', path.join('src', 'node_protocol.zig')]) {
    try {
      const stat = fs.lstatSync(path.join(root, marker));
      if (!stat.isFile() || stat.isSymbolicLink()) return null;
    } catch {
      return null;
    }
  }
  const candidate = regularExecutable(path.join(root, 'zig-out', 'bin', binaryName));
  return candidate !== null && containsLocalPath(root, candidate) ? candidate : null;
}

function binaryPath() {
  const binaryName = process.platform === 'win32' ? 'zigcss.exe' : 'zigcss';
  const sourceBinary = sourceCheckoutBinary(binaryName);
  if (sourceBinary !== null) return sourceBinary;
  let packageRoot;
  try {
    packageRoot = fs.realpathSync(__dirname);
  } catch {
    packageRoot = null;
  }
  const packagedBinary = packageRoot === null
    ? null
    : regularExecutable(path.join(packageRoot, 'bin', binaryName));
  if (
    packagedBinary === null ||
    packageRoot === null ||
    !containsLocalPath(packageRoot, packagedBinary)
  ) {
    fail(
      'API_BINARY_NOT_FOUND',
      'zigcss binary is missing or not executable; run zigcss-install, allow the package install script, or build this source checkout',
    );
  }
  return packagedBinary;
}

function decodeUtf8(buffer, label) {
  try {
    return utf8Decoder.decode(buffer);
  } catch (error) {
    fail('API_PROTOCOL', `${label} is not valid UTF-8`, [], { cause: error });
  }
}

function decodeResponse(frame, requestId) {
  if (!Buffer.isBuffer(frame) || frame.length < 4) {
    fail('API_PROTOCOL', 'response frame is truncated');
  }
  const declared = frame.readUInt32BE(0);
  if (declared === 0 || declared > MAX_RESPONSE_BYTES) {
    fail('API_RESPONSE_LIMIT', 'response frame exceeds the 128 MiB limit');
  }
  if (frame.length !== declared + 4) {
    fail('API_PROTOCOL', frame.length < declared + 4
      ? 'response frame is truncated'
      : 'response frame contains trailing bytes');
  }
  let response;
  try {
    response = JSON.parse(decodeUtf8(frame.subarray(4), 'response frame'));
  } catch (error) {
    if (error instanceof ZigCssCompileError) throw error;
    fail('API_PROTOCOL', 'response frame does not contain valid JSON', [], { cause: error });
  }
  if (!isPlainObject(response)) fail('API_PROTOCOL', 'response must be an object');
  if (response.protocol !== PROTOCOL) fail('API_PROTOCOL', 'response protocol does not match the request');
  if (response.requestId !== requestId) fail('API_PROTOCOL', 'response requestId does not match the request');
  if (typeof response.ok !== 'boolean') fail('API_PROTOCOL', 'response ok field must be boolean');

  if (!response.ok) {
    exactKeys(response, ['protocol', 'requestId', 'ok', 'error'], 'failure response');
    exactKeys(response.error, ['code', 'message', 'diagnostics'], 'failure error');
    const { code, message, diagnostics } = response.error;
    if (typeof code !== 'string' || !/^[A-Z][A-Z0-9_]{1,63}$/.test(code)) {
      fail('API_PROTOCOL', 'failure error code is invalid');
    }
    if (typeof message !== 'string' || message.length === 0) {
      fail('API_PROTOCOL', 'failure error message is invalid');
    }
    if (!isProtocolString(message, { nonEmpty: true })) {
      fail('API_PROTOCOL', 'failure error message is invalid');
    }
    const ownedDiagnostics = validateDiagnostics(diagnostics, 'failure diagnostics');
    throw new ZigCssCompileError(code, message, ownedDiagnostics);
  }

  exactKeys(response, ['protocol', 'requestId', 'ok', 'result'], 'success response');
  exactKeys(response.result, ['css', 'sourceMap', 'diagnostics', 'dependencies'], 'success result');
  const { css, sourceMap, diagnostics, dependencies } = response.result;
  if (!isProtocolString(css)) fail('API_PROTOCOL', 'result.css must be a well-formed string');

  let ownedSourceMap = null;
  if (sourceMap !== null) {
    if (typeof sourceMap !== 'string') fail('API_PROTOCOL', 'result.sourceMap must be null or JSON text');
    try {
      const parsedMap = JSON.parse(sourceMap);
      validateSourceMapShape(parsedMap);
      ownedSourceMap = cloneJsonValue(parsedMap, 'result.sourceMap');
    } catch (error) {
      if (error instanceof ZigCssCompileError) throw error;
      fail('API_PROTOCOL', 'result.sourceMap does not contain valid JSON', [], { cause: error });
    }
  }

  return Object.freeze({
    css,
    sourceMap: ownedSourceMap,
    diagnostics: validateDiagnostics(diagnostics, 'result.diagnostics'),
    dependencies: validateDependencies(dependencies),
  });
}

function boundedStderr(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) return '';
  return buffer.subarray(0, 4096).toString('utf8').trim();
}

function processFailureMessage(status, signal, stderr) {
  const detail = boundedStderr(stderr);
  if (detail !== '') return `native compiler failed: ${detail}`;
  if (signal) return `native compiler was terminated by ${signal}`;
  return `native compiler exited with status ${status ?? 'unknown'}`;
}

function runSync(frame, requestId, options) {
  const executable = binaryPath();
  const result = spawnSync(executable, [INTERNAL_ARGUMENT], {
    input: frame,
    shell: false,
    windowsHide: true,
    encoding: null,
    timeout: options.timeoutMs,
    maxBuffer: MAX_SYNC_FRAME_BYTES,
  });
  const stdout = Buffer.isBuffer(result.stdout) ? result.stdout : Buffer.alloc(0);
  const stderr = Buffer.isBuffer(result.stderr) ? result.stderr : Buffer.alloc(0);

  if (stderr.length > MAX_STDERR_BYTES) {
    fail('API_STDERR_LIMIT', 'native compiler stderr exceeds the 4 MiB limit');
  }
  if (stdout.length > MAX_SYNC_FRAME_BYTES) {
    fail('API_RESPONSE_LIMIT', 'native compiler sync response exceeds the 4 MiB framed-output limit');
  }
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      fail('API_BINARY_NOT_FOUND', 'zigcss binary could not be started', [], { cause: result.error });
    }
    if (result.error.code === 'ETIMEDOUT') {
      fail('API_TIMEOUT', `native compiler exceeded the ${options.timeoutMs} ms timeout`, [], { cause: result.error });
    }
    if (result.error.code === 'ENOBUFS') {
      const stderrLimit = stderr.length >= MAX_STDERR_BYTES && stdout.length < MAX_SYNC_FRAME_BYTES;
      fail(
        stderrLimit ? 'API_STDERR_LIMIT' : 'API_RESPONSE_LIMIT',
        stderrLimit
          ? 'native compiler stderr exceeds the 4 MiB limit'
          : 'native compiler sync response exceeds the 4 MiB framed-output limit',
        [],
        { cause: result.error },
      );
    }
    fail('API_SPAWN', `failed to run the native compiler: ${result.error.message}`, [], { cause: result.error });
  }
  if (result.signal || result.status !== 0) {
    fail('API_PROCESS', processFailureMessage(result.status, result.signal, stderr));
  }
  return decodeResponse(stdout, requestId);
}

function runAsync(frame, requestId, options) {
  if (options.signal?.aborted) {
    return Promise.reject(new ZigCssCompileError('API_ABORTED', 'compilation was aborted'));
  }
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(binaryPath(), [INTERNAL_ARGUMENT], {
        shell: false,
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (error) {
      reject(error instanceof ZigCssCompileError
        ? error
        : new ZigCssCompileError('API_SPAWN', `failed to run the native compiler: ${error.message}`, [], { cause: error }));
      return;
    }

    const stdoutChunks = [];
    const stderrChunks = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let terminal = null;
    let spawnError = null;
    let settled = false;

    const terminate = reason => {
      if (terminal === null) terminal = reason;
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    };
    const timer = setTimeout(() => terminate('timeout'), options.timeoutMs);
    const abort = () => terminate('aborted');
    options.signal?.addEventListener('abort', abort, { once: true });

    child.stdout.on('data', chunk => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > MAX_RESPONSE_BYTES + 4) {
        terminate('response-limit');
        return;
      }
      stdoutChunks.push(chunk);
    });
    child.stderr.on('data', chunk => {
      stderrBytes += chunk.length;
      if (stderrBytes > MAX_STDERR_BYTES) {
        terminate('stderr-limit');
        return;
      }
      stderrChunks.push(chunk);
    });
    child.on('error', error => {
      spawnError = error;
    });
    child.stdin.on('error', error => {
      if (error.code !== 'EPIPE' && spawnError === null) spawnError = error;
    });
    child.on('close', (status, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      options.signal?.removeEventListener('abort', abort);
      const stderr = Buffer.concat(stderrChunks, Math.min(stderrBytes, MAX_STDERR_BYTES));

      try {
        if (terminal === 'timeout') {
          fail('API_TIMEOUT', `native compiler exceeded the ${options.timeoutMs} ms timeout`);
        }
        if (terminal === 'aborted') fail('API_ABORTED', 'compilation was aborted');
        if (terminal === 'response-limit') {
          fail('API_RESPONSE_LIMIT', 'native compiler response exceeds the 128 MiB limit');
        }
        if (terminal === 'stderr-limit') {
          fail('API_STDERR_LIMIT', 'native compiler stderr exceeds the 4 MiB limit');
        }
        if (spawnError) {
          if (spawnError.code === 'ENOENT') {
            fail('API_BINARY_NOT_FOUND', 'zigcss binary could not be started', [], { cause: spawnError });
          }
          fail('API_SPAWN', `failed to run the native compiler: ${spawnError.message}`, [], { cause: spawnError });
        }
        if (signal || status !== 0) {
          fail('API_PROCESS', processFailureMessage(status, signal, stderr));
        }
        resolve(decodeResponse(Buffer.concat(stdoutChunks, stdoutBytes), requestId));
      } catch (error) {
        reject(error instanceof ZigCssCompileError
          ? error
          : new ZigCssCompileError('API_INTERNAL', error?.message || 'compilation failed', [], { cause: error }));
      }
    });
    child.stdin.end(frame);
  });
}

function prepare(source, optionValue, sourcePathOverride, asyncMode, inferRequired = false) {
  const validatedSource = validateSource(source);
  const options = normalizeOptions(optionValue, sourcePathOverride, asyncMode, inferRequired);
  const { frame, requestId } = buildFrame(validatedSource, options);
  return { frame, requestId, options };
}

async function readSourceFile(input) {
  let handle;
  try {
    handle = await fs.promises.open(input.filename, inputOpenFlags());
    const before = await handle.stat({ bigint: true });
    validateOpenedInput(input, before, 'source file');
    const chunks = [];
    const buffer = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_SOURCE_BYTES + 1));
    let total = 0;
    while (true) {
      const remaining = MAX_SOURCE_BYTES + 1 - total;
      const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, remaining), total);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > MAX_SOURCE_BYTES) fail('API_INPUT', 'source exceeds the 10 MiB limit');
      chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    }
    const after = await handle.stat({ bigint: true });
    validateStableInput(before, after, total, 'source file');
    const bytes = Buffer.concat(chunks, total);
    try {
      return utf8Decoder.decode(bytes);
    } catch (error) {
      fail('API_INPUT_ENCODING', 'source file is not valid UTF-8', [], { cause: error });
    }
  } catch (error) {
    if (error instanceof ZigCssCompileError) throw error;
    fail('API_INPUT', `source file could not be read: ${error.message}`, [], { cause: error });
  } finally {
    if (handle !== undefined) await handle.close().catch(() => {});
  }
}

function readSourceFileSync(input) {
  let descriptor;
  try {
    descriptor = fs.openSync(input.filename, inputOpenFlags());
    const before = fs.fstatSync(descriptor, { bigint: true });
    validateOpenedInput(input, before, 'source file');
    const chunks = [];
    const buffer = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_SOURCE_BYTES + 1));
    let total = 0;
    while (true) {
      const remaining = MAX_SOURCE_BYTES + 1 - total;
      const bytesRead = fs.readSync(descriptor, buffer, 0, Math.min(buffer.length, remaining), total);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > MAX_SOURCE_BYTES) fail('API_INPUT', 'source exceeds the 10 MiB limit');
      chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    }
    const after = fs.fstatSync(descriptor, { bigint: true });
    validateStableInput(before, after, total, 'source file');
    const bytes = Buffer.concat(chunks, total);
    try {
      return utf8Decoder.decode(bytes);
    } catch (error) {
      fail('API_INPUT_ENCODING', 'source file is not valid UTF-8', [], { cause: error });
    }
  } catch (error) {
    if (error instanceof ZigCssCompileError) throw error;
    fail('API_INPUT', `source file could not be read: ${error.message}`, [], { cause: error });
  } finally {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor);
      } catch {
        // Preserve the original read result or failure; the descriptor is not reused.
      }
    }
  }
}

async function compile(source, options) {
  const prepared = prepare(source, options, undefined, true);
  return runAsync(prepared.frame, prepared.requestId, prepared.options);
}

function compileSync(source, options) {
  const prepared = prepare(source, options, undefined, false);
  return runSync(prepared.frame, prepared.requestId, prepared.options);
}

async function compileFile(filename, options) {
  const input = canonicalInputFile(filename);
  const normalizedOptions = normalizeOptions(options, input.filename, true, true);
  const source = await readSourceFile(input);
  const validatedSource = validateSource(source);
  const { frame, requestId } = buildFrame(validatedSource, normalizedOptions);
  return runAsync(frame, requestId, normalizedOptions);
}

function compileFileSync(filename, options) {
  const input = canonicalInputFile(filename);
  const normalizedOptions = normalizeOptions(options, input.filename, false, true);
  const source = validateSource(readSourceFileSync(input));
  const { frame, requestId } = buildFrame(source, normalizedOptions);
  return runSync(frame, requestId, normalizedOptions);
}

module.exports = Object.freeze({
  compile,
  compileSync,
  compileFile,
  compileFileSync,
  detectSyntax,
  ZigCssCompileError,
});
