# THE PLAN

**Building a no-compromises immediate-mode UI toolkit in Zig**

*Zig owns UI. Rust is a text specialist. One-way delegation.*

---

## North Star

**Zig Territory:**
- Layout engine (flexbox in ~300 LOC)
- ID management (hash + stack)
- Focus state (which widget has focus)
- Hit testing (point-in-rect)
- Event routing (mouse, keyboard)
- Widget logic (buttons, containers, simple text)
- Layout caching (for performance)
- Accessibility tree (via accesskit-c bindings)
- Command buffer (preallocated, sent to Rust)

**Rust Territory:**
- Text measurement (Parley layout)
- Text editing state (UTF-8 String, cursor, selection)
- Text editing operations (insert, delete, grapheme boundaries)
- IME composition (platform text input)
- Text rendering (Vello glyphs)
- Shape rendering (Vello fill/stroke)
- Accessibility platform bridge (macOS AXUIElement)

**The Boundary:**
Rust is a **specialized rendering and text backend**. It has NO concept of widgets, containers, or UI structure. It receives:
1. Draw commands (shapes, text)
2. Text editing events (for active text inputs only)
3. Accessibility tree data (from Zig)

---

## Current Status (M3 Complete)

**What works:**
- ✅ Zig window with CAMetalLayer
- ✅ wgpu surface + Vello renderer
- ✅ Rounded rectangles with animation
- ✅ Text rendering with Parley + proper glyph positioning
- ✅ Command buffer architecture (implicit in current API)

**What's next:**
Build the UI layer on top of this solid foundation.

---

## Phase-by-Phase Implementation

### **PHASE 1: Stable IDs + Focus** (Week 1-2)

**Goal:** ID system + focus management, entirely in Zig

#### Zig Implementation

**1.1 - ID System** (`src/ui/id.zig`)

```zig
pub const UI = struct {
    id_stack: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UI {
        return .{
            .id_stack = std.ArrayList(u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn pushID(self: *UI, label: []const u8) !void {
        const id = hashString(label);
        try self.id_stack.append(id);
    }

    pub fn pushIDInt(self: *UI, int_id: u64) !void {
        const parent = if (self.id_stack.items.len > 0)
            self.id_stack.items[self.id_stack.items.len - 1]
        else
            0;
        const id = hashCombine(parent, int_id);
        try self.id_stack.append(id);
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
```

**1.2 - Focus State** (`src/ui/focus.zig`)

```zig
pub const FocusState = struct {
    focused_id: ?u64 = null,
    focusable_ids: std.ArrayList(u64),  // Built each frame
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FocusState {
        return .{
            .focusable_ids = std.ArrayList(u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn beginFrame(self: *FocusState) void {
        self.focusable_ids.clearRetainingCapacity();
    }

    pub fn registerFocusable(self: *FocusState, id: u64) !void {
        try self.focusable_ids.append(id);
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
```

**FFI Addition:** NONE! Pure Zig.

**Checkpoint:** Can track focus, tab between widgets (hardcoded for now)

---

### **PHASE 2: Flexbox Layout** (Week 3-4)

**Goal:** Clay-inspired flexbox layout, pure Zig

#### Zig Implementation

**2.1 - Layout Primitives** (`src/ui/layout.zig`)

```zig
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
```

**2.2 - Flex Container** (`src/ui/flex.zig`)

```zig
pub const FlexChild = struct {
    size: Size,      // Measured size
    flex: f32 = 0,   // 0 = fixed, >0 = proportional
};

pub const FlexContainer = struct {
    axis: Axis,
    gap: f32 = 0,
    padding: f32 = 0,
    cross_alignment: Alignment = .Start,
    children: std.ArrayList(FlexChild),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, axis: Axis) FlexContainer {
        return .{
            .axis = axis,
            .children = std.ArrayList(FlexChild).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addChild(self: *FlexContainer, size: Size, flex: f32) !void {
        try self.children.append(.{ .size = size, .flex = flex });
    }

    pub fn addSpacer(self: *FlexContainer, flex: f32) !void {
        try self.children.append(.{
            .size = .{ .width = 0, .height = 0 },
            .flex = flex,
        });
    }

    pub fn layout(self: *FlexContainer, constraints: BoxConstraints) ![]Rect {
        const available = switch (self.axis) {
            .Horizontal => constraints.max_width,
            .Vertical => constraints.max_height,
        };

        // 1. Measure fixed children
        var used: f32 = self.padding * 2;
        var flex_total: f32 = 0;

        for (self.children.items) |child| {
            if (child.flex == 0) {
                used += switch (self.axis) {
                    .Horizontal => child.size.width,
                    .Vertical => child.size.height,
                };
            } else {
                flex_total += child.flex;
            }
        }

        if (self.children.items.len > 1) {
            used += self.gap * @as(f32, @floatFromInt(self.children.items.len - 1));
        }

        // 2. Distribute remaining to flex children
        const remaining = @max(0, available - used);
        const flex_unit = if (flex_total > 0) remaining / flex_total else 0;

        // 3. Calculate positions
        var results = try self.allocator.alloc(Rect, self.children.items.len);
        var pos = self.padding;

        for (self.children.items, 0..) |child, i| {
            const main_size = if (child.flex > 0)
                child.flex * flex_unit
            else switch (self.axis) {
                .Horizontal => child.size.width,
                .Vertical => child.size.height,
            };

            const cross_size = switch (self.axis) {
                .Horizontal => child.size.height,
                .Vertical => child.size.width,
            };

            results[i] = switch (self.axis) {
                .Horizontal => .{
                    .x = pos,
                    .y = self.padding,
                    .width = main_size,
                    .height = cross_size,
                },
                .Vertical => .{
                    .x = self.padding,
                    .y = pos,
                    .width = cross_size,
                    .height = main_size,
                },
            };

            pos += main_size + self.gap;
        }

        return results;
    }
};
```

