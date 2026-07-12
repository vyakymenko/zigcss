pub const pass_manager = @import("transform/pass_manager.zig");
pub const empty_cleanup = @import("transform/empty_cleanup.zig");
pub const duplicate_declarations = @import("transform/duplicate_declarations.zig");

test {
    _ = pass_manager;
    _ = empty_cleanup;
    _ = duplicate_declarations;
}
