const std = @import("std");
const ast = @import("ast.zig");
const string_pool = @import("string_pool.zig");

pub const CustomPropertyResolver = struct {
    allocator: std.mem.Allocator,
    properties: std.StringHashMap([]const u8),
    string_pool: ?*string_pool.StringPool,

    pub fn init(allocator: std.mem.Allocator, pool: ?*string_pool.StringPool) CustomPropertyResolver {
        return .{
            .allocator = allocator,
            .properties = std.StringHashMap([]const u8).init(allocator),
            .string_pool = pool,
        };
    }

    pub fn deinit(self: *CustomPropertyResolver) void {
        self.properties.deinit();
    }

    pub fn resolve(self: *CustomPropertyResolver, stylesheet: *ast.Stylesheet) !void {
        self.collectProperties(stylesheet);
        try self.substituteVariables(stylesheet);
    }

    fn collectProperties(self: *CustomPropertyResolver, stylesheet: *ast.Stylesheet) void {
        self.collectFromRules(stylesheet.rules.items);
    }

    fn collectFromRules(self: *CustomPropertyResolver, rules: []ast.Rule) void {
        for (rules) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    for (style_rule.declarations.items) |*decl| {
                        if (std.mem.startsWith(u8, decl.property, "--")) {
                            self.properties.put(decl.property, decl.value) catch {};
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        self.collectFromRules(nested_rules.items);
                    }
                },
            }
        }
    }

    fn substituteVariables(self: *CustomPropertyResolver, stylesheet: *ast.Stylesheet) !void {
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    for (style_rule.declarations.items) |*decl| {
                        if (std.mem.indexOf(u8, decl.value, "var(") != null) {
                            decl.value = try self.resolveVarFunction(decl.value);
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        try self.substituteVariablesInRules(nested_rules.items);
                    }
                },
            }
        }
    }

    fn substituteVariablesInRules(self: *CustomPropertyResolver, rules: []ast.Rule) !void {
        for (rules) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    for (style_rule.declarations.items) |*decl| {
                        if (std.mem.indexOf(u8, decl.value, "var(") != null) {
                            decl.value = try self.resolveVarFunction(decl.value);
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        try self.substituteVariablesInRules(nested_rules.items);
                    }
                },
            }
        }
    }

    fn resolveVarFunction(self: *CustomPropertyResolver, value: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, value.len);
        defer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < value.len) {
            if (pos + 4 <= value.len and std.mem.eql(u8, value[pos..pos+4], "var(")) {
                pos += 4;
                
                while (pos < value.len and std.ascii.isWhitespace(value[pos])) {
                    pos += 1;
                }
                
                const var_start = pos;
                while (pos < value.len and value[pos] != ',' and value[pos] != ')') {
                    pos += 1;
                }
                
                const var_name = std.mem.trim(u8, value[var_start..pos], " \t\n\r");
                
                var fallback: ?[]const u8 = null;
                if (pos < value.len and value[pos] == ',') {
                    pos += 1;
                    while (pos < value.len and std.ascii.isWhitespace(value[pos])) {
                        pos += 1;
                    }
                    
                    const fallback_start = pos;
                    var paren_depth: usize = 0;
                    while (pos < value.len) {
                        if (value[pos] == '(') paren_depth += 1;
                        if (value[pos] == ')') {
                            if (paren_depth == 0) break;
                            paren_depth -= 1;
                        }
                        pos += 1;
                    }
                    
                    fallback = std.mem.trim(u8, value[fallback_start..pos], " \t\n\r");
                }
                
                if (pos < value.len and value[pos] == ')') {
                    pos += 1;
                }
                
                if (self.properties.get(var_name)) |resolved_value| {
                    try result.appendSlice(self.allocator, resolved_value);
                } else if (fallback) |fb| {
                    try result.appendSlice(self.allocator, fb);
                } else {
                    try result.appendSlice(self.allocator, "var(");
                    try result.appendSlice(self.allocator, var_name);
                    if (fallback) |fb| {
                        try result.append(self.allocator, ',');
                        try result.appendSlice(self.allocator, fb);
                    }
                    try result.append(self.allocator, ')');
                }
            } else {
                try result.append(self.allocator, value[pos]);
                pos += 1;
            }
        }

        const resolved = try result.toOwnedSlice(self.allocator);
        
        if (self.string_pool) |pool| {
            const interned = try pool.intern(resolved);
            self.allocator.free(resolved);
            return interned;
        } else {
            return resolved;
        }
    }
};

