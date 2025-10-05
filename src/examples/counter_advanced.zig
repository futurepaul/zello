const std = @import("std");
const zello = @import("../zello.zig");

// App state struct - organized and extensible
const AppState = struct {
    counter: i32 = 0,
    last_click_time: f64 = 0,
    total_clicks: u32 = 0,

    pub fn increment(self: *AppState, time: f64) void {
        self.counter += 1;
        self.last_click_time = time;
        self.total_clicks += 1;
    }

    pub fn decrement(self: *AppState, time: f64) void {
        self.counter -= 1;
        self.last_click_time = time;
        self.total_clicks += 1;
    }

    pub fn reset(self: *AppState) void {
        self.counter = 0;
    }
};

// Global state (you could also pass this through a context pointer)
var app_state = AppState{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 500, 400, "Advanced Counter", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(.{ 0.1, 0.1, 0.15, 1.0 }) catch {};

    // Single horizontal layout with everything in a row
    ui.beginHstack(.{ .gap = 15, .padding = 20 }) catch return;

    // Display counter and stats (combined into one label)
    var display_buf: [256]u8 = undefined;
    const display_text = std.fmt.bufPrintZ(
        &display_buf,
        "Count: {d}  |  Clicks: {d}  |  Last: {d:.2}s",
        .{ app_state.counter, app_state.total_clicks, app_state.last_click_time },
    ) catch "Counter";
    ui.label(display_text, .{ .size = 20 }) catch {};

    // Control buttons
    if (ui.button("+1", .{}) catch false) {
        app_state.increment(time);
    }

    if (ui.button("+10", .{}) catch false) {
        app_state.counter += 10;
        app_state.last_click_time = time;
        app_state.total_clicks += 1;
    }

    if (ui.button("-1", .{}) catch false) {
        app_state.decrement(time);
    }

    if (ui.button("Reset", .{}) catch false) {
        app_state.reset();
        app_state.total_clicks += 1;
    }

    ui.endHstack();
}
