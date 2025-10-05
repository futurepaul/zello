const std = @import("std");
const zello = @import("../zello.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 400, 300, "Hello Zello", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    ui.label("Hello, Zello!", .{ .size = 24 }) catch {};

    if (ui.button("Click Me!", .{}) catch false) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
