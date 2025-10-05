# CLEANUP AND LIBRARYIFY PLAN

**Status:** We've completed Phase 1-7 from THE_PLAN.md! 🎉

Now it's time to transform this working prototype into a proper library with clean ergonomics.

---

## Goals

1. **Separate demo from library** - main.zig should be a showcase, not the implementation
2. **Hide FFI complexity** - Users shouldn't need to know about `c.mcore_*` functions
3. **Ergonomic API** - Blend Clay's declarative style, Dear ImGui's immediate-mode feel, and egui's simplicity
4. **Keep low-level power** - Don't abstract away things we haven't built yet (like dynamic layouts, state management)
5. **Auto-handle IDs and accessibility** - Make the common case easy, advanced cases possible

---

## Current State Analysis

### What's Good ✅
- **Clear separation**: Zig UI logic, Rust text/rendering backend
- **Working features**: Layout, text input, focus, IME, accessibility, mouse selection, clipboard
- **Command buffer**: Single FFI call per frame
- **Solid foundation**: All 7 phases complete

### What Needs Cleanup 🔧

#### **main.zig** (977 lines!)
- **Problem**: Demo code mixed with library usage, massive file
- **Issues**:
  - Global state (`g_ctx`, `g_ui`, `g_focus`, `g_cmd_buffer`, etc.)
  - Hardcoded widget IDs (`g_text_input1_id`, `g_text_input2_id`)
  - Manual button bounds tracking (`g_button_bounds[]`, `g_button_ids[]`)
  - Repeated boilerplate (push ID, register focusable, check focus, pop ID)
  - Helper functions mixed with demo code (`measureButton`, `drawButton`, `drawLabel`)
  - Accessibility tree built manually every frame
  - FFI calls scattered everywhere (`c.mcore_*`)

#### **ui/ modules** (good structure, needs polish)
- **id.zig**: ✅ Clean, but API could be simpler
- **focus.zig**: ✅ Clean
- **layout.zig**: ✅ Clean primitives
- **flex.zig**: ✅ Works, but allocation management is manual
- **commands.zig**: ✅ Good, but users shouldn't touch it directly
- **widgets/text_input.zig**: ⚠️ Good core, but exposes too much (scroll_offset, buffer, etc.)
- **a11y.zig**: ⚠️ Manual tree building is tedious

#### **c_api.zig**
- **Problem**: Just re-exports `@cImport`. Users have to import this to use the library.
- **Solution**: Hide it entirely inside the library

#### **Rust side** (rust/engine/src/lib.rs)
- **Problem**: Single 1000+ line file with everything
- **Needs**: Split into modules (gfx.rs, text.rs, text_input.rs are already separate, but lib.rs is huge)
- **Minor cleanup**: Some functions are long, could use better organization

---

## Proposed Library Structure

```
zello/
├── src/
│   ├── examples/
│   │   └── demo.zig                 # The current main.zig, as a demo/example
│   │
│   ├── zello.zig                    # Public library entry point
│   │   # pub const UI = @import("ui/ui.zig").UI;
│   │   # pub const layout = @import("ui/layout.zig");
│   │   # pub const widgets = @import("ui/widgets.zig");
│   │
│   ├── ui/
│   │   ├── ui.zig                   # Main UI context (replaces separate id/focus/commands)
│   │   ├── layout.zig               # Layout primitives (unchanged)
│   │   ├── flex.zig                 # Flexbox (unchanged)
│   │   ├── widgets.zig              # Public widget API (re-exports)
│   │   └── widgets/
│   │       ├── button.zig           # NEW: Proper button widget
│   │       ├── label.zig            # NEW: Proper label widget
│   │       ├── text_input.zig       # REFACTOR: Simpler public API
│   │       └── internal/            # Internal helper widgets
│   │
│   ├── platform/
│   │   ├── app.zig                  # App lifecycle (init, run, quit)
│   │   └── objc/
│   │       └── metal_view.m         # macOS windowing (unchanged)
│   │
│   ├── renderer/
│   │   └── c_api.zig                # Hidden FFI layer (was top-level)
│   │
│   └── main.zig                     # NEW: Tiny launcher for examples/demo.zig
│
├── rust/engine/src/
│   ├── lib.rs                       # REFACTOR: Just FFI exports + module declarations
│   ├── gfx.rs                       # NEW: wgpu + Vello rendering (split from lib.rs)
│   ├── text.rs                      # NEW: Parley text layout (split from lib.rs)
│   ├── text_input.rs                # REFACTOR: Simplify, already separate
│   ├── a11y.rs                      # Keep as-is
│   └── blit.wgsl                    # Unchanged
```

