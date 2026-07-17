//! Internal self-contained stylesheet frontend foundation.
//!
//! Nothing in this module is part of the public ZigCSS API until the native
//! language rows graduate through the Milestone 10 compatibility gates.

pub const lexer = @import("preprocessor/lexer.zig");
pub const source = @import("preprocessor/source.zig");
pub const syntax = @import("preprocessor/syntax.zig");
pub const value = @import("preprocessor/value.zig");
pub const environment = @import("preprocessor/environment.zig");
pub const budget = @import("preprocessor/budget.zig");
pub const diagnostics = @import("preprocessor/diagnostics.zig");
pub const sourcemap = @import("preprocessor/sourcemap.zig");

test {
    _ = lexer;
    _ = source;
    _ = syntax;
    _ = value;
    _ = environment;
    _ = budget;
    _ = diagnostics;
    _ = sourcemap;
}
