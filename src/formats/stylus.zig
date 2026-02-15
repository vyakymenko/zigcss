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
        try self.parseVariables();
        const processed = try self.processVariables();
        defer self.allocator.free(processed);

        var css_p = css_parser.Parser.init(self.allocator, processed);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn parseVariables(self: *Parser) !void {
        self.pos = 0;
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.peek() == '$') {
                try self.parseVariable();
            } else {
                self.advance();
            }
        }
    }

    fn parseVariable(self: *Parser) !void {
        if (self.peek() != '$') {
            return error.ExpectedDollarSign;
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

        if (self.peek() != '=') {
            self.pos = name_start - 1;
            return;
        }
        self.advance();
        self.skipWhitespace();

        const value_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == '\n' or ch == '\r' or ch == ';') {
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
        if (self.peek() == '\n' or self.peek() == '\r') {
            self.advance();
        }
    }

    fn processVariables(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.input.len) {
            if (self.input[i] == '$' and i + 1 < self.input.len) {
                const next = self.input[i + 1];
                if (std.ascii.isAlphabetic(next) or next == '-') {
                    const var_start = i + 1;
                    var var_end = var_start;
                    
                    while (var_end < self.input.len) {
                        const ch = self.input[var_end];
                        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                            var_end += 1;
                        } else {
                            break;
                        }
                    }
                    
                    if (var_end > var_start) {
                        var scan_pos = var_end;
                        var is_decl = false;
                        
                        while (scan_pos < self.input.len) {
                            const ch = self.input[scan_pos];
                            if (ch == '=') {
                                is_decl = true;
                                break;
                            }
                            if (ch == '\n' or ch == ';' or ch == '{' or ch == ':') {
                                break;
                            }
                            if (ch != ' ' and ch != '\t') {
                                break;
                            }
                            scan_pos += 1;
                        }
                        
                        if (is_decl) {
                            while (i < self.input.len) {
                                if (self.input[i] == '\n' or self.input[i] == ';') {
                                    i += 1;
                                    break;
                                }
                                i += 1;
                            }
                            continue;
                        } else {
                            const var_name = self.input[var_start..var_end];
                            if (self.variables.get(var_name)) |value| {
                                try result.appendSlice(self.allocator, value);
                                i = var_end;
                                continue;
                            }
                        }
                    }
                }
            }

            try result.append(self.allocator, self.input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.pos += 1;
            } else {
                break;
            }
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

test "parse Stylus with variables" {
    const stylus = "$color = red\n.test\n  color: $color\n";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, stylus);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
}

test "parse Stylus basic syntax" {
    const stylus = ".container\n  color: red\n  padding: 20px\n";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, stylus);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
}
