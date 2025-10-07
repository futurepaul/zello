// Zello - Immediate-mode UI toolkit in Zig
//
// Example usage:
// ```zig
// const zello = @import("zello");
//
// fn onFrame(ui: *zello.UI, time: f64) void {
//     ui.beginFrame();
//     defer ui.endFrame(.{0.1, 0.1, 0.15, 1.0}) catch {};
//
//     ui.beginVstack(.{ .gap = 20, .padding = 20 });
//
//     ui.label("Hello, Zello!", .{ .size = 24 });
//
//     if (ui.button("Click Me!", .{})) {
//         std.debug.print("Button clicked!\n", .{});
//     }
//
//     ui.endVstack();
// }
// ```

const std = @import("std");

// Core UI context
pub const UI = @import("ui/ui.zig").UI;

// Layout primitives (re-exported for advanced users)
pub const layout = @import("ui/layout.zig");

// Platform/app lifecycle
pub const App = @import("platform/app.zig").App;
pub const init = @import("platform/app.zig").init;
pub const run = @import("platform/app.zig").run;

// Widget options (re-exported for convenience)
pub const ButtonOptions = @import("ui/ui.zig").ButtonOptions;
pub const LabelOptions = @import("ui/ui.zig").LabelOptions;
pub const TextInputOptions = @import("ui/ui.zig").TextInputOptions;
pub const VstackOptions = @import("ui/ui.zig").VstackOptions;
pub const HstackOptions = @import("ui/ui.zig").HstackOptions;

// Image widget (re-exported for convenience)
pub const ImageOptions = @import("ui/ui.zig").ImageOptions;
pub const ImageInfo = @import("ui/ui.zig").ImageInfo;
pub const loadImageFile = @import("ui/ui.zig").loadImageFile;
pub const releaseImage = @import("ui/ui.zig").releaseImage;
pub const imageById = @import("ui/ui.zig").imageById;

// Custom widget API (for extensibility)
pub const WidgetContext = @import("ui/core/context.zig").WidgetContext;
pub const WidgetInterface = @import("ui/widget_interface.zig").WidgetInterface;
pub const CustomWidget = @import("ui/widget_interface.zig").CustomWidget;
pub const createWidgetInterface = @import("ui/widget_interface.zig").createInterface;
