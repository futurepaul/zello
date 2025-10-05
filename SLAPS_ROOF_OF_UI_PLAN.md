# SLAPS_ROOF_OF_UI_PLAN.md

*"You can fit so much UI in this thing!"*

**A no-compromises immediate-mode Zig UI toolkit with modern rendering**

---

## Vision

Build a **Dear ImGui-style immediate-mode UI toolkit** in Zig that rivals native quality:

- **Zig-first immediate mode** - simple frame loop, no hidden state in Rust
- **Stable IDs** - track focus, accessibility, and animations across frames
- **Flexbox layout** - Clay-inspired containers, familiar and powerful
- **Best-in-class text** - Parley for layout, proper IME, text selection
- **Modern rendering** - Vello GPU-accelerated vector graphics
- **Full accessibility** - AccessKit integration from day one
- **No compromises** - learn from masonry_core, implement exactly what we need

This is **not** a port of masonry - it's a ground-up immediate-mode toolkit that borrows masonry's hard-won knowledge about text and accessibility.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Zig Application Layer                     │
│  Immediate-mode API: ui.label(), ui.button(), ui.input()   │
│  Layout: Flexbox containers, stable ID management          │
└──────────────────────┬──────────────────────────────────────┘
                       │ C ABI (minimal, stable)
┌──────────────────────▼──────────────────────────────────────┐
│                    Rust Rendering Core                       │
│  • ID-based state retention (focus, cursor, a11y tree)     │
│  • Parley: Text layout, shaping, line breaking             │
│  • Vello: GPU vector rendering, text glyphs                 │
│  • AccessKit: Accessibility tree management                 │
│  • IME: Platform text input bridging                        │
└─────────────────────────────────────────────────────────────┘
```

**Key Principle:** Zig owns the UI tree each frame. Rust retains only:
- Focus state (by ID)
- Text editing state (cursor position, selection, by ID)
- Accessibility tree (by ID)
- Layout cache (for perf, invalidated by ID changes)

---

## Phase Plan

### **Phase 0: Foundation** *(DONE - Current State)*

- ✅ Zig window + wgpu surface
- ✅ Vello rendering (shapes + text)
- ✅ Parley text layout
- ✅ Immediate-mode API (`mcore_rect_rounded`, `mcore_text_draw`)

**Current state:** Basic shapes and text rendering working!

---

### **Phase 1: Layout Engine + Stable IDs** *(2-3 weeks)*

**Goal:** Flexbox layout engine in Zig with stable ID system

#### Deliverables

**1.1 - Stable ID System (Week 1)**

Zig side:
```zig
const UI = struct {
    id_stack: std.ArrayList(u64),

    fn pushID(self: *UI, label: []const u8) void {
        const id = hashString(label);  // FNV-1a or similar
        self.id_stack.append(id);
    }

    fn popID(self: *UI) void {
        _ = self.id_stack.pop();
    }

    fn getCurrentID(self: *UI) u64 {
        return self.id_stack.items[self.id_stack.items.len - 1];
    }
};

// Usage:
ui.pushID("my_button");
ui.button("Click me");  // Internally uses getCurrentID()
ui.popID();

// Or automatic:
ui.label("Hello##auto_id_1");  // "##" separator like Dear ImGui
```

Rust side:
```rust
struct IdState {
    focused_id: Option<u64>,
    hover_id: Option<u64>,
    active_id: Option<u64>,
    text_states: HashMap<u64, TextInputState>,
}

struct TextInputState {
    cursor: usize,
    selection: Option<(usize, usize)>,
    composition: Option<ImeComposition>,
}
```

**Checkpoint:** Can track which button is hovered by ID across frames

---

**1.2 - Flexbox Layout (Week 2-3)**

Zig immediate-mode containers:
```zig
// Row container
ui.beginRow(.{ .gap = 10, .align = .Center });
    ui.label("Left");
    ui.spacer(.flex = 1.0);  // Flexible space
    ui.label("Right");
ui.endRow();

// Column with sizing
ui.beginColumn(.{ .width = 300, .height = 200 });
    ui.label("Top");
    ui.button("Middle");
    ui.label("Bottom");
ui.endColumn();
```

C API additions:
```c
void mcore_begin_container(mcore_context_t* ctx, mcore_container_desc_t* desc);
void mcore_end_container(mcore_context_t* ctx);
void mcore_reserve_space(mcore_context_t* ctx, float w, float h, mcore_rect_t* out);
```

Rust layout engine (minimal flexbox):
```rust
enum LayoutNode {
    Container { axis: Axis, children: Vec<LayoutNode>, gap: f32 },
    Item { id: u64, constraints: BoxConstraints },
    Spacer { flex: f32 },
}

