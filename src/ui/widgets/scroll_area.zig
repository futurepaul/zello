const std = @import("std");
const layout_mod = @import("../layout.zig");
const flex_mod = @import("../flex.zig");

const Size = layout_mod.Size;
const Point = layout_mod.Point;
const Rect = layout_mod.Rect;
const BoxConstraints = layout_mod.BoxConstraints;
const Vec2 = layout_mod.Vec2;

/// ScrollArea widget - provides scrolling for content larger than viewport
pub const ScrollArea = struct {
    // Layout results
    content_size: Size = .{ .width = 0, .height = 0 },
    viewport_size: Size = .{ .width = 0, .height = 0 },
    viewport_pos: Point = .{ .x = 0, .y = 0 }, // Current scroll position (top-left of viewport in content space)

    // Constraint mode
    constrain_horizontal: bool = false, // Pass finite width constraint?
    constrain_vertical: bool = false, // Pass finite height constraint?
    must_fill: bool = false, // Child must fill viewport?

    // Flex container for child content
    flex: flex_mod.FlexContainer,

    // Momentum scrolling (Phase 2)
    scroll_momentum: Vec2 = .{ .x = 0, .y = 0 },
    scroll_origin: Point = .{ .x = 0, .y = 0 },
    pointer_origin: Point = .{ .x = 0, .y = 0 },
    drag_active: bool = false,
    drag_time: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, opts: ScrollAreaOptions) ScrollArea {
        return .{
            .constrain_horizontal = opts.constrain_horizontal,
            .constrain_vertical = opts.constrain_vertical,
            .must_fill = opts.must_fill,
            .flex = flex_mod.FlexContainer.init(allocator, .Vertical),
        };
    }

    pub fn deinit(self: *ScrollArea) void {
        self.flex.deinit();
    }

    /// Clamp viewport position to valid range
    pub fn clamp_viewport_pos(self: *ScrollArea) void {
        // Max scroll position is content_size - viewport_size
        // (Scrolled all the way to the bottom/right)
        const max_x = @max(0, self.content_size.width - self.viewport_size.width);
        const max_y = @max(0, self.content_size.height - self.viewport_size.height);

        self.viewport_pos.x = @max(0, @min(self.viewport_pos.x, max_x));
        self.viewport_pos.y = @max(0, @min(self.viewport_pos.y, max_y));
    }

    /// Set viewport position (will be clamped)
    pub fn set_viewport_pos(self: *ScrollArea, new_pos: Point) void {
        self.viewport_pos = new_pos;
        self.clamp_viewport_pos();
    }

    /// Scroll by delta (in pixels), canceling any momentum
    pub fn scroll_by(self: *ScrollArea, delta: Vec2) void {
        self.viewport_pos.x += delta.x;
        self.viewport_pos.y += delta.y;
        self.clamp_viewport_pos();

        // Cancel momentum when manually scrolling with wheel
        self.scroll_momentum = Vec2{ .x = 0, .y = 0 };
    }

    /// Scroll by delta with momentum (used for momentum scrolling)
    pub fn scroll_by_momentum(self: *ScrollArea, delta: Vec2) void {
        self.viewport_pos.x += delta.x;
        self.viewport_pos.y += delta.y;
        self.clamp_viewport_pos();
    }

    /// Update momentum scrolling (call each frame)
    pub fn update_momentum(self: *ScrollArea, dt: f32) void {
        _ = dt;
        const MOMENTUM_DECAY: f32 = 0.95;
        const MOMENTUM_THRESHOLD: f32 = 0.1;

        // Apply momentum
        self.viewport_pos.x += self.scroll_momentum.x;
        self.scroll_momentum.x *= MOMENTUM_DECAY;
        if (@abs(self.scroll_momentum.x) < MOMENTUM_THRESHOLD) {
            self.scroll_momentum.x = 0;
        }

        self.viewport_pos.y += self.scroll_momentum.y;
        self.scroll_momentum.y *= MOMENTUM_DECAY;
        if (@abs(self.scroll_momentum.y) < MOMENTUM_THRESHOLD) {
            self.scroll_momentum.y = 0;
        }

        // Clamp to valid range
        self.clamp_viewport_pos();
    }

    /// Start a drag operation
    pub fn start_drag(self: *ScrollArea, pointer_pos: Point) void {
        self.drag_active = true;
        self.pointer_origin = pointer_pos;
        self.scroll_origin = self.viewport_pos;
        self.scroll_momentum = Vec2{ .x = 0, .y = 0 }; // Cancel existing momentum
        self.drag_time = 0;
    }

    /// Update drag position
    pub fn update_drag(self: *ScrollArea, pointer_pos: Point, dt: f32) void {
        if (!self.drag_active) return;

        const delta_x = pointer_pos.x - self.pointer_origin.x;
        const delta_y = pointer_pos.y - self.pointer_origin.y;

        self.viewport_pos.x = self.scroll_origin.x - delta_x; // Invert for natural drag
        self.viewport_pos.y = self.scroll_origin.y - delta_y;
        self.clamp_viewport_pos();
        self.drag_time += dt;
    }

    /// End drag and calculate momentum
    pub fn end_drag(self: *ScrollArea) void {
        if (!self.drag_active) return;

        const MIN_DRAG_DISTANCE: f32 = 10.0;
        const MOMENTUM_DAMPING: f32 = 25.0;

        const distance_x = self.viewport_pos.x - self.scroll_origin.x;
        const distance_y = self.viewport_pos.y - self.scroll_origin.y;

        // Only apply momentum if dragged far enough
        if (@abs(distance_x) > MIN_DRAG_DISTANCE or @abs(distance_y) > MIN_DRAG_DISTANCE) {
            const time_factor = @max(0.016, self.drag_time); // Min 1 frame
            self.scroll_momentum.x = distance_x / (time_factor * MOMENTUM_DAMPING);
            self.scroll_momentum.y = distance_y / (time_factor * MOMENTUM_DAMPING);
        }

        self.drag_active = false;
    }

    /// Get scroll offset as Vec2 (for translation)
    pub fn get_scroll_offset(self: *ScrollArea) Vec2 {
        return Vec2{
            .x = -self.viewport_pos.x,
            .y = -self.viewport_pos.y,
        };
    }

    /// Check if content is scrollable in a given direction
    pub fn is_scrollable_x(self: *ScrollArea) bool {
        return self.content_size.width > self.viewport_size.width;
    }

    pub fn is_scrollable_y(self: *ScrollArea) bool {
        return self.content_size.height > self.viewport_size.height;
    }
};

pub const ScrollAreaOptions = struct {
    constrain_horizontal: bool = false,
    constrain_vertical: bool = false,
    must_fill: bool = false,
};
