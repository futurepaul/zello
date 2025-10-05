# Zig-hosted Window + Rust wgpu/Vello + `masonry_core`

*A step-by-step plan with concrete interfaces, build instructions, and validation checkpoints.*

---

## Goals

* **Host app in Zig**: create & own native windows (start with macOS), event loop, timers.
* **Rust engine**: one Rust crate that wraps `masonry_core` (+ Vello, Parley, AccessKit) and exposes a **minimal C ABI**.
* **Rendering**: Rust creates `wgpu::Surface/Device/Queue` from the **raw window handle** that Zig passes in, then renders with Vello.
* **Layout**: Zig provides an **immediate-mode façade** each frame; Rust diffs → retained tree in `masonry_core` for stable focus/a11y.
* **Accessibility**: Rust maintains an AccessKit tree; Zig hosts per-platform bridge (later).
* **MacOS first**, with clear seams for Windows/X11/Wayland.

---

## Architecture Overview

```
+------------------+           C ABI            +------------------------------+
|      Zig App     |  ───────────────────────▶  |        Rust Engine           |
|  - AppKit Window |                            |  - masonry_core retained UI  |
|  - NSView +      |        draw + layout       |  - Parley text shaping       |
|    CAMetalLayer  |  ◀───────────────────────  |  - Vello on wgpu render      |
|  - Event Loop    |   metrics, focus, hits     |  - AccessKit a11y            |
+------------------+                            +------------------------------+
        │                                                   │
        └──── native IME/clipboard, menus, etc. ────────────┘
```

* Zig **owns the window** and passes raw handles (e.g., `NSView*`, `CAMetalLayer*`) to Rust.
* Rust **owns GPU** (creates `Surface/Adapter/Device/Queue`) and all UI engine state.
* Zig calls a tiny **immediate mode** API per frame (`begin_frame`, `text`, `rect`, `image`, `end_frame`), and forwards input events (`mouse`, `key`, `ime`).
* Rust returns **hit-test** results, **layout metrics**, and **focus** transitions.

---

## Milestones & Checkpoints

1. **M0 – Build skeletons (1–2 hrs)**

   * Cargo crate compiles as `staticlib`.
   * Zig creates an `NSWindow` + `NSView` + `CAMetalLayer`.
   * **Checkpoint**: blank window; layer attached (verify with `layer.isAsynchronous = YES`, window resizes without errors).

2. **M1 – `create_surface` in Rust (0.5–1 day)**

   * Pass raw handles from Zig → Rust.
   * Rust makes `wgpu::Surface`, requests `Device/Queue`, clears to color.
   * **Checkpoint**: window shows a solid color frame, resizes correctly, no validation errors.

3. **M2 – Vello triangle/rect (0.5 day)**

   * Integrate Vello minimal scene and present.
   * **Checkpoint**: rounded rect rendering; animated color via a `time` uniform.

4. **M3 – Text shaping (1 day)**

   * Register a font from bytes, shape & draw a paragraph (Parley/Swash).
   * **Checkpoint**: “Hello, Zig/Rust” paragraph with correct metrics (DPI-aware) and line wrapping.

5. **M4 – Immediate façade + retained tree (1–2 days)**

   * Zig submits a per-frame “UI build”; Rust diffs into `masonry_core` tree.
   * **Checkpoint**: toggling a button in Zig updates visual & retains focus across frames.

6. **M5 – Input & focus (1 day)**

   * Map mouse/keyboard to Rust; focus ring & hit-test work.
   * **Checkpoint**: clicking a text field focuses it; typing inserts text.

7. **M6 – Accessibility (1–2 days)**

   * Build AccessKit tree in Rust; (optional) wire macOS bridge later.
   * **Checkpoint**: VoiceOver focus nav between two nodes; names/roles announced.

8. **M7 – Resize, DPI, IME (1 day)**

   * Handle scale factor changes and composition updates.
   * **Checkpoint**: live DPI change redraws crisp; IME composition underlines & caret.

---

## Rust Engine Crate

### Crate layout

```
rust/engine/
  Cargo.toml
  src/
    lib.rs
    c_api.rs          // #[no_mangle] extern "C" interface
    gfx.rs            // wgpu instance/surface/device/queue, swapchain
    scene.rs          // Vello scene building
    layout.rs         // masonry_core tree & diff
    text.rs           // Parley shaping helpers
    a11y.rs           // AccessKit adapter integration
    util/abi_types.rs // POD types shared with Zig header
```

### Cargo.toml (key bits)

```toml
[package]
name = "masonry_core_capi"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]  # produces libmasonry_core_capi.a

[dependencies]
masonry_core = "..."        # pin exact commit/tag you’ve tested
vello = "..."
wgpu = { version = "...", features = ["glsl", "metal", "dx12", "vulkan"] }
raw-window-handle = "0.6"
parley = "..."
swash = "..."
accesskit = "..."
accesskit_consumer = "..."  # as needed
# plus anyhow/thiserror, bytemuck, glam, etc.

[build-dependencies]
cbindgen = "0.26"
```

