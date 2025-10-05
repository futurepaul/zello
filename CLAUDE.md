# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## RULES

1. **WHEN YOU WRITE CODE, YOU MUST CHECK TO SEE IF IT COMPILES. YOU DO NOT SPRAY AND PRAY. IF THERE ARE RELEVANT TESTS RUN THOSE TOO.**
2. **ALWAYS BUILD IN THE NIX ENVIRONMENT** - Use `nix develop --impure` to ensure correct Zig version and environment.
3. **BUILD BOTH SIDES** - Changes may affect Rust (renderer) or Zig (app) or both. Build both to verify.

## Project Overview

**Zello** is an immediate-mode UI toolkit in Zig with a Rust rendering backend. The core principle: **Zig owns UI, Rust is a text specialist.**

- **Zig** handles all UI logic: layout, widgets, events, focus, accessibility
- **Rust** provides specialized services: text measurement, text editing, GPU rendering (wgpu + Vello)
- **FFI boundary** is a clean C API (`bindings/mcore.h`)

The project is currently at **M3** (foundation complete) and ready to build the UI layer on top.

## Development Environment

### Required: Nix Flake

**Always use the Nix development environment:**

```bash
# Enter the dev shell
nix develop --impure

# All builds should happen inside this shell
zig build
cargo build --release
```

The `--impure` flag is required on macOS to access system frameworks via `SDKROOT`.

### Why Nix?

- Guarantees **Zig 0.15.1** (project uses 0.15-specific APIs)
- Provides isolated build caches
- Sets up `SDKROOT` for macOS framework access
- Ensures reproducible builds

## Development Commands

### Build and Run

```bash
# Enter Nix shell first!
nix develop --impure

# Build Rust renderer (do this first, or after Rust changes)
cd rust/engine && cargo build --release && cd ../..

# Build Zig app
zig build

# Build and run
zig build run

# Clean build
rm -rf .zig-cache zig-out && zig build
```

### Code Quality

**Zig:**
```bash
zig build                    # Compilation is the check
zig fmt src/                 # Format Zig code
```

**Rust:**
```bash
cd rust/engine
cargo check                  # Fast compilation check
cargo clippy                 # Lint
cargo fmt                    # Format
```

### Debugging Build Issues

```bash
# Check Zig version (must be 0.15.1)
zig version

# Check SDKROOT is set
echo $SDKROOT

# Verbose build
zig build --verbose

# Check Rust lib exists
ls -lh rust/engine/target/release/libmasonry_core_capi.a
```

## Architecture

### The Sacred Boundary

**Zig Territory** (current and future):
- Window management (`src/objc/metal_view.m` - Objective-C)
- App lifecycle (`src/main.zig`)
- UI logic (IDs, focus, layout, widgets) - *to be implemented*
- Event routing - *to be implemented*
- Accessibility tree - *to be implemented*

**Rust Territory**:
- wgpu + Vello renderer (`rust/engine/src/lib.rs`)
- Text measurement via Parley
- Text editing state (UTF-8, cursor, selection) - *to be implemented*
- Shape rendering (rounded rects, paths, glyphs)

**FFI Boundary** (`bindings/mcore.h`):
- C API for all cross-language communication
- Rust exports functions with `#[no_mangle] pub extern "C"`
- Zig imports via `@cImport`
- **Design rule:** Rust has NO concept of widgets or UI structure

### Current FFI Functions

```c
// Context management
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void mcore_destroy(mcore_context_t* ctx);
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Frame lifecycle
void mcore_begin_frame(mcore_context_t* ctx, double time);
int mcore_end_frame_present(mcore_context_t* ctx, mcore_rgba_t clear);

// Drawing commands
void mcore_rect_rounded(mcore_context_t* ctx, const mcore_rounded_rect_t* rect);
void mcore_text_draw(mcore_context_t* ctx, const mcore_text_req_t* req,
                     float x, float y, mcore_rgba_t color);

// Error handling
const char* mcore_last_error(void);
```

### Module Organization

```
src/
   main.zig                   # Zig app entry point
   objc/
      metal_view.m            # macOS window + Metal layer setup
   ui/                        # Future: UI implementation
      id.zig                  # ID management (Phase 1)
      focus.zig               # Focus state (Phase 1)
      layout.zig              # Layout primitives (Phase 2)
      flex.zig                # Flexbox container (Phase 2)
      commands.zig            # Command buffer (Phase 3)
      widgets/                # Widget implementations (Phase 4+)

rust/engine/src/
   lib.rs                     # Main Rust entry point + FFI exports
   gfx.rs                     # wgpu + Vello rendering (future split)
   text.rs                    # Parley text layout (future split)
   text_input.rs              # Text editing state (Phase 4)

bindings/
   mcore.h                    # C API header (FFI boundary)
```

## Key Design Decisions

### Zig 0.15.1 API Changes

The project uses Zig 0.15.1 which has breaking changes from 0.14:

**Build System:**
- ✅ Use `root_module = b.createModule(...)` instead of `root_source_file`
- ✅ Use `target.result.os.tag == .macos` instead of `target.result.isDarwin()`
- ✅ Use `exe.root_module.addSystemFrameworkPath()` for frameworks
- ✅ Use `std.posix.getenv()` instead of `b.env_map.get()`

**Calling Conventions:**
- ✅ Use `.c` (lowercase) instead of `.C` for C calling convention
- Example: `fn callback() callconv(.c) void`

### macOS Framework Handling

