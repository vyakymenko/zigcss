import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  SUPPORTED_SYNTAXES,
  ZigCssCompileError,
  compileFile,
  compileFileWithRuntime,
  compileString,
  compileStringWithRuntime,
  loadFileForCompilation,
} from './product-api.mjs'
import { MAX_SOURCE_BYTES } from './protocol.mjs'
import { createConfinedResolver } from './resolver.mjs'

const maxWorkers = 8
const maxInputs = 4096
const maxArguments = 8192
const maxArgumentBytes = 4096
const maxBatchBasenameBytes = 128
const maxWatchDependencies = 4096
const defaultWatchIntervalMs = 500
let temporaryCounter = 0

class CliUsageError extends Error {
  constructor(message) {
    super(message)
    this.name = 'CliUsageError'
  }
}

function usage(message) {
  throw new CliUsageError(message)
}

function requireValue(argv, index, option) {
  if (index + 1 >= argv.length) usage(`${option} requires a value`)
  const value = argv[index + 1]
  if (value.length === 0 || (value.startsWith('-') && value !== '-')) {
    usage(`${option} requires a value`)
  }
  return value
}

function parseArguments(argv, cwd) {
  if (!Array.isArray(argv) || argv.some(value => typeof value !== 'string')) {
    usage('arguments must be strings')
  }
  if (argv.length > maxArguments) usage(`argument count exceeds ${maxArguments}`)
  if (argv.some(value => Buffer.byteLength(value) > maxArgumentBytes || /[\u0000\r\n]/.test(value))) {
    usage('arguments must be bounded single-line strings')
  }
  const inputs = []
  const loadPaths = []
  let output = null
  let outputDir = false
  let syntax = null
  let minify = false
  let optimize = false
  let sourceMap = false
  let watch = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '-o' || argument === '--output') {
      if (output !== null) usage(`${argument} may only be specified once`)
      output = requireValue(argv, index, argument)
      index += 1
    } else if (argument === '--output-dir') {
      if (outputDir) usage('--output-dir may only be specified once')
      outputDir = true
    } else if (argument === '--syntax') {
      if (syntax !== null) usage('--syntax may only be specified once')
      syntax = requireValue(argv, index, argument)
      if (!SUPPORTED_SYNTAXES.includes(syntax)) usage(`unsupported syntax: ${syntax}`)
      index += 1
    } else if (argument === '--load-path') {
      const value = requireValue(argv, index, argument)
      if (loadPaths.length >= 64) usage('--load-path exceeds the count limit')
      loadPaths.push(path.resolve(cwd, value))
      index += 1
    } else if (argument === '--minify') {
      if (minify) usage('--minify may only be specified once')
      minify = true
    } else if (argument === '--optimize') {
      if (optimize) usage('--optimize may only be specified once')
      optimize = true
    } else if (argument === '--source-map') {
      if (sourceMap) usage('--source-map may only be specified once')
      sourceMap = true
    } else if (argument === '--watch') {
      if (watch) usage('--watch may only be specified once')
      watch = true
    } else if (argument === '--help' || argument === '-h') {
      usage('--help must be used alone through the installed ZigCSS launcher')
    } else if (argument === '--version' || argument === '-V') {
      usage('--version must be used alone through the installed ZigCSS launcher')
    } else if (argument === '-') {
      inputs.push(argument)
    } else if (argument.length === 0) {
      usage('empty arguments are not valid input paths')
    } else if (argument.startsWith('-')) {
      usage(`unknown option: ${argument}`)
    } else {
      if (argument.includes('*') || argument.includes('?')) {
        usage('preprocessor glob inputs are unavailable; pass explicit files')
      }
      if (inputs.length >= maxInputs) usage(`input count exceeds ${maxInputs}`)
      inputs.push(argument)
    }
  }

  if (inputs.length === 0) usage('no input files specified')
  const stdinCount = inputs.filter(input => input === '-').length
  if (stdinCount > 1) usage('stdin may only be specified once')
  if (stdinCount === 1 && inputs.length !== 1) usage('stdin cannot be combined with file or batch inputs')
  if (stdinCount === 1 && watch) usage('--watch requires a file input')
  if (watch && inputs.length !== 1) usage('--watch supports exactly one file')
  if (inputs.length > 1 && !outputDir) usage('multiple inputs require --output-dir')
  if (outputDir && inputs.length < 2) usage('--output-dir requires multiple inputs')
  if (outputDir && output === null) usage('--output-dir requires -o or --output')
  if (outputDir && output === '-') usage('--output-dir cannot write to stdout')
  if (sourceMap && optimize) usage('--source-map cannot be combined with --optimize')
  if (new Set(loadPaths.map(pathIdentityKey)).size !== loadPaths.length) {
    usage('--load-path values must be unique')
  }

  return Object.freeze({
    inputs: Object.freeze([...inputs]),
    output,
    outputDir,
    syntax,
    loadPaths: Object.freeze(loadPaths),
    minify,
    optimize,
    sourceMap,
    watch,
  })
}

