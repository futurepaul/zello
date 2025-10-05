# Demo Feature Requirements

Analysis of `src/examples/demo.zig` (old main.zig) to identify what we need to support in the new API.

---

## Demo Structure Overview

The old demo shows **8 sections** in a **nested layout structure**:

```
Root VStack (gap=20, padding=10)
├─ Section 1: Title
├─ Section 2: Demo 1 (Horizontal flexbox with fixed sizes)
│   └─ Nested HStack with 4 colored labels
├─ Section 3: Demo 2 (Horizontal with flex spacers)
│   └─ Nested HStack with labels + flex spacers
├─ Section 4: Demo 3 (Vertical flexbox)
│   └─ Nested VStack with 3 colored labels
├─ Section 5: Interactive buttons
│   └─ Nested HStack with 3 focusable buttons
├─ Section 6: Debug toggle button
├─ Section 7: Text inputs
│   └─ 2 text input widgets (vertical)
└─ Section 8: Window size indicator
```

**Key observation:** This requires **2-level nesting minimum** (root vstack → section hstacks/vstacks)

---

## Required Features for Full Demo

### 1. ✅ **Basic Widgets** (Already Implemented)
- [x] Label with customizable size/color
- [x] Button (clickable, focusable)
- [x] Text Input (editable, selectable, clipboard)

### 2. ❌ **Nested Layouts** (CRITICAL - Can't build demo without this!)

**Current state:** Single-level only, panics on nesting
**Required:** At minimum 2-level nesting:
```zig
ui.beginVstack(.{}) // Root
  ui.label("Section Title", .{})
  ui.beginHstack(.{}) // Nested!
    ui.button("1", .{})
    ui.button("2", .{})
  ui.endHstack()
ui.endVstack()
```

**Complexity:** This is the big one from CLEANUP_AND_LIBRARYIFY.md Phase 3

**Implementation approach (from Clay/Flutter/Masonry):**
- Constraints flow DOWN the tree (parent tells child max size)
- Sizes flow UP the tree (child reports actual size to parent)
- Two-pass algorithm:
  1. **Layout pass:** Calculate all sizes and positions
  2. **Render pass:** Draw widgets at calculated positions

**Alternatives for demo without nesting:**
- Make 8 separate examples instead of one combined demo
- Use manual positioning (not using layout system)
- Wait until nested layouts are implemented

### 3. ❌ **Flex Spacers** (Required for Demo 2)

**Current:** `flex.addSpacer(1)` exists in flex.zig but not exposed in UI API

**Required:**
```zig
ui.beginHstack(.{})
  ui.label("Start", .{})
  ui.spacer(1.0) // Flex spacer - takes up remaining space
  ui.label("Middle", .{})
  ui.spacer(1.0)
  ui.label("End", .{})
ui.endHstack()
```

**Complexity:** Easy - just expose existing `FlexContainer.addSpacer()`

### 4. ❌ **Custom Label Colors** (Required for colored boxes in Demo 1/2/3)

**Current:** `ui.label()` accepts `.color` option but all labels look the same

**Required:** Labels with custom background colors:
```zig
ui.label("One", .{ .color = .{1.0, 0.6, 0.6, 1.0}, .bg_color = .{0.2, 0.2, 0.3, 1.0} })
```

**Complexity:** Easy - modify `label()` function

### 5. ❌ **Debug Bounds Visualization** (Optional but cool)

**Current:** Not implemented in new API

**Features:**
- Toggle button to show/hide debug bounds
- Draw colored rectangles around widgets
- Different colors for different widget types
- Show layout container bounds

**Complexity:** Medium - need debug mode flag in UI context, drawing helpers

### 6. ❌ **Window Size Reactivity** (Required for "Resize the window" demo)

**Current:** `ui.width` and `ui.height` exist and update on resize

**Required:** Demo that shows layout adapting to window size
- Flex spacers that stretch with window
- Dynamic text showing window dimensions

**Complexity:** Easy - already works, just need to demonstrate it

### 7. ✅ **Text Input Features** (Already Work!)
- [x] Two separate text inputs
- [x] Focus indication (blue border)
- [x] Cursor positioning
- [x] Text selection
- [x] Clipboard (Cmd+C/V/X)
- [x] IME support
- [x] Tab navigation between inputs

### 8. ✅ **Accessibility** (Already Works!)
- [x] VoiceOver support
- [x] Keyboard navigation
- [x] Focus management
- [x] Action callbacks

---

## Feature Priority for Demo Parity

### P0 - Blocking (Can't build demo without these)
1. **Nested layouts** (2+ levels of vstack/hstack nesting)
   - This is 80% of the work
   - Without this, can only build single-row/column UIs
   - Requires two-pass layout algorithm

