# Image Widget Design

## Overview

This document describes the design for image rendering in Zello. The approach uses **Zig-owned memory with Rust-side reference counting** to efficiently handle images in dynamic UIs like social feeds.

## Design Philosophy

### Core Principles

1. **Zig owns pixel data temporarily** - Pixels live in Zig memory during registration
2. **Rust owns images permanently** - Rust copies pixels once and manages the `peniko::Image` lifecycle
3. **Reference counting for GC** - Images are freed when no widgets reference them
4. **No per-frame copies** - Drawing uses cached images, zero copies per frame

### Why This Approach?

**Problem**: Vello's `peniko::Image` wraps `Arc<Blob>` which expects owned data. We can't use Zig pointers directly.

**Solution**: Copy pixels once during registration (like fonts), but add reference counting for lifecycle management.

**Tradeoff**:
- ✅ Zero copies per frame (fast drawing)
- ✅ Automatic memory management via refcounting
- ✅ Works naturally with Vello's API
- ⚠️ One copy during registration (acceptable - happens off render path)
- ⚠️ Manual retain/release in Zig (can be automated via RAII)

## FFI API

### C Header (`bindings/mcore.h`)

```c
/// Image descriptor for registration
typedef struct {
    const uint8_t* data;      // Pointer to pixel data (can be freed after register returns)
    uint32_t data_len;        // Total bytes: width * height * bytes_per_pixel
    uint32_t width;           // Image width in pixels
    uint32_t height;          // Image height in pixels
    uint8_t format;           // 0=Rgb8, 1=Rgba8
    uint8_t alpha_type;       // 0=Opaque, 1=Premul, 2=Alpha
} mcore_image_desc_t;

/// Register an image and copy pixel data to Rust
/// Returns an image ID (>= 0) or -1 on error
/// The `data` pointer can be freed after this function returns
int32_t mcore_image_register(mcore_context_t* ctx, const mcore_image_desc_t* desc);

/// Increment reference count (call when widget stores image ID)
void mcore_image_retain(mcore_context_t* ctx, int32_t image_id);

/// Decrement reference count, free when 0 (call in widget deinit)
void mcore_image_release(mcore_context_t* ctx, int32_t image_id);

/// Draw an image with transform
typedef struct {
    float x;
    float y;
    float scale;          // Uniform scale factor
    float rotation_deg;   // Rotation in degrees (0 = no rotation)
} mcore_image_transform_t;

void mcore_image_draw(mcore_context_t* ctx, int32_t image_id,
                      const mcore_image_transform_t* transform);
```

### Format Constants

```c
// mcore_image_desc_t.format
#define MCORE_IMAGE_FORMAT_RGB8  0
#define MCORE_IMAGE_FORMAT_RGBA8 1

// mcore_image_desc_t.alpha_type
#define MCORE_IMAGE_ALPHA_OPAQUE 0  // No alpha channel
#define MCORE_IMAGE_ALPHA_PREMUL 1  // Premultiplied alpha
#define MCORE_IMAGE_ALPHA_ALPHA  2  // Straight alpha
```

## Rust Implementation

### Engine Struct Extension

```rust
// In rust/engine/src/lib.rs

struct ImageEntry {
    image: peniko::Image,
    refcount: usize,
}

struct Engine {
    gfx: gfx::Gfx,
    scene: Scene,
    time_s: f64,
    text_cx: text::TextContext,
    fonts: Vec<(Vec<u8>, FontData)>,
    text_inputs: text_input::TextInputManager,
    a11y: Option<a11y::AccessibilityAdapter>,

    // NEW: Image storage
    images: HashMap<i32, ImageEntry>,
    next_image_id: i32,
}
```

### FFI Structs

```rust
#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreImageDesc {
    pub data: *const u8,
    pub data_len: u32,
    pub width: u32,
    pub height: u32,
    pub format: u8,
    pub alpha_type: u8,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreImageTransform {
    pub x: f32,
    pub y: f32,
    pub scale: f32,
    pub rotation_deg: f32,
}
```

### Registration

