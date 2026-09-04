declare namespace api {
  type Syntax = 'css' | 'scss' | 'sass' | 'less' | 'stylus'
  type Format = 'pretty' | 'minified'
  type DiagnosticSeverity = 'error' | 'warning' | 'note'

  interface Diagnostic {
    readonly severity: DiagnosticSeverity
    readonly code: string
    readonly message: string
    readonly sourceUrl: string
    /** One-based source line. */
    readonly line: number
    /** Zero-based UTF-16 code-unit column for every supported syntax. */
    readonly column: number
    readonly [field: string]: unknown
  }

  interface CssDependency {
    readonly kind: 'css-import' | 'css-module'
    readonly specifier: string
    readonly sourceUrl: string
    readonly start: number
    readonly end: number
  }

  interface NativeDependency {
    readonly kind: 'import' | 'use' | 'forward' | 'reference'
    readonly url: string
  }

  type Dependency = CssDependency | NativeDependency

  interface SourceMap {
    readonly version: 3
    readonly sources: readonly string[]
    readonly names: readonly string[]
    readonly mappings: string
    readonly file?: string
    readonly sourceRoot?: string
    readonly sourcesContent?: readonly (string | null)[]
    readonly [field: string]: unknown
  }

  interface CompileResult {
    readonly css: string
    /** Parsed, deeply immutable source-map data; null when sourceMap was not requested. */
    readonly sourceMap: SourceMap | null
    readonly diagnostics: readonly Readonly<Diagnostic>[]
    readonly dependencies: readonly Readonly<Dependency>[]
  }

  interface CompileOptions {
    /** Explicit syntax. If omitted, sourcePath is inspected; string compilation otherwise defaults to CSS. */
    readonly syntax?: Syntax
    /** Logical drive-local filename for string input. Its existing parent is resolved to a canonical directory. */
    readonly sourcePath?: string
    /** One to sixteen existing confined import directories; at least one must contain sourcePath. */
    readonly rootPaths?: readonly string[]
    readonly format?: Format
    readonly sourceMap?: boolean
    /** Verified fixed-point optimizer. Cannot be combined with sourceMap. */
    readonly optimize?: boolean
    /** Explicit ZigCSS browser-minimum query. A string enables verified target prefixing; null disables it. */
    readonly browsers?: string | null
    /** Process deadline in milliseconds (1..120000, default 30000). */
    readonly timeoutMs?: number
    /** Cancels asynchronous compilation and terminates its private native process. */
    readonly signal?: AbortSignal
  }

  type CompileSyncOptions = Omit<CompileOptions, 'signal'> & { readonly signal?: never }
  type CompileFileOptions = Omit<CompileOptions, 'sourcePath'> & { readonly sourcePath?: never }
  type CompileFileSyncOptions = Omit<CompileFileOptions, 'signal'> & { readonly signal?: never }

  /**
   * A compilation failure. No partial CSS result is attached. Diagnostics are an
   * owned, deeply immutable snapshot of the native response.
   */
  class ZigCssCompileError extends Error {
    readonly code: string
    readonly diagnostics: readonly Readonly<Diagnostic>[]
    constructor(code: string, message: string, diagnostics?: readonly Diagnostic[], options?: ErrorOptions)
  }

  /** Compile one in-memory source with an isolated native process and no temporary files. */
  function compile(source: string, options?: CompileOptions): Promise<CompileResult>

  /** Compile one in-memory source synchronously with an isolated native process and no temporary files. */
  function compileSync(source: string, options?: CompileSyncOptions): CompileResult

  /** Read and compile one canonicalized UTF-8 file. Syntax is inferred from its finite supported extension when omitted. */
  function compileFile(filename: string, options?: CompileFileOptions): Promise<CompileResult>

  /** Synchronously read and compile one UTF-8 file. */
  function compileFileSync(filename: string, options?: CompileFileSyncOptions): CompileResult

  /** Infer CSS, SCSS, Sass, Less, or Stylus from a filename; throws for every other extension. */
  function detectSyntax(filename: string): Syntax
}

export = api
