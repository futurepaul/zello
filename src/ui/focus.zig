const std = @import("std");

pub const FocusState = struct {
    focused_id: ?u64 = null,
    focusable_ids: std.ArrayList(u64), // Built each frame
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FocusState {
        return .{
            .focusable_ids = std.ArrayList(u64){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FocusState) void {
        self.focusable_ids.deinit(self.allocator);
    }

    pub fn beginFrame(self: *FocusState) void {
        self.focusable_ids.clearRetainingCapacity();
    }

    pub fn registerFocusable(self: *FocusState, id: u64) !void {
        try self.focusable_ids.append(self.allocator, id);
    }

    pub fn isFocused(self: *FocusState, id: u64) bool {
        return if (self.focused_id) |fid| fid == id else false;
    }

    pub fn focusNext(self: *FocusState) void {
        if (self.focusable_ids.items.len == 0) return;

        const current_idx = if (self.focused_id) |fid|
            std.mem.indexOfScalar(u64, self.focusable_ids.items, fid) orelse 0
        else
            0;

        const next_idx = (current_idx + 1) % self.focusable_ids.items.len;
        self.focused_id = self.focusable_ids.items[next_idx];
    }

    pub fn focusPrev(self: *FocusState) void {
        if (self.focusable_ids.items.len == 0) return;

        const current_idx = if (self.focused_id) |fid|
            std.mem.indexOfScalar(u64, self.focusable_ids.items, fid) orelse 0
        else
            0;

        const next_idx = if (current_idx == 0)
            self.focusable_ids.items.len - 1
        else
            current_idx - 1;

        self.focused_id = self.focusable_ids.items[next_idx];
    }

    pub fn setFocus(self: *FocusState, id: ?u64) void {
        self.focused_id = id;
    }
};
