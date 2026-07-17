//! Internal self-contained stylesheet frontend foundation.
//!
//! Nothing in this module is part of the public ZigCSS API until the native
//! language rows graduate through the Milestone 10 compatibility gates.

pub const lexer = @import("preprocessor/lexer.zig");

test {
    _ = lexer;
}
