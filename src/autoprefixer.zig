const std = @import("std");
const ast = @import("ast.zig");

pub const BrowserSupport = struct {
    chrome: u32 = 0,
    firefox: u32 = 0,
    safari: u32 = 0,
    edge: u32 = 0,
    opera: u32 = 0,
    ios_saf: u32 = 0,
    android: u32 = 0,
    samsung: u32 = 0,
};

pub const AutoprefixOptions = struct {
    browsers: []const []const u8 = &.{},
    cascade: bool = true,
    add: bool = true,
    remove: bool = true,
    supports: bool = true,
    flexbox: bool = true,
    grid: bool = true,
};

const PropertyPrefixes = struct {
    property: []const u8,
    prefixes: []const []const u8,
};

const PROPERTY_PREFIXES = [_]PropertyPrefixes{
    .{ .property = "display", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-direction", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-wrap", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-flow", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-grow", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-shrink", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "flex-basis", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "justify-content", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "align-items", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "align-self", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "align-content", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "order", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "grid", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-template", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-template-areas", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-template-columns", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-template-rows", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-auto-columns", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-auto-rows", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-auto-flow", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-column", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-column-start", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-column-end", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-row", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-row-start", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-row-end", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-area", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-gap", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-column-gap", .prefixes = &.{"-ms-"} },
    .{ .property = "grid-row-gap", .prefixes = &.{"-ms-"} },
    .{ .property = "transform", .prefixes = &.{"-webkit-", "-ms-", "-moz-", "-o-"} },
    .{ .property = "transform-origin", .prefixes = &.{"-webkit-", "-ms-", "-moz-", "-o-"} },
    .{ .property = "transform-style", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "perspective", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "perspective-origin", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "backface-visibility", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "transition", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "transition-property", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "transition-duration", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "transition-timing-function", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "transition-delay", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-name", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-duration", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-timing-function", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-delay", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-iteration-count", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-direction", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-fill-mode", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "animation-play-state", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "appearance", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "user-select", .prefixes = &.{"-webkit-", "-moz-", "-ms-"} },
    .{ .property = "box-sizing", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "box-shadow", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "border-radius", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "background-clip", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "background-size", .prefixes = &.{"-webkit-", "-moz-", "-o-"} },
    .{ .property = "background-origin", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "filter", .prefixes = &.{"-webkit-"} },
    .{ .property = "backdrop-filter", .prefixes = &.{"-webkit-"} },
    .{ .property = "text-size-adjust", .prefixes = &.{"-webkit-", "-moz-", "-ms-"} },
    .{ .property = "text-decoration", .prefixes = &.{"-webkit-"} },
    .{ .property = "text-decoration-line", .prefixes = &.{"-webkit-"} },
    .{ .property = "text-decoration-style", .prefixes = &.{"-webkit-"} },
    .{ .property = "text-decoration-color", .prefixes = &.{"-webkit-"} },
    .{ .property = "column-count", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-gap", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-rule", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-rule-color", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-rule-style", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-rule-width", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-span", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "column-width", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "columns", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "writing-mode", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "text-orientation", .prefixes = &.{"-webkit-"} },
    .{ .property = "hyphens", .prefixes = &.{"-webkit-", "-moz-", "-ms-"} },
    .{ .property = "tab-size", .prefixes = &.{"-moz-", "-o-"} },
    .{ .property = "text-overflow", .prefixes = &.{"-ms-"} },
    .{ .property = "touch-action", .prefixes = &.{"-ms-"} },
    .{ .property = "scroll-snap-type", .prefixes = &.{"-ms-"} },
    .{ .property = "scroll-snap-align", .prefixes = &.{"-ms-"} },
    .{ .property = "scroll-snap-stop", .prefixes = &.{"-ms-"} },
    .{ .property = "scroll-behavior", .prefixes = &.{"-ms-"} },
    .{ .property = "clip-path", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-image", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-mode", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-repeat", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-position", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-clip", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-origin", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-size", .prefixes = &.{"-webkit-"} },
    .{ .property = "mask-composite", .prefixes = &.{"-webkit-"} },
    .{ .property = "object-fit", .prefixes = &.{"-o-"} },
    .{ .property = "object-position", .prefixes = &.{"-o-"} },
    .{ .property = "will-change", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "font-feature-settings", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "font-kerning", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "font-variant-ligatures", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "text-rendering", .prefixes = &.{"-webkit-", "-moz-"} },
    .{ .property = "shape-outside", .prefixes = &.{"-webkit-"} },
    .{ .property = "shape-margin", .prefixes = &.{"-webkit-"} },
    .{ .property = "shape-image-threshold", .prefixes = &.{"-webkit-"} },
};

const VALUE_PREFIXES = [_]struct {
    property: []const u8,
    value_pattern: []const u8,
    prefixes: []const []const u8,
}{
    .{ .property = "display", .value_pattern = "flex", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "display", .value_pattern = "inline-flex", .prefixes = &.{"-webkit-", "-ms-"} },
    .{ .property = "display", .value_pattern = "grid", .prefixes = &.{"-ms-"} },
    .{ .property = "display", .value_pattern = "inline-grid", .prefixes = &.{"-ms-"} },
    .{ .property = "position", .value_pattern = "sticky", .prefixes = &.{"-webkit-"} },
};

pub const Autoprefixer = struct {
    allocator: std.mem.Allocator,
    options: AutoprefixOptions,
    browser_support: BrowserSupport,

    pub fn init(allocator: std.mem.Allocator, options: AutoprefixOptions) Autoprefixer {
        return .{
            .allocator = allocator,
            .options = options,
            .browser_support = .{},
        };
    }

    pub fn process(self: *Autoprefixer, stylesheet: *ast.Stylesheet) !void {
        for (stylesheet.rules.items) |*rule| {
            switch (rule.*) {
                .style => |*style_rule| {
                    try self.processStyleRule(style_rule);
                },
                .at_rule => |*at_rule| {
                    if (at_rule.rules) |*rules| {
                        for (rules.items) |*nested_rule| {
                            switch (nested_rule.*) {
                                .style => |*style_rule| {
                                    try self.processStyleRule(style_rule);
                                },
                                .at_rule => {},
                            }
                        }
                    }
                },
            }
        }
    }

    fn processStyleRule(self: *Autoprefixer, style_rule: *ast.StyleRule) !void {
        var new_declarations = try std.ArrayList(ast.Declaration).initCapacity(self.allocator, style_rule.declarations.items.len * 3);

        for (style_rule.declarations.items) |decl| {
            const original_decl = ast.Declaration{
                .property = try self.allocator.dupe(u8, decl.property),
                .value = try self.allocator.dupe(u8, decl.value),
                .important = decl.important,
                .allocator = self.allocator,
            };
            try new_declarations.append(self.allocator, original_decl);

            const prefixes = self.getPropertyPrefixes(decl.property);
            if (prefixes.len > 0) {
                for (prefixes) |prefix| {
                    const prefixed_property = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}{s}",
                        .{ prefix, decl.property }
                    );

                    const prefixed_decl = ast.Declaration{
                        .property = prefixed_property,
                        .value = try self.allocator.dupe(u8, decl.value),
                        .important = decl.important,
                        .allocator = self.allocator,
                    };

                    try new_declarations.append(self.allocator, prefixed_decl);
                }
            }

            const value_prefixes = self.getValuePrefixes(decl.property, decl.value);
            if (value_prefixes.len > 0) {
                for (value_prefixes) |prefix| {
                    const prefixed_property = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}{s}",
                        .{ prefix, decl.property }
                    );

                    const prefixed_decl = ast.Declaration{
                        .property = prefixed_property,
                        .value = try self.allocator.dupe(u8, decl.value),
                        .important = decl.important,
                        .allocator = self.allocator,
                    };

                    try new_declarations.append(self.allocator, prefixed_decl);
                }
            }
        }

        for (style_rule.declarations.items) |*decl| {
            decl.deinit();
        }
        style_rule.declarations.deinit(self.allocator);
        style_rule.declarations = new_declarations;
    }

    fn getPropertyPrefixes(_: *Autoprefixer, property: []const u8) []const []const u8 {
        for (PROPERTY_PREFIXES) |entry| {
            if (std.mem.eql(u8, entry.property, property)) {
                return entry.prefixes;
            }
        }
        return &.{};
    }

    fn getValuePrefixes(_: *Autoprefixer, property: []const u8, value: []const u8) []const []const u8 {
        for (VALUE_PREFIXES) |entry| {
            if (std.mem.eql(u8, entry.property, property)) {
                if (std.mem.indexOf(u8, value, entry.value_pattern) != null) {
                    return entry.prefixes;
                }
            }
        }
        return &.{};
    }
};

