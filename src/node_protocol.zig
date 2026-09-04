//! Private one-shot protocol used by the Node.js native-process bridge.
//!
//! The transport deliberately accepts exactly one length-prefixed JSON request
//! and emits exactly one length-prefixed JSON response. It is not a public ABI.

const std = @import("std");
const builtin = @import("builtin");
const zigcss = @import("zigcss");

pub const protocol_version = "zigcss-node-v1";
pub const max_source_bytes: usize = zigcss.experimental_native.max_entry_input_bytes;
/// JSON can expand arbitrary source bytes to `\u00XX`, so the frame limit is
/// intentionally much larger than the decoded ten-megabyte source ceiling.
pub const max_request_frame_bytes: usize = 64 * 1024 * 1024;
pub const max_response_frame_bytes: usize = 128 * 1024 * 1024;

const max_request_id_bytes: usize = 64;
const max_path_bytes: usize = 4096;
const max_roots: usize = 16;
const diagnostic_position_checkpoint_stride: usize = 256;

const BoundedResponseWriter = struct {
    const Failure = enum { none, limit, out_of_memory };

    allocator: std.mem.Allocator,
    limit: usize,
    allocation: []u8 = &.{},
    failure: Failure = .none,
    writer: std.Io.Writer = .{
        .buffer = &.{},
        .vtable = &vtable,
    },

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = rebase,
    };

    fn init(allocator: std.mem.Allocator, limit: usize) BoundedResponseWriter {
        return .{ .allocator = allocator, .limit = limit };
    }

    fn deinit(self: *BoundedResponseWriter) void {
        if (self.allocation.len > 0) self.allocator.free(self.allocation);
        self.* = undefined;
    }

    fn fail(self: *BoundedResponseWriter, reason: Failure) std.Io.Writer.Error {
        if (self.failure == .none) self.failure = reason;
        return error.WriteFailed;
    }

    fn ensureTotalCapacity(self: *BoundedResponseWriter, required: usize) std.Io.Writer.Error!void {
        if (required > self.limit) return self.fail(.limit);
        if (required <= self.allocation.len) return;

        var capacity = if (self.allocation.len == 0)
            @min(self.limit, 4096)
        else
            self.allocation.len;
        while (capacity < required) {
            capacity = std.math.mul(usize, capacity, 2) catch self.limit;
            capacity = @min(capacity, self.limit);
        }
        const resized = if (self.allocation.len == 0)
            self.allocator.alloc(u8, capacity)
        else
            self.allocator.realloc(self.allocation, capacity);
        self.allocation = resized catch return self.fail(.out_of_memory);
        self.writer.buffer = self.allocation;
    }

    fn append(self: *BoundedResponseWriter, bytes: []const u8) void {
        @memcpy(self.writer.buffer[self.writer.end..][0..bytes.len], bytes);
        self.writer.end += bytes.len;
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *BoundedResponseWriter = @alignCast(@fieldParentPtr("writer", writer));
        std.debug.assert(data.len > 0);
        var additional: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            additional = std.math.add(usize, additional, bytes.len) catch
                return self.fail(.limit);
        }
        const pattern = data[data.len - 1];
        const repeated = std.math.mul(usize, pattern.len, splat) catch
            return self.fail(.limit);
        additional = std.math.add(usize, additional, repeated) catch
            return self.fail(.limit);
        const required = std.math.add(usize, writer.end, additional) catch
            return self.fail(.limit);
        try self.ensureTotalCapacity(required);

        for (data[0 .. data.len - 1]) |bytes| self.append(bytes);
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(self.writer.buffer[self.writer.end..][0..splat], pattern[0]);
                self.writer.end += splat;
            },
            else => for (0..splat) |_| self.append(pattern),
        }
        return additional;
    }

    fn rebase(
        writer: *std.Io.Writer,
        preserve: usize,
        minimum_len: usize,
    ) std.Io.Writer.Error!void {
        _ = preserve;
        const self: *BoundedResponseWriter = @alignCast(@fieldParentPtr("writer", writer));
        const required = std.math.add(usize, writer.end, minimum_len) catch
            return self.fail(.limit);
        try self.ensureTotalCapacity(required);
    }

    fn toOwnedSlice(self: *BoundedResponseWriter) std.mem.Allocator.Error![]u8 {
        const length = self.writer.end;
        if (length == 0) return self.allocator.alloc(u8, 0);
        if (self.allocation.len != length) {
            self.allocation = try self.allocator.realloc(self.allocation, length);
            self.writer.buffer = self.allocation;
        }
        const result = self.allocation;
        self.allocation = &.{};
        self.writer.buffer = &.{};
        self.writer.end = 0;
        return result;
    }
};

pub const Error = error{
    FrameTruncated,
    FrameLimit,
    FrameExtraBytes,
    InvalidRequest,
    InvalidProtocol,
    InvalidRequestId,
    InvalidOperation,
    InvalidSource,
    InvalidSourcePath,
    InvalidRoots,
    InvalidOptions,
    InvalidBrowsers,
    InvalidDiagnostic,
    ResponseLimit,
};

const Syntax = enum {
    css,
    scss,
    sass,
    less,
    stylus,
};

const Format = enum {
    pretty,
    minified,
};

const Options = struct {
    syntax: Syntax,
    format: Format,
    sourceMap: bool,
    optimize: bool,
    browsers: ?[]const u8,
};

const Request = struct {
    protocol: []const u8,
    requestId: []const u8,
    operation: []const u8,
    source: []const u8,
    sourcePath: []const u8,
    rootPaths: []const []const u8,
    options: Options,
};

