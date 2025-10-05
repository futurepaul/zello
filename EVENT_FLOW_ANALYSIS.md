# Event Flow Analysis

**Exposing the ownership conflicts**

---

## The Core Tension: Events + Text Input

Let me trace what happens when user types "H" into a text field:

### Flow 1: Zig Owns Events, Rust Owns Text ⚠️ CONFLICT

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. macOS delivers keyDown: 'H'                                  │
└────────────┬────────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────────┐
│ 2. Zig event handler                                            │
│    - Receives KeyEvent { char: 'H', mods: none }                │
│    - Which widget should get it?                                │
│    - Need to know focused_id... but that's in Rust! ────────┐   │
└─────────────────────────────────────────────────────────────│───┘
                                                              │
                                                              │ FFI call
                                                              │
┌─────────────────────────────────────────────────────────────▼───┐
│ 3. Rust: mcore_get_focused_id() -> returns ID 42                │
└─────────────────────────────────────────────┬───────────────────┘
                                              │ Return
┌─────────────────────────────────────────────▼───────────────────┐
│ 4. Zig: OK, focused widget is text_input #42                    │
│    - Should insert 'H'... but content is in Rust! ──────────┐   │
└─────────────────────────────────────────────────────────────│───┘
                                                              │
                                                              │ FFI call
┌─────────────────────────────────────────────────────────────▼───┐
│ 5. Rust: mcore_text_input_insert_char(42, 'H')                  │
│    - Updates String                                             │
│    - Advances cursor                                            │
│    - Invalidates layout cache                                   │
└─────────────────────────────────────────────┬───────────────────┘
                                              │ Return
┌─────────────────────────────────────────────▼───────────────────┐
│ 6. Zig: OK, text was inserted                                   │
│    - Need to redraw... what's the new text content? ────────┐   │
└─────────────────────────────────────────────────────────────│───┘
                                                              │
                                                              │ FFI call
┌─────────────────────────────────────────────────────────────▼───┐
│ 7. Rust: mcore_text_input_get(42) -> "Hello"                    │
└─────────────────────────────────────────────┬───────────────────┘
                                              │ Return
┌─────────────────────────────────────────────▼───────────────────┐
│ 8. Zig: Render text "Hello" at widget position                  │
└─────────────────────────────────────────────────────────────────┘
```

**Result:** 3 FFI roundtrips per keystroke! 😱
- Get focused ID
- Insert character
- Get updated text

This is the "back-and-forth" you're worried about!

---

### Flow 2: Rust Owns Events + Text ✅ CLEAN

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. macOS delivers keyDown: 'H'                                  │
└────────────┬────────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────────┐
│ 2. Zig: Just forward to Rust                                    │
│    c.mcore_key_event(ctx, &{ .char = 'H', .mods = none });      │
└─────────────────────────────────────────────┬───────────────────┘
                                              │ FFI call (one!)
┌─────────────────────────────────────────────▼───────────────────┐
│ 3. Rust: Full event processing                                  │
│    - Check focused_id (stored in Rust)                          │
│    - Is it a text input? Yes, ID 42                             │
│    - Insert 'H' into text_states[42].content                    │
│    - Advance cursor                                             │
│    - Mark needs_redraw = true                                   │
└─────────────────────────────────────────────────────────────────┘
             │
             │ (Later, in render phase)
             │
┌────────────▼────────────────────────────────────────────────────┐
│ 4. Zig: Build UI for frame                                      │
│    const text = c.mcore_text_input_get(ctx, 42);  // Get once   │
│    c.mcore_text_draw(ctx, text, x, y, white);                   │
└─────────────────────────────────────────────────────────────────┘
```

**Result:** 1 FFI call for event, 1 for text retrieval. Clean!

**But:** Zig doesn't "see" the event processing. Rust is making decisions.

---

### Flow 3: Zig Owns Events, BUT Delegates Text Editing ✅ COMPROMISE

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Zig receives KeyEvent                                        │
│    - Maintains focused_id: u64 in Zig                           │
│    - Knows widget 42 is focused text input (from UI code)       │
└────────────┬────────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────────┐
│ 2. Zig: Delegate to specialized handler                         │
│    if (widget.kind == .TextInput) {                             │
│        c.mcore_text_input_key(ctx, widget.id, &key_event);      │
│    } else if (widget.kind == .Button && key.is(.Enter)) {       │
│        handleButtonPress(widget.id);  // Pure Zig               │
│    }                                                             │
└─────────────────────────────────────────────┬───────────────────┘
                                              │ FFI (only for text)
