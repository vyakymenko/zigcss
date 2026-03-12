# CompileResult

`CompileResult` contains the result of CSS compilation.

## Structure

```zig
pub const CompileResult = struct {
    css: []const u8,
    source_map: ?[]const u8,
    
    pub fn deinit(self: *const CompileResult, allocator: Allocator) void {
        allocator.free(self.css);
        if (self.source_map) |map| {
            allocator.free(map);
        }
    }
};
```

## Fields

### `css: []const u8`

The compiled CSS output. This is a heap-allocated string that must be freed using `deinit()`.

### `source_map: ?[]const u8`

Optional source map content. Present when `source_map` option is enabled in `CompileOptions`. This is a heap-allocated string that must be freed using `deinit()`.

## Methods

### `deinit(allocator: Allocator)`

Frees all memory associated with the `CompileResult`. Must be called when done with the result to prevent memory leaks.

**Parameters:**
- `allocator`: The allocator used to allocate the result

## Example

```zig
const result = try zigcss.compile(allocator, css, options);
defer result.deinit(allocator);

// Use result.css
std.debug.print("Compiled CSS: {s}\n", .{result.css});

// Use result.source_map if present
if (result.source_map) |map| {
    std.debug.print("Source map: {s}\n", .{map});
}
```

## Memory Management

`CompileResult` owns its memory. Always call `deinit()` when done:

```zig
const result = try zigcss.compile(allocator, css, options);
defer result.deinit(allocator); // Always free memory

// Use result...
```

## Related

- [CompileOptions](/api/compile-options) — Compilation options
- [Plugin API](/api/plugin-api) — Plugin system documentation
