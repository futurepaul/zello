const std = @import("std");
const id_mod = @import("id.zig");
const focus_mod = @import("focus.zig");
const commands_mod = @import("commands.zig");
const a11y_mod = @import("a11y.zig");
const layout_mod = @import("layout.zig");
const flex_mod = @import("flex.zig");
const c_api = @import("../renderer/c_api.zig");
const c = c_api.c;

/// Main UI context - holds all state for immediate-mode UI
pub const UI = struct {
    // Core systems (internal)
    ctx: *c.mcore_context_t,
    id_system: id_mod.UI,
    focus: focus_mod.FocusState,
    commands: commands_mod.CommandBuffer,
    a11y_builder: a11y_mod.TreeBuilder,

    // Layout stack (TODO: support nesting in future)
    layout_stack: std.ArrayList(LayoutFrame),

    // Window properties
    width: f32,
    height: f32,

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false, // True for one frame after mouse up

    // Widget tracking for hit testing
    clickable_widgets: std.ArrayList(ClickableWidget),

    // Text input widgets (keyed by ID)
    text_inputs: std.AutoHashMap(u64, TextInputWidget),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *c.mcore_context_t, width: f32, height: f32) !UI {
        return .{
            .ctx = ctx,
            .id_system = id_mod.UI.init(allocator),
            .focus = focus_mod.FocusState.init(allocator),
            .commands = try commands_mod.CommandBuffer.init(allocator, 1000),
            .a11y_builder = a11y_mod.TreeBuilder.init(allocator, 1), // root ID
            .layout_stack = std.ArrayList(LayoutFrame){},
            .width = width,
            .height = height,
            .clickable_widgets = std.ArrayList(ClickableWidget){},
            .text_inputs = std.AutoHashMap(u64, TextInputWidget).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UI) void {
        self.id_system.deinit();
        self.focus.deinit();
        self.commands.deinit();
        self.a11y_builder.deinit();
        self.layout_stack.deinit(self.allocator);
        self.clickable_widgets.deinit(self.allocator);
        self.text_inputs.deinit();
    }

    pub fn beginFrame(self: *UI) void {
        self.commands.reset();
        self.focus.beginFrame();
        self.clickable_widgets.clearRetainingCapacity();

        self.a11y_builder.deinit();
        self.a11y_builder = a11y_mod.TreeBuilder.init(self.allocator, 1);
    }

    pub fn endFrame(self: *UI, clear_color: [4]f32) !void {
        // Submit draw commands
        const cmds = self.commands.getCommands();
        c.mcore_render_commands(self.ctx, @ptrCast(cmds.ptr), @intCast(cmds.count));

        // Submit accessibility tree
        if (self.focus.focused_id) |fid| {
            self.a11y_builder.setFocus(fid);
        }
        try self.a11y_builder.update(self.ctx);

        // Present
        const clear = c.mcore_rgba_t{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] };
        const st = c.mcore_end_frame_present(self.ctx, clear);
        if (st != c.MCORE_OK) {
            const err = c.mcore_last_error();
            if (err != null) std.debug.print("mcore error: {s}\n", .{std.mem.span(err)});
        }

        self.mouse_clicked = false;
    }

    pub fn updateSize(self: *UI, width: f32, height: f32) void {
        self.width = width;
        self.height = height;
    }

    // ============================================================================
    // Input Handling
    // ============================================================================

    pub fn handleMouseDown(self: *UI, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_down = true;

        // For text inputs, we need to handle mouse down immediately to position cursor
        // We check the PREVIOUS frame's clickable_widgets since current frame hasn't rendered yet
        // This is OK because text inputs are stateful and persist across frames
        for (self.clickable_widgets.items) |widget| {
            if (widget.kind == .TextInput and widget.bounds.contains(x, y)) {
                // Handle text input mouse down
                if (self.text_inputs.getPtr(widget.id)) |ti| {
                    const local_x = x - (widget.bounds.x + TextInputWidget.PADDING_X) + ti.scroll_offset;
                    const len = c.mcore_text_input_get(self.ctx, widget.id, @constCast(&ti.buffer), 256);
                    const text = ti.buffer[0..@intCast(len)];
                    const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
                    const byte_offset = findByteOffsetAtX(self.ctx, text_ptr, 16, local_x);
                    c.mcore_text_input_start_selection(self.ctx, widget.id, @intCast(byte_offset));
                }
                self.focus.setFocus(widget.id);
                return;
            }
        }

        // For buttons, focus is set, but click is detected in wasClicked() next frame
        for (self.clickable_widgets.items) |widget| {
            if (widget.kind == .Button and widget.bounds.contains(x, y)) {
                self.focus.setFocus(widget.id);
                return;
            }
        }
    }

    pub fn handleMouseUp(self: *UI, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_down = false;
        self.mouse_clicked = true;
    }

    pub fn handleMouseMove(self: *UI, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;

        // Handle drag for text selection
        if (self.mouse_down) {
            if (self.focus.focused_id) |fid| {
                for (self.clickable_widgets.items) |widget| {
                    if (widget.kind == .TextInput and widget.id == fid and widget.bounds.contains(x, y)) {
                        if (self.text_inputs.getPtr(widget.id)) |ti| {
                            const local_x = x - (widget.bounds.x + TextInputWidget.PADDING_X) + ti.scroll_offset;
                            const len = c.mcore_text_input_get(self.ctx, widget.id, @constCast(&ti.buffer), 256);
                            const text = ti.buffer[0..@intCast(len)];
                            const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
                            const byte_offset = findByteOffsetAtX(self.ctx, text_ptr, 16, local_x);
                            c.mcore_text_input_set_cursor_pos(self.ctx, widget.id, @intCast(byte_offset), 1);
                        }
                        return;
                    }
                }
            }
        }
    }

    pub fn handleKey(self: *UI, key: c_int, char_code: u32, shift: bool, cmd: bool) void {
        const KEY_TAB = 48;

        // Handle Tab navigation
        if (key == KEY_TAB) {
            if (shift) {
                self.focus.focusPrev();
            } else {
                self.focus.focusNext();
            }
            return;
        }

        // Forward to focused text input
        if (self.focus.focused_id) |fid| {
            if (self.text_inputs.getPtr(fid)) |ti| {
                _ = ti.handleKey(self.ctx, fid, key, char_code, shift, cmd);
            }
        }
    }

    // ============================================================================
    // Layout System
    // ============================================================================

    pub fn beginVstack(self: *UI, opts: VstackOptions) !void {
        // TODO: No nesting support yet - panic if we try
        if (self.layout_stack.items.len > 0) {
            @panic("Layout nesting not yet supported! Only one begin/end pair allowed per frame.");
        }

        var flex = flex_mod.FlexContainer.init(self.allocator, .Vertical);
        flex.gap = opts.gap;
        flex.padding = opts.padding;

        try self.layout_stack.append(self.allocator, .{
            .kind = .Vstack,
            .flex = flex,
            .x = opts.padding,
            .y = opts.padding,
            .current_pos = opts.padding,
        });
    }

    pub fn endVstack(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endVstack called without matching beginVstack!");
        }

        var frame = self.layout_stack.pop() orelse unreachable;
        defer frame.flex.deinit();

        // Do layout at root level
        const constraints = layout_mod.BoxConstraints.loose(self.width, self.height);
        _ = frame.flex.layout_children(constraints) catch return;
        // Note: We don't use the rects here because widgets already drew themselves
        // This is the simple immediate-mode approach - widgets draw as they're created
    }

    pub fn beginHstack(self: *UI, opts: HstackOptions) !void {
        // TODO: No nesting support yet - panic if we try
        if (self.layout_stack.items.len > 0) {
            @panic("Layout nesting not yet supported! Only one begin/end pair allowed per frame.");
        }

        var flex = flex_mod.FlexContainer.init(self.allocator, .Horizontal);
        flex.gap = opts.gap;
        flex.padding = opts.padding;

        try self.layout_stack.append(self.allocator, .{
            .kind = .Hstack,
            .flex = flex,
            .x = opts.padding,
            .y = opts.padding,
            .current_pos = opts.padding,
        });
    }

    pub fn endHstack(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endHstack called without matching beginHstack!");
        }

        var frame = self.layout_stack.pop() orelse unreachable;
        defer frame.flex.deinit();

        const constraints = layout_mod.BoxConstraints.loose(self.width, self.height);
        _ = frame.flex.layout_children(constraints) catch return;
    }

    // ============================================================================
    // ID Management (Manual - for advanced users)
    // ============================================================================

    pub fn pushID(self: *UI, id_str: []const u8) !void {
        try self.id_system.pushID(id_str);
    }

    pub fn pushIDInt(self: *UI, int_id: u64) !void {
        try self.id_system.pushIDInt(int_id);
    }

    pub fn popID(self: *UI) void {
        self.id_system.popID();
    }

    // ============================================================================
    // Widgets
    // ============================================================================

    pub fn label(self: *UI, text: [:0]const u8, opts: LabelOptions) !void {
        const size = self.measureText(text, opts.size, self.width);
        const width = size.width + (opts.padding * 2);
        const height = size.height + (opts.padding * 2);
        const pos = try self.allocateSpace(width, height);

        // Draw background if specified
        if (opts.bg_color) |bg| {
            try self.commands.roundedRect(pos.x, pos.y, width, height, 4, bg);
        }

        // Draw text
        const text_x = pos.x + opts.padding;
        const text_y = pos.y + opts.padding;
        try self.commands.text(text, text_x, text_y, opts.size, size.width, opts.color);

        // Labels are not interactive, so no accessibility node needed
    }

    pub fn button(self: *UI, label_text: [:0]const u8, opts: ButtonOptions) !bool {
        // Auto-generate ID from label
        const id_str = opts.id orelse label_text;
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        defer self.id_system.popID();

        // Register as focusable
        try self.focus.registerFocusable(id);
        const is_focused = self.focus.isFocused(id);

        // Measure button
        const padding_x: f32 = 20;
        const padding_y: f32 = 15;
        const font_size: f32 = 18;

        const text_size = self.measureText(label_text, font_size, 1000);
        const width = opts.width orelse (text_size.width + padding_x * 2);
        const height = opts.height orelse (text_size.height + padding_y * 2);

        const pos = try self.allocateSpace(width, height);

        // Check if hovered or pressed
        const bounds = layout_mod.Rect{ .x = pos.x, .y = pos.y, .width = width, .height = height };
        const is_hovered = bounds.contains(self.mouse_x, self.mouse_y);
        const is_pressed = is_hovered and self.mouse_down;

        // Draw background with visual states
        const bg_color = if (is_pressed)
            [4]f32{ 0.5, 0.6, 0.9, 1.0 } // Lighter blue when pressed
        else if (is_focused)
            [4]f32{ 0.4, 0.5, 0.8, 1.0 } // Blue when focused
        else if (is_hovered)
            [4]f32{ 0.35, 0.35, 0.45, 1.0 } // Slightly lighter when hovered
        else
            [4]f32{ 0.3, 0.3, 0.4, 1.0 }; // Default

        try self.commands.roundedRect(pos.x, pos.y, width, height, 8, bg_color);

        // Draw text (centered)
        const text_x = pos.x + (width - text_size.width) / 2.0;
        const text_y = pos.y + (height - text_size.height) / 2.0;
        try self.commands.text(label_text, text_x, text_y, font_size, text_size.width, .{ 1, 1, 1, 1 });

        // Track for hit testing
        try self.clickable_widgets.append(self.allocator, .{
            .id = id,
            .kind = .Button,
            .bounds = .{ .x = pos.x, .y = pos.y, .width = width, .height = height },
        });

        // Add to accessibility tree
        var a11y_node = a11y_mod.Node.init(self.allocator, id, .Button, .{
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .height = height,
        });
        a11y_node.setLabel(label_text);
        a11y_node.addAction(a11y_mod.Actions.Focus);
        a11y_node.addAction(a11y_mod.Actions.Click);
        try self.a11y_builder.addNode(a11y_node);

        // Check if clicked
        const clicked = self.wasClicked(pos.x, pos.y, width, height);
        return clicked;
    }

    pub fn spacer(self: *UI, flex: f32) !void {
        if (self.layout_stack.items.len == 0) {
            @panic("spacer() called outside layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.flex.addSpacer(flex);

        // Spacers don't draw anything, but they affect layout
        // In immediate mode, the space is "consumed" but nothing renders
        // This works because allocateSpace is called by actual widgets, not spacers
    }

    pub fn textInput(self: *UI, id_str: []const u8, buffer: []u8, opts: TextInputOptions) !bool {
        // Generate ID
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        defer self.id_system.popID();

        // Get or create text input widget
        const gop = try self.text_inputs.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = TextInputWidget.init(opts.width, opts.height);
        }
        const widget = gop.value_ptr;

        // Register as focusable
        try self.focus.registerFocusable(id);
        const is_focused = self.focus.isFocused(id);

        const pos = try self.allocateSpace(opts.width, opts.height);

        // Store position for hit testing
        widget.x = pos.x;
        widget.y = pos.y;

        // Render
        widget.render(self.ctx, &self.commands, id, pos.x, pos.y, is_focused, false);

        // Track for hit testing
        try self.clickable_widgets.append(self.allocator, .{
            .id = id,
            .kind = .TextInput,
            .bounds = .{ .x = pos.x, .y = pos.y, .width = opts.width, .height = opts.height },
        });

        // Add to accessibility tree
        var a11y_node = a11y_mod.Node.init(self.allocator, id, .TextInput, .{
            .x = pos.x,
            .y = pos.y,
            .width = opts.width,
            .height = opts.height,
        });
        a11y_node.setLabel(id_str);

        // Get current text value
        const len = c.mcore_text_input_get(self.ctx, id, &widget.buffer, 256);
        if (len > 0) {
            a11y_node.setValue(widget.buffer[0..@intCast(len)]);
        }

        a11y_node.addAction(a11y_mod.Actions.Focus);
        try self.a11y_builder.addNode(a11y_node);

        // Check if text changed
        const current_text = widget.buffer[0..@intCast(len)];
        const changed = !std.mem.eql(u8, current_text, buffer[0..@min(current_text.len, buffer.len)]);
        if (changed and current_text.len <= buffer.len) {
            @memcpy(buffer[0..current_text.len], current_text);
        }

        return changed;
    }

    // ============================================================================
    // Helpers (Internal)
    // ============================================================================

    const Pos = struct { x: f32, y: f32 };

    fn allocateSpace(self: *UI, width: f32, height: f32) !Pos {
        if (self.layout_stack.items.len == 0) {
            // No layout - error
            @panic("Widget rendered outside of layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];

        // Calculate position using simple immediate placement
        // This is simpler than the full flex algorithm and works for non-flex children
        const pos: Pos = switch (frame.kind) {
            .Hstack => .{
                .x = frame.current_pos,
                .y = frame.y,
            },
            .Vstack => .{
                .x = frame.x,
                .y = frame.current_pos,
            },
        };

        // Advance position for next widget
        const gap = frame.flex.gap;
        frame.current_pos += switch (frame.kind) {
            .Hstack => width + gap,
            .Vstack => height + gap,
        };

        // Add child to flex container (for potential future use)
        try frame.flex.addChild(.{ .width = width, .height = height }, 0);

        return pos;
    }

    fn measureText(self: *UI, text: []const u8, font_size: f32, max_width: f32) layout_mod.Size {
        var size: c.mcore_text_size_t = undefined;
        c.mcore_measure_text(self.ctx, text.ptr, font_size, max_width, &size);
        return .{ .width = size.width, .height = size.height };
    }

    fn wasClicked(self: *UI, x: f32, y: f32, w: f32, h: f32) bool {
        if (!self.mouse_clicked) return false;

        const in_bounds = self.mouse_x >= x and self.mouse_x < x + w and
            self.mouse_y >= y and self.mouse_y < y + h;

        return in_bounds;
    }
};

// ============================================================================
// Supporting Types
// ============================================================================

const LayoutFrame = struct {
    kind: enum { Vstack, Hstack },
    flex: flex_mod.FlexContainer,
    x: f32,
    y: f32,
    current_pos: f32, // Current position along main axis
};

const ClickableWidget = struct {
    id: u64,
    kind: enum { Button, TextInput },
    bounds: layout_mod.Rect,
};

const TextInputWidget = struct {
    buffer: [256]u8 = undefined,
    width: f32,
    height: f32,
    scroll_offset: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,

    pub const PADDING_X: f32 = 10;
    pub const PADDING_Y: f32 = 8;

    pub fn init(width: f32, height: f32) TextInputWidget {
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn render(
        self: *TextInputWidget,
        ctx: *c.mcore_context_t,
        cmd_buffer: *commands_mod.CommandBuffer,
        id: u64,
        x: f32,
        y: f32,
        is_focused: bool,
        debug_bounds: bool,
    ) void {
        _ = debug_bounds;
        self.x = x;
        self.y = y;

        // Get current text
        const len = c.mcore_text_input_get(ctx, id, &self.buffer, 256);
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
            cmd_buffer.roundedRect(x - 2, y - 2, self.width + 4, self.height + 4, 6, border_color) catch {};
            cmd_buffer.roundedRect(x, y, self.width, self.height, 4, bg_color) catch {};
        }

        // Measure text
        const max_width_no_wrap: f32 = 100000;
        var text_size: c.mcore_text_size_t = undefined;
        const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
        c.mcore_measure_text(ctx, text_ptr, 16, max_width_no_wrap, &text_size);

        const text_y = y + (self.height - text_size.height) / 2.0;

        // Calculate scroll offset
        const visible_width = self.width - (PADDING_X * 2);
        if (is_focused) {
            const cursor_pos = c.mcore_text_input_cursor(ctx, id);
            const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
            const cursor_right_margin: f32 = 20;

            if (cursor_offset_x - self.scroll_offset > visible_width - cursor_right_margin) {
                self.scroll_offset = cursor_offset_x - visible_width + cursor_right_margin;
            }
            if (cursor_offset_x < self.scroll_offset) {
                self.scroll_offset = cursor_offset_x;
            }
            if (self.scroll_offset < 0) {
                self.scroll_offset = 0;
            }
        }

        // Push clip rect
        cmd_buffer.pushClip(x, y, self.width, self.height) catch {};

        // Draw selection highlight
        var sel_start: c_int = 0;
        var sel_end: c_int = 0;
        const has_selection = c.mcore_text_input_get_selection(ctx, id, &sel_start, &sel_end);
        if (has_selection != 0 and sel_start < sel_end) {
            const sel_start_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, sel_start);
            const sel_end_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, sel_end);

            const highlight_x = x + PADDING_X + sel_start_x - self.scroll_offset;
            const highlight_width = sel_end_x - sel_start_x;

            const selection_color = [4]f32{ 0.3, 0.5, 0.8, 0.5 };
            cmd_buffer.roundedRect(highlight_x, text_y, highlight_width, text_size.height, 2, selection_color) catch {};
        }

        // Draw text
        const text_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
        const text_x = x + PADDING_X - self.scroll_offset;
        cmd_buffer.text(text_ptr, text_x, text_y, 16, max_width_no_wrap, text_color) catch {};

        // Draw cursor
        if (is_focused) {
            const cursor_pos = c.mcore_text_input_cursor(ctx, id);
            const cursor_offset_x = c.mcore_measure_text_to_byte_offset(ctx, text_ptr, 16, cursor_pos);
            const cursor_x = x + PADDING_X + cursor_offset_x - self.scroll_offset;
            const cursor_color = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
            cmd_buffer.roundedRect(cursor_x, text_y, 2, text_size.height, 1, cursor_color) catch {};
        }

        // Pop clip rect
        cmd_buffer.popClip() catch {};
    }

    pub fn handleKey(
        _: *TextInputWidget,
        ctx: *c.mcore_context_t,
        id: u64,
        key: c_int,
        char_code: u32,
        shift: bool,
        cmd: bool,
    ) bool {
        _ = cmd; // TODO: Handle cmd+a, cmd+c, cmd+v in UI context

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

        const changed = c.mcore_text_input_event(ctx, id, &event);
        return changed != 0;
    }
};

