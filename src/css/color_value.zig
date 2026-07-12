const std = @import("std");
const color = @import("color.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidSpan,
    InvalidSyntax,
    NestingLimit,
    SourceMismatch,
    UnterminatedSyntax,
};

pub const Options = struct {
    max_nesting: usize = 64,
};

pub const SyntaxKind = enum { hex, named, rgb };

pub const Parsed = struct {
    color: color.Color,
    syntax: SyntaxKind,
    span: source.Span,
};

const ParsedValue = struct {
    color: color.Color,
    syntax: SyntaxKind,
};

/// Parses only exact 8-bit sRGB colors: hexadecimal notation, the basic named
/// color set (plus transparent aliases), and integer/endpoint rgb()/rgba()
/// forms. Wider color spaces, missing channels, calculations, fractional
/// channels, and non-endpoint alpha values conservatively return null.
pub fn parse(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    options: Options,
) Error!?Parsed {
    try validateValues(file, values, 0, options.max_nesting, null);
    const significant = trimWhitespace(values, 0, values.len);
    if (significant.end - significant.start != 1) return null;
    const value = values[significant.start];
    const parsed_value: ParsedValue = switch (value) {
        .token => |token| switch (token.kind) {
            .hash => if (try parseHex(allocator, file, token)) |parsed_color|
                ParsedValue{ .color = parsed_color, .syntax = .hex }
            else
                null,
            .ident => if (try parseNamed(allocator, file, token)) |parsed_color|
                ParsedValue{ .color = parsed_color, .syntax = .named }
            else
                null,
            else => null,
        },
        .function => |function| if (try parseRgbFunction(allocator, file, function)) |parsed_color|
            ParsedValue{ .color = parsed_color, .syntax = .rgb }
        else
            null,
        .simple_block => null,
    } orelse return null;
    return .{ .color = parsed_value.color, .syntax = parsed_value.syntax, .span = value.span() };
}

const Range = struct { start: usize, end: usize };

