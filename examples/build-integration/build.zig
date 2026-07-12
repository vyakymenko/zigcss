const std = @import("std");
const zigcss_build = @import("zigcss");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigcss_target = b.dependency("zigcss", .{
        .target = target,
        .optimize = optimize,
    });
    const zigcss_host = b.dependency("zigcss", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });

    const app_module = exampleModule(b, target, optimize);
    app_module.addImport("zigcss", zigcss_target.module("zigcss"));
    const app = b.addExecutable(.{
        .name = "zigcss-build-example",
        .root_module = app_module,
    });
    b.installArtifact(app);

    const css = zigcss_build.helpers.addCssCompile(
        b,
        zigcss_host.artifact("zigcss"),
        .{
            .input = b.path("styles.css"),
            .output_name = "example.css",
            .optimize = true,
            .minify = true,
        },
    );
    const check_css = b.addCheckFile(css.getOutput(), .{
        .expected_exact = ".example{width:3px;color:#fff}",
    });
    check_css.setName("verify example CSS output");
    const install_css = b.addInstallFile(
        css.getOutput(),
        "share/zigcss-build-example/example.css",
    );
    b.getInstallStep().dependOn(&install_css.step);

    const test_module = exampleModule(b, target, optimize);
    test_module.addImport("zigcss", zigcss_target.module("zigcss"));
    const app_tests = b.addTest(.{ .root_module = test_module });
    const run_app_tests = b.addRunArtifact(app_tests);
    const test_step = b.step("test", "Compile and test every integration output");
    test_step.dependOn(&app.step);
    test_step.dependOn(&check_css.step);
    test_step.dependOn(&run_app_tests.step);
}

fn exampleModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
}