**FFI Addition:** NONE! Pure Zig.

**Checkpoint:** Can layout 3 fixed-size boxes in a row with gaps

---

**2.3 - Integrate Text Measurement**

Zig calls Rust to measure text:

```zig
pub fn measureText(ctx: *c.mcore_context_t, text: []const u8, font_size: f32, max_width: f32) Size {
    var size: c.mcore_text_size_t = undefined;
    c.mcore_measure_text(ctx, text.ptr, font_size, max_width, &size);
    return .{ .width = size.width, .height = size.height };
}

// Use in layout:
const text_size = measureText(ctx, "Hello", 16, 200);
try flex.addChild(text_size, 0);  // Fixed size
```

**FFI Addition:**
```c
typedef struct {
    float width;
    float height;
} mcore_text_size_t;

void mcore_measure_text(
    mcore_context_t* ctx,
    const char* text,
    float font_size,
    float max_width,
    mcore_text_size_t* out
);
```

**Rust Implementation:**
```rust
#[no_mangle]
pub extern "C" fn mcore_measure_text(
    ctx: *mut McoreContext,
    text: *const i8,
    font_size: f32,
    max_width: f32,
    out: *mut McoreTextSize,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let text = unsafe { CStr::from_ptr(text) }.to_str().unwrap_or("");
    let out = unsafe { out.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    let text_cx_ptr = &mut guard.text_cx as *mut TextContext;
    let layout = unsafe {
        let text_cx = &mut *text_cx_ptr;
        let mut builder = text_cx.layout_cx.ranged_builder(
            &mut text_cx.font_cx,
            text,
            guard.gfx.scale,
            true
        );
        builder.push_default(StyleProperty::FontSize(font_size));
        builder.push_default(StyleProperty::FontStack(FontStack::Source("system-ui".into())));
        let mut layout = builder.build(text);
        layout.break_all_lines(Some(max_width));
        layout
    };

    out.width = layout.width();
    out.height = layout.height();
}

#[repr(C)]
pub struct McoreTextSize {
    pub width: f32,
    pub height: f32,
}
```

**Checkpoint:** Zig can measure text and use it in flexbox layout

---

### **PHASE 3: Command Buffer** (Week 5)

**Goal:** Batch rendering, 1 FFI call per frame

#### Command Buffer Structure

**Zig Side** (`src/ui/commands.zig`)

```zig
pub const DrawCommandKind = enum(u8) {
    RoundedRect,
    Text,
    Line,
    FocusRing,
};

pub const DrawCommand = extern struct {
    kind: DrawCommandKind,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,  // For rounded rect
    color: [4]f32,
    text_ptr: ?[*:0]const u8,  // For text
    font_size: f32,
    // Padding to consistent size
    _padding: [24]u8 = undefined,
};

pub const CommandBuffer = struct {
    commands: []DrawCommand,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !CommandBuffer {
        return .{
            .commands = try allocator.alloc(DrawCommand, capacity),
        };
    }

    pub fn reset(self: *CommandBuffer) void {
        self.count = 0;
    }

    pub fn roundedRect(self: *CommandBuffer, x: f32, y: f32, w: f32, h: f32, r: f32, color: [4]f32) !void {
        self.commands[self.count] = .{
            .kind = .RoundedRect,
            .x = x, .y = y,
            .width = w, .height = h,
            .radius = r,
            .color = color,
            .text_ptr = null,
            .font_size = 0,
        };
        self.count += 1;
    }

    pub fn text(self: *CommandBuffer, str: []const u8, x: f32, y: f32, font_size: f32, color: [4]f32) !void {
        self.commands[self.count] = .{
            .kind = .Text,
            .x = x, .y = y,
            .width = 0, .height = 0,
            .radius = 0,
            .color = color,
            .text_ptr = str.ptr,
            .font_size = font_size,
        };
        self.count += 1;
    }

    pub fn submit(self: *CommandBuffer, ctx: *c.mcore_context_t) void {
        c.mcore_render_commands(ctx, self.commands.ptr, @intCast(self.count));
    }
};
```