fn trimWhitespace(values: []const syntax.ComponentValue, start: usize, end: usize) Range {
    var first = start;
    while (first < end and isWhitespace(values[first])) : (first += 1) {}
    var last = end;
    while (last > first and isWhitespace(values[last - 1])) : (last -= 1) {}
    return .{ .start = first, .end = last };
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn parseHex(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    token: tokenizer.Token,
) Error!?color.Color {
    const decoded = try decodeText(allocator, file, token);
    defer allocator.free(decoded);
    if (decoded.len != 3 and decoded.len != 4 and decoded.len != 6 and decoded.len != 8) {
        return null;
    }
    for (decoded) |byte| _ = hexNibble(byte) orelse return null;

    if (decoded.len == 3 or decoded.len == 4) {
        return .{
            .red = hexNibble(decoded[0]).? * 17,
            .green = hexNibble(decoded[1]).? * 17,
            .blue = hexNibble(decoded[2]).? * 17,
            .alpha = if (decoded.len == 4) hexNibble(decoded[3]).? * 17 else 255,
        };
    }
    return .{
        .red = hexByte(decoded[0], decoded[1]),
        .green = hexByte(decoded[2], decoded[3]),
        .blue = hexByte(decoded[4], decoded[5]),
        .alpha = if (decoded.len == 8) hexByte(decoded[6], decoded[7]) else 255,
    };
}

fn hexByte(high: u8, low: u8) u8 {
    return (hexNibble(high).? << 4) | hexNibble(low).?;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

const NamedColor = struct {
    name: []const u8,
    value: color.Color,
};

const named_colors = [_]NamedColor{
    .{ .name = "aqua", .value = .{ .red = 0, .green = 255, .blue = 255 } },
    .{ .name = "black", .value = .{ .red = 0, .green = 0, .blue = 0 } },
    .{ .name = "blue", .value = .{ .red = 0, .green = 0, .blue = 255 } },
    .{ .name = "fuchsia", .value = .{ .red = 255, .green = 0, .blue = 255 } },
    .{ .name = "gray", .value = .{ .red = 128, .green = 128, .blue = 128 } },
    .{ .name = "green", .value = .{ .red = 0, .green = 128, .blue = 0 } },
    .{ .name = "lime", .value = .{ .red = 0, .green = 255, .blue = 0 } },
    .{ .name = "maroon", .value = .{ .red = 128, .green = 0, .blue = 0 } },
    .{ .name = "navy", .value = .{ .red = 0, .green = 0, .blue = 128 } },
    .{ .name = "olive", .value = .{ .red = 128, .green = 128, .blue = 0 } },
    .{ .name = "purple", .value = .{ .red = 128, .green = 0, .blue = 128 } },
    .{ .name = "red", .value = .{ .red = 255, .green = 0, .blue = 0 } },
    .{ .name = "silver", .value = .{ .red = 192, .green = 192, .blue = 192 } },
    .{ .name = "teal", .value = .{ .red = 0, .green = 128, .blue = 128 } },
    .{ .name = "white", .value = .{ .red = 255, .green = 255, .blue = 255 } },
    .{ .name = "yellow", .value = .{ .red = 255, .green = 255, .blue = 0 } },
    .{ .name = "cyan", .value = .{ .red = 0, .green = 255, .blue = 255 } },
    .{ .name = "magenta", .value = .{ .red = 255, .green = 0, .blue = 255 } },
    .{ .name = "grey", .value = .{ .red = 128, .green = 128, .blue = 128 } },
    .{ .name = "transparent", .value = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 } },
};

fn parseNamed(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    token: tokenizer.Token,
) Error!?color.Color {
    const decoded = try decodeText(allocator, file, token);
    defer allocator.free(decoded);
    for (named_colors) |entry| {
        if (std.ascii.eqlIgnoreCase(decoded, entry.name)) return entry.value;
    }
    return null;
}

fn parseRgbFunction(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    function: *const syntax.Function,
) Error!?color.Color {
    const decoded = try decodeText(allocator, file, function.opening);
    defer allocator.free(decoded);
    if (!std.ascii.eqlIgnoreCase(decoded, "rgb") and
        !std.ascii.eqlIgnoreCase(decoded, "rgba"))
    {
        return null;
    }
    var parser = RgbParser{ .values = function.values };
    return parser.parse();
}

const ChannelKind = enum { number, percentage };

const Channel = struct {
    value: u8,
    kind: ChannelKind,
};

const RgbParser = struct {
    values: []const syntax.ComponentValue,
    cursor: usize = 0,

    fn parse(self: *RgbParser) ?color.Color {
        _ = self.skipWhitespace();
        const first = self.parseChannel() orelse return null;
        const gap_after_first = self.skipWhitespace();
        if (self.consumeKind(.comma)) return self.parseLegacy(first);
        if (!gap_after_first) return null;
        return self.parseModern(first);
    }

    fn parseLegacy(self: *RgbParser, first: Channel) ?color.Color {
        _ = self.skipWhitespace();
        const second = self.parseChannel() orelse return null;
        if (second.kind != first.kind) return null;
        _ = self.skipWhitespace();
        if (!self.consumeKind(.comma)) return null;
        _ = self.skipWhitespace();
        const third = self.parseChannel() orelse return null;
        if (third.kind != first.kind) return null;
        _ = self.skipWhitespace();

        var alpha: u8 = 255;
        if (self.consumeKind(.comma)) {
            _ = self.skipWhitespace();
            alpha = self.parseAlpha() orelse return null;
            _ = self.skipWhitespace();
        }
        if (self.cursor != self.values.len) return null;
        return .{ .red = first.value, .green = second.value, .blue = third.value, .alpha = alpha };
    }

    fn parseModern(self: *RgbParser, first: Channel) ?color.Color {
        const second = self.parseChannel() orelse return null;
        if (!self.skipWhitespace()) return null;
        const third = self.parseChannel() orelse return null;
        _ = self.skipWhitespace();

        var alpha: u8 = 255;
        if (self.consumeSlash()) {
            _ = self.skipWhitespace();
            alpha = self.parseAlpha() orelse return null;
            _ = self.skipWhitespace();
        }
        if (self.cursor != self.values.len) return null;
        return .{ .red = first.value, .green = second.value, .blue = third.value, .alpha = alpha };
    }

    fn parseChannel(self: *RgbParser) ?Channel {
        const token = self.consumeToken() orelse return null;
        const numeric = switch (token.data) {
            .numeric => |value| value,
            else => return null,
        };
        if (!std.math.isFinite(numeric.value) or numeric.number_type != .integer) return null;
        return switch (token.kind) {
            .number => if (numeric.value >= 0 and numeric.value <= 255)
                .{ .value = @intFromFloat(numeric.value), .kind = .number }
            else
                null,
            .percentage => if (numeric.value == 0 or numeric.value == 100)
                .{ .value = if (numeric.value == 0) 0 else 255, .kind = .percentage }
            else
                null,
            else => null,
        };
    }

    fn parseAlpha(self: *RgbParser) ?u8 {
        const token = self.consumeToken() orelse return null;
        const numeric = switch (token.data) {
            .numeric => |value| value,
            else => return null,
        };
        if (!std.math.isFinite(numeric.value) or numeric.number_type != .integer) return null;
        return switch (token.kind) {
            .number => if (numeric.value == 0 or numeric.value == 1)
                (if (numeric.value == 0) 0 else 255)
            else
                null,
            .percentage => if (numeric.value == 0 or numeric.value == 100)
                (if (numeric.value == 0) 0 else 255)
            else
                null,
            else => null,
        };
    }

    fn skipWhitespace(self: *RgbParser) bool {
        const start = self.cursor;
        while (self.cursor < self.values.len and isWhitespace(self.values[self.cursor])) {
            self.cursor += 1;
        }
        return self.cursor != start;
    }

    fn consumeKind(self: *RgbParser, kind: tokenizer.TokenKind) bool {
        if (self.cursor >= self.values.len) return false;
        const token = switch (self.values[self.cursor]) {
            .token => |value| value,
            else => return false,
        };
        if (token.kind != kind) return false;
        self.cursor += 1;
        return true;
    }

    fn consumeSlash(self: *RgbParser) bool {
        if (self.cursor >= self.values.len) return false;
        const token = switch (self.values[self.cursor]) {
            .token => |value| value,
            else => return false,
        };
        if (token.kind != .delim or token.data != .delim or token.data.delim != '/') return false;
        self.cursor += 1;
        return true;
    }

    fn consumeToken(self: *RgbParser) ?tokenizer.Token {
        if (self.cursor >= self.values.len) return null;
        const token = switch (self.values[self.cursor]) {
            .token => |value| value,
            else => return null,
        };
        self.cursor += 1;
        return token;
    }
};

fn decodeText(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    token: tokenizer.Token,
) Error![]u8 {
    return token.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SourceMismatch => error.SourceMismatch,
        else => error.InvalidSyntax,
    };
}

