const std = @import("std");
const color_mod = @import("color.zig");
const Color = color_mod.Color;

pub const DrawCommandKind = enum(u8) {
    RoundedRect = 0,
    Text = 1,
    PushClip = 2,
    PopClip = 3,
    StyledRect = 4,  // New: rect with border and/or shadow
};

/// Command buffer entry - must match C layout for FFI
pub const DrawCommand = extern struct {
    kind: DrawCommandKind,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    color: [4]f32, // Fill color (or text color)
    text_ptr: ?[*:0]const u8, // For text commands
    font_size: f32,
    wrap_width: f32,
    font_id: i32,

    // Border fields
    border_width: f32,
    border_color: [4]f32,
    has_border: u8,  // 0 = no border, 1 = has border

    // Shadow fields
    shadow_offset_x: f32,
    shadow_offset_y: f32,
    shadow_blur: f32,
    shadow_color: [4]f32,
    has_shadow: u8,  // 0 = no shadow, 1 = has shadow

    // Padding to maintain alignment
    _padding: [2]u8 = undefined,
};

pub const CommandBuffer = struct {
    commands: []DrawCommand,
    count: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !CommandBuffer {
        return .{
            .commands = try allocator.alloc(DrawCommand, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.allocator.free(self.commands);
    }

    pub fn reset(self: *CommandBuffer) void {
        self.count = 0;
    }

    pub fn roundedRect(self: *CommandBuffer, x: f32, y: f32, w: f32, h: f32, r: f32, col: Color) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .RoundedRect,
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .radius = r,
            .color = .{ col.r, col.g, col.b, col.a },
            .text_ptr = null,
            .font_size = 0,
            .wrap_width = 0,
            .font_id = 0,
            .border_width = 0,
            .border_color = .{ 0, 0, 0, 0 },
            .has_border = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shadow_blur = 0,
            .shadow_color = .{ 0, 0, 0, 0 },
            .has_shadow = 0,
        };
        self.count += 1;
    }

    pub fn text(self: *CommandBuffer, str: [*:0]const u8, x: f32, y: f32, font_size: f32, wrap_width: f32, col: Color) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .Text,
            .x = x,
            .y = y,
            .width = 0,
            .height = 0,
            .radius = 0,
            .color = .{ col.r, col.g, col.b, col.a },
            .text_ptr = str,
            .font_size = font_size,
            .wrap_width = wrap_width,
            .font_id = 0,
            .border_width = 0,
            .border_color = .{ 0, 0, 0, 0 },
            .has_border = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shadow_blur = 0,
            .shadow_color = .{ 0, 0, 0, 0 },
            .has_shadow = 0,
        };
        self.count += 1;
    }

    pub fn styledRect(
        self: *CommandBuffer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        fill: Color,
        border_color: ?Color,
        border_width: f32,
        shadow: ?color_mod.Shadow,
    ) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        const has_border: u8 = if (border_color != null) 1 else 0;
        const border_col = border_color orelse color_mod.TRANSPARENT;

        const has_shadow: u8 = if (shadow != null) 1 else 0;
        const shadow_data = shadow orelse color_mod.Shadow.init(0, 0, 0, color_mod.TRANSPARENT);

        self.commands[self.count] = .{
            .kind = .StyledRect,
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .radius = radius,
            .color = .{ fill.r, fill.g, fill.b, fill.a },
            .text_ptr = null,
            .font_size = 0,
            .wrap_width = 0,
            .font_id = 0,
            .border_width = border_width,
            .border_color = .{ border_col.r, border_col.g, border_col.b, border_col.a },
            .has_border = has_border,
            .shadow_offset_x = shadow_data.offset_x,
            .shadow_offset_y = shadow_data.offset_y,
            .shadow_blur = shadow_data.blur_radius,
            .shadow_color = .{ shadow_data.color.r, shadow_data.color.g, shadow_data.color.b, shadow_data.color.a },
            .has_shadow = has_shadow,
        };
        self.count += 1;
    }

    pub fn pushClip(self: *CommandBuffer, x: f32, y: f32, w: f32, h: f32) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .PushClip,
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .radius = 0,
            .color = [4]f32{ 0, 0, 0, 0 },
            .text_ptr = null,
            .font_size = 0,
            .wrap_width = 0,
            .font_id = 0,
            .border_width = 0,
            .border_color = .{ 0, 0, 0, 0 },
            .has_border = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shadow_blur = 0,
            .shadow_color = .{ 0, 0, 0, 0 },
            .has_shadow = 0,
        };
        self.count += 1;
    }

    pub fn popClip(self: *CommandBuffer) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .PopClip,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .radius = 0,
            .color = [4]f32{ 0, 0, 0, 0 },
            .text_ptr = null,
            .font_size = 0,
            .wrap_width = 0,
            .font_id = 0,
            .border_width = 0,
            .border_color = .{ 0, 0, 0, 0 },
            .has_border = 0,
            .shadow_offset_x = 0,
            .shadow_offset_y = 0,
            .shadow_blur = 0,
            .shadow_color = .{ 0, 0, 0, 0 },
            .has_shadow = 0,
        };
        self.count += 1;
    }

    /// Returns pointer and count for FFI submission
    pub fn getCommands(self: *CommandBuffer) struct { ptr: [*]const DrawCommand, count: usize } {
        return .{
            .ptr = self.commands.ptr,
            .count = self.count,
        };
    }
};
