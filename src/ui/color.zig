const c_api = @import("../renderer/c_api.zig");
const c = c_api.c;

/// Color type wrapping Rust's color::AlphaColor<Srgb>
/// Same memory layout as [4]f32 for easy FFI and compatibility
/// This is an alias to mcore_color_t from the C API
pub const Color = c.mcore_color_t;

// Add methods to the C type
pub const ColorMethods = struct {

};

// Extension methods for Color (using the namespace pattern)
pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
    var out: Color = undefined;
    c.mcore_color_from_rgba8(r, g, b, a, &out);
    return out;
}

/// Parse a CSS color string
/// Supports: oklch(), rgb(), rgba(), hex (#rrggbb), named colors, hsl(), lab(), lch()
/// Returns null if parsing fails
///
/// Examples:
///   Color.parse("oklch(0.623 0.214 259.815)")
///   Color.parse("#ff0000")
///   Color.parse("rgb(255 0 0)")
///   Color.parse("rgba(255, 0, 0, 0.5)")
///   Color.parse("hsl(120 100% 50%)")
///   Color.parse("red")
pub fn parse(css_str: []const u8) ?Color {
    var out: Color = undefined;
    const success = c.mcore_color_parse(css_str.ptr, css_str.len, &out);
    if (success != 0) {
        return out;
    }
    return null;
}

/// Interpolate between two colors using perceptually-correct Oklab space
/// This produces much smoother gradients than naive RGB interpolation
/// t should be in range [0.0, 1.0]
///
/// Example:
///   const red = parse("red").?;
///   const blue = parse("blue").?;
///   const purple = lerp(red, blue, 0.5);  // Beautiful purple!
pub fn lerp(a: Color, b: Color, t: f32) Color {
    var out: Color = undefined;
    c.mcore_color_lerp(&a, &b, t, &out);
    return out;
}

/// Convert to [4]f32 array (for backward compatibility with existing code)
pub fn toArray(self: Color) [4]f32 {
    return .{ self.r, self.g, self.b, self.a };
}

/// Create from [4]f32 array
pub fn fromArray(arr: [4]f32) Color {
    return .{ .r = arr[0], .g = arr[1], .b = arr[2], .a = arr[3] };
}

// Common color constants for convenience
pub const BLACK = rgba(0, 0, 0, 1);
pub const WHITE = rgba(1, 1, 1, 1);
pub const RED = rgba(1, 0, 0, 1);
pub const GREEN = rgba(0, 1, 0, 1);
pub const BLUE = rgba(0, 0, 1, 1);
pub const TRANSPARENT = rgba(0, 0, 0, 0);