function batchStem(input) {
  const parsed = path.parse(input)
  return parsed.name.length === 0 ? 'output' : parsed.name
}

function pathIdentityKey(value) {
  return ['win32', 'darwin'].includes(process.platform) ? value.toLowerCase() : value
}

function batchOutputName(inputs, index, cwd) {
  const stem = batchStem(inputs[index])
  const identity = pathIdentityKey(stem)
  const collides = inputs.some((input, other) => (
    other !== index && pathIdentityKey(batchStem(input)) === identity
  ))
  const relative = path.relative(cwd, path.resolve(cwd, inputs[index])).split(path.sep).join('/')
  const digest = createHash('sha256').update(relative).digest('hex').slice(0, 16)
  let basename = collides ? `${stem}-${digest}.css` : `${stem}.css`
  if (Buffer.byteLength(basename) > maxBatchBasenameBytes) basename = `zigcss-${digest}.css`
  return basename
}

function planTasks(configuration, cwd) {
  if (configuration.inputs.length === 1) {
    const display = configuration.inputs[0]
    return [Object.freeze({
      display,
      input: display === '-' ? null : path.resolve(cwd, display),
      outputDisplay: configuration.output,
      output: configuration.output === null || configuration.output === '-'
        ? null
        : path.resolve(cwd, configuration.output),
    })]
  }
  return configuration.inputs.map((display, index) => {
    const basename = batchOutputName(configuration.inputs, index, cwd)
    const outputDisplay = path.join(configuration.output, basename)
    return Object.freeze({
      display,
      input: path.resolve(cwd, display),
      outputDisplay,
      output: path.resolve(cwd, outputDisplay),
    })
  })
}

async function canonicalizePath(value) {
  let current = path.resolve(value)
  const suffix = []
  while (true) {
    try {
      const canonical = await fs.promises.realpath(current)
      return path.join(canonical, ...suffix.reverse())
    } catch (error) {
      if (error?.code !== 'ENOENT' && error?.code !== 'ENOTDIR') throw error
      const parent = path.dirname(current)
      if (parent === current) return path.resolve(value)
      suffix.push(path.basename(current))
      current = parent
    }
  }
}

async function identifyPath(value) {
  let stat = null
  try {
    stat = await fs.promises.stat(value, { bigint: true })
  } catch (error) {
    if (error?.code !== 'ENOENT' && error?.code !== 'ENOTDIR') throw error
  }
  return {
    canonical: pathIdentityKey(await canonicalizePath(value)),
    device: stat?.dev ?? null,
    inode: stat?.ino ?? null,
  }
}

function sameIdentity(left, right) {
  if (left.canonical === right.canonical) return true
  return left.device !== null && right.device !== null &&
    left.inode !== 0n && left.device === right.device && left.inode === right.inode
}

async function rejectOutputCollisions(tasks) {
  const inputs = []
  for (const task of tasks) {
    if (task.input !== null) inputs.push({ display: task.display, identity: await identifyPath(task.input) })
  }
  const outputs = []
  for (const task of tasks) {
    if (task.output === null) continue
    const identity = await identifyPath(task.output)
    if (inputs.some(input => sameIdentity(input.identity, identity))) {
      usage(`output path resolves to an input: ${task.outputDisplay}`)
    }
    if (outputs.some(output => sameIdentity(output.identity, identity))) {
      usage(`multiple inputs resolve to the same output: ${task.outputDisplay}`)
    }
    outputs.push({ identity })
  }
}

