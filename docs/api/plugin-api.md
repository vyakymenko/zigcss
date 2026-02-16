# Plugin API

zcss includes a powerful plugin system that allows you to transform the AST during compilation.

## Plugin Structure

```zig
pub const Plugin = struct {
    name: []const u8,
    transform: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void,
    
    pub fn init(name: []const u8, transform_fn: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void) Plugin;
};
```

### Fields

- `name`: Plugin name (for debugging/logging)
- `transform`: Function that transforms the stylesheet AST

### Methods

#### `init(name, transform_fn)`

Creates a new plugin.

**Parameters:**
- `name`: Plugin name
- `transform_fn`: Transform function

**Returns:** `Plugin`

## PluginRegistry

For managing multiple plugins:

```zig
pub const PluginRegistry = struct {
    pub fn init(allocator: std.mem.Allocator) !PluginRegistry;
    pub fn deinit(self: *PluginRegistry) void;
    pub fn add(self: *PluginRegistry, plugin: Plugin) !void;
    pub fn addSlice(self: *PluginRegistry, plugins: []const Plugin) !void;
    pub fn run(self: *const PluginRegistry, stylesheet: *ast.Stylesheet) !void;
    pub fn count(self: *const PluginRegistry) usize;
};
```

### Methods

#### `init(allocator)`

Creates a new plugin registry.

**Parameters:**
- `allocator`: Memory allocator

**Returns:** `PluginRegistry`

#### `deinit()`

Frees memory associated with the registry.

#### `add(plugin)`

Adds a plugin to the registry.

**Parameters:**
- `plugin`: Plugin to add

#### `addSlice(plugins)`

Adds multiple plugins to the registry.

**Parameters:**
- `plugins`: Slice of plugins

#### `run(stylesheet)`

Runs all plugins in order on the stylesheet.

**Parameters:**
- `stylesheet`: Stylesheet AST to transform

#### `count()`

Returns the number of plugins in the registry.

**Returns:** `usize`

## Transform Function Signature

```zig
fn myTransform(allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) !void {
    // Transform the stylesheet AST
    // Use allocator for any allocations
    // Modify stylesheet.rules, etc.
}
```

## Example

```zig
fn addCustomRule(allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) !void {
    var style_rule = try zcss.ast.StyleRule.init(stylesheet.allocator);
    var selector = try zcss.ast.Selector.init(stylesheet.allocator);
    try selector.parts.append(stylesheet.allocator, .{ .class = "custom-class" });
    try style_rule.selectors.append(stylesheet.allocator, selector);
    
    var decl = zcss.ast.Declaration.init(stylesheet.allocator);
    decl.property = "color";
    decl.value = "blue";
    try style_rule.declarations.append(stylesheet.allocator, decl);
    
    try stylesheet.rules.append(stylesheet.allocator, .{ .style = style_rule });
}

const my_plugin = zcss.plugin.Plugin.init("add-custom-rule", addCustomRule);
```

## Plugin Execution Order

Plugins are executed in the order they are added:

1. Parse CSS into AST
2. Run plugins (in order)
3. Run optimizations
4. Generate output

## Best Practices

1. **Keep plugins focused** — Each plugin should do one thing well
2. **Handle errors gracefully** — Use proper error handling
3. **Document your plugins** — Explain what transformations they perform
4. **Test thoroughly** — Ensure plugins work with various CSS inputs
5. **Use the provided allocator** — Don't use a different allocator

## Related

- [Plugin System Guide](/guide/plugins) — Plugin system overview
- [CompileOptions](/api/compile-options) — How to use plugins in compilation
