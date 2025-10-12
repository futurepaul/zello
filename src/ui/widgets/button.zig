const std = @import("std");
const layout_mod = @import("../layout.zig");
const layout_utils = @import("../layout_utils.zig");
const context_mod = @import("../core/context.zig");
const state_mod = @import("../core/state.zig");
const a11y_mod = @import("../a11y.zig");
const color_mod = @import("../color.zig");
const Color = color_mod.Color;

/// Button widget options
pub const Options = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null, // Override auto-ID

    // Style properties
    bg_color: ?Color = null, // Background color (null = use default)
    hover_color: ?Color = null, // Hover state color (null = auto-lighten)
    active_color: ?Color = null, // Pressed state color (null = auto-darken)
    text_color: ?Color = null, // Text color (null = white)
    border_color: ?Color = null, // Border color (null = no border)
    border_width: f32 = 1,
    radius: f32 = 8,
    shadow: ?color_mod.Shadow = null, // Drop shadow (null = no shadow)
};

/// Measure button dimensions
pub fn measure(ctx: *context_mod.WidgetContext, text: [:0]const u8, opts: Options) layout_mod.Size {
    const padding_x: f32 = 20;
    const padding_y: f32 = 15;
    const font_size: f32 = 18;

    const text_size = ctx.measureText(text, font_size, 1000);
    const width = opts.width orelse (text_size.width + padding_x * 2);
    const height = opts.height orelse (text_size.height + padding_y * 2);

    return .{ .width = width, .height = height };
}

/// Render button widget
pub fn render(
    ctx: *context_mod.WidgetContext,
    id: u64,
    text: [:0]const u8,
    opts: Options,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) !void {
    // Register as focusable
    try ctx.registerFocusable(id);
    const is_focused = ctx.isFocused(id);

    // Check if hovered or pressed
    const bounds = layout_mod.Rect{ .x = x, .y = y, .width = width, .height = height };
    const is_hovered = ctx.isHovered(bounds);
    const is_pressed = ctx.isPressed(bounds);

    // Determine background color (use custom or defaults with visual states)
    const base_bg = opts.bg_color orelse color_mod.BLACK;
    const hover_bg = opts.hover_color orelse color_mod.lerp(base_bg, color_mod.WHITE, 0.2);
    const active_bg = opts.active_color orelse color_mod.lerp(base_bg, color_mod.WHITE, 0.3);

    const bg_color = if (is_pressed)
        active_bg
    else if (is_hovered)
        hover_bg
    else if (is_focused)
        color_mod.lerp(base_bg, color_mod.WHITE, 0.15) // Slightly lighter when focused
    else
        base_bg;

    // Draw styled rect (with optional border and shadow)
    const cmd_buffer = ctx.commandBuffer();
    try cmd_buffer.styledRect(
        x,
        y,
        width,
        height,
        opts.radius,
        bg_color,
        opts.border_color,
        opts.border_width,
        opts.shadow,
    );

    // Draw text (centered, safely copied to frame arena)
    const font_size: f32 = 18;
    const text_size = ctx.measureText(text, font_size, 1000);
    const text_x = x + (width - text_size.width) / 2.0;
    const text_y = y + (height - text_size.height) / 2.0;
    const text_color = opts.text_color orelse color_mod.WHITE;
    try ctx.drawText(text, text_x, text_y, font_size, text_size.width, text_color);

    // Register clickable for next frame (includes bounds for hit testing)
    try ctx.registerClickable(id, .Button, bounds);

    // Debug bounds (green for buttons)
    ctx.drawDebugRect(x, y, width, height, color_mod.rgba(0, 1, 0, 0.9));

    // Add to accessibility tree
    var a11y_node = a11y_mod.Node.init(ctx.allocator, id, .Button, .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    });
    a11y_node.setLabel(text);
    a11y_node.addAction(a11y_mod.Actions.Focus);
    a11y_node.addAction(a11y_mod.Actions.Click);
    try ctx.addA11yNode(a11y_node);
}
