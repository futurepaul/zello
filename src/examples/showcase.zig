const std = @import("std");
const zello = @import("../zello.zig");

// App state
var debug_bounds: bool = false;
var counter: i32 = 0;
var text_buf1: [256]u8 = undefined;
var text_buf2: [256]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize text buffers
    @memset(&text_buf1, 0);
    @memset(&text_buf2, 0);
    const msg1 = "Type here...";
    const msg2 = "Or here...";
    @memcpy(text_buf1[0..msg1.len], msg1);
    @memcpy(text_buf2[0..msg2.len], msg2);

    var app = try zello.init(gpa.allocator(), 1000, 600, "Zello Showcase - All Features", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, _: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.15, 0.15, 0.20, 1.0 }) catch {};

    ui.beginHstack(.{ .gap = 15, .padding = 20 }) catch return;

    // Section 1: Colored labels
    ui.label("Red", .{ .color = .{ 1, 1, 1, 1 }, .bg_color = .{ 0.8, 0.3, 0.3, 1 }, .padding = 12 }) catch {};
    ui.label("Green", .{ .color = .{ 1, 1, 1, 1 }, .bg_color = .{ 0.3, 0.8, 0.3, 1 }, .padding = 12 }) catch {};
    ui.label("Blue", .{ .color = .{ 1, 1, 1, 1 }, .bg_color = .{ 0.3, 0.3, 0.8, 1 }, .padding = 12 }) catch {};

    // Flex spacer - takes up remaining space
    ui.spacer(1.0) catch {};

    // Section 2: Interactive buttons
    if (ui.button("Button 1", .{}) catch false) {
        std.debug.print("Button 1 clicked!\n", .{});
    }

    if (ui.button("Button 2", .{}) catch false) {
        std.debug.print("Button 2 clicked!\n", .{});
    }

    if (ui.button("Button 3", .{}) catch false) {
        std.debug.print("Button 3 clicked!\n", .{});
    }

    // Flex spacer
    ui.spacer(1.0) catch {};

    // Section 3: Counter
    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrintZ(&counter_buf, "Count: {d}", .{counter}) catch "0";
    ui.label(counter_text, .{ .size = 20 }) catch {};

    if (ui.button("+", .{}) catch false) {
        counter += 1;
    }

    if (ui.button("-", .{}) catch false) {
        counter -= 1;
    }

    // Flex spacer
    ui.spacer(0.5) catch {};

    // Section 4: Text inputs
    _ = ui.textInput("input1", &text_buf1, .{ .width = 150 }) catch {};
    _ = ui.textInput("input2", &text_buf2, .{ .width = 150 }) catch {};

    // Flex spacer
    ui.spacer(0.5) catch {};

    // Section 5: Debug toggle
    const debug_label = if (debug_bounds) "Debug: ON" else "Debug: OFF";
    if (ui.button(debug_label, .{}) catch false) {
        debug_bounds = !debug_bounds;
        std.debug.print("Debug bounds: {}\n", .{debug_bounds});
    }

    // Section 6: Window size
    var size_buf: [64]u8 = undefined;
    const size_text = std.fmt.bufPrintZ(&size_buf, "{d:.0}x{d:.0}", .{ ui.width, ui.height }) catch "???";
    ui.label(size_text, .{ .size = 12, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};

    ui.endHstack();
}
