# Zello Examples

## Running Examples

### Quick Start

1. **Enter Nix environment:**
   ```bash
   nix develop --impure
   ```

2. **Build Rust renderer** (first time or after Rust changes):
   ```bash
   cd rust/engine && cargo build --release && cd ../..
   ```

3. **Run the current example:**
   ```bash
   zig build run
   ```

### Switching Examples

Edit `src/main.zig` and change the import:

```zig
// Change this line:
const example = @import("examples/counter.zig");

// To one of:
const example = @import("examples/hello_world.zig");
const example = @import("examples/counter.zig");
const example = @import("examples/counter_advanced.zig");
```

Then run:
```bash
zig build run
```

## Available Examples

### 1. hello_world.zig
**Simple button example**

Shows:
- Basic app setup
- VStack layout
- Label widget
- Button widget
- Simple click handling

**Run:**
```zig
const example = @import("examples/hello_world.zig");
```

### 2. counter.zig
**Simple counter app**

Shows:
- Global state management
- Multiple buttons
- HStack layout (horizontal)
- Dynamic text (formatting numbers)
- State updates

**Run:**
```zig
const example = @import("examples/counter.zig");
```

Features:
- Increment/Decrement buttons
- Reset button
- Live counter display

### 3. counter_advanced.zig
**Advanced counter with stats**

Shows:
- Structured state (AppState struct)
- Methods on state
- Multiple pieces of state
- Tracking statistics
- Time-based data

**Run:**
```zig
const example = @import("examples/counter_advanced.zig");
```

Features:
- +1, +10, -1 buttons
- Reset button
- Total clicks counter
- Last click timestamp
- Larger counter display

### 4. demo_simple.zig
**Simple multi-widget demo**

Shows:
- Multiple buttons in a row
- Multiple text inputs
- Toggle button (debug mode)
- Dynamic labels
- Window size display
- All widgets in single horizontal layout

**Run:**
```zig
const example = @import("examples/demo_simple.zig");
```

Features:
- 3 clickable buttons
- Debug toggle button
- 2 text input fields
- Title label
- Window size label
- Tab navigation between all focusable widgets

⚠️ **Note:** Uses single-level layout only (no nesting)

### 5. demo.zig
**Full-featured demo** (preserved from original main.zig)

⚠️ **Note:** This still uses the old API and won't compile without updates.
Preserved as a reference for future porting to the new API with nested layouts.

## Quick Commands

```bash
# Full rebuild
rm -rf .zig-cache zig-out && zig build run

# Just rebuild Zig (faster)
zig build run

# Rebuild Rust only (if you changed Rust code)
cd rust/engine && cargo build --release && cd ../..
```

## Keyboard Shortcuts

All examples support:
- **Tab** - Cycle focus between interactive widgets
- **Shift+Tab** - Cycle focus backwards
- **Space/Enter** - Activate focused button
- **Cmd+Q** - Quit app (macOS)

Text inputs also support:
- **Cmd+A** - Select all
- **Cmd+C** - Copy
- **Cmd+X** - Cut
- **Cmd+V** - Paste
- **Arrow keys** - Move cursor
- **Shift+Arrows** - Select text

## Creating Your Own Example

1. Create `src/examples/my_example.zig`:

```zig
const std = @import("std");
const zello = @import("../zello.zig");

// Your state here
var my_state: i32 = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 400, 300, "My App", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;

    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    // Your UI here!
    ui.label("Hello!", .{}) catch {};

    ui.endVstack();
}
```

2. Update `src/main.zig`:
```zig
const example = @import("examples/my_example.zig");
```

3. Run:
```bash
zig build run
```

## Troubleshooting

### "FileNotFound" errors
Make sure you're in the project root directory.

### Rust library errors
Rebuild the Rust renderer:
```bash
cd rust/engine && cargo build --release && cd ../..
```

### Zig version errors
Use Nix environment:
```bash
nix develop --impure
zig version  # Should show 0.15.1
```

### App crashes immediately
Check for panics in terminal output. Common issues:
- Missing `endVstack()` / `endHstack()`
- Trying to nest layouts (not supported yet)

## Next Steps

- Try modifying the examples
- Create your own example
- Explore the API in `src/zello.zig`
- Read `CLEANUP_AND_LIBRARYIFY.md` for API details
