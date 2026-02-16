const std = @import("std");
const parser = @import("parser.zig");
const formats = @import("formats.zig");
const error_module = @import("error.zig");
const ast = @import("ast.zig");


pub const LspServer = struct {
    allocator: std.mem.Allocator,
    initialized: bool,
    root_uri: ?[]const u8 = null,
    documents: std.StringHashMap(Document),
    
    const Document = struct {
        uri: []const u8,
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
            self.allocator.free(entry.value_ptr.*.uri);
            self.allocator.free(entry.value_ptr.*.text);
        }
        self.documents.deinit();
        if (self.root_uri) |uri| {
            self.allocator.free(uri);
        }
    }
    
    pub fn handleRequest(self: *LspServer, request: []const u8) ![]const u8 {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const temp_allocator = gpa.allocator();
        
        var json_tree = try std.json.parseFromSlice(
            std.json.Value,
            temp_allocator,
            request,
            .{},
        );
        defer json_tree.deinit();
        
        const root = json_tree.value;
        const method = if (root.object.get("method")) |m| m.string else return error.InvalidRequest;
        const id = root.object.get("id");
        
        var response = std.ArrayList(u8).init(self.allocator);
        errdefer response.deinit(self.allocator);
        
        try response.writer(self.allocator).print("{{\"jsonrpc\":\"2.0\"", .{});
        
        if (id) |request_id| {
            try response.writer(self.allocator).print(",\"id\":", .{});
            try self.writeJsonValue(response.writer(self.allocator), request_id);
        }
        
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(&response, root);
        } else if (std.mem.eql(u8, method, "initialized")) {
            try response.writer(self.allocator).print(",\"result\":{{}}", .{});
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/diagnostics")) {
            try self.handleDiagnostics(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(&response, root);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.handleRename(&response, root);
        } else {
            try response.writer(self.allocator).print(",\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}", .{});
        }
        
        try response.append(self.allocator, '}');
        return try response.toOwnedSlice(self.allocator);
    }
    
    fn writeJsonValue(self: *LspServer, writer: anytype, value: std.json.Value) !void {
        switch (value) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{}", .{f}),
            .bool => |b| try writer.print("{}", .{b}),
            .null => try writer.writeAll("null"),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(",");
                    try self.writeJsonValue(writer, item);
                }
                try writer.writeAll("]");
            },
            .object => |obj| {
                try writer.writeAll("{");
                var first = true;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.print("\"{s}\":", .{entry.key_ptr.*});
                    try self.writeJsonValue(writer, entry.value_ptr.*);
                }
                try writer.writeAll("}");
            },
        }
    }
    
    fn handleInitialize(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        if (params.object.get("rootUri")) |root_uri_val| {
            if (root_uri_val.string.len > 0) {
                self.root_uri = try self.allocator.dupe(u8, root_uri_val.string);
            }
        }
        
        self.initialized = true;
        
        const capabilities = 
            \\"capabilities":{
            \\  "textDocumentSync":1,
            \\  "hoverProvider":true,
            \\  "completionProvider":{"triggerCharacters":[" ",":","-"]},
            \\  "diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false}
            \\}
        ;
        
        try response.writer(self.allocator).print(",\"result\":{{{s}}}", .{capabilities});
    }
    
    fn handleDidOpen(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const text = text_document.object.get("text") orelse return error.InvalidRequest;
        const version = if (text_document.object.get("version")) |v| v.integer else 0;
        
        const uri_copy = try self.allocator.dupe(u8, uri.string);
        errdefer self.allocator.free(uri_copy);
        const text_copy = try self.allocator.dupe(u8, text.string);
        errdefer self.allocator.free(text_copy);
        
        try self.documents.put(uri_copy, .{
            .uri = uri_copy,
            .version = @intCast(version),
            .text = text_copy,
        });
        
        try response.writer(self.allocator).print(",\"result\":{{}}", .{});
    }
    
    fn handleDidChange(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const changes = params.object.get("contentChanges") orelse return error.InvalidRequest;
        const version = if (text_document.object.get("version")) |v| v.integer else 0;
        
        if (changes.array.items.len > 0) {
            const change = changes.array.items[changes.array.items.len - 1];
            const text = change.object.get("text") orelse return error.InvalidRequest;
            
            if (self.documents.getPtr(uri.string)) |doc| {
                self.allocator.free(doc.text);
                doc.text = try self.allocator.dupe(u8, text.string);
                doc.version = @intCast(version);
            } else {
                const uri_copy = try self.allocator.dupe(u8, uri.string);
                errdefer self.allocator.free(uri_copy);
                const text_copy = try self.allocator.dupe(u8, text.string);
                errdefer self.allocator.free(text_copy);
                
                try self.documents.put(uri_copy, .{
                    .uri = uri_copy,
                    .version = @intCast(version),
                    .text = text_copy,
                });
            }
        }
        
        try response.writer(self.allocator).print(",\"result\":{{}}", .{});
    }
    
    fn handleDiagnostics(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"result\":{{\"items\":[]}}", .{});
            return;
        };
        
        var diagnostics = std.ArrayList(u8).init(self.allocator);
        defer diagnostics.deinit(self.allocator);
        try diagnostics.append(self.allocator, '[');
        
        var first = true;
        
        const format = formats.detectFormat(uri.string);
        if (format == .css) {
            var css_parser = parser.Parser.init(self.allocator, doc.text);
            defer if (css_parser.owns_pool) {
                css_parser.string_pool.deinit();
                self.allocator.destroy(css_parser.string_pool);
            };
            
            const result = css_parser.parseWithErrorInfo();
            switch (result) {
                .success => |_| {},
                .parse_error => |parse_error| {
                    if (!first) try diagnostics.append(self.allocator, ',');
                    first = false;
                    
                    const line = parse_error.line;
                    const column = parse_error.column;
                    const message = error_module.ParseError.getMessage(parse_error.kind);
                    
                    const col: i64 = @intCast(column);
                    const col_char = if (col - 1 > 0) col - 1 else 0;
                    try diagnostics.writer(self.allocator).print(
                        "{{\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"severity\":1,\"message\":\"{s}\",\"source\":\"zcss\"}}",
                        .{ line - 1, col_char, line - 1, column, message });
                },
            }
        } else {
            const parser_trait = formats.getParser(format);
            parser_trait.parseFn(self.allocator, doc.text) catch |err| {
                if (!first) try diagnostics.append(self.allocator, ',');
                first = false;
                
                const error_msg = @errorName(err);
                try diagnostics.writer(self.allocator).print(
                    \\{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":1}}},"severity":1,"message":"{s}","source":"zcss"}}
                , .{error_msg});
            };
        }
        
        try diagnostics.append(self.allocator, ']');
        const diagnostics_str = try diagnostics.toOwnedSlice(self.allocator);
        defer self.allocator.free(diagnostics_str);
        
        try response.writer(self.allocator).print(",\"result\":{{\"items\":{s}}}", .{diagnostics_str});
    }
    
    fn handleHover(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const position = params.object.get("position") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"result\":null", .{});
            return;
        };
        
        const line = if (position.object.get("line")) |l| l.integer else 0;
        const character = if (position.object.get("character")) |c| c.integer else 0;
        
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
                    try response.writer(self.allocator).print(
                        \\,"result":{{"contents":{{"kind":"markdown","value":"{s}"}},"range":{{"start":{{"line":{},"character":{}}},"end":{{"line":{},"character":{}}}}}}
                    , .{ info, line, word_start, line, word_end });
                    return;
                }
            }
        }
        
        try response.writer(self.allocator).print(",\"result\":null", .{});
    }
    
    fn handleCompletion(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const position = params.object.get("position") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"result\":{{\"items\":[]}}", .{});
            return;
        };
        
        const line = if (position.object.get("line")) |l| l.integer else 0;
        const character = if (position.object.get("character")) |c| c.integer else 0;
        
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
        
        var items = std.ArrayList(u8).init(self.allocator);
        defer items.deinit(self.allocator);
        try items.append(self.allocator, '[');
        
        var first = true;
        for (COMMON_CSS_PROPERTIES) |prop| {
            if (std.mem.startsWith(u8, prop, line_text[0..@min(char_pos, line_text.len)])) {
                if (!first) try items.append(self.allocator, ',');
                first = false;
                try items.writer(self.allocator).print(
                    \\{{"label":"{s}","kind":10,"detail":"CSS Property","insertText":"{s}"}}
                , .{ prop, prop });
            }
        }
        
        try items.append(self.allocator, ']');
        const items_str = try items.toOwnedSlice(self.allocator);
        defer self.allocator.free(items_str);
        
        try response.writer(self.allocator).print(",\"result\":{{\"items\":{s}}}", .{items_str});
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
    
    fn handleDefinition(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const position = params.object.get("position") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"result\":null", .{});
            return;
        };
        
        const line = if (position.object.get("line")) |l| l.integer else 0;
        const character = if (position.object.get("character")) |c| c.integer else 0;
        
        const pos = self.getPosition(doc.text, line, character);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try response.writer(self.allocator).print(",\"result\":null", .{});
            return;
        };
        
        const definition_pos = self.findDefinition(doc.text, symbol) orelse {
            try response.writer(self.allocator).print(",\"result\":null", .{});
            return;
        };
        
        const def_line_col = self.getLineColumn(doc.text, definition_pos);
        try response.writer(self.allocator).print(
            ",\"result\":{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}}}",
            .{ uri.string, def_line_col.line, def_line_col.column, def_line_col.line, def_line_col.column + symbol.len }
        );
    }
    
    fn handleReferences(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const position = params.object.get("position") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"result\":[]", .{});
            return;
        };
        
        const line = if (position.object.get("line")) |l| l.integer else 0;
        const character = if (position.object.get("character")) |c| c.integer else 0;
        
        const pos = self.getPosition(doc.text, line, character);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try response.writer(self.allocator).print(",\"result\":[]", .{});
            return;
        };
        
        var locations = std.ArrayList(u8).init(self.allocator);
        defer locations.deinit(self.allocator);
        try locations.append(self.allocator, '[');
        
        var first = true;
        var search_pos: usize = 0;
        while (self.findNextReference(doc.text, symbol, &search_pos)) |ref_pos| {
            if (!first) try locations.append(self.allocator, ',');
            first = false;
            
            const ref_line_col = self.getLineColumn(doc.text, ref_pos);
            try locations.writer(self.allocator).print(
                "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}}}",
                .{ uri.string, ref_line_col.line, ref_line_col.column, ref_line_col.line, ref_line_col.column + symbol.len }
            );
        }
        
        try locations.append(self.allocator, ']');
        const locations_str = try locations.toOwnedSlice(self.allocator);
        defer self.allocator.free(locations_str);
        
        try response.writer(self.allocator).print(",\"result\":{s}", .{locations_str});
    }
    
    fn handleRename(self: *LspServer, response: *std.ArrayList(u8), root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidRequest;
        const text_document = params.object.get("textDocument") orelse return error.InvalidRequest;
        const uri = text_document.object.get("uri") orelse return error.InvalidRequest;
        const position = params.object.get("position") orelse return error.InvalidRequest;
        const new_name = params.object.get("newName") orelse return error.InvalidRequest;
        
        const doc = self.documents.get(uri.string) orelse {
            try response.writer(self.allocator).print(",\"error\":{{\"code\":-32602,\"message\":\"Document not found\"}}", .{});
            return;
        };
        
        const line = if (position.object.get("line")) |l| l.integer else 0;
        const character = if (position.object.get("character")) |c| c.integer else 0;
        
        const pos = self.getPosition(doc.text, line, character);
        const symbol = self.getSymbolAtPosition(doc.text, pos) orelse {
            try response.writer(self.allocator).print(",\"error\":{{\"code\":-32602,\"message\":\"Symbol not found\"}}", .{});
            return;
        };
        
        var changes = std.ArrayList(u8).init(self.allocator);
        defer changes.deinit(self.allocator);
        try changes.writer(self.allocator).print("{{\"{s}\":[", .{uri.string});
        
        var first = true;
        var search_pos: usize = 0;
        while (self.findNextReference(doc.text, symbol, &search_pos)) |ref_pos| {
            if (!first) try changes.append(self.allocator, ',');
            first = false;
            
            const ref_line_col = self.getLineColumn(doc.text, ref_pos);
            try changes.writer(self.allocator).print(
                "{{\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"newText\":\"{s}\"}}",
                .{ ref_line_col.line, ref_line_col.column, ref_line_col.line, ref_line_col.column + symbol.len, new_name.string }
            );
        }
        
        try changes.append(self.allocator, ']');
        try changes.append(self.allocator, '}');
        const changes_str = try changes.toOwnedSlice(self.allocator);
        defer self.allocator.free(changes_str);
        
        try response.writer(self.allocator).print(",\"result\":{{\"changes\":{s}}}", .{changes_str});
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

