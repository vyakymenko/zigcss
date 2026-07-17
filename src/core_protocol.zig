const std = @import("std");
const zigcss = @import("zigcss");

pub const protocol_version = "zigcss-core-v1";
pub const max_source_bytes = 20 * 1024 * 1024;
pub const max_request_frame_bytes = max_source_bytes + 64 * 1024;
pub const max_response_frame_bytes = 40 * 1024 * 1024;

const max_request_id_bytes = 64;
const max_source_url_bytes = 4096;

pub const Error = error{
    FrameTruncated,
    FrameLimit,
    FrameExtraBytes,
    InvalidRequest,
    InvalidProtocol,
    InvalidRequestId,
    InvalidOperation,
    InvalidSource,
    InvalidSourceUrl,
    InvalidOptions,
    ResponseLimit,
};

const Format = enum {
    pretty,
    minified,
};

const Options = struct {
    format: Format,
    sourceMap: bool,
    optimize: bool,
};

const Request = struct {
    protocol: []const u8,
    requestId: []const u8,
    operation: []const u8,
    source: []const u8,
    sourceUrl: []const u8,
    options: Options,
};

fn isRequestId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_request_id_bytes or !std.ascii.isAlphanumeric(value[0])) {
        return false;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn isSourceUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > max_source_url_bytes or
        !std.mem.startsWith(u8, value, "file:///") or
        std.mem.indexOfAny(u8, value, "\x00\r\n?#") != null or
        std.ascii.indexOfIgnoreCase(value, "%2f") != null or
        std.ascii.indexOfIgnoreCase(value, "%5c") != null)
    {
        return false;
    }
    return true;
}

fn validateRequest(request: Request) Error!void {
    if (!std.mem.eql(u8, request.protocol, protocol_version)) return error.InvalidProtocol;
    if (!isRequestId(request.requestId)) return error.InvalidRequestId;
    if (!std.mem.eql(u8, request.operation, "compile")) return error.InvalidOperation;
    if (request.source.len > max_source_bytes) return error.InvalidSource;
    if (!isSourceUrl(request.sourceUrl)) return error.InvalidSourceUrl;
    if (request.options.optimize and request.options.sourceMap) return error.InvalidOptions;
}

fn severityName(severity: zigcss.DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn hasErrors(diagnostics: []const zigcss.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn writeDiagnostic(json: *std.json.Stringify, diagnostic: zigcss.Diagnostic) !void {
    try json.beginObject();
    try json.objectField("severity");
    try json.write(severityName(diagnostic.severity));
    try json.objectField("code");
    try json.write(diagnostic.code.label());
    try json.objectField("message");
    try json.write(diagnostic.message);
    try json.objectField("sourceUrl");
    try json.write(diagnostic.source_name);
    try json.objectField("line");
    try json.write(diagnostic.start.line);
    try json.objectField("column");
    try json.write(diagnostic.start.column);
    try json.endObject();
}

fn writeDiagnostics(json: *std.json.Stringify, diagnostics: []const zigcss.Diagnostic) !void {
    try json.beginArray();
    for (diagnostics) |diagnostic| try writeDiagnostic(json, diagnostic);
    try json.endArray();
}

fn writeDependencies(json: *std.json.Stringify, dependencies: []const zigcss.Dependency) !void {
    try json.beginArray();
    for (dependencies) |dependency| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(switch (dependency.kind) {
            .import => "css-import",
            .css_module => "css-module",
        });
        try json.objectField("specifier");
        try json.write(dependency.specifier);
        try json.objectField("sourceUrl");
        try json.write(dependency.source_name);
        try json.objectField("start");
        try json.write(dependency.span.start);
        try json.objectField("end");
        try json.write(dependency.span.end);
        try json.endObject();
    }
    try json.endArray();
}

fn compileResponse(
    allocator: std.mem.Allocator,
    request: Request,
) ![]u8 {
    const options = zigcss.CompileOptions{
        .format = switch (request.options.format) {
            .pretty => .pretty,
            .minified => .minified,
        },
        .source_map = if (request.options.sourceMap)
            .{ .external = .{
                .generated_file = null,
                .include_sources_content = false,
            } }
        else
            .none,
        .transforms = .{ .optimize = request.options.optimize },
    };
    var result = try zigcss.compile(
        allocator,
        request.sourceUrl,
        request.source,
        options,
    );
    defer result.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol_version);
    try json.objectField("requestId");
    try json.write(request.requestId);
    try json.objectField("ok");
    const failed = hasErrors(result.diagnostics);
    try json.write(!failed);
    if (failed) {
        try json.objectField("error");
        try json.beginObject();
        try json.objectField("code");
        try json.write("CORE_COMPILE_ERROR");
        try json.objectField("message");
        try json.write("generated CSS was rejected");
        try json.objectField("diagnostics");
        try writeDiagnostics(&json, result.diagnostics);
        try json.endObject();
    } else {
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("css");
        try json.write(result.css);
        try json.objectField("sourceMap");
        try json.write(result.source_map);
        try json.objectField("diagnostics");
        try writeDiagnostics(&json, result.diagnostics);
        try json.objectField("dependencies");
        try writeDependencies(&json, result.dependencies);
        try json.endObject();
    }
    try json.endObject();
    const body = try output.toOwnedSlice();
    errdefer allocator.free(body);
    if (body.len == 0 or body.len > max_response_frame_bytes) return error.ResponseLimit;
    return body;
}

