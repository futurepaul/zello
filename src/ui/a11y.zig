// Accessibility support for Zello
// Builds AccessKit-compatible accessibility trees in Zig

const std = @import("std");
const c_api = @import("../c_api.zig");
const c = c_api.c;

/// Accessibility node roles (matches AccessKit Role enum)
pub const Role = enum(u8) {
    Window = 0,
    Button = 1,
    TextInput = 2,
    Label = 3,
    Group = 4,
};

/// Accessibility actions (bitfield)
pub const Actions = struct {
    pub const Focus: u32 = 0x01;
    pub const Click: u32 = 0x02;
};

/// Rectangle in screen coordinates
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Accessibility node builder
pub const Node = struct {
    id: u64,
    role: Role,
    label: ?[]const u8 = null,
    bounds: Rect,
    actions: u32 = 0,
    children: std.ArrayList(u64),
    value: ?[]const u8 = null,
    text_selection_start: i32 = -1,
    text_selection_end: i32 = -1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, role: Role, bounds: Rect) Node {
        return .{
            .id = id,
            .role = role,
            .bounds = bounds,
            .children = std.ArrayList(u64){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Node) void {
        self.children.deinit(self.allocator);
    }

    pub fn setLabel(self: *Node, label: []const u8) void {
        self.label = label;
    }

    pub fn setValue(self: *Node, value: []const u8) void {
        self.value = value;
    }

    pub fn setTextSelection(self: *Node, start: i32, end: i32) void {
        self.text_selection_start = start;
        self.text_selection_end = end;
    }

    pub fn addAction(self: *Node, action: u32) void {
        self.actions |= action;
    }

    pub fn addChild(self: *Node, child_id: u64) !void {
        try self.children.append(self.allocator, child_id);
    }
};

/// Accessibility tree builder
pub const TreeBuilder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    root_id: u64 = 0,
    focus_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, root_id: u64) TreeBuilder {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(Node){},
            .root_id = root_id,
            .focus_id = root_id,
        };
    }

    pub fn deinit(self: *TreeBuilder) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn addNode(self: *TreeBuilder, node: Node) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn setFocus(self: *TreeBuilder, focus_id: u64) void {
        self.focus_id = focus_id;
    }

    /// Send the tree to the accessibility system
    pub fn update(self: *TreeBuilder, ctx: *c.mcore_context_t) !void {
        // Convert Zig nodes to C nodes
        var c_nodes = try self.allocator.alloc(c.mcore_a11y_node_t, self.nodes.items.len);
        defer self.allocator.free(c_nodes);

        for (self.nodes.items, 0..) |*node, i| {
            c_nodes[i] = c.mcore_a11y_node_t{
                .id = node.id,
                .role = @intFromEnum(node.role),
                .label = if (node.label) |lbl| lbl.ptr else null,
                .bounds = c.mcore_rect_t{
                    .x = node.bounds.x,
                    .y = node.bounds.y,
                    .width = node.bounds.width,
                    .height = node.bounds.height,
                },
                .actions = node.actions,
                .children = if (node.children.items.len > 0) node.children.items.ptr else null,
                .children_count = @intCast(node.children.items.len),
                .value = if (node.value) |val| val.ptr else null,
                .text_selection_start = node.text_selection_start,
                .text_selection_end = node.text_selection_end,
            };
        }

        // Send to Rust
        c.mcore_a11y_update(
            ctx,
            c_nodes.ptr,
            @intCast(self.nodes.items.len),
            self.root_id,
            self.focus_id,
        );
    }
};

/// Initialize accessibility for a window
pub fn init(ctx: ?*c.mcore_context_t, ns_view: *anyopaque) void {
    c.mcore_a11y_init(ctx, ns_view);
}
