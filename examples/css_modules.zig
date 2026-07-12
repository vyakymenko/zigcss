const std = @import("std");
const zigcss = @import("zigcss");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = try zigcss.compile(
        gpa.allocator(),
        "src/components/card.module.css",
        ".card:is(.icon,.card) { color: red; }",
        .{
            .syntax = .css_modules,
            .format = .minified,
        },
    );
    defer result.deinit();
    if (result.diagnostics.len != 0) return error.InvalidModule;

    const exports = result.module_exports orelse return error.MissingModuleExports;
    if (exports.entries.len != 2) return error.UnexpectedExports;
    if (!std.mem.eql(u8, exports.entries[0].name, "card")) return error.MissingCardExport;
    if (!std.mem.eql(u8, exports.entries[1].name, "icon")) return error.MissingIconExport;

    for (exports.entries) |entry| {
        if (entry.value.len == 0) return error.EmptyExportValue;
        // entry.composes owns ordered local, global, or dependency references.
        _ = entry.composes;
    }
}
