const std = @import("std");
const id_mod = @import("id.zig");
const focus_mod = @import("focus.zig");
const commands_mod = @import("commands.zig");
const a11y_mod = @import("a11y.zig");
const layout_mod = @import("layout.zig");
const flex_mod = @import("flex.zig");
const scroll_mod = @import("widgets/scroll_area.zig");
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

    // Layout stack (supports arbitrary nesting)
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

    // Scroll areas (keyed by ID, persist across frames)
    scroll_areas_state: std.AutoHashMap(u64, scroll_mod.ScrollArea),

    // Track buttons that were clicked this frame (filled during rendering)
    clicked_buttons: std.AutoHashMap(u64, void),

    // Track scroll areas for wheel events (filled during rendering)
    scroll_areas: std.ArrayList(ScrollAreaWidget),

    // Debug visualization
    debug_bounds: bool = false,

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
            .scroll_areas_state = std.AutoHashMap(u64, scroll_mod.ScrollArea).init(allocator),
            .clicked_buttons = std.AutoHashMap(u64, void).init(allocator),
            .scroll_areas = std.ArrayList(ScrollAreaWidget){},
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

        // Clean up scroll areas
        var it = self.scroll_areas_state.valueIterator();
        while (it.next()) |scroll_area| {
            scroll_area.deinit();
        }
        self.scroll_areas_state.deinit();

        self.clicked_buttons.deinit();
        self.scroll_areas.deinit(self.allocator);
    }

    pub fn beginFrame(self: *UI) void {
        self.commands.reset();
        self.focus.beginFrame();
        self.clickable_widgets.clearRetainingCapacity();
        self.scroll_areas.clearRetainingCapacity();
        // Note: Don't clear clicked_buttons here! They need to persist from
        // the previous frame's rendering to this frame's button() calls

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

    pub fn setDebugBounds(self: *UI, enabled: bool) void {
        self.debug_bounds = enabled;
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

    pub fn handleScroll(self: *UI, delta_x: f32, delta_y: f32) void {
        // macOS provides scrollingDeltaX/Y which already includes:
        // - Acceleration (faster scroll when you scroll faster)
        // - Momentum (continues after you lift fingers on trackpad)
        // We just apply it directly, no need for our own multiplier!

        // Find scroll area under mouse cursor (check in reverse order - topmost first)
        var i: usize = self.scroll_areas.items.len;
        while (i > 0) {
            i -= 1;
            const scroll_widget = &self.scroll_areas.items[i];
            if (scroll_widget.bounds.contains(self.mouse_x, self.mouse_y)) {
                // Apply scroll directly - macOS deltas already feel native
                scroll_widget.scroll_area.scroll_by_momentum(.{
                    .x = -delta_x, // Invert for natural scrolling
                    .y = -delta_y,
                });
                return; // Only scroll the topmost scroll area under cursor
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
        // Nesting is now supported!
        try self.layout_stack.append(self.allocator, .{
            .kind = .Vstack,
            .gap = opts.gap,
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
            .children = std.ArrayList(WidgetData){},
            .x = 0,
            .y = 0,
        });
    }

    pub fn endVstack(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endVstack called without matching beginVstack!");
        }

        var frame = self.layout_stack.pop() orelse unreachable;

        // If this is a nested layout, add it as a child to parent
        if (self.layout_stack.items.len > 0) {
            var parent = &self.layout_stack.items[self.layout_stack.items.len - 1];
            parent.children.append(self.allocator, .{
                .layout = .{
                    .kind = .Vstack,
                    .gap = frame.gap,
                    .padding = frame.padding,
                    .width = frame.width,
                    .height = frame.height,
                    .children = frame.children, // Transfer ownership
                },
            }) catch return;
        } else {
            // Root layout - do the actual layout and rendering!
            defer frame.children.deinit(self.allocator);

            // Clear clicked_buttons from PREVIOUS frame before rendering
            // This frame's rendering will populate it with NEW clicks
            self.clicked_buttons.clearRetainingCapacity();

            self.layoutAndRender(frame, .{
                .x = 0,
                .y = 0,
                .width = self.width,
                .height = self.height,
            }) catch return;
        }
    }

    pub fn beginHstack(self: *UI, opts: HstackOptions) !void {
        // Nesting is now supported!
        try self.layout_stack.append(self.allocator, .{
            .kind = .Hstack,
            .gap = opts.gap,
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
            .children = std.ArrayList(WidgetData){},
            .x = 0,
            .y = 0,
        });
    }

    pub fn endHstack(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endHstack called without matching beginHstack!");
        }

        var frame = self.layout_stack.pop() orelse unreachable;

        // If this is a nested layout, add it as a child to parent
        if (self.layout_stack.items.len > 0) {
            var parent = &self.layout_stack.items[self.layout_stack.items.len - 1];
            parent.children.append(self.allocator, .{
                .layout = .{
                    .kind = .Hstack,
                    .gap = frame.gap,
                    .padding = frame.padding,
                    .width = frame.width,
                    .height = frame.height,
                    .children = frame.children, // Transfer ownership
                },
            }) catch return;
        } else {
            // Root layout - do the actual layout and rendering!
            defer frame.children.deinit(self.allocator);

            // Clear clicked_buttons from PREVIOUS frame before rendering
            // This frame's rendering will populate it with NEW clicks
            self.clicked_buttons.clearRetainingCapacity();

            self.layoutAndRender(frame, .{
                .x = 0,
                .y = 0,
                .width = self.width,
                .height = self.height,
            }) catch return;
        }
    }

    pub fn beginScrollArea(self: *UI, opts: ScrollAreaOptions) !void {
        // Generate ID for the scroll area (use id from opts or auto-generate)
        const id_str = opts.id orelse "scroll_area";
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        self.id_system.popID();

        // Get or create scroll area state
        const gop = try self.scroll_areas_state.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = scroll_mod.ScrollArea.init(self.allocator, .{
                .constrain_horizontal = opts.constrain_horizontal,
                .constrain_vertical = opts.constrain_vertical,
                .must_fill = opts.must_fill,
            });
        }

        try self.layout_stack.append(self.allocator, .{
            .kind = .ScrollArea,
            .gap = 0,
            .padding = 0,
            .width = opts.width,
            .height = opts.height,
            .children = std.ArrayList(WidgetData){},
            .x = 0,
            .y = 0,
            .scroll_area = gop.value_ptr.*,
            .scroll_area_id = id,
        });
    }

    pub fn endScrollArea(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endScrollArea called without matching beginScrollArea!");
        }

        var frame = self.layout_stack.pop() orelse unreachable;
        if (frame.kind != .ScrollArea) {
            @panic("endScrollArea called but top of stack is not ScrollArea!");
        }

        // If this is a nested layout, add it as a child to parent
        if (self.layout_stack.items.len > 0) {
            var parent = &self.layout_stack.items[self.layout_stack.items.len - 1];
            parent.children.append(self.allocator, .{
                .scroll_layout = .{
                    .scroll_area = frame.scroll_area.?,
                    .scroll_area_id = frame.scroll_area_id,
                    .width = frame.width,
                    .height = frame.height,
                    .children = frame.children, // Transfer ownership
                },
            }) catch return;
        } else {
            // Root scroll area (unusual but supported)
            defer frame.children.deinit(self.allocator);
            defer frame.scroll_area.?.deinit();

            self.clicked_buttons.clearRetainingCapacity();

            self.layoutAndRenderScroll(frame, .{
                .x = 0,
                .y = 0,
                .width = self.width,
                .height = self.height,
            }) catch return;
        }
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
        if (self.layout_stack.items.len == 0) {
            @panic("label() called outside layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.allocator, .{
            .label = .{ .text = text, .opts = opts },
        });
    }

    pub fn button(self: *UI, label_text: [:0]const u8, opts: ButtonOptions) !bool {
        if (self.layout_stack.items.len == 0) {
            @panic("button() called outside layout! Use beginVstack/beginHstack first.");
        }

        // Generate ID for the button
        const id_str = opts.id orelse label_text;
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        self.id_system.popID();

        // Store button data for deferred rendering
        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.allocator, .{
            .button = .{ .id = id, .text = label_text, .opts = opts },
        });

        // Check if this button was clicked in the previous frame's rendering pass
        return self.clicked_buttons.contains(id);
    }

    pub fn spacer(self: *UI, flex: f32) !void {
        if (self.layout_stack.items.len == 0) {
            @panic("spacer() called outside layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.allocator, .{
            .spacer = .{ .flex = flex },
        });
    }

    pub fn textInput(self: *UI, id_str: []const u8, buffer: []u8, opts: TextInputOptions) !bool {
        if (self.layout_stack.items.len == 0) {
            @panic("textInput() called outside layout! Use beginVstack/beginHstack first.");
        }

        // Generate ID
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        self.id_system.popID();

        // Store text input data for deferred rendering
        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.allocator, .{
            .text_input = .{ .id = id, .id_str = id_str, .buffer = buffer, .opts = opts },
        });

        // Return false during declaration phase
        return false;
    }

    // ============================================================================
    // Layout and Rendering Engine (Deferred Tree Traversal)
    // ============================================================================

    fn layoutAndRender(self: *UI, frame: LayoutFrame, bounds: layout_mod.Rect) anyerror!void {
        // Draw debug bounds for the layout container itself
        if (frame.kind == .Vstack) {
            // Yellow for Vstack
            self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, .{ 1, 1, 0, 0.6 });
        } else {
            // Orange for Hstack
            self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, .{ 1, 0.5, 0, 0.6 });
        }

        // Step 1: Measure all children recursively
        var flex = flex_mod.FlexContainer.init(
            self.allocator,
            if (frame.kind == .Vstack) .Vertical else .Horizontal,
        );
        defer flex.deinit();

        flex.gap = frame.gap;
        flex.padding = frame.padding;

        for (frame.children.items) |child| {
            switch (child) {
                .label => |data| {
                    const size = self.measureText(data.text, data.opts.size, bounds.width);
                    try flex.addChild(.{
                        .width = size.width + data.opts.padding * 2,
                        .height = size.height + data.opts.padding * 2,
                    }, 0);
                },
                .button => |data| {
                    const padding_x: f32 = 20;
                    const padding_y: f32 = 15;
                    const font_size: f32 = 18;
                    const text_size = self.measureText(data.text, font_size, 1000);
                    const width = data.opts.width orelse (text_size.width + padding_x * 2);
                    const height = data.opts.height orelse (text_size.height + padding_y * 2);
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
                .text_input => |data| {
                    try flex.addChild(.{ .width = data.opts.width, .height = data.opts.height }, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    // Recursively measure nested layout!
                    const nested_size = try self.measureLayout(nested, bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => |scroll_data| {
                    // Measure scroll layout (use configured dimensions or calculated)
                    const width = scroll_data.width orelse bounds.width;
                    const height = scroll_data.height orelse bounds.height;
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
            }
        }

        // Step 2: Calculate positions
        const constraints = layout_mod.BoxConstraints.loose(bounds.width, bounds.height);
        const rects = try flex.layout_children(constraints);
        defer self.allocator.free(rects);

        // Step 3: Render each child at its calculated position
        for (frame.children.items, rects) |child, rect| {
            const abs_x = bounds.x + rect.x;
            const abs_y = bounds.y + rect.y;

            switch (child) {
                .label => |data| {
                    try self.renderLabel(data.text, data.opts, abs_x, abs_y, rect.width, rect.height);
                },
                .button => |data| {
                    try self.renderButton(data.id, data.text, data.opts, abs_x, abs_y, rect.width, rect.height);
                },
                .text_input => |data| {
                    try self.renderTextInput(data.id, data.id_str, data.buffer, data.opts, abs_x, abs_y);
                },
                .spacer => {}, // Spacers don't render
                .layout => |nested| {
                    // Recursively render nested layout!
                    const nested_frame = LayoutFrame{
                        .kind = nested.kind,
                        .gap = nested.gap,
                        .padding = nested.padding,
                        .width = nested.width,
                        .height = nested.height,
                        .children = nested.children,
                        .x = 0,
                        .y = 0,
                    };
                    try self.layoutAndRender(nested_frame, .{
                        .x = abs_x,
                        .y = abs_y,
                        .width = rect.width,
                        .height = rect.height,
                    });
                },
                .scroll_layout => |scroll_data| {
                    // Recursively render nested scroll area!
                    const scroll_frame = LayoutFrame{
                        .kind = .ScrollArea,
                        .gap = 0,
                        .padding = 0,
                        .width = scroll_data.width,
                        .height = scroll_data.height,
                        .children = scroll_data.children,
                        .x = 0,
                        .y = 0,
                        .scroll_area = scroll_data.scroll_area,
                        .scroll_area_id = scroll_data.scroll_area_id,
                    };
                    try self.layoutAndRenderScroll(scroll_frame, .{
                        .x = abs_x,
                        .y = abs_y,
                        .width = rect.width,
                        .height = rect.height,
                    });
                },
            }
        }
    }

    fn layoutAndRenderScroll(self: *UI, frame: LayoutFrame, bounds: layout_mod.Rect) anyerror!void {
        _ = frame.scroll_area orelse @panic("layoutAndRenderScroll called without scroll_area!");

        // Get the persistent scroll area state from the HashMap
        const scroll_area_ptr = self.scroll_areas_state.getPtr(frame.scroll_area_id) orelse
            @panic("Scroll area ID not found in state!");

        // Register scroll area for mouse wheel events
        try self.scroll_areas.append(self.allocator, .{
            .scroll_area = scroll_area_ptr,
            .bounds = bounds,
        });

        // Draw background for scroll area (darker gray to distinguish it)
        try self.commands.roundedRect(bounds.x, bounds.y, bounds.width, bounds.height, 4, .{ 0.18, 0.18, 0.22, 1.0 });

        // Draw debug bounds for the scroll area container (purple for scroll areas)
        self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, .{ 0.8, 0, 0.8, 0.6 });

        // Step 1: Determine child constraints based on scroll configuration
        const child_constraints = layout_mod.BoxConstraints{
            .min_width = 0,
            .min_height = 0,
            // If constrain_horizontal = false: pass parent's max width (still finite!)
            // If constrain_horizontal = true: pass parent's exact width
            .max_width = if (scroll_area_ptr.constrain_horizontal) bounds.width else bounds.width,
            // If constrain_vertical = false: pass parent's max height (still finite!)
            // If constrain_vertical = true: pass parent's exact height
            .max_height = if (scroll_area_ptr.constrain_vertical) bounds.height else bounds.height,
        };

        // Step 2: Measure all children recursively using the scroll area's flex container
        var flex = scroll_area_ptr.flex;
        flex.gap = frame.gap;
        flex.padding = frame.padding;

        for (frame.children.items) |child| {
            switch (child) {
                .label => |data| {
                    const size = self.measureText(data.text, data.opts.size, child_constraints.max_width);
                    try flex.addChild(.{
                        .width = size.width + data.opts.padding * 2,
                        .height = size.height + data.opts.padding * 2,
                    }, 0);
                },
                .button => |data| {
                    const padding_x: f32 = 20;
                    const padding_y: f32 = 15;
                    const font_size: f32 = 18;
                    const text_size = self.measureText(data.text, font_size, 1000);
                    const width = data.opts.width orelse (text_size.width + padding_x * 2);
                    const height = data.opts.height orelse (text_size.height + padding_y * 2);
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
                .text_input => |data| {
                    try flex.addChild(.{ .width = data.opts.width, .height = data.opts.height }, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    const nested_size = try self.measureLayout(nested, bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => {
                    @panic("Nested scroll areas not yet supported!");
                },
            }
        }

        // Step 3: Layout children to determine content size
        const rects = try flex.layout_children(child_constraints);
        defer self.allocator.free(rects);

        // Calculate content bounding box
        var content_width: f32 = 0;
        var content_height: f32 = 0;
        for (rects) |rect| {
            content_width = @max(content_width, rect.x + rect.width);
            content_height = @max(content_height, rect.y + rect.height);
        }

        // Step 4: Update scroll area's content_size and viewport_size
        scroll_area_ptr.content_size = .{ .width = content_width, .height = content_height };
        scroll_area_ptr.viewport_size = .{ .width = bounds.width, .height = bounds.height };

        // Step 5: Clamp viewport position to valid range
        scroll_area_ptr.clamp_viewport_pos();

        // Step 6: Push clip rect to viewport bounds
        try self.commands.pushClip(bounds.x, bounds.y, bounds.width, bounds.height);

        // Step 7: Render each child with scroll offset applied
        const scroll_offset = scroll_area_ptr.get_scroll_offset();

        for (frame.children.items, rects) |child, rect| {
            // Apply scroll offset to position
            const abs_x = bounds.x + rect.x + scroll_offset.x;
            const abs_y = bounds.y + rect.y + scroll_offset.y;

            try self.renderWidget(child, abs_x, abs_y, rect.width, rect.height);
        }

        // Step 8: Pop clip rect
        try self.commands.popClip();
    }

    fn measureLayout(self: *UI, layout_data: anytype, parent_bounds: layout_mod.Rect) !layout_mod.Size {
        // Create a temporary flex container to measure the layout
        var flex = flex_mod.FlexContainer.init(
            self.allocator,
            if (layout_data.kind == .Vstack) .Vertical else .Horizontal,
        );
        defer flex.deinit();

        flex.gap = layout_data.gap;
        flex.padding = layout_data.padding;

        for (layout_data.children.items) |child| {
            switch (child) {
                .label => |data| {
                    const size = self.measureText(data.text, data.opts.size, parent_bounds.width);
                    try flex.addChild(.{
                        .width = size.width + data.opts.padding * 2,
                        .height = size.height + data.opts.padding * 2,
                    }, 0);
                },
                .button => |data| {
                    const padding_x: f32 = 20;
                    const padding_y: f32 = 15;
                    const font_size: f32 = 18;
                    const text_size = self.measureText(data.text, font_size, 1000);
                    const width = data.opts.width orelse (text_size.width + padding_x * 2);
                    const height = data.opts.height orelse (text_size.height + padding_y * 2);
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
                .text_input => |data| {
                    try flex.addChild(.{ .width = data.opts.width, .height = data.opts.height }, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    // Recursively measure!
                    const nested_size = try self.measureLayout(nested, parent_bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => |scroll_data| {
                    // Measure scroll layout
                    const width = scroll_data.width orelse parent_bounds.width;
                    const height = scroll_data.height orelse parent_bounds.height;
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
            }
        }

        // Do a layout pass to get the total size
        const constraints = layout_mod.BoxConstraints.loose(parent_bounds.width, parent_bounds.height);
        const rects = try flex.layout_children(constraints);
        defer self.allocator.free(rects);

        // Calculate bounding box of all children
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = std.math.floatMin(f32);
        var max_y: f32 = std.math.floatMin(f32);

        for (rects) |rect| {
            min_x = @min(min_x, rect.x);
            min_y = @min(min_y, rect.y);
            max_x = @max(max_x, rect.x + rect.width);
            max_y = @max(max_y, rect.y + rect.height);
        }

        // Use fixed dimensions if specified, otherwise calculate from children
        const calculated_width = if (rects.len > 0) (max_x - min_x) else layout_data.padding * 2;
        const calculated_height = if (rects.len > 0) (max_y - min_y) else layout_data.padding * 2;

        return .{
            .width = layout_data.width orelse calculated_width,
            .height = layout_data.height orelse calculated_height,
        };
    }

    fn renderWidget(self: *UI, widget: WidgetData, x: f32, y: f32, width: f32, height: f32) anyerror!void {
        switch (widget) {
            .label => |data| {
                try self.renderLabel(data.text, data.opts, x, y, width, height);
            },
            .button => |data| {
                try self.renderButton(data.id, data.text, data.opts, x, y, width, height);
            },
            .text_input => |data| {
                try self.renderTextInput(data.id, data.id_str, data.buffer, data.opts, x, y);
            },
            .spacer => {}, // Spacers don't render
            .layout => |nested| {
                // Recursively render nested layout!
                const nested_frame = LayoutFrame{
                    .kind = nested.kind,
                    .gap = nested.gap,
                    .padding = nested.padding,
                    .width = nested.width,
                    .height = nested.height,
                    .children = nested.children,
                    .x = 0,
                    .y = 0,
                };
                try self.layoutAndRender(nested_frame, .{
                    .x = x,
                    .y = y,
                    .width = width,
                    .height = height,
                });
            },
            .scroll_layout => |scroll_data| {
                // Recursively render nested scroll area!
                const scroll_frame = LayoutFrame{
                    .kind = .ScrollArea,
                    .gap = 0,
                    .padding = 0,
                    .width = scroll_data.width,
                    .height = scroll_data.height,
                    .children = scroll_data.children,
                    .x = 0,
                    .y = 0,
                    .scroll_area = scroll_data.scroll_area,
                    .scroll_area_id = scroll_data.scroll_area_id,
                };
                try self.layoutAndRenderScroll(scroll_frame, .{
                    .x = x,
                    .y = y,
                    .width = width,
                    .height = height,
                });
            },
        }
    }

    fn renderLabel(self: *UI, text: [:0]const u8, opts: LabelOptions, x: f32, y: f32, width: f32, height: f32) !void {
        // Draw background if specified
        if (opts.bg_color) |bg| {
            try self.commands.roundedRect(x, y, width, height, 4, bg);
        }

        // Draw text
        const text_x = x + opts.padding;
        const text_y = y + opts.padding;
        const text_width = width - opts.padding * 2;
        try self.commands.text(text, text_x, text_y, opts.size, text_width, opts.color);

        // Debug bounds (cyan for labels)
        self.drawDebugRect(x, y, width, height, .{ 0, 1, 1, 0.8 });
    }

    fn renderButton(self: *UI, id: u64, label_text: [:0]const u8, _: ButtonOptions, x: f32, y: f32, width: f32, height: f32) !void {
        // Register as focusable
        try self.focus.registerFocusable(id);
        const is_focused = self.focus.isFocused(id);

        // Check if hovered or pressed
        const bounds = layout_mod.Rect{ .x = x, .y = y, .width = width, .height = height };
        const is_hovered = bounds.contains(self.mouse_x, self.mouse_y);
        const is_pressed = is_hovered and self.mouse_down;

        // Draw background with visual states
        const bg_color = if (is_pressed)
            [4]f32{ 0.5, 0.6, 0.9, 1.0 }
        else if (is_focused)
            [4]f32{ 0.4, 0.5, 0.8, 1.0 }
        else if (is_hovered)
            [4]f32{ 0.35, 0.35, 0.45, 1.0 }
        else
            [4]f32{ 0.3, 0.3, 0.4, 1.0 };

        try self.commands.roundedRect(x, y, width, height, 8, bg_color);

        // Draw text (centered)
        const font_size: f32 = 18;
        const text_size = self.measureText(label_text, font_size, 1000);
        const text_x = x + (width - text_size.width) / 2.0;
        const text_y = y + (height - text_size.height) / 2.0;
        try self.commands.text(label_text, text_x, text_y, font_size, text_size.width, .{ 1, 1, 1, 1 });

        // Track for hit testing
        try self.clickable_widgets.append(self.allocator, .{
            .id = id,
            .kind = .Button,
            .bounds = bounds,
        });

        // Check if clicked (for next frame)
        const clicked = self.wasClicked(x, y, width, height);
        if (clicked) {
            try self.clicked_buttons.put(id, {});
        }

        // Debug bounds (green for buttons)
        self.drawDebugRect(x, y, width, height, .{ 0, 1, 0, 0.9 });

        // Add to accessibility tree
        var a11y_node = a11y_mod.Node.init(self.allocator, id, .Button, .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        });
        a11y_node.setLabel(label_text);
        a11y_node.addAction(a11y_mod.Actions.Focus);
        a11y_node.addAction(a11y_mod.Actions.Click);
        try self.a11y_builder.addNode(a11y_node);
    }

    fn renderTextInput(self: *UI, id: u64, id_str: []const u8, buffer: []u8, opts: TextInputOptions, x: f32, y: f32) !void {
        // Get or create text input widget
        const gop = try self.text_inputs.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = TextInputWidget.init(opts.width, opts.height);
        }
        const widget = gop.value_ptr;

        // Register as focusable
        try self.focus.registerFocusable(id);
        const is_focused = self.focus.isFocused(id);

        // Store position for hit testing
        widget.x = x;
        widget.y = y;

        // Render
        widget.render(self.ctx, &self.commands, id, x, y, is_focused, false);

        // Track for hit testing
        try self.clickable_widgets.append(self.allocator, .{
            .id = id,
            .kind = .TextInput,
            .bounds = .{ .x = x, .y = y, .width = opts.width, .height = opts.height },
        });

        // Add to accessibility tree
        var a11y_node = a11y_mod.Node.init(self.allocator, id, .TextInput, .{
            .x = x,
            .y = y,
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

        // Update buffer if changed
        const current_text = widget.buffer[0..@intCast(len)];
        const changed = !std.mem.eql(u8, current_text, buffer[0..@min(current_text.len, buffer.len)]);
        if (changed and current_text.len <= buffer.len) {
            @memcpy(buffer[0..current_text.len], current_text);
        }

        // Debug bounds (magenta for text inputs)
        self.drawDebugRect(x, y, opts.width, opts.height, .{ 1, 0, 1, 0.9 });
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

    fn drawDebugRect(self: *UI, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (!self.debug_bounds) return;

        const line_width: f32 = 2;
        // Draw 4 edges as thin rectangles to create an outline
        // Top edge
        self.commands.roundedRect(x, y, w, line_width, 0, color) catch {};
        // Bottom edge
        self.commands.roundedRect(x, y + h - line_width, w, line_width, 0, color) catch {};
        // Left edge
        self.commands.roundedRect(x, y, line_width, h, 0, color) catch {};
        // Right edge
        self.commands.roundedRect(x + w - line_width, y, line_width, h, 0, color) catch {};
    }
};

// ============================================================================
// Supporting Types
// ============================================================================

// Shared enum for layout direction
const LayoutKind = enum { Vstack, Hstack, ScrollArea };

// Widget data stored during declaration phase
const WidgetData = union(enum) {
    label: struct {
        text: [:0]const u8,
        opts: LabelOptions,
    },
    button: struct {
        id: u64,
        text: [:0]const u8,
        opts: ButtonOptions,
    },
    text_input: struct {
        id: u64,
        id_str: []const u8,
        buffer: []u8,
        opts: TextInputOptions,
    },
    spacer: struct {
        flex: f32,
    },
    layout: struct {
        kind: LayoutKind,
        gap: f32,
        padding: f32,
        width: ?f32,
        height: ?f32,
        children: std.ArrayList(WidgetData),
    },
    scroll_layout: struct {
        scroll_area: scroll_mod.ScrollArea,
        scroll_area_id: u64,
        width: ?f32,
        height: ?f32,
        children: std.ArrayList(WidgetData),
    },
};

const LayoutFrame = struct {
    kind: LayoutKind,
    gap: f32,
    padding: f32,
    width: ?f32,
    height: ?f32,
    children: std.ArrayList(WidgetData), // Store children instead of immediate rendering
    x: f32,
    y: f32,

    // ScrollArea-specific state
    scroll_area: ?scroll_mod.ScrollArea = null,
    scroll_area_id: u64 = 0,
};

const ClickableWidget = struct {
    id: u64,
    kind: enum { Button, TextInput },
    bounds: layout_mod.Rect,
};

const ScrollAreaWidget = struct {
    scroll_area: *scroll_mod.ScrollArea,
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
    width: ?f32 = null,  // Optional fixed width
    height: ?f32 = null, // Optional fixed height
};

pub const HstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
    width: ?f32 = null,  // Optional fixed width
    height: ?f32 = null, // Optional fixed height
};

pub const ScrollAreaOptions = struct {
    constrain_horizontal: bool = false,
    constrain_vertical: bool = false,
    must_fill: bool = false,
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null, // Optional ID for the scroll area
};