```rust
use peniko::{Blob, Image};
use std::collections::HashMap;
use std::sync::Arc;

#[no_mangle]
pub extern "C" fn mcore_image_register(
    ctx: *mut McoreContext,
    desc: *const McoreImageDesc,
) -> i32 {
    let ctx = unsafe { ctx.as_mut() };
    let desc = unsafe { desc.as_ref() };

    if ctx.is_none() || desc.is_none() {
        return -1;
    }

    let ctx = ctx.unwrap();
    let desc = desc.unwrap();
    let mut guard = ctx.0.lock();

    // Copy pixel data from Zig memory (Zig can free after this)
    let pixels = unsafe {
        std::slice::from_raw_parts(desc.data, desc.data_len as usize)
    };
    let pixel_vec = pixels.to_vec();

    // Create Blob (Arc-wrapped pixel data)
    let blob = Blob::new(Arc::new(pixel_vec));

    // Map format enum
    let format = match desc.format {
        0 => peniko::ImageFormat::Rgb8,
        1 => peniko::ImageFormat::Rgba8,
        _ => {
            set_err("Invalid image format");
            return -1;
        }
    };

    // Map alpha type enum
    let alpha_type = match desc.alpha_type {
        0 => peniko::ImageAlphaType::Opaque,
        1 => peniko::ImageAlphaType::Premul,
        2 => peniko::ImageAlphaType::Alpha,
        _ => {
            set_err("Invalid alpha type");
            return -1;
        }
    };

    // Create ImageData and convert to Image
    let image: Image = peniko::ImageData {
        data: blob,
        format,
        width: desc.width,
        height: desc.height,
        alpha_type,
    }.into();

    // Store with refcount = 1
    let id = guard.next_image_id;
    guard.next_image_id += 1;
    guard.images.insert(id, ImageEntry {
        image,
        refcount: 1
    });

    id
}
```

### Reference Counting

```rust
#[no_mangle]
pub extern "C" fn mcore_image_retain(
    ctx: *mut McoreContext,
    image_id: i32,
) {
    let ctx = unsafe { ctx.as_mut() };
    if ctx.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    if let Some(entry) = guard.images.get_mut(&image_id) {
        entry.refcount += 1;
    }
}

#[no_mangle]
pub extern "C" fn mcore_image_release(
    ctx: *mut McoreContext,
    image_id: i32,
) {
    let ctx = unsafe { ctx.as_mut() };
    if ctx.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let mut guard = ctx.0.lock();

    if let Some(entry) = guard.images.get_mut(&image_id) {
        entry.refcount -= 1;
        if entry.refcount == 0 {
            // Free the image memory
            guard.images.remove(&image_id);
        }
    }
}
```

### Drawing

```rust
#[no_mangle]
pub extern "C" fn mcore_image_draw(
    ctx: *mut McoreContext,
    image_id: i32,
    transform: *const McoreImageTransform,
) {
    let ctx = unsafe { ctx.as_mut() };
    let transform = unsafe { transform.as_ref() };

    if ctx.is_none() || transform.is_none() {
        return;
    }

    let ctx = ctx.unwrap();
    let transform = transform.unwrap();
    let mut guard = ctx.0.lock();

    // Look up image
    if let Some(entry) = guard.images.get(&image_id) {
        // Build affine transform
        use peniko::kurbo::Affine;

        let affine = Affine::scale(transform.scale as f64)
            .then_rotate((transform.rotation_deg as f64).to_radians())
            .then_translate((transform.x as f64, transform.y as f64).into());

        // Draw to scene (no copy, just reference)
        guard.scene.draw_image(&entry.image, affine);
    }
}
```

### Engine Initialization

```rust
// In mcore_create()
let eng = Engine {
    gfx: engine,
    scene: Scene::new(),
    time_s: 0.0,
    text_cx: text::TextContext::default(),
    fonts: Vec::new(),
    text_inputs: text_input::TextInputManager::new(),
    a11y: None,
    images: HashMap::new(),      // NEW
    next_image_id: 0,            // NEW
};
```

## Zig Implementation

### Image Widget