struct LayoutEngine {
    stack: Vec<LayoutNode>,
    results: HashMap<u64, Rect>,  // ID -> final position
}

fn compute_layout(root: &LayoutNode, available: Size) -> HashMap<u64, Rect> {
    // Simple flexbox:
    // 1. Measure all non-flex children
    // 2. Distribute remaining space to flex children
    // 3. Position children along main axis
    // 4. Align on cross axis
}
```

**Checkpoint:** Can layout a column of labels with correct spacing, wrap_width honored

---

### **Phase 2: Text Measurement Integration** *(1 week)*

**Goal:** Clay layout uses real Parley text measurements

#### Approach

When Zig calls `ui.label("text")`:
1. Zig queries text size: `mcore_text_measure("text", font_size) -> (w, h)`
2. Zig reserves space: `mcore_reserve_space(w, h) -> (x, y)`
3. Zig draws text: `mcore_text_draw("text", x, y, color)`

Parley integration:
```rust
fn measure_text(text: &str, font_size: f32, max_width: Option<f32>) -> (f32, f32) {
    let mut builder = layout_cx.ranged_builder(&mut font_cx, text, scale);
    builder.push_default(StyleProperty::FontSize(font_size));
    let mut layout = builder.build(text);
    if let Some(w) = max_width {
        layout.break_all_lines(Some(w));
    }
    (layout.width(), layout.height())
}
```

**Checkpoint:** Multi-line text wraps correctly inside Clay containers

---

### **Phase 3: Focus + Keyboard Navigation** *(2 weeks)*

**Goal:** Tab navigation, focus ring, keyboard events

#### Focus System

```zig
// Zig declares focusable items
if (ui.button("Save##save_btn")) {
    // Button was clicked
}

// Internally:
const id = ui.getCurrentID();
const is_focused = ui.isFocused(id);
const is_hovered = ui.isHovered(id);
if (is_focused) {
    // Draw focus ring
    c.mcore_draw_focus_ring(ctx, &bounds);
}
```

Rust focus manager:
```rust
struct FocusManager {
    focused_id: Option<u64>,
    focusable_ids: Vec<u64>,  // Built each frame

    fn handle_tab(&mut self) {
        // Find next focusable ID
        if let Some(current_idx) = self.find_focused_index() {
            let next = (current_idx + 1) % self.focusable_ids.len();
            self.focused_id = Some(self.focusable_ids[next]);
        }
    }
}
```

Keyboard events from Zig → Rust:
```c
void mcore_key_event(mcore_context_t* ctx, mcore_key_event_t* event);
```

**Checkpoint:** Can tab between buttons, focus ring renders, Enter/Space activates

---

### **Phase 4: Text Input** *(3-4 weeks)*

**Goal:** Single-line and multi-line text input with IME

This is the HARD part. Break it down:

#### 4.1 - Basic Text Input (Week 1-2)

```zig
var text_buffer: [256]u8 = undefined;
var text_len: usize = 0;

ui.pushID("username");
const changed = ui.textInput(&text_buffer, &text_len, .{
    .placeholder = "Enter name...",
    .width = 200,
});
ui.popID();

if (changed) {
    std.debug.print("Text: {s}\n", .{text_buffer[0..text_len]});
}
```

Rust text state:
```rust
struct TextInputState {
    cursor: usize,           // Byte position in UTF-8
    selection: Option<Range<usize>>,
    content: String,         // Rust owns the authoritative text
}

fn handle_text_event(id: u64, event: TextEvent) {
    match event {
        TextEvent::KeyPress(key) => {
            // Insert character at cursor
            // Handle backspace, delete, arrows
        }
        TextEvent::Selection(range) => {
            state.selection = Some(range);
        }
    }
}
```

**Checkpoint:** Can type into a text field, cursor moves, backspace works

---

#### 4.2 - Text Selection (Week 3)

Mouse text selection:
```rust
fn hit_test_text(layout: &Layout, x: f32, y: f32) -> Option<usize> {
    // Use Parley's hit testing to find byte position
    // This is complex - masonry has it in text_area.rs
}

