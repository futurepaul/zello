const std = @import("std");

pub const Axis = enum { Horizontal, Vertical };

pub const Alignment = enum {
    Start,
    Center,
    End,
    Stretch,
};

pub const Size = struct {
    width: f32,
    height: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }
};

pub const BoxConstraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),

    pub fn tight(width: f32, height: f32) BoxConstraints {
        return .{
            .min_width = width,
            .max_width = width,
            .min_height = height,
            .max_height = height,
        };
    }

    pub fn loose(width: f32, height: f32) BoxConstraints {
        return .{
            .max_width = width,
            .max_height = height,
        };
    }
};
