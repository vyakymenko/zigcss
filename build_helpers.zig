const std = @import("std");
const Build = std.Build;

pub const max_output_name_bytes: usize = 128;

/// One cacheable CSS compiler invocation. The input is a declared `LazyPath`
/// and `output_name` is a portable basename used for the generated `LazyPath`.
/// The executable must be runnable on the build host.
pub const CompileOptions = struct {
    input: Build.LazyPath,
    output_name: []const u8,
    optimize: bool = false,
    minify: bool = false,
};

/// A configured run step plus its declared generated CSS file. Downstream
/// build steps should consume `output` rather than guessing a cache path.
pub const CssCompile = struct {
    step_handle: *Build.Step,
    output: Build.LazyPath,

    pub fn step(self: CssCompile) *Build.Step {
        return self.step_handle;
    }

    pub fn getOutput(self: CssCompile) Build.LazyPath {
        return self.output;
    }
};

pub fn addCssCompile(
    b: *Build,
    zigcss_exe: *Build.Step.Compile,
    options: CompileOptions,
) CssCompile {
    if (!isValidOutputName(options.output_name)) {
        std.debug.panic(
            "ZigCSS output_name must be a portable .css basename of at most {d} bytes, got '{s}'",
            .{ max_output_name_bytes, options.output_name },
        );
    }

    const run = b.addRunArtifact(zigcss_exe);
    run.setName(b.fmt("compile CSS ({s})", .{options.output_name}));
    run.stdio_limit = .limited(1024 * 1024);
    run.addFileArg(options.input);
    run.addArg("-o");
    const output = run.addOutputFileArg(options.output_name);
    if (options.optimize) run.addArg("--optimize");
    if (options.minify) run.addArg("--minify");
    return .{ .step_handle = &run.step, .output = output };
}

pub fn addCssCompileTo(
    b: *Build,
    zigcss_exe: *Build.Step.Compile,
    options: CompileOptions,
    parent: *Build.Step,
) CssCompile {
    const compilation = addCssCompile(b, zigcss_exe, options);
    parent.dependOn(compilation.step());
    return compilation;
}

pub fn isValidOutputName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_output_name_bytes) return false;
    if (!std.mem.endsWith(u8, name, ".css")) return false;
    if (std.mem.eql(u8, name, ".css")) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_')) {
            return false;
        }
    }
    return true;
}

test "generated CSS output names are portable bounded basenames" {
    const valid = [_][]const u8{
        "app.css",
        "app.min.css",
        "theme-dark_2.css",
    };
    for (valid) |name| try std.testing.expect(isValidOutputName(name));

    const invalid = [_][]const u8{
        "",
        ".css",
        "app.CSS",
        "app.css.map",
        "nested/app.css",
        "nested\\app.css",
        "../app.css",
        "app style.css",
        "app\x00.css",
        "é.css",
    };
    for (invalid) |name| try std.testing.expect(!isValidOutputName(name));

    var too_long = [_]u8{'a'} ** (max_output_name_bytes + 1);
    @memcpy(too_long[too_long.len - 4 ..], ".css");
    try std.testing.expect(!isValidOutputName(&too_long));
}
