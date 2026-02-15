const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    variables: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        self.skipWhitespace();

        while (self.pos < self.input.len) {
            if (self.peek() == '@') {
                const next_pos = self.pos + 1;
                if (next_pos < self.input.len) {
                    const next_ch = self.input[next_pos];
                    if (std.ascii.isAlphabetic(next_ch) or next_ch == '-') {
                        try self.parseVariable();
                        self.skipWhitespace();
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        const input_without_vars = try self.removeVariables();
        defer self.allocator.free(input_without_vars);

        const processed_input = try self.processVariables(input_without_vars);
        defer self.allocator.free(processed_input);

        var css_p = css_parser.Parser.init(self.allocator, processed_input);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn parseVariable(self: *Parser) !void {
        if (self.peek() != '@') {
            return error.ExpectedAtSign;
        }
        self.advance();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == name_start) {
            return error.InvalidVariableName;
        }

        const name = self.input[name_start..self.pos];
        self.skipWhitespace();

        if (self.peek() != ':') {
            return error.ExpectedColon;
        }
        self.advance();
        self.skipWhitespace();

        const value_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == ';' or ch == '\n') {
                break;
            }
            self.advance();
        }

        var value = self.input[value_start..self.pos];
        value = std.mem.trim(u8, value, " \t");
        const value_copy = try self.allocator.dupe(u8, value);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.variables.put(name_copy, value_copy);

        if (self.peek() == ';') {
            self.advance();
        }
    }

    fn removeVariables(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.input.len) {
            if (self.input[i] == '@' and i + 1 < self.input.len) {
                const var_start = i;
                i += 1;

                if (std.ascii.isAlphabetic(self.input[i]) or self.input[i] == '-') {
                    while (i < self.input.len and (std.ascii.isAlphanumeric(self.input[i]) or self.input[i] == '-' or self.input[i] == '_')) {
                        i += 1;
                    }

                    if (i < self.input.len and self.input[i] == ':') {
                        i += 1;
                        self.skipWhitespaceAt(&i);

                        while (i < self.input.len) {
                            if (self.input[i] == ';' or self.input[i] == '\n') {
                                i += 1;
                                break;
                            }
                            i += 1;
                        }
                        continue;
                    } else {
                        i = var_start;
                    }
                } else {
                    i = var_start;
                }
            }

            try result.append(self.allocator, self.input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn skipWhitespaceAt(self: *Parser, pos: *usize) void {
        while (pos.* < self.input.len and std.ascii.isWhitespace(self.input[pos.*])) {
            pos.* += 1;
        }
    }

    fn processVariables(self: *Parser, input: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '@' and i + 1 < input.len) {
                const var_start = i + 1;
                var var_end = var_start;

                if (std.ascii.isAlphabetic(input[var_end]) or input[var_end] == '-') {
                    while (var_end < input.len) {
                        const ch = input[var_end];
                        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                            var_end += 1;
                        } else {
                            break;
                        }
                    }

                    if (var_end > var_start) {
                        const var_name = input[var_start..var_end];
                        if (self.variables.get(var_name)) |value| {
                            try result.appendSlice(self.allocator, value);
                            i = var_end;
                            continue;
                        }
                    }
                }
            }

            try result.append(self.allocator, input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (std.ascii.isWhitespace(ch)) {
                self.advance();
            } else if (ch == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
                self.skipComment();
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Parser) void {
        self.pos += 2;
        while (self.pos < self.input.len - 1) {
            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                self.pos += 2;
                return;
            }
            self.advance();
        }
    }

    fn peek(self: *const Parser) u8 {
        if (self.pos >= self.input.len) {
            return 0;
        }
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            self.pos += 1;
        }
    }

    pub fn deinit(self: *Parser) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();
    }
};

test "parse LESS variables" {
    const less = "@primary-color: red;\n.container { color: @primary-color; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, less);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "parse LESS with multiple variables" {
    const less = "@color1: red; @color2: blue; .test { color: @color1; background: @color2; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, less);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[1].value, "blue"));
}

test "parse LESS with at-rules" {
    const less = "@media (min-width: 768px) { .container { width: 100%; } }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, less);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .at_rule);
    try std.testing.expect(std.mem.eql(u8, rule.at_rule.name, "media"));
}