**FFI Addition:**
```c
void mcore_render_commands(
    mcore_context_t* ctx,
    const mcore_draw_command_t* commands,
    int count
);
```

**Rust Implementation:**
```rust
#[repr(C)]
pub struct McoreDrawCommand {
    pub kind: u8,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub radius: f32,
    pub color: [f32; 4],
    pub text_ptr: *const i8,
    pub font_size: f32,
    pub _padding: [24]u8,
}

#[no_mangle]
pub extern "C" fn mcore_render_commands(
    ctx: *mut McoreContext,
    commands: *const McoreDrawCommand,
    count: i32,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let commands = unsafe { std::slice::from_raw_parts(commands, count as usize) };
    let mut guard = ctx.0.lock();

    for cmd in commands {
        match cmd.kind {
            0 => { // RoundedRect
                let shape = kurbo::RoundedRect::new(
                    cmd.x as f64, cmd.y as f64,
                    (cmd.x + cmd.width) as f64,
                    (cmd.y + cmd.height) as f64,
                    cmd.radius as f64,
                );
                guard.scene.fill(
                    Fill::NonZero,
                    kurbo::Affine::IDENTITY,
                    Color::new(cmd.color),
                    None,
                    &shape,
                );
            }
            1 => { // Text
                let text = unsafe { CStr::from_ptr(cmd.text_ptr) }.to_str().unwrap_or("");
                // ... (use existing mcore_text_draw logic)
            }
            _ => {}
        }
    }
}
```

**Checkpoint:** Command buffer works, 1 FFI call per frame instead of N

---

### **PHASE 4: Text Input State** (Week 6-8)

**Goal:** Rust owns text editing, Zig gets clean API

#### The Text State System

**Rust Side:**

```rust
#[derive(Default)]
struct TextInputState {
    content: String,
    cursor: usize,           // Byte offset in UTF-8
    selection: Option<Range<usize>>,
    composition: Option<String>,  // IME
}

struct Engine {
    // ... existing fields
    text_states: HashMap<u64, TextInputState>,
}

#[no_mangle]
pub extern "C" fn mcore_text_input_event(
    ctx: *mut McoreContext,
    id: u64,
    event: *const McoreTextEvent,
) -> bool {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let event = unsafe { event.as_ref() }.unwrap();
    let mut guard = ctx.0.lock();

    let state = guard.text_states.entry(id).or_default();
    let mut changed = false;

    match event.kind {
        TextEventKind::InsertChar => {
            if let Some(sel) = &state.selection {
                state.content.drain(sel.clone());
                state.cursor = sel.start;
                state.selection = None;
            }
            let ch = unsafe { char::from_u32_unchecked(event.char_code) };
            state.content.insert(state.cursor, ch);
            state.cursor += ch.len_utf8();
            changed = true;
        }
        TextEventKind::Backspace => {
            if let Some(sel) = &state.selection {
                state.content.drain(sel.clone());
                state.cursor = sel.start;
                state.selection = None;
            } else if state.cursor > 0 {
                // Find previous grapheme boundary
                let prev = previous_grapheme_boundary(&state.content, state.cursor);
                state.content.drain(prev..state.cursor);
                state.cursor = prev;
            }
            changed = true;
        }
        TextEventKind::Delete => {
            if let Some(sel) = &state.selection {
                state.content.drain(sel.clone());
                state.cursor = sel.start;
                state.selection = None;
            } else {
                let next = next_grapheme_boundary(&state.content, state.cursor);
                state.content.drain(state.cursor..next);
            }
            changed = true;
        }
        TextEventKind::MoveCursor => {
            match event.direction {
                CursorDirection::Left => {
                    state.cursor = previous_grapheme_boundary(&state.content, state.cursor);
                }
                CursorDirection::Right => {
                    state.cursor = next_grapheme_boundary(&state.content, state.cursor);
                }
                CursorDirection::Home => state.cursor = 0,
                CursorDirection::End => state.cursor = state.content.len(),
            }
            if event.extend_selection {
                // Update selection
            }
        }
    }

    changed
}

// Helper: UTF-8 grapheme boundaries
fn previous_grapheme_boundary(text: &str, cursor: usize) -> usize {
    // Walk backward to find grapheme cluster boundary
    // This is non-trivial! Use unicode-segmentation crate or copy masonry's impl
    let mut offset = cursor;
    while offset > 0 {
        offset -= 1;
        if text.is_char_boundary(offset) {
            // Check if it's a grapheme boundary (not just char boundary)
            // For simple ASCII, char boundary == grapheme boundary
            // For complex cases (emoji, combining marks), need proper algorithm
            break;
        }
    }
    offset
}

fn next_grapheme_boundary(text: &str, cursor: usize) -> usize {
    let mut offset = cursor;
    while offset < text.len() {
        offset += 1;
        if text.is_char_boundary(offset) {
            break;
        }
    }
    offset
}

#[no_mangle]
pub extern "C" fn mcore_text_input_get(
    ctx: *mut McoreContext,
    id: u64,
    buf: *mut u8,
    buf_len: usize,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let guard = ctx.0.lock();

    if let Some(state) = guard.text_states.get(&id) {
        let content_bytes = state.content.as_bytes();
        let copy_len = content_bytes.len().min(buf_len - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(content_bytes.as_ptr(), buf, copy_len);
            *buf.add(copy_len) = 0;  // Null terminate
        }
        copy_len as i32
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn mcore_text_input_cursor(ctx: *mut McoreContext, id: u64) -> i32 {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let guard = ctx.0.lock();
    guard.text_states.get(&id).map(|s| s.cursor as i32).unwrap_or(0)
}
```

