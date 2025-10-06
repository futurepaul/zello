# Style System Plan for Zello

This document outlines the plan to add a theming system to Zello, starting with shadcn-style buttons.

## Goals

1. **Add drop shadow support** to Vello rendering (new FFI function)
2. **Add border rendering** with separate color from fill (new FFI function or extend existing)
3. **Create theme system** with OKLCH color definitions (pure Zig)
4. **Extend ButtonOptions** to accept style properties (border, shadow, radius)
5. **Add hover animation state** (timing-based, smooth transitions)

## Design Principles

- **Keep it low-level**: Minimal abstraction - users should have full power to build their own components
- **Theming is optional**: Default widgets should work without a theme
- **Style lives in Zig**: All theme definitions are Zig constants, no complex data structures
- **FFI stays clean**: Only add rendering primitives, not style concepts

## Architecture

### Theme Structure

**Using the `color` crate for type-safe, perceptually-correct colors!**

```zig
// src/ui/color.zig - FFI wrapper for Rust color crate
const c = @import("../renderer/c_api.zig").c;

/// Opaque handle to Rust color::AlphaColor<Srgb>
pub const Color = extern struct {
    // Internal: matches Rust repr(C) of AlphaColor<Srgb>
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    /// Create from RGBA values (0.0 - 1.0)
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Parse from CSS color string (via Rust FFI)
    /// Examples: "oklch(0.623 0.214 259.815)", "#ff0000", "rgb(255 0 0)"
    pub fn parse(css_str: []const u8) ?Color {
        var out: Color = undefined;
        if (c.mcore_color_parse(css_str.ptr, css_str.len, &out) != 0) {
            return out;
        }
        return null;
    }

    /// Interpolate between two colors using perceptually-correct color space
    /// Uses Oklab for smooth interpolation (via Rust FFI)
    pub fn lerp(self: Color, other: Color, t: f32) Color {
        var out: Color = undefined;
        c.mcore_color_lerp(&self, &other, t, &out);
        return out;
    }
};

// src/ui/themes/shadcn.zig
const Color = @import("../color.zig").Color;

pub const Theme = struct {
    // Colors - defined using CSS OKLCH strings!
    // Copy-paste directly from shadcn's CSS variables
    background: Color = Color.parse("oklch(1 0 0)").?,  // White
    foreground: Color = Color.parse("oklch(0.141 0.005 285.823)").?,
    primary: Color = Color.parse("oklch(0.623 0.214 259.815)").?,  // Purple-blue
    primary_foreground: Color = Color.parse("oklch(0.97 0.014 254.604)").?,
    secondary: Color = Color.parse("oklch(0.967 0.001 286.375)").?,  // Light gray
    secondary_foreground: Color = Color.parse("oklch(0.21 0.006 285.885)").?,
    muted: Color = Color.parse("oklch(0.967 0.001 286.375)").?,
    muted_foreground: Color = Color.parse("oklch(0.552 0.016 285.938)").?,
    accent: Color = Color.parse("oklch(0.967 0.001 286.375)").?,
    accent_foreground: Color = Color.parse("oklch(0.21 0.006 285.885)").?,
    destructive: Color = Color.parse("oklch(0.577 0.245 27.325)").?,  // Red
    border: Color = Color.parse("oklch(0.92 0.004 286.32)").?,
    input: Color = Color.parse("oklch(0.92 0.004 286.32)").?,
    ring: Color = Color.parse("oklch(0.623 0.214 259.815)").?,

    // Radii
    radius: f32 = 0.65 * 16,  // rem to pixels (assuming 16px base)

    // Shadows
    shadow_sm: Shadow = .{
        .x = 0, .y = 1, .blur = 2, .spread = 0,
        .color = Color.parse("rgba(0 0 0 / 0.05)").?
    },
    shadow_md: Shadow = .{
        .x = 0, .y = 4, .blur = 6, .spread = -1,
        .color = Color.parse("rgba(0 0 0 / 0.1)").?
    },
};

pub const Shadow = struct {
    x: f32,
    y: f32,
    blur: f32,
    spread: f32,
    color: Color,
};
```

**Alternative: Compile-time parsing (no runtime overhead!)**