The build system must:
1. Get `SDKROOT` from environment (set by Nix flake)
2. Add framework search path: `{SDKROOT}/System/Library/Frameworks`
3. Link frameworks: `AppKit`, `QuartzCore`, `Metal`
4. **Do NOT** link `objc` separately (included in AppKit)

See `build.zig` for the implementation.

### FFI Patterns

**Adding a new FFI function:**

1. Define C struct/function in `bindings/mcore.h`:
```c
typedef struct {
    float x, y, width, height;
} mcore_rect_t;

void mcore_new_function(mcore_context_t* ctx, const mcore_rect_t* rect);
```

2. Implement in Rust with `#[repr(C)]` and `#[no_mangle]`:
```rust
#[repr(C)]
pub struct McoreRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[no_mangle]
pub extern "C" fn mcore_new_function(
    ctx: *mut McoreContext,
    rect: *const McoreRect,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let rect = unsafe { rect.as_ref() }.unwrap();
    // ... implementation
}
```

3. Import and use in Zig:
```zig
const c = @cImport({
    @cInclude("mcore.h");
});

const rect = c.mcore_rect_t{ .x = 0, .y = 0, .width = 100, .height = 50 };
c.mcore_new_function(ctx, &rect);
```

4. **Build both sides and test:**
```bash
cd rust/engine && cargo build --release && cd ../..
zig build run
```

## Implementation Roadmap

See [THE_PLAN.md](THE_PLAN.md) for complete details. High-level phases:

### Phase 1: IDs + Focus (Pure Zig) - NEXT
- ID system with hash + stack
- Focus state management
- Tab navigation between widgets
- **No FFI changes needed**

### Phase 2: Flexbox Layout (Zig + Rust)
- Layout primitives (Rect, Size, BoxConstraints)
- Flexbox container (~300 LOC)
- **FFI:** Add `mcore_measure_text()` for text sizing

### Phase 3: Command Buffer (Zig + Rust)
- Batch draw commands in Zig
- Single FFI call per frame
- **FFI:** Add `mcore_render_commands()`

### Phase 4-7: Text Input, Selection, IME, Accessibility
- Text editing state moves to Rust
- Zig handles UI presentation only
- Each phase adds focused FFI functions

## Testing Strategy

### Compilation Tests
**ALWAYS compile after making changes:**

```bash
# Test Rust side
cd rust/engine && cargo check && cargo clippy

# Test Zig side
zig build

# Full integration test
zig build run
```

### Manual Testing
Run the app and verify:
- Window appears
- Animated rounded rect renders
- Text displays correctly
- No crashes or errors in console

### Future: Automated Tests
Once UI layer exists:
- Unit tests for layout algorithm
- Widget behavior tests
- Rendering snapshot tests (compare Vello output)

## Code Quality Standards

### Zig
- Use `zig fmt` for formatting (run on `src/` directory)
- Prefer explicit error handling (`try`, `catch`)
- Use `std.debug.print` for debug output
- Keep FFI calls in clear boundaries (don't scatter throughout)

### Rust
- Use `cargo fmt` and `cargo clippy`
- Wrap FFI pointers safely: `unsafe { ptr.as_mut() }.unwrap()`
- Use `parking_lot::Mutex` for interior mutability in FFI context
- Keep C API exports clean (no complex Rust types)

### FFI Boundary
- All structs must be `#[repr(C)]` in Rust
- Use simple C types: `f32`, `i32`, `*const`, `*mut`
- Document ownership clearly (who allocates/frees?)
- Prefer passing pointers to structs over many scalar args

## Common Pitfalls

### 1. Wrong Zig Version
**Symptom:** `error: no field named 'root_source_file'`
**Fix:** Use `nix develop --impure` to get Zig 0.15.1

### 2. Missing Rust Library
**Symptom:** `error: FileNotFound` when linking
**Fix:** `cd rust/engine && cargo build --release`

### 3. Framework Not Found
**Symptom:** `error: unable to find framework 'AppKit'`
**Fix:** Ensure in Nix shell with `--impure` flag, or set `SDKROOT` manually

### 4. Calling Convention Errors
**Symptom:** `error: union 'CallingConvention' has no member named 'C'`
**Fix:** Use lowercase `.c` not `.C` (Zig 0.15 change)

### 5. FFI Type Mismatch
**Symptom:** Crashes or garbage data
**Fix:** Verify `#[repr(C)]` in Rust and matching types in C header

## Key Files to Understand

1. **THE_PLAN.md** - Complete architectural vision and roadmap
2. **build.zig** - Zig build system (shows 0.15 API usage)
3. **src/main.zig** - Zig app entry point (current demo)
4. **src/objc/metal_view.m** - macOS window setup
5. **rust/engine/src/lib.rs** - Rust FFI exports and rendering
6. **bindings/mcore.h** - The sacred FFI boundary

## Next Steps (For Future Development)

When implementing Phase 1 (IDs + Focus):
1. Create `src/ui/id.zig` with hash functions
2. Create `src/ui/focus.zig` with focus state
3. No FFI changes needed - pure Zig
4. Update `main.zig` to use ID system
5. **Test by building and running**

When implementing Phase 2 (Layout):
1. Add `mcore_measure_text()` to FFI
2. Implement in Rust using existing Parley code
3. Create `src/ui/layout.zig` and `src/ui/flex.zig`
4. **Build both sides and test**

Always refer to THE_PLAN.md for detailed implementation guidance.
