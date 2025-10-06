# Future Layout Enhancements

Based on analysis of Clay (C immediate-mode UI) and masonry_core (Rust retained-mode UI).

## Current Status

✅ **Phase 1 Complete**: IDs + Focus
✅ **Phase 2 Complete**: Basic Flexbox Layout
- Fixed and flexible sizing (`flex=0` and `flex>0`)
- Gap and padding support
- Horizontal and vertical axis
- Text measurement via FFI

## High Priority Enhancements

### 1. Child Alignment (Cross-Axis)

**From Clay**: `childAlignment.x` and `childAlignment.y`

Add to `FlexContainer`:
```zig
pub const CrossAxisAlignment = enum {
    Start,   // CLAY_ALIGN_X_LEFT / CLAY_ALIGN_Y_TOP
    Center,  // CLAY_ALIGN_X_CENTER / CLAY_ALIGN_Y_CENTER
    End,     // CLAY_ALIGN_X_RIGHT / CLAY_ALIGN_Y_BOTTOM
    Stretch, // Fill cross axis
};

pub const FlexContainer = struct {
    // ... existing fields
    cross_alignment: CrossAxisAlignment = .Start,
};
```

**Why**: Fixes layout funkiness on window resize, allows proper centering.

### 2. Main-Axis Alignment

**From Clay/CSS Flexbox**: `justify-content`

```zig
pub const MainAxisAlignment = enum {
    Start,        // Pack to start
    Center,       // Pack to center
    End,          // Pack to end
    SpaceBetween, // Even spacing between items
    SpaceAround,  // Even spacing around items
    SpaceEvenly,  // Truly even spacing
};
```

**Why**: Better control over spacing distribution.

### 3. Enhanced BoxConstraints

**From masonry_core**:

```zig
pub const BoxConstraints = struct {
    // ... existing fields

    pub const UNBOUNDED = BoxConstraints{
        .min_width = 0,
        .max_width = std.math.inf(f32),
        .min_height = 0,
        .max_height = std.math.inf(f32),
    };

    /// Create tight constraints (only one size satisfies)
    pub fn tight(width: f32, height: f32) BoxConstraints {
        return .{
            .min_width = width,
            .max_width = width,
            .min_height = height,
            .max_height = height,
        };
    }

    /// Remove minimum constraints
    pub fn loosen(self: BoxConstraints) BoxConstraints {
        return .{
            .min_width = 0,
            .max_width = self.max_width,
            .min_height = 0,
            .max_height = self.max_height,
        };
    }

    /// Clamp a size to fit within constraints
    pub fn constrain(self: BoxConstraints, width: f32, height: f32) Size {
        return .{
            .width = std.math.clamp(width, self.min_width, self.max_width),
            .height = std.math.clamp(height, self.min_height, self.max_height),
        };
    }

    /// Reduce constraints by an amount
    pub fn shrink(self: BoxConstraints, diff_width: f32, diff_height: f32) BoxConstraints {
        return .{
            .min_width = @max(0, self.min_width - diff_width),
            .max_width = @max(0, self.max_width - diff_width),
            .min_height = @max(0, self.min_height - diff_height),
            .max_height = @max(0, self.max_height - diff_height),
        };
    }

    pub fn isWidthBounded(self: BoxConstraints) bool {
        return std.math.isFinite(self.max_width);
    }

    pub fn isHeightBounded(self: BoxConstraints) bool {
        return std.math.isFinite(self.max_height);
    }

    /// Debug validation
    pub fn debugCheck(self: BoxConstraints, name: []const u8) void {
        if (std.math.isNan(self.min_width)) {
            std.debug.print("ERROR: {s} min_width is NaN\n", .{name});
        }
        // ... more checks
    }
};
```

**Why**: Essential utilities for robust layout calculations.

## Medium Priority Enhancements

### 4. Sizing Modes

**From Clay**: Different sizing strategies per axis

```zig
pub const SizingType = enum {
    Fit,     // Size to content (like CSS fit-content)
    Grow,    // Flexible growth (current flex>0 behavior)
    Fixed,   // Exact size
    Percent, // Percentage of parent
};

pub const SizingAxis = struct {
    type: SizingType,
    value: f32, // Meaning depends on type
    min: f32 = 0,
    max: f32 = std.math.inf(f32),
};

pub const FlexChild = struct {
    width: SizingAxis,
    height: SizingAxis,
};
```

**Usage**:
```zig
// Fit to content
.width = .{ .type = .Fit, .value = 0 }

// Grow with flex=2
.width = .{ .type = .Grow, .value = 2 }

// Fixed 200px
.width = .{ .type = .Fixed, .value = 200 }

// 50% of parent
.width = .{ .type = .Percent, .value = 0.5 }

// Fit, but between 100-300px
.width = .{ .type = .Fit, .value = 0, .min = 100, .max = 300 }
```

**Why**: Matches CSS flexbox capabilities, very flexible.

### 5. Per-Axis Min/Max Constraints

**From Clay**: Each axis has independent min/max

Currently we have global flex value. Instead:
```zig
pub const FlexChild = struct {
    width: SizingAxis,
    height: SizingAxis,
};
```

**Why**: Common UI pattern - "grow to fill, but not smaller than X or larger than Y"

### 6. Cross-Axis Stretch Implementation

When `cross_alignment = .Stretch`, children fill the cross axis.

**Example**:
```zig
// Horizontal container with stretch
// All children get same height = container height
flex.cross_alignment = .Stretch;
```

**Why**: Standard flexbox behavior, useful for card layouts.

## Low Priority Enhancements

### 7. Wrap Support

**From CSS**: `flex-wrap`

```zig
pub const FlexWrap = enum {
    NoWrap,  // Single line (current behavior)
    Wrap,    // Multi-line, wrap to next row/column
};
```

**Why**: Handle overflow gracefully, useful for tag lists, button groups.

### 8. Debug Visualization

**From Clay**: `Clay__RenderDebugLayout()`

```zig
pub fn renderDebug(container: *FlexContainer, ctx: *c.mcore_context_t, bounds: Rect) void {
    // Draw container bounds
    // Draw padding area
    // Draw child bounds
    // Label with sizing info
}
```

**Why**: Invaluable for debugging layout issues.

## Implementation Strategy

### Phase 2.1: Alignment (High Priority)
1. Add `CrossAxisAlignment` enum
2. Add `MainAxisAlignment` enum
3. Update `FlexContainer.layout_children()` to respect alignment
4. Update demo to show all alignment options

### Phase 2.2: Enhanced Constraints (High Priority)
1. Add utility methods to `BoxConstraints`
2. Add validation/debug helpers
3. Use in flexbox calculations

### Phase 2.3: Sizing Modes (Medium Priority)
1. Define `SizingType` and `SizingAxis`
2. Update `FlexChild` to use sizing axes
3. Implement each sizing type in layout algorithm
4. Handle min/max clipping

### Phase 2.4: Polish (Low Priority)
1. Wrap support (complex, deferred)
2. Debug visualization
3. Performance optimizations

## References

- **Clay**: `references/clay/clay.h` (lines 67-73 sizing, 279-312 alignment)
- **masonry_core**: `references/xilem/masonry_core/src/core/box_constraints.rs`
- **CSS Flexbox**: [MDN Flexbox Guide](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_Flexible_Box_Layout)

## Notes

- Keep it simple: Don't implement everything at once
- Clay's approach is closest to our immediate-mode style
- masonry_core has great constraint utilities we can borrow
- Test each enhancement with the demo before moving to next phase