┌─────────────────────────────────────────────▼───────────────────┐
│ 3. Rust: Handle text editing ONLY                               │
│    - mcore_text_input_key(id=42, key='H')                       │
│    - Updates internal String                                    │
│    - Returns bool (changed)                                     │
└─────────────────────────────────────────────────────────────────┘
```

**Result:** Zig routes events, but delegates text editing to Rust

**Key API:**
```c
// Zig handles most events itself
// Rust handles ONLY text editing events
bool mcore_text_input_key(ctx, id, &key_event);
bool mcore_text_input_mouse(ctx, id, x, y, &mouse_event);
```

**Zig still controls:**
- Which widget is focused
- Event routing
- Button clicks, hover, etc.

**Rust only handles:**
- Text editing ops (complex UTF-8)
- Text selection
- IME composition

---

## The "Who Knows What" Problem

### If Zig Does Layout (Your Choice 1B)...

**Zig knows:**
- Widget positions (computed flexbox)
- Widget sizes
- Widget IDs

**Rust needs to know** (for various features):
- Widget positions → Hit testing (decision 6)
- Widget positions → Accessibility bounds (decision 9)
- Widget IDs → Focus state (decision 4)
- Widget IDs → Text input state (decision 5)

**This means Zig needs to SEND layout results to Rust!**

```c
// After Zig computes layout:
typedef struct {
    uint64_t id;
    mcore_rect_t bounds;
    mcore_widget_kind_t kind;  // Button, TextInput, Label, etc.
} mcore_widget_info_t;

// Send to Rust
void mcore_set_frame_widgets(ctx, widget_info[], count);
```

Now Rust can hit test, build a11y tree, etc.

---

### If Rust Does Layout (Option 1A)...

**Rust knows everything, Zig just declares**

No need to send layout results back - Rust already has them.

But this defeats your transparency goal!

---

## The Hybrid Solution: "Zig UI, Rust Text"

Here's a cleaner ownership model:

### **Principle: Zig Owns UI, Rust Owns Text Editing**

```
┌──────────────────────────────────────┐
│         ZIG RESPONSIBILITIES         │
├──────────────────────────────────────┤
│ • Flexbox layout                     │
│ • ID management                      │
│ • Focus state (which ID is focused)  │
│ • Hit testing (point in rect)        │
│ • Event routing                      │
│ • Button/widget logic                │
│ • Layout caching                     │
│ • Accessibility tree building        │
└──────────────┬───────────────────────┘
               │
               │ Delegates ONLY text editing
               │
┌──────────────▼───────────────────────┐
│        RUST RESPONSIBILITIES         │
├──────────────────────────────────────┤
│ • Parley text measurement            │
│ • Text input String storage          │
│ • Text cursor/selection              │
│ • UTF-8 operations                   │
│ • IME composition                    │
│ • Vello rendering                    │
│ • AccessKit serialization            │
└──────────────────────────────────────┘
```

**The API becomes:**

```c
// === ZIG CONTROLS ===

// Zig-side layout (no Rust)
// Zig-side focus (no Rust)
// Zig-side hit testing (no Rust)

// === DELEGATION TO RUST ===

// Text measurement (Parley is complex)
void mcore_measure_text(ctx, text, font_size, max_width, &size);

// Text editing (Rust owns the String)
typedef struct {
    const char* content;  // Rust's String, read-only view
    int cursor;
    int selection_start;
    int selection_end;
    bool changed_this_frame;
} mcore_text_state_t;

// Zig calls this once per frame for each text input
void mcore_text_input_get_state(ctx, id, &out_state);

// Zig forwards ONLY text-related events to Rust
void mcore_text_input_event(ctx, id, &event);

// Drawing (Rust renders via Vello)
void mcore_text_draw(ctx, text, x, y, color);
void mcore_rect_rounded(ctx, &rect);

// Accessibility (Rust serializes to AccessKit)
void mcore_a11y_set_tree(ctx, &tree_data);  // Zig builds, Rust serializes
```

---

## Event Flow with This Approach

### Keystroke in Text Input:

```
[macOS] KeyDown 'H'
   ↓
[Zig Event Loop]
   if focused_widget.kind == .TextInput {
       c.mcore_text_input_event(ctx, focused_id, &key_evt); → [Rust]
   } else if focused_widget.kind == .Button && key == .Enter {
       handleButtonPress(focused_id);  // Pure Zig
   }
   ↓
[Rust] (ONLY if text input)
   text_states[id].insert_char('H');
   text_states[id].cursor += 1;

