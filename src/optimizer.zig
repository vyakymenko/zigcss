const std = @import("std");
const ast = @import("ast.zig");
const string_pool = @import("string_pool.zig");
const custom_properties = @import("custom_properties.zig");
const autoprefixer = @import("autoprefixer.zig");

pub const DeadCodeOptions = struct {
    used_classes: ?[]const []const u8 = null,
    used_ids: ?[]const []const u8 = null,
    used_elements: ?[]const []const u8 = null,
    used_attributes: ?[]const []const u8 = null,
};

pub const CriticalCssOptions = struct {
    critical_classes: ?[]const []const u8 = null,
    critical_ids: ?[]const []const u8 = null,
    critical_elements: ?[]const []const u8 = null,
    critical_attributes: ?[]const []const u8 = null,
};

pub const Optimizer = struct {
    allocator: std.mem.Allocator,
    autoprefix_options: ?autoprefixer.AutoprefixOptions = null,
    dead_code_options: ?DeadCodeOptions = null,
    critical_css_options: ?CriticalCssOptions = null,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    pub fn initWithAutoprefix(allocator: std.mem.Allocator, autoprefix_opts: autoprefixer.AutoprefixOptions) Optimizer {
        return .{
            .allocator = allocator,
            .autoprefix_options = autoprefix_opts,
        };
    }

    pub fn initWithDeadCode(allocator: std.mem.Allocator, dead_code_opts: DeadCodeOptions) Optimizer {
        return .{
            .allocator = allocator,
            .dead_code_options = dead_code_opts,
        };
    }

    pub fn initWithCriticalCss(allocator: std.mem.Allocator, critical_css_opts: CriticalCssOptions) Optimizer {
        return .{
            .allocator = allocator,
            .critical_css_options = critical_css_opts,
        };
    }

    pub fn optimize(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        var used_properties = std.StringHashMap(void).init(self.allocator);
        defer used_properties.deinit();
        self.collectUsedCustomPropertiesBeforeResolve(stylesheet, &used_properties);
        try self.resolveCustomProperties(stylesheet);
        try self.removeUnusedCustomProperties(stylesheet, &used_properties);
        if (self.autoprefix_options) |opts| {
            try self.addAutoprefixes(stylesheet, opts);
        }
        try self.removeEmptyRules(stylesheet);
        if (self.dead_code_options) |_| {
            try self.removeDeadCode(stylesheet);
        }
        if (self.critical_css_options) |_| {
            try self.extractCriticalCss(stylesheet);
        }
        if (stylesheet.rules.items.len > 0) {
            try self.optimizeSelectors(stylesheet);
            try self.mergeSelectors(stylesheet);
            try self.removeRedundantSelectors(stylesheet);
            try self.optimizeLogicalProperties(stylesheet);
            try self.optimizeShorthandProperties(stylesheet);
            try self.removeDuplicateDeclarations(stylesheet);
            try self.optimizeValues(stylesheet);
            try self.reorderAtRules(stylesheet);
            try self.mergeMediaQueries(stylesheet);
            try self.mergeContainerQueries(stylesheet);
            try self.mergeCascadeLayers(stylesheet);
        }
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

    fn removeUnusedCustomProperties(self: *Optimizer, stylesheet: *ast.Stylesheet, used_properties: *std.StringHashMap(void)) !void {
        if (stylesheet.rules.items.len == 0) return;
        if (used_properties.count() == 0) return;
        
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len == 0) continue;
                    var i: usize = 0;
                    while (i < style_rule.declarations.items.len) {
                        const decl = &style_rule.declarations.items[i];
                        if (decl.property.len >= 2 and decl.property[0] == '-' and decl.property[1] == '-') {
                            if (!used_properties.contains(decl.property)) {
                                _ = style_rule.declarations.swapRemove(i);
                            } else {
                                i += 1;
                            }
                        } else {
                            i += 1;
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        self.removeUnusedCustomPropertiesFromRules(nested_rules.items, used_properties);
                    }
                },
            }
        }
    }

    fn removeUnusedCustomPropertiesFromRules(self: *Optimizer, rules: []ast.Rule, used_properties: *const std.StringHashMap(void)) void {
        if (rules.len == 0) return;
        if (used_properties.count() == 0) return;
        
        for (rules) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len == 0) continue;
                    var i: usize = 0;
                    while (i < style_rule.declarations.items.len) {
                        const decl = &style_rule.declarations.items[i];
                        if (decl.property.len >= 2 and decl.property[0] == '-' and decl.property[1] == '-') {
                            if (!used_properties.contains(decl.property)) {
                                _ = style_rule.declarations.swapRemove(i);
                            } else {
                                i += 1;
                            }
                        } else {
                            i += 1;
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        self.removeUnusedCustomPropertiesFromRules(nested_rules.items, used_properties);
                    }
                },
            }
        }
    }

    fn collectUsedCustomPropertiesBeforeResolve(self: *Optimizer, stylesheet: *ast.Stylesheet, used_properties: *std.StringHashMap(void)) void {
        if (stylesheet.rules.items.len == 0) return;
        
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len == 0) continue;
                    for (style_rule.declarations.items) |*decl| {
                        if (decl.value.len >= 4 and std.mem.indexOf(u8, decl.value, "var(") != null) {
                            self.extractCustomPropertyNames(decl.value, used_properties);
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        if (nested_rules.items.len > 0) {
                            self.collectUsedCustomPropertiesFromRules(nested_rules.items, used_properties);
                        }
                    }
                },
            }
        }
    }

    fn collectUsedCustomPropertiesFromRules(self: *Optimizer, rules: []ast.Rule, used_properties: *std.StringHashMap(void)) void {
        if (rules.len == 0) return;
        
        for (rules) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len == 0) continue;
                    for (style_rule.declarations.items) |*decl| {
                        if (decl.value.len >= 4 and std.mem.indexOf(u8, decl.value, "var(") != null) {
                            self.extractCustomPropertyNames(decl.value, used_properties);
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*nested_rules| {
                        if (nested_rules.items.len > 0) {
                            self.collectUsedCustomPropertiesFromRules(nested_rules.items, used_properties);
                        }
                    }
                },
            }
        }
    }

    fn extractCustomPropertyNames(self: *Optimizer, value: []const u8, used_properties: *std.StringHashMap(void)) void {
        _ = self;
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
                used_properties.put(var_name, {}) catch {};
                
                if (pos < value.len and value[pos] == ',') {
                    pos += 1;
                    var paren_depth: usize = 0;
                    while (pos < value.len) {
                        if (value[pos] == '(') paren_depth += 1;
                        if (value[pos] == ')') {
                            if (paren_depth == 0) break;
                            paren_depth -= 1;
                        }
                        pos += 1;
                    }
                }
                
                if (pos < value.len and value[pos] == ')') {
                    pos += 1;
                }
            } else {
                pos += 1;
            }
        }
    }

    fn removeEmptyRules(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        _ = self;
        if (stylesheet.rules.items.len == 0) return;
        
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
        if (stylesheet.rules.items.len <= 1) return;
        
        const estimated_capacity = @as(u32, @intCast(@min(stylesheet.rules.items.len / 2, std.math.maxInt(u32))));
        var selector_map = std.AutoHashMap(usize, usize).init(self.allocator);
        try selector_map.ensureTotalCapacity(estimated_capacity);
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
                    const decl_count = rule.style.declarations.items.len;
                    if (decl_count > 0) {
                        try target_rule.style.declarations.ensureUnusedCapacity(self.allocator, decl_count);
                        for (rule.style.declarations.items) |*decl| {
                            try target_rule.style.declarations.append(self.allocator, decl.*);
                        }
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
        if (selectors.items.len == 0) return 0;
        
        var hash: u64 = 0;
        const selector_count = selectors.items.len;
        hash = hash *% 31 +% @as(u64, selector_count);
        
        for (selectors.items) |selector| {
            const part_count = selector.parts.items.len;
            hash = hash *% 31 +% @as(u64, part_count);
            if (part_count == 0) continue;
            
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
        if (stylesheet.rules.items.len == 0) return;
        if (stylesheet.string_pool == null) return;
        
        var has_optimizable = false;
        for (stylesheet.rules.items) |rule| {
            switch (rule) {
                .style => |style_rule| {
                    for (style_rule.declarations.items) |decl| {
                        if (decl.value.len >= 3) {
                            const first = decl.value[0];
                            if (first == '#' or first == 'r' or first == 't' or first == 'c' or std.ascii.isDigit(first)) {
                                has_optimizable = true;
                                break;
                            }
                        }
                    }
                    if (has_optimizable) break;
                },
                .at_rule => {},
            }
        }
        if (!has_optimizable) return;
        
        if (stylesheet.string_pool) |pool| {
            for (stylesheet.rules.items) |*rule| {
                switch (rule.*) {
                    .style => |*style_rule| {
                        if (style_rule.declarations.items.len == 0) continue;
                        for (style_rule.declarations.items) |*decl| {
                            if (decl.value.len == 0) continue;
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
                            if (rules.items.len == 0) continue;
                            for (rules.items) |*nested_rule| {
                                switch (nested_rule.*) {
                                    .style => |*style_rule| {
                                        if (style_rule.declarations.items.len == 0) continue;
                                        for (style_rule.declarations.items) |*decl| {
                                            if (decl.value.len == 0) continue;
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
        if (value.len == 0) return .{ .optimized = value, .was_optimized = false };
        
        const first_char = value[0];
        if (value.len < 3) return .{ .optimized = value, .was_optimized = false };
        
        const needs_trimming = std.ascii.isWhitespace(first_char) or std.ascii.isWhitespace(value[value.len - 1]);
        const trimmed = if (needs_trimming) std.mem.trim(u8, value, " \t\n\r") else value;
        
        if (trimmed.len == 0) return .{ .optimized = value, .was_optimized = false };
        if (trimmed.len < 3) return .{ .optimized = value, .was_optimized = false };
        
        const trimmed_first = trimmed[0];
        
        if (trimmed_first == 'r' and (trimmed.len >= 4)) {
            if (self.optimizeRgbColor(trimmed)) |optimized| {
                return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
            }
        }
        
        if (trimmed_first == '#') {
            if (self.optimizeHexColor(trimmed)) |optimized| {
                if (optimized.len < trimmed.len) {
                    return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
                }
            }
        }
        
        if (trimmed_first == 't' and trimmed.len == 11) {
            if (self.optimizeTransparent(trimmed)) |optimized| {
                return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
            }
        }
        
        if (trimmed_first == 'c' and trimmed.len >= 5) {
            if (self.optimizeMathFunction(trimmed)) |optimized| {
                return .{ .optimized = optimized, .was_optimized = true };
            }
        }
        
        if (self.optimizeColorName(trimmed)) |optimized| {
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
        if (value.len < 5) return null;
        
        const is_rgba = value.len >= 6 and std.mem.eql(u8, value[0..5], "rgba(");
        const is_rgb = std.mem.eql(u8, value[0..4], "rgb(");
        
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

    fn optimizeMathFunction(self: *Optimizer, value: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, value, "calc(")) {
            return self.optimizeCalc(value);
        }
        if (std.mem.startsWith(u8, value, "min(")) {
            return self.optimizeMinMax(value, "min");
        }
        if (std.mem.startsWith(u8, value, "max(")) {
            return self.optimizeMinMax(value, "max");
        }
        if (std.mem.startsWith(u8, value, "clamp(")) {
            return self.optimizeClamp(value);
        }
        return null;
    }

    fn optimizeCalc(self: *Optimizer, value: []const u8) ?[]const u8 {
        if (value.len < 6 or value[value.len - 1] != ')') {
            return null;
        }

        const content = std.mem.trim(u8, value[5..value.len - 1], " \t\n\r");
        if (content.len == 0) {
            return null;
        }

        if (self.evaluateMathExpression(content)) |result| {
            return result;
        }

        if (self.canRemoveCalcWrapper(content)) {
            const optimized = self.allocator.dupe(u8, content) catch return null;
            return optimized;
        }

        return null;
    }

    fn optimizeMinMax(self: *Optimizer, value: []const u8, func_name: []const u8) ?[]const u8 {
        const func_len = func_name.len;
        if (value.len < func_len + 2 or value[value.len - 1] != ')') {
            return null;
        }

        const content = std.mem.trim(u8, value[func_len + 1..value.len - 1], " \t\n\r");
        if (content.len == 0) {
            return null;
        }

        var args = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return null;
        defer args.deinit(self.allocator);

        var depth: i32 = 0;
        var start: usize = 0;
        var i: usize = 0;

        while (i < content.len) {
            const ch = content[i];
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
            } else if (ch == ',' and depth == 0) {
                const arg = std.mem.trim(u8, content[start..i], " \t\n\r");
                if (arg.len > 0) {
                    args.append(self.allocator, arg) catch return null;
                }
                start = i + 1;
            }
            i += 1;
        }

        if (start < content.len) {
            const arg = std.mem.trim(u8, content[start..], " \t\n\r");
            if (arg.len > 0) {
                args.append(self.allocator, arg) catch return null;
            }
        }

        if (args.items.len == 0) {
            return null;
        }

        var evaluated_args = std.ArrayList(?f64).initCapacity(self.allocator, 4) catch return null;
        defer evaluated_args.deinit(self.allocator);

        var all_numeric = true;
        for (args.items) |arg| {
            if (self.parseNumericValue(arg)) |num| {
                evaluated_args.append(self.allocator, num) catch return null;
            } else {
                evaluated_args.append(self.allocator, null) catch return null;
                all_numeric = false;
            }
        }

        if (all_numeric and evaluated_args.items.len > 0) {
            var result: f64 = evaluated_args.items[0].?;
            for (evaluated_args.items[1..]) |maybe_num| {
                if (maybe_num) |num| {
                    if (std.mem.eql(u8, func_name, "min")) {
                        result = @min(result, num);
                    } else {
                        result = @max(result, num);
                    }
                }
            }

            const optimized = self.formatNumericValue(result) catch return null;
            return optimized;
        }

        return null;
    }

    fn optimizeClamp(self: *Optimizer, value: []const u8) ?[]const u8 {
        if (value.len < 7 or value[value.len - 1] != ')') {
            return null;
        }

        const content = std.mem.trim(u8, value[6..value.len - 1], " \t\n\r");
        if (content.len == 0) {
            return null;
        }

        var args = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return null;
        defer args.deinit(self.allocator);

        var depth: i32 = 0;
        var start: usize = 0;
        var i: usize = 0;

        while (i < content.len) {
            const ch = content[i];
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
            } else if (ch == ',' and depth == 0) {
                const arg = std.mem.trim(u8, content[start..i], " \t\n\r");
                if (arg.len > 0) {
                    args.append(self.allocator, arg) catch return null;
                }
                start = i + 1;
            }
            i += 1;
        }

        if (start < content.len) {
            const arg = std.mem.trim(u8, content[start..], " \t\n\r");
            if (arg.len > 0) {
                args.append(self.allocator, arg) catch return null;
            }
        }

        if (args.items.len != 3) {
            return null;
        }

        const min_val = self.parseNumericValue(args.items[0]);
        const preferred_val = self.parseNumericValue(args.items[1]);
        const max_val = self.parseNumericValue(args.items[2]);

        if (min_val != null and preferred_val != null and max_val != null) {
            const min = min_val.?;
            const preferred = preferred_val.?;
            const max = max_val.?;

            const result = if (preferred < min) min else if (preferred > max) max else preferred;
            const optimized = self.formatNumericValue(result) catch return null;
            return optimized;
        }

        return null;
    }

    fn evaluateMathExpression(self: *Optimizer, expr: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (trimmed.len == 0) {
            return null;
        }

        var parts = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch return null;
        defer parts.deinit(self.allocator);

        var operators = std.ArrayList(u8).initCapacity(self.allocator, 4) catch return null;
        defer operators.deinit(self.allocator);

        var i: usize = 0;
        var start: usize = 0;
        var depth: i32 = 0;

        while (i < trimmed.len) {
            const ch = trimmed[i];
            if (ch == '(') {
                depth += 1;
                i += 1;
            } else if (ch == ')') {
                depth -= 1;
                i += 1;
            } else if ((ch == '+' or ch == '-' or ch == '*' or ch == '/') and depth == 0) {
                if (i > start) {
                    const part = std.mem.trim(u8, trimmed[start..i], " \t\n\r");
                    if (part.len > 0) {
                        parts.append(self.allocator, part) catch return null;
                    }
                }
                operators.append(self.allocator, ch) catch return null;
                i += 1;
                start = i;
            } else {
                i += 1;
            }
        }

        if (start < trimmed.len) {
            const part = std.mem.trim(u8, trimmed[start..], " \t\n\r");
            if (part.len > 0) {
                parts.append(self.allocator, part) catch return null;
            }
        }

        if (parts.items.len == 0) {
            return null;
        }

        if (parts.items.len == 1) {
            const num = self.parseNumericValue(parts.items[0]) orelse return null;
            return self.formatNumericValue(num) catch null;
        }

        if (parts.items.len != operators.items.len + 1) {
            return null;
        }

        var values = std.ArrayList(f64).initCapacity(self.allocator, 4) catch return null;
        defer values.deinit(self.allocator);

        for (parts.items) |part| {
            const num = self.parseNumericValue(part) orelse return null;
            values.append(self.allocator, num) catch return null;
        }

        var result = values.items[0];
        for (operators.items, 1..) |op, idx| {
            const next_val = values.items[idx];
            result = switch (op) {
                '+' => result + next_val,
                '-' => result - next_val,
                '*' => result * next_val,
                '/' => if (next_val != 0) result / next_val else return null,
                else => return null,
            };
        }

        return self.formatNumericValue(result) catch null;
    }

    fn parseNumericValue(self: *Optimizer, value: []const u8) ?f64 {
        _ = self;
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        if (trimmed.len == 0) {
            return null;
        }

        const units = [_][]const u8{ "px", "em", "rem", "%", "pt", "pc", "in", "cm", "mm", "ex", "ch", "vw", "vh", "vmin", "vmax" };
        var unit: ?[]const u8 = null;
        var num_str = trimmed;

        for (units) |u| {
            if (std.mem.endsWith(u8, trimmed, u)) {
                unit = u;
                num_str = trimmed[0..trimmed.len - u.len];
                break;
            }
        }

        const num = std.fmt.parseFloat(f64, num_str) catch return null;

        if (unit) |u| {
            if (!std.mem.eql(u8, u, "px")) {
                return null;
            }
        }

        return num;
    }

    fn formatNumericValue(self: *Optimizer, value: f64) ![]const u8 {
        if (value == 0.0) {
            return try self.allocator.dupe(u8, "0");
        }

        if (@mod(value, 1.0) == 0.0) {
            return try std.fmt.allocPrint(self.allocator, "{d}px", .{@as(i64, @intFromFloat(value))});
        } else {
            return try std.fmt.allocPrint(self.allocator, "{d}px", .{value});
        }
    }

    fn canRemoveCalcWrapper(self: *Optimizer, content: []const u8) bool {
        _ = self;
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        
        var has_operators = false;
        var depth: i32 = 0;
        
        for (trimmed) |ch| {
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
            } else if ((ch == '+' or ch == '-' or ch == '*' or ch == '/') and depth == 0) {
                has_operators = true;
                break;
            }
        }

        return !has_operators;
    }

    fn optimizeLogicalProperties(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        const pool = stylesheet.string_pool;
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len > 0) {
                        try self.convertLogicalPropertiesInRule(style_rule, pool);
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        if (rules.items.len > 0) {
                            for (rules.items) |*nested_rule| {
                                switch (nested_rule.*) {
                                    .style => |*style_rule| {
                                        if (style_rule.declarations.items.len > 0) {
                                            try self.convertLogicalPropertiesInRule(style_rule, pool);
                                        }
                                    },
                                    .at_rule => {},
                                }
                            }
                        }
                    }
                },
            }
        }
    }

    fn convertLogicalPropertiesInRule(self: *Optimizer, style_rule: *ast.StyleRule, pool: ?*string_pool.StringPool) !void {
        if (style_rule.declarations.items.len == 0) return;
        
        for (style_rule.declarations.items) |*decl| {
            const logical_prop = self.getPhysicalPropertyName(decl.property);
            if (logical_prop) |physical| {
                const interned = if (pool) |p| try p.intern(physical) else physical;
                decl.property = interned;
            }
        }
    }

    fn getPhysicalPropertyName(self: *Optimizer, logical: []const u8) ?[]const u8 {
        _ = self;
        const logical_map = [_]struct { logical: []const u8, physical: []const u8 }{
            .{ .logical = "margin-inline-start", .physical = "margin-left" },
            .{ .logical = "margin-inline-end", .physical = "margin-right" },
            .{ .logical = "margin-block-start", .physical = "margin-top" },
            .{ .logical = "margin-block-end", .physical = "margin-bottom" },
            .{ .logical = "padding-inline-start", .physical = "padding-left" },
            .{ .logical = "padding-inline-end", .physical = "padding-right" },
            .{ .logical = "padding-block-start", .physical = "padding-top" },
            .{ .logical = "padding-block-end", .physical = "padding-bottom" },
            .{ .logical = "border-inline-start", .physical = "border-left" },
            .{ .logical = "border-inline-end", .physical = "border-right" },
            .{ .logical = "border-block-start", .physical = "border-top" },
            .{ .logical = "border-block-end", .physical = "border-bottom" },
            .{ .logical = "border-inline-start-width", .physical = "border-left-width" },
            .{ .logical = "border-inline-end-width", .physical = "border-right-width" },
            .{ .logical = "border-block-start-width", .physical = "border-top-width" },
            .{ .logical = "border-block-end-width", .physical = "border-bottom-width" },
            .{ .logical = "border-inline-start-style", .physical = "border-left-style" },
            .{ .logical = "border-inline-end-style", .physical = "border-right-style" },
            .{ .logical = "border-block-start-style", .physical = "border-top-style" },
            .{ .logical = "border-block-end-style", .physical = "border-bottom-style" },
            .{ .logical = "border-inline-start-color", .physical = "border-left-color" },
            .{ .logical = "border-inline-end-color", .physical = "border-right-color" },
            .{ .logical = "border-block-start-color", .physical = "border-top-color" },
            .{ .logical = "border-block-end-color", .physical = "border-bottom-color" },
            .{ .logical = "inset-inline-start", .physical = "left" },
            .{ .logical = "inset-inline-end", .physical = "right" },
            .{ .logical = "inset-block-start", .physical = "top" },
            .{ .logical = "inset-block-end", .physical = "bottom" },
        };

        for (logical_map) |entry| {
            if (std.mem.eql(u8, logical, entry.logical)) {
                return entry.physical;
            }
        }

        return null;
    }

    fn optimizeShorthandProperties(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        const pool = stylesheet.string_pool;
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    if (style_rule.declarations.items.len > 0) {
                        try self.optimizeShorthandInRule(style_rule, pool);
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        if (rules.items.len > 0) {
                            for (rules.items) |*nested_rule| {
                                switch (nested_rule.*) {
                                    .style => |*style_rule| {
                                        if (style_rule.declarations.items.len > 0) {
                                            try self.optimizeShorthandInRule(style_rule, pool);
                                        }
                                    },
                                    .at_rule => {},
                                }
                            }
                        }
                    }
                },
            }
        }
    }

    fn optimizeShorthandInRule(self: *Optimizer, style_rule: *ast.StyleRule, pool: ?*string_pool.StringPool) !void {
        if (style_rule.declarations.items.len == 0) return;
        
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
        
        var flex_grow: ?[]const u8 = null;
        var flex_shrink: ?[]const u8 = null;
        var flex_basis: ?[]const u8 = null;
        
        var grid_template_rows: ?[]const u8 = null;
        var grid_template_columns: ?[]const u8 = null;
        var grid_template_areas: ?[]const u8 = null;
        
        var row_gap: ?[]const u8 = null;
        var column_gap: ?[]const u8 = null;
        
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
        var flex_indices = try std.ArrayList(usize).initCapacity(self.allocator, 3);
        defer flex_indices.deinit(self.allocator);
        var grid_template_indices = try std.ArrayList(usize).initCapacity(self.allocator, 3);
        defer grid_template_indices.deinit(self.allocator);
        var gap_indices = try std.ArrayList(usize).initCapacity(self.allocator, 2);
        defer gap_indices.deinit(self.allocator);
        
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
            } else if (std.mem.eql(u8, decl.property, "flex-grow")) {
                flex_grow = decl.value;
                try flex_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "flex-shrink")) {
                flex_shrink = decl.value;
                try flex_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "flex-basis")) {
                flex_basis = decl.value;
                try flex_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "grid-template-rows")) {
                grid_template_rows = decl.value;
                try grid_template_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "grid-template-columns")) {
                grid_template_columns = decl.value;
                try grid_template_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "grid-template-areas")) {
                grid_template_areas = decl.value;
                try grid_template_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "row-gap")) {
                row_gap = decl.value;
                try gap_indices.append(self.allocator, i);
            } else if (std.mem.eql(u8, decl.property, "column-gap")) {
                column_gap = decl.value;
                try gap_indices.append(self.allocator, i);
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
        
        if (flex_indices.items.len == 3) {
            const shorthand = try self.buildFlexShorthand(flex_grow.?, flex_shrink.?, flex_basis.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "flex";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = flex_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = flex_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
        
        if (grid_template_indices.items.len >= 2 and grid_template_rows != null and grid_template_columns != null) {
            const shorthand = try self.buildGridTemplateShorthand(grid_template_rows, grid_template_columns, grid_template_areas);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "grid-template";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = grid_template_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = grid_template_indices.items[i];
                style_rule.declarations.items[idx].deinit();
                _ = style_rule.declarations.swapRemove(idx);
            }
        }
        
        if (gap_indices.items.len == 2) {
            const shorthand = try self.buildGapShorthand(row_gap.?, column_gap.?);
            defer self.allocator.free(shorthand);
            
            const interned = if (pool) |p| try p.intern(shorthand) else shorthand;
            
            var new_decl = ast.Declaration.init(style_rule.allocator);
            new_decl.property = "gap";
            new_decl.value = interned;
            try style_rule.declarations.append(style_rule.allocator, new_decl);
            
            var i: usize = gap_indices.items.len;
            while (i > 0) {
                i -= 1;
                const idx = gap_indices.items[i];
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

    fn buildFlexShorthand(self: *Optimizer, grow: []const u8, shrink: []const u8, basis: []const u8) ![]const u8 {
        if (std.mem.eql(u8, grow, "1") and std.mem.eql(u8, shrink, "1") and std.mem.eql(u8, basis, "0%")) {
            return try self.allocator.dupe(u8, "1 1 0%");
        }
        if (std.mem.eql(u8, grow, "0") and std.mem.eql(u8, shrink, "1") and std.mem.eql(u8, basis, "auto")) {
            return try self.allocator.dupe(u8, "0 1 auto");
        }
        if (std.mem.eql(u8, grow, "none")) {
            return try self.allocator.dupe(u8, "none");
        }
        if (std.mem.eql(u8, grow, "auto")) {
            return try self.allocator.dupe(u8, "auto");
        }
        return try std.fmt.allocPrint(self.allocator, "{s} {s} {s}", .{ grow, shrink, basis });
    }

    fn buildGridTemplateShorthand(self: *Optimizer, rows: ?[]const u8, columns: ?[]const u8, areas: ?[]const u8) ![]const u8 {
        var parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 3);
        defer parts.deinit(self.allocator);

        if (areas) |a| {
            try parts.append(self.allocator, a);
        }
        if (rows) |r| {
            try parts.append(self.allocator, r);
        }
        if (columns) |c| {
            try parts.append(self.allocator, c);
        }

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

    fn buildGapShorthand(self: *Optimizer, row: []const u8, column: []const u8) ![]const u8 {
        if (std.mem.eql(u8, row, column)) {
            return try self.allocator.dupe(u8, row);
        }
        return try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ row, column });
    }

    fn removeDuplicateDeclarations(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
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
        const decl_count = style_rule.declarations.items.len;
        if (decl_count <= 1) return;
        
        const estimated_capacity = @as(u32, @intCast(@min(decl_count / 2, std.math.maxInt(u32))));
        var seen = std.StringHashMap(void).init(style_rule.allocator);
        defer seen.deinit();
        try seen.ensureTotalCapacity(estimated_capacity);

        var i: usize = decl_count;
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
        if (stylesheet.rules.items.len == 0) return;
        
        var i: usize = 0;
        const rules_len = stylesheet.rules.items.len;
        while (i < rules_len) {
            const rule = &stylesheet.rules.items[i];
            switch (rule.*) {
                .style => |*style_rule| {
                    const selector_count = style_rule.selectors.items.len;
                    var j: usize = 0;
                    while (j < selector_count) {
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
                        const nested_count = rules.items.len;
                        for (rules.items[0..nested_count]) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    const selector_count = style_rule.selectors.items.len;
                                    var j: usize = 0;
                                    while (j < selector_count) {
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
        const parts_len = selector.parts.items.len;
        
        while (i < parts_len) {
            const part = &selector.parts.items[i];
            
            if (part.* == .universal) {
                if (i == 0 and parts_len > 1) {
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
                if (i + 1 >= parts_len) {
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
        if (stylesheet.rules.items.len == 0) return;
        
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .style) {
                i += 1;
                continue;
            }

            var j: usize = 0;
            const selector_count = rule.style.selectors.items.len;
            while (j < selector_count) {
                const selector = &rule.style.selectors.items[j];
                var is_redundant = false;

                var k: usize = 0;
                while (k < selector_count) {
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

    fn reorderAtRules(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        const estimated_capacity = stylesheet.rules.items.len / 4;
        var media_rules = try std.ArrayList(usize).initCapacity(self.allocator, estimated_capacity);
        defer media_rules.deinit(self.allocator);
        var container_rules = try std.ArrayList(usize).initCapacity(self.allocator, estimated_capacity);
        defer container_rules.deinit(self.allocator);
        var layer_rules = try std.ArrayList(usize).initCapacity(self.allocator, estimated_capacity);
        defer layer_rules.deinit(self.allocator);
        var other_rules = try std.ArrayList(usize).initCapacity(self.allocator, stylesheet.rules.items.len);
        defer other_rules.deinit(self.allocator);

        for (stylesheet.rules.items, 0..) |*rule, i| {
            if (rule.* == .at_rule) {
                const at_rule = &rule.at_rule;
                const name = at_rule.name;
                if (name.len == 5 and std.mem.eql(u8, name, "media")) {
                    try media_rules.append(self.allocator, i);
                } else if (name.len == 9 and std.mem.eql(u8, name, "container")) {
                    try container_rules.append(self.allocator, i);
                } else if (name.len == 5 and std.mem.eql(u8, name, "layer")) {
                    try layer_rules.append(self.allocator, i);
                } else {
                    try other_rules.append(self.allocator, i);
                }
            } else {
                try other_rules.append(self.allocator, i);
            }
        }

        if (media_rules.items.len + container_rules.items.len + layer_rules.items.len == 0) {
            return;
        }

        var reordered = try std.ArrayList(ast.Rule).initCapacity(self.allocator, stylesheet.rules.items.len);

        for (other_rules.items) |idx| {
            if (stylesheet.rules.items[idx] != .at_rule or
                (!std.mem.eql(u8, stylesheet.rules.items[idx].at_rule.name, "media") and
                 !std.mem.eql(u8, stylesheet.rules.items[idx].at_rule.name, "container") and
                 !std.mem.eql(u8, stylesheet.rules.items[idx].at_rule.name, "layer")))
            {
                try reordered.append(self.allocator, stylesheet.rules.items[idx]);
            }
        }

        for (media_rules.items) |idx| {
            try reordered.append(self.allocator, stylesheet.rules.items[idx]);
        }

        for (container_rules.items) |idx| {
            try reordered.append(self.allocator, stylesheet.rules.items[idx]);
        }

        for (layer_rules.items) |idx| {
            try reordered.append(self.allocator, stylesheet.rules.items[idx]);
        }

        stylesheet.rules.deinit(self.allocator);
        stylesheet.rules = reordered;
    }

    fn mergeMediaQueries(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        var media_count: usize = 0;
        for (stylesheet.rules.items) |rule| {
            if (rule == .at_rule and rule.at_rule.name.len == 5 and std.mem.eql(u8, rule.at_rule.name, "media")) {
                media_count += 1;
            }
        }
        if (media_count <= 1) return;
        
        const estimated_capacity = @min(media_count / 2, 16);
        var media_map = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        try media_map.ensureTotalCapacity(estimated_capacity);
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
            if (rule.* != .at_rule) {
                i += 1;
                continue;
            }
            const name = rule.at_rule.name;
            if (name.len != 5 or !std.mem.eql(u8, name, "media")) {
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
                        while (other_rules.items.len > 0) {
                            const nested_rule = other_rules.swapRemove(0);
                            try merged_rules.append(self.allocator, nested_rule);
                        }
                    }
                    j += 1;
                }
            }
        }

        var idx_i = indices_to_remove.items.len;
        while (idx_i > 0) {
            idx_i -= 1;
            const idx = indices_to_remove.items[idx_i];
            stylesheet.rules.items[idx].deinit();
            _ = stylesheet.rules.swapRemove(idx);
        }
    }

    fn mergeContainerQueries(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        var container_count: usize = 0;
        for (stylesheet.rules.items) |rule| {
            if (rule == .at_rule and rule.at_rule.name.len == 9 and std.mem.eql(u8, rule.at_rule.name, "container")) {
                container_count += 1;
            }
        }
        if (container_count <= 1) return;
        
        const estimated_capacity = @min(container_count / 2, 16);
        var container_map = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        try container_map.ensureTotalCapacity(estimated_capacity);
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
            if (rule.* != .at_rule) {
                i += 1;
                continue;
            }
            const name = rule.at_rule.name;
            if (name.len != 9 or !std.mem.eql(u8, name, "container")) {
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
                        while (other_rules.items.len > 0) {
                            const nested_rule = other_rules.swapRemove(0);
                            try merged_rules.append(self.allocator, nested_rule);
                        }
                    }
                    j += 1;
                }
            }
        }

        var idx_i = indices_to_remove.items.len;
        while (idx_i > 0) {
            idx_i -= 1;
            const idx = indices_to_remove.items[idx_i];
            stylesheet.rules.items[idx].deinit();
            _ = stylesheet.rules.swapRemove(idx);
        }
    }

    fn mergeCascadeLayers(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        if (stylesheet.rules.items.len == 0) return;
        
        var layer_count: usize = 0;
        for (stylesheet.rules.items) |rule| {
            if (rule == .at_rule and rule.at_rule.name.len == 5 and std.mem.eql(u8, rule.at_rule.name, "layer")) {
                layer_count += 1;
            }
        }
        if (layer_count <= 1) return;
        
        const estimated_capacity = @min(layer_count / 2, 16);
        var layer_map = std.StringHashMap(std.ArrayList(usize)).init(self.allocator);
        try layer_map.ensureTotalCapacity(estimated_capacity);
        defer {
            var it = layer_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            layer_map.deinit();
        }

        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            if (rule.* != .at_rule) {
                i += 1;
                continue;
            }
            const name = rule.at_rule.name;
            if (name.len != 5 or !std.mem.eql(u8, name, "layer")) {
                i += 1;
                continue;
            }

            const prelude = rule.at_rule.prelude;
            const normalized_prelude = if (prelude.len > 0) prelude else "";
            const gop = try layer_map.getOrPut(normalized_prelude);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.ArrayList(usize).initCapacity(self.allocator, 4);
            }
            try gop.value_ptr.append(self.allocator, i);
            i += 1;
        }

        var indices_to_remove = try std.ArrayList(usize).initCapacity(self.allocator, 8);
        defer indices_to_remove.deinit(self.allocator);

        var it = layer_map.iterator();
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
                        while (other_rules.items.len > 0) {
                            const nested_rule = other_rules.swapRemove(0);
                            try merged_rules.append(self.allocator, nested_rule);
                        }
                    }
                    j += 1;
                }
            }
        }

        var idx_i = indices_to_remove.items.len;
        while (idx_i > 0) {
            idx_i -= 1;
            const idx = indices_to_remove.items[idx_i];
            stylesheet.rules.items[idx].deinit();
            _ = stylesheet.rules.swapRemove(idx);
        }
    }

    fn removeDeadCode(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        const opts = self.dead_code_options.?;
        
        var used_classes_set = std.StringHashMap(void).init(self.allocator);
        defer used_classes_set.deinit();
        if (opts.used_classes) |classes| {
            for (classes) |class| {
                try used_classes_set.put(class, {});
            }
        }
        
        var used_ids_set = std.StringHashMap(void).init(self.allocator);
        defer used_ids_set.deinit();
        if (opts.used_ids) |ids| {
            for (ids) |id| {
                try used_ids_set.put(id, {});
            }
        }
        
        var used_elements_set = std.StringHashMap(void).init(self.allocator);
        defer used_elements_set.deinit();
        if (opts.used_elements) |elements| {
            for (elements) |element| {
                try used_elements_set.put(element, {});
            }
        }
        
        var used_attributes_set = std.StringHashMap(void).init(self.allocator);
        defer used_attributes_set.deinit();
        if (opts.used_attributes) |attributes| {
            for (attributes) |attr| {
                try used_attributes_set.put(attr, {});
            }
        }
        
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            const should_remove = switch (rule.*) {
                .style => |*style_rule| !self.isSelectorUsed(&style_rule.selectors, &used_classes_set, &used_ids_set, &used_elements_set, &used_attributes_set),
                .at_rule => |*at_rule| blk: {
                    if (at_rule.rules) |*rules| {
                        var j: usize = 0;
                        while (j < rules.items.len) {
                            const nested_rule = &rules.items[j];
                            const nested_should_remove = switch (nested_rule.*) {
                                .style => |*style_rule| !self.isSelectorUsed(&style_rule.selectors, &used_classes_set, &used_ids_set, &used_elements_set, &used_attributes_set),
                                .at_rule => false,
                            };
                            if (nested_should_remove) {
                                nested_rule.deinit();
                                _ = rules.swapRemove(j);
                            } else {
                                j += 1;
                            }
                        }
                        break :blk rules.items.len == 0;
                    } else {
                        break :blk false;
                    }
                },
            };
            
            if (should_remove) {
                rule.deinit();
                _ = stylesheet.rules.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn isSelectorUsed(self: *Optimizer, selectors: *std.ArrayList(ast.Selector), used_classes: *std.StringHashMap(void), used_ids: *std.StringHashMap(void), used_elements: *std.StringHashMap(void), used_attributes: *std.StringHashMap(void)) bool {
        _ = self;
        
        if (used_classes.count() == 0 and used_ids.count() == 0 and used_elements.count() == 0 and used_attributes.count() == 0) {
            return true;
        }
        
        for (selectors.items) |selector| {
            var has_match = false;
            
            for (selector.parts.items) |part| {
                switch (part) {
                    .class => |class| {
                        if (used_classes.contains(class)) {
                            has_match = true;
                            break;
                        }
                    },
                    .id => |id| {
                        if (used_ids.contains(id)) {
                            has_match = true;
                            break;
                        }
                    },
                    .type => |element| {
                        if (used_elements.contains(element)) {
                            has_match = true;
                            break;
                        }
                    },
                    .attribute => |attr| {
                        if (used_attributes.contains(attr.name)) {
                            has_match = true;
                            break;
                        }
                    },
                    .universal => {
                        has_match = true;
                        break;
                    },
                    .pseudo_class, .pseudo_element, .combinator => {},
                }
            }
            
            if (has_match) {
                return true;
            }
        }
        
        return false;
    }

    fn extractCriticalCss(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        const opts = self.critical_css_options.?;
        
        var critical_classes_set = std.StringHashMap(void).init(self.allocator);
        defer critical_classes_set.deinit();
        if (opts.critical_classes) |classes| {
            for (classes) |class| {
                try critical_classes_set.put(class, {});
            }
        }
        
        var critical_ids_set = std.StringHashMap(void).init(self.allocator);
        defer critical_ids_set.deinit();
        if (opts.critical_ids) |ids| {
            for (ids) |id| {
                try critical_ids_set.put(id, {});
            }
        }
        
        var critical_elements_set = std.StringHashMap(void).init(self.allocator);
        defer critical_elements_set.deinit();
        if (opts.critical_elements) |elements| {
            for (elements) |element| {
                try critical_elements_set.put(element, {});
            }
        }
        
        var critical_attributes_set = std.StringHashMap(void).init(self.allocator);
        defer critical_attributes_set.deinit();
        if (opts.critical_attributes) |attributes| {
            for (attributes) |attr| {
                try critical_attributes_set.put(attr, {});
            }
        }
        
        var i: usize = 0;
        while (i < stylesheet.rules.items.len) {
            const rule = &stylesheet.rules.items[i];
            const should_remove = switch (rule.*) {
                .style => |*style_rule| !self.isSelectorUsed(&style_rule.selectors, &critical_classes_set, &critical_ids_set, &critical_elements_set, &critical_attributes_set),
                .at_rule => |*at_rule| blk: {
                    if (at_rule.rules) |*rules| {
                        var j: usize = 0;
                        while (j < rules.items.len) {
                            const nested_rule = &rules.items[j];
                            const nested_should_remove = switch (nested_rule.*) {
                                .style => |*style_rule| !self.isSelectorUsed(&style_rule.selectors, &critical_classes_set, &critical_ids_set, &critical_elements_set, &critical_attributes_set),
                                .at_rule => false,
                            };
                            if (nested_should_remove) {
                                nested_rule.deinit();
                                _ = rules.swapRemove(j);
                            } else {
                                j += 1;
                            }
                        }
                        break :blk rules.items.len == 0;
                    } else {
                        break :blk false;
                    }
                },
            };
            
            if (should_remove) {
                rule.deinit();
                _ = stylesheet.rules.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "remove unused custom properties" {
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
    var root_selector = try ast.Selector.init(allocator);
    try root_selector.parts.append(allocator, ast.SelectorPart{ .type = try pool.intern(":root") });
    try root_rule.selectors.append(allocator, root_selector);

    var used_prop = ast.Declaration.init(allocator);
    used_prop.property = try pool.intern("--primary-color");
    used_prop.value = try pool.intern("#007bff");
    try root_rule.declarations.append(allocator, used_prop);

    var unused_prop = ast.Declaration.init(allocator);
    unused_prop.property = try pool.intern("--unused-color");
    unused_prop.value = try pool.intern("#ff0000");
    try root_rule.declarations.append(allocator, unused_prop);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = root_rule });

    var button_rule = try ast.StyleRule.init(allocator);
    var button_selector = try ast.Selector.init(allocator);
    try button_selector.parts.append(allocator, ast.SelectorPart{ .class = try pool.intern("button") });
    try button_rule.selectors.append(allocator, button_selector);

    var bg_decl = ast.Declaration.init(allocator);
    bg_decl.property = try pool.intern("background-color");
    bg_decl.value = try pool.intern("var(--primary-color)");
    try button_rule.declarations.append(allocator, bg_decl);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = button_rule });

    var used_properties = std.StringHashMap(void).init(allocator);
    defer used_properties.deinit();
    var temp_optimizer = Optimizer.init(allocator);
    temp_optimizer.collectUsedCustomPropertiesBeforeResolve(&stylesheet, &used_properties);

    var resolver = custom_properties.CustomPropertyResolver.init(allocator, pool);
    defer resolver.deinit();
    try resolver.resolve(&stylesheet);

    var optimizer = Optimizer.init(allocator);
    try optimizer.removeUnusedCustomProperties(&stylesheet, &used_properties);

    const root_style = stylesheet.rules.items[0].style;
    try std.testing.expect(root_style.declarations.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, root_style.declarations.items[0].property, "--primary-color"));
}

test "remove unused custom properties with nested rules" {
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
    var root_selector = try ast.Selector.init(allocator);
    try root_selector.parts.append(allocator, ast.SelectorPart{ .type = try pool.intern(":root") });
    try root_rule.selectors.append(allocator, root_selector);

    var used_prop = ast.Declaration.init(allocator);
    used_prop.property = try pool.intern("--primary-color");
    used_prop.value = try pool.intern("#007bff");
    try root_rule.declarations.append(allocator, used_prop);

    var unused_prop = ast.Declaration.init(allocator);
    unused_prop.property = try pool.intern("--unused-color");
    unused_prop.value = try pool.intern("#ff0000");
    try root_rule.declarations.append(allocator, unused_prop);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = root_rule });

    var media_rule = ast.AtRule.init(allocator);
    media_rule.name = try pool.intern("media");
    media_rule.prelude = try pool.intern("(min-width: 768px)");
    media_rule.rules = try std.ArrayList(ast.Rule).initCapacity(allocator, 1);

    var button_rule = try ast.StyleRule.init(allocator);
    var button_selector = try ast.Selector.init(allocator);
    try button_selector.parts.append(allocator, ast.SelectorPart{ .class = try pool.intern("button") });
    try button_rule.selectors.append(allocator, button_selector);

    var bg_decl = ast.Declaration.init(allocator);
    bg_decl.property = try pool.intern("background-color");
    bg_decl.value = try pool.intern("var(--primary-color)");
    try button_rule.declarations.append(allocator, bg_decl);

    try media_rule.rules.?.append(allocator, ast.Rule{ .style = button_rule });
    try stylesheet.rules.append(allocator, ast.Rule{ .at_rule = media_rule });

    var used_properties = std.StringHashMap(void).init(allocator);
    defer used_properties.deinit();
    var temp_optimizer = Optimizer.init(allocator);
    temp_optimizer.collectUsedCustomPropertiesBeforeResolve(&stylesheet, &used_properties);

    var resolver = custom_properties.CustomPropertyResolver.init(allocator, pool);
    defer resolver.deinit();
    try resolver.resolve(&stylesheet);

    var optimizer = Optimizer.init(allocator);
    try optimizer.removeUnusedCustomProperties(&stylesheet, &used_properties);

    const root_style = stylesheet.rules.items[0].style;
    try std.testing.expect(root_style.declarations.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, root_style.declarations.items[0].property, "--primary-color"));
}