### P1 - Core Features (Demo won't look right without these)
2. **Flex spacers** - Easy, just expose existing API
3. **Custom label colors** - Easy, just add option

### P2 - Nice to Have (Demo could work without these)
4. **Debug bounds visualization** - Medium effort, good for development
5. **Section titles** - Can use regular labels

### P3 - Already Working
6. Window size reactivity - ✅ Works
7. Text inputs - ✅ Work
8. Buttons - ✅ Work
9. Focus/accessibility - ✅ Work

---

## Minimum Viable Demo (Without Nested Layouts)

If we DON'T implement nested layouts, we can still show:

**Option A: Multiple separate examples**
```
examples/
├── demo_hstack.zig    # Horizontal layout demo
├── demo_vstack.zig    # Vertical layout demo
├── demo_buttons.zig   # Interactive buttons
├── demo_text.zig      # Text inputs
└── demo_colors.zig    # Colored labels
```

**Option B: Single-level layout showcase**
```zig
// One horizontal row with everything
ui.beginHstack(.{ .gap = 15 })
  ui.label("Buttons:", .{})
  ui.button("1", .{})
  ui.button("2", .{})
  ui.button("3", .{})
  ui.spacer(1.0)
  ui.textInput("input1", &buf, .{})
  ui.label(size_text, .{})
ui.endHstack()
```

**Option C: Wait for nested layouts**
- Implement proper 2-level nesting first
- Then build full demo with feature parity

---

## Recommended Path Forward

### Quick Wins (1-2 hours):
1. ✅ Add `ui.spacer(flex: f32)` function
2. ✅ Add `bg_color` option to `label()`
3. ✅ Create `demo_single_row.zig` showing all widgets in one HStack

### Medium Effort (1-2 days):
4. Add debug bounds visualization
5. Create multiple separate demos (one per section)

### Big Work (1-2 weeks):
6. Implement 2-level nested layouts (constraints down, sizes up)
7. Port full demo.zig to new API with proper nesting

---

## Nested Layout Implementation Notes

For reference when implementing, the pattern from Clay/Flutter/Masonry:

**Phase 1: Measure (constraints down, sizes up)**
```
Parent calculates constraints for child
→ Child measures itself given constraints
→ Child returns actual size to parent
→ Parent uses child size for layout calculation
```

**Phase 2: Position (positions down)**
```
Parent calculates position for each child based on sizes
→ Child receives absolute position
→ Child positions its own children (recursive)
```

**Phase 3: Render**
```
All widgets draw at their final positions
```

This requires buffering widgets during measurement, then rendering after layout is complete.

---

## Immediate Actionable Items

To match demo with **current** single-level layout API:

### 1. Add Spacer Widget (5 minutes)
```zig
// In ui.zig
pub fn spacer(self: *UI, flex: f32) !void {
    if (self.layout_stack.items.len == 0) {
        @panic("spacer() called outside layout!");
    }

    var frame = &self.layout_stack.items[self.layout_stack.items.len - 1];
    try frame.flex.addSpacer(flex);
}
```

### 2. Add Label Background Color (10 minutes)
```zig
pub const LabelOptions = struct {
    size: f32 = 16,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    bg_color: ?[4]f32 = null, // null = no background
    padding: f32 = 8,
};

pub fn label(self: *UI, text: [:0]const u8, opts: LabelOptions) !void {
    const size = self.measureText(text, opts.size, self.width);
    const width = size.width + (opts.padding * 2);
    const height = size.height + (opts.padding * 2);
    const pos = try self.allocateSpace(width, height);

    // Draw background if specified
    if (opts.bg_color) |bg| {
        try self.commands.roundedRect(pos.x, pos.y, width, height, 4, bg);
    }

    // Draw text
    try self.commands.text(text, pos.x + opts.padding, pos.y + opts.padding, opts.size, size.width, opts.color);
}
```

### 3. Create demo_showcase.zig (30 minutes)

Show all current features in a single horizontal row:
- Colored labels
- Flex spacers
- Buttons
- Text inputs
- Dynamic text (window size, time)

---

## Conclusion

**To achieve full demo parity:** We MUST implement nested layouts.

**Without nested layouts:** We can build impressive single-level demos that show off 90% of features.

**Recommendation:**
1. Add spacer + colored labels (quick wins) ✅
2. Build `demo_showcase.zig` with single-level layout ✅
3. Implement nested layouts (big task) ⏱️
4. Port full demo.zig ⏱️

The library is working and usable NOW, but nested layouts are the key feature blocking the full demo port.