### C header generation (cbindgen)

* Add `build.rs` to emit `include/mcore.h`:

```rust
fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out = std::path::Path::new(&crate_dir).join("include/mcore.h");
    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_language(cbindgen::Language::C)
        .with_pragma_once(true)
        .with_sys_include("stddef.h")
        .generate()
        .expect("cbindgen")
        .write_to_file(out);
}
```

---

## C ABI (macOS-focused, cross-platform friendly)

### Shared types

```c
// mcore.h  (generated by cbindgen from Rust types, sketch shown)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mcore_context mcore_context_t;

typedef enum {
  MCORE_PLATFORM_MACOS = 1,
  MCORE_PLATFORM_WINDOWS = 2,
  MCORE_PLATFORM_X11 = 3,
  MCORE_PLATFORM_WAYLAND = 4
} mcore_platform_t;

typedef struct {
  void* ns_view;         // NSView*
  void* ca_metal_layer;  // CAMetalLayer*
  float scale_factor;    // backing scale
  int width_px;
  int height_px;
} mcore_macos_surface_t;

typedef struct {
  mcore_platform_t platform;
  union {
    mcore_macos_surface_t macos;
    // Windows/X11/Wayland in future
  } u;
} mcore_surface_desc_t;

// Simple color
typedef struct { float r,g,b,a; } mcore_rgba_t;

// Immediate ops (POD)
typedef struct { float x,y,w,h; float radius; mcore_rgba_t fill; } mcore_rounded_rect_t;

typedef struct {
  const void* data;
  size_t len;
  const char* name; // optional debug name
} mcore_font_blob_t;

// Text layout request/response (minimal)
typedef struct {
  const char* utf8;
  float wrap_width;
  float font_size_px;
  int font_id;
} mcore_text_req_t;

typedef struct {
  float advance_w;
  float advance_h;
  int line_count;
} mcore_text_metrics_t;

// Events (subset)
typedef enum { MOUSE_DOWN, MOUSE_UP, MOUSE_MOVE, MOUSE_WHEEL } mcore_mouse_type_t;
typedef struct { mcore_mouse_type_t ty; float x, y; int button; float wheel_dx, wheel_dy; } mcore_mouse_event_t;

typedef struct { int key_code; int mods; int is_down; } mcore_key_event_t;

// IME
typedef struct {
  const char* text;  // composed text
  int caret_utf16;   // caret index within composing text
  float caret_x, caret_y; // for popup positioning
} mcore_ime_update_t;

// Return codes
typedef enum { MCORE_OK = 0, MCORE_ERR = 1 } mcore_status_t;

#ifdef __cplusplus
}
#endif
```

### C ABI functions

```c
// Lifecycle
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void mcore_destroy(mcore_context_t* ctx);

// Resize/DPI
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Frame
void mcore_begin_frame(mcore_context_t* ctx, double time_seconds);
void mcore_rect_rounded(mcore_context_t* ctx, const mcore_rounded_rect_t* r);
void mcore_text_layout(mcore_context_t* ctx, const mcore_text_req_t* req, mcore_text_metrics_t* out);
void mcore_text_draw(mcore_context_t* ctx, const mcore_text_req_t* req, float x, float y, mcore_rgba_t color);
void mcore_end_frame_present(mcore_context_t* ctx, mcore_rgba_t clear);

// Resources
int mcore_font_register(mcore_context_t* ctx, const mcore_font_blob_t* blob);

// Input
void mcore_mouse(mcore_context_t* ctx, const mcore_mouse_event_t* e);
void mcore_key(mcore_context_t* ctx, const mcore_key_event_t* e);
void mcore_ime_update(mcore_context_t* ctx, const mcore_ime_update_t* ime);

// Query (optional early)
int  mcore_hit_test(mcore_context_t* ctx, float x, float y, int* out_node_id);
void mcore_set_focus(mcore_context_t* ctx, int node_id);

// Diagnostics
const char* mcore_last_error(void); // thread-local error string
```

> **Design notes**
>
> * All structs are **POD** and stable for FFI.
> * Rust returns only integers/handles; memory owned by Rust is never freed by Zig (no cross-allocator free).
> * `mcore_begin/end_frame` form the immediate façade; internally we diff → `masonry_core` retained tree.
> * `mcore_text_layout` provides measurement without drawing (handy for your Zig layout hints if you want).
> * `mcore_text_draw` draws using the last shaped layout or shapes on the fly; later you can add paragraph objects for reuse.

---

## Rust Side Key Steps

1. **Convert macOS handles → raw_window_handle**

   * Wrap `ns_view: *mut c_void` and `ca_metal_layer: *mut c_void` into `RawWindowHandle::AppKit` and set `ns_view` pointer.
   * Use `raw_display_handle::AppKitDisplayHandle` (macOS).

