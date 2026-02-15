const std = @import("std");
const ast = @import("ast.zig");

pub const Format = enum {
    css,
    scss,
    sass,
    less,
    css_modules,
    css_in_js,
};

pub fn detectFormat(filename: []const u8) Format {
    if (std.mem.endsWith(u8, filename, ".scss")) {
        return .scss;
    } else if (std.mem.endsWith(u8, filename, ".sass")) {
        return .sass;
    } else if (std.mem.endsWith(u8, filename, ".less")) {
        return .less;
    } else if (std.mem.endsWith(u8, filename, ".module.css")) {
        return .css_modules;
    } else if (std.mem.endsWith(u8, filename, ".css.js") or std.mem.endsWith(u8, filename, ".css.ts")) {
        return .css_in_js;
    } else {
        return .css;
    }
}

pub const ParserTrait = struct {
    parseFn: *const fn (allocator: std.mem.Allocator, input: []const u8) anyerror!ast.Stylesheet,
};

pub fn getParser(format: Format) ParserTrait {
    return switch (format) {
        .css => .{ .parseFn = parseCSS },
        .scss => .{ .parseFn = parseSCSS },
        .sass => .{ .parseFn = parseSASS },
        .less => .{ .parseFn = parseLESS },
        .css_modules => .{ .parseFn = parseCSSModules },
        .css_in_js => .{ .parseFn = parseCSSInJS },
    };
}

fn parseCSS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const css_parser = @import("parser.zig");
    var p = css_parser.Parser.init(allocator, input);
    return try p.parse();
}

fn parseSCSS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const scss_parser = @import("formats/scss.zig");
    var p = scss_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

fn parseSASS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    return parseCSS(allocator, input);
}

fn parseLESS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    return parseCSS(allocator, input);
}

fn parseCSSModules(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    return parseCSS(allocator, input);
}

fn parseCSSInJS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    return parseCSS(allocator, input);
}

test "detect format from filename" {
    try std.testing.expect(detectFormat("style.css") == .css);
    try std.testing.expect(detectFormat("style.scss") == .scss);
    try std.testing.expect(detectFormat("style.sass") == .sass);
    try std.testing.expect(detectFormat("style.less") == .less);
    try std.testing.expect(detectFormat("style.module.css") == .css_modules);
    try std.testing.expect(detectFormat("style.css.js") == .css_in_js);
    try std.testing.expect(detectFormat("style.css.ts") == .css_in_js);
}
