const std = @import("std");
const ast = @import("ast.zig");

pub const CodegenOptions = struct {
    minify: bool = false,
    optimize: bool = false,
};

pub fn generate(allocator: std.mem.Allocator, stylesheet: ast.Stylesheet, options: CodegenOptions) ![]const u8 {
    _ = options;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    for (stylesheet.rules.items, 0..) |rule, i| {
        if (i > 0 and !options.minify) {
            try list.append('\n');
        }

        switch (rule) {
            .style => |style_rule| {
                try generateStyleRule(&list, style_rule, options);
            },
            .at_rule => |at_rule| {
                try generateAtRule(&list, at_rule, options);
            },
        }
    }

    return list.toOwnedSlice();
}

fn generateStyleRule(list: *std.ArrayList(u8), rule: ast.StyleRule, options: CodegenOptions) !void {
    for (rule.selectors.items, 0..) |selector, i| {
        if (i > 0) {
            try list.append(',');
            if (!options.minify) {
                try list.append(' ');
            }
        }
        try generateSelector(list, selector, options);
    }

    if (!options.minify) {
        try list.append(' ');
    }
    try list.append('{');
    if (!options.minify) {
        try list.append('\n');
    }

    for (rule.declarations.items, 0..) |decl, i| {
        if (!options.minify and i > 0) {
            try list.append('\n');
        }
        if (!options.minify) {
            try list.appendSlice("  ");
        }
        try list.appendSlice(decl.property);
        try list.append(':');
        if (!options.minify) {
            try list.append(' ');
        }
        try list.appendSlice(decl.value);
        if (decl.important) {
            if (!options.minify) {
                try list.append(' ');
            }
            try list.appendSlice("!important");
        }
        try list.append(';');
    }

    if (!options.minify) {
        try list.append('\n');
    }
    try list.append('}');
}

fn generateSelector(list: *std.ArrayList(u8), selector: ast.Selector, options: CodegenOptions) !void {
    _ = options;
    for (selector.parts.items, 0..) |part, i| {
        if (i > 0) {
            const needs_space = switch (part) {
                .combinator => false,
                else => true,
            };
            if (needs_space and i > 0) {
                const prev_part = selector.parts.items[i - 1];
                const is_combinator = switch (prev_part) {
                    .combinator => true,
                    else => false,
                };
                if (!is_combinator) {
                    try list.append(' ');
                }
            }
        }

        switch (part) {
            .type => |s| try list.appendSlice(s),
            .class => |s| {
                try list.append('.');
                try list.appendSlice(s);
            },
            .id => |s| {
                try list.append('#');
                try list.appendSlice(s);
            },
            .universal => try list.append('*'),
            .attribute => |attr| try generateAttributeSelector(list, attr),
            .pseudo_class => |s| {
                try list.append(':');
                try list.appendSlice(s);
            },
            .pseudo_element => |s| {
                try list.appendSlice("::");
                try list.appendSlice(s);
            },
            .combinator => |c| try list.appendSlice(c.toString()),
        }
    }
}

fn generateAttributeSelector(list: *std.ArrayList(u8), attr: ast.AttributeSelector) !void {
    try list.append('[');
    try list.appendSlice(attr.name);
    if (attr.operator) |op| {
        try list.appendSlice(op);
        if (attr.value) |val| {
            try list.append('"');
            try list.appendSlice(val);
            try list.append('"');
        }
    }
    if (!attr.case_sensitive) {
        try list.appendSlice(" i");
    }
    try list.append(']');
}

fn generateAtRule(list: *std.ArrayList(u8), rule: ast.AtRule, options: CodegenOptions) !void {
    try list.append('@');
    try list.appendSlice(rule.name);
    if (rule.prelude.len > 0) {
        if (!options.minify) {
            try list.append(' ');
        }
        try list.appendSlice(rule.prelude);
    }

    if (rule.rules) |rules| {
        if (!options.minify) {
            try list.append(' ');
        }
        try list.append('{');
        if (!options.minify) {
            try list.append('\n');
        }

        for (rules.items, 0..) |nested_rule, i| {
            if (!options.minify and i > 0) {
                try list.append('\n');
            }

            switch (nested_rule) {
                .style => |style_rule| {
                    if (!options.minify) {
                        try list.appendSlice("  ");
                    }
                    try generateStyleRule(list, style_rule, options);
                },
                .at_rule => |at_rule| {
                    if (!options.minify) {
                        try list.appendSlice("  ");
                    }
                    try generateAtRule(list, at_rule, options);
                },
            }
        }

        if (!options.minify) {
            try list.append('\n');
        }
        try list.append('}');
    } else {
        try list.append(';');
    }
}
