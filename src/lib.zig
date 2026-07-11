pub const source = @import("source.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const compilation = @import("compilation.zig");

pub const SourceId = source.SourceId;
pub const Span = source.Span;
pub const SourceLocation = source.Location;
pub const SourceFile = source.SourceFile;
pub const SourceManager = source.SourceManager;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticCode = diagnostics.Code;
pub const DiagnosticList = diagnostics.DiagnosticList;
pub const DiagnosticSeverity = diagnostics.Severity;
pub const Compilation = compilation.Compilation;

test "public foundation types compose through the library root" {
    const std = @import("std");
    var context = try Compilation.init(std.testing.allocator);
    defer context.deinit();

    const source_id = try context.addSource("public.css", ".public{}");
    const span = try Span.init(source_id, 1, 7);
    try context.report(.note, .unexpected_token, span, "public API smoke");

    const file: *const SourceFile = try context.sources.get(source_id);
    const location: SourceLocation = try file.location(span.start);
    const diagnostic: Diagnostic = context.diagnostics.items()[0];
    try std.testing.expectEqual(@as(u32, 1), location.line);
    try std.testing.expectEqual(DiagnosticSeverity.note, diagnostic.severity);
    try std.testing.expectEqual(DiagnosticCode.unexpected_token, diagnostic.code);
}