2. **Create `wgpu::Instance` and `Surface`**

   * `let instance = wgpu::Instance::default();`
   * `let surface = unsafe { instance.create_surface_unsafe(raw_display, raw_window) }?;`
   * Request adapter/device/queue with `Surface` compatible features.

3. **Vello renderer bootstrap**

   * Create Vello `Renderer` and per-frame `Scene`.
   * On `begin_frame`, clear `Scene`.
   * Each immediate op mutates `Scene` (e.g., add rounded rect path, fill; add text glyph runs).
   * `end_frame`: record commands, submit to queue, present.

4. **Text pipeline**

   * On `font_register`, add font data to a `FontBook`/provider.
   * `text_layout` uses Parley to shape UTF-8 string given font/size/wrap width; cache glyph runs keyed by (text, font_id, size, wrap).
   * `text_draw` converts glyph runs → Vello glyph draws (atlas/cache).

5. **masonry_core tree**

   * Build a transient “immediate nodes” buffer per frame (IDs stable via hashing the Zig callsite keys you pass or via a push/pop stack).
   * Diff → retained tree (`masonry_core`) to keep stable node IDs for focus/hit-test and a11y.
   * Attach rendering properties to nodes (style, text, images); draw traversal reads retained nodes into Vello Scene.

6. **Input & focus**

   * Map mouse/key/IME from Zig into `masonry_core` event model.
   * Hit-test uses retained boxes (post layout); returns node IDs to Zig if needed.

7. **Accessibility**

   * Mirror retained tree into an AccessKit tree with roles/names/rects.
   * Expose a function to get the AccessKit adapter pointer if the platform bridge needs it (optional at first).

8. **Resize/DPI**

   * On `mcore_resize`, update surface size, Vello target, and layout scale.

---

## Zig Side (macOS)

### Create window, view, and CAMetalLayer

* Use Zig’s Objective-C interop to:

  * Create `NSWindow` and a custom `NSView` subclass hosting a `CAMetalLayer`.
  * Set `wantsLayer = YES` and `view.layer = CAMetalLayer`.
  * On `viewDidChangeBackingProperties` or via KVO on `window.backingScaleFactor`, update `scale_factor`.
  * On `setFrame:`/resize, update `width_px/height_px`.

### Pass handles to Rust

* Obtain raw pointers:

  * `ns_view` → cast of your `NSView*`.
  * `ca_metal_layer` → `CAMetalLayer*` from `view.layer`.
* Fill `mcore_surface_desc_t` and call `mcore_create`.

### Event forwarding

* Mouse: on `mouseDown:`, `mouseUp:`, `mouseMoved:` etc., send `mcore_mouse`.
* Key: convert to a virtual key code set; send `mcore_key`.
* IME: implement `NSTextInputClient` on your view; forward composition updates via `mcore_ime_update` (text + caret rect in view coordinates).

### Frame loop

* Use a `CVDisplayLink` or a `CADisplayLink`/timer to tick ~60fps:

  * `mcore_begin_frame(ctx, now_s)`
  * Emit immediate ops (or your higher-level Zig widgets that wrap the ops).
  * `mcore_end_frame_present(ctx, clear_color)`

---

## Build & Link

### Rust → staticlib

```bash
cd rust/engine
cargo build --release
# artifacts: target/release/libmasonry_core_capi.a, include/mcore.h
```

### Zig build.zig (sketch)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_host_app",
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFile(.{ .file = .{ .path = "src/objc/metal_view.m" }, .flags = &[_][]const u8{
        "-fobjc-arc",
        "-framework", "AppKit",
        "-framework", "QuartzCore",
        "-framework", "Metal",
    }});

    exe.addIncludePath(.{ .path = "rust/engine/include" });
    exe.linkSystemLibrary("c++"); // if needed by Apple frameworks
    exe.addObjectFile(.{ .path = "rust/engine/target/release/libmasonry_core_capi.a" });

    // Apple frameworks
    exe.linkFramework("AppKit");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("Metal");
    // For IME/Accessibility later:
    // exe.linkFramework("Carbon"); // key codes if used
    // exe.linkFramework("ApplicationServices");

    exe.addIncludePath(.{ .path = "src" });
    exe.addModule("mcore", b.createModule(.{ .source_file = .{ .path = "bindings/mcore.zig" } }));

    exe.setMainPackagePath(.{ .path = "src" });
    exe.install();
}
```

### Zig bindings

* Create `bindings/mcore.zig` that `@cImport`s `mcore.h` and exposes nice Zig wrappers.

---

## Rendering “Hello Frame” (First Useful Demo)

**Zig main loop pseudocode**

```zig
const m = @cImport(@cInclude("mcore.h"));