Since theme colors are constants, we can parse CSS strings at compile time:

```zig
// Parse CSS color string at comptime and convert to RGBA constants
pub const background = comptime Color.parse("oklch(1 0 0)").?;

// Or if we pre-calculate (for faster compile times):
pub const background = Color.rgba(1.0, 1.0, 1.0, 1.0);
pub const primary = Color.rgba(0.451, 0.482, 0.929, 1.0);  // Pre-calculated from OKLCH
```

### Extended Button Options

```zig
// In src/ui/ui.zig
const Color = @import("color.zig").Color;

pub const ButtonOptions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    id: ?[]const u8 = null,

    // Style properties (using proper Color type!)
    bg_color: ?Color = null,  // Default button background
    hover_color: ?Color = null,  // Hover state background
    border_color: ?Color = null,  // Border color (null = no border)
    border_width: f32 = 1,  // Border width in pixels
    radius: f32 = 8,  // Border radius
    shadow: ?Shadow = null,  // Drop shadow (null = no shadow)

    // Animation
    transition_duration: f32 = 0.15,  // Seconds for hover transition
};

// Usage examples:
// .bg_color = Color.parse("oklch(0.967 0.001 286.375)")  // From CSS
// .bg_color = Color.rgba(0.95, 0.95, 0.96, 1.0)          // From values
// .bg_color = theme.secondary                             // From theme
```

### Hover State & Animation

Buttons need to track:
1. **Current hover state** (bool)
2. **Animation progress** (0.0 to 1.0)
3. **Last state change time** (for smooth transitions)

We'll add a `HoverState` to the UI context that persists across frames:

```zig
// In UI struct
hover_states: std.AutoHashMap(u64, HoverState),
current_time: f64 = 0,  // Updated from mcore_begin_frame

const HoverState = struct {
    is_hovered: bool,
    animation_t: f32,  // 0.0 = normal, 1.0 = fully hovered
    transition_start_time: f64,
    transition_duration: f32,
};
```

Easing functions (low-level, easy to customize):

```zig
// src/ui/animation.zig - Simple, self-contained easing functions

/// Linear interpolation between two values
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Ease-in-out (smooth start and end)
pub fn easeInOutCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    if (t_clamped < 0.5) {
        return 4.0 * t_clamped * t_clamped * t_clamped;
    } else {
        const f = (2.0 * t_clamped - 2.0);
        return 1.0 + f * f * f / 2.0;
    }
}

/// Ease-out (fast start, slow end)
pub fn easeOutCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    const f = t_clamped - 1.0;
    return 1.0 + f * f * f;
}

/// Ease-in (slow start, fast end)
pub fn easeInCubic(t: f32) f32 {
    const t_clamped = @max(0.0, @min(1.0, t));
    return t_clamped * t_clamped * t_clamped;
}

/// Calculate animation progress with easing
/// Returns 0.0 to 1.0 based on elapsed time and duration
pub fn animationProgress(start_time: f64, current_time: f64, duration: f32, easing_fn: fn(f32) f32) f32 {
    const elapsed = @as(f32, @floatCast(current_time - start_time));
    const raw_t = elapsed / duration;
    const clamped_t = @max(0.0, @min(1.0, raw_t));
    return easing_fn(clamped_t);
}

// Note: Color interpolation is handled by Color.lerp() via Rust FFI
// This gives us perceptually-correct color blending in Oklab color space!
```

Usage in button rendering:

```zig
// Get or create hover state
const state = hover_states.getPtr(button_id) orelse {
    try hover_states.put(button_id, .{
        .is_hovered = false,
        .animation_t = 0.0,
        .transition_start_time = current_time,
        .transition_duration = 0.15,
    });
    hover_states.getPtr(button_id).?
};

// Update hover state
const currently_hovered = bounds.contains(mouse_x, mouse_y);
if (currently_hovered != state.is_hovered) {
    state.is_hovered = currently_hovered;
    state.transition_start_time = current_time;
}

// Calculate animation progress
const progress = animationProgress(
    state.transition_start_time,
    current_time,
    state.transition_duration,
    easeInOutCubic
);

// Interpolate toward target
const target_t: f32 = if (state.is_hovered) 1.0 else 0.0;
const eased_t = easeInOutCubic(progress);

// Use Rust color crate's perceptually-correct lerp (in Oklab space!)
const bg_color = normal_color.lerp(hover_color, eased_t);
```

