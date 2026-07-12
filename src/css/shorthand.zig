const std = @import("std");
const ast = @import("ast.zig");
const numeric_value = @import("numeric_value.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidSpan,
    SourceMismatch,
};

/// Evidence needed to emit one `margin` shorthand without discarding the
/// authored declarations that justify it. This deliberately recognizes only
/// the one-value form, so every generated component has one causal token.
pub const MarginProof = struct {
    value_span: source.Span,
    source_span: source.Span,
    important: bool,
};

/// Proves that four adjacent declarations may be replaced by one `margin`
/// shorthand. Unsupported or compatibility-sensitive syntax returns null;
/// malformed source bindings and allocation failures remain hard errors.
pub fn analyzeMargin(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declarations: []const ast.Declaration,
) Error!?MarginProof {
    const names = [_][]const u8{
        "margin-top",
        "margin-right",
        "margin-bottom",
        "margin-left",
    };
    if (declarations.len != names.len) return null;

    const important = declarations[0].important != null;
    var value_span: ?source.Span = null;
    var value_bytes: ?[]const u8 = null;
    for (declarations, names) |declaration, name| {
        _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
        if (!std.ascii.eqlIgnoreCase(declaration.name.value, name) or
            (declaration.important != null) != important or
            declaration.generated_value != null)
        {
            return null;
        }

        const token = singleSignificantToken(declaration.valueWithoutImportance()) orelse return null;
        if (!try isSafeMarginToken(allocator, file, declaration.valueWithoutImportance(), token)) {
            return null;
        }
        const raw = file.slice(token.span) catch |err| switch (err) {
            error.SourceMismatch => return error.SourceMismatch,
            error.InvalidSpan => return error.InvalidSpan,
        };
        if (value_bytes) |first| {
            if (!std.mem.eql(u8, first, raw)) return null;
        } else {
            value_bytes = raw;
            value_span = token.span;
        }
    }

    if (!declarations[0].span.source.eql(declarations[declarations.len - 1].span.source)) {
        return error.SourceMismatch;
    }
    const causal_span = source.Span{
        .source = declarations[0].span.source,
        .start = declarations[0].span.start,
        .end = declarations[declarations.len - 1].span.end,
    };
    _ = file.slice(causal_span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    return .{
        .value_span = value_span.?,
        .source_span = causal_span,
        .important = important,
    };
}

fn singleSignificantToken(values: []const syntax.ComponentValue) ?tokenizer.Token {
    var first: usize = 0;
    while (first < values.len and isWhitespace(values[first])) : (first += 1) {}
    var end = values.len;
    while (end > first and isWhitespace(values[end - 1])) : (end -= 1) {}
    if (end - first != 1) return null;
    return switch (values[first]) {
        .token => |token| if (token.kind == .comment) null else token,
        .simple_block, .function => null,
    };
}

fn isWhitespace(value: syntax.ComponentValue) bool {
    return switch (value) {
        .token => |token| token.kind == .whitespace,
        else => false,
    };
}

fn isSafeMarginToken(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    token: tokenizer.Token,
) Error!bool {
    if (token.kind == .ident) {
        const decoded = token.decodedTextAlloc(allocator, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceMismatch => return error.SourceMismatch,
            else => return error.InvalidAst,
        };
        defer allocator.free(decoded);
        return std.ascii.eqlIgnoreCase(decoded, "auto");
    }
    if (token.kind != .number and token.kind != .percentage and token.kind != .dimension) {
        return false;
    }

    var expression = numeric_value.parse(allocator, file, values, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
        else => return false,
    };
    defer expression.deinit();
    if (expression.instructions.len != 1 or !sameSpan(expression.span, token.span)) return false;
    const literal = switch (expression.instructions[0]) {
        .literal => |value| value,
        else => return false,
    };
    if (literal.kind != .numeric or !std.math.isFinite(literal.value)) return false;
    return switch (literal.unit) {
        .number => literal.value == 0,
        .percent => true,
        else => literal.unit.baseDimension() == .length,
    };
}

fn sameSpan(left: source.Span, right: source.Span) bool {
    return left.source.eql(right.source) and left.start == right.start and left.end == right.end;
}

const pipeline = @import("pipeline.zig");

fn declarationList(parsed: *const pipeline.ParsedStylesheet, rule_index: usize) []const ast.Declaration {
    return parsed.rules.rules[rule_index].style_rule.block.declarations.declarations;
}

test "margin shorthand proof accepts only one exact safe physical value" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "margin-proof.css",
        ".length{margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px}" ++
            ".auto{MARGIN-TOP:a\\75to!important;margin-right:a\\75to!important;" ++
            "margin-bottom:a\\75to!important;margin-left:a\\75to!important}" ++
            ".percent{margin-top:-5.5%;margin-right:-5.5%;margin-bottom:-5.5%;margin-left:-5.5%}" ++
            ".zero{margin-top:-0;margin-right:-0;margin-bottom:-0;margin-left:-0}",
    );
    defer parsed.deinit();

    for (0..4) |index| {
        const declarations = declarationList(&parsed, index);
        const proof = (try analyzeMargin(std.testing.allocator, parsed.file(), declarations)).?;
        try std.testing.expectEqual(index == 1, proof.important);
        try std.testing.expectEqual(declarations[0].valueWithoutImportance()[0].span().start, proof.value_span.start);
        try std.testing.expectEqual(declarations[0].span.start, proof.source_span.start);
        try std.testing.expectEqual(declarations[3].span.end, proof.source_span.end);
    }
}