fn readFrameBody(input: []const u8) Error![]const u8 {
    if (input.len < 4) return error.FrameTruncated;
    const declared = std.mem.readInt(u32, input[0..4], .big);
    if (declared == 0 or declared > max_request_frame_bytes) return error.FrameLimit;
    const total = std.math.add(usize, @as(usize, declared), 4) catch return error.FrameLimit;
    if (input.len < total) return error.FrameTruncated;
    if (input.len > total) return error.FrameExtraBytes;
    return input[4..total];
}

pub fn processFrame(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const body = try readFrameBody(input);
    var parsed = std.json.parseFromSlice(Request, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    try validateRequest(parsed.value);

    const response_body = try compileResponse(allocator, parsed.value);
    defer allocator.free(response_body);
    const frame = try allocator.alloc(u8, response_body.len + 4);
    std.mem.writeInt(u32, frame[0..4], @intCast(response_body.len), .big);
    @memcpy(frame[4..], response_body);
    return frame;
}

pub fn runStdio(allocator: std.mem.Allocator) !void {
    const input = try std.fs.File.stdin().readToEndAlloc(allocator, max_request_frame_bytes + 5);
    defer allocator.free(input);
    const output = try processFrame(allocator, input);
    defer allocator.free(output);
    try std.fs.File.stdout().writeAll(output);
}

fn testFrame(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    var json: std.json.Stringify = .{ .writer = &body_writer.writer };
    try json.write(value);
    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);

    const frame = try allocator.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, frame[0..4], @intCast(body.len), .big);
    @memcpy(frame[4..], body);
    return frame;
}

fn testResponse(allocator: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    if (frame.len < 4) return error.FrameTruncated;
    const length = std.mem.readInt(u32, frame[0..4], .big);
    if (frame.len != @as(usize, length) + 4) return error.FrameTruncated;
    return std.json.parseFromSlice(std.json.Value, allocator, frame[4..], .{});
}