function readBoundedStdin(stream = process.stdin, signal) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let total = 0
    let settled = false
    const cleanup = () => {
      stream.removeListener('data', onData)
      stream.removeListener('end', onEnd)
      stream.removeListener('error', onError)
      if (signal !== undefined) signal.removeEventListener('abort', onAbort)
    }
    const finish = (error, source = null) => {
      if (settled) return
      settled = true
      cleanup()
      if (typeof stream.pause === 'function') stream.pause()
      if (error === null) resolve(source)
      else reject(error)
    }
    const onData = chunk => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      total += buffer.length
      if (total > MAX_SOURCE_BYTES) {
        finish(new ZigCssCompileError('API_SOURCE_LIMIT', 'stdin exceeds 10 MiB'))
        return
      }
      chunks.push(buffer)
    }
    const onEnd = () => {
      try {
        finish(null, new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, total)))
      } catch {
        finish(new ZigCssCompileError('API_INPUT_ENCODING', 'stdin is not valid UTF-8'))
      }
    }
    const onError = () => {
      finish(new ZigCssCompileError('API_INPUT_READ', 'stdin could not be read'))
    }
    const onAbort = () => {
      finish(new ZigCssCompileError('API_PROCESS_ABORTED', 'stdin compilation was cancelled'))
    }

    stream.on('data', onData)
    stream.once('end', onEnd)
    stream.once('error', onError)
    if (signal !== undefined) signal.addEventListener('abort', onAbort, { once: true })
    if (signal?.aborted) onAbort()
    else if (typeof stream.resume === 'function') stream.resume()
  })
}

function renderedCss(result, sourceMap) {
  if (!sourceMap) return result.css
  const encoded = Buffer.from(result.sourceMap, 'utf8').toString('base64')
  return `${result.css}${result.css.endsWith('\n') ? '' : '\n'}/*# sourceMappingURL=data:application/json;charset=utf-8;base64,${encoded} */`
}

function diagnosticLine(task, diagnostic, fallbackCode) {
  const source = task.display
  const line = diagnostic.line ?? 1
  const column = diagnostic.column ?? 1
  const code = diagnostic.code ?? fallbackCode
  return `${source}:${line}:${column}: ${diagnostic.severity} ${code}: ${diagnostic.message}\n`
}

function renderFailure(task, error) {
  if (error instanceof ZigCssCompileError && error.diagnostics.length !== 0) {
    return error.diagnostics.map(diagnostic => diagnosticLine(task, diagnostic, error.code)).join('')
  }
  const code = typeof error?.code === 'string' ? `${error.code}: ` : ''
  const message = typeof error?.message === 'string' ? error.message : 'compilation failed'
  return `Error compiling ${task.display}: ${code}${message}\n`
}

function compilationOptions(configuration, signal) {
  const options = {
    format: configuration.minify ? 'minified' : 'pretty',
    sourceMap: configuration.sourceMap,
    optimize: configuration.optimize,
    loadPaths: [...configuration.loadPaths],
    signal,
  }
  if (configuration.syntax !== null) options.syntax = configuration.syntax
  return options
}

async function compileTask(task, configuration, context, signal) {
  const options = compilationOptions(configuration, signal)
  if (task.input === null) {
    const source = await context.readStdin(signal)
    const syntax = configuration.syntax ?? 'css'
    return context.runtime === undefined
      ? compileString(source, {
        ...options,
        syntax,
        sourceUrl: pathToFileURL(path.join(context.cwd, `.zigcss-stdin.${syntax === 'stylus' ? 'styl' : syntax}`)).href,
      })
      : compileStringWithRuntime(source, {
        ...options,
        syntax,
        sourceUrl: pathToFileURL(path.join(context.cwd, `.zigcss-stdin.${syntax === 'stylus' ? 'styl' : syntax}`)).href,
      }, context.runtime)
  }
  return context.runtime === undefined
    ? compileFile(task.input, options)
    : compileFileWithRuntime(task.input, options, context.runtime)
}

async function compileTasks(tasks, configuration, context) {
  const controller = new AbortController()
  const onAbort = () => controller.abort()
  if (context.signal !== undefined) {
    if (context.signal.aborted) controller.abort()
    else context.signal.addEventListener('abort', onAbort, { once: true })
  }
  let next = 0
  let failed = false
  const states = tasks.map(() => ({ result: null, error: null }))
  const workers = Array.from({ length: Math.min(tasks.length, maxWorkers) }, async () => {
    while (!failed && next < tasks.length) {
      const index = next
      next += 1
      try {
        states[index].result = await compileTask(tasks[index], configuration, context, controller.signal)
      } catch (error) {
        states[index].error = error
        if (!failed) {
          failed = true
          controller.abort()
        }
      }
    }
  })
  try {
    await Promise.all(workers)
  } finally {
    if (context.signal !== undefined) context.signal.removeEventListener('abort', onAbort)
  }
  return states
}