[Next frame in Zig]
   var text_state: mcore_text_state_t = undefined;
   c.mcore_text_input_get_state(ctx, id, &text_state); ← [Rust]

   if (text_state.changed_this_frame) {
       // React to change if needed
   }

   c.mcore_text_draw(ctx, text_state.content, x, y, white);
```

**FFI calls per keystroke:** 1 (event) + 1 (get state) = 2 total

**Clear ownership:**
- Zig decides routing
- Rust handles complex text ops
- No back-and-forth

---

### Mouse Click on Button:

```
[macOS] MouseDown at (150, 50)
   ↓
[Zig Event Loop]
   const hit_id = hitTest(mouse_pos, widgets);  // Pure Zig
   focused_id = hit_id;

   if (widgets[hit_id].kind == .Button) {
       handleButtonClick(hit_id);  // Pure Zig, no Rust!
   }
```

**FFI calls:** 0! Pure Zig.

---

### Mouse Click in Text Input (Selection):

```
[macOS] MouseDown at (100, 200)
   ↓
[Zig Event Loop]
   const hit_id = hitTest(mouse_pos, widgets);  // Pure Zig
   focused_id = hit_id;

   if (widgets[hit_id].kind == .TextInput) {
       // Delegate to Rust for text hit testing
       c.mcore_text_input_mouse(ctx, hit_id, x, y, &mouse_evt); → [Rust]
   }
   ↓
[Rust]
   // Use Parley's hit_test to find cursor position
   let cursor_pos = layout.hit_test_point(x - widget_x, y - widget_y);
   text_states[id].cursor = cursor_pos;
```

**FFI calls:** 1 (for complex text hit testing)

**Why delegate?** Parley has the glyph positions, hit testing text is complex.

---

## Constraint Analysis: App Developer Experience

### Example: Building a Login Form

```zig
const UI = @import("ui.zig");

var username_buf: [256]u8 = undefined;
var username_len: usize = 0;
var password_buf: [256]u8 = undefined;
var password_len: usize = 0;

pub fn renderLoginForm(ui: *UI) void {
    ui.beginColumn(.{ .gap = 10, .padding = 20 });

    // Label (pure Zig, no Rust)
    ui.label("Username:", .{ .font_size = 16 });

    // Text input (Rust handles editing)
    ui.pushID("username");
    if (ui.textInput(&username_buf, &username_len, .{})) {
        std.debug.print("Username changed: {s}\n", .{username_buf[0..username_len]});
    }
    ui.popID();

    // Password field
    ui.label("Password:", .{ .font_size = 16 });
    ui.pushID("password");
    _ = ui.textInput(&password_buf, &password_len, .{ .password = true });
    ui.popID();

    // Button (pure Zig)
    ui.pushID("login_btn");
    if (ui.button("Log In", .{})) {
        attemptLogin(username_buf[0..username_len], password_buf[0..password_len]);
    }
    ui.popID();

    ui.endColumn();
}
```

**Developer sees:**
- Pure Zig layout code
- Simple buffer management
- Rust is invisible except for text input internals

**Constraints:**
- Text content lives in Zig buffers (but Rust manages edits)
- Must use `pushID/popID` for stable IDs
- Text editing "just works" without thinking about UTF-8

**Not constrained:**
- Layout algorithm (pure Zig)
- Custom widgets (define in Zig)
- Event handling (mostly Zig)
- Styling (Zig controls all params)

---

## The Accessibility Problem

If Zig does layout, Zig must build the AccessKit tree:

```zig
// Zig builds a11y tree alongside UI
ui.a11yBeginNode(id, .Button);
ui.a11ySetName("Log In");
ui.a11ySetBounds(bounds);
ui.a11yAddAction(.Click);
ui.a11yEndNode();

// At end of frame, send to Rust
c.mcore_a11y_update(ctx, &tree_builder.finish());
```

**Option: Use accesskit-c!**

accesskit has C bindings: https://github.com/AccessKit/accesskit/tree/main/bindings/c

Zig could use AccessKit directly, Rust only bridges to platform:
```zig
const accesskit = @cImport(@cInclude("accesskit.h"));

