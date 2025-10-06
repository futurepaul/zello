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

    /// Scroll by delta (in pixels)
    pub fn scroll_by(self: *ScrollArea, delta: Vec2) void {
        self.viewport_pos.x += delta.x;
        self.viewport_pos.y += delta.y;
        self.clamp_viewport_pos();
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
