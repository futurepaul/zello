# Zello

**Building a no-compromises immediate-mode UI toolkit in Zig**

*Zig owns UI. Rust is a text specialist. One-way delegation.*

Zello is an experimental immediate-mode UI toolkit that combines Zig's simplicity with Rust's sophisticated text rendering. The architecture splits responsibilities cleanly: Zig handles all UI logic (layout, widgets, events, accessibility) while Rust provides specialized rendering services (text measurement, text editing, GPU rendering via Vello).

See [THE_PLAN.md](THE_PLAN.md) for the complete architectural vision and implementation roadmap.

## Current Status

**M3 Complete** - Foundation is solid:
- ✅ Zig window with CAMetalLayer
- ✅ wgpu surface + Vello renderer
- ✅ Rounded rectangles with animation
- ✅ Text rendering with Parley + proper glyph positioning
- ✅ Command buffer architecture
- ✅ **Zig 0.15.1** with Nix flake development environment

**What's next:** Build the UI layer (IDs, focus, layout, widgets) on top of this foundation.

## Requirements

### Option 1: Using Nix (Recommended)
- [Nix](https://nixos.org/download.html) with flakes enabled
- macOS (for now - the project uses macOS frameworks)

### Option 2: Manual Setup
- **Zig 0.15.1** (exactly - build.zig uses 0.15 API)
- **Rust** (latest stable)
- **macOS** with Xcode Command Line Tools (`xcode-select --install`)

## Building and Running

### With Nix (Recommended)

The project includes a Nix flake that provides the exact development environment:

```bash
# Enter the development shell
nix develop --impure

# Build Rust renderer
cd rust/engine && cargo build --release && cd ../..

# Build and run Zig app
zig build run
```

The `--impure` flag is required on macOS to allow access to system frameworks via `SDKROOT`.

### Without Nix

Make sure you have **Zig 0.15.1** installed (check with `zig version`):

```bash
# Build Rust renderer
cd rust/engine
cargo build --release
cd ../..

# Build and run Zig app
zig build run
```

## Development

### Project Structure

```
zello/
├── src/
│   ├── main.zig              # Zig app entry point
│   └── objc/
│       └── metal_view.m      # Objective-C window/Metal setup
├── rust/engine/
│   └── src/
│       └── lib.rs            # Rust rendering backend (wgpu + Vello + Parley)
├── bindings/
│   └── mcore.h               # C API header (Zig ↔ Rust FFI)
├── build.zig                 # Zig build system
├── flake.nix                 # Nix development environment
└── THE_PLAN.md               # Complete architectural roadmap
```

### Building Components

```bash
# Rebuild just the Rust renderer
cd rust/engine && cargo build --release

# Rebuild just the Zig app (requires Rust lib to exist)
zig build

# Run without rebuilding
./zig-out/bin/zig_host_app
```

### The Nix Development Environment

The flake provides:
- **Zig 0.15.1** from mitchellh/zig-overlay
- **Rust** (latest from nixpkgs)
- **macOS SDK** via `SDKROOT` environment variable
- Isolated build caches to avoid conflicts

Environment details:
```bash
# Check what's available
nix develop --impure --command bash -c "zig version && rustc --version"

# The flake sets these automatically:
# - ZIG_GLOBAL_CACHE_DIR=./.zig-cache
# - SDKROOT=$(xcrun --show-sdk-path)
```

## Architecture Overview

### The Boundary

**Zig Territory (Future):**
- Layout engine (flexbox)
- ID management & focus state
- Hit testing & event routing
- Widget logic (buttons, containers, text inputs)
- Accessibility tree (via accesskit-c)
- Command buffer

**Rust Territory (Current):**
- Text measurement (Parley)
- Text editing state (UTF-8 handling, IME)
- GPU rendering (wgpu + Vello)
- Shape rendering (rounded rects, paths)

**The FFI Boundary:** C API in `bindings/mcore.h`
- Rust is a **specialized rendering backend**
- No concept of widgets or UI structure
- Receives draw commands + text events
- Returns text measurements + rendered frames

### Current Demo

The M3 demo (`src/main.zig`) shows:
- Animated rounded rectangle (color cycles with time)
- Text rendering via Parley
- Proper integration of Zig app ↔ Rust renderer

## Troubleshooting

### "Unable to find framework 'AppKit'"

You need to use `nix develop --impure` or set `SDKROOT` manually:
```bash
export SDKROOT=$(xcrun --show-sdk-path)
```

### "Wrong Zig version"

This project requires **Zig 0.15.1** exactly. Using Nix ensures the correct version:
```bash
nix develop --impure --command zig version  # Should show 0.15.1
```

### "Rust library not found"

Build the Rust renderer first:
```bash
cd rust/engine && cargo build --release
```

The Zig build expects the staticlib at `rust/engine/target/release/libmasonry_core_capi.a`

## Roadmap

See [THE_PLAN.md](THE_PLAN.md) for the complete phase-by-phase implementation plan:

- **Phase 1-2:** ID system + Focus + Flexbox layout (pure Zig) - *Next up*
- **Phase 3:** Command buffer (batched rendering)
- **Phase 4:** Text input state (Rust handles editing)
- **Phase 5:** Text selection (mouse + keyboard)
- **Phase 6:** IME composition (Japanese/Chinese input)
- **Phase 7:** Accessibility (VoiceOver support)

**Total estimated scope:** ~3500 LOC for complete toolkit

## Inspiration

- **Clay** - Immediate-mode layout library (C)
- **Dear ImGui** - Immediate-mode UI (C++)
- **Masonry** - Retained-mode UI (Rust) - *we borrow text editing logic*

Zello aims for the sweet spot: immediate-mode simplicity with sophisticated text and accessibility.

## License

[License TBD]
