const std = @import("std");
const ast = @import("ast.zig");

pub const Plugin = struct {
    name: []const u8,
    transform: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void,

    pub fn init(name: []const u8, transform_fn: *const fn (allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) anyerror!void) Plugin {
        return .{
            .name = name,
            .transform = transform_fn,
        };
    }
};

pub const PluginRegistry = struct {
    plugins: std.ArrayList(Plugin),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PluginRegistry {
        return .{
            .plugins = try std.ArrayList(Plugin).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        self.plugins.deinit(self.allocator);
    }

    pub fn add(self: *PluginRegistry, plugin: Plugin) !void {
        try self.plugins.append(self.allocator, plugin);
    }

    pub fn addSlice(self: *PluginRegistry, plugins_slice: []const Plugin) !void {
        try self.plugins.appendSlice(self.allocator, plugins_slice);
    }

    pub fn run(self: *const PluginRegistry, stylesheet: *ast.Stylesheet) !void {
        for (self.plugins.items) |plugin| {
            try plugin.transform(self.allocator, stylesheet);
        }
    }

    pub fn count(self: *const PluginRegistry) usize {
        return self.plugins.items.len;
    }
};

pub fn createExamplePlugin() Plugin {
    return Plugin.init("example", exampleTransform);
}

fn exampleTransform(allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet) !void {
    _ = allocator;
    _ = stylesheet;
}

test "plugin registry initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.count() == 0);
}

test "plugin registry add and run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const test_plugin = Plugin.init("test", struct {
        fn transform(a: std.mem.Allocator, s: *ast.Stylesheet) !void {
            _ = a;
            _ = s;
        }
    }.transform);

    try registry.add(test_plugin);
    try std.testing.expect(registry.count() == 1);

    var stylesheet = try ast.Stylesheet.init(allocator);
    defer stylesheet.deinit();

    try registry.run(&stylesheet);
}

test "plugin registry multiple plugins" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const plugin1 = Plugin.init("plugin1", struct {
        fn transform(a: std.mem.Allocator, s: *ast.Stylesheet) !void {
            _ = a;
            _ = s;
        }
    }.transform);

    const plugin2 = Plugin.init("plugin2", struct {
        fn transform(a: std.mem.Allocator, s: *ast.Stylesheet) !void {
            _ = a;
            _ = s;
        }
    }.transform);

    try registry.add(plugin1);
    try registry.add(plugin2);
    try std.testing.expect(registry.count() == 2);

    var stylesheet = try ast.Stylesheet.init(allocator);
    defer stylesheet.deinit();

    try registry.run(&stylesheet);
}

test "plugin transforms stylesheet" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const transform_plugin = Plugin.init("transform", struct {
        fn transform(a: std.mem.Allocator, s: *ast.Stylesheet) !void {
            _ = a;
            var style_rule = try ast.StyleRule.init(s.allocator);
            var selector = try ast.Selector.init(s.allocator);
            try selector.parts.append(s.allocator, .{ .class = "test" });
            try style_rule.selectors.append(s.allocator, selector);
            var decl = ast.Declaration.init(s.allocator);
            decl.property = "color";
            decl.value = "red";
            try style_rule.declarations.append(s.allocator, decl);
            try s.rules.append(s.allocator, .{ .style = style_rule });
        }
    }.transform);

    try registry.add(transform_plugin);

    var stylesheet = try ast.Stylesheet.init(allocator);
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 0);
    try registry.run(&stylesheet);
    try std.testing.expect(stylesheet.rules.items.len == 1);
}
