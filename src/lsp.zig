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

