const std = @import("std");
const zigcss = @import("zigcss");

comptime {
    _ = zigcss.source;
    _ = zigcss.diagnostics;
    _ = zigcss.compilation;
    _ = zigcss.tokenizer;
    _ = zigcss.syntax;
    _ = zigcss.css;
    _ = zigcss.sourcemap;
    _ = zigcss.transform;
    _ = zigcss.prefixing;

    _ = zigcss.SourceId;
    _ = zigcss.Span;
    _ = zigcss.SourceLocation;
    _ = zigcss.SourceFile;
    _ = zigcss.SourceManager;
    _ = zigcss.Diagnostic;
    _ = zigcss.DiagnosticCode;
    _ = zigcss.DiagnosticList;
    _ = zigcss.DiagnosticSeverity;
    _ = zigcss.Compilation;
    _ = zigcss.CompileResult;
    _ = zigcss.Token;
    _ = zigcss.TokenKind;
    _ = zigcss.Tokenizer;
    _ = zigcss.ComponentValue;
    _ = zigcss.ComponentValueDocument;
}

test "external consumer imports the public root and owns CSS maps and diagnostics" {
    var result: zigcss.CompileResult = try zigcss.css.pipeline.compile(
        std.testing.allocator,
        "consumer.css",
        ".consumer { color: red; }",
        .{
            .mode = .minified,
            .source_map = .{ .generated_file = "consumer.out.css" },
        },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings(".consumer{color:red}", result.css);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const source_map = result.source_map orelse return error.MissingSourceMap;
    var parsed_map = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        source_map,
        .{},
    );
    defer parsed_map.deinit();
    try std.testing.expectEqualStrings(
        "consumer.css",
        parsed_map.value.object.get("sources").?.array.items[0].string,
    );
}

test "external consumer reaches only explicit transform and target modules" {
    var parsed = try zigcss.css.pipeline.parse(
        std.testing.allocator,
        "consumer-transform.css",
        ".empty{}.a{width:calc(1px + 2px)}",
    );
    defer parsed.deinit();
    try zigcss.transform.verified_optimizer.applyToFixedPoint(
        std.testing.allocator,
        &parsed,
        .minified,
    );
    var result = try parsed.emitResult(std.testing.allocator, .{ .mode = .minified });
    defer result.deinit();
    try std.testing.expectEqualStrings(".a{width:3px}", result.css);

    const parsed_query = try zigcss.prefixing.target_query.parse(
        std.testing.allocator,
        "chrome >= 120, firefox >= 115",
        .{},
    );
    var query = switch (parsed_query) {
        .query => |value| value,
        .invalid => return error.UnexpectedInvalidTargetQuery,
    };
    defer query.deinit();
    try std.testing.expect(query.validate());
    try std.testing.expectEqual(
        @as(u16, 120),
        query.minimum(.chrome).?.major,
    );
}