test "margin shorthand proof declines cascade grammar and compatibility risks" {
    const bodies = [_][]const u8{
        "margin-right:1px;margin-top:1px;margin-bottom:1px;margin-left:1px",
        "margin-top:1px;margin-right:1PX;margin-bottom:1px;margin-left:1px",
        "margin-top:calc(1px);margin-right:calc(1px);margin-bottom:calc(1px);margin-left:calc(1px)",
        "margin-top:var(--x);margin-right:var(--x);margin-bottom:var(--x);margin-left:var(--x)",
        "margin-top:inherit;margin-right:inherit;margin-bottom:inherit;margin-left:inherit",
        "margin-top:revert-layer;margin-right:revert-layer;margin-bottom:revert-layer;margin-left:revert-layer",
        "margin-top:1;margin-right:1;margin-bottom:1;margin-left:1",
        "margin-top:1deg;margin-right:1deg;margin-bottom:1deg;margin-left:1deg",
        "margin-top:1foo;margin-right:1foo;margin-bottom:1foo;margin-left:1foo",
        "margin-top:1e999px;margin-right:1e999px;margin-bottom:1e999px;margin-left:1e999px",
        "margin-top:1px/**/;margin-right:1px/**/;margin-bottom:1px/**/;margin-left:1px/**/",
        "margin-top:auto;margin-right:a\\75to;margin-bottom:auto;margin-left:auto",
        "margin-top:1px!important;margin-right:1px;margin-bottom:1px;margin-left:1px",
        "margin-top:1px;inset:0;margin-right:1px;margin-bottom:1px;margin-left:1px",
    };
    for (bodies, 0..) |body, index| {
        const css = try std.fmt.allocPrint(std.testing.allocator, ".a{{{s}}}", .{body});
        defer std.testing.allocator.free(css);
        var parsed = try pipeline.parse(std.testing.allocator, "margin-decline.css", css);
        defer parsed.deinit();
        const proof = try analyzeMargin(
            std.testing.allocator,
            parsed.file(),
            declarationList(&parsed, 0),
        );
        try std.testing.expect(proof == null);
        _ = index;
    }
}

test "margin shorthand proof rejects a foreign source binding" {
    const css = ".a{margin-top:1px;margin-right:1px;margin-bottom:1px;margin-left:1px}";
    var parsed = try pipeline.parse(std.testing.allocator, "margin-source.css", css);
    defer parsed.deinit();
    const foreign_id = try parsed.compilation.addSource("margin-foreign.css", css);
    const foreign_file = try parsed.compilation.sources.get(foreign_id);
    try std.testing.expectError(
        error.SourceMismatch,
        analyzeMargin(
            std.testing.allocator,
            foreign_file,
            declarationList(&parsed, 0),
        ),
    );
}

fn exerciseMarginProofAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "margin-proof-oom.css",
        ".a{margin-top:a\\75to;margin-right:a\\75to;margin-bottom:a\\75to;margin-left:a\\75to}" ++
            ".b{margin-top:1rem;margin-right:1rem;margin-bottom:1rem;margin-left:1rem}",
    );
    defer parsed.deinit();
    try std.testing.expect((try analyzeMargin(allocator, parsed.file(), declarationList(&parsed, 0))) != null);
    try std.testing.expect((try analyzeMargin(allocator, parsed.file(), declarationList(&parsed, 1))) != null);
}

test "margin shorthand proof handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseMarginProofAllocationFailures,
        .{},
    );
}
