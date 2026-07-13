const std = @import("std");
const compiler = @import("zigcss");
const formats = @import("formats.zig");
const lsp_index = @import("lsp_index.zig");
const lsp_position = @import("lsp_position.zig");

const unsupported_format_message = "Unsupported or removed stylesheet format";
const max_workspace_query_storage: usize = 4096;

const ServerLimits = struct {
    max_workspace_documents: usize = 4096,
    max_workspace_text_bytes: usize = 256 * 1024 * 1024,
    max_workspace_uri_bytes: usize = 16 * 1024 * 1024,
    max_workspace_index_bytes: usize = 128 * 1024 * 1024,
    max_document_uri_bytes: usize = 64 * 1024,
    max_workspace_results: usize = 100_000,
    max_editor_response_bytes: usize = 16 * 1024 * 1024,
    max_workspace_query_bytes: usize = 256,
    max_rename_name_bytes: usize = 4096,
    index: lsp_index.Limits = .{},
};

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
    workspace_text_bytes: usize,
    workspace_uri_bytes: usize,
    workspace_index_bytes: usize,
    limits: ServerLimits,

    const Lifecycle = enum {
        pre_initialize,
        running,
        shutdown,
    };

    // The hash-map key is the sole owned URI copy.
    const Document = struct {
        version: i32,
        text: []const u8,
        index: ?lsp_index.DocumentIndex = null,
    };

    pub fn init(allocator: std.mem.Allocator) LspServer {
        return .{
            .allocator = allocator,
            .lifecycle = .pre_initialize,
            .documents = std.StringHashMap(Document).init(allocator),
            .workspace_text_bytes = 0,
            .workspace_uri_bytes = 0,
            .workspace_index_bytes = 0,
            .limits = .{},
        };
    }

    pub fn deinit(self: *LspServer) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.clearDocumentIndex(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.text);
        }
        std.debug.assert(self.workspace_index_bytes == 0);
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
            error.RequestFailed => {
                success = false;
                try writeErrorField(&json, -32803, "Request failed");
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
        } else if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
            try self.handleDocumentDiagnostic(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbols(json, root);
        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            try self.handleWorkspaceSymbols(json, root);
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
        severity: compiler.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
    ) !void {
        try json.write(.{
            .range = range,
            .severity = diagnosticSeverity(severity),
            .code = code,
            .message = message,
            .source = "zigcss",
        });
    }

    fn diagnosticSeverity(severity: compiler.DiagnosticSeverity) i32 {
        return switch (severity) {
            .err => 1,
            .warning => 2,
            .note => 3,
        };
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

    fn requireBooleanField(object: JsonObject, name: []const u8) !bool {
        const value = object.get(name) orelse return error.InvalidParams;
        return switch (value) {
            .bool => |result| result,
            else => error.InvalidParams,
        };
    }

    fn optionalStringField(object: JsonObject, name: []const u8) !?[]const u8 {
        const value = object.get(name) orelse return null;
        return switch (value) {
            .string => |result| result,
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

    fn firstScalarRange(text: []const u8) !PositionRange {
        var end: usize = 0;
        if (text.len > 0 and text[0] != '\r' and text[0] != '\n') {
            end = std.unicode.utf8ByteSequenceLength(text[0]) catch
                return error.InvalidParams;
            if (end > text.len) return error.InvalidParams;
            _ = std.unicode.utf8Decode(text[0..end]) catch
                return error.InvalidParams;
        }
        return utf16Range(text, 0, end);
    }

    const WorkspaceDocument = struct {
        uri: []const u8,
        document: *Document,
    };

    fn workspaceDocuments(self: *LspServer) ![]WorkspaceDocument {
        if (self.documents.count() > self.limits.max_workspace_documents) {
            return error.RequestFailed;
        }
        const documents = try self.allocator.alloc(
            WorkspaceDocument,
            self.documents.count(),
        );
        var count: usize = 0;
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| : (count += 1) {
            documents[count] = .{
                .uri = entry.key_ptr.*,
                .document = entry.value_ptr,
            };
        }

        std.mem.sort(WorkspaceDocument, documents, {}, workspaceDocumentLessThan);
        return documents;
    }

    fn workspaceDocumentLessThan(
        _: void,
        left: WorkspaceDocument,
        right: WorkspaceDocument,
    ) bool {
        return std.mem.order(u8, left.uri, right.uri) == .lt;
    }

    fn ensureIndex(
        self: *LspServer,
        uri: []const u8,
        document: *Document,
    ) !*const lsp_index.DocumentIndex {
        if (formats.detectFormat(uri) != .css) return error.InvalidParams;
        if (document.index == null) {
            var index = lsp_index.DocumentIndex.build(
                self.allocator,
                uri,
                document.text,
                self.limits.index,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.RequestFailed,
            };
            const next_index_bytes = std.math.add(
                usize,
                self.workspace_index_bytes,
                index.ownedBytes(),
            ) catch {
                index.deinit();
                return error.RequestFailed;
            };
            if (next_index_bytes > self.limits.max_workspace_index_bytes) {
                index.deinit();
                return error.RequestFailed;
            }
            document.index = index;
            self.workspace_index_bytes = next_index_bytes;
        }
        return if (document.index) |*index| index else unreachable;
    }

    fn clearDocumentIndex(self: *LspServer, document: *Document) void {
        if (document.index) |*index| {
            self.workspace_index_bytes -= index.ownedBytes();
            index.deinit();
            document.index = null;
        }
    }

    fn handleInitialize(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        _ = try requireObjectField(params, "capabilities");
        if (params.get("rootUri")) |root_uri| {
            const replacement: ?[]u8 = switch (root_uri) {
                .null => null,
                .string => |value| blk: {
                    if (value.len == 0) break :blk null;
                    if (value.len > self.limits.max_document_uri_bytes) {
                        return error.InvalidParams;
                    }
                    break :blk try self.allocator.dupe(u8, value);
                },
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
        try json.objectField("diagnosticProvider");
        try json.beginObject();
        try json.objectField("identifier");
        try json.write("zigcss");
        try json.objectField("interFileDependencies");
        try json.write(false);
        try json.objectField("workspaceDiagnostics");
        try json.write(false);
        try json.endObject();
        try json.objectField("hoverProvider");
        try json.write(true);
        try json.objectField("completionProvider");
        try json.beginObject();
        try json.endObject();
        try json.objectField("documentSymbolProvider");
        try json.write(true);
        try json.objectField("workspaceSymbolProvider");
        try json.write(true);
        try json.objectField("definitionProvider");
        try json.write(true);
        try json.objectField("referencesProvider");
        try json.write(true);
        try json.objectField("renameProvider");
        try json.write(true);
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
        if (uri.len == 0 or uri.len > self.limits.max_document_uri_bytes or
            self.documents.contains(uri) or
            self.documents.count() >= self.limits.max_workspace_documents)
        {
            return error.InvalidParams;
        }
        const next_workspace_bytes = std.math.add(
            usize,
            self.workspace_text_bytes,
            text.len,
        ) catch return error.InvalidParams;
        if (next_workspace_bytes > self.limits.max_workspace_text_bytes) {
            return error.InvalidParams;
        }
        const next_workspace_uri_bytes = std.math.add(
            usize,
            self.workspace_uri_bytes,
            uri.len,
        ) catch return error.InvalidParams;
        if (next_workspace_uri_bytes > self.limits.max_workspace_uri_bytes) {
            return error.InvalidParams;
        }

        {
            const text_copy = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(text_copy);
            const uri_copy = try self.allocator.dupe(u8, uri);
            errdefer self.allocator.free(uri_copy);
            try self.documents.put(uri_copy, .{
                .version = version,
                .text = text_copy,
                .index = null,
            });
        }
        self.workspace_text_bytes = next_workspace_bytes;
        self.workspace_uri_bytes = next_workspace_uri_bytes;
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
        const retained_bytes = self.workspace_text_bytes - document.text.len;
        const next_workspace_bytes = std.math.add(
            usize,
            retained_bytes,
            text.len,
        ) catch return error.InvalidParams;
        if (next_workspace_bytes > self.limits.max_workspace_text_bytes) {
            return error.InvalidParams;
        }
        const text_copy = try self.allocator.dupe(u8, text);
        self.clearDocumentIndex(document);
        self.allocator.free(document.text);
        document.* = .{ .version = version, .text = text_copy, .index = null };
        self.workspace_text_bytes = next_workspace_bytes;
    }

    fn handleDidClose(self: *LspServer, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const removed = self.documents.fetchRemove(uri) orelse return error.InvalidParams;
        var document = removed.value;
        self.clearDocumentIndex(&document);
        self.workspace_uri_bytes -= removed.key.len;
        self.allocator.free(removed.key);
        self.workspace_text_bytes -= document.text.len;
        self.allocator.free(document.text);
    }

    fn handleDocumentDiagnostic(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        if (try optionalStringField(params, "identifier")) |identifier| {
            if (!std.mem.eql(u8, identifier, "zigcss")) return error.InvalidParams;
        }
        _ = try optionalStringField(params, "previousResultId");

        const doc = self.documents.get(uri) orelse return error.InvalidParams;

        const format = formats.detectFormat(uri);
        var compile_result: ?compiler.CompileResult = null;
        defer if (compile_result) |*result| result.deinit();
        if (format != null) {
            compile_result = compiler.compile(self.allocator, uri, doc.text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SourceTooLarge,
                error.CompilationFailed,
                error.ProfilingUnavailable,
                => return error.RequestFailed,
            };
        }
        const unsupported_range = if (format == null)
            try firstScalarRange(doc.text)
        else
            null;
        if (compile_result) |*result| {
            for (result.diagnostics) |diagnostic| {
                _ = try utf16Range(
                    doc.text,
                    diagnostic.span.start,
                    diagnostic.span.end,
                );
            }
        }

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("kind");
        try json.write("full");
        try json.objectField("items");
        try json.beginArray();
        if (format == null) {
            try writeDiagnostic(
                json,
                unsupported_range.?,
                .err,
                compiler.DiagnosticCode.unsupported_syntax.label(),
                unsupported_format_message,
            );
        } else {
            for (compile_result.?.diagnostics) |diagnostic| {
                try writeDiagnostic(
                    json,
                    utf16Range(
                        doc.text,
                        diagnostic.span.start,
                        diagnostic.span.end,
                    ) catch unreachable,
                    diagnostic.severity,
                    diagnostic.code.label(),
                    diagnostic.message,
                );
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

        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const offset = try byteOffsetAtPosition(document.text, position);
        if (formats.detectFormat(uri) != .css) return writeNullResult(json);
        const index = try self.ensureIndex(uri, document);

        var info: ?[]const u8 = null;
        var span: ?compiler.Span = null;
        if (index.propertyAt(offset)) |property| {
            info = getCssPropertyInfo(property.name);
            if (info == null and std.mem.startsWith(u8, property.name, "--")) {
                info = "**CSS custom property** - An authored case-sensitive custom property definition.";
            }
            if (info != null) span = property.name_span;
        }
        if (info == null) {
            if (index.symbolAt(offset)) |symbol| {
                info = symbolHoverInfo(symbol.kind);
                span = symbol.selection_span;
            }
        }
        if (info == null) return writeNullResult(json);

        const range = try utf16Range(document.text, span.?.start, span.?.end);
        try json.objectField("result");
        try json.write(.{
            .contents = .{ .kind = "markdown", .value = info.? },
            .range = range,
        });
    }

    fn writeNullResult(json: *JsonWriter) !void {
        try json.objectField("result");
        try json.write(null);
    }

    fn handleCompletion(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");

        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const offset = try byteOffsetAtPosition(document.text, position);
        const prefix = if (formats.detectFormat(uri) == .css)
            (try self.ensureIndex(uri, document)).completionPrefix(document.text, offset)
        else
            null;
        const replace_range = if (prefix) |value|
            try utf16Range(
                document.text,
                value.replace_span.start,
                value.replace_span.end,
            )
        else
            null;

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("isIncomplete");
        try json.write(false);
        try json.objectField("items");
        try json.beginArray();
        if (prefix) |value| for (COMMON_CSS_PROPERTIES) |property| {
            if (startsWithAsciiIgnoreCase(property, value.value)) {
                try json.write(.{
                    .label = property,
                    .kind = @as(i32, 10),
                    .detail = "CSS Property",
                    .textEdit = .{
                        .range = replace_range.?,
                        .newText = property,
                    },
                });
            }
        };

        try json.endArray();
        try json.endObject();
    }

    fn getCssPropertyInfo(property: []const u8) ?[]const u8 {
        for (CSS_PROPERTY_INFO) |info| {
            if (std.ascii.eqlIgnoreCase(info.property, property)) {
                return info.description;
            }
        }
        return null;
    }

    fn startsWithAsciiIgnoreCase(value: []const u8, prefix: []const u8) bool {
        return prefix.len <= value.len and std.ascii.eqlIgnoreCase(
            value[0..prefix.len],
            prefix,
        );
    }

    const WorkspaceQueryMatcher = struct {
        query: []const u8,
        failure: [max_workspace_query_storage]usize,

        fn init(query: []const u8, max_query_bytes: usize) !WorkspaceQueryMatcher {
            if (query.len > max_query_bytes or
                query.len > max_workspace_query_storage)
            {
                return error.InvalidParams;
            }

            var matcher = WorkspaceQueryMatcher{
                .query = query,
                .failure = undefined,
            };
            if (query.len == 0) return matcher;
            matcher.failure[0] = 0;

            var prefix_len: usize = 0;
            var index: usize = 1;
            while (index < query.len) {
                if (asciiBytesEqual(query[index], query[prefix_len])) {
                    prefix_len += 1;
                    matcher.failure[index] = prefix_len;
                    index += 1;
                } else if (prefix_len > 0) {
                    prefix_len = matcher.failure[prefix_len - 1];
                } else {
                    matcher.failure[index] = 0;
                    index += 1;
                }
            }
            return matcher;
        }

        fn contains(self: *const WorkspaceQueryMatcher, value: []const u8) bool {
            if (self.query.len == 0) return true;
            var matched: usize = 0;
            for (value) |byte| {
                while (matched > 0 and
                    !asciiBytesEqual(byte, self.query[matched]))
                {
                    matched = self.failure[matched - 1];
                }
                if (asciiBytesEqual(byte, self.query[matched])) matched += 1;
                if (matched == self.query.len) return true;
            }
            return false;
        }

        fn asciiBytesEqual(left: u8, right: u8) bool {
            return std.ascii.toLower(left) == std.ascii.toLower(right);
        }
    };

    const EditorResponseBudget = struct {
        used: usize = 0,
        max: usize,

        fn add(
            self: *EditorResponseBudget,
            dynamic_string_bytes: usize,
            fixed_bytes: usize,
        ) !void {
            const escaped_bytes = std.math.mul(
                usize,
                dynamic_string_bytes,
                6,
            ) catch return error.RequestFailed;
            const item_bytes = std.math.add(
                usize,
                escaped_bytes,
                fixed_bytes,
            ) catch return error.RequestFailed;
            const next = std.math.add(usize, self.used, item_bytes) catch
                return error.RequestFailed;
            if (next > self.max) return error.RequestFailed;
            self.used = next;
        }
    };

    fn handleDocumentSymbols(
        self: *LspServer,
        json: *JsonWriter,
        root: JsonObject,
    ) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const index = if (formats.detectFormat(uri) == .css)
            try self.ensureIndex(uri, document)
        else
            null;

        var response_budget = EditorResponseBudget{
            .max = self.limits.max_editor_response_bytes,
        };
        if (index) |document_index| for (document_index.symbols) |symbol| {
            if (!isDocumentSymbol(symbol)) continue;
            try response_budget.add(symbol.name.len, 512);
            _ = try utf16Range(
                document.text,
                symbol.container_span.start,
                symbol.container_span.end,
            );
            _ = try utf16Range(
                document.text,
                symbol.selection_span.start,
                symbol.selection_span.end,
            );
        };

        try json.objectField("result");
        try json.beginArray();
        if (index) |document_index| for (document_index.symbols) |symbol| {
            if (!isDocumentSymbol(symbol)) continue;
            try json.write(.{
                .name = symbol.name,
                .detail = symbolDetail(symbol.kind),
                .kind = symbolKind(symbol.kind),
                .range = utf16Range(
                    document.text,
                    symbol.container_span.start,
                    symbol.container_span.end,
                ) catch unreachable,
                .selectionRange = utf16Range(
                    document.text,
                    symbol.selection_span.start,
                    symbol.selection_span.end,
                ) catch unreachable,
            });
        };
        try json.endArray();
    }

    fn handleWorkspaceSymbols(
        self: *LspServer,
        json: *JsonWriter,
        root: JsonObject,
    ) !void {
        const params = try requireObjectField(root, "params");
        const query = try requireStringField(params, "query");
        const matcher = try WorkspaceQueryMatcher.init(
            query,
            self.limits.max_workspace_query_bytes,
        );
        const documents = try self.workspaceDocuments();
        defer self.allocator.free(documents);

        var result_count: usize = 0;
        var response_budget = EditorResponseBudget{
            .max = self.limits.max_editor_response_bytes,
        };
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = try self.ensureIndex(entry.uri, entry.document);
            for (index.symbols) |symbol| {
                if (!isDocumentSymbol(symbol) or
                    !matcher.contains(symbol.name))
                {
                    continue;
                }
                result_count += 1;
                if (result_count > self.limits.max_workspace_results) {
                    return error.RequestFailed;
                }
                try response_budget.add(symbol.name.len, 512);
                try response_budget.add(entry.uri.len, 0);
                _ = try utf16Range(
                    entry.document.text,
                    symbol.selection_span.start,
                    symbol.selection_span.end,
                );
            }
        }

        try json.objectField("result");
        try json.beginArray();
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = &entry.document.index.?;
            for (index.symbols) |symbol| {
                if (!isDocumentSymbol(symbol) or
                    !matcher.contains(symbol.name))
                {
                    continue;
                }
                try json.write(.{
                    .name = symbol.name,
                    .kind = symbolKind(symbol.kind),
                    .location = .{
                        .uri = entry.uri,
                        .range = utf16Range(
                            entry.document.text,
                            symbol.selection_span.start,
                            symbol.selection_span.end,
                        ) catch unreachable,
                    },
                });
            }
        }
        try json.endArray();
    }

    fn symbolHoverInfo(kind: lsp_index.SymbolKind) []const u8 {
        return switch (kind) {
            .class => "**CSS class selector** - A syntax-indexed class selector in an open stylesheet.",
            .id => "**CSS ID selector** - A syntax-indexed ID selector in an open stylesheet.",
            .custom_property => "**CSS custom property** - A syntax-indexed definition or var() reference.",
            .keyframes => "**CSS keyframes name** - A syntax-indexed keyframes definition or animation-name reference.",
        };
    }

    fn symbolKind(kind: lsp_index.SymbolKind) i32 {
        return switch (kind) {
            .class => 5,
            .id => 20,
            .custom_property => 13,
            .keyframes => 12,
        };
    }

    fn symbolDetail(kind: lsp_index.SymbolKind) []const u8 {
        return switch (kind) {
            .class => "CSS class selector",
            .id => "CSS ID selector",
            .custom_property => "CSS custom property",
            .keyframes => "CSS keyframes",
        };
    }

    fn isDocumentSymbol(symbol: lsp_index.Symbol) bool {
        return symbol.role == .definition or
            symbol.kind == .class or
            symbol.kind == .id;
    }

    fn symbolMatches(left: lsp_index.Symbol, right: lsp_index.Symbol) bool {
        return left.kind == right.kind and std.mem.eql(u8, left.name, right.name);
    }

    fn validRenameName(
        self: *const LspServer,
        kind: lsp_index.SymbolKind,
        name: []const u8,
    ) bool {
        if (name.len == 0 or name.len > self.limits.max_rename_name_bytes) {
            return false;
        }
        if (!std.unicode.utf8ValidateSlice(name) or
            std.mem.indexOfScalar(u8, name, 0) != null)
        {
            return false;
        }
        return switch (kind) {
            .custom_property => std.mem.startsWith(u8, name, "--"),
            .keyframes => !isReservedKeyframesName(name),
            .class, .id => true,
        };
    }

    fn isReservedKeyframesName(name: []const u8) bool {
        const reserved = [_][]const u8{
            "none",
            "initial",
            "inherit",
            "unset",
            "revert",
            "revert-layer",
        };
        for (reserved) |keyword| {
            if (std.ascii.eqlIgnoreCase(name, keyword)) return true;
        }
        return false;
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

        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const offset = try byteOffsetAtPosition(document.text, position);
        if (formats.detectFormat(uri) != .css) return writeNullResult(json);
        const source_index = try self.ensureIndex(uri, document);
        const selected = source_index.symbolAt(offset) orelse return writeNullResult(json);

        const documents = try self.workspaceDocuments();
        defer self.allocator.free(documents);
        var result_count: usize = 0;
        var response_budget = EditorResponseBudget{
            .max = self.limits.max_editor_response_bytes,
        };
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = try self.ensureIndex(entry.uri, entry.document);
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol) or symbol.role != .definition) continue;
                result_count += 1;
                if (result_count > self.limits.max_workspace_results) {
                    return error.RequestFailed;
                }
                try response_budget.add(entry.uri.len, 256);
                _ = try utf16Range(
                    entry.document.text,
                    symbol.selection_span.start,
                    symbol.selection_span.end,
                );
            }
        }
        if (result_count == 0) return writeNullResult(json);

        try json.objectField("result");
        try json.beginArray();
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = &entry.document.index.?;
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol) or symbol.role != .definition) continue;
                try json.write(.{
                    .uri = entry.uri,
                    .range = utf16Range(
                        entry.document.text,
                        symbol.selection_span.start,
                        symbol.selection_span.end,
                    ) catch unreachable,
                });
            }
        }
        try json.endArray();
    }

    fn handleReferences(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");
        const context = try requireObjectField(params, "context");
        const include_declaration = try requireBooleanField(context, "includeDeclaration");
        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const offset = try byteOffsetAtPosition(document.text, position);
        if (formats.detectFormat(uri) != .css) return writeEmptyArrayResult(json);
        const source_index = try self.ensureIndex(uri, document);
        const selected = source_index.symbolAt(offset) orelse
            return writeEmptyArrayResult(json);

        const documents = try self.workspaceDocuments();
        defer self.allocator.free(documents);
        var result_count: usize = 0;
        var response_budget = EditorResponseBudget{
            .max = self.limits.max_editor_response_bytes,
        };
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = try self.ensureIndex(entry.uri, entry.document);
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol) or
                    (!include_declaration and symbol.role == .definition))
                {
                    continue;
                }
                result_count += 1;
                if (result_count > self.limits.max_workspace_results) {
                    return error.RequestFailed;
                }
                try response_budget.add(entry.uri.len, 256);
                _ = try utf16Range(
                    entry.document.text,
                    symbol.selection_span.start,
                    symbol.selection_span.end,
                );
            }
        }

        try json.objectField("result");
        try json.beginArray();
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = &entry.document.index.?;
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol) or
                    (!include_declaration and symbol.role == .definition))
                {
                    continue;
                }
                try json.write(.{
                    .uri = entry.uri,
                    .range = utf16Range(
                        entry.document.text,
                        symbol.selection_span.start,
                        symbol.selection_span.end,
                    ) catch unreachable,
                });
            }
        }
        try json.endArray();
    }

    fn writeEmptyArrayResult(json: *JsonWriter) !void {
        try json.objectField("result");
        try json.beginArray();
        try json.endArray();
    }

    fn handleRename(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");
        const new_name = try requireStringField(params, "newName");

        const document = self.documents.getPtr(uri) orelse return error.InvalidParams;
        const offset = try byteOffsetAtPosition(document.text, position);
        if (formats.detectFormat(uri) != .css) return error.InvalidParams;
        const source_index = try self.ensureIndex(uri, document);
        const selected = source_index.symbolAt(offset) orelse return error.InvalidParams;
        if (!self.validRenameName(selected.kind, new_name)) return error.InvalidParams;
        const serialized_name = compiler.css.emitter.serializeIdentifierAlloc(
            self.allocator,
            new_name,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidParams,
        };
        defer self.allocator.free(serialized_name);

        const documents = try self.workspaceDocuments();
        defer self.allocator.free(documents);
        var result_count: usize = 0;
        var response_budget = EditorResponseBudget{
            .max = self.limits.max_editor_response_bytes,
        };
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = try self.ensureIndex(entry.uri, entry.document);
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol)) continue;
                result_count += 1;
                if (result_count > self.limits.max_workspace_results) {
                    return error.RequestFailed;
                }
                try response_budget.add(entry.uri.len, 512);
                try response_budget.add(serialized_name.len, 0);
                _ = try utf16Range(
                    entry.document.text,
                    symbol.selection_span.start,
                    symbol.selection_span.end,
                );
            }
        }
        if (result_count == 0) return error.InvalidParams;

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("changes");
        try json.beginObject();
        for (documents) |entry| {
            if (formats.detectFormat(entry.uri) != .css) continue;
            const index = &entry.document.index.?;
            var document_count: usize = 0;
            for (index.symbols) |symbol| {
                if (symbolMatches(selected.*, symbol)) document_count += 1;
            }
            if (document_count == 0) continue;
            try json.objectField(entry.uri);
            try json.beginArray();
            for (index.symbols) |symbol| {
                if (!symbolMatches(selected.*, symbol)) continue;
                try json.write(.{
                    .range = utf16Range(
                        entry.document.text,
                        symbol.selection_span.start,
                        symbol.selection_span.end,
                    ) catch unreachable,
                    .newText = serialized_name,
                });
            }
            try json.endArray();
        }
        try json.endObject();
        try json.endObject();
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