**FFI Addition:**
```c
typedef enum {
    TEXT_EVENT_INSERT_CHAR,
    TEXT_EVENT_BACKSPACE,
    TEXT_EVENT_DELETE,
    TEXT_EVENT_MOVE_CURSOR,
} mcore_text_event_kind_t;

typedef enum {
    CURSOR_LEFT,
    CURSOR_RIGHT,
    CURSOR_HOME,
    CURSOR_END,
} mcore_cursor_direction_t;

typedef struct {
    mcore_text_event_kind_t kind;
    uint32_t char_code;  // For INSERT_CHAR
    mcore_cursor_direction_t direction;  // For MOVE_CURSOR
    bool extend_selection;  // Shift key held
} mcore_text_event_t;

bool mcore_text_input_event(mcore_context_t* ctx, uint64_t id, const mcore_text_event_t* event);
int mcore_text_input_get(mcore_context_t* ctx, uint64_t id, char* buf, int buf_len);
int mcore_text_input_cursor(mcore_context_t* ctx, uint64_t id);
void mcore_text_input_set(mcore_context_t* ctx, uint64_t id, const char* text);
```

**Zig Usage:**

```zig
const TextInput = struct {
    id: u64,
    buffer: [256]u8 = undefined,

    pub fn render(self: *TextInput, ui: *UI, ctx: *c.mcore_context_t) bool {
        const is_focused = ui.focus.isFocused(self.id);

        // Get current text from Rust
        const len = c.mcore_text_input_get(ctx, self.id, &self.buffer, 256);
        const text = self.buffer[0..@intCast(len)];

        // Measure and layout
        const size = measureText(ctx, text, 16, 200);
        const bounds = ui.reserveSpace(size.width + 10, size.height + 6);

        // Draw background
        ui.commands.roundedRect(
            bounds.x, bounds.y, bounds.width, bounds.height, 4,
            if (is_focused) .{0.3, 0.3, 0.4, 1} else .{0.2, 0.2, 0.3, 1}
        );

        // Draw text
        ui.commands.text(text, bounds.x + 5, bounds.y + 3, 16, .{1, 1, 1, 1});

        // Draw cursor if focused
        if (is_focused) {
            const cursor = c.mcore_text_input_cursor(ctx, self.id);
            // Calculate cursor X position (simplified, would use Parley)
            const cursor_x = bounds.x + 5 + @as(f32, @floatFromInt(cursor)) * 8;
            ui.commands.line(cursor_x, bounds.y + 2, cursor_x, bounds.y + bounds.height - 2, .{1, 1, 1, 1});
        }

        return false;  // Changed flag
    }

    pub fn handleKey(self: *TextInput, ctx: *c.mcore_context_t, key: KeyEvent) void {
        const event = c.mcore_text_event_t{
            .kind = switch (key) {
                .Char => |ch| .TEXT_EVENT_INSERT_CHAR,
                .Backspace => .TEXT_EVENT_BACKSPACE,
                .Delete => .TEXT_EVENT_DELETE,
                .Left, .Right, .Home, .End => .TEXT_EVENT_MOVE_CURSOR,
                else => return,
            },
            .char_code = if (key == .Char) key.Char else 0,
            .direction = switch (key) {
                .Left => .CURSOR_LEFT,
                .Right => .CURSOR_RIGHT,
                .Home => .CURSOR_HOME,
                .End => .CURSOR_END,
                else => .CURSOR_LEFT,
            },
            .extend_selection = key.shift_held,
        };

        _ = c.mcore_text_input_event(ctx, self.id, &event);
    }
};
```

**Checkpoint:** Text input widget works with cursor movement and editing

---

### **PHASE 5: Text Selection** (Week 9-10)

**Goal:** Mouse selection, copy/paste

