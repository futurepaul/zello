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

    if (ui.button("Click Me!", .{}) catch false) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