fn isRequestId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_request_id_bytes or
        !std.ascii.isAlphanumeric(value[0]))
    {
        return false;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn isAbsolutePath(value: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const parsed = std.fs.path.windowsParsePath(value);
        return parsed.is_abs and parsed.kind == .Drive;
    }
    return std.fs.path.isAbsolutePosix(value);
}

fn isBoundedAbsolutePath(value: []const u8) bool {
    return value.len > 0 and value.len <= max_path_bytes and
        std.mem.indexOfAny(u8, value, "\x00\r\n") == null and
        isAbsolutePath(value);
}

fn validateRequest(request: Request) Error!void {
    if (!std.mem.eql(u8, request.protocol, protocol_version)) return error.InvalidProtocol;
    if (!isRequestId(request.requestId)) return error.InvalidRequestId;
    if (!std.mem.eql(u8, request.operation, "compile")) return error.InvalidOperation;
    if (request.source.len > max_source_bytes) return error.InvalidSource;
    if (!isBoundedAbsolutePath(request.sourcePath)) return error.InvalidSourcePath;
    if (request.rootPaths.len == 0 or request.rootPaths.len > max_roots) {
        return error.InvalidRoots;
    }
    for (request.rootPaths) |root| {
        if (!isBoundedAbsolutePath(root)) return error.InvalidRoots;
    }
    if (request.options.optimize and request.options.sourceMap) return error.InvalidOptions;
}

fn parseBrowsers(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) (std.mem.Allocator.Error || error{InvalidBrowsers})!?zigcss.TargetQuery {
    const text = value orelse return null;
    const parsed = try zigcss.prefixing.target_query.parse(allocator, text, .{});
    var query = switch (parsed) {
        .query => |query| query,
        .invalid => return error.InvalidBrowsers,
    };
    errdefer query.deinit();
    if (!query.validate()) return error.InvalidBrowsers;
    // Parsing owns normalized targets in the closed browser order. Whitespace
    // and authored target order are representational, as in the public query
    // grammar; aliases and dynamic Browserslist forms are never accepted.
    return query;
}

fn severityName(severity: anytype) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn hasStableErrors(diagnostics: []const zigcss.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

fn hasNativeErrors(diagnostics: []const zigcss.experimental_native.Diagnostic) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return true;
    }
    return false;
}

const DiagnosticPosition = struct {
    /// Public Node diagnostics use one-based lines.
    line: u32,
    /// Public Node diagnostics use zero-based UTF-16 code-unit columns.
    column: u32,
};

const DiagnosticPositionCheckpoint = struct {
    offset: usize,
    position: DiagnosticPosition,
};

const DiagnosticPositionLookup = struct {
    position: DiagnosticPosition,
    bytes_scanned: usize,
};

/// One immutable request source is indexed once when stable CSS diagnostics
/// exist. Checkpoints are sparse and always fall on UTF-8 scalar boundaries;
/// each later lookup binary-searches them and scans at most one stride plus the
/// tail of a four-byte scalar instead of rescanning a long line per diagnostic.
const StableDiagnosticPositionIndex = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    checkpoints: std.ArrayList(DiagnosticPositionCheckpoint),

    fn init(allocator: std.mem.Allocator, source: []const u8) !StableDiagnosticPositionIndex {
        const maximum_checkpoints = source.len / diagnostic_position_checkpoint_stride + 2;
        var checkpoints = try std.ArrayList(DiagnosticPositionCheckpoint).initCapacity(
            allocator,
            maximum_checkpoints,
        );
        errdefer checkpoints.deinit(allocator);
        checkpoints.appendAssumeCapacity(.{
            .offset = 0,
            .position = .{ .line = 1, .column = 0 },
        });

        var offset: usize = 0;
        var cursor = DiagnosticPosition{ .line = 1, .column = 0 };
        var previous_checkpoint: usize = 0;
        while (offset < source.len) {
            try advanceDiagnosticPosition(source, &offset, &cursor);
            if (offset - previous_checkpoint >= diagnostic_position_checkpoint_stride) {
                checkpoints.appendAssumeCapacity(.{ .offset = offset, .position = cursor });
                previous_checkpoint = offset;
            }
        }

        return .{
            .allocator = allocator,
            .source = source,
            .checkpoints = checkpoints,
        };
    }

    fn deinit(self: *StableDiagnosticPositionIndex) void {
        self.checkpoints.deinit(self.allocator);
        self.* = undefined;
    }

    fn position(self: *const StableDiagnosticPositionIndex, target: usize) Error!DiagnosticPositionLookup {
        if (target > self.source.len) return error.InvalidDiagnostic;

        var low: usize = 0;
        var high = self.checkpoints.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.checkpoints.items[middle].offset <= target) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return error.InvalidDiagnostic;

        const checkpoint = self.checkpoints.items[low - 1];
        var offset = checkpoint.offset;
        var result = checkpoint.position;
        while (offset < target) {
            try advanceDiagnosticPosition(self.source, &offset, &result);
            if (offset > target) return error.InvalidDiagnostic;
        }
        return .{
            .position = result,
            .bytes_scanned = offset - checkpoint.offset,
        };
    }
};