#### Mouse Selection

**Rust adds hit testing:**

```rust
#[no_mangle]
pub extern "C" fn mcore_text_hit_test(
    ctx: *mut McoreContext,
    id: u64,
    x: f32,
    y: f32,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let guard = ctx.0.lock();

    let Some(state) = guard.text_states.get(&id) else {
        return 0;
    };

    // Get the layout for this text
    // (Cached in text_states per ID)
    let layout = &state.layout;

    // Hit test using Parley
    for (line_idx, line) in layout.lines().enumerate() {
        if y >= line.metrics().baseline && y < line.metrics().baseline + line.metrics().line_height {
            let mut glyph_x = 0.0;
            for cluster in line.clusters() {
                if x < glyph_x + cluster.advance() / 2.0 {
                    return cluster.text_range().start as i32;
                }
                glyph_x += cluster.advance();
            }
            return line.text_range().end as i32;
        }
    }

    state.content.len() as i32
}
```

**Zig handles mouse events:**

```zig
pub fn handleMouse(self: *TextInput, ctx: *c.mcore_context_t, mouse: MouseEvent, bounds: Rect) void {
    if (mouse.kind == .Down) {
        const local_x = mouse.x - bounds.x - 5;  // Account for padding
        const local_y = mouse.y - bounds.y - 3;
        const cursor_pos = c.mcore_text_hit_test(ctx, self.id, local_x, local_y);

        const event = c.mcore_text_event_t{
            .kind = .TEXT_EVENT_SET_CURSOR,
            .cursor_position = cursor_pos,
        };
        _ = c.mcore_text_input_event(ctx, self.id, &event);
    }

    // TODO: Handle drag for selection
}
```

**Checkpoint:** Can click to position cursor in text

---

### **PHASE 6: IME Composition** (Week 11-12)

**Goal:** Support Japanese/Chinese input

#### macOS IME Bridge

**Objective-C** (`src/objc/metal_view.m` additions):

```objc
@interface MVMetalView () <NSTextInputClient>
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedRange;
@end

@implementation MVMetalView

// Text input client methods
- (void)insertText:(id)string replacementRange:(NSRange)range {
    const char* text = [string UTF8String];
    if (g_ime_commit_cb) {
        g_ime_commit_cb(text);
    }
}

- (void)setMarkedText:(id)string
       selectedRange:(NSRange)selectedRange
    replacementRange:(NSRange)replacementRange {
    self.markedText = [string copy];
    self.markedRange = replacementRange;

    if (g_ime_update_cb) {
        const char* marked = [string UTF8String];
        g_ime_update_cb(marked, (int)selectedRange.location);
    }
}

- (NSRange)markedRange {
    return self.markedRange;
}

- (NSRange)selectedRange {
    // Query Rust for selection
    return NSMakeRange(0, 0);  // TODO
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actualRange {
    // Get cursor position for IME popup
    if (g_cursor_rect_cb) {
        mcore_rect_t rect = g_cursor_rect_cb();
        return NSMakeRect(rect.x, rect.y, 1, rect.h);
    }
    return NSZeroRect;
}

- (BOOL)hasMarkedText {
    return self.markedText.length > 0;
}

@end

// C callbacks
static void (*g_ime_update_cb)(const char*, int) = NULL;
static void (*g_ime_commit_cb)(const char*) = NULL;
static mcore_rect_t (*g_cursor_rect_cb)(void) = NULL;

void mv_set_ime_callbacks(
    void (*update)(const char*, int),
    void (*commit)(const char*),
    mcore_rect_t (*cursor_rect)(void)
) {
    g_ime_update_cb = update;
    g_ime_commit_cb = commit;
    g_cursor_rect_cb = cursor_rect;
}
```

**Zig IME Handler:**

```zig
fn imeUpdate(composition: [*:0]const u8, cursor: c_int) callconv(.C) void {
    // Store composition state
    ime_state.composition = std.mem.span(composition);
    ime_state.cursor_offset = cursor;
}

fn imeCommit(text: [*:0]const u8) callconv(.C) void {
    // Insert committed text
    const event = c.mcore_text_event_t{
        .kind = .TEXT_EVENT_INSERT_TEXT,
        .text_ptr = text,
    };
    _ = c.mcore_text_input_event(ctx, focused_id, &event);

    // Clear composition
    ime_state.composition = null;
}

fn getCursorRect() callconv(.C) c.mcore_rect_t {
    // Get cursor position from layout
    const cursor_pos = c.mcore_text_input_cursor(ctx, focused_id);
    // Calculate screen position
    return .{ .x = cursor_x, .y = cursor_y, .w = 1, .h = font_size };
}
```

**Rust IME Handling:**

