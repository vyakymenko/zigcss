const std = @import("std");
pub const helpers = @import("build_helpers.zig");

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
    executable_module.addImport("zigcss", library_module);

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
    test_module.addImport("zigcss", library_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const lsp_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_test_module.addImport("zigcss", library_module);
    const lsp_tests = b.addTest(.{ .root_module = lsp_test_module });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const lsp_transport_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_transport_tests = b.addTest(.{ .root_module = lsp_transport_test_module });
    const run_lsp_transport_tests = b.addRunArtifact(lsp_transport_tests);

    const lsp_position_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp_position.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_position_tests = b.addTest(.{ .root_module = lsp_position_test_module });
    const run_lsp_position_tests = b.addRunArtifact(lsp_position_tests);

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
    const public_api_example_module = b.createModule(.{
        .root_source_file = b.path("examples/public_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_api_example_module.addImport("zigcss", library_module);
    const public_api_example = b.addExecutable(.{
        .name = "zigcss-public-api-example",
        .root_module = public_api_example_module,
    });
    const public_api_step = b.step("test-public-api", "Test the external Zig library surface");
    public_api_step.dependOn(&run_public_api_tests.step);
    public_api_step.dependOn(&public_api_example.step);

    const audit_test_module = b.addModule("zigcss-audit-regressions", .{
        .root_source_file = b.path("tests/regressions/audit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audit_options = b.addOptions();
    audit_options.addOption([]const u8, "compiler_path", b.getInstallPath(.bin, "zigcss"));
    audit_test_module.addOptions("audit_options", audit_options);
    audit_test_module.addImport("zigcss", library_module);

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

    // This executable exposes the public CSS Modules result only to the
    // independent format oracle. It is installed by `zig build test`, never by
    // the normal install step or recovery CLI.
    const css_modules_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/formats/css_modules_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    css_modules_driver_module.addImport("zigcss", library_module);
    const css_modules_driver = b.addExecutable(.{
        .name = "zigcss-css-modules-test-driver",
        .root_module = css_modules_driver_module,
    });
    const install_css_modules_driver = b.addInstallArtifact(css_modules_driver, .{});

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
    test_step.dependOn(&run_lsp_transport_tests.step);
    test_step.dependOn(&run_lsp_position_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_public_api_tests.step);
    test_step.dependOn(&public_api_example.step);
    test_step.dependOn(&run_audit_tests.step);
    test_step.dependOn(&install_transform_driver.step);
    test_step.dependOn(&install_css_modules_driver.step);

    const helper_compilation = helpers.addCssCompile(b, exe, .{
        .input = b.path("tests/build-helpers/input.css"),
        .output_name = "build-helper.css",
        .optimize = true,
        .minify = true,
    });
    const check_helper_output = b.addCheckFile(helper_compilation.getOutput(), .{
        .expected_exact = ".card{width:3px;color:#fff}",
    });
    check_helper_output.setName("verify build-helper CSS output");
    const helper_test_module = b.createModule(.{
        .root_source_file = b.path("build_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const helper_unit_tests = b.addTest(.{ .root_module = helper_test_module });
    const run_helper_unit_tests = b.addRunArtifact(helper_unit_tests);
    const helper_test_step = b.step(
        "test-build-helpers",
        "Test declared ZigCSS build inputs and outputs",
    );
    helper_test_step.dependOn(&check_helper_output.step);
    helper_test_step.dependOn(&run_helper_unit_tests.step);
    test_step.dependOn(&check_helper_output.step);
    test_step.dependOn(&run_helper_unit_tests.step);

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
