const std = @import("std");
const zello = @import("../zello.zig");
const color = @import("../ui/color.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 600, 400, "Hello Zello - Padding Test", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;
    ui.beginFrame();
    defer ui.endFrame(color.WHITE) catch {};

    // Enable debug bounds to see padding
    ui.setDebugBounds(true);

    std.debug.print("\n=== FRAME START ===\n", .{});
    std.debug.print("Window size: {}x{}\n", .{ ui.width, ui.height });

    // Root vstack with 60px padding to make the issue obvious
    ui.beginVstack(.{ .gap = 20, .padding = 60 }) catch return;
    std.debug.print("Root vstack: padding=60\n", .{});

    ui.label("Root vstack with 60px padding", .{ .size = 20, .color = color.BLACK }) catch {};

    // Nested hstack to test the measurement issue
    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;
    std.debug.print("  Nested hstack: padding=10\n", .{});

    ui.label("Left", .{ .bg_color = color.rgba(1, 0, 0, 0.3), .color = color.BLACK }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Middle", .{ .bg_color = color.rgba(0, 1, 0, 0.3), .color = color.BLACK }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Right", .{ .bg_color = color.rgba(0, 0, 1, 0.3), .color = color.BLACK }) catch {};

    ui.endHstack();

    ui.label("Text should stay within yellow bounds", .{ .size = 16, .color = color.BLACK }) catch {};

    ui.endVstack();
}