test "reorder at-rules" {
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

    var media_rule1 = ast.AtRule.init(allocator);
    media_rule1.name = try pool.intern("media");
    media_rule1.prelude = try pool.intern("(min-width: 768px)");
    try stylesheet.rules.append(allocator, ast.Rule{ .at_rule = media_rule1 });

    var style_rule = try ast.StyleRule.init(allocator);
    var selector = try ast.Selector.init(allocator);
    try selector.parts.append(allocator, ast.SelectorPart{ .class = try pool.intern("button") });
    try style_rule.selectors.append(allocator, selector);
    try stylesheet.rules.append(allocator, ast.Rule{ .style = style_rule });

    var container_rule = ast.AtRule.init(allocator);
    container_rule.name = try pool.intern("container");
    container_rule.prelude = try pool.intern("(min-width: 400px)");
    try stylesheet.rules.append(allocator, ast.Rule{ .at_rule = container_rule });

    var layer_rule = ast.AtRule.init(allocator);
    layer_rule.name = try pool.intern("layer");
    layer_rule.prelude = try pool.intern("theme");
    try stylesheet.rules.append(allocator, ast.Rule{ .at_rule = layer_rule });

    var optimizer = Optimizer.init(allocator);
    try optimizer.reorderAtRules(&stylesheet);

    try std.testing.expect(stylesheet.rules.items.len == 4);
    try std.testing.expect(stylesheet.rules.items[0] == .style);
    try std.testing.expect(stylesheet.rules.items[1] == .at_rule);
    try std.testing.expect(std.mem.eql(u8, stylesheet.rules.items[1].at_rule.name, "media"));
    try std.testing.expect(stylesheet.rules.items[2] == .at_rule);
    try std.testing.expect(std.mem.eql(u8, stylesheet.rules.items[2].at_rule.name, "container"));
    try std.testing.expect(stylesheet.rules.items[3] == .at_rule);
    try std.testing.expect(std.mem.eql(u8, stylesheet.rules.items[3].at_rule.name, "layer"));
}
