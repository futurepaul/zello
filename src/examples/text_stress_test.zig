const std = @import("std");
const zello = @import("../zello.zig");
const color = @import("../ui/color.zig");
const Color = color.Color;

// Simple color palette
const WHITE = color.rgba(1, 1, 1, 1);
const BLACK = color.rgba(0, 0, 0, 1);
const LIGHT_GRAY = color.rgba(0.95, 0.95, 0.96, 1);
const DARK_GRAY = color.rgba(0.3, 0.3, 0.3, 1);
const BLUE = color.rgba(0.2, 0.4, 0.8, 1);
const GREEN = color.rgba(0.2, 0.6, 0.3, 1);

// Typography
const TITLE_SIZE: f32 = 24;
const HEADING_SIZE: f32 = 18;
const BODY_SIZE: f32 = 14;
const STATS_SIZE: f32 = 12;

// Sample paragraphs for stress testing
const PARAGRAPHS = [_][:0]const u8{
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",

    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. How vexingly quick daft zebras jump! Sphinx of black quartz, judge my vow. The five boxing wizards jump quickly. Jackdaws love my big sphinx of quartz.",

    "In the beginning, there was nothing but void and silence. Then, from the darkness emerged a single point of light, growing and expanding until it filled the entire universe with its radiant glow. Stars were born, planets formed, and life began its long journey through the cosmos.",

    "Typography is the art and technique of arranging type to make written language legible, readable, and appealing when displayed. The arrangement of type involves selecting typefaces, point sizes, line lengths, line-spacing, and letter-spacing, and adjusting the space between pairs of letters.",

    "Software engineering is a systematic approach to the development, operation, and maintenance of software. It applies engineering principles to software creation in a methodical way. The discipline covers requirement analysis, design, implementation, testing, and maintenance phases.",

    "The scientific method is an empirical method of acquiring knowledge that has characterized the development of science since at least the 17th century. It involves careful observation, applying rigorous skepticism about what is observed, given that cognitive assumptions can distort how one interprets the observation.",

    "Artificial intelligence refers to the simulation of human intelligence in machines that are programmed to think like humans and mimic their actions. The term may also be applied to any machine that exhibits traits associated with a human mind such as learning and problem-solving.",

    "Climate change includes both global warming driven by human-induced emissions of greenhouse gases and the resulting large-scale shifts in weather patterns. Though there have been previous periods of climatic change, since the mid-20th century humans have had an unprecedented impact on Earth's climate system.",

    "The Renaissance was a fervent period of European cultural, artistic, political and economic 'rebirth' following the Middle Ages. Generally described as taking place from the 14th century to the 17th century, the Renaissance promoted the rediscovery of classical philosophy, literature and art.",

    "Quantum mechanics is a fundamental theory in physics that provides a description of the physical properties of nature at the scale of atoms and subatomic particles. It is the foundation of all quantum physics including quantum chemistry, quantum field theory, quantum technology, and quantum information science.",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try zello.init(gpa.allocator(), 900, 700, "Text Stress Test - Resize Me!", onFrame);
    defer app.deinit();

    zello.run(app);
}

fn onFrame(ui: *zello.UI, time: f64) void {
    _ = time;
    ui.beginFrame();
    defer ui.endFrame(WHITE) catch {};

    // ROOT: Main vertical container
    ui.beginVstack(.{ .gap = 0, .padding = 0 }) catch return;

    // ============================================================================
    // STATS HEADER (Fixed at top)
    // ============================================================================
    renderStatsHeader(ui);

    // ============================================================================
    // SCROLLABLE CONTENT
    // ============================================================================
    ui.beginScrollArea(.{
        .constrain_vertical = false,
        .bg_color = WHITE,
        .padding = 20,
    }) catch return;

    // Content container
    ui.beginVstack(.{ .gap = 20, .padding = 0 }) catch return;

    // Title
    ui.label("Text Rendering Stress Test", .{
        .size = TITLE_SIZE,
        .color = BLUE,
    }) catch {};

    ui.label("Resize the window to see text reflow and cache performance!", .{
        .size = BODY_SIZE,
        .color = DARK_GRAY,
    }) catch {};

    // Render multiple sections with paragraphs
    for (PARAGRAPHS, 0..) |paragraph, i| {
        ui.beginVstack(.{ .gap = 8, .padding = 0 }) catch return;

        // Section heading
        var heading_buf: [64]u8 = undefined;
        const heading = std.fmt.bufPrintZ(&heading_buf, "Section {d}", .{i + 1}) catch "Section";
        ui.label(heading, .{
            .size = HEADING_SIZE,
            .color = BLACK,
        }) catch {};

        // Paragraph
        ui.label(paragraph, .{
            .size = BODY_SIZE,
            .color = BLACK,
        }) catch {};

        ui.endVstack();
    }

    // Add another set for extra stress
    ui.label("=== Extra Stress Test Content ===", .{
        .size = HEADING_SIZE,
        .color = BLUE,
    }) catch {};

    for (PARAGRAPHS, 0..) |paragraph, i| {
        if (i % 2 == 0) {
            ui.label(paragraph, .{
                .size = BODY_SIZE,
                .color = DARK_GRAY,
            }) catch {};
        }
    }

    ui.endVstack(); // End content container
    ui.endScrollArea(); // End scroll area
    ui.endVstack(); // End root vstack
}