test "internal core protocol compiles generated CSS without recovery" {
    const allocator = std.testing.allocator;
    const request = try testFrame(allocator, .{
        .protocol = protocol_version,
        .requestId = "request-001",
        .operation = "compile",
        .source = ".card { color: red; }",
        .sourceUrl = "file:///workspace/.zigcss-intermediate.css",
        .options = .{
            .format = "minified",
            .sourceMap = true,
            .optimize = false,
        },
    });
    defer allocator.free(request);

    const response = try processFrame(allocator, request);
    defer allocator.free(response);
    var parsed = try testResponse(allocator, response);
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(protocol_version, object.get("protocol").?.string);
    try std.testing.expectEqualStrings("request-001", object.get("requestId").?.string);
    try std.testing.expect(object.get("ok").?.bool);
    const result = object.get("result").?.object;
    try std.testing.expectEqualStrings(".card{color:red}", result.get("css").?.string);
    try std.testing.expect(result.get("sourceMap").? == .string);
    try std.testing.expectEqual(@as(usize, 0), result.get("diagnostics").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.get("dependencies").?.array.items.len);
    var map = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.get("sourceMap").?.string,
        .{},
    );
    defer map.deinit();
    try std.testing.expectEqualStrings(
        "file:///workspace/.zigcss-intermediate.css",
        map.value.object.get("sources").?.array.items[0].string,
    );
}

test "internal core protocol preserves CSS import dependency facts" {
    const allocator = std.testing.allocator;
    const request = try testFrame(allocator, .{
        .protocol = protocol_version,
        .requestId = "request-import",
        .operation = "compile",
        .source = "@import \"theme.css\"; .card { color: red; }",
        .sourceUrl = "file:///workspace/.zigcss-intermediate.css",
        .options = .{
            .format = "minified",
            .sourceMap = false,
            .optimize = false,
        },
    });
    defer allocator.free(request);

    const response = try processFrame(allocator, request);
    defer allocator.free(response);
    var parsed = try testResponse(allocator, response);
    defer parsed.deinit();
    const dependencies = parsed.value.object.get("result").?.object.get("dependencies").?.array;
    try std.testing.expectEqual(@as(usize, 1), dependencies.items.len);
    const dependency = dependencies.items[0].object;
    try std.testing.expectEqualStrings("css-import", dependency.get("kind").?.string);
    try std.testing.expectEqualStrings("theme.css", dependency.get("specifier").?.string);
    try std.testing.expectEqualStrings(
        "file:///workspace/.zigcss-intermediate.css",
        dependency.get("sourceUrl").?.string,
    );
}

test "internal core protocol rejects invalid generated CSS without partial output" {
    const allocator = std.testing.allocator;
    const request = try testFrame(allocator, .{
        .protocol = protocol_version,
        .requestId = "request-002",
        .operation = "compile",
        .source = ".card { broken; color: red; }",
        .sourceUrl = "file:///workspace/.zigcss-intermediate.css",
        .options = .{
            .format = "pretty",
            .sourceMap = false,
            .optimize = false,
        },
    });
    defer allocator.free(request);

    const response = try processFrame(allocator, request);
    defer allocator.free(response);
    var parsed = try testResponse(allocator, response);
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(!object.get("ok").?.bool);
    try std.testing.expect(object.get("result") == null);
    const failure = object.get("error").?.object;
    try std.testing.expectEqualStrings("CORE_COMPILE_ERROR", failure.get("code").?.string);
    try std.testing.expect(failure.get("diagnostics").?.array.items.len > 0);
}

test "internal core protocol frame and request schema fail closed" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FrameTruncated, processFrame(allocator, ""));

    var oversized = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.FrameLimit, processFrame(allocator, &oversized));

    const unknown = try testFrame(allocator, .{
        .protocol = protocol_version,
        .requestId = "request-003",
        .operation = "compile",
        .source = ".a{}",
        .sourceUrl = "file:///workspace/.zigcss-intermediate.css",
        .options = .{ .format = "pretty", .sourceMap = false, .optimize = false },
        .unexpected = true,
    });
    defer allocator.free(unknown);
    try std.testing.expectError(error.InvalidRequest, processFrame(allocator, unknown));

    const conflicting = try testFrame(allocator, .{
        .protocol = protocol_version,
        .requestId = "request-004",
        .operation = "compile",
        .source = ".a{}",
        .sourceUrl = "file:///workspace/.zigcss-intermediate.css",
        .options = .{ .format = "pretty", .sourceMap = true, .optimize = true },
    });
    defer allocator.free(conflicting);
    try std.testing.expectError(error.InvalidOptions, processFrame(allocator, conflicting));
}
