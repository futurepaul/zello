const std = @import("std");

pub const DrawCommandKind = enum(u8) {
    RoundedRect = 0,
    Text = 1,
    PushClip = 2,
    PopClip = 3,
};

/// Command buffer entry - must match C layout for FFI
pub const DrawCommand = extern struct {
    kind: DrawCommandKind,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32, // For rounded rect
    color: [4]f32,
    text_ptr: ?[*:0]const u8, // For text (null-terminated)
    font_size: f32,
    wrap_width: f32,
    font_id: i32,
    // Padding to ensure consistent size
    _padding: [12]u8 = undefined,
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

    pub fn roundedRect(self: *CommandBuffer, x: f32, y: f32, w: f32, h: f32, r: f32, color: [4]f32) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .RoundedRect,
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .radius = r,
            .color = color,
            .text_ptr = null,
            .font_size = 0,
            .wrap_width = 0,
            .font_id = 0,
        };
        self.count += 1;
    }

    pub fn text(self: *CommandBuffer, str: [*:0]const u8, x: f32, y: f32, font_size: f32, wrap_width: f32, color: [4]f32) !void {
        if (self.count >= self.commands.len) return error.BufferFull;

        self.commands[self.count] = .{
            .kind = .Text,
            .x = x,
            .y = y,
            .width = 0,
            .height = 0,
            .radius = 0,
            .color = color,
            .text_ptr = str,
            .font_size = font_size,
            .wrap_width = wrap_width,
            .font_id = 0,
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
