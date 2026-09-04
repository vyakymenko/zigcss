# Current source CLI and recovery contract

The ZigCSS 0.7.0-rc.1 source-built candidate owns one combined command for CSS, SCSS, indented Sass, Less, and Stylus. It is not published; run `zig-out/bin/zigcss --help` for the authoritative option list.

CSS enters the stable native compile facade. SCSS, indented Sass, Less, and Stylus enter self-contained native Zig parser/evaluators, then their complete generated CSS passes through the same recovery-disabled core. The root JavaScript launcher only locates and invokes the binary; it hosts no language semantics.

This page documents the current `Unreleased` checkout. Stable 0.6.0 contains the five native language frontends and is published on npm, but it does not contain the current `--depfile`, `--autoprefix`/`--browsers`, expanded all-syntax Source Map and optimizer guarantees, hardened destination-commit contract, ASCII-safe cross-platform batch naming, independent npm-carried integrity inventory, or `zigcss-install` command. Stable users should treat `npx zigcss --help` from their installed package as authoritative; the commands and guarantees below require a current checkout and freshly built `zig-out/bin/zigcss` unless a paragraph explicitly says otherwise.

## Inputs and native frontends

| Syntax | Selection | Engine |
|---|---|---|
| CSS | default or `--syntax css` | Native ZigCSS core |
| SCSS | explicit `--syntax scss` | Native Zig Sass-family frontend |
| Indented Sass | explicit `--syntax sass` | Native Zig Sass-family frontend |
| Less | explicit `--syntax less` | Native Zig Less frontend |
| Stylus | explicit `--syntax stylus` | Native Zig Stylus frontend |

Dart Sass 1.101.0, Less 4.9.0, and Stylus 0.64.0 are development-only reference oracles. Less 4.9.0 forward-checks the frozen 4.6.7 native conformance baseline rather than changing the published native contract. These providers do not run during compilation and do not enter production dependencies, archives, installed packages, or runtime SBOM closure. CI separately audits the complete root development graph with `npm run audit:development`; the former direct `image-size` dependency is replaced by the shared bounded PNG/GIF/JPEG/SVG dimension parser used by the Less and Stylus reference paths.

CSS Modules, CSS-in-JS, PostCSS-like inputs, and Tailwind-like inputs do not fall back to CSS. They remain explicit unavailable-format errors.

## Options

| Option | Behavior |
|---|---|
| input `-` | Read one bounded UTF-8 input from stdin. Preprocessor stdin needs an explicit `--syntax`. |
| `-o`, `--output <path or ->` | Write one output file, select stdout with `-`, or name the destination directory with `--output-dir`. |
| `--output-dir` | Enable explicit multi-input output planning. It requires multiple inputs and `-o`. |
| `--syntax <css or scss or sass or less or stylus>` | Select one grammar for the request or complete batch. CSS is the default; a known preprocessor extension without an explicit selection fails closed with the required flag, while a selected grammar is not overridden by filenames. |
| `--minify` | Emit compact whitespace; this remains independent of `--optimize`. |
| `--optimize` | Run the same closed verified ZigCSS optimizer preset for CSS, SCSS, indented Sass, Less, or Stylus. Preprocessor inputs are optimized only after the native frontend produces complete CSS. |
| `--autoprefix` | Run the verified eight-feature target-prefix pass for any of the five syntaxes. It requires exactly one explicit `--browsers <query>` and runs after optional fixed-point optimization. |
| `--browsers <query>` | Set comma-separated explicit browser minimums such as `safari >= 7, ie >= 11`. It requires `--autoprefix`; no implicit or discovered target exists. |
| `--source-map` | Embed one deterministic inline Source Map for any of the five syntaxes. Preprocessor mappings are composed through the ZigCSS core. It cannot be combined with `--optimize`. |
| `--depfile <path>` | Write one bounded Make/Ninja dependency file for a single file input and explicit file output. |
| `--watch` | Recompile one input when the entry or an owned confined dependency changes. |
| `--profile` | Native CSS only: report public compile stages and requested-memory metrics. |
| `--lsp` | Native CSS only: start the experimental language server. |
| `-V`, `--version` | Print the package-synchronized version. |
| `-h`, `--help` | Print the combined five-language contract. |

Every boolean or valued option may appear at most once. Help and version must be used alone. Stdin may appear only as the sole input; watch requires one file; multiple files require `--output-dir`; batch output cannot be stdout. A depfile requires exactly one file input plus explicit non-stdio `-o`, and cannot be combined with stdin, stdout, watch, batch, or `--output-dir`. Unknown or incompatible options fail rather than becoming no-ops. Argument admission is capped at 4,096 input patterns, 16,384 expanded inputs, 16 KiB per input path, and 4 KiB per glob component before unbounded filesystem or batch work can begin.

## Streams and exit status

With no `-o`, one file or stdin emits CSS to stdout. `-o -` selects stdout explicitly. Informational text and CSS use stdout; warnings, diagnostics, watch status, and usage errors use stderr.

