# API Boundary Decisions

**Where to draw the line between Zig and Rust?**

For each subsystem, here are the options with tradeoffs. Give me your call on each!

---

## 1. Layout Computation

### Option A: Layout Engine in Rust ⚙️
```c
// Zig declares structure
mcore_begin_row(ctx, gap=10);
  mcore_label(ctx, "Left", &out_bounds);   // Rust computes position
  mcore_spacer(ctx, flex=1.0);
  mcore_label(ctx, "Right", &out_bounds);
mcore_end_row(ctx);
```

**Zig does:** Declare containers and children
**Rust does:** Flexbox algorithm, compute all positions
**FFI calls:** ~5 per container (begin, children, end)

**Pros:**
- Layout algorithm complexity stays in Rust
- Can optimize (caching, SIMD) in Rust
- Fewer bugs (Rust safety)

**Cons:**
- Zig doesn't see layout internals
- Harder to debug layout issues from Zig
- More "magic" in Rust

---

### Option B: Layout in Zig, Measurement in Rust 📏
```zig
// Zig does all layout math
const row = LayoutRow.init(.{ .gap = 10 });
row.add(.{ .width = 100, .height = 30 }); // Fixed size

// Ask Rust for text size
var text_size: Size = undefined;
c.mcore_measure_text(ctx, "Hello", 16, &text_size);
row.add(.{ .width = text_size.w, .height = text_size.h });

const positions = row.compute(available_width); // Pure Zig math

// Render at computed positions
c.mcore_text_draw(ctx, "Hello", positions[1].x, positions[1].y, color);
```

**Zig does:** Flexbox algorithm, all layout math
**Rust does:** Only text measurement (Parley)
**FFI calls:** ~N per text item (measure only)

**Pros:**
- Zig has full control and visibility
- Layout is transparent, easy to debug
- Minimal FFI surface

