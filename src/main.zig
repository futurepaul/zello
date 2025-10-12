// Zello - Main entry point with demo selection
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default to showcase if no args provided
    const demo_name = if (args.len > 1) args[1] else "showcase";

    if (std.mem.eql(u8, demo_name, "hello_world")) {
        const hello = @import("examples/hello_world.zig");
        try hello.main();
    } else if (std.mem.eql(u8, demo_name, "showcase")) {
        const showcase = @import("examples/showcase.zig");
        try showcase.main();
    } else if (std.mem.eql(u8, demo_name, "text-stress")) {
        const text_stress = @import("examples/text_stress_test.zig");
        try text_stress.main();
    } else {
        std.debug.print("Unknown demo: {s}\n\n", .{demo_name});
        std.debug.print("Available demos:\n", .{});
        std.debug.print("  hello_world - Simple hello world with a button\n", .{});
        std.debug.print("  showcase    - Full feature showcase (default)\n", .{});
        std.debug.print("  text-stress - Text rendering stress test with caching stats\n", .{});
        std.debug.print("\nUsage: zig build run -- <demo_name>\n", .{});
        std.debug.print("   or: ./zig-out/bin/zig_host_app <demo_name>\n", .{});
    }
}
