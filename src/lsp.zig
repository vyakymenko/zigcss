const std = @import("std");
const parser = @import("parser.zig");
const formats = @import("formats.zig");
const error_module = @import("error.zig");

const unsupported_format_message = "Unsupported or removed stylesheet format";

pub const LspServer = struct {
    allocator: std.mem.Allocator,
    initialized: bool,
    root_uri: ?[]const u8 = null,
    documents: std.StringHashMap(Document),

    // The hash-map key is the sole owned URI copy.
    const Document = struct {
        version: i32,
        text: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) LspServer {
        return .{
            .allocator = allocator,
            .initialized = false,
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

    pub fn handleRequest(self: *LspServer, request: []const u8) ![]const u8 {
        return self.handleRequestInner(request) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
    }

    fn handleRequestInner(self: *LspServer, request: []const u8) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            request,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.writeErrorResponse(null, -32700, "Parse error"),
        };

        const object = switch (root) {
            .object => |value| value,
            else => return self.writeErrorResponse(null, -32600, "Invalid Request"),
        };
        const version = object.get("jsonrpc") orelse
            return self.writeErrorResponse(null, -32600, "Invalid Request");
        if (version != .string or !std.mem.eql(u8, version.string, "2.0")) {
            return self.writeErrorResponse(null, -32600, "Invalid Request");
        }
        const method_value = object.get("method") orelse
            return self.writeErrorResponse(null, -32600, "Invalid Request");
        const method = switch (method_value) {
            .string => |value| value,
            else => return self.writeErrorResponse(null, -32600, "Invalid Request"),
        };
        const id = object.get("id");
        if (id) |value| {
            if (!isValidRequestId(value)) {
                return self.writeErrorResponse(null, -32600, "Invalid Request");
            }
        }
        return self.writeDispatchResponse(object, method, id);
    }

    fn writeDispatchResponse(
        self: *LspServer,
        root: JsonObject,
        method: []const u8,
        id: ?std.json.Value,
    ) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var json: JsonWriter = .{ .writer = &output.writer };
        try writeResponsePrefix(&json, id);

        self.dispatch(&json, root, method) catch |err| switch (err) {
            error.InvalidParams => try writeErrorField(&json, -32602, "Invalid params"),
            else => return err,
        };
        try json.endObject();
        return try output.toOwnedSlice();
    }

    fn dispatch(
        self: *LspServer,
        json: *JsonWriter,
        root: JsonObject,
        method: []const u8,
    ) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(json, root);
        } else if (std.mem.eql(u8, method, "initialized")) {
            try writeEmptyResult(json);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(json, root);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(json, root);
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

    fn writeEmptyResult(json: *JsonWriter) !void {
        try json.objectField("result");
        try json.beginObject();
        try json.endObject();
    }

    fn writeDiagnostic(
        json: *JsonWriter,
        start_line: i64,
        start_character: i64,
        end_line: i64,
        end_character: i64,
        message: []const u8,
    ) !void {
        try json.write(.{
            .range = .{
                .start = .{ .line = start_line, .character = start_character },
                .end = .{ .line = end_line, .character = end_character },
            },
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

    fn optionalIntegerField(object: JsonObject, name: []const u8, default: i64) !i64 {
        const value = object.get(name) orelse return default;
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
    
    fn handleInitialize(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
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
        
        self.initialized = true;
        
        try json.objectField("result");
        try json.beginObject();
        try json.objectField("capabilities");
        try json.beginObject();
        try json.objectField("textDocumentSync");
        try json.write(@as(i32, 1));
        try json.objectField("hoverProvider");
        try json.write(true);
        try json.objectField("completionProvider");
        try json.beginObject();
        try json.objectField("triggerCharacters");
        try json.write(&[_][]const u8{ " ", ":", "-" });
        try json.endObject();
        try json.objectField("diagnosticProvider");
        try json.beginObject();
        try json.objectField("interFileDependencies");
        try json.write(false);
        try json.objectField("workspaceDiagnostics");
        try json.write(false);
        try json.endObject();
        try json.endObject();
        try json.endObject();
    }
    
    fn handleDidOpen(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const text = try requireStringField(text_document, "text");
        const version = try integerToI32(try optionalIntegerField(text_document, "version", 0));

        {
            const text_copy = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(text_copy);
            if (self.documents.getPtr(uri)) |doc| {
                self.allocator.free(doc.text);
                doc.* = .{ .version = version, .text = text_copy };
            } else {
                const uri_copy = try self.allocator.dupe(u8, uri);
                errdefer self.allocator.free(uri_copy);
                try self.documents.put(uri_copy, .{ .version = version, .text = text_copy });
            }
        }
        try writeEmptyResult(json);
    }

    fn handleDidChange(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const changes = try requireArrayField(params, "contentChanges");
        const version = try integerToI32(try optionalIntegerField(text_document, "version", 0));

        if (changes.len > 0) {
            const change = switch (changes[changes.len - 1]) {
                .object => |value| value,
                else => return error.InvalidParams,
            };
            const text = try requireStringField(change, "text");
            {
                const text_copy = try self.allocator.dupe(u8, text);
                errdefer self.allocator.free(text_copy);
                if (self.documents.getPtr(uri)) |doc| {
                    self.allocator.free(doc.text);
                    doc.* = .{ .version = version, .text = text_copy };
                } else {
                    const uri_copy = try self.allocator.dupe(u8, uri);
                    errdefer self.allocator.free(uri_copy);
                    try self.documents.put(uri_copy, .{ .version = version, .text = text_copy });
                }
            }
        }
        try writeEmptyResult(json);
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
            try writeDiagnostic(json, 0, 0, 0, 1, unsupported_format_message);
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
                    const line = parse_error.line;
                    const column = parse_error.column;
                    const message = error_module.ParseError.getMessage(parse_error.kind);

                    const col: i64 = @intCast(column);
                    const col_char = if (col - 1 > 0) col - 1 else 0;
                    try writeDiagnostic(
                        json,
                        @as(i64, @intCast(line)) - 1,
                        col_char,
                        @as(i64, @intCast(line)) - 1,
                        @intCast(column),
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
        const line = @max(try requireIntegerField(position, "line"), 0);
        const character = @max(try requireIntegerField(position, "character"), 0);

        const doc = self.documents.get(uri) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };
        
        const line_start = blk: {
            var line_num: i64 = 0;
            var i: usize = 0;
            while (i < doc.text.len and line_num < line) {
                if (doc.text[i] == '\n') {
                    line_num += 1;
                }
                i += 1;
            }
            break :blk i;
        };
        
        const line_end = blk: {
            var i = line_start;
            while (i < doc.text.len and doc.text[i] != '\n') {
                i += 1;
            }
            break :blk i;
        };
        
        const line_text = doc.text[line_start..line_end];
        const char_pos: usize = @intCast(if (character > 0) character else 0);
        
        if (char_pos < line_text.len) {
            var word_start = char_pos;
            while (word_start > 0 and (std.ascii.isAlphanumeric(line_text[word_start - 1]) or line_text[word_start - 1] == '-')) {
                word_start -= 1;
            }
            
            var word_end = char_pos;
            while (word_end < line_text.len and (std.ascii.isAlphanumeric(line_text[word_end]) or line_text[word_end] == '-')) {
                word_end += 1;
            }
            
            if (word_end > word_start) {
                const word = line_text[word_start..word_end];
                if (self.getCssPropertyInfo(word)) |info| {
                    try json.objectField("result");
                    try json.write(.{
                        .contents = .{ .kind = "markdown", .value = info },
                        .range = .{
                            .start = .{ .line = line, .character = word_start },
                            .end = .{ .line = line, .character = word_end },
                        },
                    });
                    return;
                }
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
        const line = @max(try requireIntegerField(position, "line"), 0);
        const character = @max(try requireIntegerField(position, "character"), 0);

        try json.objectField("result");
        try json.beginObject();
        try json.objectField("items");
        try json.beginArray();
        const doc = self.documents.get(uri) orelse {
            try json.endArray();
            try json.endObject();
            return;
        };
        
        const line_start = blk: {
            var line_num: i64 = 0;
            var i: usize = 0;
            while (i < doc.text.len and line_num < line) {
                if (doc.text[i] == '\n') {
                    line_num += 1;
                }
                i += 1;
            }
            break :blk i;
        };
        
        const line_end = blk: {
            var i = line_start;
            while (i < doc.text.len and doc.text[i] != '\n') {
                i += 1;
            }
            break :blk i;
        };
        
        const line_text = doc.text[line_start..line_end];
        const char_pos: usize = @intCast(if (character > 0) character else 0);
        
        for (COMMON_CSS_PROPERTIES) |prop| {
            if (std.mem.startsWith(u8, prop, line_text[0..@min(char_pos, line_text.len)])) {
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
        const line = @max(try requireIntegerField(position, "line"), 0);
        const character = @max(try requireIntegerField(position, "character"), 0);

        const doc = self.documents.get(uri) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };
        
        const pos = self.getPosition(doc.text, line, character);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        const definition_pos = self.findDefinition(doc.text, symbol) orelse {
            try json.objectField("result");
            try json.write(null);
            return;
        };

        const def_line_col = self.getLineColumn(doc.text, definition_pos);
        try json.objectField("result");
        try json.write(.{
            .uri = uri,
            .range = .{
                .start = .{ .line = def_line_col.line, .character = def_line_col.column },
                .end = .{
                    .line = def_line_col.line,
                    .character = def_line_col.column + @as(i64, @intCast(symbol.len)),
                },
            },
        });
    }
    
    fn handleReferences(self: *LspServer, json: *JsonWriter, root: JsonObject) !void {
        const params = try requireObjectField(root, "params");
        const text_document = try requireObjectField(params, "textDocument");
        const uri = try requireStringField(text_document, "uri");
        const position = try requireObjectField(params, "position");
        const line = @max(try requireIntegerField(position, "line"), 0);
        const character = @max(try requireIntegerField(position, "character"), 0);

        try json.objectField("result");
        try json.beginArray();
        const doc = self.documents.get(uri) orelse {
            try json.endArray();
            return;
        };

        const pos = self.getPosition(doc.text, line, character);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try json.endArray();
            return;
        };

        var search_pos: usize = 0;
        while (self.findNextReference(doc.text, symbol, &search_pos)) |ref_pos| {
            const ref_line_col = self.getLineColumn(doc.text, ref_pos);
            try json.write(.{
                .uri = uri,
                .range = .{
                    .start = .{ .line = ref_line_col.line, .character = ref_line_col.column },
                    .end = .{
                        .line = ref_line_col.line,
                        .character = ref_line_col.column + @as(i64, @intCast(symbol.len)),
                    },
                },
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
        const line = @max(try requireIntegerField(position, "line"), 0);
        const character = @max(try requireIntegerField(position, "character"), 0);

        const doc = self.documents.get(uri) orelse {
            try writeErrorField(json, -32602, "Document not found");
            return;
        };

        const pos = self.getPosition(doc.text, line, character);
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
        while (self.findNextReference(doc.text, symbol, &search_pos)) |ref_pos| {
            const ref_line_col = self.getLineColumn(doc.text, ref_pos);
            try json.write(.{
                .range = .{
                    .start = .{ .line = ref_line_col.line, .character = ref_line_col.column },
                    .end = .{
                        .line = ref_line_col.line,
                        .character = ref_line_col.column + @as(i64, @intCast(symbol.len)),
                    },
                },
                .newText = new_name,
            });
        }

        try json.endArray();
        try json.endObject();
        try json.endObject();
    }
    
    fn getPosition(self: *LspServer, text: []const u8, line: i64, character: i64) usize {
        _ = self;
        var line_num: i64 = 0;
        var i: usize = 0;
        while (i < text.len and line_num < line) {
            if (text[i] == '\n') {
                line_num += 1;
            }
            i += 1;
        }
        const char_usize: usize = @intCast(@max(character, 0));
        return @min(i + char_usize, text.len);
    }
    
    fn getLineColumn(self: *LspServer, text: []const u8, pos: usize) struct { line: i64, column: i64 } {
        _ = self;
        var line: i64 = 0;
        var column: i64 = 0;
        var i: usize = 0;
        while (i < pos and i < text.len) {
            if (text[i] == '\n') {
                line += 1;
                column = 0;
            } else {
                column += 1;
            }
            i += 1;
        }
        return .{ .line = line, .column = column };
    }
    
    fn getSymbolAtPosition(self: *LspServer, text: []const u8, pos: usize) ?[]const u8 {
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
            return text[start..end];
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

test "LSP server initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();

    try std.testing.expect(!server.initialized);
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

    try std.testing.expect(server.initialized);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "capabilities"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "textDocumentSync"));
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

    const opened = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///a\\\"b.css\",\"version\":1,\"text\":\".foo{color:red}.foo{}\"}}}",
    );
    allocator.free(opened);

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

test "LSP serializes every handler response as complete JSON" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":null,\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\",\"version\":1,\"text\":\".foo{color:red}.foo{}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\",\"version\":2},\"contentChanges\":[{\"text\":\".foo{color:blue}.foo{}\"}]}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/diagnostics\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":6}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":0}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file:///handlers.css\"},\"position\":{\"line\":0,\"character\":2},\"newName\":\"bar\"}}",
    };

    for (requests, 1..) |request, id| {
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

test "LSP document ownership survives response serialization failure" {
    const allocator = std.testing.allocator;
    var server = LspServer.init(allocator);
    defer server.deinit();

    var request = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"params\":{\"textDocument\":{\"uri\":\"file:///ownership.css\",\"version\":1,\"text\":\".a{}\"}}}",
        .{},
    );
    defer request.deinit();

    var output_buffer: [1]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var json: std.json.Stringify = .{ .writer = &output };
    try json.beginObject();
    try std.testing.expectError(
        error.WriteFailed,
        server.handleDidOpen(&json, request.value.object),
    );

    const document = server.documents.get("file:///ownership.css").?;
    try std.testing.expectEqualStrings(".a{}", document.text);

    var change_request = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"params\":{\"textDocument\":{\"uri\":\"file:///ownership.css\",\"version\":2},\"contentChanges\":[{\"text\":\".b{}\"}]}}",
        .{},
    );
    defer change_request.deinit();

    output = std.Io.Writer.fixed(&output_buffer);
    json = .{ .writer = &output };
    try json.beginObject();
    try std.testing.expectError(
        error.WriteFailed,
        server.handleDidChange(&json, change_request.value.object),
    );
    const changed_document = server.documents.get("file:///ownership.css").?;
    try std.testing.expectEqual(@as(i32, 2), changed_document.version);
    try std.testing.expectEqualStrings(".b{}", changed_document.text);
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

    const opened = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///allocation.css\",\"version\":1,\"text\":\".a{color:red}\"}}}",
    );
    allocator.free(opened);

    const changed = try server.handleRequest(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///allocation.css\",\"version\":2},\"contentChanges\":[{\"text\":\".a{color:blue}\"}]}}",
    );
    allocator.free(changed);
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
}

test "LSP diagnostics reject unavailable formats without CSS fallback" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = LspServer.init(allocator);
    defer server.deinit();

    const cases = [_]struct {
        open: []const u8,
        diagnostics: []const u8,
    }{
        .{
            .open =
            \\{"jsonrpc":"2.0","id":1,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.scss","version":1,"text":"$color: red;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.scss"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.sass","version":1,"text":"$color: red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":4,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.sass"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":5,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.less","version":1,"text":"@color: red;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":6,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.less"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":7,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.styl","version":1,"text":"$color = red"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":8,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.styl"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":9,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///library-only.module.css","version":1,"text":".card{x:1}"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":10,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///library-only.module.css"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":11,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.js","version":1,"text":"const styles = `\\n.card { color: ${theme.color}; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":12,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.css.js"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":13,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.css.ts","version":1,"text":"const styles = `\\n.card { color: red; }\\n`;"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":14,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.css.ts"}}}
            ,
        },
        .{
            .open =
            \\{"jsonrpc":"2.0","id":15,"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///removed.postcss","version":1,"text":"@custom-media --narrow (width < 40rem); .card { color: red; }"}}}
            ,
            .diagnostics =
            \\{"jsonrpc":"2.0","id":16,"method":"textDocument/diagnostics","params":{"textDocument":{"uri":"file:///removed.postcss"}}}
            ,
        },
    };

    for (cases) |case| {
        const opened = try server.handleRequest(case.open);
        defer allocator.free(opened);
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
