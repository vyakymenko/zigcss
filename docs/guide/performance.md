# Performance

zcss is engineered to be **the fastest CSS compiler in the world**. This page explains the performance characteristics and optimizations.

## Benchmarks

Performance tested on a MacBook Pro M3 (16GB RAM) with real-world CSS workloads. All tools tested with minification and optimization enabled.

### Small CSS (~100 bytes)

| Compiler | Total Time | Speedup vs zcss |
|----------|------------|-----------------|
| **zcss** | **6.7ms** | 1x (baseline) |
| PostCSS | 546.9ms | **81.6x slower** |
| Sass | 855.0ms | **127.6x slower** |

**zcss is 81-127x faster** than competitors for small files.

### Medium CSS (~10KB, typical production bundle)

| Compiler | Total Time | Speedup vs zcss |
|----------|------------|-----------------|
| **zcss** | **6.7ms** | 1x (baseline) |
| PostCSS | 570.1ms | **85.4x slower** |
| Sass | 589.7ms | **88.2x slower** |

**zcss is 85-88x faster** than competitors for medium-sized files.

### Large CSS (~100KB, complex stylesheet)

| Compiler | Total Time | Speedup vs zcss |
|----------|------------|-----------------|
| **zcss** | **56.0ms** | 1x (baseline) |
| PostCSS | 528.2ms | **9.4x slower** |
| Sass | 634.3ms | **11.3x slower** |

**zcss is 9-11x faster** than competitors for large files.

## Performance Characteristics

- **Throughput**: ~1.8 MB/s for large files (100KB in 56ms)
- **Parsing speed**: ~1,800 rules/second (100KB file with ~1000 rules)
- **Memory efficiency**: Single 468KB binary, no runtime overhead
- **Startup time**: Instant (no VM or interpreter startup)
- **Real-world**: Processes typical 10KB production CSS in **6.7ms** vs 570ms (PostCSS) or 590ms (Sass)

## Why zcss is Faster

### 1. Native Compilation

zcss is compiled to machine code, not interpreted. This eliminates:
- VM startup overhead
- Interpretation overhead
- JIT compilation delays

### 2. Zero-Copy Parsing

Minimal allocations and string interning for efficiency:
- Tokens reference original input without copying
- String interning deduplicates repeated strings
- Arena allocator for fast AST node allocation

### 3. SIMD Optimizations

Vectorized whitespace skipping processes 32 bytes at a time:

```zig
// SIMD-optimized whitespace skipping
while (i + 32 <= input.len) {
    const chunk = std.mem.readInt(u256, input[i..][0..32], .little);
    // Process 32 bytes at once
}
```

### 4. Hash-Based Algorithms

O(n) selector merging vs O(n²) in competitors:

```zig
// Hash-based selector merging
var selector_map = std.HashMap(...);
// O(n) insertion and lookup
```

### 5. No Runtime Overhead

No Node.js, Dart VM, or interpreter startup time:
- Single binary
- Direct system calls
- Minimal memory footprint

## Performance Optimizations

### Compile-Time Optimizations

- Character classification lookup tables computed at compile time
- Comptime optimizations for maximum efficiency

### Runtime Optimizations

- Capacity estimation for ArrayLists (reduces reallocations)
- Optimized character checks (inline functions)
- Faster whitespace skipping
- Output size estimation (accurate pre-allocation)
- String interning for deduplication
- Hash-based selector merging (O(n²) → O(n))
- Backwards iteration for duplicate removal

### Parallel Processing

Multi-threaded compilation for multiple files:

```bash
# Compiles multiple files concurrently
zcss src/*.css -o dist/ --output-dir
```

Utilizes all CPU cores for maximum throughput.

## Profiling

zcss includes built-in profiling tools:

```bash
# Enable profiling
zcss input.css -o output.css --profile
```

Profiling provides:
- Parse timing
- Optimization timing
- Codegen timing
- Memory metrics

## Next Steps

- [Optimization Guide](/guide/optimization) — Learn about CSS optimizations
- [Examples](/examples/css-nesting) — See zcss in action
