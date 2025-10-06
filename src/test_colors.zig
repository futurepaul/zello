const std = @import("std");
const color = @import("ui/color.zig");
const Color = color.Color;
const animation = @import("ui/animation.zig");

pub fn main() !void {
    std.debug.print("\n=== Color API Test ===\n\n", .{});

    // Test 1: Parse CSS colors
    std.debug.print("Test 1: Parsing CSS colors\n", .{});

    const red = color.parse("red") orelse {
        std.debug.print("  ERROR: Failed to parse 'red'\n", .{});
        return error.ParseFailed;
    };
    std.debug.print("  red = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n", .{ red.r, red.g, red.b, red.a });

    const oklch_primary = color.parse("oklch(0.623 0.214 259.815)") orelse {
        std.debug.print("  ERROR: Failed to parse OKLCH\n", .{});
        return error.ParseFailed;
    };
    std.debug.print("  oklch(0.623 0.214 259.815) = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
        .{ oklch_primary.r, oklch_primary.g, oklch_primary.b, oklch_primary.a });

    const hex_color = color.parse("#ff0000") orelse {
        std.debug.print("  ERROR: Failed to parse hex\n", .{});
        return error.ParseFailed;
    };
    std.debug.print("  #ff0000 = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
        .{ hex_color.r, hex_color.g, hex_color.b, hex_color.a });

    // Test 2: rgba() constructor
    std.debug.print("\nTest 2: rgba() constructor\n", .{});
    const blue = color.rgba(0, 0, 1, 1);
    std.debug.print("  rgba(0, 0, 1, 1) = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
        .{ blue.r, blue.g, blue.b, blue.a });

    // Test 3: rgba8() constructor
    std.debug.print("\nTest 3: rgba8() constructor\n", .{});
    const green = color.rgba8(0, 255, 0, 255);
    std.debug.print("  rgba8(0, 255, 0, 255) = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
        .{ green.r, green.g, green.b, green.a });

    // Test 4: Color interpolation (perceptually-correct in Oklab!)
    std.debug.print("\nTest 4: Color interpolation (Oklab)\n", .{});
    const purple = color.lerp(red, blue, 0.5);
    std.debug.print("  lerp(red, blue, 0.5) = rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
        .{ purple.r, purple.g, purple.b, purple.a });

    // Test 5: Animation easing
    std.debug.print("\nTest 5: Animation easing functions\n", .{});
    std.debug.print("  linear(0.5) = {d:.3}\n", .{animation.lerp(0, 1, 0.5)});
    std.debug.print("  easeInOutCubic(0.5) = {d:.3}\n", .{animation.easeInOutCubic(0.5)});
    std.debug.print("  easeOutCubic(0.5) = {d:.3}\n", .{animation.easeOutCubic(0.5)});

    // Test 6: Animated color transition
    std.debug.print("\nTest 6: Animated color transition\n", .{});
    const start_color = color.parse("oklch(0.967 0.001 286.375)").?; // secondary
    const end_color = color.parse("oklch(0.92 0.004 286.32)").?;     // border (slightly darker)

    std.debug.print("  Animation progress:\n", .{});
    var t: f32 = 0;
    while (t <= 1.0) : (t += 0.25) {
        const eased_t = animation.easeInOutCubic(t);
        const col = color.lerp(start_color, end_color, eased_t);
        std.debug.print("    t={d:.2} -> rgba({d:.3}, {d:.3}, {d:.3}, {d:.3})\n",
            .{ t, col.r, col.g, col.b, col.a });
    }

    std.debug.print("\n=== All tests passed! ===\n\n", .{});
}