---

## API Design Proposal

### Inspiration Sources

**Clay**: Declarative, composable, auto-sizing
**Dear ImGui**: Immediate-mode, minimal state, returns values
**egui**: Ergonomic builder pattern, semantic helpers

### Option A: Clay-Inspired Declarative (Functional)

```zig
const zello = @import("zello");

pub fn buildUI(ui: *zello.UI) !void {
    ui.container(.{
        .layout = .{ .direction = .vertical, .gap = 20, .padding = 10 },
        .id = "main",
    }, .{
        ui.text("Hello Zello!", .{ .size = 20 });

        ui.row(.{ .gap = 15 }, .{
            ui.button("Click Me", .{}) orelse {};
            ui.button("Or Me", .{}) orelse {};
        });

        if (ui.textInput(&my_buffer, .{ .width = 400 })) |changed| {
            std.debug.print("Text changed: {s}\n", .{my_buffer});
        }
    });
}
```

**Pros:**
- Clean, declarative
- Auto-ID generation from call stack
- Type-safe

**Cons:**
- Zig doesn't have great closure syntax (need `.{}` blocks)
- Harder to implement (need comptime magic)

---

### Option B: ImGui-Style Immediate (Imperative + Returns)

```zig
const zello = @import("zello");

pub fn buildUI(ui: *zello.UI) !void {
    ui.beginVertical(.{ .gap = 20, .padding = 10 });
    defer ui.end();

    ui.label("Hello Zello!", .{ .size = 20 });

    ui.beginRow(.{ .gap = 15 });
    if (ui.button("Click Me")) {
        std.debug.print("Clicked!\n", .{});
    }
    if (ui.button("Or Me")) {
        std.debug.print("Clicked!\n", .{});
    }
    ui.end();

    if (ui.textInput("my_input", &my_buffer, .{ .width = 400 })) {
        std.debug.print("Text changed: {s}\n", .{my_buffer});
    }
}
```

**Pros:**
- Familiar to ImGui users
- Simple to implement
- Explicit control flow
- No closure weirdness

**Cons:**
- Need to remember begin/end pairs (mitigated by `defer`)
- Slightly more verbose

---

### Option C: Hybrid (Recommended) 🌟

```zig
const zello = @import("zello");

pub fn buildUI(ui: *zello.UI) !void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.15, 0.15, 0.20, 1.0 }) catch {};

    // Containers use explicit begin/end (NO defer - too confusing for layouts)
    ui.beginVstack(.{ .gap = 20, .padding = 10 });

    // Simple widgets are one-liners
    ui.label("Hello Zello!", .{ .size = 20 });

    // Horizontal layout for buttons
    ui.beginHstack(.{ .gap = 15 });

    // Widgets auto-generate IDs from label, or you can override
    if (ui.button("Click Me", .{})) {
        std.debug.print("Clicked!\n", .{});
    }

    if (ui.button("Or Me", .{})) {
        std.debug.print("Clicked!\n", .{});
    }

    ui.endHstack();

    // Text input takes an ID or generates from label
    if (ui.textInput("username", &username_buf, .{ .width = 400 })) {
        std.debug.print("Username: {s}\n", .{username_buf});
    }

    ui.endVstack();

    // Advanced: Manual ID control for dynamic widgets
    ui.pushID("button");
    ui.pushIDInt(i); // For loop indices
    if (ui.button("Dynamic", .{})) { }
    ui.popID();
    ui.popID();
}
```

**Pros:**
- Best of both worlds
- Familiar to multiple communities (SwiftUI: VStack/HStack, Flutter: Column/Row)
- Flexible (simple cases simple, complex cases possible)
- Idiomatic Zig (explicit control)
- defer for frames (natural cleanup boundary)
- NO defer for layouts (explicit is clearer for begin/end pairs)

