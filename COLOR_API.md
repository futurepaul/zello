# Color API Design

Quick reference for the color system.

## Zig API

```zig
const Color = @import("ui/color.zig").Color;

// Create colors
const red = Color.rgba(1.0, 0.0, 0.0, 1.0);
const blue = Color.parse("oklch(0.623 0.214 259.815)").?;
const green = Color.parse("#00ff00").?;
const purple = Color.parse("rgb(128 0 128)").?;

// Interpolate (perceptually-correct in Oklab space!)
const teal = blue.lerp(green, 0.5);

// Use in themes
const theme = shadcn.default_theme;
const bg = theme.secondary;
const hover_bg = bg.lerp(theme.muted, 0.2);
```

## Memory Layout

`Color` is just 4 floats - same as `[4]f32`:

```zig
pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};
```

## Supported CSS Formats

All CSS Color Level 4 formats via Rust's `color` crate:

- **OKLCH**: `"oklch(0.623 0.214 259.815)"` ✨ Best for perceptual uniformity
- **Hex**: `"#ff0000"`, `"#f00"`
- **RGB**: `"rgb(255 0 0)"`, `"rgb(255 0 0 / 0.5)"`
- **RGBA**: `"rgba(255, 0, 0, 0.5)"` (legacy syntax)
- **HSL**: `"hsl(120 100% 50%)"`
- **Named**: `"red"`, `"blue"`, etc.
- **Lab**: `"lab(50 50 50)"`
- **LCH**: `"lch(50 50 50)"`

## Why Oklab for Interpolation?

RGB interpolation looks muddy:

```
Red → Blue in RGB: Gross grayish purple
Red → Blue in Oklab: Beautiful vivid purple
```

Example:

```zig
const red = Color.parse("rgb(255 0 0)").?;
const blue = Color.parse("rgb(0 0 255)").?;

// This uses Oklab internally - smooth, vivid transition!
const purple = red.lerp(blue, 0.5);
```

## Performance

- **Parsing**: Happens at compile-time for theme constants (via `comptime`)
- **Lerping**: Fast - just a few multiply-adds in Oklab space
- **Memory**: Zero overhead - same size as `[4]f32`

## FFI Functions (for reference)

```c
// Parse CSS color string
unsigned char mcore_color_parse(const char* css_str, size_t len, mcore_color_t* out);

// Lerp in Oklab space
void mcore_color_lerp(const mcore_color_t* a, const mcore_color_t* b, float t, mcore_color_t* out);

// From RGBA8 (0-255)
void mcore_color_from_rgba8(unsigned char r, unsigned char g, unsigned char b, unsigned char a, mcore_color_t* out);
```

## Example Theme

```zig
pub const shadcn = struct {
    pub const background = Color.parse("oklch(1 0 0)").?;
    pub const foreground = Color.parse("oklch(0.141 0.005 285.823)").?;
    pub const primary = Color.parse("oklch(0.623 0.214 259.815)").?;
    pub const border = Color.parse("oklch(0.92 0.004 286.32)").?;

    // Derived colors
    pub const primary_hover = primary.lerp(Color.rgba(0, 0, 0, 1), 0.1);
    pub const primary_active = primary.lerp(Color.rgba(0, 0, 0, 1), 0.2);
};
```

## Benefits

✅ **Ergonomic**: Copy-paste CSS colors directly
✅ **Type-safe**: Can't mix incompatible color spaces
✅ **Correct**: Perceptually-uniform interpolation
✅ **Fast**: Zero-cost abstraction, comptime parsing
✅ **Familiar**: Same format as web development