| Status | Meaning |
|---|---|
| `0` | Successful compilation or informational command |
| `1` | Compilation, native frontend, generated-CSS, read, write, or operational failure |
| `2` | Invalid syntax selection, unknown option, missing value, or incoherent stream/batch/watch configuration |

The JavaScript launcher preserves exact native exit codes and re-raises POSIX termination signals. Native cancellation terminates bounded work and cannot return partial CSS.

## Dependency files

`--depfile` writes the authored output path as its target, followed by the canonical entry and only native preprocessor files that compilation actually read. Prerequisites are byte-sorted and deduplicated after the entry. Authored CSS `@import` remains in CSS for the downstream CSS layer and is not guessed into this native dependency graph.

The serializer rejects controls and bounds paths, prerequisite count, and total output. It escapes the shared Make/Ninja subset for spaces, `#`, `$`, `:`, and backslashes. Entry, native dependencies, CSS output, and depfile are checked for canonical, symlink, and hard-link aliases before staging; where the platform exposes a stable object identity, checks pair the inode/file index with its device or volume. Both destination files are completely written and flushed before replacement; each replacement is atomic per file, with the CSS target committed last as the success marker. This does not claim a two-file filesystem transaction.

The same depfile can drive direct Make or Ninja rules and CMake or Meson custom commands. See `examples/build-systems` for the four minimal forms. Bazel still requires an explicitly declared rule/toolchain contract and is not claimed by this generic depfile surface.

## Unreleased package-manager lifecycle recovery

The current source package normally runs its installer during the dependency install lifecycle. npm, pnpm, Yarn, and Bun can suppress dependency scripts globally, require explicit package approval, or install with scripts disabled. In that state, the JavaScript launcher is present but the native executable is intentionally treated as missing; it does not scan arbitrary environment paths or fall back to another compiler.

The current package contract allows ZigCSS's install script or the installed `zigcss-install` package binary through that manager's normal exec command. Both entry points first read the exact five-target `native-integrity.json` intended to ship in a future npm package. They download the target's GitHub checksum manifest and require its archive digest to match the independently npm-published digest before any archive download; the archive must then match that same SHA-256, contain one exact executable, and carry the expected ELF, Mach-O, or PE architecture header before atomic placement. Each HTTPS download is byte- and redirect-bounded, has a two-minute total deadline across redirects, and has a 30-second inactivity timeout. No published npm version currently exposes `zigcss-install` or this independent inventory. Stable 0.6.0 users must approve its normal install lifecycle and reinstall instead.

The release also carries signed Sigstore attestation bundles, but the npm installer does not claim to verify those signatures automatically. Consumers that need cryptographic provenance verification can use GitHub's documented [`gh attestation verify` offline workflow](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline) with the release asset and its downloaded bundle.

This future-package recovery path is not an offline-download promise and requires HTTPS access to the matching GitHub Release. Two isolated CI harnesses can intercept only the exact expected asset requests: the release smoke serves verified release bytes, while the default-PnP matrix serves a locally generated host fixture after changing only the temporary installed copy's selected digest. Neither mechanism is a user-facing offline mode. For an isolated network-free environment, place an already verified native binary in the package's expected `bin` location through the deployment image, or build ZigCSS from source.

The repository verifies the suppressed-lifecycle state with one immutable local package archive and blocked registry access. GitHub Actions requires six execution variants: npm, pnpm 11.25.0, Yarn Classic 1.22.22, Yarn Modern 4.9.4 with both `node-modules` and default Plug'n'Play, and Bun 1.4.0; a local run may explicitly skip an unavailable non-npm CLI. Every executed installation must leave the native `bin` directory absent, expose both `zigcss` and `zigcss-install` shims, produce the same recovery diagnostic, retain the installed integrity inventory and zero production or optional dependencies, and check every public adapter export. The five `node_modules` variants resolve CommonJS, ESM, and declarations through ordinary package resolution and compile the strict TypeScript consumer against that exact installation.

