const std = @import("std");
const parser = @import("parser.zig");
const formats = @import("formats.zig");
const error_module = @import("error.zig");
const lsp_position = @import("lsp_position.zig");

const unsupported_format_message = "Unsupported or removed stylesheet format";

pub const ExitStatus = enum {
    success,
    failure,
};

pub const MessageResult = union(enum) {
    response: []const u8,
    no_response,
    exit: ExitStatus,
};

pub const LspServer = struct {
    allocator: std.mem.Allocator,
    lifecycle: Lifecycle,
    root_uri: ?[]const u8 = null,
    documents: std.StringHashMap(Document),

    const Lifecycle = enum {
        pre_initialize,
        running,
        shutdown,
    };

    // The hash-map key is the sole owned URI copy.
    const Document = struct {
        version: i32,
        text: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) LspServer {
        return .{
            .allocator = allocator,
            .lifecycle = .pre_initialize,
            .documents = std.StringHashMap(Document).init(allocator),
        };
    }
    
    pub fn deinit(self: *LspServer) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.text);
        }
        self.documents.deinit();
        if (self.root_uri) |uri| {
            self.allocator.free(uri);
        }
    }
    
    const JsonWriter = std.json.Stringify;
    const JsonObject = std.json.ObjectMap;
    const DispatchResponse = struct {
        bytes: []const u8,
        success: bool,
    };

    pub fn handleRequest(self: *LspServer, request: []const u8) ![]const u8 {
        const result = try self.handleMessage(request);
        return switch (result) {
            .response => |response| response,
            .no_response, .exit => error.NoResponse,
        };
    }

    pub fn handleMessage(self: *LspServer, message: []const u8) !MessageResult {
        return self.handleMessageInner(message) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
    }

    fn handleMessageInner(self: *LspServer, message: []const u8) !MessageResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            message,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.errorResult(null, -32700, "Parse error"),
        };

        const object = switch (root) {
            .object => |value| value,
            else => return self.errorResult(null, -32600, "Invalid Request"),
        };
        const version = object.get("jsonrpc") orelse
            return self.errorResult(null, -32600, "Invalid Request");
        if (version != .string or !std.mem.eql(u8, version.string, "2.0")) {
            return self.errorResult(null, -32600, "Invalid Request");
        }
        const method_value = object.get("method") orelse
            return self.errorResult(null, -32600, "Invalid Request");
        const method = switch (method_value) {
            .string => |value| value,
            else => return self.errorResult(null, -32600, "Invalid Request"),
        };
        const id = object.get("id");
        if (id) |value| {
            if (!isValidRequestId(value)) {
                return self.errorResult(null, -32600, "Invalid Request");
            }
        }

        if (id == null and std.mem.eql(u8, method, "exit")) {
            validateNoParams(object) catch return .no_response;
            return .{ .exit = if (self.lifecycle == .shutdown) .success else .failure };
        }

        switch (self.lifecycle) {
            .pre_initialize => {
                if (id == null) return .no_response;
                if (!std.mem.eql(u8, method, "initialize")) {
                    return self.errorResult(id, -32002, "Server not initialized");
                }
                const response = try self.writeDispatchResponse(object, method, id);
                if (response.success) self.lifecycle = .running;
                return .{ .response = response.bytes };
            },
            .running => {
                if (std.mem.eql(u8, method, "initialize")) {
                    if (id == null) return .no_response;
                    return self.errorResult(id, -32600, "Invalid Request");
                }
                if (std.mem.eql(u8, method, "shutdown")) {
                    if (id == null) return .no_response;
                    validateNoParams(object) catch {
                        return self.errorResult(id, -32602, "Invalid params");
                    };
                    const response = try self.writeNullResultResponse(id);
                    self.lifecycle = .shutdown;
                    return .{ .response = response };
                }
                if (id == null) {
                    self.dispatchNotification(object, method) catch |err| switch (err) {
                        error.InvalidParams => {},
                        else => return err,
                    };
                    return .no_response;
                }
                const response = try self.writeDispatchResponse(object, method, id);
                return .{ .response = response.bytes };
            },
            .shutdown => {
                if (id == null) return .no_response;
                return self.errorResult(id, -32600, "Invalid Request");
            },
        }
    }

    fn errorResult(
        self: *LspServer,
        id: ?std.json.Value,
        code: i32,
        message: []const u8,
    ) !MessageResult {
        return .{ .response = try self.writeErrorResponse(id, code, message) };
    }

    fn writeDispatchResponse(
        self: *LspServer,
        root: JsonObject,
        method: []const u8,
        id: ?std.json.Value,
    ) !DispatchResponse {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: JsonWriter = .{ .writer = &output.writer };
        try writeResponsePrefix(&json, id);

        var success = true;
        self.dispatch(&json, root, method) catch |err| switch (err) {
            error.InvalidParams => {
                success = false;
                try writeErrorField(&json, -32602, "Invalid params");
            },
            else => return err,
        };
        try json.endObject();
        return .{ .bytes = try output.toOwnedSlice(), .success = success };
    }

    fn dispatch(
        self: *LspServer,
        json: *JsonWriter,
        root: JsonObject,
        method: []const u8,
    ) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/diagnostics")) {
            try self.handleDiagnostics(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.handleRename(json, root);
        } else {
            try writeErrorField(json, -32601, "Method not found");
        }
    }

    fn dispatchNotification(
        self: *LspServer,
        root: JsonObject,
        method: []const u8,
    ) !void {
        if (std.mem.eql(u8, method, "initialized")) {
            const params = root.get("params") orelse return error.InvalidParams;
            if (params != .object and params != .null) return error.InvalidParams;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(root);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(root);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(root);
        } else if (std.mem.eql(u8, method, "$/cancelRequest")) {
            try handleCancelRequest(root);
        }
    }

    fn writeErrorResponse(
        self: *LspServer,
        id: ?std.json.Value,
        code: i32,
        message: []const u8,
    ) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: JsonWriter = .{ .writer = &output.writer };
        try writeResponsePrefix(&json, id);
        try writeErrorField(&json, code, message);
        try json.endObject();
        return try output.toOwnedSlice();
    }

    fn writeNullResultResponse(
        self: *LspServer,
        id: ?std.json.Value,
    ) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: JsonWriter = .{ .writer = &output.writer };
        try writeResponsePrefix(&json, id);
        try json.objectField("result");
        try json.write(null);
        try json.endObject();
        return try output.toOwnedSlice();
    }

    fn writeResponsePrefix(json: *JsonWriter, id: ?std.json.Value) !void {
        try json.beginObject();
        try json.objectField("jsonrpc");
        try json.write("2.0");
        try json.objectField("id");
        if (id) |value| try json.write(value) else try json.write(null);
    }

    fn writeErrorField(json: *JsonWriter, code: i32, message: []const u8) !void {
        try json.objectField("error");
        try json.beginObject();
        try json.objectField("code");
        try json.write(code);
        try json.objectField("message");
        try json.write(message);
        try json.endObject();
    }

    fn validateNoParams(root: JsonObject) !void {
        const params = root.get("params") orelse return;
        if (params != .null) return error.InvalidParams;
    }

    fn handleCancelRequest(root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const id = params.get("id") orelse return error.InvalidParams;
        switch (id) {
            .string => {},
            .integer => |value| _ = try integerToI32(value),
            else => return error.InvalidParams,
        }
    }

    fn writeDiagnostic(
        json: *JsonWriter,
        range: PositionRange,
        message: []const u8,
    ) !void {
        try json.write(.{
            .range = range,
            .severity = @as(i32, 1),
            .message = message,
            .source = "zigcss",
        });
    }

    fn isValidRequestId(value: std.json.Value) bool {
        return switch (value) {
            .string, .integer, .float, .number_string, .null => true,
            else => false,
        };
    }

    fn requireObjectField(object: JsonObject, name: []const u8) !JsonObject {
        const value = object.get(name) orelse return error.InvalidParams;
        return switch (value) {
            .object => |result| result,
            else => error.InvalidParams,
        };
    }

    fn requireStringField(object: JsonObject, name: []const u8) ![]const u8 {
        const value = object.get(name) orelse return error.InvalidParams;
        return switch (value) {
            .string => |result| result,
            else => error.InvalidParams,
        };
    }

    fn requireIntegerField(object: JsonObject, name: []const u8) !i64 {
        const value = object.get(name) orelse return error.InvalidParams;
        return switch (value) {
            .integer => |result| result,
            else => error.InvalidParams,
        };
    }

    fn requireArrayField(object: JsonObject, name: []const u8) ![]const std.json.Value {
        const value = object.get(name) orelse return error.InvalidParams;
        return switch (value) {
            .array => |result| result.items,
            else => error.InvalidParams,
        };
    }

    fn integerToI32(value: i64) !i32 {
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
            return error.InvalidParams;
        }
        return @intCast(value);
    }

    fn integerToLspUinteger(value: i64) !usize {
        if (value < 0 or value > std.math.maxInt(i32)) return error.InvalidParams;
        return @intCast(value);
    }

    fn byteOffsetAtPosition(text: []const u8, position: JsonObject) !usize {
        const line = try integerToLspUinteger(try requireIntegerField(position, "line"));
        const character = try integerToLspUinteger(
            try requireIntegerField(position, "character"),
        );
        return lsp_position.byteOffsetAtUtf16Position(text, line, character) catch
            error.InvalidParams;
    }

    fn utf16Position(text: []const u8, offset: usize) !lsp_position.Position {
        return lsp_position.utf16PositionAtByteOffset(text, offset) catch
            error.InvalidParams;
    }

    const PositionRange = struct {
        start: lsp_position.Position,
        end: lsp_position.Position,
    };

    fn utf16Range(text: []const u8, start: usize, end: usize) !PositionRange {
        return .{
            .start = try utf16Position(text, start),
            .end = try utf16Position(text, end),
        };
    }

    fn legacyDiagnosticRange(
        text: []const u8,
        one_based_line: usize,
        one_based_byte_column: usize,
    ) !PositionRange {
        if (one_based_line == 0 or one_based_byte_column == 0) return error.InvalidParams;
        const start = lsp_position.byteOffsetAtUtf8Position(
            text,
            one_based_line - 1,
            one_based_byte_column - 1,
        ) catch return error.InvalidParams;
        var end = start;
        if (start < text.len and text[start] != '\r' and text[start] != '\n') {
            const length: usize = std.unicode.utf8ByteSequenceLength(text[start]) catch
                return error.InvalidParams;
            if (start + length > text.len) return error.InvalidParams;
            _ = std.unicode.utf8Decode(text[start .. start + length]) catch
                return error.InvalidParams;
            end += length;
        }
        return utf16Range(text, start, end);
    }

    fn lineStartAtByteOffset(text: []const u8, offset: usize) usize {
        var index = offset;
        while (index > 0) {
            const previous = text[index - 1];
            if (previous == '\r' or previous == '\n') return index;
            index -= 1;
        }
        return 0;
    }
    
    fn handleInitialize(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        _ = try requireObjectField(params, "capabilities");
        if (params.get("rootUri")) |root_uri| {
            const replacement: ?[]u8 = switch (root_uri) {
                .null => null,
                .string => |value| if (value.len == 0)
                    null
                else
                    try self.allocator.dupe(u8, value),
                else => return error.InvalidParams,
            };
            if (self.root_uri) |old| self.allocator.free(old);
            self.root_uri = replacement;
        }

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("capabilities");
        try json.beginObject();
        try json.objectField("positionEncoding");
        try json.write("utf-16");
        try json.objectField("textDocumentSync");
        try json.beginObject();
        try json.objectField("openClose");
        try json.write(true);
        try json.objectField("change");
        try json.write(@as(i32, 1));
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }

    fn handleDidOpen(self: *LspServer, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        _ = try requireStringField(text_document, "languageId");
        const text = try requireStringField(text_document, "text");
        const version = try integerToI32(try requireIntegerField(text_document, "version"));
        if (self.documents.contains(uri)) return error.InvalidParams;

        {
            const text_copy = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(text_copy);
            const uri_copy = try self.allocator.dupe(u8, uri);
            errdefer self.allocator.free(uri_copy);
            try self.documents.put(uri_copy, .{ .version = version, .text = text_copy });
        }
    }

    fn handleDidChange(self: *LspServer, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const changes = try requireArrayField(params, "contentChanges");
        const version = try integerToI32(try requireIntegerField(text_document, "version"));
        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        if (version <= document.version or changes.len != 1) return error.InvalidParams;
        const change = switch (changes[0]) {
            .object => |value| value,
            else => return error.InvalidParams,
        };
        if (change.get("range") != null or change.get("rangeLength") != null) {
            return error.InvalidParams;
        }
        const text = try requireStringField(change, "text");
        const text_copy = try self.allocator.dupe(u8, text);
        self.allocator.free(document.text);
        document.* = .{ .version = version, .text = text_copy };
    }

    fn handleDidClose(self: *LspServer, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const removed = self.documents.fetchRemove(uri) orelse return error.InvalidParams;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value.text);
    }
    
    fn handleDiagnostics(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("items");
        try json.beginArray();
        const doc = self.documents.get(uri) orelse {
            try json.endArray();
            try json.endObject();
            return;
        };

        const format = formats.detectFormat(uri);
        if (format == null) {
            try writeDiagnostic(
                json,
                try legacyDiagnosticRange(doc.text, 1, 1),
                unsupported_format_message,
            );
        } else if (format.? == .css) {
            var css_parser = parser.Parser.init(self.allocator, doc.text);
            defer if (css_parser.owns_pool) {
                css_parser.string_pool.deinit();
                self.allocator.destroy(css_parser.string_pool);
            };
            
            var result = css_parser.parseWithErrorInfo();
            switch (result) {
                .success => |*stylesheet| stylesheet.deinit(),
                .parse_error => |parse_error| {
                    const message = error_module.ParseError.getMessage(parse_error.kind);
                    try writeDiagnostic(
                        json,
                        try legacyDiagnosticRange(
                            doc.text,
                            parse_error.line,
                            parse_error.column,
                        ),
                        message,
                    );
                },
            }
        }

        try json.endArray();
        try json.endObject();
    }
    
    fn handleHover(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");

        const doc = self.documents.get(uri) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        const offset = try byteOffsetAtPosition(doc.text, position);
        if (self.getSymbolAtPosition(doc.text, offset)) |symbol| {
            if (self.getCssPropertyInfo(symbol.text)) |info| {
                try json.objectField("result");
                try json.write(.{
                    .contents = .{ .kind = "markdown", .value = info },
                    .range = try utf16Range(doc.text, symbol.start, symbol.end),
                });
                return;
            }
        }

        try json.objectField("result");
        try json.write(null);
    }
    
    fn handleCompletion(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("items");
        try json.beginArray();
        const doc = self.documents.get(uri) orelse {
            try json.endArray();
            try json.endObject();
            return;
        };

        const offset = try byteOffsetAtPosition(doc.text, position);
        const prefix = doc.text[lineStartAtByteOffset(doc.text, offset)..offset];
        for (COMMON_CSS_PROPERTIES) |prop| {
            if (std.mem.startsWith(u8, prop, prefix)) {
                try json.write(.{
                    .label = prop,
                    .kind = @as(i32, 10),
                    .detail = "CSS Property",
                    .insertText = prop,
                });
            }
        }

        try json.endArray();
        try json.endObject();
    }
    
    fn getCssPropertyInfo(self: *LspServer, property: []const u8) ?[]const u8 {
        _ = self;
        for (CSS_PROPERTY_INFO) |info| {
            if (std.mem.eql(u8, info.property, property)) {
                return info.description;
            }
        }
        return null;
    }
    
    const CssPropertyInfo = struct {
        property: []const u8,
        description: []const u8,
    };
    
    const CSS_PROPERTY_INFO = [_]CssPropertyInfo{
        .{ .property = "color", .description = "**color** - Sets the text color\n\nValues: `<color>` | `inherit` | `initial` | `unset`" },
        .{ .property = "background-color", .description = "**background-color** - Sets the background color\n\nValues: `<color>` | `transparent` | `inherit` | `initial` | `unset`" },
        .{ .property = "padding", .description = "**padding** - Sets padding on all sides\n\nValues: `<length>` | `<percentage>` | `inherit` | `initial` | `unset`" },
        .{ .property = "margin", .description = "**margin** - Sets margin on all sides\n\nValues: `<length>` | `<percentage>` | `auto` | `inherit` | `initial` | `unset`" },
        .{ .property = "width", .description = "**width** - Sets the width of an element\n\nValues: `<length>` | `<percentage>` | `auto` | `inherit` | `initial` | `unset`" },
        .{ .property = "height", .description = "**height** - Sets the height of an element\n\nValues: `<length>` | `<percentage>` | `auto` | `inherit` | `initial` | `unset`" },
        .{ .property = "display", .description = "**display** - Sets the display type\n\nValues: `block` | `inline` | `inline-block` | `flex` | `grid` | `none` | `inherit` | `initial` | `unset`" },
        .{ .property = "font-size", .description = "**font-size** - Sets the font size\n\nValues: `<length>` | `<percentage>` | `smaller` | `larger` | `inherit` | `initial` | `unset`" },
        .{ .property = "font-weight", .description = "**font-weight** - Sets the font weight\n\nValues: `normal` | `bold` | `bolder` | `lighter` | `100-900` | `inherit` | `initial` | `unset`" },
        .{ .property = "border", .description = "**border** - Sets border on all sides\n\nValues: `<border-width>` `<border-style>` `<border-color>` | `inherit` | `initial` | `unset`" },
    };
    
    fn handleDefinition(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");

        const doc = self.documents.get(uri) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        const pos = try byteOffsetAtPosition(doc.text, position);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        const definition_pos = self.findDefinition(doc.text, symbol.text) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        try json.objectField("result");
        try json.write(.{
            .uri = uri,
            .range = try utf16Range(
                doc.text,
                definition_pos,
                definition_pos + symbol.text.len,
            ),
        });
    }
    
    fn handleReferences(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");

        try json.objectField("result");
        try json.beginArray();
        const doc = self.documents.get(uri) orelse {
            try json.endArray();
            return;
        };

        const pos = try byteOffsetAtPosition(doc.text, position);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try json.endArray();
            return;
        };

        var search_pos: usize = 0;
        while (self.findNextReference(doc.text, symbol.text, &search_pos)) |ref_pos| {
            try json.write(.{
                .uri = uri,
                .range = try utf16Range(
                    doc.text,
                    ref_pos,
                    ref_pos + symbol.text.len,
                ),
            });
        }

        try json.endArray();
    }
    
    fn handleRename(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");
        const new_name = try requireStringField(params, "newName");

        const doc = self.documents.get(uri) orelse {
            try writeErrorField(json, -32602, "Document not found");
            return;
        };

        const pos = try byteOffsetAtPosition(doc.text, position);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try writeErrorField(json, -32602, "Symbol not found");
            return;
        };

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("changes");
        try json.beginObject();
        try json.objectField(uri);
        try json.beginArray();
        var search_pos: usize = 0;
        while (self.findNextReference(doc.text, symbol.text, &search_pos)) |ref_pos| {
            try json.write(.{
                .range = try utf16Range(
                    doc.text,
                    ref_pos,
                    ref_pos + symbol.text.len,
                ),
                .newText = new_name,
            });
        }

        try json.endArray();
        try json.endObject();
        try json.endObject();
    }
    
    const SymbolAtPosition = struct {
        text: []const u8,
        start: usize,
        end: usize,
    };

    fn getSymbolAtPosition(self: *LspServer, text: []const u8, pos: usize) ?SymbolAtPosition {
        _ = self;
        if (pos >= text.len) return null;
        
        var start = pos;
        while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '-' or text[start - 1] == '_')) {
            start -= 1;
        }
        
        var end = pos;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-' or text[end] == '_')) {
            end += 1;
        }
        
        if (start < end) {
            return .{ .text = text[start..end], .start = start, .end = end };
        }
        return null;
    }
    
    fn findDefinition(self: *LspServer, text: []const u8, symbol: []const u8) ?usize {
        _ = self;
        var pos: usize = 0;
        while (pos < text.len) {
            if (std.mem.startsWith(u8, text[pos..], ".") and pos + 1 < text.len) {
                const class_start = pos + 1;
                var class_end = class_start;
                while (class_end < text.len and (std.ascii.isAlphanumeric(text[class_end]) or text[class_end] == '-' or text[class_end] == '_')) {
                    class_end += 1;
                }
                if (std.mem.eql(u8, text[class_start..class_end], symbol)) {
                    return class_start;
                }
                pos = class_end;
            } else if (std.mem.startsWith(u8, text[pos..], "#") and pos + 1 < text.len) {
                const id_start = pos + 1;
                var id_end = id_start;
                while (id_end < text.len and (std.ascii.isAlphanumeric(text[id_end]) or text[id_end] == '-' or text[id_end] == '_')) {
                    id_end += 1;
                }
                if (std.mem.eql(u8, text[id_start..id_end], symbol)) {
                    return id_start;
                }
                pos = id_end;
            } else {
                pos += 1;
            }
        }
        return null;
    }
    
    fn findNextReference(self: *LspServer, text: []const u8, symbol: []const u8, search_pos: *usize) ?usize {
        _ = self;
        while (search_pos.* < text.len) {
            const found = std.mem.indexOfPos(u8, text, search_pos.*, symbol) orelse return null;
            search_pos.* = found + symbol.len;
            
            const before = if (found > 0) text[found - 1] else ' ';
            const after = if (found + symbol.len < text.len) text[found + symbol.len] else ' ';
            
            if ((before == '.' or before == '#' or before == ' ' or before == '\n' or before == '\t' or before == '{' or before == ',' or before == ':') and
                (after == ' ' or after == '\n' or after == '\t' or after == '{' or after == '}' or after == ',' or after == ';' or after == ':' or after == ')')) {
                return found;
            }
        }
        return null;
    }
    
    const COMMON_CSS_PROPERTIES = [_][]const u8{
        "color",
        "background-color",
        "padding",
        "margin",
        "width",
        "height",
        "display",
        "font-size",
        "font-weight",
        "border",
        "border-width",
        "border-style",
        "border-color",
        "border-radius",
        "position",
        "top",
        "right",
        "bottom",
        "left",
        "z-index",
        "opacity",
        "visibility",
        "overflow",
        "text-align",
        "text-decoration",
        "line-height",
        "letter-spacing",
        "word-spacing",
        "white-space",
        "cursor",
        "user-select",
        "pointer-events",
        "box-shadow",
        "transform",
        "transition",
        "animation",
        "flex",
        "flex-direction",
        "flex-wrap",
        "justify-content",
        "align-items",
        "grid",
        "grid-template-columns",
        "grid-template-rows",
        "gap",
    };
};

