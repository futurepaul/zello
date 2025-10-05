const std = @import("std");
const id_mod = @import("ui/id.zig");
const focus_mod = @import("ui/focus.zig");
const layout_mod = @import("ui/layout.zig");
const flex_mod = @import("ui/flex.zig");
const commands_mod = @import("ui/commands.zig");
const text_input_mod = @import("ui/widgets/text_input.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_get_ns_view() ?*anyopaque;
extern fn mv_get_metal_layer() ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.c) void) void;
extern fn mv_set_resize_callback(cb: *const fn (w: c_int, h: c_int, scale: f32) callconv(.c) void) void;
extern fn mv_set_key_callback(cb: *const fn (key: c_int, char_code: c_uint, shift: bool) callconv(.c) void) void;
extern fn mv_set_mouse_callback(cb: *const fn (event_type: c_int, x: f32, y: f32) callconv(.c) void) void;
extern fn mv_app_run() void;

var g_ctx: ?*c.mcore_context_t = null;
var g_desc: c.mcore_surface_desc_t = undefined;
var g_ui: id_mod.UI = undefined;
var g_focus: focus_mod.FocusState = undefined;
var g_cmd_buffer: commands_mod.CommandBuffer = undefined;
var g_allocator: std.mem.Allocator = undefined;
var g_window_width: f32 = 900;
var g_window_height: f32 = 600;

// Text input widgets
var g_text_input1: text_input_mod.TextInput = undefined;
var g_text_input2: text_input_mod.TextInput = undefined;
var g_text_input1_id: u64 = 0;
var g_text_input2_id: u64 = 0;

// Mouse state
var g_mouse_x: f32 = 0;
var g_mouse_y: f32 = 0;
var g_mouse_down: bool = false;

// Button tracking for hit testing
const MAX_BUTTONS = 20;
var g_button_bounds: [MAX_BUTTONS]layout_mod.Rect = undefined;
var g_button_ids: [MAX_BUTTONS]u64 = undefined;
var g_button_count: usize = 0;

const KEY_TAB = 48; // macOS key code for Tab
const MOUSE_DOWN: c_int = 0;
const MOUSE_UP: c_int = 1;
const MOUSE_MOVED: c_int = 2;

fn on_key(key: c_int, char_code: c_uint, shift: bool) callconv(.c) void {
    if (key == KEY_TAB) {
        if (shift) {
            g_focus.focusPrev();
        } else {
            g_focus.focusNext();
        }
        std.debug.print("Tab pressed, focused_id: {?}\n", .{g_focus.focused_id});
        return;
    }

    // Handle text input for focused widget
    if (g_ctx) |ctx| {
        if (g_focus.isFocused(g_text_input1_id)) {
            _ = g_text_input1.handleKey(ctx, key, char_code, shift);
        } else if (g_focus.isFocused(g_text_input2_id)) {
            _ = g_text_input2.handleKey(ctx, key, char_code, shift);
        }
    }
}

fn on_resize(w: c_int, h: c_int, scale: f32) callconv(.c) void {
    g_desc.u.macos.width_px = w;
    g_desc.u.macos.height_px = h;
    g_desc.u.macos.scale_factor = scale;
    g_window_width = @as(f32, @floatFromInt(w)) / scale;
    g_window_height = @as(f32, @floatFromInt(h)) / scale;
    if (g_ctx) |ctx| {
        c.mcore_resize(ctx, &g_desc);
    }
}

fn checkButtonClick() void {
    for (g_button_bounds[0..g_button_count], g_button_ids[0..g_button_count]) |bounds, id| {
        if (isPointInRect(g_mouse_x, g_mouse_y, bounds.x, bounds.y, bounds.width, bounds.height)) {
            std.debug.print("Button clicked! Setting focus to ID {d}\n", .{id});
            // Set focus to clicked button
            g_focus.setFocus(id);
            return;
        }
    }
}

fn on_mouse(event_type: c_int, x: f32, y: f32) callconv(.c) void {
    // Store mouse position
    g_mouse_x = x;
    g_mouse_y = y;

    if (event_type == MOUSE_DOWN) {
        g_mouse_down = true;
        // Check if we clicked a button
        checkButtonClick();
    } else if (event_type == MOUSE_UP) {
        g_mouse_down = false;
    }
    // MOUSE_MOVED events are silent for now
}

