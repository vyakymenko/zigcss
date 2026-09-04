# Depfile build-system integrations

These four minimal projects compile the single `styles.scss` entry to `styles.css` and let ZigCSS discover `_tokens.scss` through the native import resolver. The generated `styles.css.d` file is the only source of that transitive dependency; none of the build files hard-codes it.

These integrations are for the current `Unreleased` checkout only. Published stable ZigCSS 0.6.0 has no `--depfile` option. Build the current source with Zig 0.15.2 and pass the freshly built `zig-out/bin/zigcss`; do not rely on an unrelated `zigcss` already on `PATH`.

Configure that current binary by absolute path (the Ninja example may instead use a deliberately controlled `PATH`):

```bash
# GNU Make
make ZIGCSS=/absolute/path/to/zigcss

# Ninja (edit the `zigcss` variable or put the binary on PATH)
ninja -f build.ninja

# CMake 3.20+
cmake -S . -B cmake-build -DZIGCSS:FILEPATH=/absolute/path/to/zigcss
cmake --build cmake-build

# Meson 0.47+ with Ninja
meson setup meson-build -Dzigcss=/absolute/path/to/zigcss
meson compile -C meson-build
```

After the first build, an unchanged second build is a no-op. Editing `_tokens.scss` marks `styles.css` dirty through the emitted depfile and causes exactly one recompilation. Authored CSS `@import` statements stay in the CSS output and are intentionally not added to this native dependency graph.

The repository test always checks all four configuration contracts. It runs the clean/no-op/dependency-change scenario for every compatible builder installed on the current host and reports unavailable builders as explicit skips. With `ZIGCSS_REAL_BINARY` set, the same scenario also runs through that exact compiler for GNU Make, Ninja, CMake, and Meson. CI sets `ZIGCSS_REQUIRE_BUILD_SYSTEMS=1`, so GNU Make, Ninja 1.3+, CMake 3.20+, and Meson 0.47+ are all mandatory there and a missing or older tool fails the gate.