pub fn main() !void {
    const app = try App.init(); // NSApp setup, window, view, layer
    var desc: m.mcore_surface_desc_t = .{
        .platform = m.MCORE_PLATFORM_MACOS,
        .u = .{ .macos = .{
            .ns_view = app.view_ptr,
            .ca_metal_layer = app.layer_ptr,
            .scale_factor = app.scale,
            .width_px = app.width_px,
            .height_px = app.height_px,
        }},
    };

    const ctx = m.mcore_create(&desc);
    if (ctx == null) return error.EngineCreateFailed;

    app.onResize = struct {
        pub fn cb(w: i32, h: i32, scale: f32) void {
            var d = desc;
            d.u.macos.width_px = w;
            d.u.macos.height_px = h;
            d.u.macos.scale_factor = scale;
            m.mcore_resize(ctx, &d);
        }
    }.cb;

    app.onFrame = struct {
        pub fn cb(t: f64) void {
            m.mcore_begin_frame(ctx, t);

            var rect = m.mcore_rounded_rect_t{
                .x = 40, .y = 40, .w = 200, .h = 100, .radius = 12,
                .fill = .{ .r=0.2, .g=0.4, .b=0.9, .a=1.0 },
            };
            m.mcore_rect_rounded(ctx, &rect);

            var req = m.mcore_text_req_t{
                .utf8 = "Hello, Zig/Rust!",
                .wrap_width = 400,
                .font_size_px = 18,
                .font_id = 0,
            };
            var metrics: m.mcore_text_metrics_t = undefined;
            m.mcore_text_layout(ctx, &req, &metrics);
            m.mcore_text_draw(ctx, &req, 50, 80, .{.r=1,.g=1,.b=1,.a=1});

            m.mcore_end_frame_present(ctx, .{.r=0,.g=0,.b=0,.a=1});
        }
    }.cb;

    app.run();
}
```

**Checkpoint (M2/M3):** A rounded rect and text render, crisp at any scale factor, resizing works.

---

## Event Mapping Table (macOS)

| AppKit                           | Zig→Rust                                                         |
| -------------------------------- | ---------------------------------------------------------------- |
| `mouseDown:` / `mouseUp:`        | `mcore_mouse({MOUSE_DOWN/UP, x,y, button})`                      |
| `mouseMoved:` / `mouseDragged:`  | `mcore_mouse({MOUSE_MOVE, x,y})`                                 |
| `scrollWheel:`                   | `mcore_mouse({MOUSE_WHEEL, wheel_dx, wheel_dy})`                 |
| `keyDown:` / `keyUp:`            | map to virtual key codes; `mcore_key({key_code, mods, is_down})` |
| `insertText:` / `setMarkedText:` | `mcore_ime_update({text, caret_utf16, caret_x, caret_y})`        |
| backing scale change             | call `mcore_resize` with new `scale_factor`                      |
| `setFrame:`                      | call `mcore_resize` with new `width_px/height_px`                |

> Keep all coordinates in **logical points** in Zig, but pass **pixel sizes** for surfaces. Provide the current `scale_factor` so Rust can map units correctly.

---

## Threading Model

* **AppKit** requires UI work on the **main thread**.
* Create the Rust engine on the main thread; it can spawn a render thread if desired, but keep **wgpu surface operations** on a consistent thread (Rust side enforces this).
* FFI calls from Zig → Rust happen on the main thread (safe). If you later run a render thread in Rust, buffer immediate ops and swap at frame boundaries.

---

## Error Handling & Diagnostics

* All Rust functions set a thread-local error string on failure; `mcore_last_error()` returns a `const char*` valid until the next call from that thread.
* In Zig, wrap each mcore call; on error print the message and `abort()` early in dev.
* Add a `mcore_enable_validation(true)` call (optional) to enable additional GPU validation layers in debug.

---

## Version Pinning

* Pin exact commits/versions of `wgpu`, `vello`, `parley`, `masonry_core`, and `raw-window-handle`.
* Vendor a `Cargo.lock` and document the last-known-good versions in this README.
* Keep your C ABI tiny; avoid leaking any Rust types or enums across the boundary.

---

## Tests & Sanity Tools

* **Headless glyph test**: in Rust, unit test shaping: given UTF-8 + font → glyph ranges/advances.
* **Rect packing test**: stress Vello with 10k rects; assert frame time < 16ms on target GPU.
* **Hit-test test**: create overlapping nodes, verify correct node IDs at sample points.

---

## Roadmap (Post-MVP)

* **Windows**: pass `HWND` (and `HINSTANCE`), map to `RawWindowHandle::Win32`, repeat M0–M3.
* **Linux**: GTK host (X11/Wayland); extract `wl_surface*`/`Display*+Window`.
* **AccessKit platform bridges**: wire macOS a11y (AXUIElement) via AccessKit’s adapters.
* **Images**: add `mcore_image_upload`, `mcore_image_draw`.
* **Paths**: expose `mcore_path_begin/line_to/quad_to/cubic_to/close/fill/stroke`.
* **Paragraph objects**: cache text paragraphs across frames for perf.
* **GPU interop**: optional shared textures exported to Zig for custom passes (down the line).

---

## Common Pitfalls & How We Avoid Them

* **ABI creep**: keep C API stable & narrow. Add new ops behind versioned functions.
* **Allocator mismatch**: never return ownership of Rust memory to Zig; return PODs or indices.
* **DPI mismatch**: pass both **pixel size** and **scale factor** on every resize; render in device pixels.
* **IME caret positioning**: always send caret rect in **view coordinates**; Rust maps to screen as needed for a11y.
* **Frame pacing**: if you see stutter, consider moving heavy scene build to a Rust worker and double-buffer the scene.

---

## Deliverables Checklist

* [ ] `rust/engine` staticlib builds (`libmasonry_core_capi.a`) + `include/mcore.h`.
* [ ] Zig macOS host app window with Metal layer.
* [ ] `mcore_create/resize/begin/end` wired; clear-color frame shows.
* [ ] Vello rounded rect demo.
* [ ] Font registration + Parley shaping + text draw.
* [ ] Immediate façade in Zig; retained focus through `masonry_core`.
* [ ] Mouse/key events mapped; hit-test passes.
* [ ] IME composition displays; caret follows.
* [ ] (Optional) AccessKit focusable nodes visible to VoiceOver.

---

## “If blocked, try this first” Playbook

* **Surface creation fails** → confirm `NSView` has a `CAMetalLayer` attached and `presentsWithTransaction = NO`; ensure the view is layer-backed.
* **Swapchain errors on resize** → call `mcore_resize` after view size updates settle (e.g., on next runloop tick).
* **Text missing** → ensure font blob lifetime (owned by Rust), correct UTF-8, and DPI scale applied to font size.
* **Stutter** → disable macOS App Nap, ensure presentation is driven once per display frame, profile for CPU path build.

---

Here’s a tiny, working “starter kit” you can drop into a repo to hit **M0 → M2**:

* Zig owns the **macOS** window & `CAMetalLayer`.
* Rust creates the **wgpu Surface/Device/Queue**, clears to a color (animated), and presents.
* Clean C ABI between them.
* Vello/Text hooks are stubbed so you can extend next.

---

# Files & layout

```
zig-rust-masonry/
├─ rust/engine/
│  ├─ Cargo.toml
│  ├─ build.rs
│  └─ src/
│     └─ lib.rs
├─ bindings/
│  └─ mcore.h                # hand-written starter header (cbindgen later)
├─ src/
│  ├─ main.zig
│  └─ objc/
│     └─ metal_view.m        # minimal NSApp/NSWindow/NSView + CAMetalLayer + frame timer
├─ build.zig
└─ README.md
```

---

# rust/engine/Cargo.toml

```toml
[package]
name = "masonry_core_capi"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]