const node = accesskit.Node.init(id, .Button);
accesskit.Node.setName(node, "Save");
```

Then Rust just does platform adapters (macOS AX bridge).

**This solves decision 9!** Zig builds tree, Rust is just the platform bridge.

---

## Strategy: Evolutionary Architecture

### **Phase 1: Start Ultra-Simple** (Week 1-4)

**Rust is ONLY rendering:**
```c
void mcore_measure_text(ctx, text, font_size, max_width, &size);
void mcore_text_draw(ctx, text, x, y, color);
void mcore_rect_rounded(ctx, &rect);
```

**Zig does EVERYTHING else:**
- Layout (flexbox in ~300 LOC)
- IDs, focus, hit testing
- Event handling
- Even text cursor (simple ASCII-only for now)

**App constraints:** Only ASCII text input, no IME, no selection. But it WORKS!

**Benefit:** You get building immediately, defer hard decisions.

---

### **Phase 2: Add Text Editing** (Week 5-8)

When you actually need good text input:

**Add Rust text state:**
```c
// New APIs
uint64_t mcore_text_state_create(ctx);
void mcore_text_state_insert(ctx, state_id, text, cursor);
void mcore_text_state_delete(ctx, state_id, start, end);
const char* mcore_text_state_get(ctx, state_id);
int mcore_text_state_cursor(ctx, state_id);
```

**Zig still routes events:**
```zig
if (key == .Backspace and focused.kind == .TextInput) {
    c.mcore_text_state_delete(ctx, focused.text_state_id, cursor, cursor+1);
}
```

Zig is in control, but delegates UTF-8 ops to Rust helpers.

---

### **Phase 3: Add IME** (Week 9-12)

When you need CJK input:

**Rust owns composition:**
```c
void mcore_text_ime_update(ctx, state_id, composition, cursor);
void mcore_text_ime_commit(ctx, state_id, text);
```

Zig forwards IME events but Rust handles composition.

---

### **Phase 4: Add Accessibility** (Month 4+)

Use **accesskit-c** from Zig:
```zig
const tree = accesskit.Tree.init();
for (widgets) |w| {
    const node = accesskit.Node.init(w.id, w.role());
    accesskit.Node.setName(node, w.name);
    accesskit.Node.setBounds(node, w.bounds);
    tree.addNode(node);
}

// Rust just bridges to platform
c.mcore_a11y_commit_tree(ctx, tree.handle);
```

---

## My Proposed Boundary (Based on Your Answers)

### **Clean Split:**

**Zig Territory** (you control):
1. ✅ Layout computation (flexbox)
2. ✅ ID management
3. ✅ Focus state (which ID has focus)
4. ✅ Hit testing
5. ✅ Event routing
6. ✅ Widget logic (buttons, etc.)
7. ✅ Layout caching
8. ✅ Accessibility tree building (via accesskit-c)

**Rust Territory** (you delegate):
1. ✅ Text measurement (Parley)
2. ✅ Text rendering (Vello)
3. ✅ Text editing state (String, cursor, selection)
4. ✅ Text editing operations (insert, delete, grapheme boundaries)
5. ✅ IME composition
6. ✅ Accessibility platform bridge (macOS AXUIElement)

**Command Buffer** (decision 7):
- Zig builds command buffer
- Single FFI call per frame
- Rust consumes and renders

---

## Refined Minimal API

```c
// === CORE ===
mcore_context_t* mcore_create(surface_desc);
void mcore_begin_frame(ctx);
void mcore_render_commands(ctx, commands[], count);  // Command buffer!
void mcore_end_frame(ctx, clear_color);

// === TEXT (Rust helpers) ===
void mcore_measure_text(ctx, text, font_size, max_width, &size);

// === TEXT INPUT (Rust owns state) ===
uint64_t mcore_text_state_create(ctx);
void mcore_text_state_destroy(ctx, state_id);
void mcore_text_state_event(ctx, state_id, &event);  // Key or mouse
const char* mcore_text_state_get(ctx, state_id);
mcore_text_cursor_t mcore_text_state_cursor(ctx, state_id);
void mcore_text_state_set(ctx, state_id, text);

// === ACCESSIBILITY (Zig builds, Rust bridges) ===
void mcore_a11y_update(ctx, &tree_data);  // Zig serializes accesskit tree

// === IME (Rust owns composition) ===
void mcore_ime_update(ctx, state_id, composition, cursor);
void mcore_ime_commit(ctx, state_id, text);
```

**Total: ~12 functions**

---

## Command Buffer Detail (Decision 7B)

Since you like command buffers (Clay-style):

```zig
const DrawCommand = extern struct {
    kind: enum(u8) { Rect, RoundedRect, Text, Line },
    // Flat union for FFI
    x: f32, y: f32,
    width: f32, height: f32,
    radius: f32,  // For rounded rect
    color: [4]f32,
    text_ptr: ?[*:0]const u8,  // For text command
    font_size: f32,
};

// Zig allocates
var draw_commands: [4096]DrawCommand = undefined;
var cmd_count: usize = 0;

