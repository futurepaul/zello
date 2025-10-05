const std = @import("std");
const id_mod = @import("ui/id.zig");
const focus_mod = @import("ui/focus.zig");
const layout_mod = @import("ui/layout.zig");
const flex_mod = @import("ui/flex.zig");
const commands_mod = @import("ui/commands.zig");
const text_input_mod = @import("ui/widgets/text_input.zig");
const a11y_mod = @import("ui/a11y.zig");
const c_api = @import("c_api.zig");
const c = c_api.c;

extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_get_ns_view() ?*anyopaque;
extern fn mv_get_metal_layer() ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.c) void) void;
extern fn mv_set_resize_callback(cb: *const fn (w: c_int, h: c_int, scale: f32) callconv(.c) void) void;
extern fn mv_set_key_callback(cb: *const fn (key: c_int, char_code: c_uint, shift: bool, cmd: bool) callconv(.c) void) void;
extern fn mv_set_mouse_callback(cb: *const fn (event_type: c_int, x: f32, y: f32) callconv(.c) void) void;

// IME callbacks
const ImeRect = extern struct { x: f32, y: f32, w: f32, h: f32 };
extern fn mv_set_ime_commit_callback(cb: *const fn (text: [*:0]const u8) callconv(.c) void) void;
extern fn mv_set_ime_preedit_callback(cb: *const fn (text: [*:0]const u8, cursor_offset: c_int) callconv(.c) void) void;
extern fn mv_set_ime_cursor_rect_callback(cb: *const fn () callconv(.c) ImeRect) void;

extern fn mv_app_run() void;
extern fn mv_clipboard_set_text(text: [*:0]const u8) void;
extern fn mv_clipboard_get_text(buffer: [*]u8, buffer_len: c_int) c_int;
extern fn mv_app_quit() void;

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

// IME cursor position (updated when rendering focused text input)
var g_ime_cursor_x: f32 = 10;
var g_ime_cursor_y: f32 = 550;
var g_ime_cursor_h: f32 = 20;

// Button tracking for hit testing
const MAX_BUTTONS = 20;
var g_button_bounds: [MAX_BUTTONS]layout_mod.Rect = undefined;
var g_button_ids: [MAX_BUTTONS]u64 = undefined;
var g_button_count: usize = 0;

// Debug rendering
var g_debug_bounds: bool = false;
var g_debug_button_id: u64 = 0;

const KEY_TAB = 48; // macOS key code for Tab
const MOUSE_DOWN: c_int = 0;
const MOUSE_UP: c_int = 1;
const MOUSE_MOVED: c_int = 2;