fn advanceDiagnosticPosition(
    source: []const u8,
    offset: *usize,
    position: *DiagnosticPosition,
) Error!void {
    if (offset.* >= source.len) return error.InvalidDiagnostic;
    const byte = source[offset.*];

    // The stable source index treats CRLF as one line break whose next line
    // starts after LF. The intermediate byte offset remains a valid location
    // on the preceding line, so CR advances one UTF-16 unit until LF arrives.
    if (byte == '\r') {
        offset.* += 1;
        if (offset.* < source.len and source[offset.*] == '\n') {
            position.column = std.math.add(u32, position.column, 1) catch
                return error.InvalidDiagnostic;
        } else {
            position.line = std.math.add(u32, position.line, 1) catch
                return error.InvalidDiagnostic;
            position.column = 0;
        }
        return;
    }
    if (byte == '\n' or byte == '\x0c') {
        offset.* += 1;
        position.line = std.math.add(u32, position.line, 1) catch
            return error.InvalidDiagnostic;
        position.column = 0;
        return;
    }

    const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch
        return error.InvalidDiagnostic;
    const next = std.math.add(usize, offset.*, sequence_length) catch
        return error.InvalidDiagnostic;
    if (next > source.len) return error.InvalidDiagnostic;
    const scalar = std.unicode.utf8Decode(source[offset.*..next]) catch
        return error.InvalidDiagnostic;
    offset.* = next;
    const units: u32 = if (scalar > 0xffff) 2 else 1;
    position.column = std.math.add(u32, position.column, units) catch
        return error.InvalidDiagnostic;
}

fn writeStableDiagnostic(
    json: *std.json.Stringify,
    diagnostic: zigcss.Diagnostic,
    source_url: []const u8,
    positions: *const StableDiagnosticPositionIndex,
) !void {
    if (!std.mem.eql(u8, diagnostic.source_name, source_url) or
        diagnostic.start.byte_offset != diagnostic.span.start or
        diagnostic.end.byte_offset != diagnostic.span.end)
    {
        return error.InvalidDiagnostic;
    }
    const start = (try positions.position(diagnostic.start.byte_offset)).position;
    const end = (try positions.position(diagnostic.end.byte_offset)).position;
    if (start.line != diagnostic.start.line or end.line != diagnostic.end.line) {
        return error.InvalidDiagnostic;
    }

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
    try json.write(start.line);
    try json.objectField("column");
    try json.write(start.column);
    try json.endObject();
}

fn writeStableDiagnostics(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    diagnostics: []const zigcss.Diagnostic,
    source_url: []const u8,
    source: []const u8,
) !void {
    try json.beginArray();
    if (diagnostics.len == 0) {
        try json.endArray();
        return;
    }
    var positions = try StableDiagnosticPositionIndex.init(allocator, source);
    defer positions.deinit();
    for (diagnostics) |diagnostic| {
        try writeStableDiagnostic(json, diagnostic, source_url, &positions);
    }
    try json.endArray();
}

fn writeNativeDiagnostic(
    json: *std.json.Stringify,
    diagnostic: zigcss.experimental_native.Diagnostic,
) !void {
    // Native positions already use zero-based UTF-16 columns. The public Node
    // contract changes only their zero-based internal line to one-based.
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
    try json.write(@as(u64, diagnostic.start.line) + 1);
    try json.objectField("column");
    try json.write(diagnostic.start.column);
    try json.endObject();
}

fn writeNativeDiagnostics(
    json: *std.json.Stringify,
    diagnostics: []const zigcss.experimental_native.Diagnostic,
) !void {
    try json.beginArray();
    for (diagnostics) |diagnostic| try writeNativeDiagnostic(json, diagnostic);
    try json.endArray();
}

fn writeStableDependencies(json: *std.json.Stringify, values: []const zigcss.Dependency) !void {
    try json.beginArray();
    for (values) |dependency| {
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

fn writeNativeDependencies(
    json: *std.json.Stringify,
    values: []const zigcss.experimental_native.Dependency,
) !void {
    try json.beginArray();
    for (values) |dependency| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(switch (dependency.kind) {
            .import => "import",
            .use => "use",
            .forward => "forward",
            .reference => "reference",
        });
        try json.objectField("url");
        try json.write(dependency.url);
        try json.endObject();
    }
    try json.endArray();
}

fn writeEnvelopeStart(json: *std.json.Stringify, request: Request, ok: bool) !void {
    try json.beginObject();
    try json.objectField("protocol");
    try json.write(protocol_version);
    try json.objectField("requestId");
    try json.write(request.requestId);
    try json.objectField("ok");
    try json.write(ok);
}

fn writeFailureStart(
    json: *std.json.Stringify,
    request: Request,
    code: []const u8,
    message: []const u8,
) !void {
    try writeEnvelopeStart(json, request, false);
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.write(code);
    try json.objectField("message");
    try json.write(message);
    try json.objectField("diagnostics");
}

fn writeSuccessStart(
    json: *std.json.Stringify,
    request: Request,
    css: []const u8,
    source_map: ?[]const u8,
) !void {
    try writeEnvelopeStart(json, request, true);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("css");
    try json.write(css);
    try json.objectField("sourceMap");
    try json.write(source_map);
    try json.objectField("diagnostics");
}

fn finishFailure(json: *std.json.Stringify) !void {
    try json.endObject();
    try json.endObject();
}

fn finishSuccess(json: *std.json.Stringify) !void {
    try json.endObject();
    try json.endObject();
}

fn encodeFailureResponseWithLimit(
    allocator: std.mem.Allocator,
    request: Request,
    code: []const u8,
    message: []const u8,
    response_limit: usize,
) ![]u8 {
    var output = BoundedResponseWriter.init(allocator, response_limit);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    (struct {
        fn write(
            writer: *std.json.Stringify,
            value: Request,
            error_code: []const u8,
            error_message: []const u8,
        ) !void {
            try writeFailureStart(writer, value, error_code, error_message);
            try writer.beginArray();
            try writer.endArray();
            try finishFailure(writer);
        }
    }.write(&json, request, code, message)) catch |err| switch (err) {
        error.WriteFailed => return switch (output.failure) {
            .limit => error.ResponseLimit,
            .none, .out_of_memory => error.OutOfMemory,
        },
        else => return err,
    };
    const body = try output.toOwnedSlice();
    errdefer allocator.free(body);
    if (body.len == 0 or body.len > response_limit) return error.ResponseLimit;
    return body;
}

fn encodeFailureResponse(
    allocator: std.mem.Allocator,
    request: Request,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    return encodeFailureResponseWithLimit(
        allocator,
        request,
        code,
        message,
        max_response_frame_bytes,
    );
}

fn isUrlPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/", byte) != null;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

fn pathToFileUrl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(normalized);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "file://");
    if (builtin.os.tag == .windows) try output.append(allocator, '/');
    for (normalized) |raw| {
        const byte = if (builtin.os.tag == .windows and raw == '\\') '/' else raw;
        if (isUrlPathByte(byte)) {
            try output.append(allocator, byte);
        } else {
            try output.append(allocator, '%');
            try output.append(allocator, hexDigit(byte >> 4));
            try output.append(allocator, hexDigit(byte & 0x0f));
        }
    }
    return output.toOwnedSlice(allocator);
}