**Cons:**
- Need to document the patterns
- Must remember to match begin/end (but that's familiar to UI devs)

---

## Detailed Refactoring Plan

### Phase 1: Create Library Structure (Week 1)

**1.1 - Create new file structure**
- [ ] Create `src/zello.zig` as library root
- [ ] Create `src/ui/ui.zig` to unify id/focus/commands
- [ ] Create `src/platform/app.zig` for app lifecycle
- [ ] Move `src/c_api.zig` → `src/renderer/c_api.zig` (make internal)
- [ ] Create `src/examples/demo.zig` (copy current main.zig)

**1.2 - Build system updates**
- [ ] Update `build.zig` to build library + examples
- [ ] Add `pub fn buildLibrary(b: *std.Build) *std.Build.Module`
- [ ] Make main.zig just launch examples/demo.zig

**1.3 - Core UI context**

Create `src/ui/ui.zig`:
```zig
const std = @import("std");
const id_mod = @import("id.zig");
const focus_mod = @import("focus.zig");
const commands_mod = @import("commands.zig");
const a11y_mod = @import("a11y.zig");
const c_api = @import("../renderer/c_api.zig");

pub const UI = struct {
    // Internals (hidden from user)
    ctx: *c_api.c.mcore_context_t,
    id_system: id_mod.UI,
    focus: focus_mod.FocusState,
    commands: commands_mod.CommandBuffer,
    a11y_builder: a11y_mod.TreeBuilder,

    // Layout stack
    layout_stack: std.ArrayList(LayoutFrame),

    // Window properties
    width: f32,
    height: f32,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *c_api.c.mcore_context_t, width: f32, height: f32) !UI {
        return .{
            .ctx = ctx,
            .id_system = id_mod.UI.init(allocator),
            .focus = focus_mod.FocusState.init(allocator),
            .commands = try commands_mod.CommandBuffer.init(allocator, 1000),
            .a11y_builder = a11y_mod.TreeBuilder.init(allocator, 1), // root ID
            .layout_stack = std.ArrayList(LayoutFrame).init(allocator),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UI) void {
        self.id_system.deinit();
        self.focus.deinit();
        self.commands.deinit();
        self.a11y_builder.deinit();
        self.layout_stack.deinit();
    }

    pub fn beginFrame(self: *UI) void {
        self.commands.reset();
        self.focus.beginFrame();
        // Auto-start accessibility tree
        self.a11y_builder = a11y_mod.TreeBuilder.init(self.allocator, 1);
    }

    pub fn endFrame(self: *UI, clear_color: [4]f32) !void {
        // Submit draw commands
        const cmds = self.commands.getCommands();
        c_api.c.mcore_render_commands(self.ctx, @ptrCast(cmds.ptr), @intCast(cmds.count));

        // Submit accessibility tree
        try self.a11y_builder.update(self.ctx);

        // Present
        const clear = c_api.c.mcore_rgba_t{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] };
        _ = c_api.c.mcore_end_frame_present(self.ctx, clear);
    }

    // Auto-ID helpers (internal)
    fn autoID(self: *UI, label: []const u8) !u64 {
        try self.id_system.pushID(label);
        const id = self.id_system.getCurrentID();
        return id;
    }

    fn popAutoID(self: *UI) void {
        self.id_system.popID();
    }

    // Manual ID control (for advanced users)
    pub fn pushID(self: *UI, label: []const u8) !void {
        try self.id_system.pushID(label);
    }

    pub fn pushIDInt(self: *UI, int_id: u64) !void {
        try self.id_system.pushIDInt(int_id);
    }

    pub fn popID(self: *UI) void {
        self.id_system.popID();
    }

    // Widget API (to be filled in)
    pub fn label(self: *UI, text: [:0]const u8, opts: LabelOptions) !void {
        // Implementation
    }

    pub fn button(self: *UI, label: [:0]const u8, opts: ButtonOptions) !bool {
        // Implementation - returns true if clicked
    }

    pub fn textInput(self: *UI, id_str: []const u8, buffer: []u8, opts: TextInputOptions) !bool {
        // Implementation - returns true if changed
    }

    // Layout helpers
    pub fn beginVstack(self: *UI, opts: VstackOptions) !void {
        // Push layout frame (vertical stack)
    }

    pub fn endVstack(self: *UI) void {
        // Pop layout frame, do actual layout
    }

    pub fn beginHstack(self: *UI, opts: HstackOptions) !void {
        // Push layout frame (horizontal stack)
    }

    pub fn endHstack(self: *UI) void {
        // Pop layout frame, do actual layout
    }

    // Measurement helpers (wraps FFI)
    pub fn measureText(self: *UI, text: []const u8, font_size: f32, max_width: f32) Size {
        var size: c_api.c.mcore_text_size_t = undefined;
        c_api.c.mcore_measure_text(self.ctx, text.ptr, font_size, max_width, &size);
        return .{ .width = size.width, .height = size.height };
    }
};

const LayoutFrame = struct {
    kind: enum { Row, Column },
    flex: flex_mod.FlexContainer,
    x: f32,
    y: f32,
};

pub const LabelOptions = struct {
    size: f32 = 16,
    color: [4]f32 = .{1, 1, 1, 1},
};

pub const ButtonOptions = struct {
    width: ?f32 = null, // Auto-size if null
    height: ?f32 = null,
};

pub const TextInputOptions = struct {
    width: f32 = 200,
    height: f32 = 40,
};

pub const VstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
};

pub const HstackOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
};
```

**Why this works:**
- Single context object (`UI`)
- Hides all FFI calls
- Auto-manages ID stack, focus, accessibility
- Users just call `ui.button()`, not `c.mcore_*`

**Checkpoint:** Can create UI context, begin/end frame

---

### Phase 2: Implement Widget API (Week 2-3)

**2.1 - Button widget**

Create `src/ui/widgets/button.zig`:
```zig
const std = @import("std");
const UI = @import("../ui.zig").UI;
const c_api = @import("../../renderer/c_api.zig");

pub const ButtonOptions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null, // Override auto-ID
};

pub fn button(ui: *UI, label: [:0]const u8, opts: ButtonOptions) !bool {
    // Auto-generate ID from label if not provided
    const id_str = opts.id orelse label;
    const id = try ui.autoID(id_str);
    defer ui.popAutoID();

    // Register as focusable
    try ui.focus.registerFocusable(id);
    const is_focused = ui.focus.isFocused(id);

    // Measure button size
    const padding_x: f32 = 20;
    const padding_y: f32 = 15;
    const font_size: f32 = 18;

    var text_size: c_api.c.mcore_text_size_t = undefined;
    c_api.c.mcore_measure_text(ui.ctx, label, font_size, 1000, &text_size);

    const width = opts.width orelse (text_size.width + padding_x * 2);
    const height = opts.height orelse (text_size.height + padding_y * 2);

    // Get position from layout system (TODO: implement layout stack)
    const pos = try ui.allocateSpace(width, height);

    // Draw background
    const bg_color = if (is_focused)
        [4]f32{ 0.4, 0.5, 0.8, 1.0 }
    else
        [4]f32{ 0.3, 0.3, 0.4, 1.0 };

    try ui.commands.roundedRect(pos.x, pos.y, width, height, 8, bg_color);

    // Draw text (centered)
    const text_x = pos.x + (width - text_size.width) / 2.0;
    const text_y = pos.y + (height - text_size.height) / 2.0;
    try ui.commands.text(label, text_x, text_y, font_size, text_size.width, .{1, 1, 1, 1});

    // Add to accessibility tree
    var a11y_node = try ui.a11y_builder.createNode(id, .Button, .{
        .x = pos.x, .y = pos.y, .width = width, .height = height
    });
    a11y_node.setLabel(label);
    a11y_node.addAction(.Focus);
    a11y_node.addAction(.Click);
    try ui.a11y_builder.addNode(a11y_node);

    // Check if clicked (TODO: implement mouse hit testing in UI context)
    const clicked = ui.wasClicked(pos.x, pos.y, width, height);

    return clicked;
}
```

**2.2 - Label widget**

Similar pattern, simpler (no interactivity)

**2.3 - TextInput widget refactor**

Wrap the existing `text_input.zig` with a simpler API:
```zig
pub fn textInput(ui: *UI, id_str: []const u8, buffer: []u8, opts: TextInputOptions) !bool {
    const id = try ui.autoID(id_str);
    defer ui.popAutoID();

    // Get or create internal TextInput widget
    const widget = try ui.getOrCreateTextInput(id, opts.width, opts.height);

    try ui.focus.registerFocusable(id);
    const is_focused = ui.focus.isFocused(id);

    const pos = try ui.allocateSpace(opts.width, opts.height);

    // Render (existing logic)
    widget.render(ui.ctx, &ui.commands, id, pos.x, pos.y, is_focused, false);

    // Add to a11y tree
    // ...

    // Check if text changed (compare with buffer)
    const current_text = widget.getText(ui.ctx, id);
    const changed = !std.mem.eql(u8, current_text, buffer);
    if (changed) {
        @memcpy(buffer[0..current_text.len], current_text);
    }

    return changed;
}
```

**Checkpoint:** Can build simple UIs without touching FFI

---

### Phase 3: Layout Stack Implementation (Week 4)

**IMPORTANT:** This phase ONLY replicates existing functionality - NO nesting support yet!

**3.1 - Simple layout (match current demo exactly)**

Implement `beginVstack`/`endVstack` and `beginHstack`/`endHstack` in `ui.zig`:

```zig
const LayoutFrame = struct {
    kind: enum { Vstack, Hstack },
    flex: flex_mod.FlexContainer,
    x: f32,
    y: f32,
};

pub fn beginVstack(self: *UI, opts: VstackOptions) !void {
    // TODO: Panic if we already have a layout frame (no nesting yet)
    if (self.layout_stack.items.len > 0) {
        @panic("Layout nesting not yet supported! Only one begin/end pair allowed per frame.");
    }

    var flex = flex_mod.FlexContainer.init(self.allocator, .Vertical);
    flex.gap = opts.gap;
    flex.padding = opts.padding;

    try self.layout_stack.append(.{
        .kind = .Vstack,
        .flex = flex,
        .x = 0,
        .y = 0,
    });
}

pub fn endVstack(self: *UI) void {
    if (self.layout_stack.items.len == 0) {
        @panic("endVstack called without matching beginVstack!");
    }

    var frame = self.layout_stack.pop();
    defer frame.flex.deinit();

    // Do layout at root level (0, 0)
    const constraints = layout_mod.BoxConstraints.loose(self.width, self.height);
    const rects = frame.flex.layout_children(constraints) catch return;
    defer self.allocator.free(rects);

    // Draw widgets using calculated rects
    // (Widgets were deferred during layout, now we render them)
    // This is a simplified approach - just match current demo behavior
}

pub fn beginHstack(self: *UI, opts: HstackOptions) !void {
    // TODO: Same panic as vstack
    if (self.layout_stack.items.len > 0) {
        @panic("Layout nesting not yet supported! Only one begin/end pair allowed per frame.");
    }

    var flex = flex_mod.FlexContainer.init(self.allocator, .Horizontal);
    flex.gap = opts.gap;
    flex.padding = opts.padding;

    try self.layout_stack.append(.{
        .kind = .Hstack,
        .flex = flex,
        .x = 0,
        .y = 0,
    });
}

pub fn endHstack(self: *UI) void {
    if (self.layout_stack.items.len == 0) {
        @panic("endHstack called without matching beginHstack!");
    }

    // Same logic as endVstack
    var frame = self.layout_stack.pop();
    defer frame.flex.deinit();

    const constraints = layout_mod.BoxConstraints.loose(self.width, self.height);
    const rects = frame.flex.layout_children(constraints) catch return;
    defer self.allocator.free(rects);
}
```

**For now:** Just replicate the exact pattern from current main.zig:
1. Create flex container
2. Widgets call `allocateSpace()` which adds children
3. On `endVstack`/`endHstack`, do layout and position widgets

**TODO for future (NOT this cleanup pass):**
- Nested layouts (constraints flow down, sizes flow up - see Clay/Flutter/Masonry)
- Two-pass layout algorithm
- Proper constraint propagation
- See Clay's layout algorithm for inspiration

**Checkpoint:** Single-level vstack/hstack works exactly like current demo

---

### Phase 4: Event Handling Integration (Week 5)

**4.1 - Mouse/keyboard in UI context**

Move mouse/keyboard state into `UI`:
```zig
pub const UI = struct {
    // ... existing fields

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false, // True for one frame after mouse up

    pub fn handleMouseDown(self: *UI, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_down = true;
    }

    pub fn handleMouseUp(self: *UI, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_down = false;
        self.mouse_clicked = true; // Set flag for one frame
    }

    pub fn handleKey(self: *UI, key: c_int, char_code: u32, shift: bool, cmd: bool) void {
        // Handle global shortcuts (Tab, etc.)
        if (key == 48) { // Tab
            if (shift) {
                self.focus.focusPrev();
            } else {
                self.focus.focusNext();
            }
            return;
        }

        // Forward to focused widget
        // (widgets register key handlers)
    }

    fn wasClicked(self: *UI, x: f32, y: f32, w: f32, h: f32) bool {
        if (!self.mouse_clicked) return false;

        const in_bounds = self.mouse_x >= x and self.mouse_x < x + w and
                          self.mouse_y >= y and self.mouse_y < y + h;

        return in_bounds;
    }
};
```

**4.2 - Platform integration**

Create `src/platform/app.zig`:
```zig
const std = @import("std");
const UI = @import("../ui/ui.zig").UI;
const c_api = @import("../renderer/c_api.zig");

// Extern functions from metal_view.m
extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.c) void) void;
// ... etc

pub const App = struct {
    ui: *UI,
    frame_callback: *const fn(ui: *UI, time: f64) void,

    pub fn run(self: *App) void {
        // Set up callbacks
        // Call mv_app_run()
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    title: [:0]const u8,
    frame_fn: *const fn(ui: *UI, time: f64) void,
) !App {
    // Initialize window
    // Create UI context
    // Return App
}
```

**Checkpoint:** Clean app initialization, input handling in UI context

---

### Phase 5: Rust Modularization (Week 6)

**5.1 - Split lib.rs**

Current `lib.rs` is ~1000 lines. Split into:

**rust/engine/src/lib.rs** (new):
```rust
mod gfx;
mod text;
mod text_input;
mod a11y;

pub use gfx::Gfx;
pub use text::TextContext;
pub use text_input::TextInputState;

// FFI exports only
#[repr(C)]
pub struct McoreContext(pub Arc<Mutex<Engine>>);

// All #[no_mangle] functions here, delegating to modules
```

**rust/engine/src/gfx.rs** (new):
```rust
// Move Gfx struct + wgpu setup here
// All rendering code
```

**rust/engine/src/text.rs** (new):
```rust
// Move TextContext + Parley code here
// Text measurement, layout, rendering
```

**Checkpoint:** Rust code is cleaner, easier to navigate

**5.2 - Add Rust-side tests**
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_text_input_insert() {
        let mut state = TextInputState::default();
        // ... test text operations
    }
}
```

---

### Phase 6: Examples and Documentation (Week 7)

**6.1 - Create examples/**

```
src/examples/
├── demo.zig           # Full-featured demo (current main.zig)
├── hello_world.zig    # Minimal example
├── login_form.zig     # Text input example
├── layout_demo.zig    # Flexbox showcase
└── README.md          # How to run examples
```

**hello_world.zig**:
```zig
const std = @import("std");
const zello = @import("../zello.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try zello.App.init(gpa.allocator(), 400, 300, "Hello Zello", onFrame);
    app.run();
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{0.1, 0.1, 0.15, 1.0}) catch {};

    ui.beginVstack(.{ .gap = 20, .padding = 20 });

    ui.label("Hello, Zello!", .{ .size = 24 });

    if (ui.button("Click Me!", .{})) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
