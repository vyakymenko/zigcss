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
        const css_content = try self.extractCSS();
        defer self.allocator.free(css_content);

        var css_p = css_parser.Parser.init(self.allocator, css_content);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn extractCSS(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var in_template_string = false;
        var in_object = false;
        var brace_depth: usize = 0;

        while (i < self.input.len) {
            const ch = self.input[i];
            const next_ch = if (i + 1 < self.input.len) self.input[i + 1] else 0;

            if (ch == '`' and !in_object) {
                in_template_string = !in_template_string;
                i += 1;
                continue;
            }

            if (in_template_string) {
                if (ch == '\\' and next_ch == '`') {
                    try result.append(self.allocator, '`');
                    i += 2;
                    continue;
                }
                if (ch == '$' and next_ch == '{') {
                    i += 2;
                    var expr_depth: usize = 1;
                    while (i < self.input.len and expr_depth > 0) {
                        if (self.input[i] == '{') {
                            expr_depth += 1;
                        } else if (self.input[i] == '}') {
                            expr_depth -= 1;
                        }
                        i += 1;
                    }
                    continue;
                }
                try result.append(self.allocator, ch);
                i += 1;
                continue;
            }

            if (ch == '{' and !in_template_string) {
                if (!in_object) {
                    in_object = true;
                    brace_depth = 1;
                    i += 1;
                    continue;
                } else {
                    brace_depth += 1;
                }
            }

            if (ch == '}' and in_object) {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    in_object = false;
                    i += 1;
                    continue;
                }
            }

            if (in_object) {
                if (ch == ':') {
                    try result.append(self.allocator, ':');
                    i += 1;
                    self.skipWhitespaceAt(&i);
                    continue;
                }
                if (ch == ',') {
                    try result.append(self.allocator, ';');
                    i += 1;
                    self.skipWhitespaceAt(&i);
                    continue;
                }
                if (ch == '\'' or ch == '"') {
                    const quote = ch;
                    i += 1;
                    while (i < self.input.len and self.input[i] != quote) {
                        if (self.input[i] == '\\' and i + 1 < self.input.len) {
                            i += 1;
                        }
                        try result.append(self.allocator, self.input[i]);
                        i += 1;
                    }
                    if (i < self.input.len) {
                        i += 1;
                    }
                    continue;
                }
                if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '#' or ch == '(' or ch == ')' or ch == '%' or ch == ' ' or ch == '\t' or ch == '\n') {
                    try result.append(self.allocator, ch);
                    i += 1;
                    continue;
                }
            }

            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn skipWhitespaceAt(self: *Parser, pos: *usize) void {
        while (pos.* < self.input.len and std.ascii.isWhitespace(self.input[pos.*])) {
            pos.* += 1;
        }
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }
};

test "parse CSS-in-JS template string" {
    const js = "const styles = ` .container { color: red; } `;";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, js);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].property, "color"));
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "parse CSS-in-JS object literal" {
    const js = "const styles = { container: { color: 'red', background: 'blue' } };";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, js);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
}

test "parse CSS-in-JS with expressions" {
    const js = "const styles = ` .container { color: ${color}; } `;";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = Parser.init(allocator, js);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
}