fn drawButton(label: [*:0]const u8, x: f32, y: f32, id: u64, is_focused: bool) void {
    const button_w: f32 = 180;
    const button_h: f32 = 50;

    // Store button bounds for hit testing
    if (g_button_count < MAX_BUTTONS) {
        g_button_bounds[g_button_count] = .{ .x = x, .y = y, .width = button_w, .height = button_h };
        g_button_ids[g_button_count] = id;
        g_button_count += 1;
    }

    // Draw button background
    const bg_color = if (is_focused)
        [4]f32{ 0.4, 0.5, 0.8, 1.0 }
    else
        [4]f32{ 0.3, 0.3, 0.4, 1.0 };

    g_cmd_buffer.roundedRect(x, y, button_w, button_h, 8, bg_color) catch {};

    // Draw button text
    const text_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    g_cmd_buffer.text(label, x + 15, y + 15, 18, 180, text_color) catch {};
}

fn measureText(ctx: *c.mcore_context_t, text: []const u8, font_size: f32, max_width: f32) layout_mod.Size {
    var size: c.mcore_text_size_t = undefined;
    c.mcore_measure_text(ctx, text.ptr, font_size, max_width, &size);
    return .{ .width = size.width, .height = size.height };
}

fn isPointInRect(x: f32, y: f32, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32) bool {
    return x >= rect_x and x < rect_x + rect_w and
        y >= rect_y and y < rect_y + rect_h;
}

fn drawLabel(text: [*:0]const u8, rect: layout_mod.Rect, offset_x: f32, offset_y: f32, color: [4]f32, font_size: f32) void {
    // Draw background rect
    const bg_color = [4]f32{ 0.2, 0.2, 0.3, 1.0 };
    g_cmd_buffer.roundedRect(rect.x + offset_x, rect.y + offset_y, rect.width, rect.height, 4, bg_color) catch {};

    // Measure text for proper vertical centering
    if (g_ctx) |ctx| {
        var text_size: c.mcore_text_size_t = undefined;
        const padding_x: f32 = 8; // Match the padding we added in layout (16/2 = 8)
        c.mcore_measure_text(ctx, text, font_size, rect.width - (padding_x * 2), &text_size);

        // Center text vertically within the rect
        const text_y = rect.y + offset_y + (rect.height - text_size.height) / 2.0;

        // Draw text with proper horizontal padding
        g_cmd_buffer.text(text, rect.x + offset_x + padding_x, text_y, font_size, rect.width - (padding_x * 2), color) catch {};
    }
}