fn expectJsonRpcError(
    server: *LspServer,
    request: []const u8,
    expected_code: i64,
) !void {
    const response = try server.handleRequest(request);
    defer server.allocator.free(response);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        server.allocator,
        response,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(
        expected_code,
        parsed.value.object.get("error").?.object.get("code").?.integer,
    );
}

test "LSP server initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();

    try std.testing.expectEqual(LspServer.Lifecycle.pre_initialize, server.lifecycle);
    try std.testing.expect(server.root_uri == null);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_text_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_uri_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);
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
    try std.testing.expect(capabilities.get("hoverProvider").?.bool);
    try std.testing.expect(capabilities.get("completionProvider").? == .object);
    try std.testing.expect(capabilities.get("documentSymbolProvider").?.bool);
    try std.testing.expect(capabilities.get("workspaceSymbolProvider").?.bool);
    try std.testing.expect(capabilities.get("definitionProvider").?.bool);
    try std.testing.expect(capabilities.get("referencesProvider").?.bool);
    try std.testing.expect(capabilities.get("renameProvider").?.bool);
    const diagnostic_provider = capabilities.get("diagnosticProvider").?.object;
    try std.testing.expectEqualStrings(
        "zigcss",
        diagnostic_provider.get("identifier").?.string,
    );
    try std.testing.expect(!diagnostic_provider.get("interFileDependencies").?.bool);
    try std.testing.expect(!diagnostic_provider.get("workspaceDiagnostics").?.bool);
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
        "renamed\\a name",
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
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\",\"languageId\":\"css\",\"version\":1,\"text\":\"😀:root{--foo:red}\\r\\nα .x{color:var(--foo)}\"}}}",
    );

    const response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":17}}}",
    );
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?;
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 1), result.array.items.len);
    try expectJsonRange(result.array.items[0].object.get("range").?, 0, 8, 0, 13);

    const references_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":17},\"context\":{\"includeDeclaration\":true}}}",
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
    try expectJsonRange(references[0].object.get("range").?, 0, 8, 0, 13);
    try expectJsonRange(references[1].object.get("range").?, 1, 15, 1, 20);

    const hover_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.css\"},\"position\":{\"line\":1,\"character\":7}}}",
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
        1,
        5,
        1,
        10,
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
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///utf16.scss\"}}}",
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
    try std.testing.expectEqualStrings(
        "CSS0009",
        diagnostics[0].object.get("code").?.string,
    );
    try expectJsonRange(diagnostics[0].object.get("range").?, 0, 0, 0, 2);
}

