const std = @import("std");

pub const Stylesheet = struct {
    rules: std.ArrayList(Rule),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Stylesheet {
        return .{
            .rules = try std.ArrayList(Rule).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stylesheet) void {
        for (self.rules.items) |*rule| {
            rule.deinit();
        }
        self.rules.deinit(self.allocator);
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
        return .{
            .selectors = try std.ArrayList(Selector).initCapacity(allocator, 0),
            .declarations = try std.ArrayList(Declaration).initCapacity(allocator, 0),
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
        self.allocator.free(self.name);
        self.allocator.free(self.prelude);
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
        return .{
            .parts = try std.ArrayList(SelectorPart).initCapacity(allocator, 0),
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
                try list.append(' ');
            }
            const str = try part.toString(allocator);
            defer allocator.free(str);
            try list.appendSlice(str);
        }

        return list.toOwnedSlice();
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
            .type => |s| allocator.free(s),
            .class => |s| allocator.free(s),
            .id => |s| allocator.free(s),
            .attribute => |*attr| attr.deinit(allocator),
            .pseudo_class => |s| allocator.free(s),
            .pseudo_element => |s| allocator.free(s),
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
        allocator.free(self.name);
        if (self.operator) |op| {
            allocator.free(op);
        }
        if (self.value) |val| {
            allocator.free(val);
        }
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

        return list.toOwnedSlice();
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
        self.allocator.free(self.property);
        self.allocator.free(self.value);
    }
};
