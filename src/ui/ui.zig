const std = @import("std");
const id_mod = @import("id.zig");
const focus_mod = @import("focus.zig");
const commands_mod = @import("commands.zig");
const a11y_mod = @import("a11y.zig");
const layout_mod = @import("layout.zig");
const flex_mod = @import("flex.zig");
const scroll_mod = @import("widgets/scroll_area.zig");
const button_widget = @import("widgets/button.zig");
const label_widget = @import("widgets/label.zig");
const text_input_widget = @import("widgets/text_input.zig");
const image_widget = @import("widgets/image.zig");
const widget_interface = @import("widget_interface.zig");
const layout_utils = @import("layout_utils.zig");
const state_mod = @import("core/state.zig");
const context_mod = @import("core/context.zig");
const frame_arena_mod = @import("core/frame_arena.zig");
const frame_exchange_mod = @import("core/frame_exchange.zig");
const text_cache_mod = @import("core/text_cache.zig");
const c_api = @import("../renderer/c_api.zig");
const c = c_api.c;
const color_mod = @import("color.zig");
const Color = color_mod.Color;

/// Main UI context - holds all state for immediate-mode UI
pub const UI = struct {
    // Core systems (internal)
    ctx: *c.mcore_context_t,
    id_system: id_mod.UI,
    focus: focus_mod.FocusState,
    commands: commands_mod.CommandBuffer,
    a11y_builder: a11y_mod.TreeBuilder,

    // Frame arena for per-frame allocations
    frame_arena: frame_arena_mod.FrameArena,

    // Frame exchange for cross-frame data
    frame_exchange: frame_exchange_mod.FrameExchange,

    // Text measurement cache (frame-scoped)
    text_cache: text_cache_mod.TextCache,

    // Persistent state management
    state: state_mod.StateStore,

    // Input state (current frame)
    input: frame_exchange_mod.FrameInput,

    // Layout stack (supports arbitrary nesting)
    layout_stack: std.ArrayList(LayoutFrame),

    // Window properties
    width: f32,
    height: f32,
    scale: f32,

    // Debug visualization
    debug_bounds: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *c.mcore_context_t, width: f32, height: f32, scale: f32) !UI {
        // Start with 1MB arena, will grow as needed
        const initial_arena_size = 1024 * 1024;

        return .{
            .ctx = ctx,
            .id_system = id_mod.UI.init(allocator),
            .focus = focus_mod.FocusState.init(allocator),
            .commands = try commands_mod.CommandBuffer.init(allocator, 1000),
            .a11y_builder = a11y_mod.TreeBuilder.init(allocator, 1), // root ID
            .frame_arena = try frame_arena_mod.FrameArena.init(allocator, initial_arena_size),
            .frame_exchange = frame_exchange_mod.FrameExchange.init(allocator),
            .text_cache = text_cache_mod.TextCache.init(),
            .state = state_mod.StateStore.init(allocator),
            .input = frame_exchange_mod.FrameInput{},
            .layout_stack = .{},
            .width = width,
            .height = height,
            .scale = scale,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UI) void {
        self.id_system.deinit();
        self.focus.deinit();
        self.commands.deinit();
        self.a11y_builder.deinit();
        self.state.deinit();
        self.frame_arena.deinit();
        self.frame_exchange.deinit();
        self.text_cache.deinit(self.allocator);
        self.layout_stack.deinit(self.allocator);
    }

    pub fn beginFrame(self: *UI) void {
        // Reset frame arena
        self.frame_arena.beginFrame();

        // Reset command buffer
        self.commands.reset();

        // Reset focus tracking
        self.focus.beginFrame();

        // Swap frame exchange buffers and recompute interaction state
        self.frame_exchange.beginFrame(&self.frame_arena, self.input);

        // Reset text cache (uses persistent allocator for map storage, but cleared each frame)
        self.text_cache.beginFrame(self.allocator);

        // Reset accessibility tree
        self.a11y_builder.deinit();
        self.a11y_builder = a11y_mod.TreeBuilder.init(self.allocator, 1);
    }

    pub fn endFrame(self: *UI, clear_color: Color) !void {
        // Submit draw commands
        const cmds = self.commands.getCommands();
        c.mcore_render_commands(self.ctx, @ptrCast(cmds.ptr), @intCast(cmds.count));

        // Submit accessibility tree
        if (self.focus.focused_id) |fid| {
            self.a11y_builder.setFocus(fid);
        }
        try self.a11y_builder.update(self.ctx);

        // Present
        const clear = c.mcore_rgba_t{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a };
        const st = c.mcore_end_frame_present(self.ctx, clear);
        if (st != c.MCORE_OK) {
            const err = c.mcore_last_error();
            if (err != null) std.debug.print("mcore error: {s}\n", .{std.mem.span(err)});
        }

        // End frame arena (update stats)
        self.frame_arena.endFrame();

        // Clear one-frame input flags
        self.input.mouse_clicked = false;
    }

    pub fn updateSize(self: *UI, width: f32, height: f32, scale: f32) void {
        // Invalidate text cache if scale changed (affects measurements)
        if (self.scale != scale) {
            self.text_cache.invalidate();
        }

        self.width = width;
        self.height = height;
        self.scale = scale;
    }

    pub fn setDebugBounds(self: *UI, enabled: bool) void {
        self.debug_bounds = enabled;
    }

    /// Get the frame arena allocator for per-frame allocations
    /// This allocator is reset at the start of each frame
    /// Use this for temporary data that doesn't need to persist across frames
    pub fn frameAllocator(self: *UI) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    /// Get text measurement statistics for instrumentation
    pub fn getTextStats(self: *UI) struct { measure_calls: u32, offset_calls: u32 } {
        var stats: c.mcore_text_stats_t = undefined;
        c.mcore_get_text_stats(self.ctx, &stats);
        return .{
            .measure_calls = stats.total_measure_calls,
            .offset_calls = stats.total_offset_calls,
        };
    }

    /// Reset text measurement statistics
    pub fn resetTextStats(self: *UI) void {
        c.mcore_reset_text_stats(self.ctx);
    }

    /// Get text cache statistics
    pub fn getTextCacheStats(self: *UI) text_cache_mod.CacheStats {
        return self.text_cache.getStats();
    }

    /// Get text cache hit rate as percentage
    pub fn getTextCacheHitRate(self: *UI) f32 {
        return self.text_cache.getHitRate();
    }

    // ============================================================================
    // Widget Context Creation
    // ============================================================================

    /// Create a WidgetContext for widget rendering
    /// This provides the API surface that widgets use to interact with the UI system
    pub fn createWidgetContext(self: *UI) context_mod.WidgetContext {
        return .{
            .ctx = self.ctx,
            .allocator = self.allocator,
            .commands = &self.commands,
            .state = &self.state,
            .frame_exchange = &self.frame_exchange,
            .input = &self.input,
            .focus = &self.focus,
            .a11y_builder = &self.a11y_builder,
            .text_cache = &self.text_cache,
            .scale = self.scale,
            .debug_bounds = self.debug_bounds,
        };
    }

    // ============================================================================
    // Input Handling
    // ============================================================================

    pub fn handleMouseDown(self: *UI, x: f32, y: f32) void {
        self.input.mouse_x = x;
        self.input.mouse_y = y;
        self.input.mouse_down = true;

        // For text inputs, we need to handle mouse down immediately to position cursor
        // We check the PREVIOUS frame's clickables since current frame hasn't rendered yet
        // This is OK because text inputs are stateful and persist across frames
        for (self.frame_exchange.prev.clickables.items) |clickable| {
            if (clickable.kind == .TextInput and clickable.bounds.contains(x, y)) {
                // Handle text input mouse down
                if (self.state.text_inputs.getPtr(clickable.id)) |ti| {
                    const local_x = x - (clickable.bounds.x + text_input_widget.PADDING_X) + ti.scroll_offset;
                    const len = c.mcore_text_input_get(self.ctx, clickable.id, @constCast(&ti.buffer), 256);
                    const text = ti.buffer[0..@intCast(len)];
                    const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
                    var widget_ctx = self.createWidgetContext();
                    const byte_offset = widget_ctx.findByteOffsetAtX(text_ptr, 16, local_x);
                    c.mcore_text_input_start_selection(self.ctx, clickable.id, @intCast(byte_offset));
                }
                self.focus.setFocus(clickable.id);
                return;
            }
        }

        // For buttons, focus is set, but click is detected in wasClicked() next frame
        for (self.frame_exchange.prev.clickables.items) |clickable| {
            if (clickable.kind == .Button and clickable.bounds.contains(x, y)) {
                self.focus.setFocus(clickable.id);
                return;
            }
        }
    }

    pub fn handleMouseUp(self: *UI, x: f32, y: f32) void {
        self.input.mouse_x = x;
        self.input.mouse_y = y;
        self.input.mouse_down = false;
        self.input.mouse_clicked = true;
    }

    pub fn handleMouseMove(self: *UI, x: f32, y: f32) void {
        self.input.mouse_x = x;
        self.input.mouse_y = y;

        // Handle drag for text selection
        if (self.input.mouse_down) {
            if (self.focus.focused_id) |fid| {
                for (self.frame_exchange.prev.clickables.items) |clickable| {
                    if (clickable.kind == .TextInput and clickable.id == fid and clickable.bounds.contains(x, y)) {
                        if (self.state.text_inputs.getPtr(clickable.id)) |ti| {
                            const local_x = x - (clickable.bounds.x + text_input_widget.PADDING_X) + ti.scroll_offset;
                            const len = c.mcore_text_input_get(self.ctx, clickable.id, @constCast(&ti.buffer), 256);
                            const text = ti.buffer[0..@intCast(len)];
                            const text_ptr: [*:0]const u8 = if (text.len > 0) @ptrCast(text.ptr) else "";
                            var widget_ctx = self.createWidgetContext();
                            const byte_offset = widget_ctx.findByteOffsetAtX(text_ptr, 16, local_x);
                            c.mcore_text_input_set_cursor_pos(self.ctx, clickable.id, @intCast(byte_offset), 1);
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
        // Divide by scale to convert to logical pixel space (our layout is in logical pixels)
        const scaled_delta_x = delta_x / self.scale;
        const scaled_delta_y = delta_y / self.scale;

        // Find scroll area under mouse cursor (check in reverse order - topmost first)
        const scroll_regions = self.frame_exchange.getScrollRegions();
        var i: usize = scroll_regions.len;
        while (i > 0) {
            i -= 1;
            const region = &scroll_regions[i];
            if (region.bounds.contains(self.input.mouse_x, self.input.mouse_y)) {
                // Apply scroll in logical pixel space
                region.scroll_area.scroll_by_momentum(.{
                    .x = -scaled_delta_x, // Invert for natural scrolling
                    .y = -scaled_delta_y,
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
            if (self.state.text_inputs.getPtr(fid)) |_| {
                var widget_ctx = self.createWidgetContext();
                _ = text_input_widget.handleKey(&widget_ctx, fid, key, char_code, shift, cmd);
            }
        }
    }

    // ============================================================================
    // Layout System
    // ============================================================================

    // Shared stack options (same for both V and H)
    const StackOptions = struct {
        gap: f32 = 0,
        padding: f32 = 0,
        width: ?f32 = null,
        height: ?f32 = null,
    };

    fn beginStack(self: *UI, kind: LayoutKind, opts: StackOptions) !void {
        try self.layout_stack.append(self.allocator, .{
            .kind = kind,
            .gap = opts.gap,
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
            .children = .{},
            .x = 0,
            .y = 0,
        });
    }

    fn endStack(self: *UI, expected_kind: LayoutKind) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endStack called without matching beginStack!");
        }

        const frame = self.layout_stack.pop() orelse unreachable;

        // If this is a nested layout, add it as a child to parent
        if (self.layout_stack.items.len > 0) {
            var parent = &self.layout_stack.items[self.layout_stack.items.len - 1];
            parent.children.append(self.frameAllocator(), .{
                .layout = .{
                    .kind = expected_kind,
                    .gap = frame.gap,
                    .padding = frame.padding,
                    .width = frame.width,
                    .height = frame.height,
                    .children = frame.children, // Transfer ownership
                },
            }) catch return;
        } else {
            // Root layout - do the actual layout and rendering!
            self.layoutAndRender(frame, .{
                .x = 0,
                .y = 0,
                .width = self.width,
                .height = self.height,
            }) catch return;
        }
    }

    pub fn beginVstack(self: *UI, opts: VstackOptions) !void {
        try self.beginStack(.Vstack, .{
            .gap = opts.gap,
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
        });
    }

    pub fn endVstack(self: *UI) void {
        self.endStack(.Vstack);
    }

    pub fn beginHstack(self: *UI, opts: HstackOptions) !void {
        try self.beginStack(.Hstack, .{
            .gap = opts.gap,
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
        });
    }

    pub fn endHstack(self: *UI) void {
        self.endStack(.Hstack);
    }

    pub fn beginScrollArea(self: *UI, opts: ScrollAreaOptions) !void {
        // Generate ID for the scroll area (use id from opts or auto-generate)
        const id_str = opts.id orelse "scroll_area";
        try self.id_system.pushID(id_str);
        const id = self.id_system.getCurrentID();
        self.id_system.popID();

        // Get or create scroll area state
        const gop = try self.state.scroll_areas.getOrPut(id);
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
            .padding = opts.padding,
            .width = opts.width,
            .height = opts.height,
            .children = .{},
            .x = 0,
            .y = 0,
            .scroll_area = gop.value_ptr.*,
            .scroll_area_id = id,
            .scroll_bg_color = opts.bg_color,
            .scroll_padding = opts.padding,
        });
    }

    pub fn endScrollArea(self: *UI) void {
        if (self.layout_stack.items.len == 0) {
            @panic("endScrollArea called without matching beginScrollArea!");
        }

        const frame = self.layout_stack.pop() orelse unreachable;
        if (frame.kind != .ScrollArea) {
            @panic("endScrollArea called but top of stack is not ScrollArea!");
        }

        // If this is a nested layout, add it as a child to parent
        if (self.layout_stack.items.len > 0) {
            var parent = &self.layout_stack.items[self.layout_stack.items.len - 1];
            parent.children.append(self.frameAllocator(), .{
                .scroll_layout = .{
                    .scroll_area = frame.scroll_area.?,
                    .scroll_area_id = frame.scroll_area_id,
                    .width = frame.width,
                    .height = frame.height,
                    .bg_color = frame.scroll_bg_color,
                    .padding = frame.scroll_padding,
                    .children = frame.children, // Transfer ownership
                },
            }) catch return;
        } else {
            // Root scroll area (unusual but supported)
            // Note: scroll_area is stored in StateStore, not owned by frame
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
        try frame.children.append(self.frameAllocator(), .{
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
        try frame.children.append(self.frameAllocator(), .{
            .button = .{ .id = id, .text = label_text, .opts = opts },
        });

        // Check if this button was clicked in the previous frame's rendering pass
        return self.frame_exchange.wasClicked(id);
    }

    pub fn spacer(self: *UI, flex: f32) !void {
        if (self.layout_stack.items.len == 0) {
            @panic("spacer() called outside layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.frameAllocator(), .{
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
        try frame.children.append(self.frameAllocator(), .{
            .text_input = .{ .id = id, .id_str = id_str, .buffer = buffer, .opts = opts },
        });

        // Return false during declaration phase
        return false;
    }

    /// Add an image widget to the layout
    /// The image must be pre-loaded using loadImageFile() or registerImage()
    pub fn image(self: *UI, image_id: i32, natural_width: f32, natural_height: f32, opts: ImageOptions) !void {
        if (self.layout_stack.items.len == 0) {
            @panic("image() called outside layout! Use beginVstack/beginHstack first.");
        }

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.frameAllocator(), .{
            .image = .{
                .image_id = image_id,
                .natural_width = natural_width,
                .natural_height = natural_height,
                .opts = opts,
            },
        });
    }

    /// Add a custom widget to the layout
    /// This is the extensibility point for external widgets
    ///
    /// Example:
    ///   const my_widget_data = MyWidgetData{ .text = "Hello", .color = RED };
    ///   try ui.customWidget(&MyWidget.Interface, &my_widget_data);
    pub fn customWidget(self: *UI, interface: *const widget_interface.WidgetInterface, data: anytype) !void {
        if (self.layout_stack.items.len == 0) {
            @panic("customWidget() called outside layout! Use beginVstack/beginHstack first.");
        }

        const custom = widget_interface.CustomWidget.init(@TypeOf(data.*), interface, data);

        var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
        try frame.children.append(self.frameAllocator(), .{
            .custom = custom,
        });
    }

    // ============================================================================
    // Layout and Rendering Engine (Deferred Tree Traversal)
    // ============================================================================

    fn layoutAndRender(self: *UI, frame: LayoutFrame, bounds: layout_mod.Rect) anyerror!void {
        // Draw debug bounds for the layout container itself
        if (frame.kind == .Vstack) {
            // Yellow for Vstack
            self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, color_mod.rgba(1, 1, 0, 0.6));
        } else {
            // Orange for Hstack
            self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, color_mod.rgba(1, 0.5, 0, 0.6));
        }

        // Step 1: Measure all children recursively
        var flex = flex_mod.FlexContainer.init(
            self.frameAllocator(),
            if (frame.kind == .Vstack) .Vertical else .Horizontal,
        );

        flex.gap = frame.gap;
        flex.padding = frame.padding;

        // For text measurement, we always need a width constraint (text wraps based on width)
        const text_max_width = bounds.width - frame.padding * 2;

        for (frame.children.items) |child| {
            switch (child) {
                .label => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = label_widget.measure(&widget_ctx, data.text, data.opts, text_max_width);
                    try flex.addChild(size, 0);
                },
                .button => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const measurement = button_widget.measure(&widget_ctx, data.text, data.opts);
                    try flex.addChild(.{ .width = measurement.width, .height = measurement.height }, 0);
                },
                .text_input => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = text_input_widget.measure(&widget_ctx, data.opts);
                    try flex.addChild(size, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    // Recursively measure nested layout!
                    // Pass INNER bounds (with padding removed) so nested layout knows its actual space
                    const inner_bounds = layout_mod.Rect{
                        .x = bounds.x + frame.padding,
                        .y = bounds.y + frame.padding,
                        .width = bounds.width - frame.padding * 2,
                        .height = bounds.height - frame.padding * 2,
                    };
                    const nested_size = try self.measureLayout(nested, inner_bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => |scroll_data| {
                    // Measure scroll layout using INNER bounds (respecting parent padding)
                    const inner_width = bounds.width - frame.padding * 2;
                    const inner_height = bounds.height - frame.padding * 2;
                    const width = scroll_data.width orelse inner_width;
                    const height = scroll_data.height orelse inner_height;
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
                .custom => |custom_widget| {
                    var widget_ctx = self.createWidgetContext();
                    const available_width = @max(0, bounds.width - frame.padding * 2);
                    const size = custom_widget.measure(&widget_ctx, available_width);
                    try flex.addChild(size, 0);
                },
                .image => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = image_widget.measure(&widget_ctx, data.image_id, data.natural_width, data.natural_height, data.opts);
                    try flex.addChild(size, 0);
                },
            }
        }

        // Step 2: Calculate positions
        // Constrain ONLY cross-axis by padding (main axis is handled by flex algorithm)
        // For vstack (vertical main axis): constrain width (cross axis)
        // For hstack (horizontal main axis): constrain height (cross axis)
        const cross_constrained_width = bounds.width - frame.padding * 2;
        const cross_constrained_height = bounds.height - frame.padding * 2;

        const constraints = if (frame.kind == .Vstack)
            layout_mod.BoxConstraints.loose(cross_constrained_width, bounds.height)
        else
            layout_mod.BoxConstraints.loose(bounds.width, cross_constrained_height);

        const rects = try flex.layout_children(constraints);

        // Step 3: Render each child at its calculated position
        for (frame.children.items, rects) |child, rect| {
            const abs_x = bounds.x + rect.x;
            const abs_y = bounds.y + rect.y;

            switch (child) {
                .label => |data| {
                    var widget_ctx = self.createWidgetContext();
                    try label_widget.render(&widget_ctx, data.text, data.opts, abs_x, abs_y, rect.width, rect.height);
                },
                .button => |data| {
                    var widget_ctx = self.createWidgetContext();
                    try button_widget.render(&widget_ctx, data.id, data.text, data.opts, abs_x, abs_y, rect.width, rect.height);
                },
                .text_input => |data| {
                    var widget_ctx = self.createWidgetContext();
                    try text_input_widget.render(&widget_ctx, data.id, data.id_str, data.buffer, data.opts, abs_x, abs_y);
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
                        .padding = scroll_data.padding,
                        .width = scroll_data.width,
                        .height = scroll_data.height,
                        .children = scroll_data.children,
                        .x = 0,
                        .y = 0,
                        .scroll_area = scroll_data.scroll_area,
                        .scroll_area_id = scroll_data.scroll_area_id,
                        .scroll_bg_color = scroll_data.bg_color,
                        .scroll_padding = scroll_data.padding,
                    };
                    try self.layoutAndRenderScroll(scroll_frame, .{
                        .x = abs_x,
                        .y = abs_y,
                        .width = rect.width,
                        .height = rect.height,
                    });
                },
                .custom => |custom_widget| {
                    var widget_ctx = self.createWidgetContext();
                    try custom_widget.render(&widget_ctx, abs_x, abs_y, rect.width, rect.height);
                },
                .image => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const id = 0; // Dummy ID for now since we don't need focus/interaction
                    try image_widget.render(&widget_ctx, id, data.image_id, data.natural_width, data.natural_height, data.opts, abs_x, abs_y, rect.width, rect.height);
                },
            }
        }
    }

    fn layoutAndRenderScroll(self: *UI, frame: LayoutFrame, bounds: layout_mod.Rect) anyerror!void {
        _ = frame.scroll_area orelse @panic("layoutAndRenderScroll called without scroll_area!");

        // Get the persistent scroll area state from the HashMap
        const scroll_area_ptr = self.state.scroll_areas.getPtr(frame.scroll_area_id) orelse
            @panic("Scroll area ID not found in state!");

        // Register scroll area for mouse wheel events (for next frame)
        try self.frame_exchange.recordScrollRegion(scroll_area_ptr, bounds);

        // Draw background for scroll area if specified
        if (frame.scroll_bg_color) |bg_color| {
            try self.commands.roundedRect(bounds.x, bounds.y, bounds.width, bounds.height, 4, bg_color);
        }

        // Draw debug bounds for the scroll area container (purple for scroll areas)
        self.drawDebugRect(bounds.x, bounds.y, bounds.width, bounds.height, color_mod.rgba(0.8, 0, 0.8, 0.6));

        // Step 1: Determine child constraints based on scroll configuration
        const child_constraints = layout_mod.BoxConstraints{
            .min_width = 0,
            .min_height = 0,
            // Pass full bounds - flex will handle padding internally
            .max_width = if (scroll_area_ptr.constrain_horizontal) bounds.width else bounds.width,
            .max_height = if (scroll_area_ptr.constrain_vertical) bounds.height else bounds.height,
        };

        // Step 2: Measure all children recursively using the scroll area's flex container
        var flex = scroll_area_ptr.flex;
        flex.gap = frame.gap;
        flex.padding = frame.padding;

        // For text measurement, we always need a width constraint (text wraps based on width)
        const text_max_width = child_constraints.max_width - frame.padding * 2;

        for (frame.children.items) |child| {
            switch (child) {
                .label => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = label_widget.measure(&widget_ctx, data.text, data.opts, text_max_width);
                    try flex.addChild(size, 0);
                },
                .button => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const measurement = button_widget.measure(&widget_ctx, data.text, data.opts);
                    try flex.addChild(.{ .width = measurement.width, .height = measurement.height }, 0);
                },
                .text_input => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = text_input_widget.measure(&widget_ctx, data.opts);
                    try flex.addChild(size, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    // Pass INNER bounds (with padding removed) so nested layout knows its actual space
                    const inner_bounds = layout_mod.Rect{
                        .x = bounds.x + frame.padding,
                        .y = bounds.y + frame.padding,
                        .width = bounds.width - frame.padding * 2,
                        .height = bounds.height - frame.padding * 2,
                    };
                    const nested_size = try self.measureLayout(nested, inner_bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => {
                    @panic("Nested scroll areas not yet supported!");
                },
                .custom => |custom_widget| {
                    var widget_ctx = self.createWidgetContext();
                    const available_width = @max(0, child_constraints.max_width);
                    const size = custom_widget.measure(&widget_ctx, available_width);
                    try flex.addChild(size, 0);
                },
                .image => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = image_widget.measure(&widget_ctx, data.image_id, data.natural_width, data.natural_height, data.opts);
                    try flex.addChild(size, 0);
                },
            }
        }

        // Step 3: Layout children to determine content size
        const rects = try flex.layout_children(child_constraints);
        defer self.allocator.free(rects);

        // Calculate content bounding box using shared helper
        const content_size = layout_utils.calcContentBounds(rects);

        // Step 4: Update scroll area's content_size and viewport_size
        scroll_area_ptr.content_size = content_size;
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
            self.frameAllocator(),
            if (layout_data.kind == .Vstack) .Vertical else .Horizontal,
        );

        flex.gap = layout_data.gap;
        flex.padding = layout_data.padding;

        // For text measurement, we always need a width constraint (text wraps based on width)
        const text_max_width = parent_bounds.width - layout_data.padding * 2;

        for (layout_data.children.items) |child| {
            switch (child) {
                .label => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = label_widget.measure(&widget_ctx, data.text, data.opts, text_max_width);
                    try flex.addChild(size, 0);
                },
                .button => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const measurement = button_widget.measure(&widget_ctx, data.text, data.opts);
                    try flex.addChild(.{ .width = measurement.width, .height = measurement.height }, 0);
                },
                .text_input => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = text_input_widget.measure(&widget_ctx, data.opts);
                    try flex.addChild(size, 0);
                },
                .spacer => |data| {
                    try flex.addSpacer(data.flex);
                },
                .layout => |nested| {
                    // Recursively measure!
                    // Pass INNER bounds (with padding removed) so nested layout knows its actual space
                    const inner_bounds = layout_mod.Rect{
                        .x = parent_bounds.x + layout_data.padding,
                        .y = parent_bounds.y + layout_data.padding,
                        .width = parent_bounds.width - layout_data.padding * 2,
                        .height = parent_bounds.height - layout_data.padding * 2,
                    };
                    const nested_size = try self.measureLayout(nested, inner_bounds);
                    try flex.addChild(nested_size, 0);
                },
                .scroll_layout => |scroll_data| {
                    // Measure scroll layout using INNER bounds (respecting parent padding)
                    const inner_width = parent_bounds.width - layout_data.padding * 2;
                    const inner_height = parent_bounds.height - layout_data.padding * 2;
                    const width = scroll_data.width orelse inner_width;
                    const height = scroll_data.height orelse inner_height;
                    try flex.addChild(.{ .width = width, .height = height }, 0);
                },
                .custom => |custom_widget| {
                    var widget_ctx = self.createWidgetContext();
                    const available_width = @max(0, parent_bounds.width - layout_data.padding * 2);
                    const size = custom_widget.measure(&widget_ctx, available_width);
                    try flex.addChild(size, 0);
                },
                .image => |data| {
                    var widget_ctx = self.createWidgetContext();
                    const size = image_widget.measure(&widget_ctx, data.image_id, data.natural_width, data.natural_height, data.opts);
                    try flex.addChild(size, 0);
                },
            }
        }

        // Do a layout pass to get the total size
        // Constrain ONLY cross-axis by padding (main axis is handled by flex algorithm)
        const cross_constrained_width = parent_bounds.width - layout_data.padding * 2;
        const cross_constrained_height = parent_bounds.height - layout_data.padding * 2;

        const constraints = if (layout_data.kind == .Vstack)
            layout_mod.BoxConstraints.loose(cross_constrained_width, parent_bounds.height)
        else
            layout_mod.BoxConstraints.loose(parent_bounds.width, cross_constrained_height);

        const rects = try flex.layout_children(constraints);

        // Calculate bounding box of all children using shared helper
        const calculated_size = layout_utils.calcTotalBounds(rects, layout_data.padding);

        return .{
            .width = layout_data.width orelse calculated_size.width,
            .height = layout_data.height orelse calculated_size.height,
        };
    }

    fn renderWidget(self: *UI, widget: WidgetData, x: f32, y: f32, width: f32, height: f32) anyerror!void {
        switch (widget) {
            .label => |data| {
                var widget_ctx = self.createWidgetContext();
                try label_widget.render(&widget_ctx, data.text, data.opts, x, y, width, height);
            },
            .button => |data| {
                var widget_ctx = self.createWidgetContext();
                try button_widget.render(&widget_ctx, data.id, data.text, data.opts, x, y, width, height);
            },
            .text_input => |data| {
                var widget_ctx = self.createWidgetContext();
                try text_input_widget.render(&widget_ctx, data.id, data.id_str, data.buffer, data.opts, x, y);
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
            .custom => |custom_widget| {
                var widget_ctx = self.createWidgetContext();
                try custom_widget.render(&widget_ctx, x, y, width, height);
            },
            .image => |data| {
                var widget_ctx = self.createWidgetContext();
                const id = 0; // Dummy ID for now since we don't need focus/interaction
                try image_widget.render(&widget_ctx, id, data.image_id, data.natural_width, data.natural_height, data.opts, x, y, width, height);
            },
        }
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
        return layout_utils.measureText(self.ctx, text, font_size, max_width);
    }

    fn drawDebugRect(self: *UI, x: f32, y: f32, w: f32, h: f32, col: Color) void {
        if (!self.debug_bounds) return;

        const line_width: f32 = 2;
        // Draw 4 edges as thin rectangles to create an outline
        // Top edge
        self.commands.roundedRect(x, y, w, line_width, 0, col) catch {};
        // Bottom edge
        self.commands.roundedRect(x, y + h - line_width, w, line_width, 0, col) catch {};
        // Left edge
        self.commands.roundedRect(x, y, line_width, h, 0, col) catch {};
        // Right edge
        self.commands.roundedRect(x + w - line_width, y, line_width, h, 0, col) catch {};
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
        bg_color: ?Color,
        padding: f32,
        children: std.ArrayList(WidgetData),
    },

    // Custom widget (extensibility point for external widgets)
    custom: widget_interface.CustomWidget,

    // Image widget
    image: struct {
        image_id: i32,
        natural_width: f32,
        natural_height: f32,
        opts: ImageOptions,
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
    scroll_bg_color: ?Color = null,
    scroll_padding: f32 = 0,
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

// ============================================================================
// Option Types
// ============================================================================

// Re-export label options for backwards compatibility
pub const LabelOptions = label_widget.Options;

// Re-export button options for backwards compatibility
pub const ButtonOptions = button_widget.Options;

// Re-export text input options for backwards compatibility
pub const TextInputOptions = text_input_widget.Options;

// Re-export image widget functions and types
pub const ImageOptions = image_widget.Options;
pub const ImageInfo = image_widget.ImageInfo;
pub const loadImageFile = image_widget.loadImageFile;
pub const registerImageRGBA8 = image_widget.registerImageRGBA8;
pub const registerImageRGB8 = image_widget.registerImageRGB8;
pub const releaseImage = image_widget.releaseImage;
pub const imageById = image_widget.imageById;

pub const VstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
    width: ?f32 = null, // Optional fixed width
    height: ?f32 = null, // Optional fixed height
};

pub const HstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
    width: ?f32 = null, // Optional fixed width
    height: ?f32 = null, // Optional fixed height
};

pub const ScrollAreaOptions = struct {
    constrain_horizontal: bool = false,
    constrain_vertical: bool = false,
    must_fill: bool = false,
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null, // Optional ID for the scroll area
    bg_color: ?Color = null, // Background color (null = transparent)
    padding: f32 = 0, // Inner padding for scroll content
};