test "LSP syntax index powers deterministic workspace editor features" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    // Open in reverse URI order so workspace results prove their explicit sort.
    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.css","languageId":"css","version":1,"text":".hero { color: var(--theme); animation-name: pulse; }\n.card { color: blue; }\n/* --theme pulse */"}}}
    );
    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.css","languageId":"css","version":1,"text":":root { --theme: red; }\n.card { color: var(--theme); content: \"--theme\"; }\n@keyframes pulse { from { opacity: 0; } to { opacity: 1; } }\n.new { ba }\n/* --theme */"}}}
    );

    const hover_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":20,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":10}}}
    );
    defer allocator.free(hover_response);
    var hover = try std.json.parseFromSlice(std.json.Value, allocator, hover_response, .{});
    defer hover.deinit();
    const hover_result = hover.value.object.get("result").?.object;
    try expectJsonRange(hover_result.get("range").?, 1, 8, 1, 13);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            hover_result.get("contents").?.object.get("value").?.string,
            "Sets the text color",
        ) != null,
    );

    const opaque_hover_requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":21,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":42}}}
        ,
        \\{"jsonrpc":"2.0","id":22,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":4,"character":5}}}
        ,
    };
    for (opaque_hover_requests) |request| {
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result").? == .null);
    }

    const completion_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":23,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":3,"character":9}}}
    );
    defer allocator.free(completion_response);
    var completion = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        completion_response,
        .{},
    );
    defer completion.deinit();
    const completion_result = completion.value.object.get("result").?.object;
    try std.testing.expect(!completion_result.get("isIncomplete").?.bool);
    const completion_items = completion_result.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), completion_items.len);
    try std.testing.expectEqualStrings(
        "background-color",
        completion_items[0].object.get("label").?.string,
    );
    try expectJsonRange(
        completion_items[0].object.get("textEdit").?.object.get("range").?,
        3,
        7,
        3,
        9,
    );

    const closed_completion_requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":24,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":2}}}
        ,
        \\{"jsonrpc":"2.0","id":25,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":20}}}
        ,
        \\{"jsonrpc":"2.0","id":26,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":42}}}
        ,
    };
    for (closed_completion_requests) |request| {
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(
            @as(usize, 0),
            parsed.value.object.get("result").?.object.get("items").?.array.items.len,
        );
    }

    const document_symbols_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":27,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.css"}}}
    );
    defer allocator.free(document_symbols_response);
    var document_symbols = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        document_symbols_response,
        .{},
    );
    defer document_symbols.deinit();
    const symbol_items = document_symbols.value.object.get("result").?.array.items;
    const expected_symbol_names = [_][]const u8{ "--theme", "card", "pulse", "new" };
    try std.testing.expectEqual(expected_symbol_names.len, symbol_items.len);
    for (symbol_items, expected_symbol_names) |item, expected_name| {
        try std.testing.expectEqualStrings(expected_name, item.object.get("name").?.string);
    }

    const workspace_symbols_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":28,"method":"workspace/symbol","params":{"query":"CaRd"}}
    );
    defer allocator.free(workspace_symbols_response);
    var workspace_symbols = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        workspace_symbols_response,
        .{},
    );
    defer workspace_symbols.deinit();
    const workspace_items = workspace_symbols.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), workspace_items.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        workspace_items[0].object.get("location").?.object.get("uri").?.string,
    );
    try std.testing.expectEqualStrings(
        "file:///b.css",
        workspace_items[1].object.get("location").?.object.get("uri").?.string,
    );

    const definition_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":29,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20}}}
    );
    defer allocator.free(definition_response);
    var definition = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        definition_response,
        .{},
    );
    defer definition.deinit();
    const definitions = definition.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        definitions[0].object.get("uri").?.string,
    );
    try expectJsonRange(definitions[0].object.get("range").?, 0, 8, 0, 15);

    const class_definition_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":30,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":1,"character":2}}}
    );
    defer allocator.free(class_definition_response);
    var class_definition = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        class_definition_response,
        .{},
    );
    defer class_definition.deinit();
    try std.testing.expect(class_definition.value.object.get("result").? == .null);

    const references_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":31,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"context":{"includeDeclaration":false}}}
    );
    defer allocator.free(references_response);
    var references = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        references_response,
        .{},
    );
    defer references.deinit();
    const reference_items = references.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), reference_items.len);
    try std.testing.expectEqualStrings(
        "file:///a.css",
        reference_items[0].object.get("uri").?.string,
    );
    try expectJsonRange(reference_items[0].object.get("range").?, 1, 19, 1, 26);
    try std.testing.expectEqualStrings(
        "file:///b.css",
        reference_items[1].object.get("uri").?.string,
    );
    try expectJsonRange(reference_items[1].object.get("range").?, 0, 19, 0, 26);

    const all_references_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":32,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"context":{"includeDeclaration":true}}}
    );
    defer allocator.free(all_references_response);
    var all_references = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        all_references_response,
        .{},
    );
    defer all_references.deinit();
    const all_reference_items = all_references.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), all_reference_items.len);
    try expectJsonRange(all_reference_items[0].object.get("range").?, 0, 8, 0, 15);
    try expectJsonRange(all_reference_items[1].object.get("range").?, 1, 19, 1, 26);
    try expectJsonRange(all_reference_items[2].object.get("range").?, 0, 19, 0, 26);

    const rename_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":33,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"newName":"--renamed\nname"}}
    );
    defer allocator.free(rename_response);
    var rename = try std.json.parseFromSlice(std.json.Value, allocator, rename_response, .{});
    defer rename.deinit();
    const changes = rename.value.object.get("result").?.object.get("changes").?.object;
    const a_edits = changes.get("file:///a.css").?.array.items;
    const b_edits = changes.get("file:///b.css").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), a_edits.len);
    try std.testing.expectEqual(@as(usize, 1), b_edits.len);
    for (a_edits) |edit| {
        try std.testing.expectEqualStrings(
            "--renamed\\a name",
            edit.object.get("newText").?.string,
        );
    }
    try std.testing.expectEqualStrings(
        "--renamed\\a name",
        b_edits[0].object.get("newText").?.string,
    );

    try expectJsonRpcError(
        &server,
        \\{"jsonrpc":"2.0","id":34,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"newName":"theme"}}
    ,
        -32602,
    );
    try expectJsonRpcError(
        &server,
        \\{"jsonrpc":"2.0","id":35,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":2,"character":13},"newName":"none"}}
    ,
        -32602,
    );
    try expectJsonRpcError(
        &server,
        \\{"jsonrpc":"2.0","id":36,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20}}}
    ,
        -32602,
    );
    try expectJsonRpcError(
        &server,
        \\{"jsonrpc":"2.0","id":361,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"newName":"--bad\u0000"}}
    ,
        -32602,
    );

    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.css","version":2},"contentChanges":[{"text":":root { --other: red; }\n.new { pad }"}]}}
    );
    try std.testing.expect(server.documents.get("file:///a.css").?.index == null);

    const refreshed_symbols_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":37,"method":"workspace/symbol","params":{"query":"theme"}}
    );
    defer allocator.free(refreshed_symbols_response);
    var refreshed_symbols = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        refreshed_symbols_response,
        .{},
    );
    defer refreshed_symbols.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        refreshed_symbols.value.object.get("result").?.array.items.len,
    );

    const refreshed_completion_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":38,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":10}}}
    );
    defer allocator.free(refreshed_completion_response);
    var refreshed_completion = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        refreshed_completion_response,
        .{},
    );
    defer refreshed_completion.deinit();
    const refreshed_items = refreshed_completion.value.object
        .get("result").?.object.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), refreshed_items.len);
    try std.testing.expectEqualStrings(
        "padding",
        refreshed_items[0].object.get("label").?.string,
    );
    try expectJsonRange(
        refreshed_items[0].object.get("textEdit").?.object.get("range").?,
        1,
        7,
        1,
        10,
    );

    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///b.css"}}}
    );
    const closed_workspace_response = try server.handleRequest(
        \\{"jsonrpc":"2.0","id":39,"method":"workspace/symbol","params":{"query":"hero"}}
    );
    defer allocator.free(closed_workspace_response);
    var closed_workspace = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        closed_workspace_response,
        .{},
    );
    defer closed_workspace.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        closed_workspace.value.object.get("result").?.array.items.len,
    );
}

