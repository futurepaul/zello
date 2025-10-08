const std = @import("std");
const layout = @import("layout.zig");

pub const Axis = layout.Axis;
pub const Alignment = layout.Alignment;
pub const Size = layout.Size;
pub const Rect = layout.Rect;
pub const BoxConstraints = layout.BoxConstraints;

pub const FlexChild = struct {
    size: Size, // Measured size
    flex: f32 = 0, // 0 = fixed, >0 = proportional
};

pub const FlexContainer = struct {
    axis: Axis,
    gap: f32 = 0,
    padding: f32 = 0,
    cross_alignment: Alignment = .Start,
    children: std.ArrayList(FlexChild),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, axis: Axis) FlexContainer {
        return .{
            .axis = axis,
            .children = std.ArrayList(FlexChild){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlexContainer) void {
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *FlexContainer, size: Size, flex: f32) !void {
        try self.children.append(self.allocator, .{ .size = size, .flex = flex });
    }

    pub fn addSpacer(self: *FlexContainer, flex: f32) !void {
        try self.children.append(self.allocator, .{
            .size = .{ .width = 0, .height = 0 },
            .flex = flex,
        });
    }

    pub fn layout_children(self: *FlexContainer, constraints: BoxConstraints) ![]Rect {
        const available = switch (self.axis) {
            .Horizontal => constraints.max_width,
            .Vertical => constraints.max_height,
        };

        // 1. Measure fixed children and find maximum cross-axis size
        var used: f32 = self.padding * 2;
        var flex_total: f32 = 0;
        var max_cross: f32 = 0;

        for (self.children.items) |child| {
            if (child.flex == 0) {
                used += switch (self.axis) {
                    .Horizontal => child.size.width,
                    .Vertical => child.size.height,
                };
            } else {
                flex_total += child.flex;
            }

            // Track maximum cross-axis size
            const child_cross = switch (self.axis) {
                .Horizontal => child.size.height,
                .Vertical => child.size.width,
            };
            max_cross = @max(max_cross, child_cross);
        }

        if (self.children.items.len > 1) {
            used += self.gap * @as(f32, @floatFromInt(self.children.items.len - 1));
        }

        // 2. Distribute remaining to flex children
        const remaining = @max(0, available - used);
        const flex_unit = if (flex_total > 0) remaining / flex_total else 0;

        // 3. Calculate positions
        var results = try self.allocator.alloc(Rect, self.children.items.len);
        var pos = self.padding;

        for (self.children.items, 0..) |child, i| {
            const main_size = if (child.flex > 0)
                child.flex * flex_unit
            else switch (self.axis) {
                .Horizontal => child.size.width,
                .Vertical => child.size.height,
            };

            // Allow non-flex children to keep their measured cross-axis size so they don't stretch
            const cross_size = switch (self.axis) {
                .Horizontal => if (child.flex > 0) max_cross else child.size.height,
                .Vertical => if (child.flex > 0) max_cross else child.size.width,
            };

            results[i] = switch (self.axis) {
                .Horizontal => .{
                    .x = pos,
                    .y = self.padding,
                    .width = main_size,
                    .height = cross_size,
                },
                .Vertical => .{
                    .x = self.padding,
                    .y = pos,
                    .width = cross_size,
                    .height = main_size,
                },
            };

            pos += main_size + self.gap;
        }

        return results;
    }
};