fn compileCssResponse(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Request,
    query: ?*const zigcss.TargetQuery,
) !void {
    const source_url = try pathToFileUrl(allocator, request.sourcePath);
    defer allocator.free(source_url);
    var result = try zigcss.compile(allocator, source_url, request.source, .{
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
        .transforms = .{
            .optimize = request.options.optimize,
            .prefix = query != null,
        },
        .targets = query,
    });
    defer result.deinit();

    if (hasStableErrors(result.diagnostics)) {
        try writeFailureStart(
            json,
            request,
            "NODE_COMPILE_ERROR",
            "stylesheet compilation failed",
        );
        try writeStableDiagnostics(
            allocator,
            json,
            result.diagnostics,
            source_url,
            request.source,
        );
        try finishFailure(json);
        return;
    }
    try writeSuccessStart(json, request, result.css, result.source_map);
    try writeStableDiagnostics(
        allocator,
        json,
        result.diagnostics,
        source_url,
        request.source,
    );
    try json.objectField("dependencies");
    try writeStableDependencies(json, result.dependencies);
    try finishSuccess(json);
}

fn nativeSyntax(syntax: Syntax) zigcss.experimental_native.Syntax {
    return switch (syntax) {
        .scss => .scss,
        .sass => .sass,
        .less => .less,
        .stylus => .stylus,
        .css => unreachable,
    };
}

fn compileNativeResponse(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    request: Request,
    query: ?*const zigcss.TargetQuery,
) !void {
    var result = try zigcss.experimental_native.compile(
        allocator,
        request.sourcePath,
        request.source,
        .{
            .syntax = nativeSyntax(request.options.syntax),
            .root_paths = request.rootPaths,
            .format = switch (request.options.format) {
                .pretty => .pretty,
                .minified => .minified,
            },
            .max_input_bytes = max_source_bytes,
            .source_map = request.options.sourceMap,
            .optimize = request.options.optimize,
            .prefix = query != null,
            .targets = query,
        },
    );
    defer result.deinit();

    if (hasNativeErrors(result.diagnostics)) {
        try writeFailureStart(
            json,
            request,
            "NODE_COMPILE_ERROR",
            "stylesheet compilation failed",
        );
        try writeNativeDiagnostics(json, result.diagnostics);
        try finishFailure(json);
        return;
    }
    try writeSuccessStart(json, request, result.css, result.source_map);
    try writeNativeDiagnostics(json, result.diagnostics);
    try json.objectField("dependencies");
    try writeNativeDependencies(json, result.dependencies);
    try finishSuccess(json);
}

fn compileResponseWithLimit(
    allocator: std.mem.Allocator,
    request: Request,
    response_limit: usize,
) ![]u8 {
    var targets = try parseBrowsers(allocator, request.options.browsers);
    defer if (targets) |*query| query.deinit();
    const query: ?*const zigcss.TargetQuery = if (targets) |*value| value else null;

    var output = BoundedResponseWriter.init(allocator, response_limit);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    (switch (request.options.syntax) {
        .css => compileCssResponse(allocator, &json, request, query),
        .scss, .sass, .less, .stylus => compileNativeResponse(
            allocator,
            &json,
            request,
            query,
        ),
    }) catch |err| switch (err) {
        error.WriteFailed => return switch (output.failure) {
            .limit => error.ResponseLimit,
            .none, .out_of_memory => error.OutOfMemory,
        },
        else => return err,
    };
    const body = try output.toOwnedSlice();
    errdefer allocator.free(body);
    if (body.len == 0 or body.len > response_limit) return error.ResponseLimit;
    return body;
}

fn compileResponse(allocator: std.mem.Allocator, request: Request) ![]u8 {
    return compileResponseWithLimit(allocator, request, max_response_frame_bytes);
}

fn readFrameBody(input: []const u8) Error![]const u8 {
    if (input.len < 4) return error.FrameTruncated;
    const declared: usize = std.mem.readInt(u32, input[0..4], .big);
    if (declared == 0 or declared > max_request_frame_bytes) return error.FrameLimit;
    const total = std.math.add(usize, declared, 4) catch return error.FrameLimit;
    if (input.len < total) return error.FrameTruncated;
    if (input.len > total) return error.FrameExtraBytes;
    return input[4..total];
}