fn on_key(key: c_int, char_code: c_uint, shift: bool, cmd: bool) callconv(.c) void {
    // Debug: print cmd key combinations
    if (cmd) {
        std.debug.print("Cmd key: char_code={d} ('{c}'), key={d}\n", .{ char_code, @as(u8, @intCast(char_code)), key });
    }

    // Handle Cmd+Q to quit
    if (cmd and char_code == 'q') {
        mv_app_quit();
        return;
    }

    // Handle Cmd+A (select all), Cmd+C (copy), Cmd+X (cut), Cmd+V (paste)
    if (cmd and g_ctx != null) {
        const ctx = g_ctx.?;
        var clipboard_buf: [4096]u8 = undefined;

        if (char_code == 'a') {
            // Select All
            if (g_focus.isFocused(g_text_input1_id)) {
                const len = c.mcore_text_input_get(ctx, g_text_input1_id, &clipboard_buf, 4096);
                if (len > 0) {
                    c.mcore_text_input_set_cursor_pos(ctx, g_text_input1_id, 0, 0); // Go to start
                    c.mcore_text_input_set_cursor_pos(ctx, g_text_input1_id, len, 1); // Select to end
                }
            } else if (g_focus.isFocused(g_text_input2_id)) {
                const len = c.mcore_text_input_get(ctx, g_text_input2_id, &clipboard_buf, 4096);
                if (len > 0) {
                    c.mcore_text_input_set_cursor_pos(ctx, g_text_input2_id, 0, 0); // Go to start
                    c.mcore_text_input_set_cursor_pos(ctx, g_text_input2_id, len, 1); // Select to end
                }
            }
            return;
        } else if (char_code == 'c') {
            // Copy
            std.debug.print("Cmd+C detected!\n", .{});
            if (g_focus.isFocused(g_text_input1_id)) {
                const len = c.mcore_text_input_get_selected_text(ctx, g_text_input1_id, &clipboard_buf, 4096);
                std.debug.print("  Text input 1 selected text length: {d}\n", .{len});
                if (len > 0) {
                    clipboard_buf[@intCast(len)] = 0;
                    mv_clipboard_set_text(@ptrCast(&clipboard_buf));
                    std.debug.print("  Copied to clipboard: {s}\n", .{clipboard_buf[0..@intCast(len)]});
                }
            } else if (g_focus.isFocused(g_text_input2_id)) {
                const len = c.mcore_text_input_get_selected_text(ctx, g_text_input2_id, &clipboard_buf, 4096);
                std.debug.print("  Text input 2 selected text length: {d}\n", .{len});
                if (len > 0) {
                    clipboard_buf[@intCast(len)] = 0;
                    mv_clipboard_set_text(@ptrCast(&clipboard_buf));
                    std.debug.print("  Copied to clipboard: {s}\n", .{clipboard_buf[0..@intCast(len)]});
                }
            }
            return;
        } else if (char_code == 'x') {
            // Cut (copy then delete)
            if (g_focus.isFocused(g_text_input1_id)) {
                const len = c.mcore_text_input_get_selected_text(ctx, g_text_input1_id, &clipboard_buf, 4096);
                if (len > 0) {
                    clipboard_buf[@intCast(len)] = 0;
                    mv_clipboard_set_text(@ptrCast(&clipboard_buf));
                    // Delete the selection by sending a backspace event
                    var event = c.mcore_text_event_t{
                        .kind = c.TEXT_EVENT_BACKSPACE,
                        .char_code = 0,
                        .direction = c.CURSOR_LEFT,
                        .extend_selection = 0,
                        .cursor_position = 0,
                        .text_ptr = null,
                    };
                    _ = c.mcore_text_input_event(ctx, g_text_input1_id, &event);
                }
            } else if (g_focus.isFocused(g_text_input2_id)) {
                const len = c.mcore_text_input_get_selected_text(ctx, g_text_input2_id, &clipboard_buf, 4096);
                if (len > 0) {
                    clipboard_buf[@intCast(len)] = 0;
                    mv_clipboard_set_text(@ptrCast(&clipboard_buf));
                    var event = c.mcore_text_event_t{
                        .kind = c.TEXT_EVENT_BACKSPACE,
                        .char_code = 0,
                        .direction = c.CURSOR_LEFT,
                        .extend_selection = 0,
                        .cursor_position = 0,
                        .text_ptr = null,
                    };
                    _ = c.mcore_text_input_event(ctx, g_text_input2_id, &event);
                }
            }
            return;
        } else if (char_code == 'v') {
            // Paste
            const len = mv_clipboard_get_text(&clipboard_buf, 4096);
            if (len > 0) {
                clipboard_buf[@intCast(len)] = 0;
                var event = c.mcore_text_event_t{
                    .kind = c.TEXT_EVENT_INSERT_TEXT,
                    .char_code = 0,
                    .direction = c.CURSOR_LEFT,
                    .extend_selection = 0,
                    .cursor_position = 0,
                    .text_ptr = @ptrCast(&clipboard_buf),
                };
                if (g_focus.isFocused(g_text_input1_id)) {
                    _ = c.mcore_text_input_event(ctx, g_text_input1_id, &event);
                } else if (g_focus.isFocused(g_text_input2_id)) {
                    _ = c.mcore_text_input_event(ctx, g_text_input2_id, &event);
                }
            }
            return;
        }
    }

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
            _ = g_text_input1.handleKey(ctx, g_text_input1_id, key, char_code, shift);
        } else if (g_focus.isFocused(g_text_input2_id)) {
            _ = g_text_input2.handleKey(ctx, g_text_input2_id, key, char_code, shift);
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

            // Special handling for debug toggle button
            if (id == g_debug_button_id) {
                g_debug_bounds = !g_debug_bounds;
                std.debug.print("Debug bounds toggled: {}\n", .{g_debug_bounds});
            }

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

        // Check if we clicked in a text input first
        if (g_ctx) |ctx| {
            if (g_text_input1.containsPoint(x, y)) {
                g_text_input1.handleMouseDown(ctx, g_text_input1_id, x, y);
                g_focus.setFocus(g_text_input1_id);
                return;
            } else if (g_text_input2.containsPoint(x, y)) {
                g_text_input2.handleMouseDown(ctx, g_text_input2_id, x, y);
                g_focus.setFocus(g_text_input2_id);
                return;
            }
        }

        // Otherwise check if we clicked a button
        checkButtonClick();
    } else if (event_type == MOUSE_UP) {
        g_mouse_down = false;
    } else if (event_type == MOUSE_MOVED and g_mouse_down) {
        // Handle drag events for text selection
        if (g_ctx) |ctx| {
            if (g_focus.isFocused(g_text_input1_id) and g_text_input1.containsPoint(g_mouse_x, g_mouse_y)) {
                g_text_input1.handleMouseDrag(ctx, g_text_input1_id, x, y);
            } else if (g_focus.isFocused(g_text_input2_id) and g_text_input2.containsPoint(g_mouse_x, g_mouse_y)) {
                g_text_input2.handleMouseDrag(ctx, g_text_input2_id, x, y);
            }
        }
    }
}

