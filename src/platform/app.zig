const std = @import("std");
const UI = @import("../ui/ui.zig").UI;
const a11y_mod = @import("../ui/a11y.zig");
const c_api = @import("../renderer/c_api.zig");
const c = c_api.c;

// Extern functions from metal_view.m
extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_get_ns_view() ?*anyopaque;
extern fn mv_get_metal_layer() ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.c) void) void;
extern fn mv_set_resize_callback(cb: *const fn (w: c_int, h: c_int, scale: f32) callconv(.c) void) void;
extern fn mv_set_key_callback(cb: *const fn (key: c_int, char_code: c_uint, shift: bool, cmd: bool) callconv(.c) void) void;
extern fn mv_set_mouse_callback(cb: *const fn (event_type: c_int, x: f32, y: f32) callconv(.c) void) void;
extern fn mv_set_scroll_callback(cb: *const fn (delta_x: f32, delta_y: f32) callconv(.c) void) void;
extern fn mv_set_ime_commit_callback(cb: *const fn (text: [*:0]const u8) callconv(.c) void) void;
extern fn mv_set_ime_preedit_callback(cb: *const fn (text: [*:0]const u8, cursor_offset: c_int) callconv(.c) void) void;
extern fn mv_set_ime_cursor_rect_callback(cb: *const fn () callconv(.c) ImeRect) void;
extern fn mv_app_run() void;
extern fn mv_clipboard_set_text(text: [*:0]const u8) void;
extern fn mv_clipboard_get_text(buffer: [*]u8, buffer_len: c_int) c_int;
extern fn mv_app_quit() void;
extern fn mv_trigger_initial_resize() void;

const ImeRect = extern struct { x: f32, y: f32, w: f32, h: f32 };

const MOUSE_DOWN: c_int = 0;
const MOUSE_UP: c_int = 1;
const MOUSE_MOVED: c_int = 2;

// Global state (unfortunately necessary for C callbacks)
var g_ui: *UI = undefined;
var g_ctx: *c.mcore_context_t = undefined;
var g_desc: c.mcore_surface_desc_t = undefined;
var g_frame_fn: *const fn (ui: *UI, time: f64) void = undefined;
var g_allocator: std.mem.Allocator = undefined;

// IME cursor tracking
var g_ime_cursor_x: f32 = 10;
var g_ime_cursor_y: f32 = 10;
var g_ime_cursor_h: f32 = 20;

pub const App = struct {
    ui: *UI,
    ctx: *c.mcore_context_t,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *App) void {
        self.ui.deinit();
        self.allocator.destroy(self.ui);
        c.mcore_destroy(self.ctx);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    title: [:0]const u8,
    frame_fn: *const fn (ui: *UI, time: f64) void,
) !App {
    g_allocator = allocator;
    g_frame_fn = frame_fn;

    // Initialize window
    _ = mv_app_init(@intCast(width), @intCast(height), title.ptr) orelse {
        return error.WindowInitFailed;
    };

    const ns_view = mv_get_ns_view() orelse return error.NoView;
    const ca_layer = mv_get_metal_layer() orelse return error.NoLayer;

    // Create surface description
    g_desc = .{
        .platform = c.MCORE_PLATFORM_MACOS,
        .u = .{
            .macos = .{
                .ns_view = ns_view,
                .ca_metal_layer = ca_layer,
                .scale_factor = 2.0,
                .width_px = @as(i32, @intCast(width)) * 2,
                .height_px = @as(i32, @intCast(height)) * 2,
            },
        },
    };

    // Create rendering context
    g_ctx = c.mcore_create(&g_desc) orelse {
        const err = c.mcore_last_error();
        if (err != null) std.debug.print("create error: {s}\n", .{std.mem.span(err)});
        return error.EngineCreateFailed;
    };

    // Create UI context
    const ui = try allocator.create(UI);
    ui.* = try UI.init(allocator, g_ctx, @floatFromInt(width), @floatFromInt(height));
    g_ui = ui;

    // Initialize accessibility
    a11y_mod.init(g_ctx, ns_view);
    c.mcore_a11y_set_action_callback(on_a11y_action);

    // Set up callbacks
    mv_set_resize_callback(on_resize);
    mv_set_key_callback(on_key);
    mv_set_mouse_callback(on_mouse);
    mv_set_scroll_callback(on_scroll);
    mv_set_ime_commit_callback(on_ime_commit);
    mv_set_ime_preedit_callback(on_ime_preedit);
    mv_set_ime_cursor_rect_callback(on_ime_cursor_rect);
    mv_set_frame_callback(on_frame);

    // Trigger initial resize to get actual window size
    mv_trigger_initial_resize();

    return .{
        .ui = ui,
        .ctx = g_ctx,
        .allocator = allocator,
    };
}

// Note: run() is a free function, not a method on App
pub fn run(_: App) void {
    mv_app_run();
}

// ============================================================================
// Callbacks (C calling convention)
// ============================================================================

fn on_frame(t: f64) callconv(.c) void {
    c.mcore_begin_frame(g_ctx, t);
    g_frame_fn(g_ui, t);
}

fn on_resize(w: c_int, h: c_int, scale: f32) callconv(.c) void {
    g_desc.u.macos.width_px = w;
    g_desc.u.macos.height_px = h;
    g_desc.u.macos.scale_factor = scale;

    const width_logical = @as(f32, @floatFromInt(w)) / scale;
    const height_logical = @as(f32, @floatFromInt(h)) / scale;
    g_ui.updateSize(width_logical, height_logical);

    c.mcore_resize(g_ctx, &g_desc);
}

