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

    var app = try zello.init(gpa.allocator(), 1000, 700, "Zello Showcase - Nested Layouts!", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    // Set debug bounds state
    ui.setDebugBounds(debug_bounds);

    // ROOT: Main vertical stack
    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    // ============================================================================
    // SECTION 1: Title
    // ============================================================================
    ui.label("Zello Showcase - Resize the window!", .{ .size = 24, .color = .{ 1, 1, 0.5, 1 } }) catch {};

    // ============================================================================
    // SECTION 2: Horizontal Layout Demo with Nested Vstacks
    // ============================================================================
    ui.label("Demo 1: Nested Layouts (Horizontal with 3 Vertical Sections)", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};

    // NESTED: Horizontal container with 3 vertical sections
    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    // Section A: Colored boxes
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    ui.label("Red", .{ .bg_color = .{ 0.8, 0.3, 0.3, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.label("Green", .{ .bg_color = .{ 0.3, 0.8, 0.3, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.label("Blue", .{ .bg_color = .{ 0.3, 0.3, 0.8, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    // Section B: Counter controls
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrintZ(&counter_buf, "Count: {d}", .{counter}) catch "0";
    ui.label(counter_text, .{ .size = 20, .color = .{ 1, 1, 1, 1 } }) catch {};

    // Nested horizontal for +/- buttons
    ui.beginHstack(.{ .gap = 10 }) catch return;
    if (ui.button("+", .{ .width = 50 }) catch false) {
        counter += 1;
    }
    if (ui.button("-", .{ .width = 50 }) catch false) {
        counter -= 1;
    }
    if (ui.button("Reset", .{}) catch false) {
        counter = 0;
    }
    ui.endHstack();

    ui.endVstack();

    ui.spacer(1.0) catch {};

    // Section C: Time display
    ui.beginVstack(.{ .gap = 5, .padding = 8 }) catch return;
    ui.label("Time", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};
    var time_buf: [32]u8 = undefined;
    const time_text = std.fmt.bufPrintZ(&time_buf, "{d:.1}s", .{time}) catch "0.0s";
    ui.label(time_text, .{ .size = 18, .color = .{ 0.5, 1, 0.5, 1 } }) catch {};
    ui.endVstack();

    ui.endHstack(); // End horizontal container

    // ============================================================================
    // SECTION 3: Horizontal with Spacers Demo
    // ============================================================================
    ui.label("Demo 2: Flex Spacers (Stretches to Window Width)", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};

    ui.beginHstack(.{ .gap = 0, .padding = 10 }) catch return;
    ui.label("Start", .{ .bg_color = .{ 0.5, 0.3, 0.3, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Middle", .{ .bg_color = .{ 0.3, 0.5, 0.3, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("End", .{ .bg_color = .{ 0.3, 0.3, 0.5, 1 }, .color = .{ 1, 1, 1, 1 }, .padding = 12 }) catch {};
    ui.endHstack();

    // ============================================================================
    // SECTION 4: Interactive Buttons
    // ============================================================================
    ui.label("Demo 3: Interactive Buttons (Click to Test)", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};

    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;
    if (ui.button("Button 1", .{}) catch false) {
        std.debug.print("Button 1 clicked!\n", .{});
    }
    if (ui.button("Button 2", .{}) catch false) {
        std.debug.print("Button 2 clicked!\n", .{});
    }
    if (ui.button("Button 3", .{}) catch false) {
        std.debug.print("Button 3 clicked!\n", .{});
    }

    ui.spacer(1.0) catch {};

    // Debug toggle button
    const debug_label = if (debug_bounds) "Debug: ON" else "Debug: OFF";
    if (ui.button(debug_label, .{}) catch false) {
        debug_bounds = !debug_bounds;
        std.debug.print("Debug bounds: {}\n", .{debug_bounds});
    }
    ui.endHstack();

    // ============================================================================
    // SECTION 5: Text Inputs (with accessibility & IME)
    // ============================================================================
    ui.label("Demo 4: Text Inputs (Tab to switch, Cmd+C/V for clipboard)", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};

    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 1:", .{ .size = 12, .color = .{ 0.8, 0.8, 0.8, 1 } }) catch {};
    _ = ui.textInput("input1", &text_buf1, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 2:", .{ .size = 12, .color = .{ 0.8, 0.8, 0.8, 1 } }) catch {};
    _ = ui.textInput("input2", &text_buf2, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 6: Window Info
    // ============================================================================
    ui.label("Window Info", .{ .size = 14, .color = .{ 0.7, 0.7, 0.7, 1 } }) catch {};

    ui.beginHstack(.{ .gap = 20, .padding = 10 }) catch return;

    var size_buf: [64]u8 = undefined;
    const size_text = std.fmt.bufPrintZ(&size_buf, "Size: {d:.0} x {d:.0}", .{ ui.width, ui.height }) catch "???";
    ui.label(size_text, .{ .size = 14, .color = .{ 0.5, 0.8, 1, 1 } }) catch {};

    ui.spacer(1.0) catch {};

    ui.label("Resize the window to see flex layout in action!", .{ .size = 12, .color = .{ 1, 1, 0.5, 1 } }) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 7: Feature Summary
    // ============================================================================
    ui.beginVstack(.{ .gap = 5, .padding = 10 }) catch return;
    ui.label("Features Demonstrated:", .{ .size = 12, .color = .{ 0.8, 0.8, 0.8, 1 } }) catch {};
    ui.label("✓ N-level nested layouts (vstack/hstack)", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.label("✓ Flex spacers for responsive layout", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.label("✓ Interactive buttons with click detection", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.label("✓ Text inputs with IME, selection, clipboard", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.label("✓ Focus management (Tab navigation)", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.label("✓ VoiceOver accessibility support", .{ .size = 11, .color = .{ 0.6, 0.6, 0.6, 1 } }) catch {};
    ui.endVstack();

    ui.endVstack(); // End root vstack
}
