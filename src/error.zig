const std = @import("std");

pub const ParseError = struct {
    kind: ErrorKind,
    line: usize,
    column: usize,
    message: []const u8,

    pub const ErrorKind = enum {
        ExpectedOpeningBrace,
        ExpectedColon,
        ExpectedAtSign,
        InvalidIdentifier,
        UnexpectedToken,
        UnexpectedEndOfFile,
        InvalidSyntax,
    };

    pub fn format(
        self: ParseError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Parse error at line {d}, column {d}: {s}", .{
            self.line,
            self.column,
            self.message,
        });
    }

    pub fn getMessage(kind: ErrorKind) []const u8 {
        return switch (kind) {
            .ExpectedOpeningBrace => "expected opening brace '{'",
            .ExpectedColon => "expected colon ':'",
            .ExpectedAtSign => "expected '@'",
            .InvalidIdentifier => "invalid identifier",
            .UnexpectedToken => "unexpected token",
            .UnexpectedEndOfFile => "unexpected end of file",
            .InvalidSyntax => "invalid syntax",
        };
    }
};

pub fn calculateLineColumn(input: []const u8, pos: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;

    while (i < pos and i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            line += 1;
            column = 1;
        } else if (input[i] == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') {
                i += 1;
                line += 1;
                column = 1;
            } else {
                line += 1;
                column = 1;
            }
        } else {
            column += 1;
        }
    }

    return .{ .line = line, .column = column };
}

pub fn getLineContext(input: []const u8, line: usize) struct { start: usize, end: usize, line_num: usize } {
    var current_line: usize = 1;
    var start: usize = 0;
    var i: usize = 0;

    while (i < input.len and current_line < line) {
        if (input[i] == '\n') {
            current_line += 1;
            if (current_line == line) {
                start = i + 1;
            }
        } else if (input[i] == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') {
                i += 1;
            }
            current_line += 1;
            if (current_line == line) {
                start = i + 1;
            }
        }
        i += 1;
    }

    if (current_line < line) {
        return .{ .start = input.len, .end = input.len, .line_num = current_line };
    }

    if (start == 0 and line == 1) {
        start = 0;
    }

    var end = start;
    while (end < input.len and input[end] != '\n' and input[end] != '\r') {
        end += 1;
    }

    return .{ .start = start, .end = end, .line_num = line };
}

pub fn formatErrorWithContext(
    allocator: std.mem.Allocator,
    input: []const u8,
    filename: []const u8,
    parse_error: ParseError,
) ![]const u8 {
    const context = getLineContext(input, parse_error.line);
    const line_content = if (context.start < input.len)
        input[context.start..context.end]
    else
        "";

    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);

    try writer.print("error: {s}\n", .{parse_error.message});
    try writer.print("  --> {s}:{d}:{d}\n", .{ filename, parse_error.line, parse_error.column });
    try writer.print("   |\n", .{});
    try writer.print(" {d} | {s}\n", .{ parse_error.line, line_content });
    try writer.print("   |", .{});

    var col: usize = 1;
    while (col < parse_error.column) : (col += 1) {
        if (col <= line_content.len and line_content[col - 1] == '\t') {
            try writer.writeAll("    ");
        } else {
            try writer.writeAll(" ");
        }
    }
    try writer.writeAll("^\n");

    return try buffer.toOwnedSlice(allocator);
}
