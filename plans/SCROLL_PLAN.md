# SCROLL IMPLEMENTATION PLAN

**Goal:** Add smooth, OS-native feeling scroll containers to Zello with proper constraint handling.

---

## The Constraint/Infinity Problem

### The Challenge

A scroll container presents a fundamental layout paradox:

```
ScrollArea wants to know: "How tall is my content?"
Content wants to know: "How much space do I have?"
```

If we pass **infinite constraints** down:
- `flex: 1` child will try to fill infinity → breaks
- Child has no upper bound → can't calculate layout
- Flexbox algorithm fails (can't distribute infinity)

If we pass **finite constraints** down:
- Content must fit in viewport → defeats the purpose of scrolling
- Can't have content taller than viewport

### The Solution: Two Modes

**Mode 1: Finite Scroll (Default)** - Portal Approach
- Pass parent's **max constraints** to child
- Child measures itself (may be smaller than max)
- Scroll if child is larger than available space
- ✅ Works with flexbox
- ✅ No infinity issues
- ❌ Child can't grow beyond parent's max

**Mode 2: Unconstrained Scroll** - For Known-Size Content
- Pass **loose constraints** (min=0, max=parent_max OR large_number)
- Child determines its own size
- Scroll if child exceeds viewport
- ✅ Child can be any size
- ⚠️ Requires child to have intrinsic size (no `flex: 1`)

**Mode 3: Virtual Scroll** - For Infinite Lists (Future)
- Pass `f64::INFINITY` for scroll axis
- Only render visible items
- Track anchor + offset
- ✅ Truly infinite content
- ⚠️ Complex, requires cooperation

---

## Recommended Architecture (Based on Masonry Portal + Clay Momentum)

### Core Data Structure

```zig
pub const ScrollArea = struct {
    child: WidgetPod,

    // Layout results
    content_size: Size = .{},      // How big the child actually is
    viewport_size: Size = .{},     // How much space we have to show it
    viewport_pos: Point = .{},     // Current scroll position (top-left of viewport in content space)

    // Constraint mode
    constrain_horizontal: bool = false,  // Pass finite width constraint?
    constrain_vertical: bool = false,    // Pass finite height constraint?
    must_fill: bool = false,            // Child must fill viewport?

    // Scrollbars (optional)
    scrollbar_vertical: ?WidgetPod = null,
    scrollbar_horizontal: ?WidgetPod = null,

    // Momentum scrolling
    scroll_momentum: Vec2 = .{},
    scroll_origin: Point = .{},
    pointer_origin: Point = .{},
    drag_active: bool = false,
    drag_time: f32 = 0,
};
```

### Constraint Flow

```zig
fn layout(self: *ScrollArea, ctx: *LayoutCtx, bc: *const BoxConstraints) !Size {
    // Step 1: Determine child constraints
    const child_bc = BoxConstraints{
        .min = if (self.must_fill) bc.min else Size.ZERO,
        .max = Size{
            .width = if (self.constrain_horizontal) bc.max.width else f32.max,
            .height = if (self.constrain_vertical) bc.max.height else f32.max,
        },
    };

    // Step 2: Layout child
    const content_size = try ctx.run_layout(&self.child, &child_bc);
    self.content_size = content_size;

    // Step 3: Determine our own size
    const viewport_size = bc.constrain(content_size);
    self.viewport_size = viewport_size;

    // Step 4: Clamp scroll position to valid range
    self.clamp_viewport_pos();

    // Step 5: Set up clipping and place child
    try ctx.set_clip_rect(Rect.from_size(viewport_size));
    try ctx.place_child(&self.child, Point.ZERO);  // Child at (0,0), we'll translate in compose

    // Step 6: Layout scrollbars if present
    if (self.scrollbar_vertical) |*scrollbar| {
        const scrollbar_bc = BoxConstraints.tight(
            .width = 12,
            .height = viewport_size.height,
        );
        _ = try ctx.run_layout(scrollbar, &scrollbar_bc);
        try ctx.place_child(scrollbar, Point{
            .x = viewport_size.width - 12,
            .y = 0,
        });
    }

    return viewport_size;
}
```

### The Key: Apply Scroll Offset in Compose, NOT Layout

```zig
fn compose(self: *ScrollArea, ctx: *ComposeCtx) !void {
    // Translate child by negative viewport position
    // This shifts the child's content so the viewport shows the right portion
    try ctx.set_child_scroll_translation(
        &self.child,
        Vec2{
            .x = -self.viewport_pos.x,
            .y = -self.viewport_pos.y,
        },
    );

    // Scrollbar doesn't get translated (it stays fixed)
    if (self.scrollbar_vertical) |*scrollbar| {
        try ctx.compose_child(scrollbar);
    }
}
```

### Viewport Clamping

```zig
fn clamp_viewport_pos(self: *ScrollArea) void {
    // Max scroll position is content_size - viewport_size
    // (Scrolled all the way to the bottom/right)
    const max_x = @max(0, self.content_size.width - self.viewport_size.width);
    const max_y = @max(0, self.content_size.height - self.viewport_size.height);

    self.viewport_pos.x = @max(0, @min(self.viewport_pos.x, max_x));
    self.viewport_pos.y = @max(0, @min(self.viewport_pos.y, max_y));
}
```

---

## Usage Patterns

### Pattern 1: Scrolling a Tall Column (Default)

```zig
// Want: Column that can grow taller than viewport
ui.beginScrollArea(.{ .constrain_vertical = false }) catch return;

ui.beginVstack(.{ .gap = 10, .padding = 20 }) catch return;
for (items) |item| {
    ui.label(item.text, .{}) catch {};
}
ui.endVstack();

ui.endScrollArea();
```

**What happens:**
- ScrollArea passes finite width (parent's max), **large height** (unconstrained)
- VStack measures all children and sums heights
- VStack returns intrinsic size (width=constrained, height=sum)
- ScrollArea clips to viewport, enables scrolling if needed
- ✅ Works because VStack has intrinsic height (sum of children)

### Pattern 2: Scrolling with Flex Children (Constrained)

```zig
// Want: Flex layout inside scroll, but scroll the overflow
ui.beginScrollArea(.{ .constrain_vertical = true }) catch return;

ui.beginVstack(.{ .gap = 10 }) catch return;
ui.beginHstack(.{ .width = .flex_1 }) catch {};  // ✅ OK: has finite constraint
    // ...
ui.endHstack();
ui.endVstack();

ui.endScrollArea();
```

**What happens:**
- ScrollArea passes parent's max constraints (finite)
- Flex children work normally (have finite space to distribute)
- If content exceeds viewport, scroll activates
- ✅ Works because flex gets finite constraints

### Pattern 3: What NOT to Do

```zig
// ❌ WRONG: Unconstrained scroll + flex child
ui.beginScrollArea(.{ .constrain_vertical = false }) catch return;

ui.beginVstack(.{}) catch return;
ui.spacer(.{ .height = .flex_1 });  // ❌ PANIC: flex-1 with infinite constraint!
ui.endVstack();

ui.endScrollArea();
```

**What happens:**
- ScrollArea passes infinite height constraint
- VStack tries to give flex child infinite space
- **PANIC:** "Cannot use flex sizing inside unconstrained scroll area"

**Fix:** Use `constrain_vertical = true` if you need flex children.

---

## Momentum Scrolling (Clay's Algorithm)

### Constants

```zig
const MOMENTUM_DECAY: f32 = 0.95;      // Per-frame momentum retention (95%)
const MOMENTUM_THRESHOLD: f32 = 0.1;   // Stop if below this (pixels/frame)
const MOMENTUM_DAMPING: f32 = 25.0;    // Divide drag distance by (time * this)
const WHEEL_MULTIPLIER: f32 = 10.0;    // Multiply wheel delta by this
const MIN_DRAG_DISTANCE: f32 = 10.0;   // Don't apply momentum if drag < this
```

### Frame Update (call from UI.update())

```zig
pub fn update_momentum(self: *ScrollArea, dt: f32) void {
    // Apply momentum
    self.viewport_pos.x += self.scroll_momentum.x;
    self.scroll_momentum.x *= MOMENTUM_DECAY;
    if (@abs(self.scroll_momentum.x) < MOMENTUM_THRESHOLD) {
        self.scroll_momentum.x = 0;
    }

    self.viewport_pos.y += self.scroll_momentum.y;
    self.scroll_momentum.y *= MOMENTUM_DECAY;
    if (@abs(self.scroll_momentum.y) < MOMENTUM_THRESHOLD) {
        self.scroll_momentum.y = 0;
    }

    // Clamp to valid range
    self.clamp_viewport_pos();
}
```

### Event Handling

```zig
fn on_pointer_event(self: *ScrollArea, ctx: *EventCtx, event: *const PointerEvent) !void {
    switch (event.*) {
        .scroll => |scroll_data| {
            // Wheel/trackpad scroll
            const delta = switch (scroll_data.delta) {
                .pixel => |p| Vec2{ .x = p.x, .y = p.y },
                .line => |l| Vec2{
                    .x = l.x * 120.0,  // Line height in pixels
                    .y = l.y * 120.0,
                },
            };

            // Apply wheel multiplier and scale
            const scaled_delta = delta.scale(-WHEEL_MULTIPLIER * ctx.scale_factor);

            self.viewport_pos = self.viewport_pos.add(scaled_delta);
            self.clamp_viewport_pos();

            // Cancel momentum (wheel overrides drag)
            self.scroll_momentum = Vec2{};

            try ctx.request_compose();
        },

        .down => |down_data| {
            // Start drag
            self.drag_active = true;
            self.pointer_origin = down_data.position;
            self.scroll_origin = self.viewport_pos;
            self.scroll_momentum = Vec2{};  // Cancel existing momentum
            self.drag_time = 0;
        },

        .move => |move_data| {
            if (self.drag_active) {
                // Update drag
                const delta = move_data.position.sub(self.pointer_origin);
                self.viewport_pos = self.scroll_origin.add(delta);
                self.clamp_viewport_pos();
                self.drag_time += ctx.dt;
                try ctx.request_compose();
            }
        },

        .up => {
            if (self.drag_active) {
                // Calculate momentum on release
                const distance = self.viewport_pos.sub(self.scroll_origin);

                // Only apply momentum if dragged far enough
                if (@abs(distance.x) > MIN_DRAG_DISTANCE or @abs(distance.y) > MIN_DRAG_DISTANCE) {
                    // momentum = distance / (time * damping_factor)
                    const time_factor = @max(0.016, self.drag_time);  // Min 1 frame
                    self.scroll_momentum = distance.scale(1.0 / (time_factor * MOMENTUM_DAMPING));
                }

                self.drag_active = false;
            }
        },

        else => {},
    }
}
```

---

## Pan-to-View (Focus Following)

**Use case:** When a widget gains focus (e.g., text input), automatically scroll it into view.

```zig
pub fn pan_to_rect(self: *ScrollArea, target: Rect) void {
    const viewport = Rect{
        .x = self.viewport_pos.x,
        .y = self.viewport_pos.y,
        .width = self.viewport_size.width,
        .height = self.viewport_size.height,
    };

    // Compute pan range for each axis
    const new_x = compute_pan_range(
        viewport.x,
        viewport.x + viewport.width,
        target.x,
        target.x + target.width,
    );

    const new_y = compute_pan_range(
        viewport.y,
        viewport.y + viewport.height,
        target.y,
        target.y + target.height,
    );

    self.viewport_pos = Point{ .x = new_x, .y = new_y };
    self.clamp_viewport_pos();
}

fn compute_pan_range(
    viewport_start: f32,
    viewport_end: f32,
    target_start: f32,
    target_end: f32,
) f32 {
    const viewport_size = viewport_end - viewport_start;
    const target_size = target_end - target_start;

    // If target fully visible, don't move
    if (target_start >= viewport_start and target_end <= viewport_end) {
        return viewport_start;
    }

    // If viewport fully contains target, don't move
    if (viewport_start >= target_start and viewport_end <= target_end) {
        return viewport_start;
    }

    // Determine smallest movement to show target
    const target_width = @min(viewport_size, target_size);

    if (viewport_start >= target_start) {
        // Target is above/left of viewport - scroll up/left
        return target_end - target_width;
    } else {
        // Target is below/right of viewport - scroll down/right
        return target_start;
    }
}
```

**Integration with focus system:**

```zig
// In FocusState, after focus changes:
fn on_focus_changed(self: *FocusState, ui: *UI, new_focused_id: u64) !void {
    // Find the widget's bounding box
    const widget_rect = ui.getWidgetRect(new_focused_id) orelse return;

    // Find containing ScrollArea (walk up tree)
    var parent_id = ui.getParentID(new_focused_id);
    while (parent_id) |pid| {
        if (ui.getWidget(pid)) |widget| {
            if (widget.* == .scroll_area) {
                widget.scroll_area.pan_to_rect(widget_rect);
                try ui.request_compose();
                return;
            }
        }
        parent_id = ui.getParentID(pid);
    }
}
```

---

## Scrollbar Widget

### Data Structure

```zig
pub const ScrollBar = struct {
    orientation: enum { vertical, horizontal },
    thumb_pos: f32 = 0,      // 0..1 (percentage of track)
    thumb_size: f32 = 0,     // 0..1 (percentage of track)
    dragging: bool = false,
    drag_offset: f32 = 0,
};
```

### Update from ScrollArea

```zig
fn update_scrollbar(self: *ScrollArea) void {
    if (self.scrollbar_vertical) |*scrollbar| {
        const scrollable_height = @max(1, self.content_size.height - self.viewport_size.height);
        const viewport_ratio = self.viewport_size.height / self.content_size.height;

        scrollbar.thumb_size = @max(0.1, @min(1.0, viewport_ratio));  // At least 10% visible
        scrollbar.thumb_pos = self.viewport_pos.y / scrollable_height;
    }
}
```

### Scrollbar Interaction

```zig
fn on_scrollbar_drag(
    scrollbar: *ScrollBar,
    scroll_area: *ScrollArea,
    delta_pixels: f32,
    track_length: f32,
) void {
    const scrollable_height = scroll_area.content_size.height - scroll_area.viewport_size.height;
    const delta_percent = delta_pixels / track_length;

    scroll_area.viewport_pos.y += delta_percent * scrollable_height;
    scroll_area.clamp_viewport_pos();
}
```

---

## Implementation Phases

### Phase 1: Basic Scrolling (No Momentum, No Scrollbars)

**Files to create:**
- `src/ui/widgets/scroll_area.zig`

**API:**
```zig
// In ui.zig:
pub fn beginScrollArea(self: *UI, opts: ScrollAreaOptions) !void;
pub fn endScrollArea(self: *UI) void;

pub const ScrollAreaOptions = struct {
    constrain_horizontal: bool = false,
    constrain_vertical: bool = false,
    must_fill: bool = false,
};
```

**Implementation checklist:**
- [ ] Create ScrollArea struct with child, content_size, viewport_pos
- [ ] Implement layout() with constraint logic
- [ ] Implement compose() with scroll translation
- [ ] Handle wheel scroll events
- [ ] Add viewport clamping
- [ ] Add panic for flex inside unconstrained scroll
- [ ] Add to ui.zig API (beginScrollArea/endScrollArea)
- [ ] Test with tall content

**Example:**
```zig
ui.beginScrollArea(.{ .constrain_vertical = false }) catch return;
ui.beginVstack(.{ .gap = 10 }) catch return;
for (0..100) |i| {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, "Item {}", .{i});
    ui.label(text, .{}) catch {};
}
ui.endVstack();
ui.endScrollArea();
```

**Test criteria:**
- ✅ Can scroll with mouse wheel
- ✅ Content taller than viewport is clipped
- ✅ Viewport stays within bounds (can't scroll past content)
- ✅ Flex children work with `constrain_vertical = true`
- ✅ Panics with helpful message if flex + unconstrained

### Phase 2: Add Momentum Scrolling

**New fields:**
- `scroll_momentum`, `drag_active`, `drag_time`, etc.

**Implementation checklist:**
- [ ] Add momentum fields to ScrollArea
- [ ] Implement update_momentum() (called from UI.update())
- [ ] Handle pointer down/move/up events
- [ ] Calculate momentum on release
- [ ] Apply decay per frame
- [ ] Cancel momentum on wheel scroll
- [ ] Tune constants (decay, damping, threshold)

**Test criteria:**
- ✅ Touch-drag scrolling works
- ✅ Momentum continues after release
- ✅ Momentum decays smoothly
- ✅ Stops when momentum < threshold
- ✅ Wheel scroll cancels momentum
- ✅ Feels "native" (like macOS/iOS)

### Phase 3: Add Scrollbars

**Files to create:**
- `src/ui/widgets/scrollbar.zig`

**Implementation checklist:**
- [ ] Create ScrollBar widget
- [ ] Layout scrollbar in ScrollArea.layout()
- [ ] Update scrollbar thumb pos/size based on viewport
- [ ] Handle scrollbar drag events
- [ ] Draw scrollbar thumb (rounded rect)
- [ ] Auto-hide when not needed (content fits in viewport)
- [ ] Auto-fade when not hovered (optional)

**Test criteria:**
- ✅ Scrollbar appears when content overflows
- ✅ Thumb size reflects viewport/content ratio
- ✅ Thumb position reflects scroll position
- ✅ Can drag thumb to scroll
- ✅ Clicking track jumps to position

### Phase 4: Pan-to-View

**Implementation checklist:**
- [ ] Implement compute_pan_range()
- [ ] Add pan_to_rect() to ScrollArea
- [ ] Integrate with focus system
- [ ] Integrate with text input cursor (scroll to cursor)

**Test criteria:**
- ✅ Tabbing to off-screen widget scrolls it into view
- ✅ Typing in text input keeps cursor visible
- ✅ Scrolls minimal distance (doesn't overshoot)

### Phase 5: Virtual Scrolling (Future)

**Only implement when needed (1000+ item lists).**

**Files to create:**
- `src/ui/widgets/virtual_scroll.zig`

**Key differences:**
- Pass `f64::INFINITY` constraint for scroll axis
- Track `anchor_index` and `active_range`
- Render only visible items
- Use callbacks to load/unload items
- Estimate scroll range from mean item height

---

## Design Decisions Summary

### ✅ Do This

1. **Pass finite constraints by default** (Portal approach)
   - `constrain_vertical = false` means "pass parent's max" (still finite!)
   - Only use true infinity for virtual scrolling

2. **Apply scroll offset in compose phase**
   - `set_child_scroll_translation()` during compose
   - NOT during layout placement

3. **Use Clay's momentum parameters**
   - Decay: 0.95
   - Damping: 25.0
   - Threshold: 0.1
   - Wheel multiplier: 10.0

4. **Port Masonry's pan_to_rect algorithm**
   - Minimal movement to show target
   - Don't move if already visible

5. **Make scrollbars a separate widget**
   - Easier to customize/replace
   - Can be rendered on top

### ❌ Don't Do This

1. **Don't pass infinite constraints for basic scrolling**
   - Breaks flex layout
   - Requires child cooperation
   - Not needed if child has intrinsic size

2. **Don't apply scroll offset during layout**
   - Breaks widget positions
   - Makes hit testing harder

3. **Don't implement virtual scrolling first**
   - Complex
   - Not needed for most use cases
   - Basic scrolling handles 99% of cases

4. **Don't allow `flex: 1` inside unconstrained scroll**
   - Panic with clear error message
   - Document this limitation

---

## Error Messages

When user does something invalid:

```zig
// In flex.zig, when receiving infinite constraint:
if (bc.max.height == f32.max and child.sizing.height == .flex_1) {
    @panic(
        \\Cannot use flex sizing inside an unconstrained scroll area.
        \\
        \\Solution: Set `constrain_vertical = true` on the scroll area:
        \\    ui.beginScrollArea(.{ .constrain_vertical = true })
        \\
        \\Or use fixed/intrinsic sizing for this child.
    );
}
```

---

## Future Enhancements

- **Rubber-banding** (bounce at edges) - iOS style
- **Scroll snap points** (snap to page/item boundaries)
- **Pull-to-refresh** (mobile pattern)
- **Bidirectional scroll** (horizontal + vertical, with corner grab)
- **Nested scroll** (propagate to parent when child reaches edge)
- **Custom scrollbar styling** (skinning)
- **Scroll position save/restore** (for navigation)
- **Programmatic smooth scroll** (animated pan_to_rect)

---

## References

- **Masonry Portal:** `/Users/futurepaul/dev/sec/zello/references/xilem/masonry/src/widgets/portal.rs`
- **Masonry VirtualScroll:** `/Users/futurepaul/dev/sec/zello/references/xilem/masonry/src/widgets/virtual_scroll.rs`
- **Clay Momentum:** `/Users/futurepaul/dev/sec/zello/references/clay/clay.h` (lines 4102-4213)
- **Clay Example:** `/Users/futurepaul/dev/sec/zello/references/clay/examples/raylib-sidebar-scrolling-container/main.c`

---

**Ready to implement!** Start with Phase 1 (basic scrolling), test thoroughly, then add momentum and scrollbars.