fn encodeOperationalFailure(
    allocator: std.mem.Allocator,
    request: Request,
    compile_error: anyerror,
) ![]u8 {
    return switch (compile_error) {
        error.InvalidBrowsers => encodeFailureResponse(
            allocator,
            request,
            "NODE_OPTIONS",
            "browser target query is invalid",
        ),
        error.InvalidOptions => encodeFailureResponse(
            allocator,
            request,
            "NODE_OPTIONS",
            "native compiler options are invalid",
        ),
        error.InvalidRoot => encodeFailureResponse(
            allocator,
            request,
            "NODE_ROOTS",
            "stylesheet root capability is unavailable",
        ),
        error.InvalidSourcePath, error.PathEscape => encodeFailureResponse(
            allocator,
            request,
            "NODE_PATH",
            "stylesheet source path is outside the admitted roots",
        ),
        error.ResourceLimitExceeded, error.SourceTooLarge => encodeFailureResponse(
            allocator,
            request,
            "NODE_RESOURCE_LIMIT",
            "stylesheet compilation exceeded a resource limit",
        ),
        error.CompilationFailed, error.ProfilingUnavailable => encodeFailureResponse(
            allocator,
            request,
            "NODE_COMPILE_FAILURE",
            "stylesheet compilation could not complete",
        ),
        error.ResponseLimit => encodeFailureResponse(
            allocator,
            request,
            "NODE_RESPONSE_LIMIT",
            "stylesheet response exceeded its byte limit",
        ),
        else => compile_error,
    };
}

pub fn processFrame(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const body = try readFrameBody(input);
    var parsed = std.json.parseFromSlice(Request, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    try validateRequest(parsed.value);

    const response_body = compileResponse(allocator, parsed.value) catch |err|
        try encodeOperationalFailure(allocator, parsed.value, err);
    defer allocator.free(response_body);
    const frame_length = std.math.add(usize, response_body.len, 4) catch
        return error.ResponseLimit;
    const frame = try allocator.alloc(u8, frame_length);
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

fn testRawFrame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const frame = try allocator.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, frame[0..4], @intCast(body.len), .big);
    @memcpy(frame[4..], body);
    return frame;
}

fn testResponse(
    allocator: std.mem.Allocator,
    frame: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (frame.len < 4) return error.FrameTruncated;
    const length = std.mem.readInt(u32, frame[0..4], .big);
    if (frame.len != @as(usize, length) + 4) return error.FrameTruncated;
    return std.json.parseFromSlice(std.json.Value, allocator, frame[4..], .{});
}

fn sourcePath(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, name });
}

const RouteCase = struct {
    syntax: Syntax,
    filename: []const u8,
    source: []const u8,
    expected: []const u8,
};

const route_cases = [_]RouteCase{
    .{ .syntax = .css, .filename = "input.css", .source = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = .scss, .filename = "input.scss", .source = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = .sass, .filename = "input.sass", .source = ".a\n  color: red\n", .expected = ".a{color:red}" },
    .{ .syntax = .less, .filename = "input.less", .source = ".a { color: red; }", .expected = ".a{color:red}" },
    .{ .syntax = .stylus, .filename = "input.styl", .source = ".a\n  color red\n", .expected = ".a{color:#f00}" },
};

const test_absolute_root = if (builtin.os.tag == .windows) "C:\\workspace" else "/workspace";
const test_absolute_source = if (builtin.os.tag == .windows)
    "C:\\workspace\\input.css"
else
    "/workspace/input.css";

fn testRequest(
    syntax: Syntax,
    source_path: []const u8,
    roots: []const []const u8,
    source: []const u8,
) Request {
    return .{
        .protocol = protocol_version,
        .requestId = "node-request-001",
        .operation = "compile",
        .source = source,
        .sourcePath = source_path,
        .rootPaths = roots,
        .options = .{
            .syntax = syntax,
            .format = .minified,
            .sourceMap = false,
            .optimize = false,
            .browsers = null,
        },
    };
}

test "node protocol response serialization is bounded before ownership transfer" {
    const allocator = std.testing.allocator;
    const request = testRequest(.css, test_absolute_source, &.{test_absolute_root}, ".a{}");

    var bounded = BoundedResponseWriter.init(allocator, 96);
    defer bounded.deinit();
    var json: std.json.Stringify = .{ .writer = &bounded.writer };
    const escape_heavy = "\\\"" ** 256;
    try std.testing.expectError(
        error.WriteFailed,
        json.write(.{ .css = escape_heavy, .sourceMap = escape_heavy }),
    );
    try std.testing.expectEqual(BoundedResponseWriter.Failure.limit, bounded.failure);
    try std.testing.expect(bounded.allocation.len <= 96);
    try std.testing.expect(bounded.writer.end <= 96);

    try std.testing.expectError(
        error.ResponseLimit,
        encodeFailureResponseWithLimit(
            allocator,
            request,
            "NODE_TEST",
            escape_heavy,
            96,
        ),
    );
    try std.testing.expectError(
        error.ResponseLimit,
        compileResponseWithLimit(allocator, request, 32),
    );
}

test "node protocol compiles CSS and every native syntax through one envelope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    for (route_cases) |case| {
        const path = try sourcePath(allocator, root, case.filename);
        defer allocator.free(path);
        const frame = try testFrame(allocator, testRequest(case.syntax, path, &roots, case.source));
        defer allocator.free(frame);
        const response = try processFrame(allocator, frame);
        defer allocator.free(response);
        var parsed = try testResponse(allocator, response);
        defer parsed.deinit();

        const object = parsed.value.object;
        try std.testing.expectEqualStrings(protocol_version, object.get("protocol").?.string);
        try std.testing.expectEqualStrings("node-request-001", object.get("requestId").?.string);
        try std.testing.expect(object.get("ok").?.bool);
        try std.testing.expect(object.get("error") == null);
        const result = object.get("result").?.object;
        try std.testing.expectEqualStrings(case.expected, result.get("css").?.string);
        try std.testing.expect(result.get("sourceMap").? == .null);
        try std.testing.expectEqual(@as(usize, 0), result.get("diagnostics").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 0), result.get("dependencies").?.array.items.len);
    }
}

