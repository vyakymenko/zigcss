const std = @import("std");

pub const Stylesheet = struct {
    rules: std.ArrayList(Rule),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Stylesheet {
        return .{
            .rules = std.ArrayList(Rule).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stylesheet) void {
        for (self.rules.items) |*rule| {
            rule.deinit();
        }
        self.rules.deinit();
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

    pub fn init(allocator: std.mem.Allocator) StyleRule {
        return .{
            .selectors = std.ArrayList(Selector).init(allocator),
            .declarations = std.ArrayList(Declaration).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StyleRule) void {
        for (self.selectors.items) |*selector| {
            selector.deinit();
        }
        self.selectors.deinit();
        for (self.declarations.items) |*decl| {
            decl.deinit();
        }
        self.declarations.deinit();
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
            rules.deinit();
        }
    }
};

pub const Selector = struct {
    parts: std.ArrayList(SelectorPart),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Selector {
        return .{
            .parts = std.ArrayList(SelectorPart).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Selector) void {
        for (self.parts.items) |*part| {
            part.deinit();
        }
        self.parts.deinit();
    }

    pub fn toString(self: *const Selector, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

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

    pub fn deinit(self: *SelectorPart) void {
        switch (self.*) {
            .attribute => |*attr| attr.deinit(),
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

    pub fn deinit(self: *AttributeSelector) void {
        _ = self;
    }

    pub fn toString(self: *const AttributeSelector, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try list.append('[');
        try list.appendSlice(self.name);
        if (self.operator) |op| {
            try list.appendSlice(op);
            if (self.value) |val| {
                try list.append('"');
                try list.appendSlice(val);
                try list.append('"');
            }
        }
        if (!self.case_sensitive) {
            try list.appendSlice(" i");
        }
        try list.append(']');

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