fn handle_mouse_drag(id: u64, start_x: f32, start_y: f32, end_x: f32, end_y: f32) {
    let start_pos = hit_test_text(&layout, start_x, start_y);
    let end_pos = hit_test_text(&layout, end_x, end_y);
    state.selection = Some(start_pos..end_pos);
}
```

Render selection:
```rust
// Draw blue rectangles behind selected text ranges
for (line_idx, line) in layout.lines().enumerate() {
    if line_range.intersects(selection) {
        let selection_rects = compute_selection_rects(line, selection);
        for rect in selection_rects {
            scene.fill(..., SELECTION_COLOR, &rect);
        }
    }
}
```

Borrow heavily from: `masonry_core/src/widgets/text_area.rs` lines 800-1000 (selection rendering)

**Checkpoint:** Can select text with mouse, selected text highlights

---

#### 4.3 - IME Support (Week 4)

This is platform-specific. For macOS:

Objective-C side (metal_view.m):
```objc
@interface MVMetalView : NSView <NSTextInputClient>
@property(nonatomic) NSRange markedTextRange;
@property(nonatomic, strong) NSAttributedString *markedText;
@end

- (void)insertText:(id)string {
    // Committed text
    mv_ime_commit([string UTF8String]);
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange {
    // Composition preview
    self.markedText = string;
    mv_ime_update([string UTF8String], selectedRange.location);
}
```

C API:
```c
typedef struct {
    const char* composing_text;
    int cursor_offset;
    float caret_x, caret_y;  // For IME popup positioning
} mcore_ime_state_t;

void mcore_ime_update(mcore_context_t* ctx, mcore_ime_state_t* state);
void mcore_ime_commit(mcore_context_t* ctx, const char* text);
```

Rust IME handling:
```rust
struct ImeState {
    composing: Option<String>,
    composition_range: Option<Range<usize>>,
}

// Render composition underline
if let Some(comp) = &ime_state.composing {
    draw_underline(comp_range, COMPOSITION_UNDERLINE_STYLE);
}
```

Reference: masonry_core IME is in the platform backends, check masonry_winit for patterns

**Checkpoint:** Can type Japanese/Chinese with IME, composition shows with underline

---

### **Phase 5: Accessibility** *(2-3 weeks)*

**Goal:** Screen reader support via AccessKit

#### 5.1 - AccessKit Tree Building (Week 1)

Build tree from IDs:
```rust
use accesskit::{Node, NodeId, Role, Tree, TreeUpdate};

fn build_accessibility_tree(ui_items: &[UiItem]) -> TreeUpdate {
    let mut nodes = vec![];

    for item in ui_items {
        let node = match item.kind {
            UiItemKind::Label(text) => {
                Node::new(NodeId(item.id), Role::StaticText)
                    .with_name(text)
            }
            UiItemKind::Button(text) => {
                Node::new(NodeId(item.id), Role::Button)
                    .with_name(text)
                    .with_default_action_verb(DefaultActionVerb::Click)
            }
            UiItemKind::TextInput => {
                Node::new(NodeId(item.id), Role::TextInput)
                    .with_value(state.content)
                    .with_text_selection(state.selection)
            }
        };
        nodes.push(node);
    }

    TreeUpdate { nodes, tree: Some(Tree::new(NodeId(0))) }
}
```

**Checkpoint:** VoiceOver announces "Hello, Zig/Rust! Static text"

---

#### 5.2 - Platform Bridges (Week 2-3)

macOS Accessibility:
```objc
// In MVMetalView, implement NSAccessibility protocol
- (id)accessibilityFocusedUIElement {
    // Query Rust for focused ID, return appropriate element
}

// Expose AccessKit tree to AppKit
@property(nonatomic) AXUIElementRef accessibilityElement;
```

This is complex - study masonry_core's platform adapters:
- `masonry_core/src/app/platform` (platform abstractions)
- Look for AccessKit bridges in full masonry repo

**Checkpoint:** VoiceOver can navigate between buttons, announces focus changes

---

### **Phase 6: Advanced Text Features** *(3-4 weeks)*

Once basic text input works, add:

**6.1 - Text Selection Editing**
- Copy/paste via system clipboard
- Select all, cut, undo/redo
- Keyboard selection (Shift+arrows)

**6.2 - Rich Text Rendering**
- Borrow masonry's `render_text()` completely
- Underlines, strikethrough
- Multiple text styles per line

**6.3 - Text Area (Multi-line)**
- Scrolling for overflow
- Line numbers (optional)
- Tab handling

Reference: `masonry_core/src/widgets/text_area.rs` - this is 2000+ lines but you can extract pieces

---

## Detailed Milestones

### **M0-M3: Foundation** ✅ DONE

We already have Vello + Parley working!

---

### **M4: Stable IDs + Layout Begin** *(Week 1-2)*

**Tasks:**
1. **ID System in Zig**
   - Hash-based ID generation
   - ID stack (push/pop for nested contexts)
   - String labels with "##id" separator

2. **C API for IDs**
   ```c
   void mcore_push_id(mcore_context_t* ctx, uint64_t id);
   void mcore_pop_id(mcore_context_t* ctx);
   uint64_t mcore_hash_string(const char* str);
   ```

3. **Rust ID tracking**
   ```rust
   struct PerFrameState {
       current_id_stack: Vec<u64>,
       encountered_ids: HashSet<u64>,
   }

   struct RetainedState {
       focused_id: Option<u64>,
       previous_ids: HashSet<u64>,  // For diffing
   }
   ```

**Checkpoint:** Can generate stable IDs, track them across frames

---

### **M5: Basic Flexbox** *(Week 3-4)*

**Container API:**
```zig
ui.beginRow(.{ .gap = 10, .padding = 5 });
ui.endRow();

ui.beginColumn(.{ .gap = 10, .width = 200 });
ui.endColumn();
```

**Layout computation (Rust):**
```rust
struct FlexContainer {
    axis: Axis,              // Row or Column
    gap: f32,
    padding: Edges,
    children: Vec<FlexChild>,
}

struct FlexChild {
    id: u64,
    size: Size,              // From measure
    flex: f32,               // 0 = fixed, >0 = proportional
}

fn layout_flex(container: &FlexContainer, available: Size) -> Vec<(u64, Rect)> {
    // 1. Measure fixed children
    // 2. Calculate remaining space
    // 3. Distribute to flex children
    // 4. Position all children with gap
    // Return: (id, final_rect) for each child
}
```

**Checkpoint:** Can layout 3 buttons in a row with correct spacing

---

### **M6: Text Measurement + Layout Integration** *(Week 5)*

Connect Parley to layout:
```c
typedef struct {
    const char* text;
    float font_size;
    float max_width;  // For wrapping
} mcore_text_measure_t;

typedef struct {
    float width;
    float height;
    int line_count;
} mcore_text_size_t;

void mcore_measure_text(mcore_context_t* ctx, mcore_text_measure_t* req, mcore_text_size_t* out);
```

Zig usage:
```zig
const text = "Long text that wraps...";
var size: c.mcore_text_size_t = undefined;
c.mcore_measure_text(ctx, &.{
    .text = text,
    .font_size = 16,
    .max_width = 200,
}, &size);

// Reserve layout space
var bounds: c.mcore_rect_t = undefined;
c.mcore_reserve_space(ctx, size.width, size.height, &bounds);

// Draw text at reserved position
c.mcore_text_draw(ctx, text, bounds.x, bounds.y, color);
```

**Checkpoint:** Text in containers wraps and sizes correctly

---

### **M7: Focus Management** *(Week 6-7)*

**Focusable items:**
```zig
const focused = ui.isFocused(id);
const clicked = ui.button("Save");

if (clicked) {
    ui.setFocus(id);  // Explicitly grab focus
}

// Automatic tab order (order items declared in frame)
```

**Rust focus manager:**
```rust
impl FocusManager {
    fn handle_tab(&mut self, shift: bool) {
        // Cycle through focusable_ids (collected this frame)
    }

    fn handle_mouse_down(&mut self, x: f32, y: f32) -> Option<u64> {
        // Hit test layout results, return clicked ID
        // Set focused_id
    }
}
```

**Focus ring rendering:**
```rust
if Some(id) == state.focused_id {
    let ring_rect = layout_rects[&id].inflate(2.0);
    scene.stroke(FOCUS_RING_STROKE, FOCUS_RING_COLOR, &ring_rect);
}
```

**Checkpoint:** Tab moves focus, Enter activates focused button, focus ring renders

---

### **M8: Text Input Widget** *(Week 8-10)*

**Single-line input:**
```zig
var name_buf: [64]u8 = undefined;
var name_len: usize = 0;

if (ui.textInput("##name", &name_buf, &name_len, .{ .placeholder = "Name" })) {
    std.debug.print("Changed: {s}\n", .{name_buf[0..name_len]});
}
```

**Rust text input state:**
```rust
struct TextInputState {
    content: String,
    cursor: usize,
    selection: Option<Range<usize>>,
    is_composing: bool,
    composition: Option<String>,
}

fn handle_key_press(state: &mut TextInputState, key: KeyEvent) {
    match key {
        Key::Char(c) => {
            if let Some(sel) = state.selection {
                state.content.drain(sel);
            }
            state.content.insert(state.cursor, c);
            state.cursor += c.len_utf8();
        }
        Key::Backspace => {
            // Handle grapheme cluster deletion
        }
        Key::Left => state.cursor = previous_grapheme_boundary(state.cursor),
        Key::Right => state.cursor = next_grapheme_boundary(state.cursor),
        // ... etc
    }
}
```

**Cursor rendering:**
```rust
// Calculate cursor X position from Parley layout
let cursor_offset = layout.cursor_position(state.cursor);
let cursor_line = kurbo::Line::new(
    (cursor_offset.x, cursor_offset.y),
    (cursor_offset.x, cursor_offset.y + font_size),
);
scene.stroke(CURSOR_STROKE, CURSOR_COLOR, &cursor_line);
```

**Borrow from masonry:**
- `masonry_core/src/widgets/text_area.rs` - lines 500-800 (editing logic)
- `masonry_core/src/core/text.rs` - cursor positioning helpers

**Checkpoint:** Can type, move cursor with arrows, select with Shift+arrows

---

### **M9: IME Integration** *(Week 11-12)*

**Platform IME bridge:**

Objective-C NSTextInputClient:
```objc
@implementation MVMetalView

- (void)insertText:(id)string replacementRange:(NSRange)range {
    const char* text = [string UTF8String];
    mcore_ime_commit(g_ctx, text);
}

- (void)setMarkedText:(id)string
         selectedRange:(NSRange)selectedRange
      replacementRange:(NSRange)replacementRange {
    const char* marked = [string UTF8String];
    mcore_ime_set_composition(g_ctx, marked, selectedRange.location);
}

- (NSRect)firstRectForCharacterRange:(NSRange)range
                          actualRange:(NSRangePointer)actualRange {
    // Get cursor position from Rust for IME popup placement
    mcore_rect_t cursor_rect = mcore_get_cursor_rect(g_ctx);
    return NSMakeRect(cursor_rect.x, cursor_rect.y, 1, cursor_rect.h);
}

@end
```

**Checkpoint:** IME works for Japanese/Chinese, composition underline shows

---

### **M10: Accessibility Integration** *(Week 13-15)*

**AccessKit tree from UI items:**

Each frame, build AccessKit tree from declared UI:
```rust
fn build_a11y_tree(ui_frame: &UiFrame) -> TreeUpdate {
    let mut builder = TreeUpdateBuilder::new();

    for item in &ui_frame.items {
        let mut node = NodeBuilder::new(item.id, item.role());

        match &item.kind {
            UiItem::Label(text) => {
                node.set_name(text);
            }
            UiItem::Button { text, .. } => {
                node.set_name(text);
                node.add_action(Action::Click);
                if item.id == state.focused_id {
                    node.set_focused();
                }
            }
            UiItem::TextInput { state, .. } => {
                node.set_value(&state.content);
                if let Some(sel) = state.selection {
                    node.set_text_selection(TextSelection {
                        anchor: sel.start,
                        focus: sel.end,
                    });
                }
            }
        }

        node.set_bounds(item.bounds);
        builder.add_node(node.build());
    }

    builder.build()
}
```

**macOS bridge:**
```objc
#import <AccessKit/AccessKit.h>

@interface MVMetalView ()
@property(nonatomic) AKAdapter *accessibilityAdapter;
@end

- (void)setupAccessibility {
    self.accessibilityAdapter = [[AKAdapter alloc]
        initWithView:self
        initialTree:initialTree];
}

// Update tree each frame
[self.accessibilityAdapter updateTree:tree_update];
```

Reference:
- AccessKit macOS adapter docs
- masonry_core's AccessKit usage in core/widget.rs

**Checkpoint:** VoiceOver reads text, announces button presses, text input is editable

---

## Detailed Implementation Guides

### **Text Selection Algorithm** (from masonry_core)

```rust
// Hit test to find cursor position from mouse click
fn hit_test_point(layout: &Layout, point: (f32, f32)) -> usize {
    for (line_idx, line) in layout.lines().enumerate() {
        if point.1 >= line.offset() && point.1 < line.offset() + line.height() {
            // Point is on this line
            let mut x = 0.0;
            for cluster in line.clusters() {
                if point.0 < x + cluster.advance() / 2.0 {
                    return cluster.byte_offset();
                }
                x += cluster.advance();
            }
            return line.end_byte_offset();
        }
    }
    layout.len()  // Past end
}

// Render selection rectangles
fn selection_rects(layout: &Layout, selection: Range<usize>) -> Vec<Rect> {
    let mut rects = vec![];

    for line in layout.lines() {
        let line_range = line.start()..line.end();
        if let Some(intersection) = range_intersection(line_range, selection) {
            // Calculate X positions for selection start/end on this line
            let start_x = layout.cursor_position(intersection.start).x;
            let end_x = layout.cursor_position(intersection.end).x;

            rects.push(Rect::new(
                start_x,
                line.offset(),
                end_x,
                line.offset() + line.height(),
            ));
        }
    }

    rects
}
```

masonry reference: `text_area.rs` lines 1200-1400

---

### **Flexbox Layout Algorithm**

Simplified from CSS Flexbox spec:

```rust
fn layout_flex_axis(
    children: &[FlexChild],
    available_size: f32,
    gap: f32,
) -> Vec<f32> {
    // 1. Measure fixed children
    let mut used = 0.0;
    let mut flex_total = 0.0;

    for child in children {
        if child.flex == 0.0 {
            used += child.measure().main_axis_size;
        } else {
            flex_total += child.flex;
        }
    }

    used += gap * (children.len() - 1) as f32;

    // 2. Distribute remaining to flex children
    let remaining = (available_size - used).max(0.0);
    let flex_unit = if flex_total > 0.0 { remaining / flex_total } else { 0.0 };

    // 3. Calculate positions
    let mut pos = 0.0;
    let mut positions = vec![];

    for child in children {
        positions.push(pos);
        let size = if child.flex > 0.0 {
            child.flex * flex_unit
        } else {
            child.measure().main_axis_size
        };
        pos += size + gap;
    }

    positions
}
```

Clay reference: `clay.h` layout logic
CSS Flexbox spec: https://www.w3.org/TR/css-flexbox-1/

---

## C API Evolution

### Current (M3):
```c
void mcore_rect_rounded(mcore_context_t*, const mcore_rounded_rect_t*);
void mcore_text_draw(mcore_context_t*, const mcore_text_req_t*, float x, float y, mcore_rgba_t);
```

### Phase 1 (IDs + Layout):
```c
// IDs
void mcore_push_id(mcore_context_t*, uint64_t id);
void mcore_pop_id(mcore_context_t*);

// Layout
void mcore_begin_container(mcore_context_t*, mcore_container_t* desc);
void mcore_end_container(mcore_context_t*);
void mcore_reserve_space(mcore_context_t*, float w, float h, mcore_rect_t* out);
```

### Phase 3 (Focus):
```c
bool mcore_is_focused(mcore_context_t*, uint64_t id);
bool mcore_is_hovered(mcore_context_t*, uint64_t id);
void mcore_set_focus(mcore_context_t*, uint64_t id);
```

### Phase 4 (Text Input):
```c
typedef struct {
    const char* content;      // Current text
    int cursor;               // Byte offset
    int selection_start;
    int selection_end;
    bool changed;
} mcore_text_input_state_t;

void mcore_text_input(mcore_context_t*, uint64_t id, mcore_text_input_state_t* state);
```

---

## Learning Resources

**Borrow code/patterns from:**

1. **masonry_core/src/core/text.rs**
   - `render_text()` - glyph rendering
   - Text measurement helpers

2. **masonry_core/src/widgets/text_area.rs**
   - Lines 500-800: Keyboard handling
   - Lines 800-1200: Selection rendering
   - Lines 1200-1500: Mouse hit testing
   - Lines 1500-1800: IME composition

3. **Dear ImGui** (for immediate-mode patterns)
   - `imgui.cpp` InputText() - stable ID management
   - Focus handling, tab navigation

4. **Clay**
   - `clay.h` - flexbox layout algorithm
   - Memory management patterns

5. **AccessKit examples**
   - https://github.com/AccessKit/accesskit
   - Platform adapter examples

---

## Key Design Decisions

### **1. Who owns the text?**

**Decision: Rust owns authoritative text content**

Why:
- UTF-8 safety (Rust String)
- Selection is in byte offsets
- IME composition needs proper string manipulation

Zig owns the "intent" (edit events), Rust owns the "state" (content + cursor)

```zig
// Zig passes buffer for display
var display_buf: [256]u8 = undefined;
const text_len = c.mcore_text_input_get(ctx, id, &display_buf);
const text = display_buf[0..text_len];

// Render it
ui.drawTextAt(text, x, y);
```

---

### **2. Layout: Pull or Push?**

**Decision: Hybrid**

Pull (measure first):
```zig
// Works for simple cases
const text_size = ui.measureText("Hello");
ui.drawRect(x, y, text_size.w, text_size.h);
ui.drawText("Hello", x, y);
```

Push (auto-layout):
```zig
// Better for containers
ui.beginRow(.{ .gap = 10 });
    ui.button("OK");     // Size measured automatically
    ui.button("Cancel"); // Positioned by container
ui.endRow();
```

Rust tracks both:
- Manual positions (from `mcore_text_draw` x, y)
- Container-managed positions (from `mcore_reserve_space`)

---

### **3. How much to cache?**

**Decision: Cache by ID, invalidate on content change**

```rust
struct LayoutCache {
    text_layouts: HashMap<(u64, String), Layout<Brush>>,  // (ID, content) -> layout

    fn get_or_layout(&mut self, id: u64, text: &str, font_size: f32) -> &Layout<Brush> {
        self.text_layouts.entry((id, text.to_string()))
            .or_insert_with(|| {
                // Expensive: shape text with Parley
                layout_text(text, font_size)
            })
    }
}
```

Invalidation:
- If ID disappears between frames, remove from cache
- If same ID but different text hash, re-layout

---

## Testing Strategy

### Phase 1-2: Layout Tests
```zig
test "flex row distributes space" {
    // Create 3 items: fixed 100px, flex 1.0, fixed 50px
    // In 400px container with 10px gap
    // Expect: 100, 230, 50 with correct positions
}

test "text wrapping" {
    // Measure "Long text that should wrap" at width 100
    // Expect: 2+ lines, correct total height
}
```

### Phase 3-4: Focus Tests
```zig
test "tab cycles focus" {
    // Create 3 buttons
    // Simulate Tab key 3 times
    // Expect: focus cycles through all, wraps to first
}

test "text input cursor movement" {
    // Type "Hello", press Left 2 times, type "X"
    // Expect: "HelXlo"
}
```

### Phase 5: Accessibility Tests
```rust
test "accesskit tree for button" {
    // Create button with ID 42
    // Build tree
    // Assert: Node 42 has Role::Button, name="Click", has Click action
}
```

---

## Performance Targets

- **Layout**: < 1ms for 100 items (simple caching)
- **Text shaping**: < 5ms for 1000 chars (Parley is fast, cache layouts)
- **Rendering**: 60fps at 1920x1080 (Vello is GPU-accelerated)
- **Frame budget**: 16ms total (layout + render)

If you hit perf issues:
1. Cache Parley layouts by (ID, text_hash)
2. Only re-layout containers that changed
3. Use Vello's scene cloning for static content

---

## What We're NOT Building (Initially)

To keep scope manageable:

- ❌ Scrolling (can add later)
- ❌ Complex widgets (sliders, color pickers) - just primitives
- ❌ Animations (CSS-style) - just immediate value changes
- ❌ Themes / styling system - just hardcoded colors/sizes
- ❌ Bitmap images (Vello supports it but not priority)
- ❌ Custom shaders - Vello is enough

**Philosophy:** Start minimal. Add features when your app needs them.

---

## Migration Path (Practical)

### Week 1-4: Get Layout Working
- You can build simple UIs (buttons, labels in columns/rows)
- No text input yet - just display and buttons

### Week 5-8: Add Focus + Basic Input
- Keyboard navigation works
- Simple text input (no IME)
- Good enough for many apps!

### Week 9-12: Production Polish
- IME for international users
- Text selection for copy/paste
- Accessibility for compliance

### Month 4+: Features On Demand
- Build what your actual app needs
- Don't implement features speculatively

---

## Risk Mitigation

### **Risk: Text editing is hard**

**Mitigation:**
- Copy masonry_core's `text_area.rs` almost verbatim into your Rust
- Just expose it via C API
- Don't reimplement from scratch - adapt what works

### **Risk: AccessKit platform bridges are complex**

**Mitigation:**
- macOS: Use AccessKit's official macOS adapter
- Don't write platform code yourself
- Just build the tree, let AccessKit handle OS integration

### **Risk: IME is platform-specific**

**Mitigation:**
- macOS first, abstract platform later
- Objective-C bridge in `metal_view.m` already exists
- Just add NSTextInputClient methods incrementally

### **Risk: Scope creep**

**Mitigation:**
- Build features ONLY when you need them for your app
- Start with: layout + labels + buttons
- Add text input when you actually need a search bar
- Add accessibility when you need to ship

---

## Success Metrics

**Phase 1-2 Success:**
✅ Can build a calculator UI with layout and buttons
✅ Text measures and wraps correctly
✅ Code is ~500 lines of Zig, ~1000 lines of Rust

**Phase 3-4 Success:**
✅ Can tab between buttons and text inputs
✅ Can type, edit, select text
✅ IME works for at least one language (Japanese)

**Phase 5 Success:**
✅ VoiceOver fully works
✅ Can navigate entire UI with keyboard
✅ Text input is accessible

**Final Success:**
✅ You have a clean, immediate-mode UI toolkit
✅ It's smaller and simpler than masonry
✅ It handles text/a11y as well as masonry
✅ You understand every line of code

---

## Current Status

**Completed:**
- ✅ M0-M3: Rendering foundation (Vello + Parley working)
- ✅ Immediate-mode API (`mcore_text_draw`, `mcore_rect_rounded`)
- ✅ Text rendering with proper glyph positioning
- ✅ Zig → C ABI → Rust → Vello pipeline

**Next Steps:**
1. Upgrade to Zig 0.15 (for better Clay compatibility if needed)
2. Implement stable ID system (M4)
3. Build flexbox layout engine (M5)
4. Integrate text measurement (M6)

**Architecture Decision Made:**
- ✅ **Pure immediate-mode** (no masonry widgets)
- ✅ **Stable IDs** for focus/accessibility
- ✅ **Learn from masonry** (don't use it directly)
- ✅ **Zig controls UI** (Rust is rendering backend)

This is the right foundation for a no-compromises toolkit! 🚀

---

## Open Questions

1. **Layout: Should we use Clay as-is or reimplement flexbox?**
   - Clay is C, Zig-compatible, well-tested
   - But it's another dependency vs pure Zig flexbox (300 LOC?)
   - **Recommendation:** Start with pure Zig, borrow Clay's algorithm

2. **Text measurement: Synchronous or async?**
   - Parley shaping can be expensive (5ms for long text)
   - Could cache aggressively or compute async
   - **Recommendation:** Cache by (ID, text_hash), re-shape only when changed

3. **How to handle dynamic text in labels?**
   ```zig
   // This text changes every frame - cache miss every time!
   ui.label(std.fmt.allocPrint("FPS: {d}", .{fps}));
   ```
   - **Solution:** Separate static vs dynamic text APIs
   - `ui.labelStatic("Fixed")` - caches layout
   - `ui.labelDynamic(fps_str)` - re-layouts each frame, but caller can cache string

4. **Should Zig or Rust own layout computation?**
   - Zig: Simpler API, but more C FFI calls
   - Rust: Fewer FFI calls, but less Zig control
   - **Recommendation:** Rust does heavy compute (flexbox), Zig controls structure

---

## Comparison to Alternatives

| Feature | This Toolkit | masonry | Dear ImGui | Clay |
|---------|-------------|---------|-----------|------|
| Language | Zig | Rust | C++ | C |
| Mode | Immediate | Retained | Immediate | Immediate |
| Layout | Flexbox (custom) | Flexbox | Manual | Flexbox |
| Text | Parley | Parley | STB TrueType | External |
| Rendering | Vello (GPU) | Vello (GPU) | CPU/GPU | External |
| Accessibility | AccessKit | AccessKit | None | None |
| IME | Full | Full | Partial | None |
| Zig-first | ✅ | ❌ | ❌ | ❌ |
| Learning curve | Medium | High | Low | Low |

**Unique value:** Only immediate-mode toolkit with Parley text AND AccessKit!

---

## Long-term Vision

**Year 1:** Core toolkit
- Layout, text, focus, input, accessibility
- Good enough to build real apps

**Year 2:** Polish
- Animations, transitions
- More widgets (sliders, dropdowns)
- Performance optimization

**Year 3:** Ecosystem
- Documentation, examples
- Community contributions
- Backends for Windows/Linux

But start small: **build only what you need for YOUR app!**

---

*"This immediate-mode UI toolkit can fit so many features!"* - *slaps roof enthusiastically* 🚗

---

## Next Session TODO

1. Upgrade to Zig 0.15 (use ../zarmot/flake.nix)
2. Implement ID system (push/pop/hash)
3. Add `mcore_push_id`, `mcore_pop_id` to C API
4. Start basic flex row/column in Zig
5. Test: 3 buttons in a row with correct spacing

Let's build this! 🔨
