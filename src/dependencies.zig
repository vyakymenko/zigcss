const std = @import("std");
const ast = @import("css/ast.zig");
const pipeline = @import("css/pipeline.zig");
const source = @import("source.zig");
const syntax = @import("syntax.zig");
const tokenizer = @import("tokenizer.zig");

pub const Kind = enum {
    import,
};

/// Result-owned dependency evidence. Entries retain authored order and
/// duplicates because repeated CSS imports remain observable. The source name
/// and decoded specifier remain valid after compilation cleanup.
pub const Dependency = struct {
    kind: Kind,
    specifier: []const u8,
    source_name: []const u8,
    span: source.Span,
};

pub const Options = struct {
    max_dependencies: usize = 100_000,
    max_owned_bytes: usize = 64 * 1024 * 1024,
};

pub const OwnedList = struct {
    allocator: std.mem.Allocator,
    items: []Dependency,

    pub fn init(allocator: std.mem.Allocator) OwnedList {
        return .{ .allocator = allocator, .items = &.{} };
    }

    pub fn deinit(self: *OwnedList) void {
        release(self.allocator, self.items);
        self.items = &.{};
    }

    pub fn take(self: *OwnedList) []Dependency {
        const items = self.items;
        self.items = &.{};
        return items;
    }
};

pub fn release(allocator: std.mem.Allocator, items: []const Dependency) void {
    if (items.len == 0) return;
    for (items) |dependency| {
        if (dependency.specifier.len > 0) allocator.free(dependency.specifier);
        if (dependency.source_name.len > 0) allocator.free(dependency.source_name);
    }
    allocator.free(items);
}

const Builder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Dependency),

    fn init(allocator: std.mem.Allocator) !Builder {
        return .{
            .allocator = allocator,
            .items = try std.ArrayList(Dependency).initCapacity(allocator, 0),
        };
    }

    fn deinit(self: *Builder) void {
        for (self.items.items) |dependency| {
            if (dependency.specifier.len > 0) self.allocator.free(dependency.specifier);
            if (dependency.source_name.len > 0) self.allocator.free(dependency.source_name);
        }
        self.items.deinit(self.allocator);
    }
};

const Specifier = struct {
    value: []u8,
    span: source.Span,
};

pub fn collect(
    allocator: std.mem.Allocator,
    parsed: *pipeline.ParsedStylesheet,
    options: Options,
) !OwnedList {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    const file = parsed.file();
    var owned_bytes: usize = 0;

    for (parsed.rules.rules) |rule| {
        const at_rule = switch (rule) {
            .at_rule => |value| value,
            else => continue,
        };
        if (!std.ascii.eqlIgnoreCase(at_rule.name.value, "import") or
            at_rule.block != .none)
        {
            continue;
        }
        const candidate = try importSpecifier(allocator, file, at_rule) orelse continue;
        const next_bytes = std.math.add(
            usize,
            owned_bytes,
            std.math.add(usize, candidate.value.len, file.name.len) catch std.math.maxInt(usize),
        ) catch std.math.maxInt(usize);
        if (builder.items.items.len >= options.max_dependencies or
            next_bytes > options.max_owned_bytes)
        {
            if (candidate.value.len > 0) allocator.free(candidate.value);
            try parsed.compilation.report(
                .err,
                .resource_limit,
                at_rule.span,
                "CSS dependency reporting limit exceeded",
            );
            return OwnedList.init(allocator);
        }

        const source_name = allocator.dupe(u8, file.name) catch |err| {
            if (candidate.value.len > 0) allocator.free(candidate.value);
            return err;
        };
        builder.items.append(allocator, .{
            .kind = .import,
            .specifier = candidate.value,
            .source_name = source_name,
            .span = candidate.span,
        }) catch |err| {
            if (candidate.value.len > 0) allocator.free(candidate.value);
            if (source_name.len > 0) allocator.free(source_name);
            return err;
        };
        owned_bytes = next_bytes;
    }

    return .{
        .allocator = allocator,
        .items = try builder.items.toOwnedSlice(allocator),
    };
}

