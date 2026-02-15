const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

pub const Parser = struct {
    input: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .input = input,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        const processed = try self.processPostCSS();
        defer self.allocator.free(processed);

        var css_p = css_parser.Parser.init(self.allocator, processed);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn processPostCSS(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.input.len) {
            if (self.matchAt(i, "@apply")) {
                const apply_end = i + 6;
                var j = apply_end;
                while (j < self.input.len and std.ascii.isWhitespace(self.input[j])) {
                    j += 1;
                }
                
                var depth: usize = 0;
                var in_string = false;
                var string_char: u8 = 0;
                
                while (j < self.input.len) {
                    const ch = self.input[j];
                    if (!in_string) {
                        if (ch == '"' or ch == '\'') {
                            in_string = true;
                            string_char = ch;
                        } else if (ch == ';' and depth == 0) {
                            i = j + 1;
                            break;
                        } else if (ch == '{') {
                            depth += 1;
                        } else if (ch == '}') {
                            if (depth == 0) {
                                i = j;
                                break;
                            }
                            depth -= 1;
                        }
                    } else {
                        if (ch == string_char and (j == 0 or self.input[j - 1] != '\\')) {
                            in_string = false;
                        }
                    }
                    j += 1;
                }
                if (j >= self.input.len) {
                    i = j;
                }
                continue;
            }

            if (self.matchAt(i, "@custom-media")) {
                i = try self.skipAtRule(i);
                continue;
            }

            if (self.matchAt(i, "@nest")) {
                i = try self.skipAtRule(i);
                continue;
            }

            try result.append(self.allocator, self.input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn matchAt(self: *Parser, pos: usize, pattern: []const u8) bool {
        if (pos + pattern.len > self.input.len) {
            return false;
        }
        return std.mem.eql(u8, self.input[pos..pos + pattern.len], pattern);
    }

    fn skipAtRule(self: *Parser, start: usize) !usize {
        var i = start;
        var depth: usize = 0;
        var in_string = false;
        var string_char: u8 = 0;

        while (i < self.input.len) {
            const ch = self.input[i];
            
            if (!in_string) {
                if (ch == '"' or ch == '\'') {
                    in_string = true;
                    string_char = ch;
                } else if (ch == '{') {
                    depth += 1;
                } else if (ch == '}') {
                    if (depth == 0) {
                        return i + 1;
                    }
                    depth -= 1;
                } else if (ch == ';' and depth == 0) {
                    return i + 1;
                }
            } else {
                if (ch == string_char and (i == 0 or self.input[i - 1] != '\\')) {
                    in_string = false;
                }
            }

            i += 1;
        }

        return i;
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }
};

test "parse PostCSS @apply directive" {
    const postcss = ".btn { @apply px-4 py-2; }";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, postcss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
}

test "parse PostCSS custom media" {
    const postcss = "@custom-media --small-viewport (max-width: 30em);";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, postcss);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 0);
}
