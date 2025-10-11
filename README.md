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
const zello = @import("zello.zig");
const color = @import("ui/color.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 600, 400, "Hello Zello", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(color.WHITE) catch {};

    ui.beginVstack(.{ .gap = 20, .padding = 40 }) catch return;

    ui.label("Hello, Zello!", .{ .size = 24, .color = color.BLACK }) catch {};

    if (ui.button("Click Me!", .{}) catch false) {
        std.debug.print("Button clicked at {d:.2}s\n", .{time});
    }

    ui.endVstack();
}
```

## Building and Running

**Always use the Nix development environment** (ensures correct Zig version and dependencies):

```bash
# Enter the dev environment
nix develop --impure

# Build Rust renderer (first time or after Rust changes)
cd rust/engine && cargo build --release && cd ../..

# Build Zig app
zig build

# Run the showcase demo (default)
zig build run
# or
./zig-out/bin/zig_host_app

# Run a specific demo
zig build run -- hello_world
# or
./zig-out/bin/zig_host_app hello_world
```

**Available demos:**
- `showcase` - Full feature showcase with all widgets (default)
- `hello_world` - Simple hello world with a button

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

## Creating Your Own App

The demos in `src/examples/` show how to create apps. The pattern is simple:

1. Create a `.zig` file with a `main()` function that calls `zello.init()`
2. Provide a frame callback function that builds your UI
3. Call `zello.run()` to start the event loop

Check out `src/examples/hello_world.zig` for the simplest example, or `src/examples/showcase.zig` for a comprehensive feature demo.
