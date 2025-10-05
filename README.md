# Zello

**Immediate-mode UI toolkit in Zig with Rust rendering backend**

*Zig owns UI. Rust is a text specialist. One-way delegation.*

## Status

✅ **Library restructuring complete!** The project has been reorganized into a clean, ergonomic API.

See [THE_PLAN.md](THE_PLAN.md) for the architectural vision and [CLEANUP_AND_LIBRARYIFY.md](CLEANUP_AND_LIBRARYIFY.md) for the refactoring plan.

## Features

- ✅ Immediate-mode UI (ImGui-style)
- ✅ Flexbox layout (Clay-inspired)
- ✅ Text input with full editing (cursor, selection, clipboard)
- ✅ IME support (emoji picker, Japanese/Chinese input)
- ✅ Accessibility (VoiceOver on macOS)
- ✅ Mouse and keyboard input
- ✅ Focus management (Tab navigation)
- ✅ Clean Zig API (hides FFI complexity)

## Quick Start

```zig
const std = @import("std");
const zello = @import("zello");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 400, 300, "Hello Zello", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    ui.beginVstack(.{ .gap = 20, .padding = 20 }) catch return;

    ui.label("Hello, Zello!", .{ .size = 24 }) catch {};

    if (ui.button("Click Me!", .{}) catch false) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
```

## Building

**With Nix (recommended):**

```bash
nix develop --impure
cd rust/engine && cargo build --release && cd ../..
zig build run
```

## Project Structure

```
src/
├── zello.zig          # Public library API
├── ui/                # UI implementation  
├── platform/          # Platform integration
├── renderer/          # FFI layer (internal)
└── examples/          # Example programs
```

## API Overview

See [CLEANUP_AND_LIBRARYIFY.md](CLEANUP_AND_LIBRARYIFY.md) for complete API documentation.

## License

See LICENSE file.

## Running Examples

### Quick Method (with script)

```bash
./run_example.sh counter              # Run counter example
./run_example.sh hello_world          # Run hello world
./run_example.sh counter_advanced     # Run advanced counter
```

### Manual Method

1. Edit `src/main.zig` and change the import:
   ```zig
   const example = @import("examples/counter.zig");
   ```

2. Build and run:
   ```bash
   nix develop --impure
   zig build run
   ```

See `src/examples/README.md` for all available examples and details.
