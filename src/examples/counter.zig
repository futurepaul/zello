const std = @import("std");
const zello = @import("../zello.zig");

// App state - lives for the entire program
var counter: i32 = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 400, 300, "Counter Demo", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    // Use vertical layout with all widgets in a column
    ui.beginVstack(.{ .gap = 10, .padding = 20 }) catch return;

    // Display counter - regenerate text every frame!
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "Count: {d}\nTime: {d:.1}s", .{ counter, time }) catch "Count: ???";
    ui.label(text, .{ .size = 32 }) catch {};

    // Buttons to increment/decrement
    if (ui.button("Increment", .{}) catch false) {
        counter += 1;
        std.debug.print("Counter incremented to: {d}\n", .{counter});
    }

    if (ui.button("Decrement", .{}) catch false) {
        counter -= 1;
        std.debug.print("Counter decremented to: {d}\n", .{counter});
    }

    if (ui.button("Reset", .{}) catch false) {
        counter = 0;
        std.debug.print("Counter reset\n", .{});
    }

    ui.endVstack();
}
