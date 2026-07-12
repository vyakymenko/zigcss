const std = @import("std");

pub const max_header_bytes: usize = 8 * 1024;
pub const default_max_message_bytes: usize = 16 * 1024 * 1024;

const header_terminator = "\r\n\r\n";

pub fn readFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) !?[]u8 {
    return readFrameWithLimit(allocator, reader, default_max_message_bytes);
}

pub fn readFrameWithLimit(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_message_bytes: usize,
) !?[]u8 {
    var header_buffer: [max_header_bytes]u8 = undefined;
    var header_len: usize = 0;

    while (true) {
        if (header_len == header_buffer.len) return error.HeaderTooLarge;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (header_len == 0) return null;
                return error.TruncatedHeader;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        header_buffer[header_len] = byte;
        header_len += 1;

        if (byte == '\n' and (header_len < 2 or header_buffer[header_len - 2] != '\r')) {
            return error.InvalidHeaderTermination;
        }
        if (header_len >= header_terminator.len and
            std.mem.eql(
                u8,
                header_buffer[header_len - header_terminator.len .. header_len],
                header_terminator,
            ))
        {
            break;
        }
    }

    const header = header_buffer[0 .. header_len - header_terminator.len];
    const content_length = try parseContentLength(header);
    if (content_length > max_message_bytes) return error.MessageTooLarge;

    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    reader.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedBody,
        error.ReadFailed => return error.ReadFailed,
    };
    return body;
}

pub fn writeFrame(writer: anytype, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

fn parseContentLength(header: []const u8) !usize {
    var content_length: ?usize = null;
    var fields = std.mem.splitSequence(u8, header, "\r\n");
    while (fields.next()) |field| {
        if (field.len == 0) return error.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse
            return error.InvalidHeader;
        const name = field[0..colon];
        if (name.len == 0) return error.InvalidHeader;
        for (name) |byte| if (!isHeaderNameByte(byte)) return error.InvalidHeader;

        const raw_value = field[colon + 1 ..];
        for (raw_value) |byte| {
            if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidHeader;
        }
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        if (content_length != null) return error.DuplicateContentLength;
        content_length = try parseDecimalLength(std.mem.trim(u8, raw_value, " \t"));
    }
    return content_length orelse error.MissingContentLength;
}

fn parseDecimalLength(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidContentLength;
    var result: usize = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidContentLength;
        result = std.math.mul(usize, result, 10) catch return error.InvalidContentLength;
        result = std.math.add(usize, result, byte - '0') catch
            return error.InvalidContentLength;
    }
    return result;
}

fn isHeaderNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn appendTestFrame(output: *std.ArrayList(u8), body: []const u8) !void {
    try writeFrame(output.writer(std.testing.allocator), body);
}

test "dynamic framing reads sequential messages and clean EOF" {
    const allocator = std.testing.allocator;
    const large = try allocator.alloc(u8, 9 * 1024);
    defer allocator.free(large);
    @memset(large, 'x');

    var transcript = std.ArrayList(u8).empty;
    defer transcript.deinit(allocator);
    try appendTestFrame(&transcript, large);
    try appendTestFrame(&transcript, "{}");

    var reader = std.Io.Reader.fixed(transcript.items);
    const first = (try readFrame(allocator, &reader)).?;
    defer allocator.free(first);
    try std.testing.expectEqualSlices(u8, large, first);

    const second = (try readFrame(allocator, &reader)).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("{}", second);
    try std.testing.expect((try readFrame(allocator, &reader)) == null);
}

test "framing accepts bounded HTTP-style headers and writes exact bytes" {
    const input =
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "cOnTeNt-LeNgTh:\t2 \r\n\r\n{}";
    var reader = std.Io.Reader.fixed(input);
    const body = (try readFrame(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{}", body);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);
    try writeFrame(output.writer(std.testing.allocator), "{\"ok\":true}");
    try std.testing.expectEqualStrings(
        "Content-Length: 11\r\n\r\n{\"ok\":true}",
        output.items,
    );
}

test "framing rejects malformed truncated duplicate and oversized messages" {
    const Case = struct {
        expected: anyerror,
        input: []const u8,
        limit: usize = default_max_message_bytes,
    };
    const cases = [_]Case{
        .{ .expected = error.MissingContentLength, .input = "Content-Type: x\r\n\r\n" },
        .{
            .expected = error.DuplicateContentLength,
            .input = "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}",
        },
        .{ .expected = error.InvalidContentLength, .input = "Content-Length: +2\r\n\r\n{}" },
        .{ .expected = error.InvalidContentLength, .input = "Content-Length: 999999999999999999999999\r\n\r\n" },
        .{ .expected = error.InvalidHeaderTermination, .input = "Content-Length: 2\n\n{}" },
        .{ .expected = error.TruncatedHeader, .input = "Content-Length: 2\r\n" },
        .{ .expected = error.TruncatedBody, .input = "Content-Length: 3\r\n\r\n{}" },
        .{ .expected = error.MessageTooLarge, .input = "Content-Length: 2\r\n\r\n{}", .limit = 1 },
    };
    for (cases) |case| {
        var reader = std.Io.Reader.fixed(case.input);
        try std.testing.expectError(
            case.expected,
            readFrameWithLimit(std.testing.allocator, &reader, case.limit),
        );
    }

    var long_header: [max_header_bytes + 1]u8 = undefined;
    @memset(&long_header, 'x');
    var long_reader = std.Io.Reader.fixed(&long_header);
    try std.testing.expectError(
        error.HeaderTooLarge,
        readFrame(std.testing.allocator, &long_reader),
    );
}

fn exerciseFrameAllocationFailure(allocator: std.mem.Allocator) !void {
    var reader = std.Io.Reader.fixed("Content-Length: 2\r\n\r\n{}");
    const body = (try readFrame(allocator, &reader)).?;
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{}", body);
}

test "dynamic frame ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFrameAllocationFailure,
        .{},
    );
}