test "LSP pull diagnostics expose recoverable compiler diagnostics" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    const open =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///recover.css","languageId":"css","version":1,"text":".a{broken; color:\"oops\n} .b{also}"}}}
    ;
    try expectNoResponse(&server, open);

    const request =
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///recover.css"},"identifier":"zigcss","previousResultId":"old"}}
    ;
    const response = try server.handleRequest(request);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("full", result.get("kind").?.string);
    const items = result.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    const expected = [_]struct {
        code: []const u8,
        message: []const u8,
        start_line: i64,
        start_character: i64,
        end_line: i64,
        end_character: i64,
    }{
        .{
            .code = "CSS0005",
            .message = "unescaped newline terminated the CSS string",
            .start_line = 0,
            .start_character = 17,
            .end_line = 0,
            .end_character = 22,
        },
        .{
            .code = "CSS0007",
            .message = "declaration is missing ':'",
            .start_line = 0,
            .start_character = 3,
            .end_line = 0,
            .end_character = 9,
        },
        .{
            .code = "CSS0007",
            .message = "declaration is missing ':'",
            .start_line = 1,
            .start_character = 5,
            .end_line = 1,
            .end_character = 9,
        },
    };
    for (items, expected) |item_value, target| {
        const item = item_value.object;
        try std.testing.expectEqualStrings(target.code, item.get("code").?.string);
        try std.testing.expectEqualStrings(target.message, item.get("message").?.string);
        try std.testing.expectEqualStrings("zigcss", item.get("source").?.string);
        try std.testing.expectEqual(@as(i64, 1), item.get("severity").?.integer);
        try expectJsonRange(
            item.get("range").?,
            target.start_line,
            target.start_character,
            target.end_line,
            target.end_character,
        );
    }

    const legacy_request =
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///recover.css"}}}
    ;
    const legacy_response = try server.handleRequest(legacy_request);
    defer allocator.free(legacy_response);
    var legacy = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        legacy_response,
        .{},
    );
    defer legacy.deinit();
    try std.testing.expectEqual(
        @as(i64, -32601),
        legacy.value.object.get("error").?.object.get("code").?.integer,
    );

    try std.testing.expectEqual(@as(i32, 1), LspServer.diagnosticSeverity(.err));
    try std.testing.expectEqual(@as(i32, 2), LspServer.diagnosticSeverity(.warning));
    try std.testing.expectEqual(@as(i32, 3), LspServer.diagnosticSeverity(.note));
    for ([_][]const u8{ "", "\r\n" }) |text| {
        try std.testing.expectEqual(
            LspServer.PositionRange{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 0 },
            },
            try LspServer.firstScalarRange(text),
        );
    }

    const invalid_requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///missing.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///recover.css\"},\"identifier\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///recover.css\"},\"identifier\":\"other\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///recover.css\"},\"previousResultId\":1}}",
    };
    for (invalid_requests) |invalid_request| {
        const invalid_response = try server.handleRequest(invalid_request);
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
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///valid.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".valid{color:red}\"}}}",
    );
    const valid_response = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///valid.css\"}}}",
    );
    defer allocator.free(valid_response);
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        valid_response,
        .{},
    );
    defer valid.deinit();
    const valid_report = valid.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("full", valid_report.get("kind").?.string);
    try std.testing.expectEqual(
        @as(usize, 0),
        valid_report.get("items").?.array.items.len,
    );
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
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":6}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":0}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2},\"context\":{\"includeDeclaration\":true}}}",
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
    try std.testing.expectEqual(
        server.documents.get("file:///versions.css").?.text.len,
        server.workspace_text_bytes,
    );

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
    try std.testing.expectEqual(@as(usize, 0), server.workspace_text_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_uri_bytes);

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
    try std.testing.expectEqual(
        server.documents.get("file:///versions.css").?.text.len,
        server.workspace_text_bytes,
    );
    try std.testing.expectEqual(
        "file:///versions.css".len,
        server.workspace_uri_bytes,
    );
}