```zig
// In src/ui/widgets/image.zig

const std = @import("std");
const c = @cImport({
    @cInclude("mcore.h");
});

pub const Image = struct {
    image_id: i32,
    width: f32,
    height: f32,

    pub fn init(ctx: *c.mcore_context_t, pixels: []const u8, width: u32, height: u32) !Image {
        const desc = c.mcore_image_desc_t{
            .data = pixels.ptr,
            .data_len = @intCast(pixels.len),
            .width = width,
            .height = height,
            .format = 1, // RGBA8
            .alpha_type = 2, // Alpha (straight alpha)
        };

        const id = c.mcore_image_register(ctx, &desc);
        if (id < 0) {
            return error.ImageRegistrationFailed;
        }

        // Pixels can now be freed in Zig if desired
        // Rust has made its own copy

        return Image{
            .image_id = id,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
    }

    pub fn deinit(self: *Image, ctx: *c.mcore_context_t) void {
        c.mcore_image_release(ctx, self.image_id);
        self.image_id = -1;
    }

    pub fn draw(self: *const Image, ctx: *c.mcore_context_t, x: f32, y: f32, scale: f32) void {
        const transform = c.mcore_image_transform_t{
            .x = x,
            .y = y,
            .scale = scale,
            .rotation_deg = 0.0,
        };
        c.mcore_image_draw(ctx, self.image_id, &transform);
    }
};
```

### Usage Example

```zig
// In app code
const img = try Image.init(ctx, pixel_data, 256, 256);
defer img.deinit(ctx);

// Draw in frame
img.draw(ctx, 100.0, 100.0, 1.0);
```

### Widget Integration (Future)

When integrated into the widget system:

```zig
pub fn image(pixels: []const u8, width: u32, height: u32) Widget {
    const id = ui.id("image");

    // Store image_id in retained state
    var state = ui.getState(ImageState, id) orelse blk: {
        const img_id = c.mcore_image_register(ctx, ...);
        const new_state = ImageState{ .image_id = img_id };
        ui.setState(id, new_state);
        break :blk new_state;
    };

    // On widget removal, release is called automatically
    defer if (!ui.widgetExists(id)) {
        c.mcore_image_release(ctx, state.image_id);
    };

    // Draw during layout
    c.mcore_image_draw(ctx, state.image_id, &transform);
}
```

## Performance Characteristics

### Memory Usage

| Operation | Cost |
|-----------|------|
| **Registration** | 1× copy of pixel data (e.g., 4MB for 1024×1024 RGBA) |
| **Per-frame draw** | 0 copies, pointer lookup only |
| **Storage** | `sizeof(Image) + pixel_data` per unique image |
| **Refcount** | 8 bytes per image |

### Time Complexity

| Operation | Complexity |
|-----------|-----------|
| `mcore_image_register` | O(n) where n = pixel count (copy) |
| `mcore_image_retain` | O(1) HashMap lookup |
| `mcore_image_release` | O(1) HashMap lookup + remove |
| `mcore_image_draw` | O(1) HashMap lookup + Vello draw |

### Comparison to Alternatives

**Per-frame copy** (naive approach):
- ❌ 4MB copied every frame for 1024×1024 image
- ❌ 240 MB/sec at 60 FPS
- ❌ Unacceptable for multiple images

**This approach**:
- ✅ 4MB copied once during registration
- ✅ 0 bytes copied per frame
- ✅ Scales to hundreds of images

## Future Optimizations

### 1. Content-Addressed Deduplication

**Problem**: Same image loaded multiple times wastes memory.

**Solution**: Hash pixel data, reuse existing image.

```rust
struct Engine {
    images: HashMap<i32, ImageEntry>,
    image_hashes: HashMap<u64, i32>,  // hash -> id
    // ...
}

fn mcore_image_register(desc: &McoreImageDesc) -> i32 {
    let hash = hash_pixels(desc.data, desc.data_len);

    // Check if we already have this image
    if let Some(&existing_id) = guard.image_hashes.get(&hash) {
        guard.images.get_mut(&existing_id).unwrap().refcount += 1;
        return existing_id;  // Reuse!
    }

    // Create new...
    let id = create_new_image(desc);
    guard.image_hashes.insert(hash, id);
    id
}
```

**Benefit**: Avatar images, repeated icons, etc. stored only once.

### 2. LRU Cache with Auto-Eviction

**Problem**: Infinite scrolling feed loads unbounded images.

**Solution**: Cap cache size, evict LRU when full.