test "node protocol returns source maps for CSS and every native syntax" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    for (route_cases) |case| {
        const path = try sourcePath(allocator, root, case.filename);
        defer allocator.free(path);
        var request = testRequest(case.syntax, path, &roots, case.source);
        request.options.sourceMap = true;
        const frame = try testFrame(allocator, request);
        defer allocator.free(frame);
        const response = try processFrame(allocator, frame);
        defer allocator.free(response);
        var parsed = try testResponse(allocator, response);
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expectEqualStrings(case.expected, result.get("css").?.string);
        const map_text = result.get("sourceMap").?.string;
        var map = try std.json.parseFromSlice(std.json.Value, allocator, map_text, .{});
        defer map.deinit();
        const sources = map.value.object.get("sources").?.array.items;
        try std.testing.expect(sources.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, sources[0].string, case.filename));
    }
}

const transform_cases = [_]RouteCase{
    .{ .syntax = .css, .filename = "transform.css", .source = ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}", .expected = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}" },
    .{ .syntax = .scss, .filename = "transform.scss", .source = ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}", .expected = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}" },
    .{ .syntax = .sass, .filename = "transform.sass", .source = ".a\n  user-select: none\n  color: #ffffff\n.b\n  user-select: none\n  color: #fff\n", .expected = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}" },
    .{ .syntax = .less, .filename = "transform.less", .source = ".empty{}.a{user-select:none;color:#ffffff}.b{user-select:none;color:#fff}", .expected = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}" },
    .{ .syntax = .stylus, .filename = "transform.styl", .source = ".a\n  user-select none\n  color #ffffff\n.b\n  user-select none\n  color #fff\n", .expected = ".a,.b{-webkit-user-select:none;-ms-user-select:none;user-select:none;color:#fff}" },
};

test "node protocol composes verified optimizer and canonical target prefixing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    for (transform_cases) |case| {
        const path = try sourcePath(allocator, root, case.filename);
        defer allocator.free(path);
        var request = testRequest(case.syntax, path, &roots, case.source);
        request.options.optimize = true;
        request.options.browsers = "safari >= 7, ie >= 11";
        const frame = try testFrame(allocator, request);
        defer allocator.free(frame);
        const response = try processFrame(allocator, frame);
        defer allocator.free(response);
        var parsed = try testResponse(allocator, response);
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(object.get("ok").?.bool);
        try std.testing.expectEqualStrings(
            case.expected,
            object.get("result").?.object.get("css").?.string,
        );
    }
}

test "node protocol permits prefixing with source maps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};
    const path = try sourcePath(allocator, root, "prefix.scss");
    defer allocator.free(path);
    var request = testRequest(.scss, path, &roots, ".a{user-select:none}");
    request.options.sourceMap = true;
    request.options.browsers = "safari >= 7, ie >= 11";
    const frame = try testFrame(allocator, request);
    defer allocator.free(frame);
    const response = try processFrame(allocator, frame);
    defer allocator.free(response);
    var parsed = try testResponse(allocator, response);
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(
        ".a{-webkit-user-select:none;-ms-user-select:none;user-select:none}",
        result.get("css").?.string,
    );
    try std.testing.expect(result.get("sourceMap").? == .string);
}

test "node protocol preserves stable CSS facts and canonical native dependency URLs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "_tokens.scss", .data = "$color: red;" });
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    const css_path = try sourcePath(allocator, root, "facts.css");
    defer allocator.free(css_path);
    const css_frame = try testFrame(
        allocator,
        testRequest(.css, css_path, &roots, "@import \"theme.css\";.a{color:red}"),
    );
    defer allocator.free(css_frame);
    const css_response = try processFrame(allocator, css_frame);
    defer allocator.free(css_response);
    var css_parsed = try testResponse(allocator, css_response);
    defer css_parsed.deinit();
    const css_dependencies = css_parsed.value.object.get("result").?.object
        .get("dependencies").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), css_dependencies.len);
    const css_dependency = css_dependencies[0].object;
    try std.testing.expectEqualStrings("css-import", css_dependency.get("kind").?.string);
    try std.testing.expectEqualStrings("theme.css", css_dependency.get("specifier").?.string);
    try std.testing.expect(std.mem.startsWith(u8, css_dependency.get("sourceUrl").?.string, "file:///"));
    try std.testing.expect(css_dependency.get("end").?.integer > css_dependency.get("start").?.integer);

    const scss_path = try sourcePath(allocator, root, "facts.scss");
    defer allocator.free(scss_path);
    const scss_frame = try testFrame(
        allocator,
        testRequest(
            .scss,
            scss_path,
            &roots,
            "@use \"tokens\" as tokens;.a{color:tokens.$color}",
        ),
    );
    defer allocator.free(scss_frame);
    const scss_response = try processFrame(allocator, scss_frame);
    defer allocator.free(scss_response);
    var scss_parsed = try testResponse(allocator, scss_response);
    defer scss_parsed.deinit();
    const native_dependencies = scss_parsed.value.object.get("result").?.object
        .get("dependencies").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), native_dependencies.len);
    const native_dependency = native_dependencies[0].object;
    try std.testing.expectEqualStrings("use", native_dependency.get("kind").?.string);
    try std.testing.expect(std.mem.startsWith(u8, native_dependency.get("url").?.string, "file:///"));
    try std.testing.expect(std.mem.endsWith(u8, native_dependency.get("url").?.string, "/_tokens.scss"));
}

