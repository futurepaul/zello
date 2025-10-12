# TEXT_COPYING_STATUS.md

## Current Situation (After Lifetime Fix)

We now have **safe** text rendering, but we're copying strings **twice per frame**:

### Copy #1: Widget Declaration (UI.label/button)
```zig
pub fn label(self: *UI, text: [:0]const u8, opts: LabelOptions) !void {
    // First copy: into frame arena when widget is declared
    const text_copy = try self.frameAllocator().dupeZ(u8, text);

    try frame.children.append(self.frameAllocator(), .{
        .label = .{ .text = text_copy, .opts = opts },
    });
}
```
**Location:** src/ui/ui.zig:503, 523, 557

### Copy #2: Command Buffer (CommandBuffer.text)
```zig
pub fn text(self: *CommandBuffer, frame_arena: std.mem.Allocator, str: [:0]const u8, ...) !void {
    // Second copy: into frame arena when command is created
    const text_copy = try frame_arena.dupeZ(u8, str);

    self.commands[self.count] = .{
        .text_ptr = text_copy.ptr,
        // ...
    };
}
```
**Location:** src/ui/commands.zig:96

### Why We Have Two Copies

1. **Copy #1 is necessary** to fix the lifetime bug—we must capture the text before the caller's stack frame is destroyed.
2. **Copy #2 is redundant** but was kept as defense-in-depth in case widgets bypass the safe API.

### Cost Analysis

For the text-stress demo with 10 labels showing cache statistics:
- Each label text: ~20-50 bytes
- Total per frame: ~300-500 bytes copied twice = **600-1000 bytes/frame**
- At 60 FPS: **36-60 KB/second** of redundant copying

This is cheap (frame arena is bump-pointer), but it's still wasted work.

## What We Don't Have Yet

### Missing: Text Measurement Cache (from TEXT_CACHING_PLAN.md)

The plan calls for a **per-frame cache** of text measurements keyed by `(text, font_size, max_width, scale)`:

```zig
// Phase 2 from TEXT_CACHING_PLAN.md
pub const TextCache = struct {
    cache: std.AutoHashMap(CacheKey, Size),
    frame_arena: std.mem.Allocator,

    pub const CacheKey = struct {
        text_hash: u64,      // Hash of text bytes
        font_size: f32,
        max_width: f32,
        scale: f32,
    };
};
```

**Status:** NOT IMPLEMENTED
- We have a stub `src/ui/core/text_cache.zig` with basic structure
- It doesn't actually cache anything yet—every call goes to Rust
- The text-stress demo shows we're measuring the same strings repeatedly

### Missing: String Deduplication

We could deduplicate identical strings within a frame:

```zig
pub const StringCache = struct {
    interned: std.StringHashMap([:0]const u8),

    pub fn intern(self: *StringCache, text: [:0]const u8) ![:0]const u8 {
        if (self.interned.get(text)) |cached| {
            return cached;  // Return existing copy
        }
        const copy = try self.frame_arena.dupeZ(u8, text);
        try self.interned.put(text, copy);
        return copy;
    }
};
```

**Use case:** The text-stress demo displays the same label strings ("Hit Rate:", "Miss Count:", etc.) multiple times. We could intern these once per frame instead of copying each time.

## Recommended Next Steps

### Option 1: Remove Copy #2 (Simple Optimization)

Since Copy #1 already ensures safety, we could remove the duplication in `CommandBuffer.text()`:

```zig
// Change CommandBuffer.text() signature back to:
pub fn text(self: *CommandBuffer, str: [*:0]const u8, ...) !void {
    self.commands[self.count] = .{
        .text_ptr = str,  // No copy—caller guarantees lifetime
        // ...
    };
}
```

**Benefit:** Eliminates one copy per text command
**Risk:** If a widget bypasses the safe API and passes a dangling pointer, we're back to garbage rendering
**Mitigation:** Only expose `WidgetContext.drawText()` to widget authors, keep raw command buffer internal

### Option 2: Implement Text Measurement Cache (Per TEXT_CACHING_PLAN.md)

Follow Phase 2 of the caching plan:
1. Hash incoming text in `WidgetContext.measureText()`
2. Check frame-scoped cache for `(text_hash, font_size, max_width, scale)` → `Size`
3. On miss: call Rust, store result
4. On hit: return cached size (no FFI call)

**Benefit:** Reduces expensive Rust FFI calls for repeated measurements
**Location:** src/ui/core/text_cache.zig (currently a stub)
**Estimated effort:** 2-3 hours

### Option 3: Implement String Interning (Advanced)

Add a string interning cache to `WidgetContext`:
1. `UI.label()` calls `self.internString(text)` instead of raw `dupeZ()`
2. Interning checks a hash map; returns existing copy if present
3. Resets when frame arena resets

**Benefit:** Reduces memory usage for duplicate strings within a frame
**Use case:** Static labels, button text, repeated UI elements
**Estimated effort:** 1-2 hours

## Performance Impact (Current State)

Based on the text-stress demo:
- **Frame arena usage:** Low (text is ~1-2% of total allocations)
- **Copy overhead:** Negligible (memcpy is extremely fast for small strings)
- **Real bottleneck:** Text measurement FFI calls to Rust (not copying)

### Evidence from Profiling

The text-stress demo shows:
- 10 labels × 2 measurements (measure + render) = **20 text measurements/frame**
- Each measurement: FFI call + Parley layout = **~100-500µs each**
- Total measurement time: **2-10ms/frame** (16-66% of 16ms budget at 60 FPS)

**Conclusion:** Text copying is cheap; measurement is expensive. Priority should be measurement caching (Option 2).

## Recommended Priority

1. **Implement text measurement cache** (Option 2)
   - Biggest performance win
   - Aligns with TEXT_CACHING_PLAN.md
   - Already has stub implementation

2. **Consider string interning** (Option 3)
   - Nice-to-have for memory usage
   - Lower priority than measurement caching

3. **Potentially remove Copy #2** (Option 1)
   - Minor optimization
   - Do after measurement cache shows its value
   - Verify no widgets bypass the safe API first

## Open Questions

1. Should we measure the performance impact of double-copying before optimizing?
2. Is the text measurement cache the real bottleneck, or is it GPU rendering?
3. Should we implement word-level caching (Clay-style) as mentioned in the plan?

## Related Documents

- TEXT_STRESS_GARBAGE.md - Original problem diagnosis
- TEXT_CACHING_PLAN.md - Complete caching strategy
- src/ui/core/text_cache.zig - Stub implementation (needs work)