```rust
// Add to TextInputState
struct TextInputState {
    // ... existing fields
    composition: Option<ImeComposition>,
}

struct ImeComposition {
    text: String,
    cursor_offset: usize,
}

// Handle IME events
impl TextEventKind {
    ImeUpdate => {
        state.composition = Some(ImeComposition {
            text: event.text.to_string(),
            cursor_offset: event.cursor_offset,
        });
    }
    ImeCommit => {
        state.content.insert_str(state.cursor, event.text);
        state.cursor += event.text.len();
        state.composition = None;
    }
}

// Render composition with underline
fn render_composition(scene: &mut Scene, comp: &ImeComposition, x: f32, y: f32) {
    // Draw composition text
    // Draw underline beneath
    let line = kurbo::Line::new((x, y + font_size + 2), (x + width, y + font_size + 2));
    scene.stroke(&Stroke::new(1.0), COMPOSITION_UNDERLINE_COLOR, &line);
}
```

**Checkpoint:** IME works for Japanese input, composition shows with underline

---

### **PHASE 7: Accessibility via accesskit-c** (Week 13-15)

**Goal:** Screen reader support, all from Zig

#### Zig Builds AccessKit Tree

**Use accesskit C bindings:**

```zig
const ak = @cImport({
    @cInclude("accesskit.h");
});

pub const A11yBuilder = struct {
    tree: ak.TreeBuilder,

    pub fn init() A11yBuilder {
        return .{
            .tree = ak.tree_builder_new(),
        };
    }

    pub fn addButton(self: *A11yBuilder, id: u64, name: []const u8, bounds: Rect) void {
        const node = ak.node_builder_new(id, ak.ROLE_BUTTON);
        ak.node_builder_set_name(node, name.ptr, name.len);
        ak.node_builder_set_bounds(node, bounds.x, bounds.y, bounds.width, bounds.height);
        ak.node_builder_add_action(node, ak.ACTION_CLICK);
        ak.tree_builder_add_node(self.tree, node);
    }

    pub fn addLabel(self: *A11yBuilder, id: u64, text: []const u8, bounds: Rect) void {
        const node = ak.node_builder_new(id, ak.ROLE_STATIC_TEXT);
        ak.node_builder_set_name(node, text.ptr, text.len);
        ak.node_builder_set_bounds(node, bounds.x, bounds.y, bounds.width, bounds.height);
        ak.tree_builder_add_node(self.tree, node);
    }

    pub fn addTextInput(self: *A11yBuilder, id: u64, content: []const u8, cursor: usize, bounds: Rect) void {
        const node = ak.node_builder_new(id, ak.ROLE_TEXT_INPUT);
        ak.node_builder_set_value(node, content.ptr, content.len);
        ak.node_builder_set_text_selection(node, cursor, cursor);  // No selection for now
        ak.node_builder_set_bounds(node, bounds.x, bounds.y, bounds.width, bounds.height);
        ak.tree_builder_add_node(self.tree, node);
    }

    pub fn finish(self: *A11yBuilder) ak.TreeUpdate {
        return ak.tree_builder_build(self.tree);
    }
};

// Use in frame:
pub fn buildA11yTree(ui: *UI, ctx: *c.mcore_context_t) void {
    var builder = A11yBuilder.init();

    for (ui.widgets) |widget| {
        switch (widget.kind) {
            .Button => builder.addButton(widget.id, widget.label, widget.bounds),
            .Label => builder.addLabel(widget.id, widget.text, widget.bounds),
            .TextInput => {
                // Get text from Rust
                var buf: [256]u8 = undefined;
                const len = c.mcore_text_input_get(ctx, widget.id, &buf, 256);
                const cursor = c.mcore_text_input_cursor(ctx, widget.id);
                builder.addTextInput(widget.id, buf[0..len], cursor, widget.bounds);
            },
        }
    }

    const tree = builder.finish();
    c.mcore_a11y_update(ctx, tree);  // Send to Rust for platform bridge
}
```

**Rust Platform Bridge:**

```rust
use accesskit_macos::Adapter;

struct Engine {
    // ... existing
    a11y_adapter: Option<Adapter>,
}

#[no_mangle]
pub extern "C" fn mcore_a11y_update(
    ctx: *mut McoreContext,
    tree: *const accesskit::TreeUpdate,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let tree = unsafe { &*tree };
    let mut guard = ctx.0.lock();

    // Forward to macOS adapter
    if let Some(adapter) = &mut guard.a11y_adapter {
        adapter.update(tree.clone());
    }
}
```

**Note:** Need to bridge accesskit C types to Rust types, or just use Rust accesskit directly and serialize tree from Zig.

**Checkpoint:** VoiceOver reads buttons and text, focus navigation works

---

## Complete API Reference

### **Phase 1-2: Core + Layout**

```c
// Context
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void mcore_destroy(mcore_context_t* ctx);
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Frame
void mcore_begin_frame(mcore_context_t* ctx, double time);
void mcore_end_frame(mcore_context_t* ctx, mcore_rgba_t clear);

// Text measurement
void mcore_measure_text(mcore_context_t* ctx, const char* text, float font_size, float max_width, mcore_text_size_t* out);
```