// Helper: Find byte offset at X coordinate
fn findByteOffsetAtX(ctx: *c.mcore_context_t, text: [*:0]const u8, font_size: f32, target_x: f32) usize {
    if (target_x <= 0) return 0;

    const text_len = std.mem.len(text);
    if (text_len == 0) return 0;

    var left: usize = 0;
    var right: usize = text_len;

    while (left < right) {
        const mid = (left + right) / 2;
        const mid_x = c.mcore_measure_text_to_byte_offset(ctx, text, font_size, @intCast(mid));

        if (mid_x < target_x) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    if (left > 0) {
        const left_x = c.mcore_measure_text_to_byte_offset(ctx, text, font_size, @intCast(left));
        const prev_x = c.mcore_measure_text_to_byte_offset(ctx, text, font_size, @intCast(left - 1));

        if (@abs(prev_x - target_x) < @abs(left_x - target_x)) {
            return left - 1;
        }
    }

    return left;
}

// ============================================================================
// Option Types
// ============================================================================

pub const LabelOptions = struct {
    size: f32 = 16,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    bg_color: ?[4]f32 = null, // null = no background
    padding: f32 = 8,
};

pub const ButtonOptions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null, // Override auto-ID
};

pub const TextInputOptions = struct {
    width: f32 = 200,
    height: f32 = 40,
};

pub const VstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
};

pub const HstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
};