fn on_key(key: c_int, char_code: c_uint, shift: bool, cmd: bool) callconv(.c) void {
    // Handle Cmd+Q to quit
    if (cmd and char_code == 'q') {
        mv_app_quit();
        return;
    }

    // Handle clipboard operations
    if (cmd) {
        handleClipboardOps(char_code);
        return;
    }

    // Forward to UI
    g_ui.handleKey(key, char_code, shift, cmd);
}

fn handleClipboardOps(char_code: c_uint) void {
    var clipboard_buf: [4096]u8 = undefined;

    if (char_code == 'a') {
        // Select All
        if (g_ui.focus.focused_id) |fid| {
            const len = c.mcore_text_input_get(g_ctx, fid, &clipboard_buf, 4096);
            if (len > 0) {
                c.mcore_text_input_set_cursor_pos(g_ctx, fid, 0, 0);
                c.mcore_text_input_set_cursor_pos(g_ctx, fid, len, 1);
            }
        }
    } else if (char_code == 'c') {
        // Copy
        if (g_ui.focus.focused_id) |fid| {
            const len = c.mcore_text_input_get_selected_text(g_ctx, fid, &clipboard_buf, 4096);
            if (len > 0) {
                clipboard_buf[@intCast(len)] = 0;
                mv_clipboard_set_text(@ptrCast(&clipboard_buf));
            }
        }
    } else if (char_code == 'x') {
        // Cut
        if (g_ui.focus.focused_id) |fid| {
            const len = c.mcore_text_input_get_selected_text(g_ctx, fid, &clipboard_buf, 4096);
            if (len > 0) {
                clipboard_buf[@intCast(len)] = 0;
                mv_clipboard_set_text(@ptrCast(&clipboard_buf));
                var event = c.mcore_text_event_t{
                    .kind = c.TEXT_EVENT_BACKSPACE,
                    .char_code = 0,
                    .direction = c.CURSOR_LEFT,
                    .extend_selection = 0,
                    .cursor_position = 0,
                    .text_ptr = null,
                };
                _ = c.mcore_text_input_event(g_ctx, fid, &event);
            }
        }
    } else if (char_code == 'v') {
        // Paste
        const len = mv_clipboard_get_text(&clipboard_buf, 4096);
        if (len > 0) {
            clipboard_buf[@intCast(len)] = 0;
            var event = c.mcore_text_event_t{
                .kind = c.TEXT_EVENT_INSERT_TEXT,
                .char_code = 0,
                .direction = c.CURSOR_LEFT,
                .extend_selection = 0,
                .cursor_position = 0,
                .text_ptr = @ptrCast(&clipboard_buf),
            };
            if (g_ui.focus.focused_id) |fid| {
                _ = c.mcore_text_input_event(g_ctx, fid, &event);
            }
        }
    }
}

fn on_mouse(event_type: c_int, x: f32, y: f32) callconv(.c) void {
    if (event_type == MOUSE_DOWN) {
        g_ui.handleMouseDown(x, y);
    } else if (event_type == MOUSE_UP) {
        g_ui.handleMouseUp(x, y);
    } else if (event_type == MOUSE_MOVED) {
        g_ui.handleMouseMove(x, y);
    }
}

fn on_scroll(delta_x: f32, delta_y: f32) callconv(.c) void {
    g_ui.handleScroll(delta_x, delta_y);
}

fn on_ime_commit(text: [*:0]const u8) callconv(.c) void {
    const focused_id = g_ui.focus.focused_id orelse return;
    c.mcore_ime_commit(g_ctx, focused_id, text);
}

fn on_ime_preedit(text: [*:0]const u8, cursor_offset: c_int) callconv(.c) void {
    const focused_id = g_ui.focus.focused_id orelse return;
    const preedit = c.mcore_ime_preedit_t{
        .text = text,
        .cursor_offset = cursor_offset,
    };
    c.mcore_ime_set_preedit(g_ctx, focused_id, &preedit);
}

fn on_ime_cursor_rect() callconv(.c) ImeRect {
    // Update cursor position from focused text input
    if (g_ui.focus.focused_id) |fid| {
        if (g_ui.state.text_inputs.get(fid)) |ti| {
            var text_buf: [256]u8 = undefined;
            const cursor_pos = c.mcore_text_input_cursor(g_ctx, fid);
            const text_len = c.mcore_text_input_get(g_ctx, fid, &text_buf, 256);
            const text_ptr: [*:0]const u8 = if (text_len > 0) @ptrCast(text_buf[0..@intCast(text_len)].ptr) else "";
            const cursor_offset_x = c.mcore_measure_text_to_byte_offset(g_ctx, text_ptr, 16, cursor_pos);

            g_ime_cursor_x = ti.x + 10 + cursor_offset_x - ti.scroll_offset;
            g_ime_cursor_y = ti.y;
            g_ime_cursor_h = ti.height;
        }
    }

    return ImeRect{
        .x = g_ime_cursor_x,
        .y = g_ime_cursor_y,
        .w = 2,
        .h = g_ime_cursor_h,
    };
}

fn on_a11y_action(widget_id: u64, action_code: u8) callconv(.c) void {
    switch (action_code) {
        0 => {
            // Focus action
            g_ui.focus.setFocus(widget_id);
        },
        1 => {
            // Click action
            g_ui.focus.setFocus(widget_id);
            // For buttons, we'd trigger the click here
            // But in immediate mode, the button will detect focus change next frame
        },
        else => {},
    }
}
