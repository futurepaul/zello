const std = @import("std");
const zello = @import("../zello.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try zello.init(gpa.allocator(), 800, 600, "Scroll Test", onFrame);
    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;

    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    // Main layout
    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    ui.label("Scroll Area Demo", .{ .size = 24 }) catch {};
    ui.label("Scroll with mouse wheel inside the gray box below:", .{}) catch {};

    // Scroll area with lots of content
    ui.beginScrollArea(.{
        .constrain_vertical = false, // Allow content to be taller than viewport
        .height = 300, // Fixed height viewport
    }) catch return;

    ui.beginVstack(.{ .gap = 5, .padding = 15 }) catch return;

    // Add lots of items to demonstrate scrolling
    var i: usize = 0;
    var buf: [64]u8 = undefined; // Move buffer outside loop
    while (i < 50) : (i += 1) {
        const text = std.fmt.bufPrintZ(&buf, "Scrollable Item #{d}", .{i + 1}) catch "Item";
        ui.label(text, .{ .bg_color = .{ 0.2, 0.2, 0.25, 1.0 } }) catch {};
    }

    ui.endVstack();
    ui.endScrollArea();

    ui.label("Content below the scroll area", .{}) catch {};

    ui.endVstack();
}
