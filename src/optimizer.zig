const std = @import("std");
const ast = @import("ast.zig");

pub const Optimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .allocator = allocator };
    }

    pub fn optimize(self: *Optimizer, stylesheet: *ast.Stylesheet) !void {
        try self.removeEmptyRules(stylesheet);
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
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    for (style_rule.declarations.items) |*decl| {
                        const optimized = try self.optimizeValue(decl.value);
                        if (optimized.ptr != decl.value.ptr) {
                            decl.value = optimized;
                        }
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    for (style_rule.declarations.items) |*decl| {
                                        const optimized = try self.optimizeValue(decl.value);
                                        if (optimized.ptr != decl.value.ptr) {
                                            decl.value = optimized;
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

    fn optimizeValue(self: *Optimizer, value: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        
        if (trimmed.len == 0) return value;

        if (self.optimizeHexColor(trimmed)) |optimized| {
            if (optimized.len < trimmed.len) {
                return try self.allocator.dupe(u8, optimized);
            }
        }

        if (self.optimizeUnit(trimmed)) |optimized| {
            return try self.allocator.dupe(u8, optimized);
        }

        return value;
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
