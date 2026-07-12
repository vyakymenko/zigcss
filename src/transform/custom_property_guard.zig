const std = @import("std");
const ast = @import("../css/ast.zig");
const source = @import("../source.zig");
const syntax = @import("../syntax.zig");
const tokenizer = @import("../tokenizer.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidAst,
    InvalidSpan,
    InvalidToken,
    NestingLimit,
    ProtectedDeclarationRewrite,
    SourceMismatch,
    UnterminatedSyntax,
};

pub const Options = struct {
    max_depth: usize = 256,
};

/// Custom-property declarations and declarations containing `var()` remain
/// authored at the default transform boundary. A future static resolver must
/// use a separately authorized pass instead of the shared rewrite helpers.
pub fn protectsDeclaration(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declaration: ast.Declaration,
    options: Options,
) Error!bool {
    _ = ast.Declaration.init(declaration) catch return error.InvalidAst;
    _ = file.slice(declaration.span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    if (declaration.name.isCustomProperty()) return true;
    return containsVarFunction(
        allocator,
        file,
        declaration.valueWithoutImportance(),
        options,
        0,
    );
}

/// Rejects declaration-level generated proofs that consume a protected input.
/// Structural proof validation remains the AST constructor's responsibility.
pub fn validateGeneratedDeclarations(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    declarations: []const ast.Declaration,
    generated: []const ast.GeneratedDeclaration,
    options: Options,
) Error!void {
    for (generated) |proof| {
        const end = std.math.add(
            usize,
            proof.first_declaration,
            proof.kind.inputCount(),
        ) catch return error.InvalidAst;
        if (end > declarations.len) return error.InvalidAst;
        if (proof.kind == .compatibility) {
            const compatibility = proof.compatibility orelse return error.InvalidAst;
            if (!ast.compatibilityDeclarationMatchesStructure(
                declarations[proof.first_declaration],
                compatibility.feature,
            )) return error.InvalidAst;
            // Compatibility expansion copies the complete value verbatim; it
            // neither resolves nor substitutes a custom property. The source
            // declaration remains the standard-last proof input.
            continue;
        }
        for (declarations[proof.first_declaration..end]) |declaration| {
            if (try protectsDeclaration(allocator, file, declaration, options)) {
                return error.ProtectedDeclarationRewrite;
            }
        }
    }
}

fn containsVarFunction(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    values: []const syntax.ComponentValue,
    options: Options,
    depth: usize,
) Error!bool {
    if (depth > options.max_depth) return error.NestingLimit;
    for (values) |value| {
        _ = file.slice(value.span()) catch |err| switch (err) {
            error.SourceMismatch => return error.SourceMismatch,
            error.InvalidSpan => return error.InvalidSpan,
        };
        switch (value) {
            .token => {},
            .simple_block => |block| {
                if (!block.terminated()) return error.UnterminatedSyntax;
                if (try containsVarFunction(
                    allocator,
                    file,
                    block.values,
                    options,
                    try nextDepth(depth),
                )) return true;
            },
            .function => |function| {
                if (!function.terminated()) return error.UnterminatedSyntax;
                if (try functionIsVar(allocator, file, function.opening)) return true;
                if (try containsVarFunction(
                    allocator,
                    file,
                    function.values,
                    options,
                    try nextDepth(depth),
                )) return true;
            },
        }
    }
    return false;
}

fn functionIsVar(
    allocator: std.mem.Allocator,
    file: *const source.SourceFile,
    opening: tokenizer.Token,
) Error!bool {
    const value_span = opening.valueSpan() orelse return error.InvalidToken;
    const raw = file.slice(value_span) catch |err| switch (err) {
        error.SourceMismatch => return error.SourceMismatch,
        error.InvalidSpan => return error.InvalidSpan,
    };
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return std.ascii.eqlIgnoreCase(raw, "var");
    }
    const decoded = opening.decodedTextAlloc(allocator, file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceMismatch => return error.SourceMismatch,
        else => return error.InvalidToken,
    };
    defer allocator.free(decoded);
    return std.ascii.eqlIgnoreCase(decoded, "var");
}

