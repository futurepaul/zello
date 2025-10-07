const std = @import("std");
const zello = @import("../zello.zig");
const color = @import("../ui/color.zig");
const Color = color.Color;
const Shadow = color.Shadow;
const custom_badge = @import("../ui/widgets/custom_widget_example.zig");

// App state
var debug_bounds: bool = false;
var counter: i32 = 0;
var text_buf1: [256]u8 = undefined;
var text_buf2: [256]u8 = undefined;

// Simple color palette
const WHITE = color.rgba(1, 1, 1, 1);
const BLACK = color.rgba(0, 0, 0, 1);
const LIGHT_GRAY = color.rgba(0.95, 0.95, 0.96, 1);
const RED = color.rgba(0.8, 0.3, 0.3, 1);
const GREEN = color.rgba(0.3, 0.8, 0.3, 1);
const BLUE = color.rgba(0.3, 0.3, 0.8, 1);

// Typography
const FONT_SIZE: f32 = 14;

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

    //const t: f32 = @floatCast(time);
    defer ui.endFrame(WHITE) catch {};

    // Set debug bounds state
    ui.setDebugBounds(debug_bounds);

    // ROOT: Main vertical stack
    ui.beginVstack(.{ .gap = 20, .padding = 60 }) catch return;

    // ============================================================================
    // SECTION 1: Title
    // ============================================================================
    ui.label("Zello Showcase - Resize the window!", .{ .size = 24, .color = BLACK }) catch {};

    // ============================================================================
    // SECTION 2: Horizontal Layout Demo with Nested Vstacks
    // ============================================================================
    ui.label("Demo 1: Nested Layouts (Horizontal with 3 Vertical Sections)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    // NESTED: Horizontal container with 3 vertical sections
    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    // Section A: Colored boxes
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    ui.label("Red", .{ .bg_color = RED, .color = WHITE, .padding = 12 }) catch {};
    ui.label("Green", .{ .bg_color = GREEN, .color = WHITE, .padding = 12 }) catch {};
    ui.label("Blue", .{ .bg_color = BLUE, .color = WHITE, .padding = 12 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    // Section B: Counter controls
    ui.beginVstack(.{ .gap = 8, .padding = 8 }) catch return;
    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrintZ(&counter_buf, "Count: {d}", .{counter}) catch "0";
    ui.label(counter_text, .{ .size = 20, .color = BLACK }) catch {};

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

    // Section C: Time display (fixed width)
    ui.beginVstack(.{ .gap = 5, .padding = 8, .width = 100 }) catch return;
    ui.label("Time", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    var time_buf: [32]u8 = undefined;
    const time_text = std.fmt.bufPrintZ(&time_buf, "{d:.1}s", .{time}) catch "0.0s";
    ui.label(time_text, .{ .size = 18, .color = BLACK }) catch {};
    ui.endVstack();

    ui.endHstack(); // End horizontal container

    // ============================================================================
    // SECTION 3: Horizontal with Spacers Demo
    // ============================================================================
    ui.label("Demo 2: Flex Spacers (Stretches to Window Width)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 0, .padding = 10 }) catch return;
    ui.label("Start", .{ .bg_color = RED, .color = WHITE, .padding = 12, .size = FONT_SIZE }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("Middle", .{ .bg_color = GREEN, .color = WHITE, .padding = 12, .size = FONT_SIZE }) catch {};
    ui.spacer(1.0) catch {};
    ui.label("End", .{ .bg_color = BLUE, .color = WHITE, .padding = 12, .size = FONT_SIZE }) catch {};
    ui.endHstack();

    // ============================================================================
    // SECTION 4: Interactive Buttons
    // ============================================================================
    ui.label("Demo 3: Interactive Buttons (Click to Test)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;

    // Default button
    if (ui.button("Default", .{}) catch false) {
        std.debug.print("Default button clicked!\n", .{});
    }

    // Styled button with border (shadcn-style!)
    const border_color = color.rgba(0.85, 0.85, 0.87, 1);
    if (ui.button("With Border", .{
        .bg_color = LIGHT_GRAY,
        .hover_color = color.lerp(LIGHT_GRAY, BLACK, 0.02),
        .active_color = color.lerp(LIGHT_GRAY, BLACK, 0.05),
        .text_color = BLACK,
        .border_color = border_color,
        .border_width = 1,
        .radius = 6,
    }) catch false) {
        std.debug.print("Bordered button clicked!\n", .{});
    }

    // Styled button with shadow (shadcn-style!)
    const shadow = Shadow.init(0, 2, 4, color.rgba(0, 0, 0, 0.1));
    if (ui.button("With Shadow", .{
        .bg_color = LIGHT_GRAY,
        .hover_color = color.lerp(LIGHT_GRAY, BLACK, 0.02),
        .active_color = color.lerp(LIGHT_GRAY, BLACK, 0.05),
        .text_color = BLACK,
        .border_color = border_color,
        .border_width = 1,
        .radius = 6,
        .shadow = shadow,
    }) catch false) {
        std.debug.print("Shadow button clicked!\n", .{});
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
    ui.label("Demo 4: Text Inputs (Tab to switch, Cmd+C/V for clipboard)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 15, .padding = 10 }) catch return;

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 1:", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    _ = ui.textInput("input1", &text_buf1, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.beginVstack(.{ .gap = 5 }) catch return;
    ui.label("Input 2:", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    _ = ui.textInput("input2", &text_buf2, .{ .width = 200 }) catch {};
    ui.endVstack();

    ui.spacer(1.0) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 6: Window Info
    // ============================================================================
    ui.label("Window Info", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 20, .padding = 10 }) catch return;

    var size_buf: [64]u8 = undefined;
    const size_text = std.fmt.bufPrintZ(&size_buf, "Size: {d:.0} x {d:.0}", .{ ui.width, ui.height }) catch "???";
    ui.label(size_text, .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.spacer(1.0) catch {};

    ui.label("Resize the window to see flex layout in action!", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 7: Custom Widget Demo
    // ============================================================================
    ui.label("Demo 5: Custom Widget (Extensibility API)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;

    // Create custom badge widgets (stack-allocated, no heap!)
    var badge1 = custom_badge.BadgeData{
        .text = "NEW",
        .bg_color = color.rgba(0.9, 0.2, 0.2, 1),
        .text_color = WHITE,
        .padding = 8,
    };
    ui.customWidget(&custom_badge.Interface, &badge1) catch {};

    var badge2 = custom_badge.BadgeData{
        .text = "BETA",
        .bg_color = color.rgba(0.2, 0.6, 0.9, 1),
        .text_color = WHITE,
        .padding = 8,
    };
    ui.customWidget(&custom_badge.Interface, &badge2) catch {};

    var badge3 = custom_badge.BadgeData{
        .text = "PRO",
        .bg_color = color.rgba(0.6, 0.4, 0.9, 1),
        .text_color = WHITE,
        .padding = 8,
    };
    ui.customWidget(&custom_badge.Interface, &badge3) catch {};

    ui.spacer(1.0) catch {};

    ui.label("← Custom widgets work seamlessly!", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 8: Image Widget Demo
    // ============================================================================
    ui.label("Demo 6: Image Widget (JPEG/PNG Loading)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.beginHstack(.{ .gap = 10, .padding = 10 }) catch return;

    // Load the waffle dog image
    var widget_ctx = ui.createWidgetContext();
    const img_info = zello.loadImageFile(&widget_ctx, "src/examples/waffle_dog.jpeg") catch {
        ui.label("Failed to load image", .{ .color = RED }) catch {};
        ui.endHstack();
        ui.endVstack(); // ROOT
        return;
    };
    defer zello.releaseImage(&widget_ctx, img_info.id);

    // Display the image at 100x100 using the proper widget system
    const natural_w = @as(f32, @floatFromInt(img_info.width));
    const natural_h = @as(f32, @floatFromInt(img_info.height));
    const scale = 100.0 / natural_w;

    ui.image(img_info.id, natural_w, natural_h, .{ .scale = scale }) catch {};

    ui.label("← Waffle Dog! 🧇🐕", .{ .size = FONT_SIZE, .color = BLACK }) catch {};

    ui.endHstack();

    // ============================================================================
    // SECTION 9: Feature Summary
    // ============================================================================
    ui.beginVstack(.{ .gap = 5, .padding = 10 }) catch return;
    ui.label("Features Demonstrated:", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ N-level nested layouts (vstack/hstack)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Flex spacers for responsive layout", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Interactive buttons with borders & shadows", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Text inputs with IME, selection, clipboard", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Focus management (Tab navigation)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Image loading (JPEG, PNG, GIF, BMP, etc.)", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ VoiceOver accessibility support", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.label("✓ Custom widget extensibility API", .{ .size = FONT_SIZE, .color = BLACK }) catch {};
    ui.endVstack();

    ui.endVstack(); // End root vstack
}
