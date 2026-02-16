const std = @import("std");
const ast = @import("ast.zig");
const optimizer = @import("optimizer.zig");
const autoprefixer = @import("autoprefixer.zig");
const plugin = @import("plugin.zig");

pub const CodegenOptions = struct {
    minify: bool = false,
    optimize: bool = false,
    autoprefix: ?autoprefixer.AutoprefixOptions = null,
    dead_code: ?optimizer.DeadCodeOptions = null,
    critical_css: ?optimizer.CriticalCssOptions = null,
    plugins: []const plugin.Plugin = &.{},
};

fn estimateOutputSize(stylesheet: ast.Stylesheet) usize {
    if (stylesheet.rules.items.len == 0) return 0;
    
    var size: usize = 0;
    for (stylesheet.rules.items) |rule| {
        switch (rule) {
            .style => |style_rule| {
                for (style_rule.selectors.items, 0..) |selector, i| {
                    if (i > 0) size += 2;
                    for (selector.parts.items) |part| {
                        size += switch (part) {
                            .type => |s| s.len,
                            .class => |s| s.len + 1,
                            .id => |s| s.len + 1,
                            .universal => 1,
                            .attribute => |attr| attr.name.len + (attr.value orelse "").len + 6,
                            .pseudo_class => |s| s.len + 1,
                            .pseudo_element => |s| s.len + 2,
                            .combinator => 3,
                        };
                    }
                }
                size += 2;
                const decl_count = style_rule.declarations.items.len;
                for (style_rule.declarations.items, 0..) |decl, i| {
                    size += decl.property.len + decl.value.len + 2;
                    if (decl.important) size += 10;
                    if (i < decl_count - 1) size += 1;
                }
            },
            .at_rule => |at_rule| {
                size += at_rule.name.len + 1;
                if (at_rule.prelude.len > 0) {
                    size += at_rule.prelude.len + 1;
                }
                if (at_rule.rules) |rules| {
                    size += 2;
                    for (rules.items) |nested_rule| {
                        switch (nested_rule) {
                            .style => |style_rule| {
                                size += estimateStyleRuleSize(style_rule);
                            },
                            .at_rule => |nested_at| {
                                size += nested_at.name.len + nested_at.prelude.len + 5;
                            },
                        }
                    }
                } else {
                    size += 1;
                }
            },
        }
    }
    return @max(size, 256);
}

fn estimateStyleRuleSize(style_rule: ast.StyleRule) usize {
    var size: usize = 0;
    for (style_rule.selectors.items, 0..) |selector, i| {
        if (i > 0) size += 2;
        for (selector.parts.items) |part| {
            size += switch (part) {
                .type => |s| s.len,
                .class => |s| s.len + 1,
                .id => |s| s.len + 1,
                .universal => 1,
                .attribute => |attr| attr.name.len + (attr.value orelse "").len + 6,
                .pseudo_class => |s| s.len + 1,
                .pseudo_element => |s| s.len + 2,
                .combinator => 3,
            };
        }
    }
    size += 2;
    const decl_count = style_rule.declarations.items.len;
    for (style_rule.declarations.items, 0..) |decl, i| {
        size += decl.property.len + decl.value.len + 2;
        if (decl.important) size += 10;
        if (i < decl_count - 1) size += 1;
    }
    return size;
}

pub fn generate(allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet, options: CodegenOptions) ![]const u8 {
    if (options.plugins.len > 0) {
        var registry = try plugin.PluginRegistry.init(allocator);
        defer registry.deinit();
        try registry.addSlice(options.plugins);
        try registry.run(stylesheet);
    }

    if (options.optimize or options.autoprefix != null or options.dead_code != null or options.critical_css != null) {
        var opt = if (options.critical_css) |critical_css_opts|
            optimizer.Optimizer.initWithCriticalCss(allocator, critical_css_opts)
        else if (options.dead_code) |dead_code_opts|
            optimizer.Optimizer.initWithDeadCode(allocator, dead_code_opts)
        else if (options.autoprefix) |autoprefix_opts|
            optimizer.Optimizer.initWithAutoprefix(allocator, autoprefix_opts)
        else
            optimizer.Optimizer.init(allocator);
        
        if (options.autoprefix) |autoprefix_opts| {
            opt.autoprefix_options = autoprefix_opts;
        }
        if (options.dead_code) |dead_code_opts| {
            opt.dead_code_options = dead_code_opts;
        }
        if (options.critical_css) |critical_css_opts| {
            opt.critical_css_options = critical_css_opts;
        }
        
        try opt.optimize(stylesheet);
    }

    const estimated_size = estimateOutputSize(stylesheet.*);
    var list = std.ArrayListUnmanaged(u8){};
    try list.ensureTotalCapacity(allocator, estimated_size);
    errdefer list.deinit(allocator);

    if (stylesheet.rules.items.len == 0) {
        return try list.toOwnedSlice(allocator);
    }
    
    for (stylesheet.rules.items, 0..) |rule, i| {
        if (i > 0 and !options.minify) {
            try list.append(allocator, '\n');
        }

        switch (rule) {
            .style => |style_rule| {
                try generateStyleRule(&list, allocator, style_rule, options);
            },
            .at_rule => |at_rule| {
                try generateAtRule(&list, allocator, at_rule, options);
            },
        }
    }

    return try list.toOwnedSlice(allocator);
}