```

**6.2 - Add doc comments**

```zig
/// Zello - Immediate-mode UI toolkit in Zig
///
/// Example usage:
/// ```zig
/// const zello = @import("zello");
///
/// fn onFrame(ui: *zello.UI, time: f64) void {
///     ui.beginFrame();
///     defer ui.endFrame(.{0, 0, 0, 1}) catch {};
///
///     if (ui.button("Hello", .{})) {
///         std.debug.print("Clicked!\n", .{});
///     }
/// }
/// ```
pub const UI = @import("ui/ui.zig").UI;
```

---

## Testing Cut Points

### Unit Tests
- **id.zig**: Hash collision resistance, ID stack push/pop
- **focus.zig**: Tab navigation, focus next/prev edge cases
- **layout.zig**: Constraint satisfaction, rect containment
- **flex.zig**: Fixed/flex sizing, gap/padding calculation
- **text_input.zig**: Cursor movement, selection, grapheme boundaries

### Integration Tests
- **Button click**: Mouse down+up in bounds triggers callback
- **Text input focus**: Tab navigation to text input, typing works
- **Layout**: Nested row/column produces correct bounds
- **Accessibility**: Tree update produces valid AccessKit nodes

### Example Tests
```zig
test "button returns true when clicked" {
    var ui = try UI.init(std.testing.allocator, ctx, 800, 600);
    defer ui.deinit();

    ui.handleMouseDown(50, 50);
    ui.handleMouseUp(50, 50);

    const clicked = try ui.button("Test", .{});
    try std.testing.expect(clicked);
}
```

---

## Code Smells & TODOs

### Current Hacks to Fix

1. **Global state in main.zig** ❌
   - `g_ctx`, `g_ui`, `g_focus`, etc.
   - **Fix:** Move into `UI` struct, pass as parameter

2. **Manual button bounds tracking** ❌
   ```zig
   var g_button_bounds: [MAX_BUTTONS]layout_mod.Rect = undefined;
   var g_button_ids: [MAX_BUTTONS]u64 = undefined;
   ```
   - **Fix:** UI context tracks hit-testable widgets automatically

3. **Repeated ID boilerplate** ❌
   ```zig
   g_ui.pushID("button1") catch {};
   const button1_id = g_ui.getCurrentID();
   g_focus.registerFocusable(button1_id) catch {};
   const is_focused_1 = g_focus.isFocused(button1_id);
   drawButton(...);
   g_ui.popID();
   ```
   - **Fix:** `ui.button()` does this internally

4. **Manual accessibility tree building** ⚠️
   - **Current:** Build tree manually in `buildA11yTree()`
   - **Fix:** Auto-build as widgets are created (track in `UI` context)

5. **Hardcoded IME cursor tracking** ⚠️
   ```zig
   var g_ime_cursor_x: f32 = 10;
   var g_ime_cursor_y: f32 = 550;
   ```
   - **Fix:** Text input widget reports cursor position to UI context

6. **Clipboard ops in main.zig** ⚠️
   - **Fix:** Add `ui.clipboard.set()`, `ui.clipboard.get()` helpers

7. **No error handling in demo** ⚠️
   - **Current:** `.catch {}` everywhere
   - **Fix:** Proper error handling in library, examples can ignore

8. **Text input widget exposes internals** ⚠️
   - **Current:** `.buffer`, `.scroll_offset` are public
   - **Fix:** Make private, expose only necessary methods

### Feature Completeness TODOs

1. **Layout system limitations** 🔨
   - ✅ Horizontal/vertical layouts work (single level)
   - ✅ Fixed + flex sizing works
   - ❌ **NO NESTING YET** - will panic if you try (intentional, see Phase 3 notes)
   - ❌ Can't mutate flex children after creation
   - ❌ No wrapping layouts
   - ❌ No scroll containers
   - **TODO for later:** Nested layouts with constraints-down/sizes-up (see Clay/Flutter/Masonry)

2. **Text input limitations** 🔨
   - ✅ Basic editing works
   - ✅ Mouse selection works
   - ✅ IME composition works
   - ✅ Clipboard copy/paste works
   - ❌ No multi-line text input
   - ❌ No undo/redo
   - ❌ No drag-and-drop

3. **Widget catalog** 🔨
   - ✅ Button
   - ✅ Label
   - ✅ TextInput
   - ❌ Checkbox
   - ❌ Radio buttons
   - ❌ Slider
   - ❌ Dropdown
   - ❌ Image
   - ❌ Custom widgets API

4. **Styling** 🔨
   - ❌ No theming system
   - ❌ Colors are hardcoded
   - ❌ No font selection (uses system-ui)
   - ❌ No custom fonts (FFI exists, not exposed)

5. **Advanced features** 🔨
   - ❌ No animation system (time is passed, but not used)
   - ❌ No tooltips
   - ❌ No drag-and-drop
   - ❌ No modal dialogs
   - ❌ No custom rendering (users can't draw arbitrary shapes)

### Nice-to-Have Testing

1. **Visual regression tests** 📸
   - Use Vello to render to PNG
   - Compare with golden images
   - Detect layout/rendering changes

2. **Fuzzing text input** 🐛
   - Random text insertion/deletion
   - Random mouse clicks
   - Ensure no crashes

3. **Accessibility compliance** ♿
   - VoiceOver navigation test
   - Keyboard-only navigation test
   - Screen reader announcements test

---

## Migration Path

For users of the current prototype:

**Before:**
```zig
const c = @import("c_api.zig").c;
var g_ctx: *c.mcore_context_t = ...;
var g_ui: id_mod.UI = ...;
var g_focus: focus_mod.FocusState = ...;