fn validateValues(
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    depth: usize,
    max_depth: usize,
    parent: ?source.Span,
) Error!void {
    var previous_end: ?usize = null;
    for (values) |value| {
        const span = value.span();
        try validateSourceSpan(file, span);
        if (parent) |parent_span| {
            if (!parent_span.source.eql(span.source) or
                span.start < parent_span.start or span.end > parent_span.end)
            {
                return error.InvalidSpan;
            }
        }
        if (previous_end) |end| {
            if (span.start != end) return error.InvalidSpan;
        }
        previous_end = span.end;

        switch (value) {
            .token => |token| try validateToken(file, token),
            .simple_block => |block| {
                if (depth >= max_depth) return error.NestingLimit;
                const closing = block.closing orelse return error.UnterminatedSyntax;
                try validateToken(file, block.opening);
                try validateToken(file, closing);
                if ((block.opening.kind != .open_curly and
                    block.opening.kind != .open_square and
                    block.opening.kind != .open_paren) or
                    closing.kind != block.expectedClosing() or
                    block.span.start != block.opening.span.start or
                    block.opening.span.end > closing.span.start or
                    block.span.end != closing.span.end)
                {
                    return error.InvalidSyntax;
                }
                try validateValues(file, block.values, depth + 1, max_depth, .{
                    .source = file.id,
                    .start = block.opening.span.end,
                    .end = closing.span.start,
                });
            },
            .function => |function| {
                if (depth >= max_depth) return error.NestingLimit;
                const closing = function.closing orelse return error.UnterminatedSyntax;
                try validateToken(file, function.opening);
                try validateToken(file, closing);
                if (function.opening.kind != .function or
                    closing.kind != .close_paren or
                    function.span.start != function.opening.span.start or
                    function.opening.span.end > closing.span.start or
                    function.span.end != closing.span.end)
                {
                    return error.InvalidSyntax;
                }
                try validateValues(file, function.values, depth + 1, max_depth, .{
                    .source = file.id,
                    .start = function.opening.span.end,
                    .end = closing.span.start,
                });
            },
        }
    }

    if (parent) |parent_span| {
        if (values.len == 0) {
            if (!parent_span.isEmpty()) return error.InvalidSpan;
        } else if (values[0].span().start != parent_span.start or
            values[values.len - 1].span().end != parent_span.end)
        {
            return error.InvalidSpan;
        }
    }
}

fn validateToken(file: *const source.SourceFile, token: tokenizer.Token) Error!void {
    try validateSourceSpan(file, token.span);
    if (!token.isTerminated()) return error.UnterminatedSyntax;
    switch (token.data) {
        .text => |span| try validateContainedSpan(file, token.span, span),
        .hash => |hash| try validateContainedSpan(file, token.span, hash.value),
        .numeric => |numeric| try validateContainedSpan(file, token.span, numeric.representation),
        .dimension => |dimension| {
            try validateContainedSpan(file, token.span, dimension.numeric.representation);
            try validateContainedSpan(file, token.span, dimension.unit);
            if (dimension.numeric.representation.start != token.span.start or
                dimension.numeric.representation.end != dimension.unit.start or
                dimension.unit.end != token.span.end)
            {
                return error.InvalidSpan;
            }
        },
        .comment => |comment| try validateContainedSpan(file, token.span, comment.content),
        .none, .delim, .unicode_range => {},
    }
}