fn initializeTestServer(server: *LspServer) !void {
    const response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
    );
    server.allocator.free(response);
}

fn expectNoResponse(server: *LspServer, message: []const u8) !void {
    switch (try server.handleMessage(message)) {
        .no_response => {},
        .response => |response| {
            server.allocator.free(response);
            return error.UnexpectedResponse;
        },
        .exit => return error.UnexpectedExit,
    }
}

fn expectJsonRange(
    range_value: std.json.Value,
    start_line: i64,
    start_character: i64,
    end_line: i64,
    end_character: i64,
) !void {
    try std.testing.expect(range_value == .object);
    const start = range_value.object.get("start").?.object;
    const end = range_value.object.get("end").?.object;
    try std.testing.expectEqual(start_line, start.get("line").?.integer);
    try std.testing.expectEqual(start_character, start.get("character").?.integer);
    try std.testing.expectEqual(end_line, end.get("line").?.integer);
    try std.testing.expectEqual(end_character, end.get("character").?.integer);
}

test "LSP server initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();

    try std.testing.expectEqual(LspServer.Lifecycle.pre_initialize, server.lifecycle);
    try std.testing.expect(server.root_uri == null);
}

test "LSP handle initialize request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();

    const request = 
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///test","capabilities":{}}}
    ;
    
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    try std.testing.expectEqual(LspServer.Lifecycle.running, server.lifecycle);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const capabilities = parsed.value.object
        .get("result").?.object
        .get("capabilities").?.object;
    try std.testing.expectEqualStrings(
        "utf-16",
        capabilities.get("positionEncoding").?.string,
    );
    const synchronization = capabilities.get("textDocumentSync").?.object;
    try std.testing.expect(synchronization.get("openClose").?.bool);
    try std.testing.expectEqual(@as(i64, 1), synchronization.get("change").?.integer);
    try std.testing.expect(capabilities.get("hoverProvider") == null);
    try std.testing.expect(capabilities.get("completionProvider") == null);
    try std.testing.expect(capabilities.get("diagnosticProvider") == null);
}