[dependencies]
wgpu = { version = "0.20", features = ["metal", "dx12", "vulkan"] }
raw-window-handle = "0.6"
bytemuck = { version = "1.16", features = ["derive"] }
thiserror = "1"
parking_lot = "0.12"

[build-dependencies]
cbindgen = "0.26"
```

> Pin `wgpu` to what you’re comfortable with; `0.20` is just an example.

---

# rust/engine/build.rs

```rust
fn main() {
    // Optional for later: generate bindings/include/mcore.h with cbindgen.
    // For now we use a hand-written header in /bindings to get going.
    println!("cargo:rerun-if-changed=src/lib.rs");
}
```

---

# rust/engine/src/lib.rs

Minimal engine: creates a `Surface`, `Device`, and `Queue` from an `NSView`/`CAMetalLayer` handle, then clears to a color each frame.

```rust
use parking_lot::Mutex;
use raw_window_handle::{AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::ffi::c_void;
use std::sync::Arc;
use wgpu::util::DeviceExt;

#[derive(Debug, thiserror::Error)]
enum EngineError {
    #[error("wgpu error: {0}")]
    Wgpu(String),
    #[error("invalid surface")]
    InvalidSurface,
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}
fn set_err(e: impl std::fmt::Display) {
    LAST_ERROR.with(|s| *s.borrow_mut() = Some(e.to_string()));
}
#[no_mangle]
pub extern "C" fn mcore_last_error() -> *const i8 {
    use std::ffi::CString;
    LAST_ERROR.with(|s| {
        if let Some(msg) = s.borrow().as_ref() {
            // leak a CString for debugging simplicity (process lifetime)
            let c = CString::new(msg.clone()).unwrap();
            Box::leak(c.into_boxed_c_str()).as_ptr()
        } else {
            std::ptr::null()
        }
    })
}

#[repr(C)]
pub enum McorePlatform {
    MacOS = 1,
    Windows = 2,
    X11 = 3,
    Wayland = 4,
}

#[repr(C)]
pub struct McoreMacSurface {
    pub ns_view: *mut c_void,        // NSView*
    pub ca_metal_layer: *mut c_void, // CAMetalLayer*
    pub scale_factor: f32,
    pub width_px: i32,
    pub height_px: i32,
}

#[repr(C)]
pub union McoreSurfaceUnion {
    pub macos: McoreMacSurface,
}

#[repr(C)]
pub struct McoreSurfaceDesc {
    pub platform: McorePlatform,
    pub u: McoreSurfaceUnion,
}

struct Gfx {
    instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    size: (u32, u32),
    scale: f32,
}

impl Gfx {
    async fn new_macos(desc: &McoreMacSurface) -> Result<Self, EngineError> {
        // SAFETY: we trust the caller to pass a valid NSView* and CAMetalLayer*.
        // raw-window-handle only needs the NSView pointer populated.
        let mut win = AppKitWindowHandle::empty();
        win.ns_view = desc.ns_view as *mut std::ffi::c_void;
        let win = RawWindowHandle::AppKit(win);

        let disp = RawDisplayHandle::AppKit(AppKitDisplayHandle::empty());

        let instance = wgpu::Instance::default();
        // Unsafe: creating surface from raw handles is inherently unsafe.
        let surface = unsafe {
            instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: disp,
                    raw_window_handle: win,
                })
                .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?
        };

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .ok_or_else(|| EngineError::Wgpu("no adapter".into()))?;

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("mcore-device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::downlevel_defaults(),
                },
                None,
            )
            .await
            .map_err(|e| EngineError::Wgpu(format!("{e:?}")))?;

        let (w, h) = (desc.width_px.max(1) as u32, desc.height_px.max(1) as u32);
        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(caps.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: w,
            height: h,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        Ok(Self {
            instance,
            surface,
            adapter,
            device,
            queue,
            config,
            size: (w, h),
            scale: desc.scale_factor,
        })
    }

    fn resize(&mut self, w: u32, h: u32, scale: f32) {
        if w == 0 || h == 0 {
            return;
        }
        self.size = (w, h);
        self.scale = scale;
        self.config.width = w;
        self.config.height = h;
        self.surface.configure(&self.device, &self.config);
    }

    fn render_clear(&mut self, rgba: [f32; 4]) -> Result<(), EngineError> {
        let frame = self
            .surface
            .get_current_texture()
            .map_err(|e| EngineError::Wgpu(format!("acquire: {e:?}")))?;
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("mcore-encoder"),
            });

        {
            let _rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("mcore-clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: rgba[0] as f64,
                            g: rgba[1] as f64,
                            b: rgba[2] as f64,
                            a: rgba[3] as f64,
                        }),
                        store: true,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        frame.present();
        Ok(())
    }
}