fn importSpecifier(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    at_rule: *const ast.AtRule,
) !?Specifier {
    const value = firstSignificant(at_rule.prelude.values) orelse return null;
    return switch (value.*) {
        .token => |token| decodeSpecifierToken(allocator, file, token),
        .function => |function| decodeUrlFunction(allocator, file, function),
        else => null,
    };
}

fn decodeSpecifierToken(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    token: tokenizer.Token,
) !?Specifier {
    if (token.kind != .string and token.kind != .url) return null;
    if (!token.isTerminated()) return null;
    return .{
        .value = try token.decodedTextAlloc(allocator, file),
        .span = token.valueSpan() orelse token.span,
    };
}

fn decodeUrlFunction(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    function: *const syntax.Function,
) !?Specifier {
    if (!function.terminated()) return null;
    const name = try function.opening.decodedTextAlloc(allocator, file);
    defer if (name.len > 0) allocator.free(name);
    if (!std.ascii.eqlIgnoreCase(name, "url")) return null;

    var significant: ?tokenizer.Token = null;
    for (function.values) |value| {
        const token = switch (value) {
            .token => |candidate| candidate,
            else => return null,
        };
        if (token.isTrivia()) continue;
        if (significant != null) return null;
        significant = token;
    }
    const token = significant orelse return null;
    if (token.kind != .string or !token.isTerminated()) return null;
    return .{
        .value = try token.decodedTextAlloc(allocator, file),
        .span = token.valueSpan() orelse token.span,
    };
}

fn firstSignificant(values: []const syntax.ComponentValue) ?*const syntax.ComponentValue {
    for (values) |*value| {
        switch (value.*) {
            .token => |token| if (token.isTrivia()) continue,
            else => {},
        }
        return value;
    }
    return null;
}

test "dependency collection owns ordered decoded CSS imports" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "dependencies.css",
        "@import \"a.css\";" ++
            "@import url(b\\2e css) layer(base);" ++
            "@import u\\72l(\"c.css\") supports(display:grid);" ++
            "@import \"a.css\";" ++
            "@import layer(base);" ++
            ".keep{color:red}",
    );
    try std.testing.expect(!parsed.hasErrors());
    var dependencies = try collect(std.testing.allocator, &parsed, .{});
    parsed.deinit();
    defer dependencies.deinit();

    try std.testing.expectEqual(@as(usize, 4), dependencies.items.len);
    const expected = [_][]const u8{ "a.css", "b.css", "c.css", "a.css" };
    for (dependencies.items, expected) |dependency, specifier| {
        try std.testing.expectEqual(Kind.import, dependency.kind);
        try std.testing.expectEqualStrings(specifier, dependency.specifier);
        try std.testing.expectEqualStrings("dependencies.css", dependency.source_name);
        try std.testing.expect(dependency.span.start < dependency.span.end);
    }
}

test "dependency limits are structured diagnostics without partial facts" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "dependency-limit.css",
        "@import \"one.css\";@import \"two.css\";",
    );
    defer parsed.deinit();
    var dependencies = try collect(std.testing.allocator, &parsed, .{
        .max_dependencies = 1,
    });
    defer dependencies.deinit();

    try std.testing.expectEqual(@as(usize, 0), dependencies.items.len);
    try std.testing.expect(parsed.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), parsed.compilation.diagnostics.items().len);
    try std.testing.expectEqual(
        @import("diagnostics.zig").Code.resource_limit,
        parsed.compilation.diagnostics.items()[0].code,
    );
}

fn exerciseDependencyAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "dependency-oom.css",
        "@import \"a.css\";@import url(b.css);",
    );
    defer parsed.deinit();
    var dependencies = try collect(allocator, &parsed, .{});
    defer dependencies.deinit();
    try std.testing.expectEqual(@as(usize, 2), dependencies.items.len);
}

test "dependency collection handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDependencyAllocationFailures,
        .{},
    );
}