test "LSP workspace state and indexed requests enforce resource budgets" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();
    server.limits.max_workspace_documents = 2;
    server.limits.max_workspace_text_bytes = 8;
    server.limits.max_workspace_uri_bytes = "file:///a.css".len;
    server.limits.max_document_uri_bytes = 32;
    server.limits.max_workspace_results = 1;
    server.limits.max_workspace_query_bytes = 3;
    server.limits.max_rename_name_bytes = 2;

    try initializeTestServer(&server);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".a{}\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 1), server.documents.count());
    try std.testing.expectEqual(@as(usize, 4), server.workspace_text_bytes);
    try std.testing.expectEqual("file:///a.css".len, server.workspace_uri_bytes);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///b.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".b{}\"}}}",
    );
    try std.testing.expect(server.documents.get("file:///b.css") == null);
    try std.testing.expectEqual(@as(usize, 4), server.workspace_text_bytes);
    try std.testing.expectEqual("file:///a.css".len, server.workspace_uri_bytes);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\",\"version\":2},\"contentChanges\":[{\"text\":\".oversize{}\"}]}}",
    );
    try std.testing.expectEqual(@as(i32, 1), server.documents.get("file:///a.css").?.version);
    try std.testing.expectEqualStrings(".a{}", server.documents.get("file:///a.css").?.text);
    try std.testing.expectEqual(@as(usize, 4), server.workspace_text_bytes);

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\",\"version\":3},\"contentChanges\":[{\"text\":\".b{}.b{}\"}]}}",
    );
    try std.testing.expectEqual(@as(i32, 3), server.documents.get("file:///a.css").?.version);
    try std.testing.expectEqual(@as(usize, 8), server.workspace_text_bytes);

    try expectJsonRpcError(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"bbbb\"}}",
        -32602,
    );
    try expectJsonRpcError(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"b\"}}",
        -32803,
    );
    try std.testing.expect(server.documents.get("file:///a.css").?.index != null);
    try std.testing.expect(server.workspace_index_bytes > 0);
    server.limits.max_editor_response_bytes = 1;
    try expectJsonRpcError(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":411,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"}}}",
        -32803,
    );
    server.limits.max_editor_response_bytes = 16 * 1024 * 1024;
    try expectJsonRpcError(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"},\"position\":{\"line\":0,\"character\":1},\"newName\":\"long\"}}",
        -32602,
    );

    const matcher = try LspServer.WorkspaceQueryMatcher.init("aab", 3);
    try std.testing.expect(matcher.contains("xxAAAByy"));
    try std.testing.expect(!matcher.contains("aaaaac"));

    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 0), server.workspace_text_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_uri_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);

    server.limits.max_workspace_index_bytes = 1;
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\",\"languageId\":\"css\",\"version\":4,\"text\":\".a{}\"}}}",
    );
    try expectJsonRpcError(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"}}}",
        -32803,
    );
    try std.testing.expect(server.documents.get("file:///a.css").?.index == null);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"}}}",
    );

    server.limits.max_workspace_documents = 1;
    server.limits.max_workspace_uri_bytes = 100;
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\",\"languageId\":\"css\",\"version\":4,\"text\":\".a{}\"}}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///b.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".b{}\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 1), server.documents.count());
    try std.testing.expect(server.documents.get("file:///b.css") == null);
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.css\"}}}",
    );
    try expectNoResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///this-uri-is-definitely-too-long.css\",\"languageId\":\"css\",\"version\":1,\"text\":\".x{}\"}}}",
    );
    try std.testing.expectEqual(@as(usize, 0), server.documents.count());
    try std.testing.expectEqual(@as(usize, 0), server.workspace_text_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_uri_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);
}