## FFI Changes

### 0. Color Support (NEW!)

**C API** (`bindings/mcore.h`):
```c
// Color type (matches Rust AlphaColor<Srgb> repr(C))
typedef struct {
    float r, g, b, a;
} mcore_color_t;

// Parse CSS color string to mcore_color_t
// Returns 1 on success, 0 on parse error
// Supports: oklch(), rgb(), rgba(), hex (#rrggbb), named colors, etc.
unsigned char mcore_color_parse(const char* css_str, size_t len, mcore_color_t* out);

// Interpolate between two colors using perceptually-correct Oklab space
void mcore_color_lerp(const mcore_color_t* a, const mcore_color_t* b, float t, mcore_color_t* out);

// Convert from RGBA8 (0-255) to mcore_color_t
void mcore_color_from_rgba8(unsigned char r, unsigned char g, unsigned char b, unsigned char a, mcore_color_t* out);
```

**Rust implementation**:
```rust
use color::{AlphaColor, Srgb, Oklch};

#[repr(C)]
#[derive(Copy, Clone)]
pub struct McoreColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl From<AlphaColor<Srgb>> for McoreColor {
    fn from(c: AlphaColor<Srgb>) -> Self {
        Self { r: c.r, g: c.g, b: c.b, a: c.alpha }
    }
}

impl From<McoreColor> for AlphaColor<Srgb> {
    fn from(c: McoreColor) -> Self {
        AlphaColor { r: c.r, g: c.g, b: c.b, alpha: c.a }
    }
}

#[no_mangle]
pub extern "C" fn mcore_color_parse(
    css_str: *const u8,
    len: usize,
    out: *mut McoreColor,
) -> u8 {
    let css_str = unsafe { std::slice::from_raw_parts(css_str, len) };
    let css_str = std::str::from_utf8(css_str).ok()?;

    // Use color crate's CSS parsing
    let parsed: color::DynamicColor = css_str.parse().ok()?;
    let srgb: AlphaColor<Srgb> = parsed.convert();

    unsafe {
        *out = srgb.into();
    }
    1  // Success
}

#[no_mangle]
pub extern "C" fn mcore_color_lerp(
    a: *const McoreColor,
    b: *const McoreColor,
    t: f32,
    out: *mut McoreColor,
) {
    let a = unsafe { (*a).into() };
    let b = unsafe { (*b).into() };

    // Convert to Oklab for perceptually-correct interpolation
    let a_oklab: AlphaColor<color::Oklab> = a.convert();
    let b_oklab: AlphaColor<color::Oklab> = b.convert();

    // Lerp in Oklab space (much better than RGB!)
    let result = a_oklab.lerp(b_oklab, t, color::HueDirection::Shorter);

    // Convert back to sRGB
    let result_srgb: AlphaColor<Srgb> = result.convert();

    unsafe {
        *out = result_srgb.into();
    }
}

#[no_mangle]
pub extern "C" fn mcore_color_from_rgba8(
    r: u8, g: u8, b: u8, a: u8,
    out: *mut McoreColor,
) {
    let color = AlphaColor::<Srgb> {
        r: r as f32 / 255.0,
        g: g as f32 / 255.0,
        b: b as f32 / 255.0,
        alpha: a as f32 / 255.0,
    };

    unsafe {
        *out = color.into();
    }
}
```

**Why this is awesome:**
- ✅ Copy-paste CSS colors directly: `Color.parse("oklch(0.623 0.214 259.815)")`
- ✅ Perceptually-correct color interpolation (Oklab, not RGB!)
- ✅ Type-safe at the Zig level
- ✅ Zero-cost abstraction (same memory layout as `[4]f32`)

### 1. Add Drop Shadow Support

**C API** (`bindings/mcore.h`):
```c
typedef struct {
    float offset_x;
    float offset_y;
    float blur_radius;
    float spread;
    mcore_rgba_t color;
} mcore_shadow_t;

// Draw a rectangle with drop shadow
void mcore_rect_with_shadow(
    mcore_context_t* ctx,
    float x, float y, float width, float height,
    float radius,
    mcore_rgba_t fill,
    const mcore_shadow_t* shadow  // Can be NULL
);
```