// Global stats strings (persists across renderStatsHeader calls)
var g_stats_strings = struct {
    hit_rate: [128]u8 = undefined,
    hits: [128]u8 = undefined,
    misses: [128]u8 = undefined,
    entries: [128]u8 = undefined,
    measure_calls: [128]u8 = undefined,
    offset_calls: [128]u8 = undefined,
    ffi_ratio: [128]u8 = undefined,
    arena_current: [128]u8 = undefined,
    arena_peak: [128]u8 = undefined,
    frame_time: [128]u8 = undefined,
}{};

fn renderStatsHeader(ui: *zello.UI) void {
    const stats = ui.getTextStats();
    const cache_stats = ui.getTextCacheStats();
    const arena_stats = ui.frame_arena.getStats();
    const hit_rate = ui.getTextCacheHitRate();

    // Stats panel with colored background
    ui.beginVstack(.{ .gap = 5, .padding = 12 }) catch return;

    ui.label("PERFORMANCE STATS (Live)", .{
        .size = STATS_SIZE + 2,
        .color = WHITE,
        .bg_color = BLUE,
        .padding = 6,
    }) catch {};

    // Create a horizontal layout for stats
    ui.beginHstack(.{ .gap = 30, .padding = 0 }) catch return;

    // Column 1: Cache Performance
    ui.beginVstack(.{ .gap = 3, .padding = 0 }) catch return;
    ui.label("Cache Performance:", .{ .size = STATS_SIZE, .color = BLACK }) catch {};

    const hit_rate_text = std.fmt.bufPrintZ(&g_stats_strings.hit_rate, "Hit Rate: {d:.1}%", .{hit_rate}) catch "?";
    const hit_rate_color = if (hit_rate > 90) GREEN else if (hit_rate > 70) color.rgba(0.8, 0.6, 0.2, 1) else color.rgba(0.8, 0.2, 0.2, 1);
    ui.label(hit_rate_text, .{ .size = STATS_SIZE, .color = hit_rate_color }) catch {};

    const hits_text = std.fmt.bufPrintZ(&g_stats_strings.hits, "Hits: {d}", .{cache_stats.hits}) catch "?";
    ui.label(hits_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    const misses_text = std.fmt.bufPrintZ(&g_stats_strings.misses, "Misses: {d}", .{cache_stats.misses}) catch "?";
    ui.label(misses_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    const entries_text = std.fmt.bufPrintZ(&g_stats_strings.entries, "Entries: {d}", .{cache_stats.unique_entries}) catch "?";
    ui.label(entries_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};
    ui.endVstack();

    // Column 2: Rust FFI Calls
    ui.beginVstack(.{ .gap = 3, .padding = 0 }) catch return;
    ui.label("Rust FFI Calls:", .{ .size = STATS_SIZE, .color = BLACK }) catch {};

    const measure_text = std.fmt.bufPrintZ(&g_stats_strings.measure_calls, "measure(): {d}", .{stats.measure_calls}) catch "?";
    ui.label(measure_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    const offset_text = std.fmt.bufPrintZ(&g_stats_strings.offset_calls, "offset(): {d}", .{stats.offset_calls}) catch "?";
    ui.label(offset_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    // Show ratio
    const total_requests = cache_stats.hits + cache_stats.misses;
    if (total_requests > 0) {
        const ratio = @as(f32, @floatFromInt(stats.measure_calls)) / @as(f32, @floatFromInt(total_requests));
        const ratio_text = std.fmt.bufPrintZ(&g_stats_strings.ffi_ratio, "FFI Ratio: {d:.2}x", .{ratio}) catch "?";
        ui.label(ratio_text, .{ .size = STATS_SIZE, .color = GREEN }) catch {};
    }
    ui.endVstack();

    // Column 3: Memory
    ui.beginVstack(.{ .gap = 3, .padding = 0 }) catch return;
    ui.label("Frame Arena:", .{ .size = STATS_SIZE, .color = BLACK }) catch {};

    const current_text = std.fmt.bufPrintZ(&g_stats_strings.arena_current, "Current: {d} KB", .{arena_stats.current_usage / 1024}) catch "?";
    ui.label(current_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    const peak_text = std.fmt.bufPrintZ(&g_stats_strings.arena_peak, "Peak: {d} KB", .{arena_stats.peak_usage / 1024}) catch "?";
    ui.label(peak_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};

    const capacity_text = std.fmt.bufPrintZ(&g_stats_strings.frame_time, "Capacity: {d} KB", .{arena_stats.capacity / 1024}) catch "?";
    ui.label(capacity_text, .{ .size = STATS_SIZE, .color = DARK_GRAY }) catch {};
    ui.endVstack();

    ui.endHstack(); // End stats columns

    // Instructions
    ui.label("→ Resize the window to trigger text reflow and see cache effectiveness!", .{
        .size = STATS_SIZE,
        .color = BLUE,
        .padding = 4,
    }) catch {};

    ui.endVstack(); // End stats panel
}
