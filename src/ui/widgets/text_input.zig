const std = @import("std");
const layout_mod = @import("../layout.zig");
const commands_mod = @import("../commands.zig");
const c_api = @import("../../c_api.zig");
const c = c_api.c;

pub const TextInput = struct {
    id: u64,
    buffer: [256]u8 = undefined,
    width: f32,
    height: f32,
    scroll_offset: f32 = 0, // Horizontal scroll for overflow text

    pub fn init(id: u64, width: f32, height: f32) TextInput {
        return .{
            .id = id,
            .width = width,
            .height = height,
        };
    }

    const PADDING_X: f32 = 10;
    const PADDING_Y: f32 = 8;

    /// Render the text input widget
    /// Returns true if the text changed
    pub fn render(
        self: *TextInput,
        ctx: *c.mcore_context_t,
        cmd_buffer: *commands_mod.CommandBuffer,
        x: f32,
        y: f32,
        is_focused: bool,
        debug_bounds: bool,
    ) void {
        // Get current text from Rust
        const len = c.mcore_text_input_get(ctx, self.id, &self.buffer, 256);
        const text = self.buffer[0..@intCast(len)];

        // Draw background
        const bg_color = if (is_focused)
            [4]f32{ 0.3, 0.3, 0.4, 1.0 }
        else
            [4]f32{ 0.2, 0.2, 0.3, 1.0 };

        cmd_buffer.roundedRect(x, y, self.width, self.height, 4, bg_color) catch {};

        // Draw border if focused
        if (is_focused) {
            const border_color = [4]f32{ 0.5, 0.7, 1.0, 1.0 };
            // Draw a simple border by drawing a slightly larger rect behind
            cmd_buffer.roundedRect(x - 2, y - 2, self.width + 4, self.height + 4, 6, border_color) catch {};
            cmd_buffer.roundedRect(x, y, self.width, self.height, 4, bg_color) catch {};
        }

        // Measure text to get proper height for vertical centering
        // Use large max_width to prevent wrapping in single-line input
        const max_width_no_wrap: f32 = 100000;
        var text_size: c.mcore_text_size_t = undefined;
        const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
        c.mcore_measure_text(ctx, text_ptr, 16, max_width_no_wrap, &text_size);

        // Center text vertically
        const text_y = y + (self.height - text_size.height) / 2.0;

        // Calculate scroll offset to keep cursor visible (do this before rendering)
        const visible_width = self.width - (PADDING_X * 2);
        if (is_focused) {
            const cursor_pos = c.mcore_text_input_cursor(ctx, self.id);
            const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
            const cursor_right_margin: f32 = 20;

            // If cursor is past the right edge, scroll left
            if (cursor_offset_x - self.scroll_offset > visible_width - cursor_right_margin) {
                self.scroll_offset = cursor_offset_x - visible_width + cursor_right_margin;
            }
            // If cursor is before the left edge, scroll right
            if (cursor_offset_x < self.scroll_offset) {
                self.scroll_offset = cursor_offset_x;
            }
            // Don't scroll past the beginning
            if (self.scroll_offset < 0) {
                self.scroll_offset = 0;
            }
        }

        // Push clip rect to prevent text overflow
        cmd_buffer.pushClip(x, y, self.width, self.height) catch {};

        // Draw text with scroll offset applied
        const text_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const text_x = x + PADDING_X - self.scroll_offset;
        cmd_buffer.text(text_ptr, text_x, text_y, 16, max_width_no_wrap, text_color) catch {};

        // Draw cursor if focused
        if (is_focused) {
            const cursor_pos = c.mcore_text_input_cursor(ctx, self.id);
            const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
            const cursor_x = x + PADDING_X + cursor_offset_x - self.scroll_offset;
            const cursor_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

            // Draw cursor as a thin vertical line, height based on line height
            const cursor_height = text_size.height;
            cmd_buffer.roundedRect(cursor_x, text_y, 2, cursor_height, 1, cursor_color) catch {};
        }

        // Pop clip rect
        cmd_buffer.popClip() catch {};

        // Debug bounds
        if (debug_bounds) {
            const debug_color = [4]f32{ 0.0, 1.0, 0.0, 0.9 }; // Green for interactive widgets
            const line_width: f32 = 2;
            // Top edge
            cmd_buffer.roundedRect(x, y, self.width, line_width, 0, debug_color) catch {};
            // Bottom edge
            cmd_buffer.roundedRect(x, y + self.height - line_width, self.width, line_width, 0, debug_color) catch {};
            // Left edge
            cmd_buffer.roundedRect(x, y, line_width, self.height, 0, debug_color) catch {};
            // Right edge
            cmd_buffer.roundedRect(x + self.width - line_width, y, line_width, self.height, 0, debug_color) catch {};
        }
    }

    /// Handle keyboard input
    pub fn handleKey(
        self: *TextInput,
        ctx: *c.mcore_context_t,
        key: c_int,
        char_code: u32,
        shift: bool,
    ) bool {
        var event = c.mcore_text_event_t{
            .kind = c.TEXT_EVENT_INSERT_CHAR,
            .char_code = 0,
            .direction = c.CURSOR_LEFT,
            .extend_selection = 0,
            .cursor_position = 0,
            .text_ptr = null,
        };

        // Map key codes to events
        // macOS key codes
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
            // Don't handle these keys in text input
            return false;
        } else if (char_code > 0) {
            // Regular character
            event.kind = c.TEXT_EVENT_INSERT_CHAR;
            event.char_code = char_code;
        } else {
            // Unknown key
            return false;
        }

        event.extend_selection = if (shift) 1 else 0;

        const changed = c.mcore_text_input_event(ctx, self.id, &event);
        return changed != 0;
    }

    /// Get the current text content
    pub fn getText(self: *TextInput, ctx: *c.mcore_context_t) []const u8 {
        const len = c.mcore_text_input_get(ctx, self.id, &self.buffer, 256);
        return self.buffer[0..@intCast(len)];
    }

    /// Set the text content
    pub fn setText(self: *TextInput, ctx: *c.mcore_context_t, text: []const u8) void {
        // Ensure null termination
        var temp_buf: [256]u8 = undefined;
        const len = @min(text.len, 255);
        @memcpy(temp_buf[0..len], text[0..len]);
        temp_buf[len] = 0;

        c.mcore_text_input_set(ctx, self.id, @ptrCast(&temp_buf));
    }
};
