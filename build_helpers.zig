const std = @import("std");
const Build = std.Build;

pub const CssCompileStep = struct {
    step: Build.Step,
    builder: *Build,
    zcss_exe: *Build.Step.Compile,
    input_files: std.ArrayList([]const u8),
    output_dir: []const u8,
    optimize: bool,
    minify: bool,
    source_map: bool,
    autoprefix: bool,
    browsers: std.ArrayList([]const u8),

    pub fn init(
        builder: *Build,
        zcss_exe: *Build.Step.Compile,
        output_dir: []const u8,
    ) *CssCompileStep {
        const self = builder.allocator.create(CssCompileStep) catch @panic("OOM");
        self.* = .{
            .step = Build.Step.init(.{
                .id = .custom,
                .name = "compile-css",
                .owner = builder,
                .makeFn = make,
            }),
            .builder = builder,
            .zcss_exe = zcss_exe,
            .input_files = std.ArrayList([]const u8).init(builder.allocator),
            .output_dir = output_dir,
            .optimize = false,
            .minify = false,
            .source_map = false,
            .autoprefix = false,
            .browsers = std.ArrayList([]const u8).init(builder.allocator),
        };
        return self;
    }

    pub fn addInputFile(self: *CssCompileStep, file: []const u8) void {
        self.input_files.append(self.builder.allocator, file) catch @panic("OOM");
    }

    pub fn addInputFiles(self: *CssCompileStep, files: []const []const u8) void {
        for (files) |file| {
            self.addInputFile(file);
        }
    }

    pub fn setOptimize(self: *CssCompileStep, optimize: bool) void {
        self.optimize = optimize;
    }

    pub fn setMinify(self: *CssCompileStep, minify: bool) void {
        self.minify = minify;
    }

    pub fn setSourceMap(self: *CssCompileStep, source_map: bool) void {
        self.source_map = source_map;
    }

    pub fn setAutoprefix(self: *CssCompileStep, autoprefix: bool) void {
        self.autoprefix = autoprefix;
    }

    pub fn addBrowser(self: *CssCompileStep, browser: []const u8) void {
        self.browsers.append(self.builder.allocator, browser) catch @panic("OOM");
    }

    pub fn addBrowsers(self: *CssCompileStep, browsers: []const []const u8) void {
        for (browsers) |browser| {
            self.addBrowser(browser);
        }
    }

    fn make(step: *Build.Step, progress: *std.Progress.Node) !void {
        _ = progress;
        const self = @fieldParentPtr(CssCompileStep, "step", step);

        const run_cmd = self.builder.addRunArtifact(self.zcss_exe);
        run_cmd.step.dependOn(&self.zcss_exe.step);

        if (self.input_files.items.len == 0) {
            return error.NoInputFiles;
        }

        for (self.input_files.items) |input_file| {
            run_cmd.addArg(input_file);
        }

        if (self.output_dir.len > 0) {
            run_cmd.addArg("-o");
            run_cmd.addArg(self.output_dir);
            run_cmd.addArg("--output-dir");
        }

        if (self.optimize) {
            run_cmd.addArg("--optimize");
        }

        if (self.minify) {
            run_cmd.addArg("--minify");
        }

        if (self.source_map) {
            run_cmd.addArg("--source-map");
        }

        if (self.autoprefix) {
            run_cmd.addArg("--autoprefix");
            if (self.browsers.items.len > 0) {
                run_cmd.addArg("--browsers");
                var browsers_str = std.ArrayList(u8).init(self.builder.allocator);
                defer browsers_str.deinit();
                for (self.browsers.items, 0..) |browser, i| {
                    if (i > 0) {
                        browsers_str.appendSlice(self.builder.allocator, ",") catch @panic("OOM");
                    }
                    browsers_str.appendSlice(self.builder.allocator, browser) catch @panic("OOM");
                }
                run_cmd.addArg(browsers_str.items);
            }
        }

        try run_cmd.step.make(step, progress);
    }
};

pub fn addCssCompileStep(
    builder: *Build,
    zcss_exe: *Build.Step.Compile,
    output_dir: []const u8,
) *CssCompileStep {
    return CssCompileStep.init(builder, zcss_exe, output_dir);
}

pub fn addCssCompileStepTo(
    builder: *Build,
    zcss_exe: *Build.Step.Compile,
    output_dir: []const u8,
    step: *Build.Step,
) *CssCompileStep {
    const css_step = addCssCompileStep(builder, zcss_exe, output_dir);
    step.dependOn(&css_step.step);
    return css_step;
}