struct Engine {
    gfx: Gfx,
    time_s: f64,
}

#[repr(C)]
pub struct McoreRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[repr(C)]
pub enum McoreStatus {
    Ok = 0,
    Err = 1,
}

#[repr(C)]
pub struct McoreContext(Arc<Mutex<Engine>>);

#[no_mangle]
pub extern "C" fn mcore_create(desc: *const McoreSurfaceDesc) -> *mut McoreContext {
    let desc = unsafe { desc.as_ref() }.unwrap();
    let ctx = match desc.platform {
        McorePlatform::MacOS => {
            let mac = unsafe { desc.u.macos };
            // block_on in a new thread so we don't block AppKit
            let engine = pollster::block_on(Gfx::new_macos(&mac))
                .map_err(|e| {
                    set_err(e);
                })
                .ok()?;
            let eng = Engine {
                gfx: engine,
                time_s: 0.0,
            };
            Box::into_raw(Box::new(McoreContext(Arc::new(Mutex::new(eng)))))
        }
        _ => {
            set_err("unsupported platform");
            std::ptr::null_mut()
        }
    };
    ctx
}

#[no_mangle]
pub extern "C" fn mcore_destroy(ctx: *mut McoreContext) {
    if !ctx.is_null() {
        unsafe { drop(Box::from_raw(ctx)) }
    }
}

#[no_mangle]
pub extern "C" fn mcore_resize(ctx: *mut McoreContext, desc: *const McoreSurfaceDesc) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let desc = unsafe { desc.as_ref() }.unwrap();
    if let McorePlatform::MacOS = desc.platform {
        let mac = unsafe { desc.u.macos };
        let mut guard = ctx.0.lock();
        guard
            .gfx
            .resize(mac.width_px.max(1) as u32, mac.height_px.max(1) as u32, mac.scale_factor);
    }
}

#[no_mangle]
pub extern "C" fn mcore_begin_frame(ctx: *mut McoreContext, time_seconds: f64) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();
    guard.time_s = time_seconds;
}

