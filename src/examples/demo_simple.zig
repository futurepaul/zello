const std = @import("std");
const zello = @import("../zello.zig");

// Demo state
var text_buffer1: [256]u8 = undefined;
var text_buffer2: [256]u8 = undefined;
var debug_bounds: bool = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize text buffers with default values
    @memset(&text_buffer1, 0);
    @memset(&text_buffer2, 0);
    const default1 = "Type here...";
    const default2 = "Or here...";
    @memcpy(text_buffer1[0..default1.len], default1);
    @memcpy(text_buffer2[0..default2.len], default2);

    var app = try zello.init(gpa.allocator(), 900, 600, "Zello Demo - Simple", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;

    ui.beginFrame();
    defer ui.endFrame(.{ 0.15, 0.15, 0.20, 1.0 }) catch {};

    // Single horizontal layout with all elements
    // Note: Can't nest layouts yet, so everything is in one row
    ui.beginHstack(.{ .gap = 15, .padding = 20 }) catch return;

    // Title
    ui.label("Zello Demo", .{ .size = 24 }) catch {};

    // Button 1
    if (ui.button("Button 1", .{}) catch false) {
        std.debug.print("Button 1 clicked!\n", .{});
    }

    // Button 2
    if (ui.button("Button 2", .{}) catch false) {
        std.debug.print("Button 2 clicked!\n", .{});
    }

    // Button 3
    if (ui.button("Button 3", .{}) catch false) {
        std.debug.print("Button 3 clicked!\n", .{});
    }

    // Debug toggle
    const debug_label = if (debug_bounds) "Debug: ON" else "Debug: OFF";
    if (ui.button(debug_label, .{}) catch false) {
        debug_bounds = !debug_bounds;
        std.debug.print("Debug bounds: {}\n", .{debug_bounds});
    }

    // Text Input 1
    if (ui.textInput("text1", &text_buffer1, .{ .width = 200, .height = 40 }) catch false) {
        std.debug.print("Text 1 changed\n", .{});
    }

    // Text Input 2
    if (ui.textInput("text2", &text_buffer2, .{ .width = 200, .height = 40 }) catch false) {
        std.debug.print("Text 2 changed\n", .{});
    }

    // Window size indicator
    var size_buf: [64]u8 = undefined;
    const size_text = std.fmt.bufPrintZ(
        &size_buf,
        "{d:.0}x{d:.0}",
        .{ ui.width, ui.height },
    ) catch "???";
    ui.label(size_text, .{ .size = 12 }) catch {};

    ui.endHstack();
}