test "LSP returns structured JSON-RPC envelope errors" {
    var server = LspServer.init(std.testing.allocator);
    defer server.deinit();

    const cases = [_]struct {
        request: []const u8,
        code: i64,
        id: ?i64 = null,
    }{
        .{ .request = "{", .code = -32700 },
        .{ .request = "[]", .code = -32600 },
        .{
            .request = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
            .code = -32600,
        },
        .{
            .request = "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"initialize\",\"params\":{}}",
            .code = -32600,
        },
        .{
            .request = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":[]}",
            .code = -32602,
            .id = 7,
        },
    };

    for (cases) |case| {
        const response = try server.handleRequest(case.request);
        defer std.testing.allocator.free(response);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            response,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "2.0",
            parsed.value.object.get("jsonrpc").?.string,
        );
        try std.testing.expectEqual(
            case.code,
            parsed.value.object.get("error").?.object.get("code").?.integer,
        );
        if (case.id) |id| {
            try std.testing.expectEqual(id, parsed.value.object.get("id").?.integer);
        } else {
            try std.testing.expect(parsed.value.object.get("id").? == .null);
        }
    }

    const large_id_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"method\":\"unknown/method\"}",
    );
    defer std.testing.allocator.free(large_id_response);
    try std.testing.expect(
        std.mem.indexOf(u8, large_id_response, "\"id\":9223372036854775808") != null,
    );
    var parsed_large_id = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        large_id_response,
        .{},
    );
    defer parsed_large_id.deinit();
    try std.testing.expectEqualStrings(
        "9223372036854775808",
        parsed_large_id.value.object.get("id").?.number_string,
    );
}