fn validateContainedSpan(
    file: *const source.SourceFile,
    container: source.Span,
    child: source.Span,
) Error!void {
    try validateSourceSpan(file, child);
    if (!container.source.eql(child.source) or
        child.start < container.start or child.end > container.end)
    {
        return error.InvalidSpan;
    }
}

fn validateSourceSpan(file: *const source.SourceFile, span: source.Span) Error!void {
    if (!span.source.eql(file.id)) return error.SourceMismatch;
    if (span.start > span.end or span.end > file.bytes.len) return error.InvalidSpan;
}

const pipeline = @import("pipeline.zig");

fn parseTestDeclaration(
    allocator: std.mem.Allocator,
    parsed: *const pipeline.ParsedStylesheet,
    index: usize,
    options: Options,
) !?Parsed {
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[index];
    return parse(allocator, parsed.file(), declaration.valueWithoutImportance(), options);
}

test "typed colors parse exact hex named and rgb sRGB forms" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "colors.css",
        ".a{a:#aabbcc;b:#abcd;c:#11223344;d:ReD;e:r\\65 d;f:#\\61 bc;" ++
            "g:rgb(255,0,0);h:rgba(0,128,0,1);i:rgb(100% 0 0 / 100%);" ++
            "j:rgb(0 0 255);k:rgba(18,52,86,0)}",
    );
    defer parsed.deinit();
    const expected = [_]color.Color{
        .{ .red = 170, .green = 187, .blue = 204 },
        .{ .red = 170, .green = 187, .blue = 204, .alpha = 221 },
        .{ .red = 17, .green = 34, .blue = 51, .alpha = 68 },
        .{ .red = 255, .green = 0, .blue = 0 },
        .{ .red = 255, .green = 0, .blue = 0 },
        .{ .red = 170, .green = 187, .blue = 204 },
        .{ .red = 255, .green = 0, .blue = 0 },
        .{ .red = 0, .green = 128, .blue = 0 },
        .{ .red = 255, .green = 0, .blue = 0 },
        .{ .red = 0, .green = 0, .blue = 255 },
        .{ .red = 18, .green = 52, .blue = 86, .alpha = 0 },
    };
    for (expected, 0..) |wanted, index| {
        const actual = (try parseTestDeclaration(std.testing.allocator, &parsed, index, .{})).?;
        try std.testing.expect(wanted.eql(actual.color));
    }
}

test "typed colors conservatively decline contextual fractional and wider syntax" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "unsupported-colors.css",
        ".a{a:currentColor;b:CanvasText;c:hsl(0 100% 50%);d:red blue;" ++
            "e:rgb(1.5,0,0);f:rgb(256,0,0);g:rgb(100%,0,0);" ++
            "h:rgb(1/**/ 2 3);i:rgba(0,0,0,.5);j:color(display-p3 1 0 0)}",
    );
    defer parsed.deinit();
    for (0..10) |index| {
        try std.testing.expect((try parseTestDeclaration(
            std.testing.allocator,
            &parsed,
            index,
            .{},
        )) == null);
    }
}

test "typed color parsing rejects foreign truncated and over-nested component trees" {
    var parsed = try pipeline.parse(std.testing.allocator, "source.css", ".a{x:rgb(1,2,3)}");
    defer parsed.deinit();
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[0];
    var foreign_file = parsed.file().*;
    foreign_file.id.value += 1;
    try std.testing.expectError(
        error.SourceMismatch,
        parse(std.testing.allocator, &foreign_file, declaration.valueWithoutImportance(), .{}),
    );

    var truncated = try pipeline.parse(std.testing.allocator, "truncated.css", ".a{x:rgb(1,2,3}");
    defer truncated.deinit();
    try std.testing.expectError(
        error.UnterminatedSyntax,
        parseTestDeclaration(std.testing.allocator, &truncated, 0, .{}),
    );

    var nested = try pipeline.parse(std.testing.allocator, "nested.css", ".a{x:rgb(calc(1),2,3)}");
    defer nested.deinit();
    try std.testing.expectError(
        error.NestingLimit,
        parseTestDeclaration(std.testing.allocator, &nested, 0, .{ .max_nesting = 1 }),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(allocator, "color-oom.css", ".a{x:r\\65 d}");
    defer parsed.deinit();
    const result = (try parseTestDeclaration(allocator, &parsed, 0, .{})).?;
    try std.testing.expect(result.color.eql(.{ .red = 255, .green = 0, .blue = 0 }));
}

test "typed color parsing handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
