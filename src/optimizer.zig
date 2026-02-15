const std = @import("std");
const ast = @import("ast.zig");

pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    pub fn optimize(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        try self.removeEmptyRules(stylesheet);
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

        if (self.optimizeHexColor(trimmed)) |optimized| {
            if (optimized.len < trimmed.len) {
                return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
            }
        }

        if (self.optimizeUnit(trimmed)) |optimized| {
            return .{ .optimized = try self.allocator.dupe(u8, optimized), .was_optimized = true };
        }

        return .{ .optimized = value, .was_optimized = false };
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

    fn optimizeUnit(self: *Optimizer, value: []const u8) ?[]const u8 {
        _ = self;
        if (value.len < 3) return null;
        
        if (std.mem.endsWith(u8, value, "px")) {
            if (std.fmt.parseFloat(f32, value[0..value.len - 2])) |num| {
                if (num == 0.0) {
                    return "0";
                }
            } else |_| {}
        }

        if (std.mem.endsWith(u8, value, "em")) {
            if (std.fmt.parseFloat(f32, value[0..value.len - 2])) |num| {
                if (num == 0.0) {
                    return "0";
                }
            } else |_| {}
        }

        return null;
    }

    fn removeDuplicateDeclarations(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        _ = self;
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    var seen = std.StringHashMap(void).init(style_rule.allocator);
                    defer seen.deinit();

                    var i: usize = 0;
                    while (i < style_rule.declarations.items.len) {
                        const property = style_rule.declarations.items[i].property;
                        const gop = try seen.getOrPut(property);
                        if (gop.found_existing) {
                            style_rule.declarations.items[i].deinit();
                            _ = style_rule.declarations.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    var seen = std.StringHashMap(void).init(style_rule.allocator);
                                    defer seen.deinit();

                                    var i: usize = 0;
                                    while (i < style_rule.declarations.items.len) {
                                        const property = style_rule.declarations.items[i].property;
                                        const gop = try seen.getOrPut(property);
                                        if (gop.found_existing) {
                                            style_rule.declarations.items[i].deinit();
                                            _ = style_rule.declarations.swapRemove(i);
                                        } else {
                                            i += 1;
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
};