**Rust implementation**:
```rust
#[repr(C)]
pub struct McoreShadow {
    pub offset_x: f32,
    pub offset_y: f32,
    pub blur_radius: f32,
    pub spread: f32,
    pub color: McoreRgba,
}

#[no_mangle]
pub extern "C" fn mcore_rect_with_shadow(
    ctx: *mut McoreContext,
    x: f32, y: f32, width: f32, height: f32,
    radius: f32,
    fill: McoreRgba,
    shadow: *const McoreShadow,
) {
    // 1. Draw shadow if present (slightly larger rect, blurred)
    // 2. Draw main rect on top
    // Vello's blur effect: scene.push_layer with BackdropFilter
}
```

**Vello rendering approach**:
- Use Vello's `draw_blurred_rounded_rect()` for shadow
- Render shadow rect offset by (offset_x, offset_y)
- Render main rect on top

### 2. Add Border Support

**Option A: Extend existing rounded rect** (simpler, recommended):
```c
typedef struct {
    float x, y, width, height;
    float radius;
    mcore_rgba_t fill;
    mcore_rgba_t border_color;  // NEW
    float border_width;         // NEW (0 = no border)
} mcore_rect_style_t;

void mcore_rect_styled(mcore_context_t* ctx, const mcore_rect_style_t* style);
```

**Rust implementation**:
```rust
#[no_mangle]
pub extern "C" fn mcore_rect_styled(
    ctx: *mut McoreContext,
    style: *const McoreRectStyle,
) {
    let ctx = unsafe { ctx.as_mut() }.unwrap();
    let style = unsafe { style.as_ref() }.unwrap();
    let mut guard = ctx.0.lock();

    // 1. Draw fill
    let fill_shape = peniko::kurbo::RoundedRect::new(...);
    guard.scene.fill(..., fill_color, &fill_shape);

    // 2. Draw border if border_width > 0
    if style.border_width > 0.0 {
        // Use stroke instead of fill
        guard.scene.stroke(
            peniko::Stroke::new(style.border_width),
            ...,
            border_color,
            ...,
            &fill_shape
        );
    }
}
```

### 3. Update Command Buffer

Add new command types to support shadows and borders:

```c
typedef enum {
    MCORE_DRAW_CMD_ROUNDED_RECT = 0,
    MCORE_DRAW_CMD_TEXT = 1,
    MCORE_DRAW_CMD_PUSH_CLIP = 2,  // Already exists
    MCORE_DRAW_CMD_POP_CLIP = 3,   // Already exists
    MCORE_DRAW_CMD_STYLED_RECT = 4,  // NEW: rect with border
    MCORE_DRAW_CMD_SHADOW_RECT = 5,  // NEW: rect with shadow
} mcore_draw_cmd_kind_t;
```

Extend `mcore_draw_command_t` to include border/shadow fields (may need to increase padding or add union).

## Implementation Phases

### Phase 1: Color FFI & Animation Helpers

**Rust side:**
- [ ] Add `mcore_color_t` struct to `lib.rs`
- [ ] Implement `mcore_color_parse()` using `color` crate's CSS parser
- [ ] Implement `mcore_color_lerp()` using Oklab interpolation
- [ ] Implement `mcore_color_from_rgba8()` for convenience
- [ ] Add to `mcore.h` header

**Zig side:**
- [ ] Create `src/ui/color.zig` with `Color` type and FFI wrappers
- [ ] Add `Color.parse()`, `Color.lerp()`, `Color.rgba()` helpers
- [ ] Create `src/ui/animation.zig` with easing functions
- [ ] Test color parsing with CSS strings
- [ ] Test color lerp vs naive RGB lerp (visual comparison)

**Deliverable**: Can parse CSS colors and lerp them perceptually correctly

### Phase 2: Border Rendering (FFI + Rust)
- [ ] Add `mcore_rect_styled()` to C API header
- [ ] Implement in Rust using Vello's stroke
- [ ] Add `MCORE_DRAW_CMD_STYLED_RECT` to command buffer
- [ ] Update `commands.zig` to support border commands
- [ ] Test: render a button with border

