const std = @import("std");
const ast = @import("ast.zig");

pub const Format = enum {
    css,
    less,
    css_modules,
    css_in_js,
    postcss,
    stylus,
};

/// The legacy adapters are retained for characterization and future adapter
/// work, but are not part of the recovery CLI's supported surface.
pub fn isExperimental(format: Format) bool {
    return format != .css;
}

pub fn displayName(format: Format) []const u8 {
    return switch (format) {
        .css => "CSS",
        .less => "LESS",
        .css_modules => "CSS Modules",
        .css_in_js => "CSS-in-JS",
        .postcss => "PostCSS",
        .stylus => "Stylus",
    };
}

pub fn detectFormat(filename: []const u8) ?Format {
    if (std.mem.endsWith(u8, filename, ".scss") or
        std.mem.endsWith(u8, filename, ".sass"))
    {
        return null;
    } else if (std.mem.endsWith(u8, filename, ".less")) {
        return .less;
    } else if (std.mem.endsWith(u8, filename, ".module.css")) {
        return .css_modules;
    } else if (std.mem.endsWith(u8, filename, ".css.js") or std.mem.endsWith(u8, filename, ".css.ts")) {
        return .css_in_js;
    } else if (std.mem.endsWith(u8, filename, ".postcss")) {
        return .postcss;
    } else if (std.mem.endsWith(u8, filename, ".styl")) {
        return .stylus;
    } else if (std.mem.endsWith(u8, filename, ".css")) {
        return .css;
    } else {
        return null;
    }
}

pub const ParserTrait = struct {
    parseFn: *const fn (allocator: std.mem.Allocator, input: []const u8) anyerror!ast.Stylesheet,
};

pub fn getParser(format: Format) ParserTrait {
    return switch (format) {
        .css => .{ .parseFn = parseCSS },
        .less => .{ .parseFn = parseLESS },
        .css_modules => .{ .parseFn = parseCSSModules },
        .css_in_js => .{ .parseFn = parseCSSInJS },
        .postcss => .{ .parseFn = parsePostCSS },
        .stylus => .{ .parseFn = parseStylus },
    };
}

fn parseCSS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const css_parser = @import("parser.zig");
    var p = css_parser.Parser.init(allocator, input);
    return try p.parse();
}

fn parseLESS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const less_parser = @import("formats/less.zig");
    var p = less_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

fn parseCSSModules(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const css_modules_parser = @import("formats/css_modules.zig");
    var p = css_modules_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

fn parseCSSInJS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const css_in_js_parser = @import("formats/css_in_js.zig");
    var p = css_in_js_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

fn parsePostCSS(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const postcss_parser = @import("formats/postcss.zig");
    var p = postcss_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

fn parseStylus(allocator: std.mem.Allocator, input: []const u8) !ast.Stylesheet {
    const stylus_parser = @import("formats/stylus.zig");
    var p = stylus_parser.Parser.init(allocator, input);
    defer p.deinit();
    return try p.parse();
}

test "detect format from filename" {
    try std.testing.expectEqual(Format.css, detectFormat("style.css").?);
    try std.testing.expectEqual(Format.less, detectFormat("style.less").?);
    try std.testing.expectEqual(Format.css_modules, detectFormat("style.module.css").?);
    try std.testing.expectEqual(Format.css_in_js, detectFormat("style.css.js").?);
    try std.testing.expectEqual(Format.css_in_js, detectFormat("style.css.ts").?);
    try std.testing.expectEqual(Format.postcss, detectFormat("style.postcss").?);
    try std.testing.expectEqual(Format.stylus, detectFormat("style.styl").?);
    try std.testing.expect(detectFormat("style.scss") == null);
    try std.testing.expect(detectFormat("style.sass") == null);
    try std.testing.expect(detectFormat("style.unknown") == null);
}

test "non-CSS format adapters are classified as experimental" {
    inline for (std.meta.tags(Format)) |format| {
        try std.testing.expectEqual(format != .css, isExperimental(format));
    }
}