test "resolve custom properties" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try allocator.create(string_pool.StringPool);
    pool.* = string_pool.StringPool.init(allocator);
    defer {
        pool.deinit();
        allocator.destroy(pool);
    }

    var stylesheet = try ast.Stylesheet.init(allocator);
    stylesheet.string_pool = pool;
    stylesheet.owns_string_pool = false;
    defer stylesheet.deinit();

    var root_rule = try ast.StyleRule.init(allocator);

    var color_decl = ast.Declaration.init(allocator);
    color_decl.property = try pool.intern("--primary-color");
    color_decl.value = try pool.intern("#007bff");
    try root_rule.declarations.append(allocator, color_decl);

    var spacing_decl = ast.Declaration.init(allocator);
    spacing_decl.property = try pool.intern("--spacing-unit");
    spacing_decl.value = try pool.intern("8px");
    try root_rule.declarations.append(allocator, spacing_decl);

    var root_selector = try ast.Selector.init(allocator);
    try root_selector.parts.append(allocator, ast.SelectorPart{ .type = try pool.intern(":root") });
    try root_rule.selectors.append(allocator, root_selector);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = root_rule });

    var button_rule = try ast.StyleRule.init(allocator);

    var bg_decl = ast.Declaration.init(allocator);
    bg_decl.property = try pool.intern("background-color");
    bg_decl.value = try pool.intern("var(--primary-color)");
    try button_rule.declarations.append(allocator, bg_decl);

    var padding_decl = ast.Declaration.init(allocator);
    padding_decl.property = try pool.intern("padding");
    padding_decl.value = try pool.intern("var(--spacing-unit)");
    try button_rule.declarations.append(allocator, padding_decl);

    var button_selector = try ast.Selector.init(allocator);
    try button_selector.parts.append(allocator, ast.SelectorPart{ .class = try pool.intern("button") });
    try button_rule.selectors.append(allocator, button_selector);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = button_rule });

    var resolver = CustomPropertyResolver.init(allocator, pool);
    defer resolver.deinit();

    try resolver.resolve(&stylesheet);

    const button_style = stylesheet.rules.items[1].style;
    try std.testing.expect(std.mem.eql(u8, button_style.declarations.items[0].value, "#007bff"));
    try std.testing.expect(std.mem.eql(u8, button_style.declarations.items[1].value, "8px"));
}

test "resolve custom properties with fallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try allocator.create(string_pool.StringPool);
    pool.* = string_pool.StringPool.init(allocator);
    defer {
        pool.deinit();
        allocator.destroy(pool);
    }

    var stylesheet = try ast.Stylesheet.init(allocator);
    stylesheet.string_pool = pool;
    stylesheet.owns_string_pool = false;
    defer stylesheet.deinit();

    var rule = try ast.StyleRule.init(allocator);

    var decl = ast.Declaration.init(allocator);
    decl.property = try pool.intern("color");
    decl.value = try pool.intern("var(--missing-color, red)");
    try rule.declarations.append(allocator, decl);

    var selector = try ast.Selector.init(allocator);
    try selector.parts.append(allocator, ast.SelectorPart{ .type = try pool.intern("div") });
    try rule.selectors.append(allocator, selector);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = rule });

    var resolver = CustomPropertyResolver.init(allocator, pool);
    defer resolver.deinit();

    try resolver.resolve(&stylesheet);

    const style = stylesheet.rules.items[0].style;
    try std.testing.expect(std.mem.eql(u8, style.declarations.items[0].value, "red"));
}