fn generateStyleRule(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, rule: ast.StyleRule, options: CodegenOptions) !void {
    if (rule.selectors.items.len == 0) return;
    if (rule.declarations.items.len == 0) return;
    
    const minify = options.minify;
    
    for (rule.selectors.items, 0..) |selector, i| {
        if (i > 0) {
            try list.append(allocator, ',');
            if (!minify) {
                try list.append(allocator, ' ');
            }
        }
        try generateSelector(list, allocator, selector, options);
    }

    if (!minify) {
        try list.append(allocator, ' ');
    }
    try list.append(allocator, '{');
    if (!minify) {
        try list.append(allocator, '\n');
    }

    const decl_count = rule.declarations.items.len;
    const last_idx = decl_count - 1;
    
    for (rule.declarations.items, 0..) |decl, i| {
        if (!minify) {
            if (i > 0) {
                try list.append(allocator, '\n');
            }
            try list.appendSlice(allocator, "  ");
        }
        try list.appendSlice(allocator, decl.property);
        try list.append(allocator, ':');
        if (!minify) {
            try list.append(allocator, ' ');
        }
        try list.appendSlice(allocator, decl.value);
        if (decl.important) {
            if (!minify) {
                try list.append(allocator, ' ');
            }
            try list.appendSlice(allocator, "!important");
        }
        if (i != last_idx or !minify) {
            try list.append(allocator, ';');
        }
    }

    if (!minify) {
        try list.append(allocator, '\n');
    }
    try list.append(allocator, '}');
}

fn generateSelector(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, selector: ast.Selector, options: CodegenOptions) !void {
    _ = options;
    const parts = selector.parts.items;
    if (parts.len == 0) return;
    if (parts.len == 1) {
        try generateSelectorPart(list, allocator, parts[0]);
        return;
    }

    var prev_was_combinator = false;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            const is_combinator = part == .combinator;
            if (!is_combinator and !prev_was_combinator) {
                try list.append(allocator, ' ');
            }
            prev_was_combinator = is_combinator;
        } else {
            prev_was_combinator = part == .combinator;
        }

        try generateSelectorPart(list, allocator, part);
    }
}

fn generateSelectorPart(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, part: ast.SelectorPart) !void {
    switch (part) {
        .type => |s| try list.appendSlice(allocator, s),
        .class => |s| {
            try list.append(allocator, '.');
            try list.appendSlice(allocator, s);
        },
        .id => |s| {
            try list.append(allocator, '#');
            try list.appendSlice(allocator, s);
        },
        .universal => try list.append(allocator, '*'),
        .attribute => |attr| try generateAttributeSelector(list, allocator, attr),
        .pseudo_class => |s| {
            try list.append(allocator, ':');
            try list.appendSlice(allocator, s);
        },
        .pseudo_element => |s| {
            try list.appendSlice(allocator, "::");
            try list.appendSlice(allocator, s);
        },
        .combinator => |c| try list.appendSlice(allocator, c.toString()),
    }
}

fn generateAttributeSelector(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, attr: ast.AttributeSelector) !void {
    try list.append(allocator, '[');
    try list.appendSlice(allocator, attr.name);
    if (attr.operator) |op| {
        try list.appendSlice(allocator, op);
        if (attr.value) |val| {
            try list.append(allocator, '"');
            try list.appendSlice(allocator, val);
            try list.append(allocator, '"');
        }
    }
    if (!attr.case_sensitive) {
        try list.appendSlice(allocator, " i");
    }
    try list.append(allocator, ']');
}

fn generateAtRule(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, rule: ast.AtRule, options: CodegenOptions) !void {
    try list.append(allocator, '@');
    try list.appendSlice(allocator, rule.name);
    if (rule.prelude.len > 0) {
        if (!options.minify) {
            try list.append(allocator, ' ');
        }
        try list.appendSlice(allocator, rule.prelude);
    }

    if (rule.rules) |rules| {
        if (!options.minify) {
            try list.append(allocator, ' ');
        }
        try list.append(allocator, '{');
        if (!options.minify) {
            try list.append(allocator, '\n');
        }

        for (rules.items, 0..) |nested_rule, i| {
            if (!options.minify and i > 0) {
                try list.append(allocator, '\n');
            }

            switch (nested_rule) {
                .style => |style_rule| {
                    if (!options.minify) {
                        try list.appendSlice(allocator, "  ");
                    }
                    try generateStyleRule(list, allocator, style_rule, options);
                },
                .at_rule => |at_rule| {
                    if (!options.minify) {
                        try list.appendSlice(allocator, "  ");
                    }
                    try generateAtRule(list, allocator, at_rule, options);
                },
            }
        }

        if (!options.minify) {
            try list.append(allocator, '\n');
        }
        try list.append(allocator, '}');
    } else {
        try list.append(allocator, ';');
    }
}
