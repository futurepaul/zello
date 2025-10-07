const std = @import("std");
const layout_mod = @import("../layout.zig");
const context_mod = @import("../core/context.zig");
const color_mod = @import("../color.zig");
const Color = color_mod.Color;

/// Label widget options
pub const Options = struct {
    size: f32 = 16,
    color: Color = color_mod.rgba(1, 1, 1, 1),
    bg_color: ?Color = null, // null = no background
    padding: f32 = 8,
};

/// Measure label dimensions
pub fn measure(ctx: *context_mod.WidgetContext, text: [:0]const u8, opts: Options, max_width: f32) layout_mod.Size {
    const text_size = ctx.measureText(text, opts.size, max_width);
    return .{
        .width = text_size.width + opts.padding * 2,
        .height = text_size.height + opts.padding * 2,
    };
}

/// Render label widget
pub fn render(
    ctx: *context_mod.WidgetContext,
    text: [:0]const u8,
    opts: Options,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) !void {
    // Draw background if specified
    const cmd_buffer = ctx.commandBuffer();
    if (opts.bg_color) |bg| {
        try cmd_buffer.roundedRect(x, y, width, height, 4, bg);
    }

    // Draw text
    const text_x = x + opts.padding;
    const text_y = y + opts.padding;
    const text_width = width - opts.padding * 2;
    try cmd_buffer.text(text, text_x, text_y, opts.size, text_width, opts.color);

    // Debug bounds (cyan for labels)
    ctx.drawDebugRect(x, y, width, height, color_mod.rgba(0, 1, 1, 0.8));
}
