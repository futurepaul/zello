# Zello Quick Start

## TL;DR

```bash
# 1. Enter Nix environment
nix develop --impure

# 2. Build Rust renderer (first time only)
cd rust/engine && cargo build --release && cd ../..

# 3. Run an example
./run_example.sh demo_simple
```

That's it! You should see a window with buttons and text inputs.

---

## What Just Happened?

You ran a **fully functional immediate-mode UI** written in Zig with:
- ✅ Flexbox layout
- ✅ Text input with editing, selection, clipboard
- ✅ IME support (emoji picker, Japanese/Chinese input)
- ✅ Full accessibility (VoiceOver on macOS)
- ✅ Mouse and keyboard input
- ✅ Focus management (Tab to navigate)

All in **~80 lines of code** for the demo!

---

## Available Examples

| Example | Lines | What It Shows |
|---------|-------|---------------|
| `hello_world` | 27 | Simplest possible UI |
| `counter` | 48 | State management |
| `counter_advanced` | 77 | Structured state |
| `demo_simple` | 85 | Multiple widgets |

**Run any:**
```bash
./run_example.sh hello_world
./run_example.sh counter
./run_example.sh counter_advanced
./run_example.sh demo_simple
```

---

## Try It Yourself

### Modify an Example

1. Open `src/examples/counter.zig`
2. Change line 29:
   ```zig
   ui.label(text, .{ .size = 32 }) catch {};
   // Change to:
   ui.label(text, .{ .size = 64 }) catch {};
   ```
3. Run:
   ```bash
   ./run_example.sh counter
   ```

The counter text is now twice as big!

### Create Your Own

Create `src/examples/my_app.zig`:

```zig
const std = @import("std");
const zello = @import("../zello.zig");

var clicks: u32 = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 500, 200, "My App", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;

    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    ui.beginHstack(.{ .gap = 20, .padding = 30 }) catch return;

    // Show click count
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "Clicks: {d}", .{clicks}) catch "???";
    ui.label(text, .{ .size = 28 }) catch {};

    // Click button
    if (ui.button("Click Me!", .{}) catch false) {
        clicks += 1;
        std.debug.print("Total clicks: {d}\n", .{clicks});
    }

    ui.endHstack();
}
```

Run it:
```bash
# Edit main.zig to point to your example
./run_example.sh my_app
```

---

## Keyboard Shortcuts

- **Tab / Shift+Tab** - Navigate between widgets
- **Space / Enter** - Click focused button
- **Cmd+Q** - Quit

**In text inputs:**
- **Cmd+A** - Select all
- **Cmd+C / X / V** - Copy / Cut / Paste
- **Arrow keys** - Move cursor
- **Shift+Arrows** - Select text

---

## What's Next?

### Learn More
- `src/examples/README.md` - Detailed examples guide
- `WORKING_EXAMPLES.md` - API comparison (old vs new)
- `CLEANUP_AND_LIBRARYIFY.md` - Full API reference

### Limitations (for now)
- ❌ Can't nest layouts yet (vstack inside hstack)
- ❌ Limited widget set (label, button, text_input only)
- ❌ No theming/styling system

### Future Features
See [CLEANUP_AND_LIBRARYIFY.md](CLEANUP_AND_LIBRARYIFY.md) for:
- Nested layouts (constraints down, sizes up)
- More widgets (checkbox, slider, etc.)
- Theming system
- Custom fonts
- Multi-line text
- Scroll containers

---

## Troubleshooting

### "Layout nesting not yet supported"
You tried to nest layouts! For now, use a single `beginVstack` or `beginHstack` per frame.

**Don't:**
```zig
ui.beginVstack(.{}) catch return;
  ui.beginHstack(.{}) catch return;  // ❌ Will panic!
  ui.endHstack();
ui.endVstack();
```

**Do:**
```zig
ui.beginHstack(.{}) catch return;
// All widgets here
ui.endHstack();
```

### App crashes immediately
Check for:
- Missing `endVstack()` or `endHstack()`
- Unmatched begin/end pairs
- Trying to use `demo.zig` (old API, doesn't work yet)

### Black screen
Make sure you're calling:
```zig
ui.beginFrame();
defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};
```

---

## You're Ready!

You now have a working immediate-mode UI toolkit in Zig. Start building! 🚀

**Explore:**
- Modify the examples
- Create your own widgets
- Experiment with layouts
- Read the API docs

**Share:**
- Show us what you build!
- Report issues
- Contribute examples

Have fun! ✨
