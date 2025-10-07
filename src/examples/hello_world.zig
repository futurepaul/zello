const std = @import("std");
const zello = @import("../zello.zig");
const color = @import("../ui/color.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 600, 400, "Hello Zello", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(color.WHITE) catch {};

    // Simple example with some padding
    ui.beginVstack(.{ .gap = 20, .padding = 40 }) catch return;

    ui.label("Hello, Zello!", .{ .size = 24, .color = color.BLACK }) catch {};

    // Nested hstack with spacers
    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;

    ui.label("Left", .{ .bg_color = color.rgba(1, 0, 0, 0.3), .color = color.BLACK }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Middle", .{ .bg_color = color.rgba(0, 1, 0, 0.3), .color = color.BLACK }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Right", .{ .bg_color = color.rgba(0, 0, 1, 0.3), .color = color.BLACK }) catch {};

    ui.endHstack();

    if (ui.button("Click Me!", .{}) catch false) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
