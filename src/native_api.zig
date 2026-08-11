//! Pre-graduation Zig API route for the self-contained stylesheet frontends.
//!
//! This explicit experimental namespace does not graduate a public language
//! row or authorize CLI, JavaScript, package, documentation, or release claims.
//! It currently returns owned CSS only; diagnostics, dependencies, and source
//! maps remain behind their separately declared NATIVE-006 routing gates.

const std = @import("std");
const native_compiler = @import("preprocessor/compiler.zig");
const native_resolver = @import("preprocessor/resolver.zig");

pub const max_entry_input_bytes: usize = 10 * 1024 * 1024;

pub const Syntax = enum {
    scss,
    sass,
    less,
    stylus,
};

pub const OutputFormat = enum {
    pretty,
    minified,
};

pub const Options = struct {
    syntax: Syntax,
    /// Borrowed canonical directory capabilities for this compilation only.
    root_paths: []const []const u8,
    format: OutputFormat = .pretty,
    /// Applies to the already-loaded entry bytes. Imported resources retain
    /// the shared resolver and language evaluator ceilings.
    max_input_bytes: usize = max_entry_input_bytes,
};

pub const Error = std.mem.Allocator.Error || error{
    CompilationFailed,
    InvalidOptions,
    InvalidRoot,
    InvalidSourcePath,
    PathEscape,
    ResourceLimitExceeded,
};

/// Move-only by convention. The CSS remains owned independently of all native
/// parser, resolver, source-table, and evaluation transaction lifetimes.
pub const CompileResult = struct {
    result_allocator: std.mem.Allocator,
    css: []const u8,

    pub fn take(self: *CompileResult) CompileResult {
        const moved = self.*;
        self.* = empty(self.result_allocator);
        return moved;
    }

    pub fn deinit(self: *CompileResult) void {
        const allocator = self.result_allocator;
        if (self.css.len > 0) allocator.free(self.css);
        self.* = empty(allocator);
    }

    fn empty(allocator: std.mem.Allocator) CompileResult {
        return .{ .result_allocator = allocator, .css = &.{} };
    }
};

/// Compiles already-loaded source bytes through the single shared native
/// compiler. `entry_path` must be an absolute path lexically contained by one
/// of `root_paths`; the entry need not be read from the filesystem.
pub fn compile(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    input: []const u8,
    options: Options,
) Error!CompileResult {
    if (options.max_input_bytes == 0 or
        options.max_input_bytes > max_entry_input_bytes)
    {
        return error.InvalidOptions;
    }
    if (input.len > options.max_input_bytes) return error.ResourceLimitExceeded;

    const entry_url = native_resolver.pathToFileUrl(allocator, entry_path) catch |err|
        return mapPathError(err);
    defer allocator.free(entry_url);

    var compiled = native_compiler.compile(allocator, entry_url, input, .{
        .syntax = switch (options.syntax) {
            .scss => .scss,
            .sass => .sass,
            .less => .less,
            .stylus => .stylus,
        },
        .root_paths = options.root_paths,
        .format = switch (options.format) {
            .pretty => .pretty,
            .minified => .minified,
        },
        .source_map = false,
        .limits = .{
            .sass_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .less_evaluator = .{ .max_source_bytes = options.max_input_bytes },
            .stylus_parser = .{ .lexer = .{ .max_input_bytes = options.max_input_bytes } },
            .stylus_evaluator = .{ .max_source_bytes = options.max_input_bytes },
        },
    }) catch |err| return mapCompileError(err);
    defer compiled.deinit();

    const css = try allocator.dupe(u8, compiled.css());
    return .{ .result_allocator = allocator, .css = css };
}

fn mapPathError(err: native_resolver.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSourcePath,
    };
}

fn mapCompileError(err: native_compiler.Error) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.InvalidRoot) return error.InvalidRoot;
    if (err == error.PathEscape) return error.PathEscape;
    if (err == error.InvalidLimits) return error.InvalidOptions;
    const name = @errorName(err);
    if (std.mem.endsWith(u8, name, "LimitExceeded") or
        std.mem.eql(u8, name, "SourceTooLarge"))
    {
        return error.ResourceLimitExceeded;
    }
    return error.CompilationFailed;
}
