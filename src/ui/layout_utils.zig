const std = @import("std");
const layout_mod = @import("layout.zig");
const flex_mod = @import("flex.zig");
const c_api = @import("../renderer/c_api.zig");
const c = c_api.c;

/// Represents a child widget for measurement purposes
pub const ChildMeasurement = struct {
    width: f32,
    height: f32,
};

/// Measure text using the FFI text measurement API
pub fn measureText(ctx: *c.mcore_context_t, text: []const u8, font_size: f32, max_width: f32) layout_mod.Size {
    var size: c.mcore_text_size_t = undefined;
    c.mcore_measure_text(ctx, text.ptr, font_size, max_width, &size);
    return .{ .width = size.width, .height = size.height };
}


/// Calculate content bounding box from a slice of rects
pub fn calcContentBounds(rects: []const layout_mod.Rect) layout_mod.Size {
    var content_width: f32 = 0;
    var content_height: f32 = 0;

    for (rects) |rect| {
        content_width = @max(content_width, rect.x + rect.width);
        content_height = @max(content_height, rect.y + rect.height);
    }

    return .{ .width = content_width, .height = content_height };
}

/// Calculate total bounding box from a slice of rects (includes negative offsets)
pub fn calcTotalBounds(rects: []const layout_mod.Rect, default_padding: f32) layout_mod.Size {
    if (rects.len == 0) {
        return .{ .width = default_padding * 2, .height = default_padding * 2 };
    }

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

    // Add padding to right and bottom edges since children are positioned at (padding, padding)
    return .{
        .width = max_x + default_padding,
        .height = max_y + default_padding,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "calcContentBounds - empty" {
    const rects: []const layout_mod.Rect = &.{};
    const result = calcContentBounds(rects);
    try std.testing.expectEqual(@as(f32, 0), result.width);
    try std.testing.expectEqual(@as(f32, 0), result.height);
}

test "calcContentBounds - single rect" {
    const rects = &[_]layout_mod.Rect{
        .{ .x = 10, .y = 20, .width = 100, .height = 50 },
    };
    const result = calcContentBounds(rects);
    try std.testing.expectEqual(@as(f32, 110), result.width); // 10 + 100
    try std.testing.expectEqual(@as(f32, 70), result.height); // 20 + 50
}

test "calcContentBounds - multiple rects" {
    const rects = &[_]layout_mod.Rect{
        .{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .{ .x = 0, .y = 55, .width = 100, .height = 50 },
        .{ .x = 0, .y = 110, .width = 100, .height = 50 },
    };
    const result = calcContentBounds(rects);
    try std.testing.expectEqual(@as(f32, 100), result.width);
    try std.testing.expectEqual(@as(f32, 160), result.height); // 110 + 50
}

test "calcTotalBounds - empty uses padding" {
    const rects: []const layout_mod.Rect = &.{};
    const result = calcTotalBounds(rects, 10);
    try std.testing.expectEqual(@as(f32, 20), result.width);
    try std.testing.expectEqual(@as(f32, 20), result.height);
}

test "calcTotalBounds - handles negative offsets" {
    const rects = &[_]layout_mod.Rect{
        .{ .x = -10, .y = -5, .width = 100, .height = 50 },
        .{ .x = 20, .y = 10, .width = 80, .height = 40 },
    };
    const result = calcTotalBounds(rects, 0);
    try std.testing.expectEqual(@as(f32, 100), result.width); // -10 to 90 + 0 padding
    try std.testing.expectEqual(@as(f32, 50), result.height); // -5 to 45 + 0 padding
}

test "calcTotalBounds - includes padding" {
    const rects = &[_]layout_mod.Rect{
        .{ .x = 10, .y = 10, .width = 100, .height = 50 },
    };
    const result = calcTotalBounds(rects, 10);
    try std.testing.expectEqual(@as(f32, 120), result.width); // 10 (left) + 100 + 10 (right)
    try std.testing.expectEqual(@as(f32, 70), result.height); // 10 (top) + 50 + 10 (bottom)
}
