const std = @import("std");
const layout_mod = @import("../layout.zig");
const context_mod = @import("../core/context.zig");
const state_mod = @import("../core/state.zig");
const a11y_mod = @import("../a11y.zig");
const c = @cImport({
    @cInclude("mcore.h");
});

/// Image widget options
pub const Options = struct {
    width: ?f32 = null, // Width (null = image natural width * scale)
    height: ?f32 = null, // Height (null = image natural height * scale)
    scale: f32 = 1.0, // Scale factor
    rotation_deg: f32 = 0.0, // Rotation in degrees
    id: ?[]const u8 = null, // Override auto-ID
};

/// State for an image widget (stores the image ID)
const ImageState = struct {
    image_id: i32,
    natural_width: f32,
    natural_height: f32,
};

/// Image info returned from loading
pub const ImageInfo = struct {
    id: i32,
    width: u32,
    height: u32,
};

/// Load an image from a file (JPEG, PNG, GIF, BMP, etc.)
/// Returns image info (id, width, height)
/// The image is automatically decoded to RGBA8
pub fn loadImageFile(
    ctx: *context_mod.WidgetContext,
    path: [:0]const u8,
) !ImageInfo {
    const info = c.mcore_image_load_file(@ptrCast(ctx.ctx), path.ptr);
    if (info.image_id < 0) {
        return error.ImageLoadFailed;
    }
    return ImageInfo{
        .id = info.image_id,
        .width = info.width,
        .height = info.height,
    };
}

/// Register an image from raw pixel data
/// Returns an image ID that can be used with the image widget
pub fn registerImage(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
    format: u8, // MCORE_IMAGE_FORMAT_*
    alpha_type: u8, // MCORE_IMAGE_ALPHA_*
) !i32 {
    const desc = c.mcore_image_desc_t{
        .data = pixels.ptr,
        .data_len = @intCast(pixels.len),
        .width = width,
        .height = height,
        .format = format,
        .alpha_type = alpha_type,
    };

    const id = c.mcore_image_register(@ptrCast(ctx.ctx), &desc);
    if (id < 0) {
        return error.ImageRegistrationFailed;
    }

    return id;
}

/// Helper: Register an RGBA8 image with straight alpha
pub fn registerImageRGBA8(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
) !i32 {
    return registerImage(
        ctx,
        pixels,
        width,
        height,
        c.MCORE_IMAGE_FORMAT_RGBA8,
        c.MCORE_IMAGE_ALPHA_ALPHA,
    );
}

/// Helper: Register an RGB8 image (no alpha)
pub fn registerImageRGB8(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
) !i32 {
    return registerImage(
        ctx,
        pixels,
        width,
        height,
        c.MCORE_IMAGE_FORMAT_RGB8,
        c.MCORE_IMAGE_ALPHA_OPAQUE,
    );
}

/// Release an image (decrement refcount)
pub fn releaseImage(ctx: *context_mod.WidgetContext, image_id: i32) void {
    c.mcore_image_release(@ptrCast(ctx.ctx), image_id);
}

/// Measure image dimensions
pub fn measure(
    ctx: *context_mod.WidgetContext,
    image_id: i32,
    natural_width: f32,
    natural_height: f32,
    opts: Options,
) layout_mod.Size {
    _ = ctx;
    _ = image_id;

    const scaled_width = natural_width * opts.scale;
    const scaled_height = natural_height * opts.scale;

    const width = opts.width orelse scaled_width;
    const height = opts.height orelse scaled_height;

    return .{ .width = width, .height = height };
}

/// Render image widget
pub fn render(
    ctx: *context_mod.WidgetContext,
    id: u64,
    image_id: i32,
    natural_width: f32,
    natural_height: f32,
    opts: Options,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) !void {
    _ = width;
    _ = height;

    // Register a11y node for the image
    var a11y_node = a11y_mod.Node.init(ctx.allocator, id, .Image, .{
        .x = x,
        .y = y,
        .width = natural_width * opts.scale,
        .height = natural_height * opts.scale,
    });
    a11y_node.setLabel("Image"); // TODO: Could add alt text to Options
    try ctx.addA11yNode(a11y_node);

    // Draw the image
    const transform = c.mcore_image_transform_t{
        .x = x,
        .y = y,
        .scale = opts.scale,
        .rotation_deg = opts.rotation_deg,
    };

    c.mcore_image_draw(@ptrCast(ctx.ctx), image_id, &transform);
}

/// High-level widget function: Draw an image by ID
/// This is the main entry point for using pre-registered images
pub fn imageById(
    ctx: *context_mod.WidgetContext,
    image_id: i32,
    natural_width: f32,
    natural_height: f32,
    opts: Options,
) !layout_mod.Size {
    const id_str = opts.id orelse "image";
    const id = ctx.getId(id_str);

    const size = measure(ctx, image_id, natural_width, natural_height, opts);

    if (try ctx.layoutItem(size)) |rect| {
        try render(ctx, id, image_id, natural_width, natural_height, opts, rect.x, rect.y, rect.w, rect.h);
    }

    return size;
}

/// High-level widget function: Draw an image from pixel data (registers on first use)
/// The image is registered once and cached in widget state
pub fn image(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
    format: u8,
    alpha_type: u8,
    opts: Options,
) !layout_mod.Size {
    const id_str = opts.id orelse "image";
    const id = ctx.getId(id_str);

    // Get or create state
    const state = ctx.state.get(ImageState, id) orelse blk: {
        // Register image on first use
        const image_id = try registerImage(ctx, pixels, width, height, format, alpha_type);

        const new_state = ImageState{
            .image_id = image_id,
            .natural_width = @floatFromInt(width),
            .natural_height = @floatFromInt(height),
        };

        ctx.state.set(id, new_state);
        break :blk new_state;
    };

    const size = measure(ctx, state.image_id, state.natural_width, state.natural_height, opts);

    if (try ctx.layoutItem(size)) |rect| {
        try render(ctx, id, state.image_id, state.natural_width, state.natural_height, opts, rect.x, rect.y, rect.w, rect.h);
    }

    return size;
}

/// Convenience function for RGBA8 images
pub fn imageRGBA8(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
    opts: Options,
) !layout_mod.Size {
    return image(
        ctx,
        pixels,
        width,
        height,
        c.MCORE_IMAGE_FORMAT_RGBA8,
        c.MCORE_IMAGE_ALPHA_ALPHA,
        opts,
    );
}

/// Convenience function for RGB8 images
pub fn imageRGB8(
    ctx: *context_mod.WidgetContext,
    pixels: []const u8,
    width: u32,
    height: u32,
    opts: Options,
) !layout_mod.Size {
    return image(
        ctx,
        pixels,
        width,
        height,
        c.MCORE_IMAGE_FORMAT_RGB8,
        c.MCORE_IMAGE_ALPHA_OPAQUE,
        opts,
    );
}
