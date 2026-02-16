const std = @import("std");
const ast = @import("ast.zig");
const string_pool = @import("string_pool.zig");
const custom_properties = @import("custom_properties.zig");
const autoprefixer = @import("autoprefixer.zig");

pub const Optimizer = struct {
    allocator: std.mem.Allocator,
    autoprefix_options: ?autoprefixer.AutoprefixOptions = null,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    pub fn initWithAutoprefix(allocator: std.mem.Allocator, autoprefix_opts: autoprefixer.AutoprefixOptions) Optimizer {
        return .{
            .allocator = allocator,
            .autoprefix_options = autoprefix_opts,
        };
    }

    pub fn optimize(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        try self.resolveCustomProperties(stylesheet);
        if (self.autoprefix_options) |opts| {
            try self.addAutoprefixes(stylesheet, opts);
        }
        try self.removeEmptyRules(stylesheet);
        try self.optimizeSelectors(stylesheet);
        try self.mergeSelectors(stylesheet);
        try self.removeRedundantSelectors(stylesheet);
        try self.optimizeShorthandProperties(stylesheet);
        try self.removeDuplicateDeclarations(stylesheet);
        try self.optimizeValues(stylesheet);
        try self.mergeMediaQueries(stylesheet);
        try self.mergeContainerQueries(stylesheet);
    }

    fn addAutoprefixes(self: *Optimizer, stylesheet: *ast.Stylesheet, options: autoprefixer.AutoprefixOptions) !void {
        var prefixer = autoprefixer.Autoprefixer.init(self.allocator, options);
        try prefixer.process(stylesheet);
    }

    fn resolveCustomProperties(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var resolver = custom_properties.CustomPropertyResolver.init(self.allocator, stylesheet.string_pool);
        defer resolver.deinit();
        try resolver.resolve(stylesheet);
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
        var hash: u64 = 0;
        for (selectors.items) |selector| {
            hash = hash *% 31 +% @as(u64, selector.parts.items.len);
            for (selector.parts.items) |part| {
                hash = hash *% 31 +% @as(u64, @intFromEnum(@as(std.meta.Tag(ast.SelectorPart), part)));
                hash = hash *% 31 +% @as(u64, switch (part) {
                    .type => |s| std.hash_map.hashString(s),
                    .class => |s| std.hash_map.hashString(s),
                    .id => |s| std.hash_map.hashString(s),
                    .universal => 0,
                    .pseudo_class => |s| std.hash_map.hashString(s),
                    .pseudo_element => |s| std.hash_map.hashString(s),
                    .combinator => |c| @intFromEnum(c),
                    .attribute => |attr| blk: {
                        var h: u64 = @as(u64, std.hash_map.hashString(attr.name));
                        if (attr.operator) |op| {
                            h = h *% 31 +% @as(u64, std.hash_map.hashString(op));
                        }
                        if (attr.value) |val| {
                            h = h *% 31 +% @as(u64, std.hash_map.hashString(val));
                        }
                        h = h *% 31 +% @intFromBool(attr.case_sensitive);
                        break :blk h;
                    },
                });
            }
        }
        return @as(usize, @intCast(hash));
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
        
        var font_style: ?[]const u8 = null;
        var font_variant: ?[]const u8 = null;
        var font_weight: ?[]const u8 = null;
        var font_size: ?[]const u8 = null;
        var line_height: ?[]const u8 = null;
        var font_family: ?[]const u8 = null;
        
        var background_color: ?[]const u8 = null;
        var background_image: ?[]const u8 = null;
        var background_repeat: ?[]const u8 = null;
        var background_position: ?[]const u8 = null;
        var background_attachment: ?[]const u8 = null;
        
        var margin_indices = try std.ArrayList(usize).initCapacity(self.allocator, 4);
        defer margin_indices.deinit(self.allocator);
        var padding_indices = try std.ArrayList(usize).initCapacity(self.allocator, 4);
        defer padding_indices.deinit(self.allocator);
        var border_indices = try std.ArrayList(usize).initCapacity(self.allocator, 3);
        defer border_indices.deinit(self.allocator);
        var font_indices = try std.ArrayList(usize).initCapacity(self.allocator, 6);
        defer font_indices.deinit(self.allocator);
        var background_indices = try std.ArrayList(usize).initCapacity(self.allocator, 5);
        defer background_indices.deinit(self.allocator);
        
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
            } else if (std.mem.eql(u8, decl.property, "font-style")) {
                font_style = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "font-variant")) {
                font_variant = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "font-weight")) {
                font_weight = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "font-size")) {
                font_size = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "line-height")) {
                line_height = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "font-family")) {
                font_family = decl.value;
                try font_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "background-color")) {
                background_color = decl.value;
                try background_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "background-image")) {
                background_image = decl.value;
                try background_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "background-repeat")) {
                background_repeat = decl.value;
                try background_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "background-position")) {
                background_position = decl.value;
                try background_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "background-attachment")) {
                background_attachment = decl.value;
                try background_indices.append(self.allocator, i);
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
        
        if (font_indices.items.len >= 2 and font_size != null and font_family != null) {
            const shorthand = try self.buildFontShorthand(font_style, font_variant, font_weight, font_size.?, line_height, font_family.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "font";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = font_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = font_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
        
        if (background_indices.items.len >= 2) {
            const shorthand = try self.buildBackgroundShorthand(background_color, background_image, background_repeat, background_position, background_attachment);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "background";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = background_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = background_indices.items[i];
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

    fn buildFontShorthand(self: *Optimizer, style: ?[]const u8, variant: ?[]const u8, weight: ?[]const u8, size: []const u8, line_height: ?[]const u8, family: []const u8) ![]const u8 {
        var parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer parts.deinit(self.allocator);

        if (style) |s| try parts.append(self.allocator, s);
        if (variant) |v| try parts.append(self.allocator, v);
        if (weight) |w| try parts.append(self.allocator, w);
        
        if (line_height) |lh| {
            try parts.append(self.allocator, size);
            try parts.append(self.allocator, "/");
            try parts.append(self.allocator, lh);
        } else {
            try parts.append(self.allocator, size);
        }
        
        try parts.append(self.allocator, family);

        var result = try std.ArrayList(u8).initCapacity(self.allocator, 128);
        defer result.deinit(self.allocator);

        for (parts.items, 0..) |part, i| {
            if (i > 0) {
                try result.append(self.allocator, ' ');
            }
            try result.appendSlice(self.allocator, part);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn buildBackgroundShorthand(self: *Optimizer, color: ?[]const u8, image: ?[]const u8, repeat: ?[]const u8, position: ?[]const u8, attachment: ?[]const u8) ![]const u8 {
        var parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 5);
        defer parts.deinit(self.allocator);

        if (color) |c| try parts.append(self.allocator, c);
        if (image) |img| try parts.append(self.allocator, img);
        if (repeat) |r| try parts.append(self.allocator, r);
        if (attachment) |a| try parts.append(self.allocator, a);
        if (position) |p| try parts.append(self.allocator, p);

        if (parts.items.len == 0) {
            return try self.allocator.dupe(u8, "none");
        }

        var result = try std.ArrayList(u8).initCapacity(self.allocator, 128);
        defer result.deinit(self.allocator);

        for (parts.items, 0..) |part, i| {
            if (i > 0) {
                try result.append(self.allocator, ' ');
            }
            try result.appendSlice(self.allocator, part);
        }

        return try result.toOwnedSlice(self.allocator);
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

    fn optimizeSelectors(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            switch (rule.*) {
                .style => |*style_rule| {
                    var j: usize = 0;
                    while (j < style_rule.selectors.items.len) {
                        const selector = &style_rule.selectors.items[j];
                        if (self.simplifySelector(selector)) {
                            if (selector.parts.items.len == 0) {
                                selector.deinit();
                                _ = style_rule.selectors.swapRemove(j);
                                continue;
                            }
                        }
                        j += 1;
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    var j: usize = 0;
                                    while (j < style_rule.selectors.items.len) {
                                        const selector = &style_rule.selectors.items[j];
                                        if (self.simplifySelector(selector)) {
                                            if (selector.parts.items.len == 0) {
                                                selector.deinit();
                                                _ = style_rule.selectors.swapRemove(j);
                                                continue;
                                            }
                                        }
                                        j += 1;
                                    }
                                },
                                .at_rule => {},
                            }
                        }
                    }
                },
            }
            i += 1;
        }
    }

    fn simplifySelector(self: *Optimizer, selector: *ast.Selector) bool {
        _ = self;
        var modified = false;
        var i: usize = 0;
        
        while (i < selector.parts.items.len) {
            const part = &selector.parts.items[i];
            
            if (part.* == .universal) {
                if (i == 0 and selector.parts.items.len > 1) {
                    const next_part = &selector.parts.items[i + 1];
                    if (next_part.* == .combinator) {
                        selector.parts.items[i].deinit(selector.allocator);
                        _ = selector.parts.swapRemove(i);
                        modified = true;
                        continue;
                    }
                }
                if (i > 0) {
                    const prev_part = &selector.parts.items[i - 1];
                    if (prev_part.* == .combinator) {
                        const combinator = prev_part.combinator;
                        if (combinator == .descendant) {
                            selector.parts.items[i].deinit(selector.allocator);
                            _ = selector.parts.swapRemove(i);
                            modified = true;
                            continue;
                        }
                    }
                }
            }
            
            if (part.* == .combinator) {
                if (i == 0) {
                    selector.parts.items[i].deinit(selector.allocator);
                    _ = selector.parts.swapRemove(i);
                    modified = true;
                    continue;
                }
                if (i + 1 >= selector.parts.items.len) {
                    selector.parts.items[i].deinit(selector.allocator);
                    _ = selector.parts.swapRemove(i);
                    modified = true;
                    continue;
                }
                const prev_part = &selector.parts.items[i - 1];
                const next_part = &selector.parts.items[i + 1];
                if (prev_part.* == .combinator or next_part.* == .combinator) {
                    selector.parts.items[i].deinit(selector.allocator);
                    _ = selector.parts.swapRemove(i);
                    modified = true;
                    continue;
                }
            }
            
            i += 1;
        }
        
        return modified;
    }

    fn calculateSpecificity(self: *Optimizer, selector: *const ast.Selector) struct { ids: u32, classes: u32, elements: u32 } {
        _ = self;
        var ids: u32 = 0;
        var classes: u32 = 0;
        var elements: u32 = 0;
        
        for (selector.parts.items) |part| {
            switch (part) {
                .id => ids += 1,
                .class => classes += 1,
                .attribute => classes += 1,
                .pseudo_class => classes += 1,
                .type => elements += 1,
                .pseudo_element => elements += 1,
                .universal => {},
                .combinator => {},
            }
        }
        
        return .{ .ids = ids, .classes = classes, .elements = elements };
    }

    fn compareSpecificity(self: *Optimizer, a: *const ast.Selector, b: *const ast.Selector) i32 {
        const spec_a = self.calculateSpecificity(a);
        const spec_b = self.calculateSpecificity(b);
        
        if (spec_a.ids != spec_b.ids) {
            return @as(i32, @intCast(spec_a.ids)) - @as(i32, @intCast(spec_b.ids));
        }
        if (spec_a.classes != spec_b.classes) {
            return @as(i32, @intCast(spec_a.classes)) - @as(i32, @intCast(spec_b.classes));
        }
        return @as(i32, @intCast(spec_a.elements)) - @as(i32, @intCast(spec_b.elements));
    }

    fn removeRedundantSelectors(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .style) {
                i += 1;
                continue;
            }

            var j: usize = 0;
            while (j < rule.style.selectors.items.len) {
                const selector = &rule.style.selectors.items[j];
                var is_redundant = false;

                var k: usize = 0;
                while (k < rule.style.selectors.items.len) {
                    if (k == j) {
                        k += 1;
                        continue;
                    }
                    const other = &rule.style.selectors.items[k];
                    if (self.isSelectorSubset(selector, other)) {
                        is_redundant = true;
                        break;
                    }
                    const specificity_diff = self.compareSpecificity(selector, other);
                    if (specificity_diff == 0 and self.selectorEqual(selector, other)) {
                        is_redundant = true;
                        break;
                    }
                    k += 1;
                }

                if (is_redundant) {
                    selector.deinit();
                    _ = rule.style.selectors.swapRemove(j);
                } else {
                    j += 1;
                }
            }

            if (rule.style.selectors.items.len == 0) {
                rule.deinit();
                _ = stylesheet.rules.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn isSelectorSubset(self: *Optimizer, a: *const ast.Selector, b: *const ast.Selector) bool {
        if (a.parts.items.len >= b.parts.items.len) {
            return false;
        }

        var a_idx: usize = 0;
        var b_idx: usize = 0;

        while (a_idx < a.parts.items.len and b_idx < b.parts.items.len) {
            if (self.selectorPartEqual(&a.parts.items[a_idx], &b.parts.items[b_idx])) {
                a_idx += 1;
            }
            b_idx += 1;
        }

        return a_idx == a.parts.items.len;
    }

    fn mergeMediaQueries(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var media_map = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        defer {
            var it = media_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            media_map.deinit();
        }

        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .at_rule or !std.mem.eql(u8, rule.at_rule.name, "media")) {
                i += 1;
                continue;
            }

            const prelude = rule.at_rule.prelude;
            const gop = try media_map.getOrPut(prelude);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.ArrayList(usize).initCapacity(self.allocator, 4);
            }
            try gop.value_ptr.append(self.allocator, i);
            i += 1;
        }

        var indices_to_remove = try std.ArrayList(usize).initCapacity(self.allocator, 8);
        defer indices_to_remove.deinit(self.allocator);

        var it = media_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.items.len > 1) {
                const first_idx = entry.value_ptr.items[0];
                const first_rule = &stylesheet.rules.items[first_idx];
                
                if (first_rule.at_rule.rules == null) {
                    first_rule.at_rule.rules = try std.ArrayList(ast.Rule).initCapacity(self.allocator, 0);
                }
                var merged_rules = &first_rule.at_rule.rules.?;

                var j: usize = 1;
                while (j < entry.value_ptr.items.len) {
                    const other_idx = entry.value_ptr.items[j];
                    try indices_to_remove.append(self.allocator, other_idx);
                    const other_rule = &stylesheet.rules.items[other_idx];
                    
                    if (other_rule.at_rule.rules) |*other_rules| {
                        for (other_rules.items) |nested_rule| {
                            try merged_rules.append(self.allocator, nested_rule);
                        }
                    }
                    j += 1;
                }
            }
        }

        std.mem.sort(usize, indices_to_remove.items, {}, comptime std.sort.desc(usize));
        for (indices_to_remove.items) |idx| {
            stylesheet.rules.items[idx].deinit();
            _ = stylesheet.rules.swapRemove(idx);
        }
    }

    fn mergeContainerQueries(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var container_map = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        defer {
            var it = container_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            container_map.deinit();
        }

        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .at_rule or !std.mem.eql(u8, rule.at_rule.name, "container")) {
                i += 1;
                continue;
            }

            const prelude = rule.at_rule.prelude;
            const gop = try container_map.getOrPut(prelude);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.ArrayList(usize).initCapacity(self.allocator, 4);
            }
            try gop.value_ptr.append(self.allocator, i);
            i += 1;
        }

        var indices_to_remove = try std.ArrayList(usize).initCapacity(self.allocator, 8);
        defer indices_to_remove.deinit(self.allocator);

        var it = container_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.items.len > 1) {
                const first_idx = entry.value_ptr.items[0];
                const first_rule = &stylesheet.rules.items[first_idx];
                
                if (first_rule.at_rule.rules == null) {
                    first_rule.at_rule.rules = try std.ArrayList(ast.Rule).initCapacity(self.allocator, 0);
                }
                var merged_rules = &first_rule.at_rule.rules.?;

                var j: usize = 1;
                while (j < entry.value_ptr.items.len) {
                    const other_idx = entry.value_ptr.items[j];
                    try indices_to_remove.append(self.allocator, other_idx);
                    const other_rule = &stylesheet.rules.items[other_idx];
                    
                    if (other_rule.at_rule.rules) |*other_rules| {
                        for (other_rules.items) |nested_rule| {
                            try merged_rules.append(self.allocator, nested_rule);
                        }
                    }
                    j += 1;
                }
            }
        }

        std.mem.sort(usize, indices_to_remove.items, {}, comptime std.sort.desc(usize));
        for (indices_to_remove.items) |idx| {
            stylesheet.rules.items[idx].deinit();
            _ = stylesheet.rules.swapRemove(idx);
        }
    }
};
