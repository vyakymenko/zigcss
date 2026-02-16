# Plugin System

zcss includes a powerful plugin system that allows you to transform the AST during compilation. Plugins run after parsing and before optimization, giving you full control over CSS transformations.

## Basic Plugin Usage

```zig
const std = @import("std");
const zcss = @import("zcss");

fn myTransform(allocator: std.mem.Allocator, stylesheet: *zcss.ast.Stylesheet) !void {
    // Transform the stylesheet AST
    // For example, add a custom rule
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const css = ".container { color: red; }";
    
    const parser_trait = zcss.formats.getParser(.css);
    var stylesheet = try parser_trait.parseFn(allocator, css);
    defer stylesheet.deinit();

    const my_plugin = zcss.plugin.Plugin.init("my-transform", myTransform);
    
    const options = zcss.codegen.CodegenOptions{
        .plugins = &.{my_plugin},
        .optimize = true,
        .minify = true,
    };

    const result = try zcss.codegen.generate(allocator, &stylesheet, options);
    defer allocator.free(result);
    
    std.debug.print("Compiled CSS: {s}\n", .{result});
}
```

## Plugin Registry

For multiple plugins, use the `PluginRegistry`:

```zig
var registry = try zcss.plugin.PluginRegistry.init(allocator);
defer registry.deinit();

const plugin1 = zcss.plugin.Plugin.init("plugin1", transform1);
const plugin2 = zcss.plugin.Plugin.init("plugin2", transform2);

try registry.add(plugin1);
try registry.add(plugin2);

try registry.run(&stylesheet);
```

## Plugin API

### Plugin Structure

```zig
pub const Plugin = struct {
    name: []const u8,
    transform: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void,
    
    pub fn init(name: []const u8, transform_fn: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void) Plugin;
};
```

### PluginRegistry API

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

## Plugin Execution Order

Plugins are executed in the order they are added to the registry:

1. Parse CSS into AST
2. Run plugins (in order)
3. Run optimizations
4. Generate output

## Example: Custom Property Transformer

```zig
fn transformCustomProperties(allocator: std.mem.Allocator, stylesheet: *zcss.ast.Stylesheet) !void {
    // Find all :root rules and extract custom properties
    for (stylesheet.rules.items) |*rule| {
        if (rule.* == .style) {
            const style_rule = &rule.style;
            // Process custom properties
            for (style_rule.declarations.items) |*decl| {
                if (std.mem.startsWith(u8, decl.property, "--")) {
                    // Transform custom property
                }
            }
        }
    }
}

const custom_props_plugin = zcss.plugin.Plugin.init("custom-props", transformCustomProperties);
```

## Best Practices

1. **Keep plugins focused** — Each plugin should do one thing well
2. **Handle errors gracefully** — Use proper error handling
3. **Document your plugins** — Explain what transformations they perform
4. **Test thoroughly** — Ensure plugins work with various CSS inputs

## Next Steps

- [API Reference](/api/plugin-api) — Learn about the plugin API
- [Examples](/examples/css-nesting) — See plugins in action