test "LSP serializer escapes handler strings and dynamic object fields" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();
    const uri = "file:///a\"b.css";

    try initializeTestServer(&server);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a\\\"b.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".foo{color:red}.foo{}\"}}}",
    );

    const hover = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"hover\\n\\\"id\",\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///a\\\"b.css\"},\"position\":{\"line\":0,\"character\":5}}}",
    );
    defer allocator.free(hover);
    var parsed_hover = try std.json.parseFromSlice(std.json.Value, allocator, hover, .{});
    defer parsed_hover.deinit();
    try std.testing.expectEqualStrings(
        "hover\n\"id",
        parsed_hover.value.object.get("id").?.string,
    );
    const markdown = parsed_hover.value.object
        .get("result").?.object
        .get("contents").?.object
        .get("value").?.string;
    try std.testing.expect(std.mem.indexOfScalar(u8, markdown, '\n') != null);

    const rename = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///a\\\"b.css\"},\"position\":{\"line\":0,\"character\":1},\"newName\":\"renamed\\nname\"}}",
    );
    defer allocator.free(rename);
    var parsed_rename = try std.json.parseFromSlice(std.json.Value, allocator, rename, .{});
    defer parsed_rename.deinit();
    const edits = parsed_rename.value.object
        .get("result").?.object
        .get("changes").?.object
        .get(uri).?.array.items;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings(
        "renamed\nname",
        edits[0].object.get("newText").?.string,
    );
}

