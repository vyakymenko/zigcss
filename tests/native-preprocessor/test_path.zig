const std = @import("std");

pub fn absoluteTmpDirPath(
    allocator: std.mem.Allocator,
    temporary: *const std.testing.TmpDir,
) ![]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        temporary.sub_path[0..],
    });
}