// Zig builds commands
draw_commands[cmd_count] = .{
    .kind = .Text,
    .x = 50, .y = 100,
    .text_ptr = "Hello",
    .font_size = 24,
    .color = .{1, 1, 1, 1},
    ...
};
cmd_count += 1;

// Single FFI call per frame
c.mcore_render_commands(ctx, &draw_commands, cmd_count);
```

**Rust consumes in one shot:**
```rust
fn render_commands(commands: &[DrawCommand]) {
    for cmd in commands {
        match cmd.kind {
            DrawCommandKind::Text => {
                let text = unsafe { CStr::from_ptr(cmd.text_ptr) };
                // Measure, layout, draw
            }
            DrawCommandKind::RoundedRect => {
                scene.fill(...);
            }
        }
    }
}
```

**Benefits:**
- Zig preallocates (fast!)
- 1 FFI call per frame
- Zig can inspect/modify commands before sending
- Rust can reorder/optimize

---

## Answer to "How Constrained?"

### **With This Boundary, App Developer Can:**

✅ Write entire UI in pure Zig
✅ Custom widgets trivially (just Zig code)
✅ Custom layout (modify flexbox, or write grid layout)
✅ Debug with print statements (all state visible)
✅ Introspect widget tree (it's just Zig structs)
✅ Cache aggressively (Zig allocators)
✅ Profile and optimize (Zig tooling)

### **App Developer Cannot:**

❌ Customize text editing behavior deeply (cursor movement is in Rust)
❌ Implement custom IME handling (platform-specific, stays in Rust)
❌ Modify text shaping (Parley is opaque)

### **But in practice:**

Most apps don't need to customize text cursor movement! They just want:
- "Give me a text input box"
- "Tell me when it changes"
- "It should support IME"

This approach delivers that with **minimal Rust intrusion**.

---

## Recommendation: Start Simple, Add Complexity

### **Phase 1 (Now → Week 4): Pure Zig + Dumb Rust**

```c
// ONLY these APIs:
void mcore_measure_text(ctx, text, font_size, max_width, &size);
void mcore_render_commands(ctx, commands[], count);
```

Zig implements:
- Flexbox
- IDs, focus, hit testing
- Simple text cursor (no selection, no IME yet)
- Accessibility via accesskit-c

**Result:** Functional UI toolkit, ~1500 LOC Zig, ~500 LOC Rust

---

### **Phase 2 (Week 5-8): Add Text Editing**

When simple cursor isn't enough:

```c
// Add:
uint64_t mcore_text_state_create(ctx);
void mcore_text_state_event(ctx, state_id, &event);
const char* mcore_text_state_get(ctx, state_id);
// ... etc
```

Zig still owns focus/routing, but delegates text editing.

**Result:** Production-quality text, ~2000 LOC Zig, ~1500 LOC Rust

---

### **Phase 3 (Month 3+): Add IME if Needed**

Only if your app needs CJK input.

---

## Final Answers to Your Questions

Based on your comments and my analysis:

### **Decisions:**

1. **Layout:** B (Zig) ✅ You chose this
2. **Text measurement:** A (Rust full layout) ✅ You chose this - no conflict because Zig calls it as a black box
3. **ID management:** A (Zig owns) ✅ You chose this
4. **Focus:** **Hybrid** → Zig stores `focused_id`, Rust queries it
5. **Text input state:** A (Rust owns String) ✅ You chose this
6. **Hit testing:** **Hybrid** → Zig does rect hit test, delegates text hit test to Rust
7. **Rendering:** B (command buffer) ✅ You chose this
8. **Events:** **Hybrid** → Zig routes, delegates text events to Rust
9. **Accessibility:** **B + accesskit-c** → Zig builds tree, Rust is platform bridge
10. **Layout cache:** B (Zig) ✅ You chose this

### **The Hybrid Pattern:**

```
┌────────────────────────────────────────────────┐
│ Zig: General UI (layout, focus, events)       │
│   ↓ Delegates ONLY text complexity             │
│ Rust: Text specialist (editing, IME, Parley)  │
└────────────────────────────────────────────────┘
```

**Key insight:** Zig is in control, Rust is a specialized text backend.

---

## Does This Make Sense?

The trick is:
- **Zig owns the focused_id** (decision-making)
- **Rust owns text content** (UTF-8 safety)
- **Clean handoff:** Zig says "this text input got an event, handle it", Rust handles it

No back-and-forth because:
- Zig doesn't query Rust for every decision
- Zig sends events to Rust, gets state back once per frame
- For non-text widgets, Rust isn't involved at all

**Want me to make a diagram showing this clean separation?**

Or should we start implementing Phase 1 and see how it feels?