test "LSP positions use UTF-16 across non-BMP text and CRLF" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\",\"languageId\":\"css\",\"version\":1,\"text\":\"😀.foo{color:red}\\r\\nα .foo{}\"}}}",
    );

    const response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":3}}}",
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result == .object);
    try expectJsonRange(result.object.get("range").?, 0, 3, 0, 6);

    const references_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":3}}}",
    );
    defer allocator.free(references_response);
    var parsed_references = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        references_response,
        .{},
    );
    defer parsed_references.deinit();
    const references = parsed_references.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), references.len);
    try expectJsonRange(references[0].object.get("range").?, 0, 3, 0, 6);
    try expectJsonRange(references[1].object.get("range").?, 1, 3, 1, 6);

    const hover_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":0,\"character\":7}}}",
    );
    defer allocator.free(hover_response);
    var parsed_hover = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        hover_response,
        .{},
    );
    defer parsed_hover.deinit();
    try expectJsonRange(
        parsed_hover.value.object.get("result").?.object.get("range").?,
        0,
        7,
        0,
        12,
    );

    const invalid_positions = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":0,\"character\":1}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":-1,\"character\":0}}}",
    };
    for (invalid_positions) |request| {
        const invalid_response = try server.handleRequest(request);
        defer allocator.free(invalid_response);
        var invalid = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            invalid_response,
            .{},
        );
        defer invalid.deinit();
        try std.testing.expectEqual(
            @as(i64, -32602),
            invalid.value.object.get("error").?.object.get("code").?.integer,
        );
    }

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.scss\",\"languageId\":\"scss\",\"version\":1,\"text\":\"😀$x: red;\"}}}",
    );
    const diagnostics_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/diagnostics\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.scss\"}}}",
    );
    defer allocator.free(diagnostics_response);
    var parsed_diagnostics = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        diagnostics_response,
        .{},
    );
    defer parsed_diagnostics.deinit();
    const diagnostics = parsed_diagnostics.value.object
        .get("result").?.object
        .get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try expectJsonRange(diagnostics[0].object.get("range").?, 0, 0, 0, 2);
}

