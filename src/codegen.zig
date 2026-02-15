const std = @import("std");
const ast = @import("ast.zig");
const optimizer = @import("optimizer.zig");

pub const CodegenOptions = struct {
    minify: bool = false,
    optimize: bool = false,
};

fn estimateOutputSize(stylesheet: ast.Stylesheet) usize {
    var size: usize = 0;
    for (stylesheet.rules.items) |rule| {
        switch (rule) {
            .style => |style_rule| {
                for (style_rule.selectors.items) |selector| {
                    size += 15;
                    for (selector.parts.items) |part| {
                        size += switch (part) {
                            .type => |s| s.len,
                            .class => |s| s.len + 1,
                            .id => |s| s.len + 1,
                            .universal => 1,
                            .attribute => |attr| attr.name.len + (attr.value orelse "").len + 5,
                            .pseudo_class => |s| s.len + 1,
                            .pseudo_element => |s| s.len + 2,
                            .combinator => 3,
                        };
                    }
                }
                size += 3;
                for (style_rule.declarations.items) |decl| {
                    size += decl.property.len + decl.value.len + 3;
                    if (decl.important) size += 10;
                }
            },
            .at_rule => |at_rule| {
                size += at_rule.name.len + at_rule.prelude.len + 5;
                if (at_rule.rules) |rules| {
                    size += rules.items.len * 25;
                }
            },
        }
    }
    return @max(size, 256);
}

pub fn generate(allocator: std.mem.Allocator, stylesheet: *ast.Stylesheet, options: CodegenOptions) ![]const u8 {
    if (options.optimize) {
        var opt = optimizer.Optimizer.init(allocator);
        try opt.optimize(stylesheet);
    }

    const estimated_size = estimateOutputSize(stylesheet.*);
    var list = try std.ArrayList(u8).initCapacity(allocator, estimated_size);
    errdefer list.deinit(allocator);

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

fn generateStyleRule(list: *std.ArrayList(u8), allocator: std.mem.Allocator, rule: ast.StyleRule, options: CodegenOptions) !void {
    for (rule.selectors.items, 0..) |selector, i| {
        if (i > 0) {
            try list.append(allocator, ',');
            if (!options.minify) {
                try list.append(allocator, ' ');
            }
        }
        try generateSelector(list, allocator, selector, options);
    }

    if (!options.minify) {
        try list.append(allocator, ' ');
    }
    try list.append(allocator, '{');
    if (!options.minify) {
        try list.append(allocator, '\n');
    }

    const decl_count = rule.declarations.items.len;
    for (rule.declarations.items, 0..) |decl, i| {
        if (!options.minify and i > 0) {
            try list.append(allocator, '\n');
        }
        if (!options.minify) {
            try list.appendSlice(allocator, "  ");
        }
        try list.appendSlice(allocator, decl.property);
        try list.append(allocator, ':');
        if (!options.minify) {
            try list.append(allocator, ' ');
        }
        try list.appendSlice(allocator, decl.value);
        if (decl.important) {
            if (!options.minify) {
                try list.append(allocator, ' ');
            }
            try list.appendSlice(allocator, "!important");
        }
        const is_last = i == decl_count - 1;
        if (!is_last or !options.minify) {
            try list.append(allocator, ';');
        }
    }

    if (!options.minify) {
        try list.append(allocator, '\n');
    }
    try list.append(allocator, '}');
}

fn generateSelector(list: *std.ArrayList(u8), allocator: std.mem.Allocator, selector: ast.Selector, options: CodegenOptions) !void {
    _ = options;
    const parts = selector.parts.items;
    if (parts.len == 0) return;
    
    var prev_was_combinator = false;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            const is_combinator = switch (part) {
                .combinator => true,
                else => false,
            };
            if (!is_combinator and !prev_was_combinator) {
                try list.append(allocator, ' ');
            }
            prev_was_combinator = is_combinator;
        } else {
            prev_was_combinator = switch (part) {
                .combinator => true,
                else => false,
            };
        }

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
}

fn generateAttributeSelector(list: *std.ArrayList(u8), allocator: std.mem.Allocator, attr: ast.AttributeSelector) !void {
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

fn generateAtRule(list: *std.ArrayList(u8), allocator: std.mem.Allocator, rule: ast.AtRule, options: CodegenOptions) !void {
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
