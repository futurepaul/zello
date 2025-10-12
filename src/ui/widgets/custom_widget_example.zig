/// Example custom widget demonstrating the extensibility system
/// This shows how external developers can create their own widgets
/// without modifying the core UI code.
const std = @import("std");
const layout_mod = @import("../layout.zig");
const context_mod = @import("../core/context.zig");
const widget_interface = @import("../widget_interface.zig");
const color_mod = @import("../color.zig");

/// Widget data - this is what you store for your custom widget
pub const BadgeData = struct {
    text: [:0]const u8,
    bg_color: color_mod.Color,
    text_color: color_mod.Color,
    padding: f32 = 8,
};

/// Widget interface - this is how you tell the UI system how to measure and render your widget
pub const Interface: widget_interface.WidgetInterface = widget_interface.createInterface(
    BadgeData,
    measure,
    render,
    null, // No cleanup needed
);

/// Measure function - calculate the widget's size
fn measure(ctx: *context_mod.WidgetContext, data: *const BadgeData, max_width: f32) layout_mod.Size {
    const content_max = @max(0, max_width - data.padding * 2);
    const text_size = ctx.measureText(data.text, 14, content_max);
    return .{
        .width = @min(text_size.width + data.padding * 2, max_width),
        .height = text_size.height + data.padding * 2,
    };
}

/// Render function - draw the widget
fn render(
    ctx: *context_mod.WidgetContext,
    data: *const BadgeData,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) !void {
    const cmd_buffer = ctx.commandBuffer();

    // Draw rounded rectangle background
    try cmd_buffer.roundedRect(x, y, width, height, height / 2, data.bg_color);

    // Draw text centered
    const content_width = @max(0, width - data.padding * 2);
    const text_size = ctx.measureText(data.text, 14, content_width);
    const text_x = x + (width - text_size.width) / 2.0;
    const text_y = y + (height - text_size.height) / 2.0;
    try ctx.drawText(data.text.ptr, text_x, text_y, 14, content_width, data.text_color);

    // Debug bounds
    ctx.drawDebugRect(x, y, width, height, color_mod.rgba(1, 0.5, 0, 0.9));
}

// ============================================================================
// Example usage (this would be in your application code)
// ============================================================================

/// Example function showing how to use the custom widget
pub fn exampleUsage(ui: anytype) !void {
    // Create widget data (stack-allocated, no heap needed)
    var badge_data = BadgeData{
        .text = "NEW",
        .bg_color = color_mod.rgba(1, 0, 0, 1),
        .text_color = color_mod.WHITE,
        .padding = 10,
    };

    // Add it to the UI just like any built-in widget!
    try ui.customWidget(&Interface, &badge_data);
}