### **Phase 3: Command Buffer**

```c
typedef struct {
    uint8_t kind;  // 0=RoundedRect, 1=Text, 2=Line
    float x, y, width, height, radius;
    float color[4];
    const char* text_ptr;
    float font_size;
    uint8_t _padding[24];
} mcore_draw_command_t;

void mcore_render_commands(mcore_context_t* ctx, const mcore_draw_command_t* commands, int count);
```

### **Phase 4: Text Input**

```c
typedef struct {
    uint8_t kind;  // INSERT_CHAR, BACKSPACE, DELETE, MOVE_CURSOR, SET_CURSOR
    uint32_t char_code;
    uint8_t direction;  // LEFT, RIGHT, HOME, END
    bool extend_selection;
    int cursor_position;  // For SET_CURSOR
    const char* text_ptr;  // For INSERT_TEXT
} mcore_text_event_t;

bool mcore_text_input_event(mcore_context_t* ctx, uint64_t id, const mcore_text_event_t* event);
int mcore_text_input_get(mcore_context_t* ctx, uint64_t id, char* buf, int buf_len);
int mcore_text_input_cursor(mcore_context_t* ctx, uint64_t id);
void mcore_text_input_set(mcore_context_t* ctx, uint64_t id, const char* text);
```

### **Phase 5: Selection**

```c
int mcore_text_hit_test(mcore_context_t* ctx, uint64_t id, float x, float y);
void mcore_text_input_selection(mcore_context_t* ctx, uint64_t id, int* start, int* end);
```

### **Phase 6: IME**

```c
// Set from Objective-C IME callbacks
void mcore_ime_update(mcore_context_t* ctx, uint64_t id, const char* composition, int cursor);
void mcore_ime_commit(mcore_context_t* ctx, uint64_t id, const char* text);
```

### **Phase 7: Accessibility**

```c
// Zig sends serialized AccessKit tree
void mcore_a11y_update(mcore_context_t* ctx, const void* tree_data, int data_len);
```

**Total API: ~20 functions across all phases**

---

## File Structure

```
zello/
├── src/
│   ├── main.zig                  # App entry point
│   └── ui/
│       ├── ui.zig                # Main UI module
│       ├── id.zig                # ID management
│       ├── focus.zig             # Focus state
│       ├── layout.zig            # Layout primitives
│       ├── flex.zig              # Flexbox container
│       ├── commands.zig          # Draw command buffer
│       ├── widgets/
│       │   ├── label.zig
│       │   ├── button.zig
│       │   └── text_input.zig
│       └── a11y.zig              # AccessKit integration
│
├── rust/engine/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                # C API exports
│       ├── gfx.rs                # wgpu + Vello renderer
│       ├── text.rs               # Parley text layout + measurement
│       ├── text_input.rs         # Text editing state
│       ├── ime.rs                # IME composition
│       └── a11y_bridge.rs        # AccessKit platform adapter
│
├── bindings/
│   └── mcore.h                   # C API header
│
└── THE_PLAN.md                   # This file
```

---

## Implementation Checklist

### **Phase 1: IDs + Focus** (Pure Zig)
- [ ] `ui/id.zig` - ID hashing and stack
- [ ] `ui/focus.zig` - Focus state management
- [ ] Update `main.zig` to use ID system
- [ ] Test: Tab navigation between hardcoded buttons

### **Phase 2: Layout** (Pure Zig)
- [ ] `ui/layout.zig` - Size, Rect, BoxConstraints
- [ ] `ui/flex.zig` - Flexbox container
- [ ] FFI: `mcore_measure_text` in Rust
- [ ] Test: 3 labels in a row, correct spacing

### **Phase 3: Command Buffer** (Zig + Rust)
- [ ] `ui/commands.zig` - Command buffer
- [ ] Update `rust/engine/src/lib.rs` with `mcore_render_commands`
- [ ] Refactor existing draw calls to use command buffer
- [ ] Test: Same visual result, but 1 FFI call per frame

### **Phase 4: Text Input** (Zig + Rust)
- [ ] `ui/widgets/text_input.zig` - Text input widget
- [ ] `rust/engine/src/text_input.rs` - Text editing state
- [ ] FFI: Text event handling
- [ ] Test: Can type, cursor moves, backspace works

### **Phase 5: Selection**
- [ ] Mouse selection in text_input.zig
- [ ] FFI: `mcore_text_hit_test`
- [ ] Render selection rects
- [ ] Test: Click-drag selects text

### **Phase 6: IME**
- [ ] Implement NSTextInputClient in metal_view.m
- [ ] FFI: IME callbacks
- [ ] Rust composition handling
- [ ] Test: Japanese input works

