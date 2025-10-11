const std = @import("std");
const layout_mod = @import("../layout.zig");
const scroll_mod = @import("../widgets/scroll_area.zig");
const frame_arena = @import("frame_arena.zig");

/// Frame exchange - double-buffered cross-frame data contract
pub const FrameExchange = struct {
    allocator: std.mem.Allocator, // Used for persistent allocations only
    prev: FrameSnapshot,
    next: FrameSnapshot,

    pub fn init(allocator: std.mem.Allocator) FrameExchange {
        return .{
            .allocator = allocator,
            .prev = FrameSnapshot.init(),
            .next = FrameSnapshot.init(),
        };
    }

    pub fn deinit(self: *FrameExchange) void {
        // Note: FrameSnapshots don't own their memory (it's in the arena)
        // So no cleanup needed
        _ = self;
    }

    /// Begin a new frame - swap buffers and recompute derived state
    pub fn beginFrame(
        self: *FrameExchange,
        arena: *frame_arena.FrameArena,
        input: FrameInput,
    ) void {
        // Swap buffers
        self.swap();

        // Clear next (will be populated during this frame's rendering)
        self.next = FrameSnapshot.init();
        self.next.arena = arena;

        // Recompute hover/press state from prev frame's data using current input
        self.prev.recomputeInteractionState(input);
    }

    /// Swap prev/next buffers
    fn swap(self: *FrameExchange) void {
        const temp = self.prev;
        self.prev = self.next;
        self.next = temp;
    }

    // ========================================================================
    // Recording API (called during rendering to populate 'next')
    // ========================================================================

    /// Record a clickable widget for next frame
    pub fn recordClickable(
        self: *FrameExchange,
        id: u64,
        bounds: layout_mod.Rect,
        kind: ClickableKind,
    ) !void {
        const arena_alloc = self.next.arena.?.allocator();
        try self.next.clickables.append(arena_alloc, .{
            .id = id,
            .bounds = bounds,
            .kind = kind,
        });
    }

    /// Record a scroll region for next frame
    pub fn recordScrollRegion(
        self: *FrameExchange,
        scroll_area: *scroll_mod.ScrollArea,
        bounds: layout_mod.Rect,
    ) !void {
        const arena_alloc = self.next.arena.?.allocator();
        try self.next.scroll_regions.append(arena_alloc, .{
            .scroll_area = scroll_area,
            .bounds = bounds,
        });
    }

    /// Record a bounding box for next frame
    pub fn recordBoundingBox(
        self: *FrameExchange,
        id: u64,
        bounds: layout_mod.Rect,
    ) !void {
        const arena_alloc = self.next.arena.?.allocator();
        try self.next.bounding_boxes.put(arena_alloc, id, bounds);
    }

    // ========================================================================
    // Query API (reads from 'prev' - last frame's data)
    // ========================================================================

    /// Check if a widget is hovered (from previous frame)
    pub fn isHovered(self: *const FrameExchange, id: u64) bool {
        return self.prev.hovered_id == id;
    }

    /// Check if a widget is pressed (from previous frame)
    pub fn isPressed(self: *const FrameExchange, id: u64) bool {
        return self.prev.pressed_id == id;
    }

    /// Check if a widget was clicked (from previous frame)
    pub fn wasClicked(self: *const FrameExchange, id: u64) bool {
        return self.prev.clicked_id == id;
    }

    /// Get the bounding box for a widget from previous frame
    pub fn getBoundingBox(self: *const FrameExchange, id: u64) ?layout_mod.Rect {
        return self.prev.bounding_boxes.get(id);
    }

    /// Get scroll regions for event handling
    pub fn getScrollRegions(self: *const FrameExchange) []const ScrollRegion {
        return self.prev.scroll_regions.items;
    }
};

/// Input state for a single frame
pub const FrameInput = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
};

/// Snapshot of one frame's cross-frame data
pub const FrameSnapshot = struct {
    arena: ?*frame_arena.FrameArena = null,

    // Widget tracking (allocated from arena)
    clickables: std.ArrayListUnmanaged(ClickableRecord) = .{},
    scroll_regions: std.ArrayListUnmanaged(ScrollRegion) = .{},
    bounding_boxes: std.AutoHashMapUnmanaged(u64, layout_mod.Rect) = .{},

    // Computed interaction state (derived from clickables + input)
    hovered_id: ?u64 = null,
    pressed_id: ?u64 = null,
    clicked_id: ?u64 = null,

    pub fn init() FrameSnapshot {
        return .{};
    }

    /// Recompute interaction state from clickables and current input
    fn recomputeInteractionState(self: *FrameSnapshot, input: FrameInput) void {
        self.hovered_id = null;
        self.pressed_id = null;
        self.clicked_id = null;

        // Find hovered widget (topmost clickable under mouse)
        var i: usize = self.clickables.items.len;
        while (i > 0) {
            i -= 1;
            const clickable = &self.clickables.items[i];
            if (clickable.bounds.contains(input.mouse_x, input.mouse_y)) {
                self.hovered_id = clickable.id;

                // Check for press
                if (input.mouse_down) {
                    self.pressed_id = clickable.id;
                }

                // Check for click (mouse was released this frame while hovering)
                if (input.mouse_clicked) {
                    self.clicked_id = clickable.id;
                }

                break; // Only process topmost widget
            }
        }
    }
};

/// Record of a clickable widget
pub const ClickableRecord = struct {
    id: u64,
    bounds: layout_mod.Rect,
    kind: ClickableKind,
};

/// Kind of clickable widget
pub const ClickableKind = enum {
    Button,
    TextInput,
};

/// Record of a scroll region
pub const ScrollRegion = struct {
    scroll_area: *scroll_mod.ScrollArea,
    bounds: layout_mod.Rect,
};