async function atomicWrite(destination, contents) {
  const parent = path.dirname(destination)
  await fs.promises.mkdir(parent, { recursive: true })
  let temporary = null
  let handle = null
  try {
    for (let attempt = 0; attempt < 32; attempt += 1) {
      temporaryCounter += 1
      temporary = path.join(parent, `.zigcss-${process.pid}-${temporaryCounter}.tmp`)
      try {
        handle = await fs.promises.open(temporary, 'wx', 0o666)
        break
      } catch (error) {
        if (error?.code !== 'EEXIST') throw error
      }
    }
    if (handle === null) throw new Error('could not reserve an atomic output file')
    await handle.writeFile(contents, 'utf8')
    await handle.sync()
    await handle.close()
    handle = null
    await fs.promises.rename(temporary, destination)
    temporary = null
  } finally {
    if (handle !== null) await handle.close().catch(() => {})
    if (temporary !== null) await fs.promises.unlink(temporary).catch(() => {})
  }
}

function watchFingerprint(kind, value) {
  return `${kind}:${createHash('sha256').update(value).digest('hex')}`
}

function watchErrorFingerprint(error) {
  const code = typeof error?.code === 'string' ? error.code : 'WATCH_ERROR'
  const message = typeof error?.message === 'string' ? error.message : 'watch path is unavailable'
  return watchFingerprint('error', `${code}\u0000${message}`)
}

async function observeWatchSource(task, configuration, context) {
  try {
    const loaded = await context.loadFileForWatch(
      task.input,
      compilationOptions(configuration, context.signal),
    )
    return Object.freeze({
      state: watchFingerprint('contents', loaded.source),
      loaded,
      error: null,
    })
  } catch (error) {
    return Object.freeze({
      state: watchErrorFingerprint(error),
      loaded: null,
      error,
    })
  }
}

function watchRoots(loaded) {
  const entry = fileURLToPath(loaded.options.sourceUrl)
  const roots = [path.dirname(entry), ...loaded.options.loadPaths]
  const seen = new Set()
  return roots.filter(root => {
    const identity = pathIdentityKey(root)
    if (seen.has(identity)) return false
    seen.add(identity)
    return true
  })
}

function localCoreDependency(entry, specifier) {
  let end = specifier.length
  for (const separator of ['?', '#']) {
    const index = specifier.indexOf(separator)
    if (index !== -1) end = Math.min(end, index)
  }
  const local = specifier.slice(0, end)
  if (
    local.length === 0 ||
    local.startsWith('/') ||
    local.startsWith('\\') ||
    local.startsWith('//') ||
    path.isAbsolute(local) ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(local)
  ) {
    return null
  }
  return path.resolve(path.dirname(entry), local)
}

function watchDependencyPaths(result, loaded) {
  const entry = fileURLToPath(loaded.options.sourceUrl)
  const entryIdentity = pathIdentityKey(entry)
  const output = []
  const seen = new Set()
  for (const dependency of result.dependencies) {
    let filename = null
    if (typeof dependency.url === 'string') {
      filename = fileURLToPath(dependency.url)
    } else if (
      (dependency.kind === 'css-import' || dependency.kind === 'css-module') &&
      typeof dependency.specifier === 'string'
    ) {
      filename = localCoreDependency(entry, dependency.specifier)
    }
    if (filename === null) continue
    if (Buffer.byteLength(filename) > 4096 || /[\u0000\r\n]/.test(filename)) {
      throw new ZigCssCompileError('WATCH_PATH_INVALID', 'dependency watch path is invalid')
    }
    const identity = pathIdentityKey(filename)
    if (identity === entryIdentity || seen.has(identity)) continue
    if (output.length >= maxWatchDependencies) {
      throw new ZigCssCompileError(
        'WATCH_DEPENDENCY_LIMIT',
        `watch dependency count exceeds ${maxWatchDependencies}`,
      )
    }
    seen.add(identity)
    output.push(filename)
  }
  return Object.freeze(output)
}