**Deliverable**: Can render rect with separate fill and border colors

### Phase 3: Drop Shadow Rendering (FFI + Rust)
- [ ] Research Vello's blur/filter capabilities (may use layers or manual blur)
- [ ] Add `mcore_shadow_t` struct to C API
- [ ] Implement shadow rendering in Rust
- [ ] Add to command buffer
- [ ] Test: render button with shadow

**Deliverable**: Can render rect with drop shadow using Vello's `draw_blurred_rounded_rect()`

### Phase 4: Theme System (Pure Zig)
- [ ] Create `src/ui/themes/shadcn.zig`
- [ ] Define `Theme` struct with shadcn colors using `Color.parse()`
- [ ] Define `Shadow` struct
- [ ] Export default theme instance
- [ ] Test: verify colors match shadcn CSS output

**Deliverable**: `shadcn.default_theme` with CSS-parseable colors

### Phase 5: Hover State Tracking with Easing (Zig)
- [ ] Add `hover_states` HashMap to UI context
- [ ] Add `current_time` field, updated in `beginFrame()`
- [ ] Update `renderButton()` to track hover state changes
- [ ] Use `animationProgress()` with easing for smooth transitions
- [ ] Lerp between normal and hover colors

**Deliverable**: Buttons smoothly animate on hover with cubic easing

### Phase 6: Styled Button Widget (Zig)
- [ ] Extend `ButtonOptions` with style fields
- [ ] Update `renderButton()` to use new styled rect commands
- [ ] Add shadow rendering if `shadow` is non-null
- [ ] Add border rendering if `border_color` is non-null

**Deliverable**: Can create shadcn-style button with theme

### Phase 7: Example & Polish
- [ ] Update `main.zig` with example themed button
- [ ] Add hover state demo
- [ ] Test animation smoothness
- [ ] Document theme usage in comments

**Deliverable**: Working shadcn button demo

## Testing Strategy

1. **Visual tests**: Render buttons and compare to shadcn reference
2. **Animation tests**: Verify smooth transitions (60fps)
3. **Color accuracy**: Compare OKLCH conversions to CSS output
4. **Border/shadow tests**: Verify rendering at different sizes/radii

## Decisions Made

1. **Vello blur support**: ✅ Use `draw_blurred_rounded_rect()` for shadows
2. **OKLCH conversion**: ✅ Pre-calculate RGB values (simpler, faster)
3. **Animation timing**: ✅ Use `time_seconds` from frame for smooth timing
4. **Hover state persistence**: ✅ Store in `UI.hover_states` HashMap
5. **Easing functions**: ✅ Simple vanilla functions (easeInOutCubic, etc.) - easy to import/customize

## Success Criteria

A button rendered with:
```zig
const theme = shadcn.default_theme;

// Super ergonomic with CSS color support!
try ui.button("Button", .{
    .bg_color = theme.secondary,
    .hover_color = theme.secondary.lerp(theme.muted, 0.2),  // Slight darkening
    .border_color = theme.border,
    .border_width = 1,
    .radius = theme.radius,
    .shadow = theme.shadow_sm,
});

// Or inline with CSS strings:
try ui.button("Primary Button", .{
    .bg_color = Color.parse("oklch(0.623 0.214 259.815)"),  // Copy from CSS!
    .hover_color = Color.parse("oklch(0.523 0.214 259.815)"),  // Darker
    .border_color = Color.parse("#e5e7eb"),
    .radius = 8,
});

// Or mix and match:
try ui.button("Danger", .{
    .bg_color = theme.destructive,
    .hover_color = theme.destructive.lerp(Color.rgba(0, 0, 0, 1), 0.1),  // 10% darker
    .border_color = null,  // No border
});
```

Should match the shadcn button visual from the reference images:
- White/light gray background
- Subtle border
- Small drop shadow
- Smooth hover transition to darker gray
- Rounded corners (~10px radius)

## Future Extensions (Out of Scope for MVP)

- Full color system with variants (hover, active, disabled)
- Dark mode support (second theme)
- Other widget styles (input, checkbox, etc.)
- Animation easing functions (ease-in-out, etc.)
- CSS-like style composition
- Gradient support
