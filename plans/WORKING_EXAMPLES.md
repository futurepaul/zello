# Working Examples

All these examples compile and run with the new API! 🎉

## ✅ Currently Working

### 1. hello_world.zig (27 lines)
**Simplest possible example**
- One label
- One button
- VStack layout

```bash
./run_example.sh hello_world
```

### 2. counter.zig (48 lines)
**Simple counter with state**
- Global `var counter: i32`
- Label showing count
- Increment/Decrement/Reset buttons
- HStack layout

```bash
./run_example.sh counter
```

### 3. counter_advanced.zig (77 lines)
**Counter with AppState struct**
- Organized state management
- Multiple stats (clicks, last time)
- Structured methods
- HStack layout

```bash
./run_example.sh counter_advanced
```

### 4. demo_simple.zig (85 lines)
**Multi-widget showcase**
- Multiple buttons
- Multiple text inputs
- Toggle button (debug mode)
- Dynamic labels
- Window size display
- All in single HStack

```bash
./run_example.sh demo_simple
```

## ❌ Not Yet Working

### demo.zig (977 lines)
**Original full demo - OLD API**

This is preserved from the original `main.zig` but hasn't been ported yet because:
- Uses old direct FFI calls
- Uses old module imports
- Has nested layouts (vstack with hstack inside)
- Needs nested layout support to port properly

**Will port after:** Nested layouts are implemented (constraints down, sizes up)

---

## Layout Limitations

**Current:** Only single-level layouts (one `beginVstack` or `beginHstack` per frame)

**Future:** Nested layouts with proper constraint propagation

See `CLEANUP_AND_LIBRARYIFY.md` Phase 3 for details on the future nested layout system.

---

## API Comparison

### Old API (demo.zig):
```zig
// Globals everywhere
var g_ctx: ?*c.mcore_context_t = null;
var g_ui: id_mod.UI = undefined;
var g_focus: focus_mod.FocusState = undefined;

// Manual ID management
g_ui.pushID("button1") catch {};
const id = g_ui.getCurrentID();
g_focus.registerFocusable(id) catch {};
const is_focused = g_focus.isFocused(id);
drawButton(g_ctx, "Click", x, y, w, h, id, is_focused);
g_ui.popID();

// Manual accessibility
buildA11yTree(g_ctx) catch {};
```

### New API (all working examples):
```zig
// Everything in UI context
fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{0.15, 0.15, 0.20, 1.0}) catch {};
    
    ui.beginHstack(.{ .gap = 10 }) catch return;
    
    // Auto-ID, auto-focus, auto-accessibility!
    if (ui.button("Click", .{}) catch false) {
        // Clicked!
    }
    
    ui.endHstack();
}
```

**Reduction:** ~10 lines → 1 line for a button! 🎉

---

## Next Steps

1. **Try the examples** - They all work!
2. **Modify them** - Change text, add buttons, etc.
3. **Create your own** - Start from `hello_world.zig`
4. **Wait for nested layouts** - Then we can port `demo.zig` properly

The library is ready to use! 🚀