test "node protocol reports one-based line and zero-based UTF-16 diagnostic locations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const roots = [_][]const u8{root};

    const failures = [_]struct { syntax: Syntax, filename: []const u8, source: []const u8 }{
        .{
            .syntax = .css,
            .filename = "failure.css",
            .source = ".a{content:\"🙂\";/*xx*/broken;color:red}",
        },
        .{
            .syntax = .scss,
            .filename = "failure.scss",
            .source = ".a{content:\"🙂\";color:$missing}",
        },
    };
    for (failures) |failure| {
        const path = try sourcePath(allocator, root, failure.filename);
        defer allocator.free(path);
        var request = testRequest(failure.syntax, path, &roots, failure.source);
        request.options.sourceMap = true;
        const frame = try testFrame(allocator, request);
        defer allocator.free(frame);
        const response = try processFrame(allocator, frame);
        defer allocator.free(response);
        var parsed = try testResponse(allocator, response);
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(!object.get("ok").?.bool);
        try std.testing.expect(object.get("result") == null);
        const failure_object = object.get("error").?.object;
        try std.testing.expectEqualStrings(
            "NODE_COMPILE_ERROR",
            failure_object.get("code").?.string,
        );
        const diagnostics = failure_object.get("diagnostics").?.array.items;
        try std.testing.expect(diagnostics.len > 0);
        const diagnostic = diagnostics[0].object;
        try std.testing.expectEqualStrings("error", diagnostic.get("severity").?.string);
        try std.testing.expectEqual(@as(i64, 1), diagnostic.get("line").?.integer);
        // Both errors start after the same UTF-16 prefix. The non-BMP scalar
        // contributes two code units for CSS exactly as it already does for
        // native preprocessors.
        try std.testing.expectEqual(@as(i64, 22), diagnostic.get("column").?.integer);
        try std.testing.expect(std.mem.startsWith(u8, diagnostic.get("sourceUrl").?.string, "file:///"));
    }
}

test "stable diagnostic position index is sparse bounded and fail closed" {
    const allocator = std.testing.allocator;
    const source = "a🙂b\r\nc🙂d\re🙂f\nx🙂y\x0cz";
    var positions = try StableDiagnosticPositionIndex.init(allocator, source);
    defer positions.deinit();

    const cases = [_]struct {
        offset: usize,
        expected: DiagnosticPosition,
    }{
        .{ .offset = 0, .expected = .{ .line = 1, .column = 0 } },
        .{ .offset = std.mem.indexOf(u8, source, "b").?, .expected = .{ .line = 1, .column = 3 } },
        .{ .offset = std.mem.indexOf(u8, source, "\n").?, .expected = .{ .line = 1, .column = 5 } },
        .{ .offset = std.mem.indexOf(u8, source, "c").?, .expected = .{ .line = 2, .column = 0 } },
        .{ .offset = std.mem.indexOf(u8, source, "d").?, .expected = .{ .line = 2, .column = 3 } },
        .{ .offset = std.mem.indexOf(u8, source, "e").?, .expected = .{ .line = 3, .column = 0 } },
        .{ .offset = std.mem.indexOf(u8, source, "f").?, .expected = .{ .line = 3, .column = 3 } },
        .{ .offset = std.mem.indexOf(u8, source, "x").?, .expected = .{ .line = 4, .column = 0 } },
        .{ .offset = std.mem.indexOf(u8, source, "y").?, .expected = .{ .line = 4, .column = 3 } },
        .{ .offset = std.mem.indexOf(u8, source, "z").?, .expected = .{ .line = 5, .column = 0 } },
    };
    for (cases) |case| {
        const actual = try positions.position(case.offset);
        try std.testing.expectEqual(case.expected, actual.position);
        try std.testing.expect(actual.bytes_scanned <= diagnostic_position_checkpoint_stride + 3);
    }

    // Byte 2 is inside the first four-byte scalar; neither it nor an offset
    // beyond the source may be serialized as a plausible public location.
    try std.testing.expectError(error.InvalidDiagnostic, positions.position(2));
    try std.testing.expectError(error.InvalidDiagnostic, positions.position(source.len + 1));

    const invalid = [_]u8{0xff};
    try std.testing.expectError(
        error.InvalidDiagnostic,
        StableDiagnosticPositionIndex.init(allocator, &invalid),
    );

    const long_source = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(long_source);
    @memset(long_source, 'a');
    var long_positions = try StableDiagnosticPositionIndex.init(allocator, long_source);
    defer long_positions.deinit();
    try std.testing.expect(
        long_positions.checkpoints.items.len <=
            long_source.len / diagnostic_position_checkpoint_stride + 2,
    );
    var offset = long_source.len;
    while (true) {
        const actual = try long_positions.position(offset);
        try std.testing.expect(actual.bytes_scanned <= diagnostic_position_checkpoint_stride + 3);
        if (offset < 37) break;
        offset -= 37;
    }
}

fn expectRequestError(allocator: std.mem.Allocator, expected: anyerror, value: anytype) !void {
    const frame = try testFrame(allocator, value);
    defer allocator.free(frame);
    try std.testing.expectError(expected, processFrame(allocator, frame));
}

fn expectRequestFailure(
    allocator: std.mem.Allocator,
    value: anytype,
    expected_code: []const u8,
) !void {
    const frame = try testFrame(allocator, value);
    defer allocator.free(frame);
    const response = try processFrame(allocator, frame);
    defer allocator.free(response);
    var parsed = try testResponse(allocator, response);
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(!object.get("ok").?.bool);
    try std.testing.expect(object.get("result") == null);
    const failure = object.get("error").?.object;
    try std.testing.expectEqualStrings(expected_code, failure.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 0), failure.get("diagnostics").?.array.items.len);
}

