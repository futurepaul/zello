const std = @import("std");

/// Frame arena allocator for per-frame allocations
/// Uses a bump-pointer strategy with a reusable buffer
pub const FrameArena = struct {
    backing_allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    cursor: usize,
    peak_usage: usize, // Track peak usage for diagnostics

    pub fn init(backing: std.mem.Allocator, initial_size: usize) !FrameArena {
        var buffer = std.ArrayListUnmanaged(u8){};
        try buffer.ensureTotalCapacity(backing, initial_size);
        return .{
            .backing_allocator = backing,
            .buffer = buffer,
            .cursor = 0,
            .peak_usage = 0,
        };
    }

    pub fn deinit(self: *FrameArena) void {
        self.buffer.deinit(self.backing_allocator);
    }

    /// Get an allocator interface for this frame arena
    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    /// Begin a new frame - reset cursor to 0, keep buffer
    pub fn beginFrame(self: *FrameArena) void {
        self.cursor = 0;
    }

    /// End frame - update peak usage stats
    pub fn endFrame(self: *FrameArena) void {
        if (self.cursor > self.peak_usage) {
            self.peak_usage = self.cursor;
        }
    }

    /// Get current usage statistics
    pub fn getStats(self: *const FrameArena) FrameArenaStats {
        return .{
            .current_usage = self.cursor,
            .peak_usage = self.peak_usage,
            .capacity = self.buffer.capacity,
        };
    }

    // Allocator vtable implementation
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *FrameArena = @ptrCast(@alignCast(ctx));

        const alignment = @as(usize, 1) << @intFromEnum(ptr_align);
        const aligned_cursor = std.mem.alignForward(usize, self.cursor, alignment);
        const new_cursor = aligned_cursor + len;

        // Ensure we have enough capacity
        if (new_cursor > self.buffer.capacity) {
            // Grow the buffer (doubling strategy)
            const new_capacity = @max(new_cursor, self.buffer.capacity * 2);
            self.buffer.ensureTotalCapacity(self.backing_allocator, new_capacity) catch return null;
        }

        // Update buffer items length to include this allocation
        self.buffer.items.len = @max(self.buffer.items.len, new_cursor);

        const result = self.buffer.items.ptr + aligned_cursor;
        self.cursor = new_cursor;

        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf_align;
        _ = ret_addr;

        // Simple resize: only support shrinking or same size
        // Growing requires reallocation which we don't support in this arena
        return new_len <= buf.len;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // No-op: arena is freed all at once at frame reset
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf_align;
        _ = ret_addr;
        // Arena doesn't support remap - growing/moving allocations
        // Return null to indicate remap is not supported
        if (new_len > buf.len) return null;
        return buf.ptr;
    }
};

pub const FrameArenaStats = struct {
    current_usage: usize,
    peak_usage: usize,
    capacity: usize,
};