// In render loop:
g_ui.pushID("mybutton") catch {};
const id = g_ui.getCurrentID();
g_focus.registerFocusable(id) catch {};
drawButton(g_ctx, "Click", x, y, w, h, id, g_focus.isFocused(id));
g_ui.popID();
```

**After:**
```zig
const zello = @import("zello");

var ui: *zello.UI = ...;

// In render loop:
if (ui.button("Click", .{})) {
    // Clicked!
}
```

**Compatibility:** Break everything 😅 This is a prototype, clean break is OK.

---

## Success Criteria

### Phase 1-2 Done (Library Structure + Widget API):
✅ Can write hello_world.zig without touching FFI
✅ `ui.button()`, `ui.label()`, `ui.textInput()` work
✅ No global state in user code

### Phase 3-4 Done (Layout + Events):
✅ Row/column layouts work
✅ Mouse clicks on buttons work
✅ Keyboard focus navigation works

### Phase 5-6 Done (Cleanup + Examples):
✅ Rust code is modular
✅ At least 3 example programs
✅ Doc comments on public API

### Final Done (Polish):
✅ No TODOs in library code (move to GitHub issues)
✅ Clean separation: library (`src/zello.zig`), examples (`src/examples/`), demo (`main.zig`)
✅ README.md with quickstart example
✅ Tests for core widgets

---

## Open Questions

1. **Layout strategy**: Two-pass (measure, then render) or deferred rendering?
   - **Recommendation:** Start with simple linear layouts, iterate to nesting later

2. **Widget state storage**: Where to keep TextInput internal state?
   - **Option A:** HashMap in UI context (keyed by ID)
   - **Option B:** User owns widget instances
   - **Recommendation:** A (more immediate-mode)

3. **ID auto-generation**: Hash from label or increment counter?
   - **Current:** Hash from label (stable across frames)
   - **Problem:** Collisions if two buttons have same label
   - **Solution:** User can override with `.id = "unique"` option

4. **Error handling philosophy**: Propagate errors or panic?
   - **Recommendation:** Widgets return errors, user code decides (can `catch {}` if desired)

5. **Memory management**: Who owns flexbox allocation results?
   - **Current:** Caller must free
   - **Problem:** Annoying
   - **Solution:** Arena allocator per frame in UI context (reset each frame)

---

## Timeline

**Week 1:** Phase 1 (Structure)
**Week 2-3:** Phase 2 (Widget API)
**Week 4:** Phase 3 (Layout)
**Week 5:** Phase 4 (Events)
**Week 6:** Phase 5 (Rust cleanup)
**Week 7:** Phase 6 (Examples + docs)

**Total:** 7 weeks for full library-ification

**MVP:** Phases 1-2 (3 weeks) gives a usable library

---

## Notes for Implementation

- **Keep THE_PLAN.md** - It's the architectural source of truth
- **This doc is tactical** - How to refactor what we built
- **Iterate fast** - Don't gold-plate, ship early examples
- **User feedback** - Once Phase 2 done, share with early adopters
- **Zig 0.15 APIs** - Already using modern Zig, good to go

---

**Ready to build!** 🔨

Let's transform this prototype into a proper library that makes UI in Zig feel natural.