test "LSP serializes every handler response as complete JSON" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".foo{color:red}.foo{}\"}}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\",\"version\":2},\"contentChanges\":[{\"text\":\".foo{color:blue}.foo{}\"}]}}",
    );

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/diagnostics\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":6}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":0}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2},\"newName\":\"bar\"}}",
    };

    for (requests, 5..) |request, id| {
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
        try std.testing.expectEqual(@as(i64, @intCast(id)), parsed.value.object.get("id").?.integer);
        try std.testing.expect(parsed.value.object.get("result") != null);
        try std.testing.expect(parsed.value.object.get("error") == null);
    }
}

test "LSP document synchronization is balanced full and version ordered" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"languageId\":\"css\",\"version\":5,\"text\":\".v5{}\"}}}",
    );
    try std.testing.expectEqual(@as(i32, 5), server.documents.get("file:///versions.css").?.version);
    try std.testing.expectEqualStrings(".v5{}", server.documents.get("file:///versions.css").?.text);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"languageId\":\"css\",\"version\":6,\"text\":\".duplicate{}\"}}}",
    );
    try std.testing.expectEqual(@as(i32, 5), server.documents.get("file:///versions.css").?.version);
    try std.testing.expectEqualStrings(".v5{}", server.documents.get("file:///versions.css").?.text);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"version\":5},\"contentChanges\":[{\"text\":\".stale{}\"}]}}",
    );
    try std.testing.expectEqualStrings(".v5{}", server.documents.get("file:///versions.css").?.text);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"version\":7},\"contentChanges\":[{\"text\":\".v7{}\"}]}}",
    );
    try std.testing.expectEqual(@as(i32, 7), server.documents.get("file:///versions.css").?.version);
    try std.testing.expectEqualStrings(".v7{}", server.documents.get("file:///versions.css").?.text);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"version\":8},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"text\":\"x\"}]}}",
    );
    try std.testing.expectEqual(@as(i32, 7), server.documents.get("file:///versions.css").?.version);
    try std.testing.expectEqualStrings(".v7{}", server.documents.get("file:///versions.css").?.text);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\"}}}",
    );
    try std.testing.expect(server.documents.get("file:///versions.css") == null);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"version\":9},\"contentChanges\":[{\"text\":\".closed{}\"}]}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\"}}}",
    );
    try std.testing.expect(server.documents.get("file:///versions.css") == null);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///versions.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".reopened{}\"}}}",
    );
    try std.testing.expectEqual(@as(i32, 1), server.documents.get("file:///versions.css").?.version);
    try std.testing.expectEqualStrings(".reopened{}", server.documents.get("file:///versions.css").?.text);
}

