const std = @import("std");
const layout_mod = @import("../layout.zig");
const layout_utils = @import("../layout_utils.zig");
const commands_mod = @import("../commands.zig");
const state_mod = @import("state.zig");
const focus_mod = @import("../focus.zig");
const a11y_mod = @import("../a11y.zig");
const c_api = @import("../../renderer/c_api.zig");
const c = c_api.c;

/// WidgetContext provides the API surface for widgets to interact with the UI system
/// This is the primary interface for both built-in and external widgets
pub const WidgetContext = struct {
    // Core dependencies (opaque to widgets)
    ctx: *c.mcore_context_t,
    allocator: std.mem.Allocator,

    // Widget services
    commands: *commands_mod.CommandBuffer,
    state: *state_mod.StateStore,
    interaction: *state_mod.InteractionState,
    focus: *focus_mod.FocusState,
    a11y_builder: *a11y_mod.TreeBuilder,

    // Debug flags
    debug_bounds: bool,

    // ========================================================================
    // Text Measurement (FFI to Rust)
    // ========================================================================

    /// Measure text dimensions using the rendering backend
    pub fn measureText(self: *const WidgetContext, text: []const u8, font_size: f32, max_width: f32) layout_mod.Size {
        return layout_utils.measureText(self.ctx, text, font_size, max_width);
    }

    /// Find byte offset in text at a given X coordinate (for cursor positioning)
    pub fn findByteOffsetAtX(self: *const WidgetContext, text: [*:0]const u8, font_size: f32, target_x: f32) usize {
        if (target_x <= 0) return 0;

        const text_len = std.mem.len(text);
        if (text_len == 0) return 0;

        var left: usize = 0;
        var right: usize = text_len;

        while (left < right) {
            const mid = (left + right) / 2;
            const mid_x = c.mcore_measure_text_to_byte_offset(self.ctx, text, font_size, @intCast(mid));

            if (mid_x < target_x) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (left > 0) {
            const left_x = c.mcore_measure_text_to_byte_offset(self.ctx, text, font_size, @intCast(left));
            const prev_x = c.mcore_measure_text_to_byte_offset(self.ctx, text, font_size, @intCast(left - 1));

            if (@abs(prev_x - target_x) < @abs(left_x - target_x)) {
                return left - 1;
            }
        }

        return left;
    }

    // ========================================================================
    // Drawing Commands
    // ========================================================================

    /// Get the command buffer for direct rendering
    pub fn commandBuffer(self: *WidgetContext) *commands_mod.CommandBuffer {
        return self.commands;
    }

    // ========================================================================
    // Focus Management
    // ========================================================================

    /// Register a widget as focusable
    pub fn registerFocusable(self: *WidgetContext, id: u64) !void {
        try self.focus.registerFocusable(id);
    }

    /// Check if a widget is currently focused
    pub fn isFocused(self: *const WidgetContext, id: u64) bool {
        return self.focus.isFocused(id);
    }

    /// Set focus to a specific widget
    pub fn setFocus(self: *WidgetContext, id: u64) void {
        self.focus.setFocus(id);
    }

    // ========================================================================
    // Interaction State
    // ========================================================================

    /// Check if a bounds is hovered by the mouse
    pub fn isHovered(self: *const WidgetContext, bounds: layout_mod.Rect) bool {
        return self.interaction.isHovered(bounds);
    }

    /// Check if a bounds is pressed (hovered and mouse down)
    pub fn isPressed(self: *const WidgetContext, bounds: layout_mod.Rect) bool {
        return self.interaction.isPressed(bounds);
    }

    /// Register a clickable widget for hit testing
    pub fn registerClickable(self: *WidgetContext, id: u64, kind: state_mod.ClickableKind, bounds: layout_mod.Rect) !void {
        try self.interaction.registerClickable(id, kind, bounds);
    }

    /// Check if a widget was clicked this frame
    pub fn wasClicked(self: *const WidgetContext, id: u64) bool {
        return self.interaction.wasClicked(id);
    }

    /// Mark a widget as clicked (for next frame)
    pub fn markClicked(self: *WidgetContext, id: u64) !void {
        try self.interaction.markClicked(id);
    }

    /// Get current mouse position
    pub fn getMousePos(self: *const WidgetContext) struct { x: f32, y: f32 } {
        return .{
            .x = self.interaction.input.mouse_x,
            .y = self.interaction.input.mouse_y,
        };
    }

    /// Check if mouse was clicked this frame
    pub fn isMouseClicked(self: *const WidgetContext) bool {
        return self.interaction.input.mouse_clicked;
    }

    // ========================================================================
    // Persistent State (useState pattern)
    // ========================================================================

    /// Get or create text input state for a widget
    pub fn getOrPutTextInput(self: *WidgetContext, id: u64, width: f32, height: f32) !*state_mod.TextInputState {
        return try self.state.getOrPutTextInput(id, width, height);
    }

    /// Get or create scroll area state for a widget
    pub fn getOrPutScrollArea(self: *WidgetContext, id: u64, opts: state_mod.ScrollAreaOptions) !*@import("../widgets/scroll_area.zig").ScrollArea {
        return try self.state.getOrPutScrollArea(id, opts);
    }

    // ========================================================================
    // Accessibility
    // ========================================================================

    /// Add a node to the accessibility tree
    pub fn addA11yNode(self: *WidgetContext, node: a11y_mod.Node) !void {
        try self.a11y_builder.addNode(node);
    }

    // ========================================================================
    // Debug Helpers
    // ========================================================================

    /// Check if debug bounds rendering is enabled
    pub fn isDebugBoundsEnabled(self: *const WidgetContext) bool {
        return self.debug_bounds;
    }

    /// Draw debug bounds rectangle
    pub fn drawDebugRect(self: *WidgetContext, x: f32, y: f32, w: f32, h: f32, color: @import("../color.zig").Color) void {
        if (!self.debug_bounds) return;

        const line_width: f32 = 2;
        // Draw 4 edges as thin rectangles to create an outline
        self.commands.roundedRect(x, y, w, line_width, 0, color) catch {};
        self.commands.roundedRect(x, y + h - line_width, w, line_width, 0, color) catch {};
        self.commands.roundedRect(x, y, line_width, h, 0, color) catch {};
        self.commands.roundedRect(x + w - line_width, y, line_width, h, 0, color) catch {};
    }
};
