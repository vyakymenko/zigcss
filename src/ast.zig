const std = @import("std");
const string_pool = @import("string_pool.zig");

pub const Stylesheet = struct {
    rules: std.ArrayList(Rule),
    allocator: std.mem.Allocator,
    string_pool: ?*string_pool.StringPool,
    owns_string_pool: bool,

    pub fn init(allocator: std.mem.Allocator) !Stylesheet {
        return initWithCapacity(allocator, 0);
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !Stylesheet {
        return .{
            .rules = try std.ArrayList(Rule).initCapacity(allocator, capacity),
            .allocator = allocator,
            .string_pool = null,
            .owns_string_pool = false,
        };
    }

    pub fn deinit(self: *Stylesheet) void {
        for (self.rules.items) |*rule| {
            rule.deinit();
        }
        self.rules.deinit(self.allocator);
        if (self.owns_string_pool) {
            if (self.string_pool) |pool| {
                pool.deinit();
                self.allocator.destroy(pool);
            }
        }
    }
};

pub const Rule = union(enum) {
    style: StyleRule,
    at_rule: AtRule,

    pub fn deinit(self: *Rule) void {
        switch (self.*) {
            .style => |*r| r.deinit(),
            .at_rule => |*r| r.deinit(),
        }
    }
};

pub const StyleRule = struct {
    selectors: std.ArrayList(Selector),
    declarations: std.ArrayList(Declaration),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !StyleRule {
        return initWithCapacity(allocator, 0, 0);
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, selector_capacity: usize, declaration_capacity: usize) !StyleRule {
        return .{
            .selectors = try std.ArrayList(Selector).initCapacity(allocator, selector_capacity),
            .declarations = try std.ArrayList(Declaration).initCapacity(allocator, declaration_capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StyleRule) void {
        for (self.selectors.items) |*selector| {
            selector.deinit();
        }
        self.selectors.deinit(self.allocator);
        for (self.declarations.items) |*decl| {
            decl.deinit();
        }
        self.declarations.deinit(self.allocator);
    }
};

pub const AtRule = struct {
    name: []const u8,
    prelude: []const u8,
    rules: ?std.ArrayList(Rule),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AtRule {
        return .{
            .name = "",
            .prelude = "",
            .rules = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtRule) void {
        if (self.rules) |*rules| {
            for (rules.items) |*rule| {
                rule.deinit();
            }
            rules.deinit(self.allocator);
        }
    }
};

pub const Selector = struct {
    parts: std.ArrayList(SelectorPart),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Selector {
        return initWithCapacity(allocator, 0);
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !Selector {
        return .{
            .parts = try std.ArrayList(SelectorPart).initCapacity(allocator, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Selector) void {
        for (self.parts.items) |*part| {
            part.deinit(self.allocator);
        }
        self.parts.deinit(self.allocator);
    }

    pub fn toString(self: *const Selector, allocator: std.mem.Allocator) ![]const u8 {
        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer list.deinit(allocator);

        for (self.parts.items, 0..) |part, i| {
            if (i > 0) {
                try list.append(allocator, ' ');
            }
            const str = try part.toString(allocator);
            defer allocator.free(str);
            try list.appendSlice(allocator, str);
        }

        return try list.toOwnedSlice(allocator);
    }
};

pub const SelectorPart = union(enum) {
    type: []const u8,
    class: []const u8,
    id: []const u8,
    universal: void,
    attribute: AttributeSelector,
    pseudo_class: []const u8,
    pseudo_element: []const u8,
    combinator: Combinator,

    pub fn deinit(self: *SelectorPart, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .attribute => |*attr| attr.deinit(allocator),
            else => {},
        }
    }

    pub fn toString(self: *const SelectorPart, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.*) {
            .type => |s| try allocator.dupe(u8, s),
            .class => |s| try std.fmt.allocPrint(allocator, ".{s}", .{s}),
            .id => |s| try std.fmt.allocPrint(allocator, "#{s}", .{s}),
            .universal => try allocator.dupe(u8, "*"),
            .attribute => |attr| try attr.toString(allocator),
            .pseudo_class => |s| try std.fmt.allocPrint(allocator, ":{s}", .{s}),
            .pseudo_element => |s| try std.fmt.allocPrint(allocator, "::{s}", .{s}),
            .combinator => |c| try allocator.dupe(u8, c.toString()),
        };
    }
};

pub const AttributeSelector = struct {
    name: []const u8,
    operator: ?[]const u8,
    value: ?[]const u8,
    case_sensitive: bool = true,

    pub fn deinit(self: *AttributeSelector, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn toString(self: *const AttributeSelector, allocator: std.mem.Allocator) ![]const u8 {
        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer list.deinit(allocator);

    try list.append(allocator, '[');
    try list.appendSlice(allocator, self.name);
    if (self.operator) |op| {
        try list.appendSlice(allocator, op);
        if (self.value) |val| {
            try list.append(allocator, '"');
            try list.appendSlice(allocator, val);
            try list.append(allocator, '"');
        }
    }
    if (!self.case_sensitive) {
        try list.appendSlice(allocator, " i");
    }
    try list.append(allocator, ']');

        return try list.toOwnedSlice(allocator);
    }
};

pub const Combinator = enum {
    descendant,
    child,
    next_sibling,
    following_sibling,

    pub fn toString(self: Combinator) []const u8 {
        return switch (self) {
            .descendant => " ",
            .child => " > ",
            .next_sibling => " + ",
            .following_sibling => " ~ ",
        };
    }
};

pub const Declaration = struct {
    property: []const u8,
    value: []const u8,
    important: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Declaration {
        return .{
            .property = "",
            .value = "",
            .important = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Declaration) void {
        _ = self;
    }
};
