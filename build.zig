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

    const core_protocol_test_module = b.createModule(.{
        .root_source_file = b.path("src/core_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_protocol_test_module.addImport("zigcss", library_module);
    const core_protocol_tests = b.addTest(.{ .root_module = core_protocol_test_module });
    const run_core_protocol_tests = b.addRunArtifact(core_protocol_tests);

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

    const lsp_index_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp_index.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_index_test_module.addImport("zigcss", library_module);
    const lsp_index_tests = b.addTest(.{ .root_module = lsp_index_test_module });
    const run_lsp_index_tests = b.addRunArtifact(lsp_index_tests);

    const core_tests = b.addTest(.{
        .root_module = library_module,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const native_preprocessor_module = b.createModule(.{
        .root_source_file = b.path("src/preprocessor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_preprocessor_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_preprocessor_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_preprocessor_tests = b.addTest(.{
        .root_module = native_preprocessor_test_module,
    });
    const run_native_preprocessor_tests = b.addRunArtifact(native_preprocessor_tests);
    const native_foundation_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_foundation_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_foundation_tests = b.addTest(.{
        .root_module = native_foundation_test_module,
    });
    const run_native_foundation_tests = b.addRunArtifact(native_foundation_tests);
    const native_resolver_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_resolver_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_resolver_tests = b.addTest(.{
        .root_module = native_resolver_test_module,
    });
    const run_native_resolver_tests = b.addRunArtifact(native_resolver_tests);
    const native_evaluator_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/evaluator.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_evaluator_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_evaluator_tests = b.addTest(.{
        .root_module = native_evaluator_test_module,
    });
    const run_native_evaluator_tests = b.addRunArtifact(native_evaluator_tests);
    const native_sass_parser_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_parser_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_parser_tests = b.addTest(.{
        .root_module = native_sass_parser_test_module,
    });
    const run_native_sass_parser_tests = b.addRunArtifact(native_sass_parser_tests);
    run_native_sass_parser_tests.setCwd(b.path("."));
    const native_sass_arguments_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_arguments.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_arguments_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_arguments_tests = b.addTest(.{
        .root_module = native_sass_arguments_test_module,
    });
    const run_native_sass_arguments_tests = b.addRunArtifact(native_sass_arguments_tests);
    const native_sass_numeric_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_numeric.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_numeric_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_numeric_tests = b.addTest(.{
        .root_module = native_sass_numeric_test_module,
    });
    const run_native_sass_numeric_tests = b.addRunArtifact(native_sass_numeric_tests);
    const native_sass_color_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_color.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_color_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_color_tests = b.addTest(.{
        .root_module = native_sass_color_test_module,
    });
    const run_native_sass_color_tests = b.addRunArtifact(native_sass_color_tests);
    const native_sass_string_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_string.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_string_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_string_tests = b.addTest(.{
        .root_module = native_sass_string_test_module,
    });
    const run_native_sass_string_tests = b.addRunArtifact(native_sass_string_tests);
    const native_sass_evaluator_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native-preprocessor/sass_evaluator.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_sass_evaluator_test_module.addImport("native_preprocessor", native_preprocessor_module);
    const native_sass_evaluator_tests = b.addTest(.{
        .root_module = native_sass_evaluator_test_module,
    });
    const run_native_sass_evaluator_tests = b.addRunArtifact(native_sass_evaluator_tests);
    run_native_sass_evaluator_tests.setCwd(b.path("."));
    const native_preprocessor_test_step = b.step(
        "test-native-preprocessor",
        "Test the internal self-contained stylesheet frontend implementation",
    );
    native_preprocessor_test_step.dependOn(&run_native_preprocessor_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_foundation_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_resolver_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_evaluator_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_parser_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_arguments_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_numeric_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_color_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_string_tests.step);
    native_preprocessor_test_step.dependOn(&run_native_sass_evaluator_tests.step);

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
    const run_public_api_example = b.addRunArtifact(public_api_example);
    run_public_api_example.expectStdOutEqual(".notice{color:red}");

    const css_modules_example_module = b.createModule(.{
        .root_source_file = b.path("examples/css_modules.zig"),
        .target = target,
        .optimize = optimize,
    });
    css_modules_example_module.addImport("zigcss", library_module);
    const css_modules_example = b.addExecutable(.{
        .name = "zigcss-css-modules-example",
        .root_module = css_modules_example_module,
    });
    const run_css_modules_example = b.addRunArtifact(css_modules_example);
    run_css_modules_example.expectStdOutEqual("");

    const documentation_examples_step = b.step(
        "test-documentation-examples",
        "Compile and run published Zig documentation examples",
    );
    documentation_examples_step.dependOn(&run_public_api_example.step);
    documentation_examples_step.dependOn(&run_css_modules_example.step);

    const public_api_step = b.step("test-public-api", "Test the external Zig library surface");
    public_api_step.dependOn(&run_public_api_tests.step);
    public_api_step.dependOn(documentation_examples_step);

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
    test_step.dependOn(&run_core_protocol_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
    test_step.dependOn(&run_lsp_transport_tests.step);
    test_step.dependOn(&run_lsp_position_tests.step);
    test_step.dependOn(&run_lsp_index_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_native_preprocessor_tests.step);
    test_step.dependOn(&run_native_foundation_tests.step);
    test_step.dependOn(&run_native_resolver_tests.step);
    test_step.dependOn(&run_native_evaluator_tests.step);
    test_step.dependOn(&run_native_sass_parser_tests.step);
    test_step.dependOn(&run_native_sass_arguments_tests.step);
    test_step.dependOn(&run_native_sass_numeric_tests.step);
    test_step.dependOn(&run_native_sass_color_tests.step);
    test_step.dependOn(&run_native_sass_string_tests.step);
    test_step.dependOn(&run_native_sass_evaluator_tests.step);
    test_step.dependOn(&run_public_api_tests.step);
    test_step.dependOn(documentation_examples_step);
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
    bench_module.addAnonymousImport("benchmark-small-css", .{
        .root_source_file = b.path("benchmarks/corpora/v1/small.css"),
    });
    bench_module.addAnonymousImport("benchmark-medium-css", .{
        .root_source_file = b.path("benchmarks/corpora/v1/medium.css"),
    });
    bench_module.addAnonymousImport("benchmark-large-css", .{
        .root_source_file = b.path("benchmarks/corpora/v1/large.css"),
    });
    bench_module.addImport("zigcss", library_module);

    const bench_exe = b.addExecutable(.{
        .name = "zigcss-bench",
        .root_module = bench_module,
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    const install_bench_step = b.step(
        "install-benchmark-runner",
        "Install the private benchmark measurement runner",
    );
    install_bench_step.dependOn(&install_bench.step);
    const bench_tests = b.addTest(.{ .root_module = bench_module });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Smoke separated validated benchmark modes");
    bench_step.dependOn(&run_bench.step);
}
