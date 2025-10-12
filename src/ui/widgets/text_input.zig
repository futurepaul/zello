const std = @import("std");
const layout_mod = @import("../layout.zig");
const context_mod = @import("../core/context.zig");
const state_mod = @import("../core/state.zig");
const a11y_mod = @import("../a11y.zig");
const color_mod = @import("../color.zig");
const Color = color_mod.Color;
const c_api = @import("../../renderer/c_api.zig");
const c = c_api.c;

pub const PADDING_X: f32 = 10;
pub const PADDING_Y: f32 = 8;

/// Text input widget options
pub const Options = struct {
    width: f32 = 200,
    height: f32 = 40,
};

/// Measure text input dimensions
pub fn measure(ctx: *context_mod.WidgetContext, opts: Options) layout_mod.Size {
    _ = ctx;
    return .{ .width = opts.width, .height = opts.height };
}

/// Render text input widget
pub fn render(
    ctx: *context_mod.WidgetContext,
    id: u64,
    id_str: []const u8,
    buffer: []u8,
    opts: Options,
    x: f32,
    y: f32,
) !void {
    // Get or create text input state
    const widget_state = try ctx.getOrPutTextInput(id, opts.width, opts.height);

    // Register as focusable
    try ctx.registerFocusable(id);
    const is_focused = ctx.isFocused(id);

    // Store position for hit testing
    widget_state.x = x;
    widget_state.y = y;

    // Get current text from Rust
    const len = c.mcore_text_input_get(ctx.ctx, id, &widget_state.buffer, 256);
    const text = widget_state.buffer[0..@intCast(len)];

    // Draw background
    const bg_color = if (is_focused)
        color_mod.rgba(0.3, 0.3, 0.4, 1.0)
    else
        color_mod.rgba(0.2, 0.2, 0.3, 1.0);

    const cmd_buffer = ctx.commandBuffer();
    try cmd_buffer.roundedRect(x, y, opts.width, opts.height, 4, bg_color);

    // Draw border if focused
    if (is_focused) {
        const border_color = color_mod.rgba(0.5, 0.7, 1.0, 1.0);
        try cmd_buffer.roundedRect(x - 2, y - 2, opts.width + 4, opts.height + 4, 6, border_color);
        try cmd_buffer.roundedRect(x, y, opts.width, opts.height, 4, bg_color);
    }

    // Measure text
    const max_width_no_wrap: f32 = 100000;
    const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
    const text_size = ctx.measureText(text, 16, max_width_no_wrap);

    const text_y = y + (opts.height - text_size.height) / 2.0;

    // Calculate scroll offset
    const visible_width = opts.width - (PADDING_X * 2);
    if (is_focused) {
        const cursor_pos = c.mcore_text_input_cursor(ctx.ctx, id);
        const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx.ctx, text_ptr, 16, cursor_pos);
        const cursor_right_margin: f32 = 20;

        if (cursor_offset_x - widget_state.scroll_offset > visible_width - cursor_right_margin) {
            widget_state.scroll_offset = cursor_offset_x - visible_width + cursor_right_margin;
        }
        if (cursor_offset_x < widget_state.scroll_offset) {
            widget_state.scroll_offset = cursor_offset_x;
        }
        if (widget_state.scroll_offset < 0) {
            widget_state.scroll_offset = 0;
        }
    }

    // Push clip rect
    try cmd_buffer.pushClip(x, y, opts.width, opts.height);

    // Draw selection highlight
    var sel_start: c_int = 0;
    var sel_end: c_int = 0;
    const has_selection = c.mcore_text_input_get_selection(ctx.ctx, id, &sel_start, &sel_end);
    if (has_selection != 0 and sel_start < sel_end) {
        const sel_start_x = c.mcore_measure_text_to_byte_offset(ctx.ctx, text_ptr, 16, sel_start);
        const sel_end_x = c.mcore_measure_text_to_byte_offset(ctx.ctx, text_ptr, 16, sel_end);

        const highlight_x = x + PADDING_X + sel_start_x - widget_state.scroll_offset;
        const highlight_width = sel_end_x - sel_start_x;

        const selection_color = color_mod.rgba(0.3, 0.5, 0.8, 0.5);
        try cmd_buffer.roundedRect(highlight_x, text_y, highlight_width, text_size.height, 2, selection_color);
    }

    // Draw text
    const text_color = color_mod.WHITE;
    const text_x = x + PADDING_X - widget_state.scroll_offset;
    // Only draw text if there's content
    if (text.len > 0) {
        try ctx.drawText(text_ptr, text_x, text_y, 16, max_width_no_wrap, text_color);
    }

    // Draw cursor
    if (is_focused) {
        const cursor_pos = c.mcore_text_input_cursor(ctx.ctx, id);
        const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx.ctx, text_ptr, 16, cursor_pos);
        const cursor_x = x + PADDING_X + cursor_offset_x - widget_state.scroll_offset;
        const cursor_color = color_mod.WHITE;
        try cmd_buffer.roundedRect(cursor_x, text_y, 1, text_size.height, 0.5, cursor_color);
    }

    // Pop clip rect
    try cmd_buffer.popClip();

    // Track for hit testing
    try ctx.registerClickable(id, .TextInput, .{ .x = x, .y = y, .width = opts.width, .height = opts.height });

    // Debug bounds (magenta for text inputs)
    ctx.drawDebugRect(x, y, opts.width, opts.height, color_mod.rgba(1, 0, 1, 0.9));

    // Add to accessibility tree
    var a11y_node = a11y_mod.Node.init(ctx.allocator, id, .TextInput, .{
        .x = x,
        .y = y,
        .width = opts.width,
        .height = opts.height,
    });
    a11y_node.setLabel(id_str);

    if (len > 0) {
        a11y_node.setValue(widget_state.buffer[0..@intCast(len)]);
    }

    a11y_node.addAction(a11y_mod.Actions.Focus);
    try ctx.addA11yNode(a11y_node);

    // Update buffer if changed
    const current_text = widget_state.buffer[0..@intCast(len)];
    const changed = !std.mem.eql(u8, current_text, buffer[0..@min(current_text.len, buffer.len)]);
    if (changed and current_text.len <= buffer.len) {
        @memcpy(buffer[0..current_text.len], current_text);
    }
}

