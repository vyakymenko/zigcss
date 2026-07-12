pub const pass_manager = @import("transform/pass_manager.zig");
pub const empty_cleanup = @import("transform/empty_cleanup.zig");
pub const duplicate_declarations = @import("transform/duplicate_declarations.zig");
pub const color_zero_shortening = @import("transform/color_zero_shortening.zig");
pub const math_folding = @import("transform/math_folding.zig");
pub const shorthand_synthesis = @import("transform/shorthand_synthesis.zig");
pub const value_rewrite = @import("transform/value_rewrite.zig");

test {
    _ = pass_manager;
    _ = empty_cleanup;
    _ = duplicate_declarations;
    _ = color_zero_shortening;
    _ = math_folding;
    _ = shorthand_synthesis;
    _ = value_rewrite;
}
