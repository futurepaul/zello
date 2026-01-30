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

    // On Apple platforms, add SDK paths
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    if (is_apple) {
        if (std.posix.getenv("SDKROOT")) |sdkroot| {
            const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdkroot});
            exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = frameworks_path });

            // For iOS, we need additional system paths
            if (target.result.os.tag == .ios) {
                const system_include_path = b.fmt("{s}/usr/include", .{sdkroot});
                const system_lib_path = b.fmt("{s}/usr/lib", .{sdkroot});
                const private_frameworks_path = b.fmt("{s}/System/Library/PrivateFrameworks", .{sdkroot});
                exe.addSystemIncludePath(.{ .cwd_relative = system_include_path });
                exe.addLibraryPath(.{ .cwd_relative = system_lib_path });
                exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = private_frameworks_path });
            }
        }
    }

    // Objective-C sources (platform-specific)
    if (target.result.os.tag == .ios) {
        // For iOS, use pre-compiled object file (compiled with clang)
        // Device: Run ./compile-ios-objc.sh
        // Simulator: Run ./compile-ios-sim-objc.sh (with IOS_SIMULATOR=1)
        const objc_path = if (std.posix.getenv("IOS_SIMULATOR")) |_|
            ".zig-cache/ios-sim-objc/metal_view_ios.o"
        else
            ".zig-cache/ios-objc/metal_view_ios.o";
        exe.addObjectFile(b.path(objc_path));
    } else {
        // For macOS, compile directly
        exe.addCSourceFile(.{
            .file = b.path("src/platform/objc/metal_view.m"),
            .flags = &.{
                "-fobjc-arc",
            },
        });
    }

    // Include path for mcore.h
    exe.addIncludePath(b.path("bindings"));
    // Link the Rust staticlib (platform-specific path)
    const rust_lib_path = if (target.result.os.tag == .ios) blk: {
        // For simulator, use patched library (see build-simulator-working.sh)
        if (std.posix.getenv("IOS_SIMULATOR")) |_| {
            // Use pre-patched library (platform tag removed for Zig linker compatibility)
            break :blk ".zig-cache/ios-sim-objc/libmasonry_core_capi_patched.a";
        } else {
            // Device build
            break :blk "rust/engine/target/aarch64-apple-ios/release/libmasonry_core_capi.a";
        }
    } else "rust/engine/target/release/libmasonry_core_capi.a";
    exe.addObjectFile(b.path(rust_lib_path));

    // Apple frameworks (platform-specific)
    if (target.result.os.tag == .macos) {
        exe.linkFramework("AppKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Metal");
    } else if (target.result.os.tag == .ios) {
        exe.linkFramework("UIKit");
        exe.linkFramework("Foundation");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("CoreGraphics");
        exe.linkFramework("CoreText");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Metal");
        exe.linkSystemLibrary("objc");
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

    // On Apple platforms, add SDK paths
    if (is_apple) {
        if (std.posix.getenv("SDKROOT")) |sdkroot| {
            const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdkroot});
            test_colors.root_module.addSystemFrameworkPath(.{ .cwd_relative = frameworks_path });

            // For iOS, we need additional system paths
            if (target.result.os.tag == .ios) {
                const system_include_path = b.fmt("{s}/usr/include", .{sdkroot});
                const system_lib_path = b.fmt("{s}/usr/lib", .{sdkroot});
                const private_frameworks_path = b.fmt("{s}/System/Library/PrivateFrameworks", .{sdkroot});
                test_colors.addSystemIncludePath(.{ .cwd_relative = system_include_path });
                test_colors.addLibraryPath(.{ .cwd_relative = system_lib_path });
                test_colors.root_module.addSystemFrameworkPath(.{ .cwd_relative = private_frameworks_path });
            }
        }
    }

    // Include path for mcore.h
    test_colors.addIncludePath(b.path("bindings"));
    // Link the Rust staticlib (use same path as main exe)
    test_colors.addObjectFile(b.path(rust_lib_path));

    // Apple frameworks (platform-specific)
    if (target.result.os.tag == .macos) {
        test_colors.linkFramework("AppKit");
        test_colors.linkFramework("QuartzCore");
        test_colors.linkFramework("Metal");
    } else if (target.result.os.tag == .ios) {
        test_colors.linkFramework("UIKit");
        test_colors.linkFramework("Foundation");
        test_colors.linkFramework("CoreFoundation");
        test_colors.linkFramework("CoreGraphics");
        test_colors.linkFramework("CoreText");
        test_colors.linkFramework("QuartzCore");
        test_colors.linkFramework("Metal");
        test_colors.linkSystemLibrary("objc");
    }

    b.installArtifact(test_colors);

    const test_colors_run = b.addRunArtifact(test_colors);
    const test_colors_step = b.step("test-colors", "Run color API tests");
    test_colors_step.dependOn(&test_colors_run.step);
}