/// Handle keyboard input for text input widget
pub fn handleKey(
    ctx: *context_mod.WidgetContext,
    id: u64,
    key: c_int,
    char_code: u32,
    shift: bool,
    cmd: bool,
) bool {
    _ = cmd; // TODO: Handle cmd+a, cmd+c, cmd+v

    var event = c.mcore_text_event_t{
        .kind = c.TEXT_EVENT_INSERT_CHAR,
        .char_code = 0,
        .direction = c.CURSOR_LEFT,
        .extend_selection = 0,
        .cursor_position = 0,
        .text_ptr = null,
    };

    // Map key codes
    const KEY_BACKSPACE = 51;
    const KEY_DELETE = 117;
    const KEY_LEFT = 123;
    const KEY_RIGHT = 124;
    const KEY_HOME = 115;
    const KEY_END = 119;
    const KEY_RETURN = 36;
    const KEY_ESC = 53;
    const KEY_TAB = 48;

    if (key == KEY_BACKSPACE) {
        event.kind = c.TEXT_EVENT_BACKSPACE;
    } else if (key == KEY_DELETE) {
        event.kind = c.TEXT_EVENT_DELETE;
    } else if (key == KEY_LEFT) {
        event.kind = c.TEXT_EVENT_MOVE_CURSOR;
        event.direction = c.CURSOR_LEFT;
    } else if (key == KEY_RIGHT) {
        event.kind = c.TEXT_EVENT_MOVE_CURSOR;
        event.direction = c.CURSOR_RIGHT;
    } else if (key == KEY_HOME) {
        event.kind = c.TEXT_EVENT_MOVE_CURSOR;
        event.direction = c.CURSOR_HOME;
    } else if (key == KEY_END) {
        event.kind = c.TEXT_EVENT_MOVE_CURSOR;
        event.direction = c.CURSOR_END;
    } else if (key == KEY_RETURN or key == KEY_ESC or key == KEY_TAB) {
        return false;
    } else if (char_code > 0) {
        event.kind = c.TEXT_EVENT_INSERT_CHAR;
        event.char_code = char_code;
    } else {
        return false;
    }

    event.extend_selection = if (shift) 1 else 0;

    const changed = c.mcore_text_input_event(ctx.ctx, id, &event);
    return changed != 0;
}