```rust
struct ImageCache {
    max_images: usize,
    lru: LinkedHashMap<i32, (Image, Instant)>,
}

fn mcore_image_register(...) {
    if cache.len() >= max_images {
        // Evict oldest
        let (old_id, _) = cache.pop_front().unwrap();
    }
    // ...
}
```

**Benefit**: Bounded memory usage for infinite feeds.

### 3. Async Image Loading

**Current**: Zig loads pixels, blocks on registration.

**Future**: Background loading thread.

```zig
pub fn loadImageAsync(path: []const u8, callback: fn(Image) void) void {
    // Spawn thread, decode, register, callback on main thread
}
```

### 4. GPU-Resident Images (Advanced)

**Current**: Vello uploads to GPU each frame.

**Future**: Keep decoded textures on GPU between frames.

Requires changes to Vello/wgpu integration - out of scope for now.

## Error Handling

### Rust Errors

| Error | Condition | Return Value |
|-------|-----------|--------------|
| Invalid format | `format > 1` | `-1` |
| Invalid alpha type | `alpha_type > 2` | `-1` |
| Null pointer | `ctx` or `desc` is null | `-1` |
| Allocation failure | Out of memory | `-1` |

### Zig Errors

```zig
pub const ImageError = error{
    ImageRegistrationFailed,
    InvalidImageId,
};
```

Use `try` for error propagation:
```zig
const img = try Image.init(ctx, pixels, 256, 256);
```

## Testing Strategy

### Unit Tests (Rust)

```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_image_refcount() {
        // Register image
        let id = mcore_image_register(...);
        assert_eq!(engine.images[&id].refcount, 1);

        // Retain
        mcore_image_retain(ctx, id);
        assert_eq!(engine.images[&id].refcount, 2);

        // Release
        mcore_image_release(ctx, id);
        assert_eq!(engine.images[&id].refcount, 1);

        // Final release should free
        mcore_image_release(ctx, id);
        assert!(!engine.images.contains_key(&id));
    }
}
```

### Integration Tests (Zig)

```zig
test "image lifecycle" {
    const pixels = [_]u8{255} ** (4 * 256 * 256);
    var img = try Image.init(ctx, &pixels, 256, 256);
    defer img.deinit(ctx);

    img.draw(ctx, 0, 0, 1.0);
    // Should not crash
}
```

### Manual Tests

1. **Feed scroll test**: Load 1000 images, scroll, verify memory doesn't grow unbounded
2. **Duplicate test**: Load same image 100 times, verify only 1 copy in memory (with dedup)
3. **Leak test**: Load/unload 10000 images, verify memory returns to baseline

## Implementation Checklist

- [ ] Add FFI structs to `bindings/mcore.h`
- [ ] Add `images` HashMap to `Engine` struct
- [ ] Implement `mcore_image_register`
- [ ] Implement `mcore_image_retain`
- [ ] Implement `mcore_image_release`
- [ ] Implement `mcore_image_draw`
- [ ] Add `Image` widget to `src/ui/widgets/image.zig`
- [ ] Write Rust unit tests
- [ ] Write Zig integration test
- [ ] Build and test with demo app
- [ ] (Optional) Add content-addressed deduplication
- [ ] (Optional) Add LRU cache with eviction

## Open Questions

1. **Image decoding**: Should Zig decode (PNG/JPEG) or pass encoded bytes to Rust?
   - **Recommendation**: Zig decodes. Keeps Rust FFI simple (just raw pixels).
   - Use `stb_image` or similar in Zig.

2. **Color space**: sRGB assumed? HDR support?
   - **Recommendation**: Start with sRGB, add HDR later if needed.

3. **Mipmaps**: Do we need mipmap generation for scaled images?
   - **Recommendation**: Not yet. Vello handles scaling. Add if quality issues arise.

4. **Animated images** (GIF, APNG): How to handle?
   - **Recommendation**: Out of scope for MVP. Can add frame array later.

## References

- [Vello Scene API](https://docs.rs/vello/latest/vello/struct.Scene.html)
- [Peniko Image Types](https://docs.rs/peniko/latest/peniko/)
- [Vello Example Code](https://github.com/linebender/vello/tree/main/examples)
- Font registration pattern: `src/lib.rs:299` (`mcore_font_register`)