async function fingerprintWatchPaths(paths, roots) {
  const output = new Map()
  if (paths.length === 0) return output
  let resolver
  try {
    resolver = createConfinedResolver({
      roots,
      limits: {
        maxFileBytes: MAX_SOURCE_BYTES,
        maxTotalBytes: 40 * 1024 * 1024,
        maxFiles: maxWatchDependencies,
        maxReads: maxWatchDependencies,
        maxDepth: 64,
      },
    })
  } catch (error) {
    const state = watchErrorFingerprint(error)
    for (const filename of paths) output.set(filename, state)
    return output
  }
  const session = resolver.createSession()
  try {
    for (const filename of paths) {
      try {
        const loaded = await session.load(pathToFileURL(filename).href, {
          kind: 'reference',
          ancestry: [],
        })
        output.set(filename, watchFingerprint('contents', loaded.contents))
      } catch (error) {
        output.set(filename, watchErrorFingerprint(error))
      }
    }
  } finally {
    session.close()
  }
  return output
}

async function initializeWatchStates(paths, roots, previous) {
  const newPaths = paths.filter(filename => !previous.has(filename))
  const added = await fingerprintWatchPaths(newPaths, roots)
  const output = new Map()
  for (const filename of paths) {
    output.set(filename, previous.get(filename) ?? added.get(filename))
  }
  return output
}

async function pollWatchDependencies(paths, roots, previous) {
  const states = await fingerprintWatchPaths(paths, roots)
  const changed = paths.some(filename => states.get(filename) !== previous.get(filename))
  return { states, changed }
}

function waitForWatchInterval(_poll, intervalMs, signal) {
  if (signal?.aborted) return Promise.resolve()
  return new Promise(resolve => {
    const timer = setTimeout(done, intervalMs)
    function done() {
      clearTimeout(timer)
      if (signal !== undefined) signal.removeEventListener('abort', done)
      resolve()
    }
    if (signal !== undefined) signal.addEventListener('abort', done, { once: true })
    if (signal?.aborted) done()
  })
}

async function compileLoadedWatchSource(loaded, context) {
  return context.runtime === undefined
    ? compileString(loaded.source, loaded.options)
    : compileStringWithRuntime(loaded.source, loaded.options, context.runtime)
}

async function emitWatchResult(task, configuration, context, result) {
  await rejectOutputCollisions([task])
  const css = renderedCss(result, configuration.sourceMap)
  for (const diagnostic of result.diagnostics) {
    context.writeStderr(diagnosticLine(task, diagnostic, 'warning'))
  }
  if (task.output === null) {
    context.writeStdout(css)
  } else {
    await atomicWrite(task.output, css)
    context.writeStderr(`Compiled: ${task.display} -> ${task.outputDisplay}\n`)
  }
}

async function runWatch(task, configuration, context) {
  context.writeStderr(`Watching ${task.display} for changes... (Press Ctrl+C to stop)\n`)
  let previousSource = null
  let dependencyPaths = Object.freeze([])
  let dependencyRoots = Object.freeze([])
  let dependencyStates = new Map()
  let firstAttempt = true
  let lastAttemptFailed = false
  let polls = 0

  while (!context.signal?.aborted) {
    const observed = await observeWatchSource(task, configuration, context)
    let dependencyChanged = false
    if (dependencyPaths.length !== 0) {
      const polled = await pollWatchDependencies(
        dependencyPaths,
        dependencyRoots,
        dependencyStates,
      )
      dependencyStates = polled.states
      dependencyChanged = polled.changed
    }
    const sourceChanged = observed.state !== previousSource
    previousSource = observed.state

    if (firstAttempt || sourceChanged || dependencyChanged) {
      if (!firstAttempt) {
        context.writeStderr('Source or dependency changed, recompiling...\n')
      }
      if (observed.error !== null) {
        context.writeStderr(renderFailure(task, observed.error))
        lastAttemptFailed = true
      } else {
        try {
          const result = await compileLoadedWatchSource(observed.loaded, context)
          const nextPaths = watchDependencyPaths(result, observed.loaded)
          const nextRoots = Object.freeze(watchRoots(observed.loaded))
          const nextStates = await initializeWatchStates(
            nextPaths,
            nextRoots,
            dependencyStates,
          )
          await emitWatchResult(task, configuration, context, result)
          dependencyPaths = nextPaths
          dependencyRoots = nextRoots
          dependencyStates = nextStates
          lastAttemptFailed = false
        } catch (error) {
          if (context.signal?.aborted) break
          context.writeStderr(renderFailure(task, error))
          lastAttemptFailed = true
        }
      }
    }

    firstAttempt = false
    if (context.signal?.aborted || polls >= context.watchPollLimit) break
    polls += 1
    await context.waitForWatchPoll(polls, context.watchIntervalMs, context.signal)
  }

  return context.signal?.aborted ? 0 : lastAttemptFailed ? 1 : 0
}