### **Phase 7: Accessibility**
- [ ] Add accesskit-c dependency
- [ ] `ui/a11y.zig` - Build AccessKit tree
- [ ] `rust/engine/src/a11y_bridge.rs` - Platform adapter
- [ ] Test: VoiceOver reads UI

---

## Code Size Estimates

**Phase 1-2 (Layout working):**
- Zig: ~800 LOC (id, focus, layout, flex)
- Rust: ~600 LOC (text measurement, rendering)

**Phase 4 (Text input working):**
- Zig: ~1500 LOC (+ widgets)
- Rust: ~1200 LOC (+ text editing)

**Phase 7 (Accessibility working):**
- Zig: ~2000 LOC (+ a11y tree building)
- Rust: ~1500 LOC (+ platform bridge)

**Total: ~3500 LOC for complete toolkit**

Compare:
- masonry_core: ~15,000 LOC
- Dear ImGui: ~20,000 LOC
- Clay: ~2,000 LOC (but no text or a11y)

We're building something in between - immediate-mode simplicity with text/a11y sophistication.

---

## Porting Guide: Borrowing from masonry_core

When implementing each phase, reference these masonry_core files:

### **Text Editing:**
File: `masonry_core/src/widgets/text_area.rs`

**Borrow these functions directly:**
- Lines 450-550: `insert_char()`, `delete_backward()`, `delete_forward()`
- Lines 600-700: Cursor movement (left, right, home, end, word boundaries)
- Lines 800-900: Selection rendering (selection_rects)
- Lines 1000-1100: Mouse hit testing

**Translation strategy:**
1. Copy the Rust function
2. Adapt to work with our `TextInputState` struct
3. Expose via FFI
4. Call from Zig

### **Text Rendering:**
File: `masonry_core/src/core/text.rs`

**Copy verbatim:**
- `render_text()` function (lines 50-150) - WE ALREADY DID THIS! ✅
- Underline/strikethrough rendering (if needed later)

### **IME:**
File: `masonry_winit/src/platform/macos.rs` (or similar)

**Borrow patterns:**
- NSTextInputClient implementation
- Composition range tracking
- Marked text handling

### **Accessibility:**
File: `masonry_core/src/app/render_root.rs`

**Borrow:**
- Lines with AccessKit TreeUpdate building
- How they map widgets to AccessKit roles

**But:** We build tree in Zig, not Rust!

---

## FAQ

**Q: Why not just use masonry?**

A: masonry is retained-mode with Rust widgets. We want immediate-mode with Zig control. Totally different architecture.

**Q: Why not just use Dear ImGui?**

A: Dear ImGui has poor text (bitmap fonts, no IME) and no accessibility. We want modern text + a11y.

**Q: Why not just use Clay?**

A: Clay has no text, no text editing, no accessibility. We're building Clay + proper text + a11y.

**Q: Can I customize text editing behavior?**

A: Somewhat. You can modify Rust text_input.rs since you own the code. But core Parley layout is opaque.

**Q: What about gamepad support, mobile, etc.?**

A: Out of scope initially. Focus on macOS desktop first. Architecture allows adding platforms later.

**Q: How hard is this really?**

A: Phase 1-3 (layout + rendering): **Easy** (2-3 weeks)
Phase 4 (text input): **Medium** (3-4 weeks, copy from masonry)
Phase 5-6 (selection + IME): **Hard** (4-6 weeks, platform-specific)
Phase 7 (accessibility): **Medium** (2-3 weeks, mostly wiring)

Total: **3-4 months part-time** for full toolkit.

Or: **Build only what you need!** Most apps don't need all features.

---

## Success Criteria

### **Phase 2 Done:**
✅ Can build UI like this:
```zig
ui.beginColumn(.{ .gap = 10 });
    ui.label("Hello");
    ui.label("World");
    ui.label("This wraps at 200px", .{ .wrap_width = 200 });
ui.endColumn();
```

### **Phase 4 Done:**
✅ Can build login form:
```zig
ui.label("Username:");
if (ui.textInput(&username_buf, &username_len, .{})) {
    // Text changed
}

ui.label("Password:");
_ = ui.textInput(&password_buf, &password_len, .{ .password = true });

if (ui.button("Log In")) {
    attemptLogin();
}
```

### **Phase 7 Done:**
✅ VoiceOver fully works
✅ Can navigate with keyboard only
✅ Text input is accessible

---

## Next Steps

1. **Upgrade to Zig 0.15** (use ../zarmot/flake.nix)
2. **Implement Phase 1** (IDs + Focus)
3. **Implement Phase 2** (Flexbox layout)
4. **Build a demo app** to validate

Then decide if you need Phase 4+ based on your actual app requirements.

---

## Repository of Truth

This file is the **single source of truth**. All decisions are made. No more analysis paralysis.

Ready to build! 🔨
