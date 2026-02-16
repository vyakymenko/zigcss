const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigcss_dep = b.dependency("zigcss", .{
        .target = target,
        .optimize = optimize,
    });

    const zigcss_module = zigcss_dep.module("zigcss");
    
    const zigcss_exe = zigcss_dep.artifact("zigcss");

    const build_helpers = @import("build_helpers.zig");
    const zigcss_path = zigcss_dep.path("");

    const build_helpers_module = b.addModule("zigcss-build-helpers", .{
        .root_source_file = b.path(b.pathJoin(&.{ zigcss_path, "build_helpers.zig" })),
    });

    const css_step = build_helpers.addCssCompileStep(
        b,
        zigcss_exe,
        "zig-out/css",
    );

    css_step.addInputFile("src/styles.css");
    css_step.addInputFile("src/components.scss");
    css_step.setOptimize(true);
    css_step.setMinify(true);
    css_step.setAutoprefix(true);
    css_step.addBrowsers(&.{ "last 2 versions", "> 1%" });

    const install_step = b.getInstallStep();
    install_step.dependOn(&css_step.step);

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zigcss", zigcss_module);

    b.installArtifact(exe);
}