test "autoprefixer adds flex prefixes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stylesheet = try ast.Stylesheet.init(allocator);
    defer stylesheet.deinit();

    var style_rule = try ast.StyleRule.init(allocator);

    var selector = try ast.Selector.init(allocator);
    try selector.parts.append(allocator, ast.SelectorPart{ .class = "container" });
    try style_rule.selectors.append(allocator, selector);

    var decl = ast.Declaration.init(allocator);
    decl.property = try allocator.dupe(u8, "display");
    decl.value = try allocator.dupe(u8, "flex");
    try style_rule.declarations.append(allocator, decl);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = style_rule });

    var autoprefixer = Autoprefixer.init(allocator, .{});
    try autoprefixer.process(&stylesheet);

    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 1);

    var found_webkit = false;
    var found_ms = false;
    for (rule.style.declarations.items) |d| {
        if (std.mem.eql(u8, d.property, "-webkit-display")) {
            found_webkit = true;
        }
        if (std.mem.eql(u8, d.property, "-ms-display")) {
            found_ms = true;
        }
    }
    try std.testing.expect(found_webkit);
    try std.testing.expect(found_ms);
}

test "autoprefixer adds transform prefixes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stylesheet = try ast.Stylesheet.init(allocator);
    defer stylesheet.deinit();

    var style_rule = try ast.StyleRule.init(allocator);

    var selector = try ast.Selector.init(allocator);
    try selector.parts.append(allocator, ast.SelectorPart{ .class = "box" });
    try style_rule.selectors.append(allocator, selector);

    var decl = ast.Declaration.init(allocator);
    decl.property = try allocator.dupe(u8, "transform");
    decl.value = try allocator.dupe(u8, "rotate(45deg)");
    try style_rule.declarations.append(allocator, decl);

    try stylesheet.rules.append(allocator, ast.Rule{ .style = style_rule });

    var autoprefixer = Autoprefixer.init(allocator, .{});
    try autoprefixer.process(&stylesheet);

    const rule = stylesheet.rules.items[0];
    try std.testing.expect(rule == .style);
    try std.testing.expect(rule.style.declarations.items.len >= 4);

    var found_webkit = false;
    var found_moz = false;
    var found_ms = false;
    var found_o = false;
    for (rule.style.declarations.items) |d| {
        if (std.mem.eql(u8, d.property, "-webkit-transform")) {
            found_webkit = true;
        }
        if (std.mem.eql(u8, d.property, "-moz-transform")) {
            found_moz = true;
        }
        if (std.mem.eql(u8, d.property, "-ms-transform")) {
            found_ms = true;
        }
        if (std.mem.eql(u8, d.property, "-o-transform")) {
            found_o = true;
        }
    }
    try std.testing.expect(found_webkit);
    try std.testing.expect(found_moz);
    try std.testing.expect(found_ms);
    try std.testing.expect(found_o);
}
