# TEXT_STRESS_GARBAGE.md

## Problem Description

The text-stress demo displays garbage characters (red striped boxes) instead of the formatted performance statistics, even though:
1. Debug output shows the strings are formatted correctly (`"Hit Rate: 0.0%"`)
2. The buffers are function-scoped and should remain valid
3. The buffers are zero-initialized to avoid uninitialized memory

## Current Understanding

### How Text Rendering Works
1. **Command Buffer Pattern**: UI widgets don't render immediately. They store commands in a buffer.
2. **Text Pointer Storage**: The `DrawCommand` struct stores `text_ptr: ?[*:0]const u8` - a pointer to text, NOT a copy
3. **Deferred Rendering**: Text is rendered later in `endFrame()`, after all layout is complete

### The Lifetime Problem
```zig
fn renderStatsHeader(ui: *zello.UI) void {
    var buf1: [128]u8 = [_]u8{0} ** 128;

    const hit_rate_text = std.fmt.bufPrintZ(&buf1, "Hit Rate: {d:.1}%", .{hit_rate});
    ui.label(hit_rate_text, .{ ... });  // Stores pointer to buf1

    // buf1 is still valid here...
}
// ...but what happens to the pointer after this?
```

The function-scoped buffer `buf1` should remain valid until the function returns. Since `endFrame()` is called via `defer` in `onFrame()`, and `renderStatsHeader()` is called from within `onFrame()`, the buffers should still be valid when rendering happens.

### Why Showcase Works But Text-Stress Doesn't

**Showcase pattern (works):**
```zig
fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(WHITE) catch {};

    // Direct in onFrame scope
    var counter_buf: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrintZ(&counter_buf, "Count: {d}", .{counter});
    ui.label(counter_text, ...);

    // counter_buf lives until endFrame() via defer
}
```

**Text-stress pattern (broken):**
```zig
fn onFrame(ui: *zello.UI, time: f64) void {
    ui.beginFrame();
    defer ui.endFrame(WHITE) catch {};

    renderStatsHeader(ui);  // Call separate function
}

fn renderStatsHeader(ui: *zello.UI) void {
    var buf1: [128]u8 = [_]u8{0} ** 128;
    const text = std.fmt.bufPrintZ(&buf1, ...);
    ui.label(text, ...);

    // buf1 goes out of scope HERE
} // <-- Function returns

// Later, endFrame() tries to render using the pointer...
// ...but buf1 is gone!
```

## The Real Problem: Stack Frame Lifetime

When `renderStatsHeader()` returns:
1. Its stack frame is popped
2. Local variables (buf1-buf10) are no longer valid
3. The pointers stored in the command buffer now point to invalid memory
4. `endFrame()` tries to read from these invalid addresses
5. Whatever is at those memory locations gets interpreted as text → garbage

## Why It Sometimes "Works"
- Stack memory isn't immediately overwritten
- Sometimes the old values are still there by chance
- Other function calls might overwrite the stack
- This is classic **use-after-free** but with stack memory instead of heap

## Proof: The Debug Output
The debug output `hit_rate_text: 'Hit Rate: 0.0%'` proves the string is formatted correctly **at the time of creation**. But by the time rendering happens, that memory location contains something else.

## Solutions

### Option 1: Keep Buffers in onFrame Scope (Simple)
Move all buffer declarations to `onFrame()` and pass them to `renderStatsHeader()`:
```zig
fn onFrame(ui: *zello.UI, time: f64) void {
    var stats_buffers: [10][128]u8 = undefined;
    renderStatsHeader(ui, &stats_buffers);
    // Buffers live until defer endFrame() runs
}
```

### Option 2: Copy Strings to Frame Arena (Proper Fix)
Modify the command buffer to copy text into the frame arena:
```zig
pub fn text(self: *CommandBuffer, frame_arena: std.mem.Allocator, str: [:0]const u8, ...) !void {
    // Copy string into frame arena
    const text_copy = try frame_arena.dupeZ(u8, str);

    self.commands[self.count] = .{
        .text_ptr = text_copy.ptr,  // Points to frame arena memory
        ...
    };
}
```

### Option 3: Make buffers static (Hacky)
```zig
fn renderStatsHeader(ui: *zello.UI) void {
    const State = struct {
        var buf1: [128]u8 = [_]u8{0} ** 128;
        var buf2: [128]u8 = [_]u8{0} ** 128;
        // ...
    };

    const text = std.fmt.bufPrintZ(&State.buf1, ...);
    // Static memory lives forever
}
```

## Recommendation

**Option 2 is the correct fix** because:
1. Eliminates the lifetime footgun entirely
2. Frame arena already exists and is designed for per-frame data
3. Text strings are naturally per-frame (recreated every frame)
4. Makes the API safer - users don't need to worry about lifetimes

The command buffer should own the text data, not just reference it.

## Why This Is A Footgun

This is a dangerous API pattern because:
1. **Non-obvious lifetime requirements**: The API doesn't make it clear that strings must outlive the frame
2. **No compile-time protection**: Zig can't detect this use-after-free with stack memory
3. **Works by accident**: Short examples work because stack isn't reused yet
4. **Hard to debug**: Appears as "random" garbage or corruption
5. **Violates immediate-mode semantics**: Immediate-mode UI should not require manual lifetime management

Every user will eventually hit this bug when they try to extract helper functions like `renderStatsHeader()`.
