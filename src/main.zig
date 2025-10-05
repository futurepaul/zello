const std = @import("std");

extern fn mv_app_init(width: c_int, height: c_int, title: [*:0]const u8) ?*anyopaque;
extern fn mv_get_ns_view() ?*anyopaque;
extern fn mv_get_metal_layer() ?*anyopaque;
extern fn mv_set_frame_callback(cb: *const fn (t: f64) callconv(.C) void) void;
extern fn mv_set_resize_callback(cb: *const fn (w: c_int, h: c_int, scale: f32) callconv(.C) void) void;
extern fn mv_app_run() void;

const c = @cImport({
    @cInclude("mcore.h");
});

var g_ctx: ?*c.mcore_context_t = null;
var g_desc: c.mcore_surface_desc_t = undefined;

fn on_resize(w: c_int, h: c_int, scale: f32) callconv(.C) void {
    g_desc.u.macos.width_px = w;
    g_desc.u.macos.height_px = h;
    g_desc.u.macos.scale_factor = scale;
    if (g_ctx) |ctx| {
        c.mcore_resize(ctx, &g_desc);
    }
}

fn on_frame(t: f64) callconv(.C) void {
    if (g_ctx) |ctx| {
        c.mcore_begin_frame(ctx, t);

        // Draw a rounded rect with animated color
        const t_f: f32 = @floatCast(t);
        const hue = @mod(t_f * 0.2, 1.0);
        const rect = c.mcore_rounded_rect_t{
            .x = 40,
            .y = 40,
            .w = 200,
            .h = 100,
            .radius = 12,
            .fill = .{
                .r = 0.2 + 0.5 * @sin(hue * 6.28),
                .g = 0.4 + 0.3 * @cos(hue * 6.28),
                .b = 0.9,
                .a = 1.0,
            },
        };
        c.mcore_rect_rounded(ctx, &rect);

        const clear = c.mcore_rgba_t{ .r = 0.15, .g = 0.15, .b = 0.20, .a = 1.0 };
        const st = c.mcore_end_frame_present(ctx, clear);
        if (st != c.MCORE_OK) {
            const err = c.mcore_last_error();
            if (err != null) std.debug.print("mcore error: {s}\n", .{std.mem.span(err)});
        }
    }
}

pub fn main() !void {
    _ = mv_app_init(900, 600, "Zig ⟷ Rust wgpu");
    const ns_view = mv_get_ns_view() orelse return error.NoView;
    const ca_layer = mv_get_metal_layer() orelse return error.NoLayer;

    // Fill surface desc
    g_desc = .{
        .platform = c.MCORE_PLATFORM_MACOS,
        .u = .{ .macos = .{
            .ns_view = ns_view,
            .ca_metal_layer = ca_layer,
            .scale_factor = 2.0,    // updated by resize callback
            .width_px = 900 * 2,    // starter values
            .height_px = 600 * 2,
        }},
    };

    g_ctx = c.mcore_create(&g_desc) orelse {
        const err = c.mcore_last_error();
        if (err != null) std.debug.print("create error: {s}\n", .{std.mem.span(err)});
        return error.EngineCreateFailed;
    };

    mv_set_resize_callback(on_resize);
    mv_set_frame_callback(on_frame);
    mv_app_run();
}