fn exerciseLspJsonAllocationFailures(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();
    const response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":\"quoted\\\"id\",\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///root\",\"capabilities\":{}}}",
    );
    defer allocator.free(response);
    try std.testing.expect(response.len > 0);
}

fn exerciseLspParseErrorAllocationFailures(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();
    const response = try server.handleRequest("{");
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "-32700") != null);
}

fn exerciseLspDocumentAllocationFailures(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();

    const initialized = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
    );
    allocator.free(initialized);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///allocation.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".a{color:red}\"}}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///allocation.css\",\"version\":2},\"contentChanges\":[{\"text\":\".a{color:blue}\"}]}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///allocation.css\"}}}",
    );
}

fn exerciseLspLifecycleAllocationFailures(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();

    const initialized = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///allocation-root\",\"capabilities\":{}}}",
    );
    allocator.free(initialized);
    const shutdown = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
    );
    allocator.free(shutdown);
    const exited = try server.handleMessage(
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    );
    try std.testing.expect(exited == .exit);
    try std.testing.expectEqual(ExitStatus.success, exited.exit);
}

test "LSP JSON parsing and responses handle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLspJsonAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLspParseErrorAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLspDocumentAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLspLifecycleAllocationFailures,
        .{},
    );
}

test "LSP diagnostics reject unavailable formats without CSS fallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();
    try initializeTestServer(&server);

    const cases = [_]struct {
        open: []const u8,
        diagnostics: []const u8,
    }{
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.scss","languageId":"scss","version":1,"text":"$color: red;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.scss"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.sass","languageId":"sass","version":1,"text":"$color: red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":4,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.sass"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.less","languageId":"less","version":1,"text":"@color: red;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":6,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.less"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.styl","languageId":"stylus","version":1,"text":"$color = red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":8,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.styl"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///library-only.module.css","languageId":"css","version":1,"text":".card{x:1}"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":10,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///library-only.module.css"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.js","languageId":"javascript","version":1,"text":"const styles = `\\n.card { color: ${theme.color}; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":12,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.css.js"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.ts","languageId":"typescript","version":1,"text":"const styles = `\\n.card { color: red; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":14,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.css.ts"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.postcss","languageId":"postcss","version":1,"text":"@custom-media --narrow (width < 40rem); .card { color: red; }"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":16,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.postcss"}}}
            ,
        },
    };

    for (cases) |case| {
        try expectNoResponse(&server, case.open);
        const diagnostics = try server.handleRequest(case.diagnostics);
        defer allocator.free(diagnostics);
        try std.testing.expect(std.mem.containsAtLeast(
            u8,
            diagnostics,
            1,
            unsupported_format_message,
        ));
    }
}
