const std = @import("std");
const layout_mod = @import("../layout.zig");
const scroll_mod = @import("../widgets/scroll_area.zig");

/// Input state for the current frame (mouse, keyboard)
pub const FrameInput = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false, // True for one frame after mouse up
};

/// Per-widget persistent state storage
pub const StateStore = struct {
    allocator: std.mem.Allocator,

    // Text input widgets (keyed by ID)
    text_inputs: std.AutoHashMap(u64, TextInputState),

    // Scroll areas (keyed by ID, persist across frames)
    scroll_areas: std.AutoHashMap(u64, scroll_mod.ScrollArea),

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{
            .allocator = allocator,
            .text_inputs = std.AutoHashMap(u64, TextInputState).init(allocator),
            .scroll_areas = std.AutoHashMap(u64, scroll_mod.ScrollArea).init(allocator),
        };
    }

    pub fn deinit(self: *StateStore) void {
        self.text_inputs.deinit();

        // Clean up scroll areas
        var it = self.scroll_areas.valueIterator();
        while (it.next()) |scroll_area| {
            scroll_area.deinit();
        }
        self.scroll_areas.deinit();
    }

    /// Get or create a text input state for a widget ID
    pub fn getOrPutTextInput(self: *StateStore, id: u64, width: f32, height: f32) !*TextInputState {
        const gop = try self.text_inputs.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = TextInputState.init(width, height);
        }
        return gop.value_ptr;
    }

    /// Get or create a scroll area state for a widget ID
    pub fn getOrPutScrollArea(self: *StateStore, id: u64, opts: ScrollAreaOptions) !*scroll_mod.ScrollArea {
        const gop = try self.scroll_areas.getOrPut(id);
        if (!gop.found_existing) {
            gop.value_ptr.* = scroll_mod.ScrollArea.init(self.allocator, .{
                .constrain_horizontal = opts.constrain_horizontal,
                .constrain_vertical = opts.constrain_vertical,
                .must_fill = opts.must_fill,
            });
        }
        return gop.value_ptr;
    }
};

/// Options for creating scroll areas
pub const ScrollAreaOptions = struct {
    constrain_horizontal: bool = false,
    constrain_vertical: bool = false,
    must_fill: bool = false,
};

/// Text input widget state
pub const TextInputState = struct {
    buffer: [256]u8 = undefined,
    width: f32,
    height: f32,
    scroll_offset: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(width: f32, height: f32) TextInputState {
        return .{
            .width = width,
            .height = height,
        };
    }
};

/// Interaction state tracked per-frame
pub const InteractionState = struct {
    allocator: std.mem.Allocator,

    // Input from host
    input: FrameInput,

    // Widget tracking for hit testing (cleared each frame)
    clickable_widgets: std.ArrayList(ClickableWidget),

    // Track buttons that were clicked this frame (filled during rendering)
    clicked_buttons: std.AutoHashMap(u64, void),

    // Track scroll areas for wheel events (filled during rendering)
    scroll_areas_for_events: std.ArrayList(ScrollAreaForEvents),

    pub fn init(allocator: std.mem.Allocator) InteractionState {
        return .{
            .allocator = allocator,
            .input = FrameInput{},
            .clickable_widgets = .{},
            .clicked_buttons = std.AutoHashMap(u64, void).init(allocator),
            .scroll_areas_for_events = .{},
        };
    }

    pub fn deinit(self: *InteractionState) void {
        self.clickable_widgets.deinit(self.allocator);
        self.clicked_buttons.deinit();
        self.scroll_areas_for_events.deinit(self.allocator);
    }

    /// Begin a new frame - reset per-frame state
    pub fn beginFrame(self: *InteractionState) void {
        self.clickable_widgets.clearRetainingCapacity();
        self.scroll_areas_for_events.clearRetainingCapacity();
        // Note: Don't clear clicked_buttons here! They need to persist from
        // the previous frame's rendering to this frame's button() calls
    }

    /// End frame - cleanup
    pub fn endFrame(self: *InteractionState) void {
        self.input.mouse_clicked = false;
    }

    /// Register a clickable widget for hit testing
    pub fn registerClickable(self: *InteractionState, id: u64, kind: ClickableKind, bounds: layout_mod.Rect) !void {
        try self.clickable_widgets.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .bounds = bounds,
        });
    }

    /// Register a scroll area for mouse wheel events
    pub fn registerScrollArea(self: *InteractionState, scroll_area: *scroll_mod.ScrollArea, bounds: layout_mod.Rect) !void {
        try self.scroll_areas_for_events.append(self.allocator, .{
            .scroll_area = scroll_area,
            .bounds = bounds,
        });
    }

    /// Check if a widget was clicked this frame
    pub fn wasClicked(self: *InteractionState, id: u64) bool {
        return self.clicked_buttons.contains(id);
    }

    /// Mark a widget as clicked (for next frame)
    pub fn markClicked(self: *InteractionState, id: u64) !void {
        try self.clicked_buttons.put(id, {});
    }

    /// Clear clicked buttons (called before rendering)
    pub fn clearClickedButtons(self: *InteractionState) void {
        self.clicked_buttons.clearRetainingCapacity();
    }

    /// Check if a point is inside a bounds
    pub fn isHovered(self: *InteractionState, bounds: layout_mod.Rect) bool {
        return bounds.contains(self.input.mouse_x, self.input.mouse_y);
    }

    /// Check if a point is pressed (hovered and mouse down)
    pub fn isPressed(self: *InteractionState, bounds: layout_mod.Rect) bool {
        return self.isHovered(bounds) and self.input.mouse_down;
    }
};

/// Kind of clickable widget
pub const ClickableKind = enum {
    Button,
    TextInput,
};

/// Clickable widget for hit testing
pub const ClickableWidget = struct {
    id: u64,
    kind: ClickableKind,
    bounds: layout_mod.Rect,
};

/// Scroll area registration for events
pub const ScrollAreaForEvents = struct {
    scroll_area: *scroll_mod.ScrollArea,
    bounds: layout_mod.Rect,
};
