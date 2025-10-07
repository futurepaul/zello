# Image Loading and Display Usage

## Quick Start: Load a JPEG/PNG Image

The simplest way to load and display an image:

```zig
const ui = @import("ui");

// In your UI code:
pub fn build(ui_ctx: *ui.UI) !void {
    // Create a widget context
    var widget_ctx = ui_ctx.createWidgetContext();

    // Load image from file (JPEG, PNG, GIF, BMP, etc.)
    const image_id = try ui.loadImageFile(&widget_ctx, "src/examples/waffle_dog.jpeg");
    defer ui.releaseImage(&widget_ctx, image_id);

    try ui_ctx.beginVstack(.{});

    // Display the image (currently needs manual implementation)
    // TODO: Add imageById widget function

    ui_ctx.endVstack();
}
```

## Current Implementation Status

### ✅ Working
- **Image decoding**: JPEG, PNG, GIF, BMP automatically decoded to RGBA8
- **Image loading**: `loadImageFile(ctx, path)`
- **Image registration**: Raw pixels → GPU-ready image data
- **Image drawing**: FFI `mcore_image_draw()` with transforms (scale, rotation, position)
- **Reference counting**: Automatic memory management via `releaseImage()`

### 🚧 To Implement
- **Widget integration**: Need to add image dimensions to return value
- **imageById widget**: Convenience function for layout integration

## Manual Drawing (Advanced)

If you need more control, you can use the lower-level API:

```zig
// Load and get ID
const image_id = try ui.loadImageFile(&widget_ctx, "path/to/image.jpeg");

// Draw manually with transform
const transform = c.mcore_image_transform_t{
    .x = 100,
    .y = 100,
    .scale = 1.0,
    .rotation_deg = 0,
};
c.mcore_image_draw(ctx.mcore_ctx, image_id, &transform);

// Clean up when done
ui.releaseImage(&widget_ctx, image_id);
```

## Next Steps

To make images work with the layout system, we need to:

1. **Return image dimensions** from `mcore_image_load_file()`
   - Currently it only returns the image ID
   - Need to return width/height so Zig can do layout

2. **Add `imageById()` widget function**
   - Similar to existing widgets (label, button, etc.)
   - Integrates with layout system (Vstack/Hstack)

3. **Add state management**
   - Cache loaded images in widget state
   - Avoid reloading same image every frame

## Example Implementation Plan

```zig
// In image.zig:
pub fn imageById(
    ctx: *context_mod.WidgetContext,
    image_id: i32,
    natural_width: f32,
    natural_height: f32,
    opts: Options,
) !layout_mod.Size {
    // ... existing implementation already works!
}

// What we need in C header:
typedef struct {
    int image_id;
    unsigned int width;
    unsigned int height;
} mcore_image_info_t;

mcore_image_info_t mcore_image_load_file_with_info(
    mcore_context_t* ctx,
    const char* path
);
```

## Performance Notes

- **One-time copy**: Image pixels copied once during load/registration
- **Zero copies per frame**: Drawing uses cached GPU data
- **Efficient format**: All images converted to RGBA8 for uniform handling
- **Reference counting**: Images freed when refcount hits 0

## Supported Formats

Via the `image` crate (0.25):
- JPEG
- PNG
- GIF
- BMP
- TIFF
- WebP
- And more!

All formats are automatically decoded to RGBA8.
