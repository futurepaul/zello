const std = @import("std");
const zello = @import("../zello.zig");

// Static buffers for item labels (persists across frames)
var item_labels: [50][64:0]u8 = undefined;
var labels_initialized: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try zello.init(gpa.allocator(), 800, 600, "Scroll Test", onFrame);
    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;

    // Initialize labels once
    if (!labels_initialized) {
        for (0..50) |i| {
            _ = std.fmt.bufPrintZ(&item_labels[i], "Scrollable Item #{d}", .{i + 1}) catch {};
        }
        labels_initialized = true;
    }

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
    for (0..50) |i| {
        const text: [:0]const u8 = std.mem.sliceTo(&item_labels[i], 0);
        ui.label(text, .{ .bg_color = .{ 0.2, 0.2, 0.25, 1.0 } }) catch {};
    }

    ui.endVstack();
    ui.endScrollArea();

    ui.label("Content below the scroll area", .{}) catch {};

    ui.endVstack();
}
