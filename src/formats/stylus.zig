const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

const InfiniteLoop = error{InfiniteLoop};

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
        
        var processed = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        defer processed.deinit(self.allocator);
        
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
                        while (scan_pos < self.input.len and (self.input[scan_pos] == ' ' or self.input[scan_pos] == '\t')) {
                            scan_pos += 1;
                        }
                        
                        if (scan_pos < self.input.len and self.input[scan_pos] == '=') {
                            while (i < self.input.len and self.input[i] != '\n' and self.input[i] != ';') {
                                i += 1;
                            }
                            if (i < self.input.len) {
                                i += 1;
                            }
                            continue;
                        } else {
                            const var_name = self.input[var_start..var_end];
                            if (self.variables.get(var_name)) |value| {
                                try processed.appendSlice(self.allocator, value);
                                i = var_end;
                                continue;
                            }
                        }
                    }
                }
            }
            
            try processed.append(self.allocator, self.input[i]);
            i += 1;
        }
        
        const processed_str = try processed.toOwnedSlice(self.allocator);
        defer self.allocator.free(processed_str);

        var css_p = css_parser.Parser.init(self.allocator, processed_str);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn parseVariables(self: *Parser) !void {
        self.pos = 0;
        var last_pos: usize = 0;
        var iterations: usize = 0;
        
        while (self.pos < self.input.len) {
            if (iterations > self.input.len * 2) {
                return error.InfiniteLoop;
            }
            iterations += 1;
            
            if (self.pos == last_pos and self.pos < self.input.len) {
                self.advance();
                last_pos = self.pos;
                continue;
            }
            last_pos = self.pos;
            
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.peek() == '$') {
                const before_parse = self.pos;
                self.parseVariable() catch {};
                if (self.pos == before_parse) {
                    self.advance();
                }
            } else {
                self.advance();
            }
        }
    }

    fn parseVariable(self: *Parser) !void {
        if (self.peek() != '$') {
            return error.ExpectedDollarSign;
        }
        const dollar_pos = self.pos;
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
            self.pos = dollar_pos;
            return;
        }

        const name = self.input[name_start..self.pos];
        self.skipWhitespace();

        if (self.peek() != '=') {
            self.pos = dollar_pos;
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
    
    var stylesheet = p.parse() catch |err| {
        std.debug.print("Error parsing Stylus: {}\n", .{err});
        return err;
    };
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