fn nextDepth(depth: usize) Error!usize {
    return std.math.add(usize, depth, 1) catch error.NestingLimit;
}

const pipeline = @import("../css/pipeline.zig");

test "custom property guard protects definitions and nested escaped var functions" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "custom-property-guard.css",
        ".a{--Theme:calc(1px + 2px);color:v\\61 r(--Theme);" ++
            "width:calc(1px + VAR(--size));height:calc(1px + 2px)}",
    );
    defer parsed.deinit();
    const declarations = parsed.rules.rules[0].style_rule.block.declarations.declarations;
    try std.testing.expect(try protectsDeclaration(
        std.testing.allocator,
        parsed.file(),
        declarations[0],
        .{},
    ));
    try std.testing.expect(try protectsDeclaration(
        std.testing.allocator,
        parsed.file(),
        declarations[1],
        .{},
    ));
    try std.testing.expect(try protectsDeclaration(
        std.testing.allocator,
        parsed.file(),
        declarations[2],
        .{},
    ));
    try std.testing.expect(!(try protectsDeclaration(
        std.testing.allocator,
        parsed.file(),
        declarations[3],
        .{},
    )));
}

test "custom property guard rejects generated declarations that consume substitutions" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "custom-property-generated.css",
        ".a{margin-top:var(--gap);margin-right:var(--gap);" ++
            "margin-bottom:var(--gap);margin-left:var(--gap)}",
    );
    defer parsed.deinit();
    const declarations = parsed.rules.rules[0].style_rule.block.declarations.declarations;
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .margin,
        .first_declaration = 0,
        .source_span = .{
            .source = parsed.source_id,
            .start = declarations[0].span.start,
            .end = declarations[3].span.end,
        },
    }};
    try std.testing.expectError(
        error.ProtectedDeclarationRewrite,
        validateGeneratedDeclarations(
            std.testing.allocator,
            parsed.file(),
            declarations,
            &generated,
            .{},
        ),
    );
}

test "custom property guard permits closed compatibility copies of var consumers" {
    var parsed = try pipeline.parse(
        std.testing.allocator,
        "custom-property-prefix.css",
        ".a{appearance:var(--appearance)}",
    );
    defer parsed.deinit();
    const declarations = parsed.rules.rules[0].style_rule.block.declarations.declarations;
    const forms = [_]ast.CompatibilityForm{.webkit};
    const generated = [_]ast.GeneratedDeclaration{.{
        .kind = .compatibility,
        .first_declaration = 0,
        .source_span = declarations[0].span,
        .compatibility = .{ .feature = .appearance, .forms = &forms },
    }};
    try validateGeneratedDeclarations(
        std.testing.allocator,
        parsed.file(),
        declarations,
        &generated,
        .{},
    );
}

test "custom property guard validates source ownership and nesting limits" {
    const css = ".a{width:outer(inner(1px))}";
    var parsed = try pipeline.parse(std.testing.allocator, "custom-property-limits.css", css);
    defer parsed.deinit();
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[0];
    try std.testing.expectError(
        error.NestingLimit,
        protectsDeclaration(
            std.testing.allocator,
            parsed.file(),
            declaration,
            .{ .max_depth = 0 },
        ),
    );
    const foreign_id = try parsed.compilation.addSource("custom-property-foreign.css", css);
    try std.testing.expectError(
        error.SourceMismatch,
        protectsDeclaration(
            std.testing.allocator,
            try parsed.compilation.sources.get(foreign_id),
            declaration,
            .{},
        ),
    );
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var parsed = try pipeline.parse(
        allocator,
        "custom-property-guard-oom.css",
        ".a{color:calc(1px + v\\61 r(--theme, red))}",
    );
    defer parsed.deinit();
    const declaration = parsed.rules.rules[0].style_rule.block.declarations.declarations[0];
    try std.testing.expect(try protectsDeclaration(allocator, parsed.file(), declaration, .{}));
}

test "custom property guard handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