#[no_mangle]
pub extern "C" fn mcore_end_frame_present(ctx: *mut McoreContext, clear: McoreRgba) -> McoreStatus {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let mut guard = ctx.0.lock();

    // animate the clear a tiny bit so you know frames are ticking
    let t = guard.time_s as f32;
    let c = [
        (clear.r + 0.1 * (t).sin()).clamp(0.0, 1.0),
        (clear.g + 0.1 * (t * 1.3).sin()).clamp(0.0, 1.0),
        (clear.b + 0.1 * (t * 1.7).sin()).clamp(0.0, 1.0),
        clear.a,
    ];

    match guard.gfx.render_clear(c) {
        Ok(_) => McoreStatus::Ok,
        Err(e) => {
            set_err(e);
            McoreStatus::Err
        }
    }
}
```

> This is intentionally minimal: it proves the raw-handle → `wgpu::Surface` path and presentation. Vello + text can be layered next.

---

# bindings/mcore.h (starter hand-written header)

```c
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct mcore_context mcore_context_t;

typedef enum {
  MCORE_PLATFORM_MACOS = 1,
  MCORE_PLATFORM_WINDOWS = 2,
  MCORE_PLATFORM_X11 = 3,
  MCORE_PLATFORM_WAYLAND = 4,
} mcore_platform_t;

typedef struct {
  void* ns_view;        // NSView*
  void* ca_metal_layer; // CAMetalLayer*
  float scale_factor;
  int   width_px;
  int   height_px;
} mcore_macos_surface_t;

typedef union {
  mcore_macos_surface_t macos;
} mcore_surface_union_t;

typedef struct {
  mcore_platform_t platform;
  mcore_surface_union_t u;
} mcore_surface_desc_t;

typedef struct { float r,g,b,a; } mcore_rgba_t;

typedef enum { MCORE_OK = 0, MCORE_ERR = 1 } mcore_status_t;

// Lifecycle
mcore_context_t* mcore_create(const mcore_surface_desc_t* desc);
void             mcore_destroy(mcore_context_t* ctx);

// Resize/DPI
void mcore_resize(mcore_context_t* ctx, const mcore_surface_desc_t* desc);

// Frame
void mcore_begin_frame(mcore_context_t* ctx, double time_seconds);
mcore_status_t mcore_end_frame_present(mcore_context_t* ctx, mcore_rgba_t clear);

// Diagnostics
const char* mcore_last_error(void);

#ifdef __cplusplus
}
#endif
```

---

# src/objc/metal_view.m

A tiny AppKit host with a CAMetalLayer and a 60 fps timer that calls back into Zig.

```objective-c
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CVDisplayLink.h>

typedef void (*mv_frame_cb_t)(double t);
typedef void (*mv_resize_cb_t)(int w, int h, float scale);

static mv_frame_cb_t g_frame_cb = 0;
static mv_resize_cb_t g_resize_cb = 0;

@interface MVMetalView : NSView
@end

@implementation MVMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.wantsLayer = YES;
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
        self.layer = [CAMetalLayer layer];
    }
    CAMetalLayer *layer = (CAMetalLayer*)self.layer;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    layer.opaque = YES;
}
- (void)layout {
    [super layout];
    if (g_resize_cb) {
        NSRect b = self.bounds;
        CGFloat scale = self.window.backingScaleFactor;
        g_resize_cb((int)(b.size.width * scale), (int)(b.size.height * scale), (float)scale);
    }
}
@end

@interface MVApp : NSObject
@property(strong) NSWindow *window;
@property(strong) MVMetalView *view;
@property(strong) NSTimer *timer;
@end

@implementation MVApp
@end

static MVApp *GApp;

void* mv_app_init(int width, int height, const char* ctitle) {
    @autoreleasepool {
        if (!NSApp) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        GApp = [MVApp new];

        NSRect rect = NSMakeRect(100, 100, width, height);
        NSString *title = [NSString stringWithUTF8String:ctitle ?: "Zig Host"];
        GApp.window = [[NSWindow alloc] initWithContentRect:rect
                                                  styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable |
                                                             NSWindowStyleMaskMiniaturizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [GApp.window setTitle:title];

        GApp.view = [MVMetalView new];
        GApp.view.frame = ((NSView *)GApp.window.contentView).bounds;
        GApp.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [GApp.window setContentView:GApp.view];

        [GApp.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        // 60 fps timer
        GApp.timer = [NSTimer scheduledTimerWithTimeInterval:(1.0/60.0)
                                                      repeats:YES
                                                        block:^(__unused NSTimer *t) {
            static double t0 = 0;
            double now = CFAbsoluteTimeGetCurrent();
            if (t0 == 0) t0 = now;
            if (g_frame_cb) g_frame_cb(now - t0);
        }];
        return (__bridge void*)GApp;
    }
}

void* mv_get_ns_view(void) {
    return (__bridge void*)GApp.view;
}

void* mv_get_metal_layer(void) {
    return (__bridge void*)GApp.view.layer;
}

void mv_set_frame_callback(mv_frame_cb_t cb) {
    g_frame_cb = cb;
}

void mv_set_resize_callback(mv_resize_cb_t cb) {
    g_resize_cb = cb;
}

void mv_app_run(void) {
    [NSApp run];
}
```

---

# src/main.zig

Creates the window, initializes Rust, and draws animated clear frames.

```zig
const std = @import("std");

extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_get_ns_view() ?*anyopaque;
extern fn mv_get_metal_layer() ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.C) void) void;
extern fn mv_set_resize_callback(cb: *const fn (w: c_int, h: c_int, scale: f32) callconv(.C) void) void;
extern fn mv_app_run() void;