The default-PnP gate uses Yarn's loader to resolve every CommonJS and ESM export and verifies the exact import/require declaration bytes. It then path-maps only those verified files for a condition-specific strict compile. Exact unpatched TypeScript 7.0.2 without a Yarn SDK or patch is expected to report `TS2307` for no-paths PnP package resolution; native TypeScript PnP resolution is not claimed by this gate. Projects that require it should follow [Yarn's official SDK guidance](https://yarnpkg.com/getting-started/editor-sdks); SDK generation and editor integration remain outside this gate. It also requires no `node_modules`, checks that `preferUnplugged` places the package in a writable project-local `.yarn/unplugged` area, confines both Yarn and Corepack state to disposable test roots, and performs controlled offline recovery from a locally generated native fixture. That fixture changes only the temporary installed copy's selected digest and leaves the committed manifest and exact packed archive unchanged; it does not turn the production recovery command into an offline installer.

## Import and execution boundary

File compilation confines native preprocessor imports to the entry directory. Additional CLI load paths are not currently exposed. The resolver rejects lexical or canonical escapes, symbolic links, special files, unstable reads, invalid UTF-8, cycles, excess ancestry, and resource exhaustion. Network schemes and ambient package discovery are disabled.

The native contract does not enable project plugins, custom functions, custom importers, Less JavaScript, Stylus evaluator hooks, or arbitrary executable project code. Matching a development oracle does not grant those extension points implicitly.

## Batch execution

Each batch uses one selected grammar for every input (CSS by default); mixed-syntax batches are not currently exposed. Glob matching is iterative, filesystem matches are byte-sorted before planning, and expansion stops at the declared input ceiling. Worker count is bounded by the input count, available CPUs, and a process cap of eight. Each task owns its compiler result. The first failure closes the queue; already-running tasks finish safely, unclaimed tasks never open, and no output commit begins unless every compilation succeeded. Native batches then union every entry and discovered dependency and reject any output alias across tasks before the first commit.

Unique input stems become `<stem>.css`. Colliding stems receive a deterministic 16-digit digest of the normalized working-directory-relative path. On Windows and Apple targets, every non-ASCII stem instead receives the ASCII-only `zigcss-<digest>.css` form, so filesystem case or Unicode-normalization rules cannot merge two planned names. Stem counts and input/output collision identities are indexed rather than repeatedly rescanned. Final basenames have a 128-byte ceiling. Results and diagnostics are committed or rendered in original argument order, independent of scheduling.

## Watch behavior

Watch mode hashes one owned entry snapshot and uses result dependency facts to track native confined imports. It supports all five syntaxes. New, changed, missing, and recovered dependencies trigger one recompilation. A failed attempt keeps the last successful dependency set and retains the last successful output.

Dependency polling uses the same confined roots as compilation. Remote URLs, protocol-relative URLs, absolute unowned paths, query/fragment aliases, links, and excessive dependency sets are not opened. Cancellation stops polling and native frontend work without one extra compile.

## Output safety

Before reading inputs, the CLI rejects destinations that resolve to an entry and duplicate final destinations, including relative aliases, symlinks, and hard links. After compilation reveals the complete input graph, single/watch and batch routes open each canonical parent directory and retain that handle through a repeated identity check and a directory-relative atomic rename. Each destination entry is checked again after its unique temporary neighbor is completely written and flushed; a CSS/depfile pair jointly checks both entries before either commit, and the CSS entry is checked once more after the depfile commit. This prevents a later parent-path or parent-symlink replacement from redirecting the commit and makes ordinary concurrent destination changes fail closed.

These checks assume a cooperative filesystem namespace. They do not lock inputs or destinations and do not claim protection from a malicious or privileged process that continuously mutates directory entries inside the final check-to-rename syscall gap. Compilation failures before destination preparation and collisions found by the initial preflight create no partial CSS or output directory; a later operational or race-detection failure can leave a newly created empty parent directory.

Apple filesystem case and Unicode-normalization behavior is volume-configurable and has no portable userspace equivalence key. Batch output avoids that ambiguity with ASCII-only names. For explicit non-ASCII output/depfile names in one directory, the CLI fails closed unless different all-ASCII extensions prove that the two entries cannot alias; this can conservatively reject distinct same-extension names on a case-sensitive volume.

An operational failure while committing a later batch file can leave earlier files committed; output files are individually atomic, not one multi-file filesystem transaction.

## Native optimizer, target-prefix, and profiling boundaries

`--optimize` admits exactly the verified order-preserving pass preset. An exact whole-plan no-op stops before fixed-point emit/reparse work; a changed root repeats parse-transform-emit to a bounded byte-stable fixed point. CSS enters the preset directly; SCSS, indented Sass, Less, and Stylus enter it only after their native frontend emits complete CSS that passes recovery-disabled core parsing. File, stdin, watch, and bounded batch routes share this contract. Experimental extraction, compatibility rewriting, custom-property resolution, logical-to-physical conversion, and reorder authority are absent.

Fixed-point optimization remains incompatible with `--source-map`. Native CSS `--profile` reports one monotonic public compile total, actual stage intervals, and allocator-requested byte metrics. It does not claim RSS or operating-system memory. Profiling is not exposed across the native preprocessor bridge, so preprocessor requests reject that flag rather than report an incomplete number.

Target prefixing is a separate, narrower authority and is not enabled by `--optimize`. The closed browser names are `chrome`, `edge`, `firefox`, `safari`, `ios_safari`, and `ie`; each entry uses the exact `name >= version` grammar, duplicate browsers and dynamic forms fail, and compatibility data is pinned rather than fetched or discovered from project configuration. The CLI parses one canonical query before dispatch and borrows it immutably across file, stdin, watch, and bounded batch work. Prefixing runs after any optimizer fixed point and remains compatible with deterministic inline source maps. Missing option pairs, malformed queries, and forged API queries fail without partial CSS.

- [Format compatibility](/guide/format-compatibility)
- [Current status](/guide/status)
- [CSS compatibility](/guide/css-compatibility)
- [Build from source](/guide/build-from-source)