const ButtonSize = struct {
    width: f32,
    height: f32,
};

fn measureButton(ctx: *c.mcore_context_t, label: [*:0]const u8) ButtonSize {
    const padding_x: f32 = 20;
    const padding_y: f32 = 15;
    const font_size: f32 = 18;

    var text_size: c.mcore_text_size_t = undefined;
    c.mcore_measure_text(ctx, label, font_size, 1000, &text_size); // Large max_width to avoid wrapping

    return .{
        .width = text_size.width + (padding_x * 2),
        .height = text_size.height + (padding_y * 2),
    };
}

fn drawButton(ctx: *c.mcore_context_t, label: [*:0]const u8, x: f32, y: f32, width: f32, height: f32, id: u64, is_focused: bool) void {
    // Store button bounds for hit testing
    if (g_button_count < MAX_BUTTONS) {
        g_button_bounds[g_button_count] = .{ .x = x, .y = y, .width = width, .height = height };
        g_button_ids[g_button_count] = id;
        g_button_count += 1;
    }

    // Draw button background
    const bg_color = if (is_focused)
        [4]f32{ 0.4, 0.5, 0.8, 1.0 }
    else
        [4]f32{ 0.3, 0.3, 0.4, 1.0 };

    g_cmd_buffer.roundedRect(x, y, width, height, 8, bg_color) catch {};

    // Measure text for vertical centering
    var text_size: c.mcore_text_size_t = undefined;
    const padding_x: f32 = 20;
    c.mcore_measure_text(ctx, label, 18, width - (padding_x * 2), &text_size);

    // Center text both horizontally and vertically
    const text_x = x + (width - text_size.width) / 2.0;
    const text_y = y + (height - text_size.height) / 2.0;

    // Draw button text
    const text_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
    g_cmd_buffer.text(label, text_x, text_y, 18, text_size.width, text_color) catch {};

    // Debug bounds
    if (g_debug_bounds) {
        const debug_color = [4]f32{ 0.0, 1.0, 0.0, 0.9 }; // Green for interactive widgets
        const rect = layout_mod.Rect{ .x = 0, .y = 0, .width = width, .height = height };
        drawDebugRect(rect, x, y, debug_color);
    }
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

fn drawDebugRect(rect: layout_mod.Rect, offset_x: f32, offset_y: f32, color: [4]f32) void {
    const x = rect.x + offset_x;
    const y = rect.y + offset_y;
    const w = rect.width;
    const h = rect.height;
    const line_width: f32 = 2;

    // Draw 4 edges as thin rectangles to create an outline
    // Top edge
    g_cmd_buffer.roundedRect(x, y, w, line_width, 0, color) catch {};
    // Bottom edge
    g_cmd_buffer.roundedRect(x, y + h - line_width, w, line_width, 0, color) catch {};
    // Left edge
    g_cmd_buffer.roundedRect(x, y, line_width, h, 0, color) catch {};
    // Right edge
    g_cmd_buffer.roundedRect(x + w - line_width, y, line_width, h, 0, color) catch {};
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

// IME callback implementations
fn on_ime_commit(text: [*:0]const u8) callconv(.c) void {
    const focused_id = g_focus.focused_id orelse return;
    if (g_ctx) |ctx| {
        c.mcore_ime_commit(ctx, focused_id, text);
    }
}

fn on_ime_preedit(text: [*:0]const u8, cursor_offset: c_int) callconv(.c) void {
    const focused_id = g_focus.focused_id orelse return;
    if (g_ctx) |ctx| {
        const preedit = c.mcore_ime_preedit_t{
            .text = text,
            .cursor_offset = cursor_offset,
        };
        c.mcore_ime_set_preedit(ctx, focused_id, &preedit);
    }
}

fn on_ime_cursor_rect() callconv(.c) ImeRect {
    // Return the actual cursor position for IME candidate window
    return ImeRect{
        .x = g_ime_cursor_x,
        .y = g_ime_cursor_y,
        .w = 2,
        .h = g_ime_cursor_h,
    };
}

fn on_a11y_action(widget_id: u64, action_code: u8) callconv(.c) void {
    std.debug.print("A11y action: widget_id={}, action={}\n", .{ widget_id, action_code });

    // Action codes: 0 = Focus, 1 = Click
    switch (action_code) {
        0 => {
            // Focus action
            std.debug.print("Setting focus to widget {}\n", .{widget_id});
            g_focus.setFocus(widget_id);
        },
        1 => {
            // Click action
            std.debug.print("Click on widget {}\n", .{widget_id});
            // Check if it's a button by looking in g_button_ids
            for (g_button_ids[0..g_button_count], 0..) |bid, i| {
                if (bid == widget_id) {
                    std.debug.print("Button {} clicked via VoiceOver!\n", .{i + 1});
                    // Handle button click
                    if (widget_id == g_debug_button_id) {
                        g_debug_bounds = !g_debug_bounds;
                    }
                    // Set focus too
                    g_focus.setFocus(widget_id);
                    break;
                }
            }
        },
        else => {},
    }
}

fn buildA11yTree(ctx: *c.mcore_context_t) !void {
    const WINDOW_ID: u64 = 1;
    // Use actual widget IDs from the focus system
    const TEXT_INPUT_1_ID: u64 = g_text_input1_id;
    const TEXT_INPUT_2_ID: u64 = g_text_input2_id;
    // Button IDs from g_button_ids array (set during rendering)
    const BUTTON_1_ID: u64 = if (g_button_count > 0) g_button_ids[0] else 100;
    const BUTTON_2_ID: u64 = if (g_button_count > 1) g_button_ids[1] else 101;
    const BUTTON_3_ID: u64 = if (g_button_count > 2) g_button_ids[2] else 102;
    const DEBUG_BUTTON_ID: u64 = if (g_button_count > 3) g_button_ids[3] else g_debug_button_id;

    var tree = a11y_mod.TreeBuilder.init(g_allocator, WINDOW_ID);
    defer tree.deinit();

    // Root window node
    var window_node = a11y_mod.Node.init(
        g_allocator,
        WINDOW_ID,
        .Window,
        .{ .x = 0, .y = 0, .width = g_window_width, .height = g_window_height },
    );
    window_node.setLabel("Zello - Phase 4: Text Input");

    // Add buttons as children
    try window_node.addChild(BUTTON_1_ID);
    try window_node.addChild(BUTTON_2_ID);
    try window_node.addChild(BUTTON_3_ID);
    try window_node.addChild(DEBUG_BUTTON_ID);
    try window_node.addChild(TEXT_INPUT_1_ID);
    try window_node.addChild(TEXT_INPUT_2_ID);

    try tree.addNode(window_node);

    // Button 1
    if (g_button_count > 0) {
        const b = g_button_bounds[0];
        var btn1 = a11y_mod.Node.init(g_allocator, BUTTON_1_ID, .Button, .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height });
        btn1.setLabel("Button 1");
        btn1.addAction(a11y_mod.Actions.Focus);
        btn1.addAction(a11y_mod.Actions.Click);
        try tree.addNode(btn1);
    }

    // Button 2
    if (g_button_count > 1) {
        const b = g_button_bounds[1];
        var btn2 = a11y_mod.Node.init(g_allocator, BUTTON_2_ID, .Button, .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height });
        btn2.setLabel("Button 2");
        btn2.addAction(a11y_mod.Actions.Focus);
        btn2.addAction(a11y_mod.Actions.Click);
        try tree.addNode(btn2);
    }

    // Button 3
    if (g_button_count > 2) {
        const b = g_button_bounds[2];
        var btn3 = a11y_mod.Node.init(g_allocator, BUTTON_3_ID, .Button, .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height });
        btn3.setLabel("Button 3");
        btn3.addAction(a11y_mod.Actions.Focus);
        btn3.addAction(a11y_mod.Actions.Click);
        try tree.addNode(btn3);
    }

    // Debug button
    if (g_button_count > 3) {
        const b = g_button_bounds[3];
        var debug_btn = a11y_mod.Node.init(g_allocator, DEBUG_BUTTON_ID, .Button, .{ .x = b.x, .y = b.y, .width = b.width, .height = b.height });
        if (g_debug_bounds) {
            debug_btn.setLabel("Debug Bounds: ON");
        } else {
            debug_btn.setLabel("Debug Bounds: OFF");
        }
        debug_btn.addAction(a11y_mod.Actions.Focus);
        debug_btn.addAction(a11y_mod.Actions.Click);
        try tree.addNode(debug_btn);
    }

    // Text Input 1
    var ti1 = a11y_mod.Node.init(g_allocator, TEXT_INPUT_1_ID, .TextInput, .{ .x = g_text_input1.x, .y = g_text_input1.y, .width = g_text_input1.width, .height = g_text_input1.height });
    ti1.setLabel("Text Input 1");

    // Get current text value
    var text_buf: [256]u8 = undefined;
    const len = c.mcore_text_input_get(ctx, g_text_input1_id, &text_buf, 256);
    if (len > 0) {
        ti1.setValue(text_buf[0..@intCast(len)]);
    }

    ti1.addAction(a11y_mod.Actions.Focus);
    try tree.addNode(ti1);

    // Text Input 2
    var ti2 = a11y_mod.Node.init(g_allocator, TEXT_INPUT_2_ID, .TextInput, .{ .x = g_text_input2.x, .y = g_text_input2.y, .width = g_text_input2.width, .height = g_text_input2.height });
    ti2.setLabel("Text Input 2");

    const len2 = c.mcore_text_input_get(ctx, g_text_input2_id, &text_buf, 256);
    if (len2 > 0) {
        ti2.setValue(text_buf[0..@intCast(len2)]);
    }

    ti2.addAction(a11y_mod.Actions.Focus);
    try tree.addNode(ti2);

    // Set focus
    if (g_focus.focused_id) |fid| {
        tree.setFocus(fid);
    } else {
        tree.setFocus(WINDOW_ID);
    }

    // Send to accessibility system
    try tree.update(ctx);
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

        // Create a vertical flex container for the entire UI
        var root_flex = flex_mod.FlexContainer.init(g_allocator, .Vertical);
        defer root_flex.deinit();
        root_flex.gap = 20; // More generous gap between sections
        root_flex.padding = 10;

        // Add sections as children with proper heights
        // Title section (text + spacing)
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 40 }, 0) catch {};

        // Demo 1 section (label + content + spacing)
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 80 }, 0) catch {};

        // Demo 2 section (label + content + spacing)
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 80 }, 0) catch {};

        // Demo 3 section (label + vertical content + spacing)
        // 20 (label) + 20 (gap) + 10 (padding) + 3*50 (items) + 2*8 (gaps) + 10 (padding) = 216
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 216 }, 0) catch {};

        // Interactive buttons section (label + buttons + spacing)
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 100 }, 0) catch {};

        // Debug button section
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 70 }, 0) catch {};

        // Text inputs section (label + 2 inputs + spacing)
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 150 }, 0) catch {};

        // Window size indicator
        root_flex.addChild(.{ .width = g_window_width - 20, .height = 30 }, 0) catch {};

        // Layout the root flex
        const root_constraints = layout_mod.BoxConstraints.loose(g_window_width, g_window_height);
        const sections = root_flex.layout_children(root_constraints) catch &[_]layout_mod.Rect{};
        defer g_allocator.free(sections);

        // Now render each section at its calculated position
        var section_idx: usize = 0;

        // Title
        const title_section = sections[section_idx];
        section_idx += 1;
        const title_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        g_cmd_buffer.text("Zello Flexbox Demo - Resize the window!", title_section.x, title_section.y, 20, title_section.width, title_color) catch {};
        if (g_debug_bounds) {
            const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
            drawDebugRect(title_section, 0, 0, section_debug_color);
        }

        // Demo 1: Horizontal flexbox with fixed sizes
        {
            const demo1_section = sections[section_idx];
            section_idx += 1;
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("1. Horizontal (fixed sizes, gap=15, padding=10)", demo1_section.x, demo1_section.y, 14, demo1_section.width, demo_color) catch {};
            const content_y = demo1_section.y + 20;

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
                drawLabel(@ptrCast(labels[i].ptr), rect, demo1_section.x, content_y, colors[i], 16);
                if (g_debug_bounds) {
                    const debug_color = [4]f32{ 1.0, 0.0, 1.0, 0.8 }; // Magenta outline
                    drawDebugRect(rect, demo1_section.x, content_y, debug_color);
                }
            }

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(demo1_section, 0, 0, section_debug_color);
            }
        }

        // Demo 2: Horizontal with flex spacing
        {
            const demo2_section = sections[section_idx];
            section_idx += 1;
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("2. Horizontal with flex=1 spacers (stretches to window width)", demo2_section.x, demo2_section.y, 14, demo2_section.width, demo_color) catch {};
            const content_y = demo2_section.y + 20;

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
                    drawLabel(@ptrCast(labels[label_idx].ptr), rect, demo2_section.x, content_y, colors[label_idx], 16);
                }
                if (g_debug_bounds) {
                    // Show all rects including spacers
                    const debug_color = if (i % 2 == 0)
                        [4]f32{ 1.0, 0.0, 1.0, 0.8 } // Magenta for content
                    else
                        [4]f32{ 0.0, 1.0, 1.0, 0.6 }; // Cyan for spacers
                    drawDebugRect(rect, demo2_section.x, content_y, debug_color);
                }
            }

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(demo2_section, 0, 0, section_debug_color);
            }
        }

        // Demo 3: Vertical flexbox
        {
            const demo3_section = sections[section_idx];
            section_idx += 1;
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("3. Vertical (gap=8, padding=10)", demo3_section.x, demo3_section.y, 14, demo3_section.width, demo_color) catch {};
            const content_y = demo3_section.y + 20;

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
                drawLabel(@ptrCast(labels[i].ptr), rect, demo3_section.x, content_y, colors[i], 16);
                if (g_debug_bounds) {
                    const debug_color = [4]f32{ 1.0, 0.0, 1.0, 0.8 }; // Magenta outline
                    drawDebugRect(rect, demo3_section.x, content_y, debug_color);
                }
            }

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(demo3_section, 0, 0, section_debug_color);
            }
        }

        // Demo 4: Focusable buttons in horizontal layout
        {
            const demo4_section = sections[section_idx];
            section_idx += 1;
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("4. Interactive buttons (Press Tab to cycle focus)", demo4_section.x, demo4_section.y, 14, demo4_section.width, demo_color) catch {};
            const content_y = demo4_section.y + 25;

            // Measure buttons
            const btn1_size = measureButton(ctx, "Button 1");
            const btn2_size = measureButton(ctx, "Button 2");
            const btn3_size = measureButton(ctx, "Button 3");

            // Create horizontal flex for buttons
            var buttons_flex = flex_mod.FlexContainer.init(g_allocator, .Horizontal);
            defer buttons_flex.deinit();
            buttons_flex.gap = 15;
            buttons_flex.padding = 0;

            buttons_flex.addChild(.{ .width = btn1_size.width, .height = btn1_size.height }, 0) catch {};
            buttons_flex.addChild(.{ .width = btn2_size.width, .height = btn2_size.height }, 0) catch {};
            buttons_flex.addChild(.{ .width = btn3_size.width, .height = btn3_size.height }, 0) catch {};

            const btn_constraints = layout_mod.BoxConstraints.loose(demo4_section.width, 100);
            const btn_rects = buttons_flex.layout_children(btn_constraints) catch &[_]layout_mod.Rect{};
            defer g_allocator.free(btn_rects);

            // Draw buttons at calculated positions
            g_ui.pushID("button1") catch {};
            const button1_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button1_id) catch {};
            const is_focused_1 = g_focus.isFocused(button1_id);
            drawButton(ctx, "Button 1", demo4_section.x + btn_rects[0].x, content_y + btn_rects[0].y, btn_rects[0].width, btn_rects[0].height, button1_id, is_focused_1);
            g_ui.popID();

            g_ui.pushID("button2") catch {};
            const button2_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button2_id) catch {};
            const is_focused_2 = g_focus.isFocused(button2_id);
            drawButton(ctx, "Button 2", demo4_section.x + btn_rects[1].x, content_y + btn_rects[1].y, btn_rects[1].width, btn_rects[1].height, button2_id, is_focused_2);
            g_ui.popID();

            g_ui.pushID("button3") catch {};
            const button3_id = g_ui.getCurrentID();
            g_focus.registerFocusable(button3_id) catch {};
            const is_focused_3 = g_focus.isFocused(button3_id);
            drawButton(ctx, "Button 3", demo4_section.x + btn_rects[2].x, content_y + btn_rects[2].y, btn_rects[2].width, btn_rects[2].height, button3_id, is_focused_3);
            g_ui.popID();

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(demo4_section, 0, 0, section_debug_color);
            }
        }

        // Debug toggle button
        {
            const debug_section = sections[section_idx];
            section_idx += 1;
            g_ui.pushID("debug_button") catch {};
            g_debug_button_id = g_ui.getCurrentID();
            g_focus.registerFocusable(g_debug_button_id) catch {};
            const is_focused_debug = g_focus.isFocused(g_debug_button_id);
            const label = if (g_debug_bounds) "Debug Bounds: ON" else "Debug Bounds: OFF";

            // Measure button
            const debug_btn_size = measureButton(ctx, label);
            drawButton(ctx, label, debug_section.x, debug_section.y, debug_btn_size.width, debug_btn_size.height, g_debug_button_id, is_focused_debug);
            g_ui.popID();

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(debug_section, 0, 0, section_debug_color);
            }
        }

        // Demo 5: Text Input Widgets
        {
            const demo5_section = sections[section_idx];
            section_idx += 1;
            const demo_color = [4]f32{ 0.8, 0.8, 0.8, 1.0 };
            g_cmd_buffer.text("5. Text Input (Press Tab to focus, type to edit)", demo5_section.x, demo5_section.y, 14, demo5_section.width, demo_color) catch {};
            const input_y = demo5_section.y + 25;

            // Text input 1
            g_ui.pushID("textinput1") catch {};
            g_text_input1_id = g_ui.getCurrentID();
            g_focus.registerFocusable(g_text_input1_id) catch {};
            const is_focused_ti1 = g_focus.isFocused(g_text_input1_id);
            g_text_input1.render(ctx, &g_cmd_buffer, g_text_input1_id, 20, input_y, is_focused_ti1, g_debug_bounds);

            // Update IME cursor position if this text input is focused
            if (is_focused_ti1) {
                const cursor_pos = c.mcore_text_input_cursor(ctx, g_text_input1_id);
                const text_len = c.mcore_text_input_get(ctx, g_text_input1_id, &g_text_input1.buffer, 256);
                const text_ptr: [*:0]const u8 = if (text_len > 0) @ptrCast(g_text_input1.buffer[0..@intCast(text_len)].ptr) else "";
                const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
                g_ime_cursor_x = 20 + text_input_mod.TextInput.PADDING_X + cursor_offset_x - g_text_input1.scroll_offset;
                g_ime_cursor_y = input_y;
                g_ime_cursor_h = g_text_input1.height;
            }
            g_ui.popID();

            // Text input 2
            g_ui.pushID("textinput2") catch {};
            g_text_input2_id = g_ui.getCurrentID();
            g_focus.registerFocusable(g_text_input2_id) catch {};
            const is_focused_ti2 = g_focus.isFocused(g_text_input2_id);
            g_text_input2.render(ctx, &g_cmd_buffer, g_text_input2_id, 20, input_y + 50, is_focused_ti2, g_debug_bounds);

            // Update IME cursor position if this text input is focused
            if (is_focused_ti2) {
                const cursor_pos = c.mcore_text_input_cursor(ctx, g_text_input2_id);
                const text_len = c.mcore_text_input_get(ctx, g_text_input2_id, &g_text_input2.buffer, 256);
                const text_ptr: [*:0]const u8 = if (text_len > 0) @ptrCast(g_text_input2.buffer[0..@intCast(text_len)].ptr) else "";
                const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
                g_ime_cursor_x = 20 + text_input_mod.TextInput.PADDING_X + cursor_offset_x - g_text_input2.scroll_offset;
                g_ime_cursor_y = input_y + 50;
                g_ime_cursor_h = g_text_input2.height;
            }
            g_ui.popID();

            if (g_debug_bounds) {
                const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
                drawDebugRect(demo5_section, 0, 0, section_debug_color);
            }
        }

        // Window size indicator
        const size_section = sections[section_idx];
        section_idx += 1;
        var size_buf: [64]u8 = undefined;
        const size_info = std.fmt.bufPrintZ(&size_buf, "Window: {d:.0}x{d:.0}", .{ g_window_width, g_window_height }) catch "Window: ???";
        const size_color = [4]f32{ 0.6, 0.6, 0.6, 1.0 };
        g_cmd_buffer.text(size_info.ptr, size_section.x, size_section.y, 12, 400, size_color) catch {};

        if (g_debug_bounds) {
            const section_debug_color = [4]f32{ 1.0, 1.0, 0.0, 0.6 }; // Yellow for sections
            drawDebugRect(size_section, 0, 0, section_debug_color);
        }

        // Submit all draw commands in a single FFI call
        const cmds = g_cmd_buffer.getCommands();
        c.mcore_render_commands(ctx, @ptrCast(cmds.ptr), @intCast(cmds.count));

        // Build and update accessibility tree
        buildA11yTree(ctx) catch |err| {
            std.debug.print("Failed to build a11y tree: {}\n", .{err});
        };

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
    g_text_input1 = text_input_mod.TextInput.init(400, 40);
    g_text_input2 = text_input_mod.TextInput.init(400, 40);

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

    // Initialize accessibility
    a11y_mod.init(g_ctx, ns_view);
    c.mcore_a11y_set_action_callback(on_a11y_action);

    mv_set_resize_callback(on_resize);
    mv_set_key_callback(on_key);
    mv_set_mouse_callback(on_mouse);
    mv_set_ime_commit_callback(on_ime_commit);
    mv_set_ime_preedit_callback(on_ime_preedit);
    mv_set_ime_cursor_rect_callback(on_ime_cursor_rect);
    mv_set_frame_callback(on_frame);
    mv_app_run();
}