fn on_frame(t: f64) callconv(.c) void {
    if (g_ctx) |ctx| {
        c.mcore_begin_frame(ctx, t);

        // Reset command buffer
        g_cmd_buffer.reset();

        // Begin frame for focus system
        g_focus.beginFrame();

        // Reset button tracking for this frame
        g_button_count = 0;

        var y_offset: f32 = 10;

        // Title
        const title_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        g_cmd_buffer.text("Zello Flexbox Demo - Resize the window!", 10, y_offset, 20, g_window_width - 20, title_color) catch {};
        y_offset += 35;

        // Demo 1: Horizontal flexbox with fixed sizes
        {
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("1. Horizontal (fixed sizes, gap=15, padding=10)", 10, y_offset, 14, g_window_width - 20, demo_color) catch {};
            y_offset += 20;

            var flex = flex_mod.FlexContainer.init(g_allocator, .Horizontal);
            defer flex.deinit();
            flex.gap = 15;
            flex.padding = 10;

            const labels = [_][]const u8{ "One", "Two", "Three", "Four" };
            const colors = [_][4]f32{
                [4]f32{ 1.0, 0.6, 0.6, 1.0 },
                [4]f32{ 0.6, 1.0, 0.6, 1.0 },
                [4]f32{ 0.6, 0.6, 1.0, 1.0 },
                [4]f32{ 1.0, 1.0, 0.6, 1.0 },
            };

            for (labels) |label| {
                const size = measureText(ctx, label, 16, 400);
                // Add generous padding: 16px horizontal, 12px vertical
                flex.addChild(.{ .width = size.width + 16, .height = size.height + 12 }, 0) catch {};
            }

            const constraints = layout_mod.BoxConstraints.loose(g_window_width - 20, 100);
            const rects = flex.layout_children(constraints) catch &[_]layout_mod.Rect{};
            defer g_allocator.free(rects);

            for (rects, 0..) |rect, i| {
                drawLabel(@ptrCast(labels[i].ptr), rect, 10, y_offset, colors[i], 16);
            }
            y_offset += 40;
        }

        // Demo 2: Horizontal with flex spacing
        {
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("2. Horizontal with flex=1 spacers (stretches to window width)", 10, y_offset, 14, g_window_width - 20, demo_color) catch {};
            y_offset += 20;

            var flex = flex_mod.FlexContainer.init(g_allocator, .Horizontal);
            defer flex.deinit();
            flex.gap = 0;
            flex.padding = 10;

            const labels = [_][]const u8{ "Start", "Middle", "End" };
            const colors = [_][4]f32{
                [4]f32{ 1.0, 0.5, 0.5, 1.0 },
                [4]f32{ 0.5, 1.0, 0.5, 1.0 },
                [4]f32{ 0.5, 0.5, 1.0, 1.0 },
            };

            // Start label
            const size1 = measureText(ctx, labels[0], 16, 400);
            flex.addChild(.{ .width = size1.width + 16, .height = size1.height + 12 }, 0) catch {};
            // Spacer
            flex.addSpacer(1) catch {};
            // Middle label
            const size2 = measureText(ctx, labels[1], 16, 400);
            flex.addChild(.{ .width = size2.width + 16, .height = size2.height + 12 }, 0) catch {};
            // Spacer
            flex.addSpacer(1) catch {};
            // End label
            const size3 = measureText(ctx, labels[2], 16, 400);
            flex.addChild(.{ .width = size3.width + 16, .height = size3.height + 12 }, 0) catch {};

            const constraints = layout_mod.BoxConstraints.loose(g_window_width - 20, 100);
            const rects = flex.layout_children(constraints) catch &[_]layout_mod.Rect{};
            defer g_allocator.free(rects);

            for (rects, 0..) |rect, i| {
                // Skip spacers (odd indices)
                if (i % 2 == 0) {
                    const label_idx = i / 2;
                    drawLabel(@ptrCast(labels[label_idx].ptr), rect, 10, y_offset, colors[label_idx], 16);
                }
            }
            y_offset += 40;
        }

        // Demo 3: Vertical flexbox
        {
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("3. Vertical (gap=8, padding=10)", 10, y_offset, 14, g_window_width - 20, demo_color) catch {};
            y_offset += 20;

            var flex = flex_mod.FlexContainer.init(g_allocator, .Vertical);
            defer flex.deinit();
            flex.gap = 8;
            flex.padding = 10;

            const labels = [_][]const u8{ "First", "Second", "Third" };
            const colors = [_][4]f32{
                [4]f32{ 1.0, 0.7, 0.3, 1.0 },
                [4]f32{ 0.7, 0.3, 1.0, 1.0 },
                [4]f32{ 0.3, 1.0, 0.7, 1.0 },
            };

            for (labels) |label| {
                const size = measureText(ctx, label, 16, 400);
                // Add generous padding: 16px horizontal, 12px vertical
                flex.addChild(.{ .width = size.width + 16, .height = size.height + 12 }, 0) catch {};
            }

            const constraints = layout_mod.BoxConstraints.loose(200, 200);
            const rects = flex.layout_children(constraints) catch &[_]layout_mod.Rect{};
            defer g_allocator.free(rects);

            for (rects, 0..) |rect, i| {
                drawLabel(@ptrCast(labels[i].ptr), rect, 10, y_offset, colors[i], 16);
            }
            y_offset += 100;
        }

        // Demo 4: Focusable buttons in horizontal layout
        {
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("4. Interactive buttons (Press Tab to cycle focus)", 10, y_offset, 14, g_window_width - 20, demo_color) catch {};
            y_offset += 25;

            g_ui.pushID("button1") catch {};
            const button1_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button1_id) catch {};
            const is_focused_1 = g_focus.isFocused(button1_id);
            drawButton("Button 1", 20, y_offset, button1_id, is_focused_1);
            g_ui.popID();

            g_ui.pushID("button2") catch {};
            const button2_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button2_id) catch {};
            const is_focused_2 = g_focus.isFocused(button2_id);
            drawButton("Button 2", 220, y_offset, button2_id, is_focused_2);
            g_ui.popID();

            g_ui.pushID("button3") catch {};
            const button3_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button3_id) catch {};
            const is_focused_3 = g_focus.isFocused(button3_id);
            drawButton("Button 3", 420, y_offset, button3_id, is_focused_3);
            g_ui.popID();

            y_offset += 60;
        }

        // Demo 5: Text Input Widgets
        {
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("5. Text Input (Press Tab to focus, type to edit)", 10, y_offset, 14, g_window_width - 20, demo_color) catch {};
            y_offset += 25;

            // Text input 1
            g_ui.pushID("textinput1") catch {};
            g_text_input1_id = g_ui.getCurrentID();
            g_focus.registerFocusable(g_text_input1_id) catch {};
            const is_focused_ti1 = g_focus.isFocused(g_text_input1_id);
            g_text_input1.render(ctx, &g_cmd_buffer, 20, y_offset, is_focused_ti1);
            g_ui.popID();

            // Text input 2
            g_ui.pushID("textinput2") catch {};
            g_text_input2_id = g_ui.getCurrentID();
            g_focus.registerFocusable(g_text_input2_id) catch {};
            const is_focused_ti2 = g_focus.isFocused(g_text_input2_id);
            g_text_input2.render(ctx, &g_cmd_buffer, 20, y_offset + 50, is_focused_ti2);
            g_ui.popID();

            y_offset += 120;
        }

        // Window size indicator
        var size_buf: [64]u8 = undefined;
        const size_info = std.fmt.bufPrintZ(&size_buf, "Window: {d:.0}x{d:.0}", .{ g_window_width, g_window_height }) catch "Window: ???";
        const size_color = [4]f32{ 0.6, 0.6, 0.6, 1.0 };
        g_cmd_buffer.text(size_info.ptr, 10, y_offset, 12, 400, size_color) catch {};

        // Submit all draw commands in a single FFI call
        const cmds = g_cmd_buffer.getCommands();
        c.mcore_render_commands(ctx, @ptrCast(cmds.ptr), @intCast(cmds.count));

        const clear = c.mcore_rgba_t{ .r = 0.15, .g = 0.15, .b = 0.20, .a = 1.0 };
        const st = c.mcore_end_frame_present(ctx, clear);
        if (st != c.MCORE_OK) {
            const err = c.mcore_last_error();
            if (err != null) std.debug.print("mcore error: {s}\n", .{std.mem.span(err)});
        }
    }
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();

    // Initialize UI and focus systems
    g_ui = id_mod.UI.init(g_allocator);
    defer g_ui.deinit();

    g_focus = focus_mod.FocusState.init(g_allocator);
    defer g_focus.deinit();

    // Initialize command buffer (capacity for 1000 commands)
    g_cmd_buffer = commands_mod.CommandBuffer.init(g_allocator, 1000) catch unreachable;
    defer g_cmd_buffer.deinit();

    // Initialize text input widgets
    // Height should accommodate line height (16px font ~= 20-24px line height) + padding
    g_text_input1 = text_input_mod.TextInput.init(0, 400, 40); // ID will be set by UI system
    g_text_input2 = text_input_mod.TextInput.init(0, 400, 40);

    _ = mv_app_init(900, 600, "Zello - Phase 4: Text Input");
    const ns_view = mv_get_ns_view() orelse return error.NoView;
    const ca_layer = mv_get_metal_layer() orelse return error.NoLayer;

    // Fill surface desc
    g_desc = .{
        .platform = c.MCORE_PLATFORM_MACOS,
        .u = .{
            .macos = .{
                .ns_view = ns_view,
                .ca_metal_layer = ca_layer,
                .scale_factor = 2.0, // updated by resize callback
                .width_px = 900 * 2, // starter values
                .height_px = 600 * 2,
            },
        },
    };

    g_ctx = c.mcore_create(&g_desc) orelse {
        const err = c.mcore_last_error();
        if (err != null) std.debug.print("create error: {s}\n", .{std.mem.span(err)});
        return error.EngineCreateFailed;
    };

    mv_set_resize_callback(on_resize);
    mv_set_key_callback(on_key);
    mv_set_mouse_callback(on_mouse);
    mv_set_frame_callback(on_frame);
    mv_app_run();
}
