const std = @import("std");
const zigcss_build = @import("zigcss");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigcss = b.dependency("zigcss", .{
        .target = target,
        .optimize = optimize,
    });

    const consumer_module = b.createModule(.{
        .root_source_file = b.path("consumer.zig"),
        .target = target,
        .optimize = optimize,
    });
    consumer_module.addImport("zigcss", zigcss.module("zigcss"));
    const consumer_tests = b.addTest(.{ .root_module = consumer_module });
    const run_consumer_tests = b.addRunArtifact(consumer_tests);

    const css = zigcss_build.helpers.addCssCompile(b, zigcss.artifact("zigcss"), .{
        .input = b.path("input.css"),
        .output_name = "package-helper.css",
        .optimize = true,
        .minify = true,
    });
    const check_css = b.addCheckFile(css.getOutput(), .{
        .expected_exact = ".consumer-helper{color:red}",
    });
    check_css.setName("verify package build-helper CSS output");

    const test_step = b.step("test", "Test ZigCSS through a package dependency");
    test_step.dependOn(&run_consumer_tests.step);
    test_step.dependOn(&check_css.step);
}
