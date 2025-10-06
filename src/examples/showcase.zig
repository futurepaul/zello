const std = @import("std");
const zello = @import("../zello.zig");
const color = @import("../ui/color.zig");
const Color = color.Color;

// App state
var debug_bounds: bool = false;
var counter: i32 = 0;
var text_buf1: [256]u8 = undefined;
var text_buf2: [256]u8 = undefined;

// Colors using the fancy new Color API!
// Note: FFI calls like parse() can't be comptime, so we use rgba() for constants
const WHITE = color.rgba(1, 1, 1, 1);
const DARK_BG = color.rgba(0.05, 0.08, 0.12, 1); // Dark blue-ish
const PURPLE_BG = color.rgba(0.15, 0.05, 0.20, 1); // Vibrant purple
const GRAY = color.rgba(0.7, 0.7, 0.7, 1);
const LIGHT_GRAY = color.rgba(0.8, 0.8, 0.8, 1);
const DIM_GRAY = color.rgba(0.6, 0.6, 0.6, 1);

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

    // 🎨 Animated clear color using perceptually-correct Oklab lerping!
    // Smoothly oscillates between dark blue and dark purple
    const t: f32 = @floatCast(time);
    const lerp_factor = (@sin(t * 0.5) + 1.0) / 2.0; // Oscillate between 0 and 1
    const bg_color = color.lerp(DARK_BG, PURPLE_BG, lerp_factor);
    defer ui.endFrame(bg_color) catch {};

    // Set debug bounds state
    ui.setDebugBounds(debug_bounds);

    // ROOT: Main vertical stack
    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    // ============================================================================
    // SECTION 1: Title
    // ============================================================================
    const title_color = color.parse("oklch(0.9 0.15 85)") orelse color.rgba(1, 1, 0.5, 1); // Warm yellow
    ui.label("Zello Showcase - Resize the window!", .{ .size = 24, .color = title_color }) catch {};

    // ============================================================================
    // SECTION 2: Horizontal Layout Demo with Nested Vstacks
    // ============================================================================
    ui.label("Demo 1: Nested Layouts (Horizontal with 3 Vertical Sections)", .{ .size = 14, .color = GRAY }) catch {};

    // NESTED: Horizontal container with 3 vertical sections
    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    // Section A: Colored boxes (using CSS color parsing!)
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    const red = color.parse("oklch(0.55 0.22 25)") orelse color.rgba(0.8, 0.3, 0.3, 1);
    const green = color.parse("oklch(0.65 0.20 145)") orelse color.rgba(0.3, 0.8, 0.3, 1);
    const blue = color.parse("oklch(0.55 0.20 250)") orelse color.rgba(0.3, 0.3, 0.8, 1);

    ui.label("Red", .{ .bg_color = red, .color = WHITE, .padding = 12 }) catch {};
    ui.label("Green", .{ .bg_color = green, .color = WHITE, .padding = 12 }) catch {};
    ui.label("Blue", .{ .bg_color = blue, .color = WHITE, .padding = 12 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    // Section B: Counter controls
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrintZ(&counter_buf, "Count: {d}", .{counter}) catch "0";
    ui.label(counter_text, .{ .size = 20, .color = WHITE }) catch {};

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

    // Section C: Time display (fixed width, with animated color!)
    ui.beginVstack(.{ .gap = 5, .padding = 8, .width = 100 }) catch return;
    ui.label("Time", .{ .size = 14, .color = GRAY }) catch {};
    var time_buf: [32]u8 = undefined;
    const time_text = std.fmt.bufPrintZ(&time_buf, "{d:.1}s", .{time}) catch "0.0s";

    // Animate time color from green to cyan using lerp
    const green_time = color.parse("oklch(0.75 0.15 145)") orelse color.rgba(0.5, 1, 0.5, 1);
    const cyan_time = color.parse("oklch(0.75 0.15 195)") orelse color.rgba(0.5, 1, 1, 1);
    const time_t = (@sin(t * 2.0) + 1.0) / 2.0;
    const time_color = color.lerp(green_time, cyan_time, time_t);

    ui.label(time_text, .{ .size = 18, .color = time_color }) catch {};
    ui.endVstack();

    ui.endHstack(); // End horizontal container

    // ============================================================================
    // SECTION 3: Horizontal with Spacers Demo
    // ============================================================================
    ui.label("Demo 2: Flex Spacers (Stretches to Window Width)", .{ .size = 14, .color = GRAY }) catch {};

    ui.beginHstack(.{ .gap = 0, .padding = 10 }) catch return;
    const start_col = color.parse("#d44") orelse color.rgba(0.5, 0.3, 0.3, 1);
    const middle_col = color.parse("#4d4") orelse color.rgba(0.3, 0.5, 0.3, 1);
    const end_col = color.parse("#44d") orelse color.rgba(0.3, 0.3, 0.5, 1);

    ui.label("Start", .{ .bg_color = start_col, .color = WHITE, .padding = 12 }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Middle", .{ .bg_color = middle_col, .color = WHITE, .padding = 12 }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("End", .{ .bg_color = end_col, .color = WHITE, .padding = 12 }) catch {};
    ui.endHstack();

    // ============================================================================
    // SECTION 4: Interactive Buttons
    // ============================================================================
    ui.label("Demo 3: Interactive Buttons (Click to Test)", .{ .size = 14, .color = GRAY }) catch {};

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
    ui.label("Demo 4: Text Inputs (Tab to switch, Cmd+C/V for clipboard)", .{ .size = 14, .color = GRAY }) catch {};

    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 1:", .{ .size = 12, .color = LIGHT_GRAY }) catch {};
    _ = ui.textInput("input1", &text_buf1, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 2:", .{ .size = 12, .color = LIGHT_GRAY }) catch {};
    _ = ui.textInput("input2", &text_buf2, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 6: Window Info
    // ============================================================================
    ui.label("Window Info", .{ .size = 14, .color = GRAY }) catch {};

    ui.beginHstack(.{ .gap = 20, .padding = 10 }) catch return;

    var size_buf: [64]u8 = undefined;
    const size_text = std.fmt.bufPrintZ(&size_buf, "Size: {d:.0} x {d:.0}", .{ ui.width, ui.height }) catch "???";
    const info_color = color.rgba(0.5, 0.8, 1, 1);
    ui.label(size_text, .{ .size = 14, .color = info_color }) catch {};

    ui.spacer(1.0) catch {};

    const resize_color = color.rgba(1, 1, 0.5, 1);
    ui.label("Resize the window to see flex layout in action!", .{ .size = 12, .color = resize_color }) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 7: Feature Summary
    // ============================================================================
    ui.beginVstack(.{ .gap = 5, .padding = 10 }) catch return;
    ui.label("Features Demonstrated:", .{ .size = 12, .color = LIGHT_GRAY }) catch {};
    ui.label("✓ N-level nested layouts (vstack/hstack)", .{ .size = 11, .color = DIM_GRAY }) catch {};
    ui.label("✓ Flex spacers for responsive layout", .{ .size = 11, .color = DIM_GRAY }) catch {};
    ui.label("✓ Interactive buttons with click detection", .{ .size = 11, .color = DIM_GRAY }) catch {};
    ui.label("✓ Text inputs with IME, selection, clipboard", .{ .size = 11, .color = DIM_GRAY }) catch {};
    ui.label("✓ Focus management (Tab navigation)", .{ .size = 11, .color = DIM_GRAY }) catch {};
    ui.label("✓ VoiceOver accessibility support", .{ .size = 11, .color = DIM_GRAY }) catch {};
    const sparkle_color = color.rgba(0.8, 0.6, 1.0, 1);
    ui.label("✨ CSS color parsing & Oklab lerping!", .{ .size = 11, .color = sparkle_color }) catch {};
    ui.endVstack();

    ui.endVstack(); // End root vstack
}
