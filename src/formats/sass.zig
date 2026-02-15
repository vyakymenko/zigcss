const std = @import("std");
const ast = @import("../ast.zig");
const css_parser = @import("../parser.zig");

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    variables: std.StringHashMap([]const u8),
    lines: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, input: []const u8) !Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .lines = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn parse(self: *Parser) !ast.Stylesheet {
        try self.parseLines();
        defer {
            for (self.lines.items) |line| {
                self.allocator.free(line);
            }
            self.lines.deinit(self.allocator);
        }

        try self.parseVariablesFromLines();

        const css_content = try self.convertToCSS();
        defer self.allocator.free(css_content);

        const processed_css = try self.substituteVariables(css_content);
        defer self.allocator.free(processed_css);

        var css_p = css_parser.Parser.init(self.allocator, processed_css);
        const stylesheet = try css_p.parse();
        return stylesheet;
    }

    fn parseVariablesFromLines(self: *Parser) !void {
        for (self.lines.items) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '$') {
                var i: usize = 1;
                while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '-' or trimmed[i] == '_')) {
                    i += 1;
                }
                
                if (i < trimmed.len and trimmed[i] == ':') {
                    const name = trimmed[1..i];
                    i += 1;
                    while (i < trimmed.len and std.ascii.isWhitespace(trimmed[i])) {
                        i += 1;
                    }
                    const value = std.mem.trim(u8, trimmed[i..], " \t");
                    
                    const name_copy = try self.allocator.dupe(u8, name);
                    const value_copy = try self.allocator.dupe(u8, value);
                    try self.variables.put(name_copy, value_copy);
                }
            }
        }
    }

    fn parseLines(self: *Parser) !void {
        var line_start: usize = 0;
        var i: usize = 0;

        while (i < self.input.len) {
            if (self.input[i] == '\n' or i == self.input.len - 1) {
                const line_end = if (i == self.input.len - 1) i + 1 else i;
                if (line_end > line_start) {
                    var line = self.input[line_start..line_end];
                    line = std.mem.trimRight(u8, line, "\r\n");
                    if (line.len > 0) {
                        const line_copy = try self.allocator.dupe(u8, line);
                        try self.lines.append(self.allocator, line_copy);
                    }
                }
                line_start = i + 1;
            }
            i += 1;
        }
    }

    fn convertToCSS(self: *Parser) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, self.input.len * 2);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var indent_stack = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer indent_stack.deinit(self.allocator);

        while (i < self.lines.items.len) {
            const line = self.lines.items[i];
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            
            if (trimmed.len == 0) {
                i += 1;
                continue;
            }

            const indent = line.len - trimmed.len;

            while (indent_stack.items.len > 0) {
                const prev_indent = self.getIndentForLine(i - 1);
                if (prev_indent >= indent) {
                    _ = indent_stack.pop();
                    try result.append(self.allocator, '}');
                    try result.append(self.allocator, '\n');
                } else {
                    break;
                }
            }

            if (trimmed[0] == '$') {
                i += 1;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "@")) {
                try result.appendSlice(self.allocator, trimmed);
                try result.append(self.allocator, '\n');
                i += 1;
                continue;
            }

            if (self.isSelector(trimmed)) {
                if (indent_stack.items.len > 0) {
                    const parent_selector = indent_stack.items[indent_stack.items.len - 1];
                    try result.appendSlice(self.allocator, parent_selector);
                    try result.append(self.allocator, ' ');
                }
                try result.appendSlice(self.allocator, trimmed);
                try result.append(self.allocator, ' ');
                try result.append(self.allocator, '{');
                try result.append(self.allocator, '\n');
                const selector_copy = try self.allocator.dupe(u8, trimmed);
                try indent_stack.append(self.allocator, selector_copy);
            } else if (self.isProperty(trimmed)) {
                try result.appendSlice(self.allocator, "  ");
                const property_line = try self.processVariablesInLine(trimmed);
                defer self.allocator.free(property_line);
                try result.appendSlice(self.allocator, property_line);
                try result.append(self.allocator, ';');
                try result.append(self.allocator, '\n');
            }

            i += 1;
        }

        while (indent_stack.items.len > 0) {
            _ = indent_stack.pop();
            try result.append(self.allocator, '}');
            if (indent_stack.items.len > 0) {
                try result.append(self.allocator, '\n');
            }
        }

        for (indent_stack.items) |selector| {
            self.allocator.free(selector);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn getIndentForLine(self: *Parser, line_index: usize) usize {
        if (line_index >= self.lines.items.len) {
            return 0;
        }
        const line = self.lines.items[line_index];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        return line.len - trimmed.len;
    }

    fn isSelector(self: *Parser, line: []const u8) bool {
        _ = self;
        if (line.len == 0) return false;
        
        const first = line[0];
        if (first == '.' or first == '#' or first == '&' or std.ascii.isAlphabetic(first)) {
            if (std.mem.indexOf(u8, line, ":") == null) {
                return true;
            }
        }
        return false;
    }

    fn isProperty(self: *Parser, line: []const u8) bool {
        _ = self;
        if (std.mem.indexOf(u8, line, ":") != null) {
            return true;
        }
        return false;
    }

    fn isLastLine(self: *Parser, index: usize) bool {
        return index == self.lines.items.len - 1;
    }

    fn processVariablesInLine(self: *Parser, line: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, line.len * 2);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '$' and i + 1 < line.len) {
                const var_start = i + 1;
                var var_end = var_start;

                if (std.ascii.isAlphabetic(line[var_end]) or line[var_end] == '-') {
                    while (var_end < line.len) {
                        const ch = line[var_end];
                        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                            var_end += 1;
                        } else {
                            break;
                        }
                    }

                    if (var_end > var_start) {
                        const var_name = line[var_start..var_end];
                        if (self.variables.get(var_name)) |value| {
                            try result.appendSlice(self.allocator, value);
                            i = var_end;
                            continue;
                        }
                    }
                }
            }

            try result.append(self.allocator, line[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn substituteVariables(self: *Parser, input: []const u8) ![]const u8 {

        var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '$' and i + 1 < input.len) {
                const var_start = i + 1;
                var var_end = var_start;

                if (std.ascii.isAlphabetic(input[var_end]) or input[var_end] == '-') {
                    while (var_end < input.len) {
                        const ch = input[var_end];
                        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                            var_end += 1;
                        } else {
                            break;
                        }
                    }

                    if (var_end > var_start) {
                        const var_name = input[var_start..var_end];
                        if (self.variables.get(var_name)) |value| {
                            try result.appendSlice(self.allocator, value);
                            i = var_end;
                            continue;
                        }
                    }
                }
            }

            try result.append(self.allocator, input[i]);
            i += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn parseVariable(self: *Parser) !void {
        if (self.peek() != '$') {
            return error.ExpectedDollarSign;
        }
        self.advance();

        const name_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == name_start) {
            return error.InvalidVariableName;
        }

        const name = self.input[name_start..self.pos];
        self.skipWhitespace();

        if (self.peek() != ':') {
            return error.ExpectedColon;
        }
        self.advance();
        self.skipWhitespace();

        const value_start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.peek();
            if (ch == '\n' or ch == '\r') {
                break;
            }
            self.advance();
        }

        var value = self.input[value_start..self.pos];
        value = std.mem.trim(u8, value, " \t");
        const value_copy = try self.allocator.dupe(u8, value);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.variables.put(name_copy, value_copy);

        if (self.peek() == '\n' or self.peek() == '\r') {
            self.advance();
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (std.ascii.isWhitespace(ch)) {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn peek(self: *const Parser) u8 {
        if (self.pos >= self.input.len) {
            return 0;
        }
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            self.pos += 1;
        }
    }

    pub fn deinit(self: *Parser) void {
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();
    }
};

test "parse SASS indented syntax" {
    const sass = ".container\n  color: red\n  padding: 20px\n";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = try Parser.init(allocator, sass);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len == 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len == 2);
}

test "parse SASS with variables" {
    const sass = "$primary-color: red\n.container\n  color: $primary-color\n";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = try Parser.init(allocator, sass);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 1);
    try std.testing.expect(std.mem.eql(u8, rule.style.declarations.items[0].value, "red"));
}

test "parse SASS with nesting" {
    const sass = ".container\n  color: red\n  .nested\n    background: blue\n";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var p = try Parser.init(allocator, sass);
    defer p.deinit();
    var stylesheet = try p.parse();
    defer stylesheet.deinit();

    try std.testing.expect(stylesheet.rules.items.len >= 1);
}