test "LSP repeated Unicode index lifecycle is balanced and leak-free" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();
    try initializeTestServer(&server);

    const open =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///stress.css","languageId":"css","version":1,"text":":root{--色:red}.使用{color:var(--色)}@keyframes 回転{to{opacity:1}}"}}}
    ;
    const first_symbols =
        \\{"jsonrpc":"2.0","id":50,"method":"workspace/symbol","params":{"query":"使用"}}
    ;
    const change =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///stress.css","version":2},"contentChanges":[{"text":":root{--色:blue}.使用{background:var(--色);animation-name:回転}@keyframes 回転{to{opacity:0}}"}]}}
    ;
    const second_symbols =
        \\{"jsonrpc":"2.0","id":51,"method":"workspace/symbol","params":{"query":"回転"}}
    ;
    const close =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///stress.css"}}}
    ;

    for (0..64) |_| {
        try expectNoResponse(&server, open);
        {
            const response = try server.handleRequest(first_symbols);
            defer allocator.free(response);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqual(
                @as(usize, 1),
                parsed.value.object.get("result").?.array.items.len,
            );
        }
        try std.testing.expect(server.documents.get("file:///stress.css").?.index != null);
        try std.testing.expect(server.workspace_index_bytes > 0);

        try expectNoResponse(&server, change);
        try std.testing.expect(server.documents.get("file:///stress.css").?.index == null);
        try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);
        {
            const response = try server.handleRequest(second_symbols);
            defer allocator.free(response);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqual(
                @as(usize, 1),
                parsed.value.object.get("result").?.array.items.len,
            );
        }

        try expectNoResponse(&server, close);
        try std.testing.expectEqual(@as(usize, 0), server.documents.count());
        try std.testing.expectEqual(@as(usize, 0), server.workspace_text_bytes);
        try std.testing.expectEqual(@as(usize, 0), server.workspace_uri_bytes);
        try std.testing.expectEqual(@as(usize, 0), server.workspace_index_bytes);
    }
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

