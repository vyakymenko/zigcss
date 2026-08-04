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
pub const resolver = @import("preprocessor/resolver.zig");
pub const evaluator = @import("preprocessor/evaluator.zig");
pub const sass = @import("preprocessor/sass.zig");
pub const less = @import("preprocessor/less.zig");
pub const stylus = @import("preprocessor/stylus.zig");
pub const less_evaluator = @import("preprocessor/less_evaluator.zig");
pub const sass_arguments = @import("preprocessor/sass_arguments.zig");
pub const sass_numeric = @import("preprocessor/sass_numeric.zig");
pub const sass_color = @import("preprocessor/sass_color.zig");
pub const sass_selector = @import("preprocessor/sass_selector.zig");
pub const sass_string = @import("preprocessor/sass_string.zig");
pub const sass_evaluator = @import("preprocessor/sass_evaluator.zig");

test {
    _ = lexer;
    _ = source;
    _ = syntax;
    _ = value;
    _ = environment;
    _ = budget;
    _ = diagnostics;
    _ = sourcemap;
    _ = resolver;
    _ = evaluator;
    _ = sass;
    _ = less;
    _ = stylus;
    _ = less_evaluator;
    _ = sass_arguments;
    _ = sass_numeric;
    _ = sass_color;
    _ = sass_string;
    _ = sass_evaluator;
}
