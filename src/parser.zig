const std = @import("std");
const ast = @import("ast.zig");
const string_pool = @import("string_pool.zig");
const simd = @import("simd.zig");
const error_module = @import("error.zig");

pub const ParseError = error_module.ParseError;

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    allocator: std.mem.Allocator,
    string_pool: *string_pool.StringPool,
    owns_pool: bool,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        const pool = allocator.create(string_pool.StringPool) catch @panic("Failed to create string pool");
        pool.* = string_pool.StringPool.init(allocator);
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
            .string_pool = pool,
            .owns_pool = true,
        };
    }

    pub fn initWithPool(allocator: std.mem.Allocator, input: []const u8, pool: *string_pool.StringPool) Parser {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
            .string_pool = pool,
            .owns_pool = false,
        };
    }

    pub const ParseResult = union(enum) {
        success: ast.Stylesheet,
        parse_error: ParseError,
    };

    pub fn parseWithErrorInfo(self: *Parser) ParseResult {
        const result = self.parse() catch |err| {
            return .{ .parse_error = switch (err) {
                error.ExpectedOpeningBrace => self.makeError(.ExpectedOpeningBrace),
                error.ExpectedColon => self.makeError(.ExpectedColon),
                error.ExpectedAtSign => self.makeError(.ExpectedAtSign),
                error.InvalidIdentifier => self.makeError(.InvalidIdentifier),
                else => self.makeError(.InvalidSyntax),
            } };
        };
        return .{ .success = result };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        const estimated_rules = self.estimateRuleCount();
        var stylesheet = try ast.Stylesheet.initWithCapacity(self.allocator, estimated_rules);
        errdefer stylesheet.deinit();

        if (stylesheet.string_pool) |pool| {
            if (stylesheet.owns_string_pool) {
                pool.deinit();
                stylesheet.allocator.destroy(pool);
            }
        }
        stylesheet.string_pool = self.string_pool;
        stylesheet.owns_string_pool = self.owns_pool;
        if (self.owns_pool) {
            self.owns_pool = false;
        }

        self.skipWhitespace();

        while (self.pos < self.input.len) {
            if (self.peek() == '@') {
                const at_rule = try self.parseAtRule();
                try stylesheet.rules.append(self.allocator, ast.Rule{ .at_rule = at_rule });
            } else {
                const style_rule = try self.parseStyleRule();
                try stylesheet.rules.append(self.allocator, ast.Rule{ .style = style_rule });
            }
            self.skipWhitespace();
        }

        return stylesheet;
    }

    fn estimateRuleCount(self: *const Parser) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.input.len) {
            if (self.input[i] == '{' or self.input[i] == '@') {
                count += 1;
            }
            i += 1;
        }
        return @max(count / 2, 4);
    }

    fn estimateDeclarationCount(self: *const Parser) usize {
        var count: usize = 0;
        var i: usize = self.pos;
        var depth: usize = 0;
        while (i < self.input.len and depth < 2) {
            const ch = self.input[i];
            if (ch == '{') {
                depth += 1;
            } else if (ch == '}') {
                if (depth == 0) break;
                depth -= 1;
            } else if (ch == ':' and depth == 1) {
                count += 1;
            }
            i += 1;
        }
        return @max(count, 2);
    }

    fn parseStyleRule(self: *Parser) !ast.StyleRule {
        const estimated_decls = self.estimateDeclarationCount();
        var rule = try ast.StyleRule.initWithCapacity(self.allocator, 1, estimated_decls);
        errdefer rule.deinit();

        while (true) {
            const selector = try self.parseSelector();
            try rule.selectors.append(self.allocator, selector);

            self.skipWhitespace();
            if (self.peek() == ',') {
                self.advance();
                self.skipWhitespace();
                continue;
            }
            break;
        }

        self.skipWhitespace();
        if (self.peek() != '{') {
            return error.ExpectedOpeningBrace;
        }
        self.advance();
        self.skipWhitespace();

        while (self.pos < self.input.len and self.peek() != '}') {
            const decl = try self.parseDeclaration();
            try rule.declarations.append(self.allocator, decl);
            self.skipWhitespace();
            if (self.peek() == ';') {
                self.advance();
                self.skipWhitespace();
            }
        }

        if (self.peek() == '}') {
            self.advance();
        }

        return rule;
    }

    fn parseSelector(self: *Parser) !ast.Selector {
        var selector = try ast.Selector.initWithCapacity(self.allocator, 4);
        errdefer selector.deinit();

        while (self.pos < self.input.len) {
            self.skipWhitespace();

            const ch = self.peek();
            if (ch == '{' or ch == ',' or ch == '}') {
                break;
            }

            if (ch == '.') {
                self.advance();
                const name = try self.parseIdentifier();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .class = name });
            } else if (ch == '#') {
                self.advance();
                const name = try self.parseIdentifier();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .id = name });
            } else if (ch == '*') {
                self.advance();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .universal = {} });
            } else if (ch == ':') {
                self.advance();
                if (self.peek() == ':') {
                    self.advance();
                    const name = try self.parseIdentifier();
                    try selector.parts.append(self.allocator, ast.SelectorPart{ .pseudo_element = name });
                } else {
                    const name = try self.parseIdentifier();
                    try selector.parts.append(self.allocator, ast.SelectorPart{ .pseudo_class = name });
                }
            } else if (ch == '>') {
                self.advance();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .combinator = .child });
            } else if (ch == '+') {
                self.advance();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .combinator = .next_sibling });
            } else if (ch == '~') {
                self.advance();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .combinator = .following_sibling });
            } else if (isAlnumOrDash(ch)) {
                const name = try self.parseIdentifier();
                try selector.parts.append(self.allocator, ast.SelectorPart{ .type = name });
            } else {
                self.advance();
            }
        }

        return selector;
    }

    fn parseDeclaration(self: *Parser) !ast.Declaration {
        const property = try self.parseIdentifier();
        self.skipWhitespace();

        if (self.peek() != ':') {
            return error.ExpectedColon;
        }
        self.advance();
        self.skipWhitespace();

        const value_start = self.pos;
        var value_end = self.pos;
        var important = false;

        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == ';' or ch == '}') {
                break;
            }
            if (ch == '!') {
                const remaining = self.input[self.pos..];
                if (std.mem.startsWith(u8, remaining, "!important")) {
                    important = true;
                    value_end = self.pos;
                    self.pos += 10;
                    break;
                }
            }
            value_end = self.pos + 1;
            self.advance();
        }

        var value = self.input[value_start..value_end];
        value = std.mem.trim(u8, value, " \t\n\r");
        const value_interned = try self.string_pool.intern(value);

        var decl = ast.Declaration.init(self.allocator);
        decl.property = property;
        decl.value = value_interned;
        decl.important = important;
        return decl;
    }

    fn parseAtRule(self: *Parser) !ast.AtRule {
        if (self.peek() != '@') {
            return error.ExpectedAtSign;
        }
        self.advance();

        const name = try self.parseIdentifier();
        self.skipWhitespace();

        const prelude_start = self.pos;
        var prelude_end = self.pos;

        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == '{' or ch == ';') {
                prelude_end = self.pos;
                break;
            }
            self.advance();
            prelude_end = self.pos;
        }

        var prelude_raw = self.input[prelude_start..prelude_end];
        prelude_raw = std.mem.trim(u8, prelude_raw, " \t\n\r");
        const prelude = try self.string_pool.intern(prelude_raw);

        var at_rule = ast.AtRule.init(self.allocator);
        at_rule.name = name;
        at_rule.prelude = prelude;

        if (self.peek() == '{') {
            self.advance();
            self.skipWhitespace();

            var rules = try std.ArrayList(ast.Rule).initCapacity(self.allocator, 0);
            errdefer rules.deinit(self.allocator);

            while (self.pos < self.input.len and self.peek() != '}') {
                if (self.peek() == '@') {
                    const nested_at_rule = try self.parseAtRule();
                    try rules.append(self.allocator, ast.Rule{ .at_rule = nested_at_rule });
                } else {
                    const style_rule = try self.parseStyleRule();
                    try rules.append(self.allocator, ast.Rule{ .style = style_rule });
                }
                self.skipWhitespace();
            }

            if (self.peek() == '}') {
                self.advance();
            }

            at_rule.rules = rules;
        } else if (self.peek() == ';') {
            self.advance();
        }

        return at_rule;
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        const start = self.pos;

        if (self.pos < self.input.len) {
            const first = self.input[self.pos];
            if (first == '-') {
                self.advance();
            } else if (!isAlpha(first) and first != '_') {
                return error.InvalidIdentifier;
            }
        }

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (isAlnumOrDash(ch)) {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == start) {
            return error.InvalidIdentifier;
        }

        return try self.string_pool.internSlice(start, self.pos, self.input);
    }

    const CHAR_CLASS = initCharClass();

    fn initCharClass() [256]u8 {
        comptime {
            @setEvalBranchQuota(10000);
            var table: [256]u8 = undefined;
            for (&table, 0..) |*entry, i| {
                const ch = @as(u8, @intCast(i));
                var flags: u8 = 0;
                if (std.ascii.isAlphabetic(ch)) flags |= 1;
                if (std.ascii.isDigit(ch)) flags |= 2;
                if (std.ascii.isAlphanumeric(ch)) flags |= 4;
                if (ch == '-' or ch == '_') flags |= 8;
                entry.* = flags;
            }
            return table;
        }
    }

    inline fn isAlpha(ch: u8) bool {
        return (CHAR_CLASS[ch] & 1) != 0;
    }

    inline fn isAlnum(ch: u8) bool {
        return (CHAR_CLASS[ch] & 4) != 0;
    }

    inline fn isAlnumOrDash(ch: u8) bool {
        return (CHAR_CLASS[ch] & 12) != 0;
    }

    fn skipWhitespace(self: *Parser) void {
        if (self.pos < self.input.len and self.input[self.pos] == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
            self.skipComment();
            self.skipWhitespace();
            return;
        }
        simd.skipWhitespaceSimd(self.input, &self.pos);
        if (self.pos < self.input.len and self.input[self.pos] == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
            self.skipComment();
            self.skipWhitespace();
        }
    }

    fn skipComment(self: *Parser) void {
        self.pos += 2;
        const end = self.input.len - 1;
        while (self.pos < end) {
            if (self.input[self.pos] == '*') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                    self.pos += 2;
                    return;
                }
            }
            self.pos += 1;
        }
        self.pos = self.input.len;
    }

    inline fn peek(self: *const Parser) u8 {
        if (self.pos >= self.input.len) {
            return 0;
        }
        return self.input[self.pos];
    }

    inline fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '\n') {
                self.line += 1;
                self.column = 1;
            } else if (ch == '\r') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') {
                    self.pos += 1;
                }
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn makeError(self: *const Parser, kind: error_module.ParseError.ErrorKind) ParseError {
        return ParseError{
            .kind = kind,
            .line = self.line,
            .column = self.column,
            .message = error_module.ParseError.getMessage(kind),
        };
    }
};
