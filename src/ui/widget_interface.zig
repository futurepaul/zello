const std = @import("std");
const layout_mod = @import("layout.zig");
const context_mod = @import("core/context.zig");

/// Generic widget interface for custom widgets
/// This allows external code to create widgets that work seamlessly with the layout system
pub const WidgetInterface = struct {
    /// Measure the widget's desired size
    /// Called during the layout measurement pass
    measureFn: *const fn(ctx: *context_mod.WidgetContext, data: *const anyopaque, max_width: f32) layout_mod.Size,

    /// Render the widget at the given position and size
    /// Called during the rendering pass after layout is complete
    renderFn: *const fn(ctx: *context_mod.WidgetContext, data: *const anyopaque, x: f32, y: f32, width: f32, height: f32) anyerror!void,

    /// Optional cleanup function called when the widget is no longer needed
    /// Set to null if no cleanup is required
    deinitFn: ?*const fn(allocator: std.mem.Allocator, data: *anyopaque) void,
};

/// Type-erased widget data for custom widgets
pub const CustomWidget = struct {
    interface: *const WidgetInterface,
    data: *anyopaque,

    /// Create a custom widget from typed data
    pub fn init(comptime T: type, interface: *const WidgetInterface, data: *T) CustomWidget {
        return .{
            .interface = interface,
            .data = @ptrCast(data),
        };
    }

    /// Measure the widget
    pub fn measure(self: CustomWidget, ctx: *context_mod.WidgetContext, max_width: f32) layout_mod.Size {
        return self.interface.measureFn(ctx, self.data, max_width);
    }

    /// Render the widget
    pub fn render(self: CustomWidget, ctx: *context_mod.WidgetContext, x: f32, y: f32, width: f32, height: f32) !void {
        try self.interface.renderFn(ctx, self.data, x, y, width, height);
    }

    /// Clean up the widget (if deinitFn is provided)
    pub fn deinit(self: CustomWidget, allocator: std.mem.Allocator) void {
        if (self.interface.deinitFn) |deinitFn| {
            deinitFn(allocator, self.data);
        }
    }
};

/// Helper to create a widget interface at comptime for a given widget type
/// Usage:
///   pub const Interface = createInterface(MyWidgetData, measure, render, null);
pub fn createInterface(
    comptime T: type,
    comptime measureFn: fn(ctx: *context_mod.WidgetContext, data: *const T, max_width: f32) layout_mod.Size,
    comptime renderFn: fn(ctx: *context_mod.WidgetContext, data: *const T, x: f32, y: f32, width: f32, height: f32) anyerror!void,
    comptime deinitFn: ?fn(allocator: std.mem.Allocator, data: *T) void,
) WidgetInterface {
    const Wrapper = struct {
        fn measureErased(ctx: *context_mod.WidgetContext, data: *const anyopaque, max_width: f32) layout_mod.Size {
            const typed_data: *const T = @ptrCast(@alignCast(data));
            return measureFn(ctx, typed_data, max_width);
        }

        fn renderErased(ctx: *context_mod.WidgetContext, data: *const anyopaque, x: f32, y: f32, width: f32, height: f32) anyerror!void {
            const typed_data: *const T = @ptrCast(@alignCast(data));
            try renderFn(ctx, typed_data, x, y, width, height);
        }

        fn deinitErased(allocator: std.mem.Allocator, data: *anyopaque) void {
            const typed_data: *T = @ptrCast(@alignCast(data));
            if (deinitFn) |deinit| {
                deinit(allocator, typed_data);
            }
        }
    };

    return .{
        .measureFn = Wrapper.measureErased,
        .renderFn = Wrapper.renderErased,
        .deinitFn = if (deinitFn != null) Wrapper.deinitErased else null,
    };
}
