const std = @import("std");
const ast = @import("ast.zig");
const string_pool = @import("string_pool.zig");

pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    pub fn optimize(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        try self.removeEmptyRules(stylesheet);
        try self.mergeSelectors(stylesheet);
        try self.optimizeShorthandProperties(stylesheet);
        try self.removeDuplicateDeclarations(stylesheet);
        try self.optimizeValues(stylesheet);
    }

    fn removeEmptyRules(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        _ = self;
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const should_remove = switch (stylesheet.rules.items[i]) {
                .style => |style_rule| style_rule.declarations.items.len == 0,
                .at_rule => |at_rule| blk: {
                    if (at_rule.rules) |rules| {
                        break :blk rules.items.len == 0;
                    } else {
                        break :blk false;
                    }
                },
            };

            if (should_remove) {
                _ = stylesheet.rules.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn mergeSelectors(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var selector_map = std.AutoHashMap(usize, usize).init(self.allocator);
        defer selector_map.deinit();

        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .style) {
                i += 1;
                continue;
            }

            const selector_hash = self.hashSelectors(&rule.style.selectors);
            const gop = try selector_map.getOrPut(selector_hash);
            
            if (gop.found_existing) {
                const target_idx = gop.value_ptr.*;
                const target_rule = &stylesheet.rules.items[target_idx];
                
                if (target_rule.* == .style and self.selectorsEqual(&target_rule.style.selectors, &rule.style.selectors)) {
                    for (rule.style.declarations.items) |*decl| {
                        try target_rule.style.declarations.append(self.allocator, decl.*);
                    }
                    rule.style.declarations.items.len = 0;
                    rule.deinit();
                    _ = stylesheet.rules.swapRemove(i);
                    continue;
                }
            } else {
                gop.value_ptr.* = i;
            }
            
            i += 1;
        }
    }

    fn hashSelectors(self: *Optimizer, selectors: *std.ArrayList(ast.Selector)) usize {
        _ = self;
        var hash: usize = 0;
        for (selectors.items) |selector| {
            hash = hash * 31 +% selector.parts.items.len;
            for (selector.parts.items) |part| {
                hash = hash * 31 +% @intFromEnum(@as(std.meta.Tag(ast.SelectorPart), part));
                hash = hash * 31 +% switch (part) {
                    .type => |s| std.hash_map.hashString(s),
                    .class => |s| std.hash_map.hashString(s),
                    .id => |s| std.hash_map.hashString(s),
                    .universal => 0,
                    .pseudo_class => |s| std.hash_map.hashString(s),
                    .pseudo_element => |s| std.hash_map.hashString(s),
                    .combinator => |c| @intFromEnum(c),
                    .attribute => |attr| blk: {
                        var h: usize = std.hash_map.hashString(attr.name);
                        if (attr.operator) |op| {
                            h = h * 31 +% std.hash_map.hashString(op);
                        }
                        if (attr.value) |val| {
                            h = h * 31 +% std.hash_map.hashString(val);
                        }
                        h = h * 31 +% @intFromBool(attr.case_sensitive);
                        break :blk h;
                    },
                };
            }
        }
        return hash;
    }

    fn selectorsEqual(self: *Optimizer, a: *std.ArrayList(ast.Selector), b: *std.ArrayList(ast.Selector)) bool {
        if (a.items.len != b.items.len) {
            return false;
        }

        for (a.items, 0..) |selector_a, i| {
            const selector_b = b.items[i];
            if (!self.selectorEqual(&selector_a, &selector_b)) {
                return false;
            }
        }

        return true;
    }

    fn selectorEqual(self: *Optimizer, a: *const ast.Selector, b: *const ast.Selector) bool {
        if (a.parts.items.len != b.parts.items.len) {
            return false;
        }

        for (a.parts.items, b.parts.items) |part_a, part_b| {
            if (!self.selectorPartEqual(&part_a, &part_b)) {
                return false;
            }
        }

        return true;
    }

    fn selectorPartEqual(self: *Optimizer, a: *const ast.SelectorPart, b: *const ast.SelectorPart) bool {
        _ = self;
        if (@as(std.meta.Tag(ast.SelectorPart), a.*) != @as(std.meta.Tag(ast.SelectorPart), b.*)) {
            return false;
        }

        return switch (a.*) {
            .type => |s_a| std.mem.eql(u8, s_a, b.type),
            .class => |s_a| std.mem.eql(u8, s_a, b.class),
            .id => |s_a| std.mem.eql(u8, s_a, b.id),
            .universal => true,
            .pseudo_class => |s_a| std.mem.eql(u8, s_a, b.pseudo_class),
            .pseudo_element => |s_a| std.mem.eql(u8, s_a, b.pseudo_element),
            .combinator => |c_a| c_a == b.combinator,
            .attribute => |attr_a| blk: {
                const attr_b = b.attribute;
                if (!std.mem.eql(u8, attr_a.name, attr_b.name)) break :blk false;
                if (attr_a.operator) |op_a| {
                    if (attr_b.operator) |op_b| {
                        if (!std.mem.eql(u8, op_a, op_b)) break :blk false;
                    } else {
                        break :blk false;
                    }
                } else if (attr_b.operator != null) {
                    break :blk false;
                }
                if (attr_a.value) |val_a| {
                    if (attr_b.value) |val_b| {
                        if (!std.mem.eql(u8, val_a, val_b)) break :blk false;
                    } else {
                        break :blk false;
                    }
                } else if (attr_b.value != null) {
                    break :blk false;
                }
                if (attr_a.case_sensitive != attr_b.case_sensitive) break :blk false;
                break :blk true;
            },
        };
    }

    fn optimizeValues(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.string_pool) |pool| {
            for (stylesheet.rules.items) |*rule| {
                switch (rule.*) {
                    .style => |*style_rule| {
                        for (style_rule.declarations.items) |*decl| {
                            const result = try self.optimizeValue(decl.value);
                            if (result.was_optimized) {
                                const interned = try pool.intern(result.optimized);
                                self.allocator.free(result.optimized);
                                decl.value = interned;
                            }
                        }
                    },
                    .at_rule => |*at_rule| {
                        if (at_rule.rules) |*rules| {
                            for (rules.items) |*nested_rule| {
                                switch (nested_rule.*) {
                                    .style => |*style_rule| {
                                        for (style_rule.declarations.items) |*decl| {
                                            const opt_result = try self.optimizeValue(decl.value);
                                            if (opt_result.was_optimized) {
                                                const interned = try pool.intern(opt_result.optimized);
                                                self.allocator.free(opt_result.optimized);
                                                decl.value = interned;
                                            }
                                        }
                                    },
                                    .at_rule => {},
                                }
                            }
                        }
                    },
                }
            }
        }
    }

    fn optimizeValue(self: *Optimizer, value: []const u8) !struct { optimized: []const u8, was_optimized: bool } {
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        
        if (trimmed.len == 0) return .{ .optimized = value, .was_optimized = false };

        if (self.optimizeRgbColor(trimmed)) |optimized| {
            return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
        }

        if (self.optimizeHexColor(trimmed)) |optimized| {
            if (optimized.len < trimmed.len) {
                return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
            }
        }

        if (self.optimizeColorName(trimmed)) |optimized| {
            return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
        }

        if (self.optimizeTransparent(trimmed)) |optimized| {
            return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
        }

        if (self.optimizeUnit(trimmed)) |optimized| {
            return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
        }

        return .{ .optimized = value, .was_optimized = false };
    }

    fn optimizeTransparent(self: *Optimizer, value: []const u8) ?[]const u8 {
        _ = self;
        if (std.mem.eql(u8, value, "transparent")) {
            return "rgba(0,0,0,0)";
        }
        return null;
    }

    fn optimizeHexColor(self: *Optimizer, value: []const u8) ?[]const u8 {
        _ = self;
        if (value.len == 7 and value[0] == '#') {
            if (value[1] == value[2] and value[3] == value[4] and value[5] == value[6]) {
                return value[0..4];
            }
        }
        if (value.len == 4 and value[0] == '#') {
            return value;
        }
        return null;
    }

    fn optimizeRgbColor(self: *Optimizer, value: []const u8) ?[]const u8 {
        const is_rgba = std.mem.startsWith(u8, value, "rgba(");
        const is_rgb = std.mem.startsWith(u8, value, "rgb(");
        
        if (!is_rgb and !is_rgba) {
            return null;
        }

        const prefix_len: usize = if (is_rgba) 5 else 4;
        
        if (value.len < prefix_len + 1 or value[value.len - 1] != ')') {
            return null;
        }

        const content = value[prefix_len..value.len - 1];
        var parts = std.mem.splitScalar(u8, content, ',');
        
        var r: ?u8 = null;
        var g: ?u8 = null;
        var b: ?u8 = null;
        var a: ?f32 = null;
        var part_idx: usize = 0;

        while (parts.next()) |part| {
            const trimmed_part = std.mem.trim(u8, part, " \t");
            if (part_idx == 0) {
                if (std.fmt.parseInt(u8, trimmed_part, 10)) |val| {
                    r = val;
                } else |_| {
                    return null;
                }
            } else if (part_idx == 1) {
                if (std.fmt.parseInt(u8, trimmed_part, 10)) |val| {
                    g = val;
                } else |_| {
                    return null;
                }
            } else if (part_idx == 2) {
                if (std.fmt.parseInt(u8, trimmed_part, 10)) |val| {
                    b = val;
                } else |_| {
                    return null;
                }
            } else if (part_idx == 3 and is_rgba) {
                if (std.fmt.parseFloat(f32, trimmed_part)) |val| {
                    a = val;
                } else |_| {
                    return null;
                }
            }
            part_idx += 1;
        }

        if (r == null or g == null or b == null) {
            return null;
        }

        if (is_rgba and a != null and a.? != 1.0) {
            return null;
        }

        const r_val = r.?;
        const g_val = g.?;
        const b_val = b.?;

        if (r_val >> 4 == r_val & 0xF and g_val >> 4 == g_val & 0xF and b_val >> 4 == b_val & 0xF) {
            const short_hex = std.fmt.allocPrint(self.allocator, "#{x}{x}{x}", .{ r_val & 0xF, g_val & 0xF, b_val & 0xF }) catch return null;
            return short_hex;
        }

        const hex = std.fmt.allocPrint(self.allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r_val, g_val, b_val }) catch return null;
        return hex;
    }

    fn optimizeColorName(self: *Optimizer, value: []const u8) ?[]const u8 {
        return self.getColorHex(value);
    }

    fn getColorHex(self: *Optimizer, name: []const u8) ?[]const u8 {
        _ = self;
        if (name.len == 0) return null;
        
        const first = name[0];
        if (first >= 'A' and first <= 'Z') {
            return null;
        }
        
        return switch (name.len) {
            3 => if (std.mem.eql(u8, name, "red")) "#f00" else if (std.mem.eql(u8, name, "lime")) "#0f0" else null,
            4 => if (std.mem.eql(u8, name, "blue")) "#00f" else if (std.mem.eql(u8, name, "cyan")) "#0ff" else if (std.mem.eql(u8, name, "aqua")) "#0ff" else if (std.mem.eql(u8, name, "gray")) "#808080" else if (std.mem.eql(u8, name, "teal")) "#008080" else if (std.mem.eql(u8, name, "navy")) "#000080" else null,
            5 => if (std.mem.eql(u8, name, "black")) "#000" else if (std.mem.eql(u8, name, "white")) "#fff" else if (std.mem.eql(u8, name, "green")) "#008000" else if (std.mem.eql(u8, name, "olive")) "#808000" else if (std.mem.eql(u8, name, "maroon")) "#800000" else null,
            6 => if (std.mem.eql(u8, name, "yellow")) "#ff0" else if (std.mem.eql(u8, name, "silver")) "#c0c0c0" else if (std.mem.eql(u8, name, "purple")) "#800080" else null,
            7 => if (std.mem.eql(u8, name, "magenta")) "#f0f" else if (std.mem.eql(u8, name, "fuchsia")) "#f0f" else null,
            else => null,
        };
    }

    fn optimizeUnit(self: *Optimizer, value: []const u8) ?[]const u8 {
        _ = self;
        if (value.len < 2) return null;
        
        const units = [_][]const u8{ "px", "em", "rem", "%", "pt", "pc", "in", "cm", "mm", "ex", "ch", "vw", "vh", "vmin", "vmax" };
        
        for (units) |unit| {
            if (std.mem.endsWith(u8, value, unit)) {
                const num_str = value[0..value.len - unit.len];
                if (std.fmt.parseFloat(f32, num_str)) |num| {
                    if (num == 0.0) {
                        return "0";
                    }
                } else |_| {
                    continue;
                }
            }
        }

        return null;
    }

    fn optimizeShorthandProperties(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        const pool = stylesheet.string_pool;
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    try self.optimizeShorthandInRule(style_rule, pool);
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    try self.optimizeShorthandInRule(style_rule, pool);
                                },
                                .at_rule => {},
                            }
                        }
                    }
                },
            }
        }
    }

    fn optimizeShorthandInRule(self: *Optimizer, style_rule: *ast.StyleRule, pool: ?*string_pool.StringPool) !void {
        var margin_top: ?[]const u8 = null;
        var margin_right: ?[]const u8 = null;
        var margin_bottom: ?[]const u8 = null;
        var margin_left: ?[]const u8 = null;
        
        var padding_top: ?[]const u8 = null;
        var padding_right: ?[]const u8 = null;
        var padding_bottom: ?[]const u8 = null;
        var padding_left: ?[]const u8 = null;
        
        var border_width: ?[]const u8 = null;
        var border_style: ?[]const u8 = null;
        var border_color: ?[]const u8 = null;
        
        var margin_indices = try std.ArrayList(usize).initCapacity(self.allocator, 4);
        defer margin_indices.deinit(self.allocator);
        var padding_indices = try std.ArrayList(usize).initCapacity(self.allocator, 4);
        defer padding_indices.deinit(self.allocator);
        var border_indices = try std.ArrayList(usize).initCapacity(self.allocator, 3);
        defer border_indices.deinit(self.allocator);
        
        for (style_rule.declarations.items, 0..) |*decl, i| {
            if (std.mem.eql(u8, decl.property, "margin-top")) {
                margin_top = decl.value;
                try margin_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "margin-right")) {
                margin_right = decl.value;
                try margin_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "margin-bottom")) {
                margin_bottom = decl.value;
                try margin_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "margin-left")) {
                margin_left = decl.value;
                try margin_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "padding-top")) {
                padding_top = decl.value;
                try padding_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "padding-right")) {
                padding_right = decl.value;
                try padding_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "padding-bottom")) {
                padding_bottom = decl.value;
                try padding_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "padding-left")) {
                padding_left = decl.value;
                try padding_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "border-width")) {
                border_width = decl.value;
                try border_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "border-style")) {
                border_style = decl.value;
                try border_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "border-color")) {
                border_color = decl.value;
                try border_indices.append(self.allocator, i);
            }
        }
        
        if (margin_indices.items.len == 4) {
            const shorthand = try self.buildShorthand(margin_top.?, margin_right.?, margin_bottom.?, margin_left.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "margin";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = margin_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = margin_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
        
        if (padding_indices.items.len == 4) {
            const shorthand = try self.buildShorthand(padding_top.?, padding_right.?, padding_bottom.?, padding_left.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "padding";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = padding_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = padding_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
        
        if (border_indices.items.len == 3) {
            const shorthand = try self.buildBorderShorthand(border_width.?, border_style.?, border_color.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "border";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = border_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = border_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
    }

    fn buildShorthand(self: *Optimizer, top: []const u8, right: []const u8, bottom: []const u8, left: []const u8) ![]const u8 {
        if (std.mem.eql(u8, top, bottom) and std.mem.eql(u8, right, left)) {
            if (std.mem.eql(u8, top, right)) {
                return try std.fmt.allocPrint(self.allocator, "{s}", .{top});
            } else {
                return try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ top, right });
            }
        } else if (std.mem.eql(u8, right, left)) {
            return try std.fmt.allocPrint(self.allocator, "{s} {s} {s}", .{ top, right, bottom });
        } else {
            return try std.fmt.allocPrint(self.allocator, "{s} {s} {s} {s}", .{ top, right, bottom, left });
        }
    }

    fn buildBorderShorthand(self: *Optimizer, width: []const u8, style: []const u8, color: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s} {s} {s}", .{ width, style, color });
    }

    fn removeDuplicateDeclarations(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    try self.removeDuplicatesInRule(style_rule);
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    try self.removeDuplicatesInRule(style_rule);
                                },
                                .at_rule => {},
                            }
                        }
                    }
                },
            }
        }
    }

    fn removeDuplicatesInRule(self: *Optimizer, style_rule: *ast.StyleRule) !void {
        _ = self;
        var seen = std.StringHashMap(void).init(style_rule.allocator);
        defer seen.deinit();

        var i: usize = style_rule.declarations.items.len;
        while (i > 0) {
            i -= 1;
            const property = style_rule.declarations.items[i].property;
            const gop = try seen.getOrPut(property);
            if (gop.found_existing) {
                style_rule.declarations.items[i].deinit();
                _ = style_rule.declarations.swapRemove(i);
            }
        }
    }
};