**Cons:**
- Zig implements flexbox (but it's only ~300 LOC)
- Zig handles float math (more potential for bugs)

---

### Option C: Hybrid - Zig Describes, Rust Solves 🤝
```zig
// Zig builds layout tree
var row = LayoutTree.beginRow();
row.addFixed(100, 30);
row.addText("Hello", 16);  // Zig doesn't know size yet
row.addFlex(1.0);
const tree = row.finish();

// Send entire tree to Rust for solving
var results: [16]Rect = undefined;
c.mcore_solve_layout(ctx, &tree, available_w, &results);

// Render at solved positions
c.mcore_text_draw(ctx, "Hello", results[1].x, results[1].y, color);
```

**Zig does:** Build layout tree structure
**Rust does:** Text measurement + flexbox solving (one pass)
**FFI calls:** 1-2 per frame (send tree, get results)

**Pros:**
- Single FFI call per frame (fast!)
- Rust can optimize the solve
- Zig still declares structure explicitly

**Cons:**
- Need to serialize layout tree across FFI
- Less incremental than streaming API

---

**MY VOTE:** Option B or C. Leaning toward **B** for transparency.

**YOUR CALL:** Which do you prefer?

PAUL: option B for sure! we're basically Clay in this case, while rust is the dumb simple renderer.

---

## 2. Text Measurement

### Option A: Full Layout in Rust
```c
void mcore_measure_text(ctx, "Hello", font_size, max_width, &out_size);
```

**Rust does:** Parley layout, break lines, measure
**Zig sees:** Just final (width, height)

---

### Option B: Granular Control
```c
int layout_id = mcore_text_layout_create(ctx, "Hello", font_size);
float width = mcore_text_layout_width(ctx, layout_id);
int lines = mcore_text_layout_line_count(ctx, layout_id);
void mcore_text_layout_break_lines(ctx, layout_id, max_width);
void mcore_text_layout_draw(ctx, layout_id, x, y, color);
```

**Rust does:** Parley operations
**Zig sees:** Step-by-step control over layout

---

**MY VOTE:** Option A. Text layout is complex, no benefit to exposing internals.

**YOUR CALL:** Agree or want more control?

PAUL: yeah let's do full layout in rust for text... but will that conflict with layout choice? or is this still the clay way

---

## 3. ID Management

### Option A: Zig Owns IDs
```zig
// Zig manages ID stack
const UI = struct {
    id_stack: ArrayList(u64),

    fn pushID(label: []const u8) u64 {
        const id = hash(label);
        self.id_stack.append(id);
        c.mcore_push_id(ctx, id);  // Just notify Rust
        return id;
    }
};
```

**Zig does:** ID generation, stack management
**Rust does:** Track IDs for state lookup
**FFI:** 2 calls per widget (push/pop)

**Pros:**
- Zig controls ID logic
- Easy to debug (print IDs in Zig)

**Cons:**
- More FFI calls

---

### Option B: Rust Manages IDs
```c
uint64_t mcore_push_id(ctx, "label");  // Rust hashes and returns ID
void mcore_pop_id(ctx);
```

**Zig does:** Just push/pop labels
**Rust does:** Hashing, stack, everything

**Pros:**
- Less Zig code
- Consistent hashing (Rust's DefaultHasher)

**Cons:**
- Zig doesn't see IDs (harder to debug)

---

**MY VOTE:** Option A. Zig should see and control IDs.

**YOUR CALL:** ?

PAUL: agreed, option A

---

## 4. Focus State

### Option A: Rust Owns Focus State
```c
bool mcore_is_focused(ctx, id);
void mcore_set_focus(ctx, id);
```

**Rust does:** Track focused_id, handle Tab navigation
**Zig does:** Query and react

---

### Option B: Zig Owns Focus State
```zig
var ui_state = UI.State{
    .focused_id = null,
};

if (key == .Tab) {
    ui_state.focused_id = ui_state.next_focusable_id();
}

const is_focused = (ui_state.focused_id == current_id);
```

**Zig does:** Track focused_id, tab logic
**Rust does:** Nothing (or just stores for accessibility tree)

---

**MY VOTE:** Option A. Focus needs to interact with text cursor state (in Rust), better to keep together.

**YOUR CALL:** ?

PAUL: gah this is a tough one! I want to be able to drive focus from zig (like for tabbing events for instance) but I agree rust should "own" the focus state.

---

## 5. Text Input State

### Option A: Rust Owns Text Content
```c
// Rust owns the String
int mcore_text_input(ctx, id, &out_changed);
const char* mcore_text_input_get(ctx, id, buf, buf_len);
void mcore_text_input_set(ctx, id, text);
```

**Rust does:** UTF-8 String, cursor, selection
**Zig does:** Display and react to changes

---

### Option B: Zig Owns Text Buffer
```zig
var buf: [256]u8 = undefined;
var cursor: usize = 0;
var selection: ?[2]usize = null;

// Zig calls Rust for each edit
if (key == .Backspace) {
    c.mcore_text_delete_at(ctx, &buf, &cursor, &selection);
}

// Rust just helps with operations
```

**Zig does:** Own buffer, call Rust helpers
**Rust does:** UTF-8 operations, grapheme boundaries

---

**MY VOTE:** Option A. UTF-8 String operations are error-prone, Rust should own.

**YOUR CALL:** ?

PAUL: yeah this sounds like something where it will be nice to have the masonry wins

---

## 6. Hit Testing (Mouse → Widget)

### Option A: Rust Does Hit Testing
```c
uint64_t mcore_hit_test(ctx, mouse_x, mouse_y);  // Returns widget ID
```

**Rust does:** Check mouse against all layout rects
**Zig does:** React to hit widget

---

### Option B: Zig Does Hit Testing
```zig
for (widgets) |widget| {
    if (pointInRect(mouse, widget.bounds)) {
        handleClick(widget.id);
        break;
    }
}
```

**Zig does:** Rect intersection tests
**Rust does:** Nothing

---

**MY VOTE:** Option A. Rust has layout rects, might as well hit test there.

**YOUR CALL:** ?

PAUL: I don't like the idea of roundtripping to rust code for every interaction just conceptually. I'm leaning toward option a.

---

## 7. Rendering Batching

### Option A: Stream Rendering (Current)
```zig
// Each draw call goes to Rust immediately
c.mcore_rect_rounded(ctx, &rect1);
c.mcore_text_draw(ctx, "A", 10, 10, white);
c.mcore_rect_rounded(ctx, &rect2);
c.mcore_text_draw(ctx, "B", 20, 20, white);
```

**FFI calls:** N (one per draw call)
**Vello Scene:** Built incrementally

---

### Option B: Batch Commands
```zig
const DrawCmd = extern struct {
    kind: enum { Rect, Text },
    // ... union of params
};

var commands: [1024]DrawCmd = undefined;
var cmd_count: usize = 0;

// Zig collects commands
commands[cmd_count] = .{ .kind = .Rect, ... };
cmd_count += 1;

// Send batch to Rust
c.mcore_render_batch(ctx, &commands, cmd_count);
```

**FFI calls:** 1 per frame
**Vello Scene:** Built from batch

**Pros:**
- Fewer FFI calls (faster)
- Could reorder for optimization

**Cons:**
- More complex API
- Zig needs command buffer

PAUL: I like the idea of command buffer because then we can preallocate that in zig. that's what clay does right?

---

**MY VOTE:** Option A for now (simple). Optimize to B only if profiling shows FFI overhead.

**YOUR CALL:** ?

---

## 8. Event Handling

### Option A: Rust Processes Events
```c
void mcore_mouse_event(ctx, x, y, button, is_down);
void mcore_key_event(ctx, keycode, mods, is_down);

// Rust figures out what widget is affected, updates state
```

**Rust does:** Hit testing, focus changes, text insertion
**Zig does:** Forward raw events

---

### Option B: Zig Processes Events
```zig
const mouse_evt = event_queue.pop();
const hit_id = hitTest(mouse_evt.x, mouse_evt.y, widgets);

if (mouse_evt.is_down) {
    focused_id = hit_id;
    if (widgets[hit_id].kind == .Button) {
        handleButtonClick(hit_id);
    }
}
```

**Zig does:** Hit test, route to widgets
**Rust does:** Helper functions only

---

**MY VOTE:** Option A. Events interact with text editing state (in Rust), keep it together.

**YOUR CALL:** ?

PAUL: gah these are so hard! I want rust to own text but I want zig to be in charge of events! gah!

---

## 9. Accessibility Tree

### Option A: Rust Builds Tree
```c
// Zig just declares items with IDs
mcore_button(ctx, id, "Save", &bounds);

// Rust builds AccessKit tree from encountered IDs + layout
```

**Rust does:** AccessKit tree building
**Zig does:** Declare UI (implicitly builds tree)

---

### Option B: Zig Builds Tree
```c
mcore_a11y_begin_node(ctx, id, ROLE_BUTTON);
mcore_a11y_set_name(ctx, "Save");
mcore_a11y_set_bounds(ctx, &bounds);
mcore_a11y_end_node(ctx);
```

**Zig does:** Explicit tree building
**Rust does:** Serialize to AccessKit

---

**MY VOTE:** Option A. Accessibility tree mirrors UI structure, let Rust infer it.

**YOUR CALL:** ?

PAUL: dang, it makes sense that rust would own this because it's talking to accesskit, but this would mean rust would need a whole idea of our widget tree not just getting simple draw commands. maybe we want to use accesskit-c?

---

## 10. Layout Caching

### Option A: Rust Caches Layouts
```rust
// Rust remembers last frame's layout by ID
if id_exists_and_same_size {
    return cached_layout[id];
}
```

**Rust does:** Cache management, invalidation
**Zig does:** Nothing (transparent optimization)

---

### Option B: Zig Manages Cache
```zig
const layout_cache = LayoutCache.init();

// Zig explicitly caches
if (layout_cache.get(id)) |cached| {
    return cached;
}
const new_layout = computeLayout(...);
layout_cache.put(id, new_layout);
```

**Zig does:** Cache decisions
**Rust does:** Just compute when asked

---

**MY VOTE:** Option A. Caching is an optimization, hide it in Rust.

**YOUR CALL:** ?

PAUL: but zig is so good at optimization!!!

---

## Summary Table

| Subsystem | My Vote | Reasoning |
|-----------|---------|-----------|
| **1. Layout computation** | **Zig (B)** | Transparency worth it, flexbox is simple |
| **2. Text measurement** | **Rust (A)** | Parley is complex, no benefit to expose |
| **3. ID management** | **Zig (A)** | Control + debuggability |
| **4. Focus state** | **Rust (A)** | Interacts with text editing |
| **5. Text input state** | **Rust (A)** | UTF-8 safety critical |
| **6. Hit testing** | **Rust (A)** | Trivial, Rust has the rects |
| **7. Rendering batching** | **Stream (A)** | Simple first, optimize later |
| **8. Event handling** | **Rust (A)** | Needs text state |
| **9. Accessibility tree** | **Rust (A)** | Mirror UI structure automatically |
| **10. Layout caching** | **Rust (A)** | Hidden optimization |

---

## The Minimal Rust API (Based on My Votes)

```c
// Core
mcore_context_t* mcore_create(surface_desc);
void mcore_begin_frame(ctx, time);
void mcore_end_frame(ctx, clear_color);

// IDs (Zig computes, Rust tracks)
void mcore_push_id(ctx, uint64_t id);
void mcore_pop_id(ctx);

// Measurement
void mcore_measure_text(ctx, text, font_size, max_width, &out_size);

// Drawing (immediate)
void mcore_rect_rounded(ctx, &rect);
void mcore_text_draw(ctx, text, x, y, color);

// Focus queries
bool mcore_is_focused(ctx, id);
bool mcore_is_hovered(ctx, id);
void mcore_set_focus(ctx, id);

// Events (Zig forwards, Rust processes)
void mcore_mouse_event(ctx, &event);
void mcore_key_event(ctx, &event);

// Text input
bool mcore_text_input(ctx, id);  // Returns true if changed
const char* mcore_text_input_get(ctx, id, buf, buf_len);
void mcore_text_input_set(ctx, id, text);

// Optional: Get layout rects for debugging
void mcore_get_widget_bounds(ctx, id, &out_rect);
```

**Total API: ~15 functions**

Zig would implement:
- Flexbox layout (~300 LOC)
- ID hashing/stack (~50 LOC)
- Event routing logic (~100 LOC)

---

## Alternative: The Other Extreme

**"Zig Does Everything" Approach:**

Zig implements:
- Layout (flexbox)
- Focus management
- Hit testing
- Even text cursor movement

Rust is ONLY:
- Parley (text measurement + rendering)
- Vello (drawing)
- AccessKit (tree serialization)

C API becomes even smaller:
```c
// Measurement
void mcore_measure_text(...);

// Drawing
void mcore_text_draw(...);
void mcore_rect(...);

// Accessibility
void mcore_a11y_update(ctx, &tree_data);

// IME helpers
int mcore_utf8_cursor_left(text, cursor);
int mcore_utf8_grapheme_len(text, offset);
```

**Rust is just a graphics/text backend!**

This would be ~500 LOC in Rust, ~2000 LOC in Zig.

---

**Could work if:**
- You're comfortable with UTF-8 manipulation in Zig
- You want maximum control
- You don't mind reimplementing focus/hit test logic

**Tradeoff:**
- More code in Zig
- But total transparency
- Rust becomes a "dumb" rendering backend

---

## Questions for You

For each decision, tell me **A, B, or C**:

1. **Layout computation:** A (Rust), B (Zig), C (Hybrid)?
2. **Text measurement:** A (opaque), B (granular)?
3. **ID management:** A (Zig owns), B (Rust owns)?
4. **Focus state:** A (Rust), B (Zig)?
5. **Text input state:** A (Rust owns String), B (Zig owns buffer)?
6. **Hit testing:** A (Rust), B (Zig)?
7. **Rendering:** A (stream), B (batch)?
8. **Events:** A (Rust processes), B (Zig processes)?
9. **Accessibility:** A (Rust builds tree), B (Zig builds explicitly)?
10. **Layout cache:** A (Rust), B (Zig)?

**Or tell me your philosophy and I'll design the boundary:**
- "Maximum Zig control" → Rust is a rendering backend
- "Balanced pragmatic" → Rust handles complex bits (text, a11y)
- "Minimal FFI overhead" → Batch calls, Rust does heavy lifting

What's your take?
