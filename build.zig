const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_host_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // On macOS, add SDK framework path if SDKROOT is set
    if (target.result.os.tag == .macos) {
        if (std.posix.getenv("SDKROOT")) |sdkroot| {
            const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdkroot});
            exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = frameworks_path });
        }
    }

    // Objective-C sources
    exe.addCSourceFile(.{
        .file = b.path("src/platform/objc/metal_view.m"),
        .flags = &.{
            "-fobjc-arc",
        },
    });

    // Include path for mcore.h
    exe.addIncludePath(b.path("bindings"));
    // Link the Rust staticlib
    exe.addObjectFile(b.path("rust/engine/target/release/libmasonry_core_capi.a"));

    // Apple frameworks
    if (target.result.os.tag == .macos) {
        exe.linkFramework("AppKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Metal");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Color test executable
    const test_colors = b.addExecutable(.{
        .name = "test_colors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_colors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // On macOS, add SDK framework path if SDKROOT is set
    if (target.result.os.tag == .macos) {
        if (std.posix.getenv("SDKROOT")) |sdkroot| {
            const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdkroot});
            test_colors.root_module.addSystemFrameworkPath(.{ .cwd_relative = frameworks_path });
        }
    }

    // Include path for mcore.h
    test_colors.addIncludePath(b.path("bindings"));
    // Link the Rust staticlib
    test_colors.addObjectFile(b.path("rust/engine/target/release/libmasonry_core_capi.a"));

    // Apple frameworks (needed for Rust engine)
    if (target.result.os.tag == .macos) {
        test_colors.linkFramework("AppKit");
        test_colors.linkFramework("QuartzCore");
        test_colors.linkFramework("Metal");
    }

    b.installArtifact(test_colors);

    const test_colors_run = b.addRunArtifact(test_colors);
    const test_colors_step = b.step("test-colors", "Run color API tests");
    test_colors_step.dependOn(&test_colors_run.step);
}
