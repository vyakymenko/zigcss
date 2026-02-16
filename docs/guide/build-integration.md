# Build Integration

zigcss provides build helpers for seamless integration with Zig's build system. Automatically compile CSS files as part of your build process.

## Setup

### 1. Add zigcss as a Dependency

Add to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zigcss = .{
            .path = "../zigcss",
        },
    },
}
```

### 2. Use Build Helpers in build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigcss_dep = b.dependency("zigcss", .{
        .target = target,
        .optimize = optimize,
    });

    const zigcss_exe = zigcss_dep.artifact("zigcss");
    const zigcss_path = zigcss_dep.path("");

    const build_helpers = @import("build_helpers.zig");
    const build_helpers_path = b.pathJoin(&.{ zigcss_path, "build_helpers.zig" });
    const build_helpers_module = b.createModule(.{
        .root_source_file = b.path(build_helpers_path),
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

    b.installArtifact(exe);
}
```

## Build Helper API

### Creating a CSS Compile Step

```zig
// Create a CSS compilation step
const css_step = build_helpers.addCssCompileStep(
    builder,
    zigcss_exe,
    output_dir,
);

// Or attach to an existing step
const css_step = build_helpers.addCssCompileStepTo(
    builder,
    zigcss_exe,
    output_dir,
    existing_step,
);
```

### Adding Input Files

```zig
// Add a single file
css_step.addInputFile("src/styles.css");

// Add multiple files
css_step.addInputFiles(&.{ "src/styles.css", "src/components.scss" });
```

### Configuration Options

```zig
// Enable/disable optimizations
css_step.setOptimize(true);
css_step.setMinify(true);

// Source maps
css_step.setSourceMap(true);

// Autoprefixer
css_step.setAutoprefix(true);
css_step.addBrowser("last 2 versions");
css_step.addBrowsers(&.{ "last 2 versions", "> 1%" });
```

## Integration with Build Steps

CSS files are automatically compiled when you run `zig build`, and the compiled output is placed in the specified output directory.

### Example: Web Application

```zig
pub fn build(b: *std.Build) void {
    // ... setup ...

    const css_step = build_helpers.addCssCompileStep(
        b,
        zigcss_exe,
        "zig-out/www/css",
    );

    css_step.addInputFiles(&.{
        "src/www/styles.css",
        "src/www/components.scss",
    });
    css_step.setOptimize(true);
    css_step.setMinify(true);

    // CSS compilation happens before web server starts
    const run_step = b.step("run", "Run the web server");
    run_step.dependOn(&css_step.step);
}
```

## Next Steps

- [Quick Start](/guide/quick-start) — Learn the basics
- [API Reference](/api/compile-options) — Learn about compile options