const c = @cImport({
    @cInclude("mcore.h");
});

var g_ctx: ?*c.mcore_context_t = null;
var g_desc: c.mcore_surface_desc_t = undefined;

fn on_resize(w: c_int, h: c_int, scale: f32) callconv(.C) void {
    g_desc.u.macos.width_px = w;
    g_desc.u.macos.height_px = h;
    g_desc.u.macos.scale_factor = scale;
    if (g_ctx) |ctx| {
        c.mcore_resize(ctx, &g_desc);
    }
}

fn on_frame(t: f64) callconv(.C) void {
    if (g_ctx) |ctx| {
        c.mcore_begin_frame(ctx, t);
        const clear = c.mcore_rgba_t{ .r = 0.15, .g = 0.15, .b = 0.20, .a = 1.0 };
        const st = c.mcore_end_frame_present(ctx, clear);
        if (st != c.MCORE_OK) {
            const err = c.mcore_last_error();
            if (err != null) std.debug.print("mcore error: {s}\n", .{std.mem.span(err)});
        }
    }
}

pub fn main() !void {
    _ = mv_app_init(900, 600, "Zig ⟷ Rust wgpu");
    const ns_view = mv_get_ns_view() orelse return error.NoView;
    const ca_layer = mv_get_metal_layer() orelse return error.NoLayer;

    // Fill surface desc
    g_desc = .{
        .platform = c.MCORE_PLATFORM_MACOS,
        .u = .{ .macos = .{
            .ns_view = ns_view,
            .ca_metal_layer = ca_layer,
            .scale_factor = 2.0,    // updated by resize callback
            .width_px = 900 * 2,    // starter values
            .height_px = 600 * 2,
        }},
    };

    g_ctx = c.mcore_create(&g_desc) orelse {
        const err = c.mcore_last_error();
        if (err != null) std.debug.print("create error: {s}\n", .{std.mem.span(err)});
        return error.EngineCreateFailed;
    };

    mv_set_resize_callback(on_resize);
    mv_set_frame_callback(on_frame);
    mv_app_run();
}
```

---

# build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_host_app",
        .target = target,
        .optimize = optimize,
    });

    // Zig sources
    exe.addCSourceFile(.{
        .file = .{ .path = "src/objc/metal_view.m" },
        .flags = &.{
            "-fobjc-arc",
        },
    });

    // Include path for mcore.h
    exe.addIncludePath(.{ .path = "bindings" });
    // Link the Rust staticlib
    exe.addObjectFile(.{ .path = "rust/engine/target/release/libmasonry_core_capi.a" });

    // Apple frameworks
    exe.linkFramework("AppKit");
    exe.linkFramework("QuartzCore");
    exe.linkFramework("Metal");
    exe.linkSystemLibrary("objc");

    exe.addAnonymousModule("root", .{ .source_file = .{ .path = "src/main.zig" }});
    exe.install();
}
```

---

# README.md (quick run)

````md
## Build Rust staticlib

```bash
cd rust/engine
cargo build --release
cd ../../
````

## Build & run Zig app (macOS)

```bash
zig build run
```

You should see a window with an animated clear color (subtle sine pulsing). Resizing the window should keep presenting without validation errors.

If you get a failure, check:

* `mcore_last_error()` printed in the Zig console
* Your view has a `CAMetalLayer` attached (the ObjC host does this)
* `width_px/height_px` are > 0 on creation and resize

````

---

## Next steps (quick pointers)

- **M2: Vello** — In `lib.rs`, add Vello’s `Renderer` and a simple scene (rounded rect). Use `render_clear` as a template: instead of a plain render pass, record Vello commands and draw to the same `TextureView`.
- **M3: Text** — Add font registration + Parley shaping in Rust; expose:
  ```c
  int  mcore_font_register(...);
  void mcore_text_layout(...);
  void mcore_text_draw(...);
````

* **Events** — In `metal_view.m`, forward mouse/key/IME to small C shims, and implement corresponding Rust handlers later.

---

This starter compiles down to the exact glue you need for “Zig owns the window, Rust owns wgpu.” When you’re ready, I can append the minimal Vello scene pass and a `mcore_rect_rounded` call so M2 (rounded rect) is just a drop-in.

