const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcss_dep = b.dependency("zcss", .{
        .target = target,
        .optimize = optimize,
    });

    const zcss_module = zcss_dep.module("zcss");
    
    const zcss_exe = zcss_dep.artifact("zcss");

    const build_helpers = @import("build_helpers.zig");
    const zcss_path = zcss_dep.path("");

    const build_helpers_module = b.addModule("zcss-build-helpers", .{
        .root_source_file = b.path(b.pathJoin(&.{ zcss_path, "build_helpers.zig" })),
    });

    const css_step = build_helpers.addCssCompileStep(
        b,
        zcss_exe,
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

    exe.root_module.addImport("zcss", zcss_module);

    b.installArtifact(exe);
}
