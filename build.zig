const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const library_module = b.addModule("zigcss", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zigcss",
        .root_module = executable_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const core_tests = b.addTest(.{
        .root_module = library_module,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const public_api_test_module = b.createModule(.{
        .root_source_file = b.path("tests/public-api/consumer.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_api_test_module.addImport("zigcss", library_module);
    const public_api_tests = b.addTest(.{
        .root_module = public_api_test_module,
    });
    const run_public_api_tests = b.addRunArtifact(public_api_tests);
    const public_api_step = b.step("test-public-api", "Test the external Zig library surface");
    public_api_step.dependOn(&run_public_api_tests.step);

    const audit_test_module = b.addModule("zigcss-audit-regressions", .{
        .root_source_file = b.path("tests/regressions/audit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audit_options = b.addOptions();
    audit_options.addOption([]const u8, "compiler_path", b.getInstallPath(.bin, "zigcss"));
    audit_test_module.addOptions("audit_options", audit_options);

    const audit_tests = b.addTest(.{
        .root_module = audit_test_module,
    });
    const run_audit_tests = b.addRunArtifact(audit_tests);
    run_audit_tests.step.dependOn(b.getInstallStep());

    // This executable exposes verified transforms only to differential tests.
    // It is installed by `zig build test`, never by the normal install step.
    const transform_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/transforms/driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    transform_driver_module.addImport("zigcss", library_module);
    const transform_driver = b.addExecutable(.{
        .name = "zigcss-transform-test-driver",
        .root_module = transform_driver_module,
    });
    const install_transform_driver = b.addInstallArtifact(transform_driver, .{});

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_public_api_tests.step);
    test_step.dependOn(&run_audit_tests.step);
    test_step.dependOn(&install_transform_driver.step);

    const bench_module = b.addModule("zigcss-bench", .{
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "zigcss-bench",
        .root_module = bench_module,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