test "node protocol frame schema paths options and queries fail closed" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FrameTruncated, processFrame(allocator, ""));
    var oversized = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.FrameLimit, processFrame(allocator, &oversized));
    var zero = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.FrameLimit, processFrame(allocator, &zero));

    const malformed = try testRawFrame(allocator, "{");
    defer allocator.free(malformed);
    try std.testing.expectError(error.InvalidRequest, processFrame(allocator, malformed));
    const extra = try allocator.alloc(u8, malformed.len + 1);
    defer allocator.free(extra);
    @memcpy(extra[0..malformed.len], malformed);
    extra[extra.len - 1] = 0;
    try std.testing.expectError(error.FrameExtraBytes, processFrame(allocator, extra));

    const base = testRequest(.css, test_absolute_source, &.{test_absolute_root}, ".a{}");
    try expectRequestError(allocator, error.InvalidRequest, .{
        .protocol = base.protocol,
        .requestId = base.requestId,
        .operation = base.operation,
        .source = base.source,
        .sourcePath = base.sourcePath,
        .rootPaths = base.rootPaths,
        .options = base.options,
        .unexpected = true,
    });
    var wrong_protocol = base;
    wrong_protocol.protocol = "zigcss-node-v2";
    try expectRequestError(allocator, error.InvalidProtocol, wrong_protocol);
    var wrong_id = base;
    wrong_id.requestId = "bad request";
    try expectRequestError(allocator, error.InvalidRequestId, wrong_id);
    var wrong_operation = base;
    wrong_operation.operation = "watch";
    try expectRequestError(allocator, error.InvalidOperation, wrong_operation);
    var relative_source = base;
    relative_source.sourcePath = "input.css";
    try expectRequestError(allocator, error.InvalidSourcePath, relative_source);
    var controlled_source = base;
    controlled_source.sourcePath = if (builtin.os.tag == .windows)
        "C:\\workspace\\input\n.css"
    else
        "/workspace/input\n.css";
    try expectRequestError(allocator, error.InvalidSourcePath, controlled_source);
    var empty_roots = base;
    empty_roots.rootPaths = &.{};
    try expectRequestError(allocator, error.InvalidRoots, empty_roots);
    var relative_root = base;
    relative_root.rootPaths = &.{"workspace"};
    try expectRequestError(allocator, error.InvalidRoots, relative_root);
    var conflicting = base;
    conflicting.options.optimize = true;
    conflicting.options.sourceMap = true;
    try expectRequestError(allocator, error.InvalidOptions, conflicting);
    var invalid_query = base;
    invalid_query.options.browsers = "ie 11";
    try expectRequestFailure(allocator, invalid_query, "NODE_OPTIONS");
    var duplicate_query = base;
    duplicate_query.options.browsers = "ie >= 11, ie >= 12";
    try expectRequestFailure(allocator, duplicate_query, "NODE_OPTIONS");

    const seventeen = [_][]const u8{test_absolute_root} ** 17;
    var too_many_roots = base;
    too_many_roots.rootPaths = &seventeen;
    try expectRequestError(allocator, error.InvalidRoots, too_many_roots);

    const huge = try allocator.alloc(u8, max_source_bytes + 1);
    defer allocator.free(huge);
    var too_large = base;
    too_large.source = huge;
    try std.testing.expectError(error.InvalidSource, validateRequest(too_large));
}

test "valid native frames preserve request identity across operational failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const missing_root = try sourcePath(allocator, root, "missing-root");
    defer allocator.free(missing_root);
    const missing_source = try sourcePath(allocator, missing_root, "input.scss");
    defer allocator.free(missing_source);
    try expectRequestFailure(
        allocator,
        testRequest(.scss, missing_source, &.{missing_root}, ".a{color:red}"),
        "NODE_ROOTS",
    );

    const escaped_source = try sourcePath(allocator, root, "../outside.scss");
    defer allocator.free(escaped_source);
    try expectRequestFailure(
        allocator,
        testRequest(.scss, escaped_source, &.{root}, ".a{color:red}"),
        "NODE_PATH",
    );

    const base = testRequest(.scss, escaped_source, &.{root}, ".a{color:red}");
    const resource_body = try encodeOperationalFailure(
        allocator,
        base,
        error.ResourceLimitExceeded,
    );
    defer allocator.free(resource_body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resource_body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("node-request-001", object.get("requestId").?.string);
    try std.testing.expect(!object.get("ok").?.bool);
    try std.testing.expectEqualStrings(
        "NODE_RESOURCE_LIMIT",
        object.get("error").?.object.get("code").?.string,
    );
}

fn exerciseProcessFrameAllocationFailures(allocator: std.mem.Allocator, frame: []const u8) !void {
    const response = try processFrame(allocator, frame);
    defer allocator.free(response);
}

test "node protocol releases every allocation on success and injected failure" {
    const allocator = std.testing.allocator;
    const request = testRequest(.css, test_absolute_source, &.{test_absolute_root}, ".a{color:red}");
    const frame = try testFrame(allocator, request);
    defer allocator.free(frame);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseProcessFrameAllocationFailures,
        .{frame},
    );

    const diagnostic_request = testRequest(
        .css,
        if (builtin.os.tag == .windows) "C:\\workspace\\diagnostic.css" else "/workspace/diagnostic.css",
        &.{test_absolute_root},
        ".a{content:\"🙂\";/*xx*/broken;color:red}",
    );
    const diagnostic_frame = try testFrame(allocator, diagnostic_request);
    defer allocator.free(diagnostic_frame);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseProcessFrameAllocationFailures,
        .{diagnostic_frame},
    );
}
