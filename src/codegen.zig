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
    
    var selector_needed: usize = 0;
    for (rule.selectors.items) |selector| {
        selector_needed += estimateSelectorSize(selector);
        if (!minify) selector_needed += 2;
    }
    selector_needed += if (!minify) 3 else 1;
    try list.ensureUnusedCapacity(allocator, selector_needed);
    
    for (rule.selectors.items, 0..) |selector, i| {
        if (i > 0) {
            list.appendAssumeCapacity(',');
            if (!minify) {
                list.appendAssumeCapacity(' ');
            }
        }
        try generateSelector(list, allocator, selector, options);
    }

    if (!minify) {
        list.appendAssumeCapacity(' ');
    }
    list.appendAssumeCapacity('{');
    if (!minify) {
        list.appendAssumeCapacity('\n');
    }

    const decl_count = rule.declarations.items.len;
    const last_idx = decl_count - 1;
    
    const total_decl_size = blk: {
        var size: usize = 0;
        for (rule.declarations.items) |decl| {
            size += decl.property.len + decl.value.len + 2;
            if (decl.important) size += 10;
        }
        if (!minify) {
            size += (rule.declarations.items.len * 3) + 1;
        } else {
            size += rule.declarations.items.len - 1;
        }
        break :blk size;
    };
    try list.ensureUnusedCapacity(allocator, total_decl_size);
    
    for (rule.declarations.items, 0..) |decl, i| {
        
        if (!minify) {
            if (i > 0) {
                list.appendAssumeCapacity('\n');
            }
            list.appendSliceAssumeCapacity("  ");
        }
        list.appendSliceAssumeCapacity(decl.property);
        list.appendAssumeCapacity(':');
        if (!minify) {
            list.appendAssumeCapacity(' ');
        }
        list.appendSliceAssumeCapacity(decl.value);
        if (decl.important) {
            if (!minify) {
                list.appendAssumeCapacity(' ');
            }
            list.appendSliceAssumeCapacity("!important");
        }
        if (i != last_idx or !minify) {
            list.appendAssumeCapacity(';');
        }
    }

    if (!minify) {
        list.appendAssumeCapacity('\n');
    }
    list.appendAssumeCapacity('}');
}

fn estimateSelectorSize(selector: ast.Selector) usize {
    var size: usize = 0;
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
    return size;
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
                try list.ensureUnusedCapacity(allocator, 1);
                list.appendAssumeCapacity(' ');
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
        .type => |s| {
            if (list.capacity - list.items.len < s.len) {
                try list.ensureUnusedCapacity(allocator, s.len);
            }
            list.appendSliceAssumeCapacity(s);
        },
        .class => |s| {
            if (list.capacity - list.items.len < s.len + 1) {
                try list.ensureUnusedCapacity(allocator, s.len + 1);
            }
            list.appendAssumeCapacity('.');
            list.appendSliceAssumeCapacity(s);
        },
        .id => |s| {
            if (list.capacity - list.items.len < s.len + 1) {
                try list.ensureUnusedCapacity(allocator, s.len + 1);
            }
            list.appendAssumeCapacity('#');
            list.appendSliceAssumeCapacity(s);
        },
        .universal => {
            if (list.capacity - list.items.len < 1) {
                try list.ensureUnusedCapacity(allocator, 1);
            }
            list.appendAssumeCapacity('*');
        },
        .attribute => |attr| try generateAttributeSelector(list, allocator, attr),
        .pseudo_class => |s| {
            if (list.capacity - list.items.len < s.len + 1) {
                try list.ensureUnusedCapacity(allocator, s.len + 1);
            }
            list.appendAssumeCapacity(':');
            list.appendSliceAssumeCapacity(s);
        },
        .pseudo_element => |s| {
            if (list.capacity - list.items.len < s.len + 2) {
                try list.ensureUnusedCapacity(allocator, s.len + 2);
            }
            list.appendSliceAssumeCapacity("::");
            list.appendSliceAssumeCapacity(s);
        },
        .combinator => |c| {
            const comb_str = c.toString();
            if (list.capacity - list.items.len < comb_str.len) {
                try list.ensureUnusedCapacity(allocator, comb_str.len);
            }
            list.appendSliceAssumeCapacity(comb_str);
        },
    }
}

fn generateAttributeSelector(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, attr: ast.AttributeSelector) !void {
    var needed = attr.name.len + 2;
    if (attr.operator) |op| {
        needed += op.len;
        if (attr.value) |val| {
            needed += val.len + 2;
        }
    }
    if (!attr.case_sensitive) {
        needed += 2;
    }
    try list.ensureUnusedCapacity(allocator, needed);
    
    list.appendAssumeCapacity('[');
    list.appendSliceAssumeCapacity(attr.name);
    if (attr.operator) |op| {
        list.appendSliceAssumeCapacity(op);
        if (attr.value) |val| {
            list.appendAssumeCapacity('"');
            list.appendSliceAssumeCapacity(val);
            list.appendAssumeCapacity('"');
        }
    }
    if (!attr.case_sensitive) {
        list.appendSliceAssumeCapacity(" i");
    }
    list.appendAssumeCapacity(']');
}

fn generateAtRule(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, rule: ast.AtRule, options: CodegenOptions) !void {
    const minify = options.minify;
    var needed = rule.name.len + 1;
    if (rule.prelude.len > 0) {
        needed += rule.prelude.len;
        if (!minify) needed += 1;
    }
    
    if (rule.rules) |rules| {
        needed += if (!minify) 3 else 1;
        for (rules.items) |nested_rule| {
            switch (nested_rule) {
                .style => |style_rule| {
                    needed += estimateStyleRuleSize(style_rule);
                    if (!minify) needed += 2;
                },
                .at_rule => |at_rule| {
                    needed += at_rule.name.len + at_rule.prelude.len + 3;
                    if (!minify) needed += 2;
                },
            }
        }
        if (!minify) needed += 1;
    } else {
        needed += 1;
    }
    
    try list.ensureUnusedCapacity(allocator, needed);
    
    list.appendAssumeCapacity('@');
    list.appendSliceAssumeCapacity(rule.name);
    if (rule.prelude.len > 0) {
        if (!minify) {
            list.appendAssumeCapacity(' ');
        }
        list.appendSliceAssumeCapacity(rule.prelude);
    }

    if (rule.rules) |rules| {
        if (!minify) {
            list.appendAssumeCapacity(' ');
        }
        list.appendAssumeCapacity('{');
        if (!minify) {
            list.appendAssumeCapacity('\n');
        }

        for (rules.items, 0..) |nested_rule, i| {
            if (!minify and i > 0) {
                list.appendAssumeCapacity('\n');
            }

            switch (nested_rule) {
                .style => |style_rule| {
                    if (!minify) {
                        list.appendSliceAssumeCapacity("  ");
                    }
                    try generateStyleRule(list, allocator, style_rule, options);
                },
                .at_rule => |at_rule| {
                    if (!minify) {
                        list.appendSliceAssumeCapacity("  ");
                    }
                    try generateAtRule(list, allocator, at_rule, options);
                },
            }
        }

        if (!minify) {
            list.appendAssumeCapacity('\n');
        }
        list.appendAssumeCapacity('}');
    } else {
        list.appendAssumeCapacity(';');
    }
}
