const std = @import("std");

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

    const test_step = b.step("test", "Test ZigCSS through a package dependency");
    test_step.dependOn(&run_consumer_tests.step);
}
