const std = @import("std");

pub const UI = struct {
    id_stack: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UI {
        return .{
            .id_stack = std.ArrayList(u64){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UI) void {
        self.id_stack.deinit(self.allocator);
    }

    pub fn pushID(self: *UI, label: []const u8) !void {
        const id = hashString(label);
        try self.id_stack.append(self.allocator, id);
    }

    pub fn pushIDInt(self: *UI, int_id: u64) !void {
        const parent = if (self.id_stack.items.len > 0)
            self.id_stack.items[self.id_stack.items.len - 1]
        else
            0;
        const id = hashCombine(parent, int_id);
        try self.id_stack.append(self.allocator, id);
    }

    pub fn popID(self: *UI) void {
        _ = self.id_stack.pop();
    }

    pub fn getCurrentID(self: *UI) u64 {
        return if (self.id_stack.items.len > 0)
            self.id_stack.items[self.id_stack.items.len - 1]
        else
            0;
    }

    // FNV-1a hash
    fn hashString(str: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (str) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        return hash;
    }

    fn hashCombine(a: u64, b: u64) u64 {
        var hash = a;
        hash ^= b +% 0x9e3779b9 +% (hash << 6) +% (hash >> 2);
        return hash;
    }
};
