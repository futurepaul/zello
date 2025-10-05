const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_host_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Zig sources
    exe.addCSourceFile(.{
        .file = b.path("src/objc/metal_view.m"),
        .flags = &.{
            "-fobjc-arc",
        },
    });

    // Include path for mcore.h
    exe.addIncludePath(b.path("bindings"));
    // Link the Rust staticlib
    exe.addObjectFile(b.path("rust/engine/target/release/libmasonry_core_capi.a"));

    // Apple frameworks
    exe.linkFramework("AppKit");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("Metal");
    exe.linkSystemLibrary("objc");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