fn exerciseLspEditorAllocationFailures(allocator: std.mem.Allocator) !void {
    var server = LspServer.init(allocator);
    defer server.deinit();

    try initializeTestServer(&server);
    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.css","languageId":"css","version":1,"text":".hero { color: var(--theme); animation-name: pulse; }\n.card { color: blue; }"}}}
    );
    try expectNoResponse(&server,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.css","languageId":"css","version":1,"text":":root { --theme: red; }\n.card { color: var(--theme); }\n@keyframes pulse { to { opacity: 1; } }\n.new { ba }"}}}
    );

    const requests = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":1,"character":10}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.css"},"position":{"line":3,"character":9}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.css"}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"workspace/symbol","params":{"query":"card"}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"context":{"includeDeclaration":true}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///b.css"},"position":{"line":0,"character":20},"newName":"--renamed"}}
        ,
    };
    for (requests) |request| {
        const response = try server.handleRequest(request);
        defer allocator.free(response);
        try std.testing.expect(response.len > 0);
    }
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
        exerciseLspEditorAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLspLifecycleAllocationFailures,
        .{},
    );
}

test "LSP pull diagnostics reject unavailable formats without CSS fallback" {
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
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.scss"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.sass","languageId":"sass","version":1,"text":"$color: red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":4,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.sass"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.less","languageId":"less","version":1,"text":"@color: red;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":6,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.less"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.styl","languageId":"stylus","version":1,"text":"$color = red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":8,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.styl"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///library-only.module.css","languageId":"css","version":1,"text":".card{x:1}"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":10,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///library-only.module.css"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.js","languageId":"javascript","version":1,"text":"const styles = `\\n.card { color: ${theme.color}; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":12,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.css.js"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.ts","languageId":"typescript","version":1,"text":"const styles = `\\n.card { color: red; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":14,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.css.ts"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.postcss","languageId":"postcss","version":1,"text":"@custom-media --narrow (width < 40rem); .card { color: red; }"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":16,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///removed.postcss"}}}
            ,
        },
    };

    for (cases) |case| {
        try expectNoResponse(&server, case.open);
        const response = try server.handleRequest(case.diagnostics);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const report = parsed.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("full", report.get("kind").?.string);
        const items = report.get("items").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), items.len);
        const diagnostic = items[0].object;
        try std.testing.expectEqualStrings(
            unsupported_format_message,
            diagnostic.get("message").?.string,
        );
        try std.testing.expectEqualStrings("CSS0009", diagnostic.get("code").?.string);
        try std.testing.expectEqualStrings("zigcss", diagnostic.get("source").?.string);
        try std.testing.expectEqual(@as(i64, 1), diagnostic.get("severity").?.integer);
    }
}
