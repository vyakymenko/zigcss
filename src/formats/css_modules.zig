const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

pub const Parser = struct {
    input: []const u8,
    allocator: std.mem.Allocator,
    class_map: std.StringHashMap([]const u8),
    hash_counter: u32,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .allocator = allocator,
            .class_map = std.StringHashMap([]const u8).init(allocator),
            .hash_counter = 0,
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        var css_p = css_parser.Parser.init(self.allocator, self.input);
        var stylesheet = try css_p.parse();
        errdefer stylesheet.deinit();

        try self.scopeClassNames(&stylesheet);
        return stylesheet;
    }

    fn scopeClassNames(self: *Parser, stylesheet: *ast.Stylesheet) !void {
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    for (style_rule.selectors.items) |*selector| {
                        try self.scopeSelector(selector);
                    }
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    for (style_rule.selectors.items) |*selector| {
                                        try self.scopeSelector(selector);
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

    fn scopeSelector(self: *Parser, selector: *ast.Selector) !void {
        for (selector.parts.items) |*part| {
            switch (part.*) {
                .class => |class_name| {
                    const scoped_name = try self.getScopedClassName(class_name);
                    part.* = .{ .class = scoped_name };
                },
                else => {},
            }
        }
    }

    fn getScopedClassName(self: *Parser, original_name: []const u8) ![]const u8 {
        if (self.class_map.get(original_name)) |scoped| {
            return scoped;
        }

        const hash = try self.generateHash(original_name);
        const scoped_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ original_name, hash });
        
        const original_copy = try self.allocator.dupe(u8, original_name);
        const scoped_copy = try self.allocator.dupe(u8, scoped_name);
        
        try self.class_map.put(original_copy, scoped_copy);
        return scoped_copy;
    }

    fn generateHash(self: *Parser, name: []const u8) ![]const u8 {
        var hasher = std.hash.Fnv1a_32.init();
        hasher.update(name);
        const hash_value = hasher.final();
        
        const hash_str = try std.fmt.allocPrint(self.allocator, "{x}", .{hash_value});
        return hash_str;
    }

    pub fn getClassMap(self: *const Parser) std.StringHashMap([]const u8) {
        return self.class_map;
    }

    pub fn deinit(self: *Parser) void {
        var it = self.class_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.class_map.deinit();
    }
};

test "parse CSS Modules and scope class names" {
    const css = ".container { color: red; } .button { background: blue; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, css);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 2);
    
    const rule1 = stylesheet.rules.items[0];
    try std.testing.expect(rule1 == .style);
    try std.testing.expect(rule1.style.selectors.items.len == 1);
    
    const selector1 = rule1.style.selectors.items[0];
    try std.testing.expect(selector1.parts.items.len > 0);
    
    const part = selector1.parts.items[0];
    try std.testing.expect(part == .class);
    try std.testing.expect(std.mem.startsWith(u8, part.class, "container_"));
}

test "CSS Modules generates consistent hashes" {
    const css = ".test { color: red; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p1 = Parser.init(allocator, css);
    defer p1.deinit();
    var stylesheet1 = try p1.parse();
    defer stylesheet1.deinit();

    var p2 = Parser.init(allocator, css);
    defer p2.deinit();
    var stylesheet2 = try p2.parse();
    defer stylesheet2.deinit();

    const rule1 = stylesheet1.rules.items[0];
    const rule2 = stylesheet2.rules.items[0];
    
    const scoped1 = rule1.style.selectors.items[0].parts.items[0].class;
    const scoped2 = rule2.style.selectors.items[0].parts.items[0].class;
    
    try std.testing.expect(std.mem.eql(u8, scoped1, scoped2));
}