export async function runProductCli(argv, options = {}) {
  const watchPollLimit = options.watchPollLimit ?? Number.POSITIVE_INFINITY
  const watchIntervalMs = options.watchIntervalMs ?? defaultWatchIntervalMs
  const waitForWatchPoll = options.waitForWatchPoll ?? waitForWatchInterval
  const loadFileForWatch = options.loadFileForWatch ?? loadFileForCompilation
  const context = {
    cwd: path.resolve(options.cwd ?? process.cwd()),
    readStdin: options.readStdin ?? (signal => readBoundedStdin(process.stdin, signal)),
    writeStdout: options.writeStdout ?? (value => process.stdout.write(value)),
    writeStderr: options.writeStderr ?? (value => process.stderr.write(value)),
    runtime: options.runtime,
    signal: options.signal,
    watchPollLimit,
    watchIntervalMs,
    waitForWatchPoll,
    loadFileForWatch,
  }
  try {
    if (
      (watchPollLimit !== Number.POSITIVE_INFINITY && (
        !Number.isSafeInteger(watchPollLimit) || watchPollLimit < 0 || watchPollLimit > 1_000_000
      )) ||
      !Number.isSafeInteger(watchIntervalMs) ||
      watchIntervalMs < 1 ||
      watchIntervalMs > 60_000 ||
      typeof waitForWatchPoll !== 'function' ||
      typeof loadFileForWatch !== 'function' ||
      (context.signal !== undefined && !(context.signal instanceof AbortSignal))
    ) {
      throw new TypeError('invalid product CLI runtime options')
    }
    const configuration = parseArguments(argv, context.cwd)
    const tasks = planTasks(configuration, context.cwd)
    await rejectOutputCollisions(tasks)
    if (configuration.watch) return await runWatch(tasks[0], configuration, context)
    const states = await compileTasks(tasks, configuration, context)
    const failed = states.some(state => state.error !== null)
    if (failed) {
      for (let index = 0; index < states.length; index += 1) {
        const error = states[index].error
        if (
          error === null ||
          error?.code === 'HOST_PROCESS_ABORTED' ||
          error?.code === 'CORE_PROCESS_ABORTED' ||
          error?.code === 'API_PROCESS_ABORTED'
        ) continue
        context.writeStderr(renderFailure(tasks[index], error))
      }
      return 1
    }

    await rejectOutputCollisions(tasks)
    for (let index = 0; index < tasks.length; index += 1) {
      const task = tasks[index]
      const result = states[index].result
      const css = renderedCss(result, configuration.sourceMap)
      for (const diagnostic of result.diagnostics) {
        context.writeStderr(diagnosticLine(task, diagnostic, 'warning'))
      }
      if (task.output === null) {
        context.writeStdout(css)
      } else {
        await atomicWrite(task.output, css)
        context.writeStderr(`Compiled: ${task.display} -> ${task.outputDisplay}\n`)
      }
    }
    return 0
  } catch (error) {
    if (error instanceof CliUsageError) {
      context.writeStderr(`Error: ${error.message}\n`)
      return 2
    }
    context.writeStderr(`Error: ${error?.message ?? 'compilation failed'}\n`)
    return 1
  }
}

export async function mainProductCli(argv = process.argv.slice(2)) {
  const controller = new AbortController()
  let receivedSignal = null
  const onSigint = () => {
    receivedSignal = 'SIGINT'
    controller.abort()
  }
  const onSigterm = () => {
    receivedSignal = 'SIGTERM'
    controller.abort()
  }
  process.once('SIGINT', onSigint)
  process.once('SIGTERM', onSigterm)
  try {
    process.exitCode = await runProductCli(argv, { signal: controller.signal })
  } finally {
    process.removeListener('SIGINT', onSigint)
    process.removeListener('SIGTERM', onSigterm)
  }
  if (receivedSignal !== null) {
    try {
      process.kill(process.pid, receivedSignal)
    } catch {
      process.exitCode = 1
    }
  }
}
