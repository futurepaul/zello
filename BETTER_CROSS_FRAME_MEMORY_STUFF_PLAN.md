# BETTER_CROSS_FRAME_MEMORY_STUFF_PLAN

## Goals
- Introduce a single allocator whose lifetime equals one frame so that all transient allocations are cheap to make and free, eliminating the current leak-prone pattern of manually managing `std.ArrayList` buffers.
- Define a principled cross-frame data contract: everything that must survive one frame boundary (hit-testing metadata, hover state, scroll info, etc.) lives in one place, has a clear producer/consumer order, and is reset in one step each frame.

This plan deliberately looks for places to simplify the system instead of layering more complexity on top. Expect some API and internal type changes to reach a cleaner model.

## Current Friction
- **Per-frame allocations are scattered.** Layout frames, widget lists, and temporary measurement arrays all allocate with the general allocator and rely on ad-hoc `defer ... .deinit()`. Nested layouts currently leak because we transfer ownership of `std.ArrayList` structures without freeing their buffers.
- **Cross-frame data is implicit.** `InteractionState` mixes input for the current frame with click results intended for the next frame, and the lifetime of each slice/map is unclear. The "previous frame bounding box" concept exists only implicitly through vectors that are cleared/reset in multiple places.
- **Difficult to reason about teardown order.** Because temporaries are freed manually, it is hard to tell what is safe to reuse or when it is valid to access structures such as `clickable_widgets`.

## Proposed Architecture

### 1. Frame Arena

Introduce a `FrameArena` that owns all per-frame memory:

```zig
const FrameArena = struct {
    backing_allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    cursor: usize,

    pub fn init(backing: std.mem.Allocator, initial: usize) FrameArena;
    pub fn allocator(self: *FrameArena) std.mem.Allocator;
    pub fn beginFrame(self: *FrameArena) void; // reset cursor, keep buffer
    pub fn endFrame(self: *FrameArena) void;   // optionally shrink/diagnostics
};
```

- Allocation strategy: bump-pointer into a reusable `ArrayListUnmanaged(u8)`. The arena grows (doubling) when needed, never shrinks inside a frame, and `beginFrame` simply rewinds `cursor = 0`.
- Use the arena allocator for _every structure that is rebuilt on each frame_: layout tree nodes, temporary measurement buffers, hit-test collections, a11y scratch, etc.
- Persistent data continues to use the existing allocator (`StateStore`, `FocusState`, renderer command buffers, cached text input state, etc.).
- To reduce boilerplate, introduce tiny helpers that wrap `FrameArena` for common patterns (e.g. `FrameList(T)` built on top of `ArrayListUnmanaged(T)` with the arena allocator injected).

This change lets us delete the manual `defer ... deinit()` chains sprinkled around layout traversal and guarantees the leak disappears because the arena reset wipes all per-frame allocations.

### 2. Frame Exchange (Cross-Frame Data Contract)

Create an explicit double-buffered structure that captures “what the next frame needs”:

```zig
const FrameExchange = struct {
    prev: FrameSnapshot,
    next: FrameSnapshot,

    pub fn beginFrame(self: *FrameExchange, arena: *FrameArena, viewport: layout.Rect, input: FrameInput) void;
    pub fn swap(self: *FrameExchange) void; // called by beginFrame internally
};

const FrameSnapshot = struct {
    clickables: FrameList(ClickableRecord),
    scroll_regions: FrameList(ScrollRegion),
    focusables: FrameList(u64), // if needed for tab order
    bounding_boxes: FrameMap(u64, layout.Rect),
    // extend as future cross-frame needs appear
};
```

Key rules:
- **Single producer:** only the render/layout pass populates `FrameExchange.next` via helpers (`frame_exchange.recordClickable(id, rect, kind)`).
- **Single consumer:** input handling and “declaration-time” queries (e.g. `isHovered(id)`) read from `FrameExchange.prev`.
- **Single clear:** `FrameExchange.beginFrame` swaps buffers, clears `next` (by rewinding the arena), and recomputes any derived state such as hover/click detection using the stored bounding boxes plus the latest input snapshot.

The hover/click flow then becomes:
1. Platform feeds mouse events into `UI.handleMouse*`, which only updates the `FrameInput` snapshot.
2. `UI.beginFrame` calls `frame_exchange.beginFrame(&arena, viewport_rect, interaction.input)`. This step:
   - Swaps `prev`/`next`.
   - Clears `next`.
   - Runs hover detection against `prev.clickables` using last frame’s bounding boxes, producing `prev.hovered_id`, `prev.pressed_id`, etc., and stores those results so they can be queried immediately during layout.
3. During layout/render, widgets call `frame_exchange.emitClickable(id, rect, kind)` (and friends). Those records live in `next` and will be used on the following frame.

Compared with the current `InteractionState`, this removes the concept of “clearing some pieces here, other pieces later” and gives us one place to reset and reason about cross-frame lifetime. Bounding boxes, click history, and scroll areas are all scoped to the snapshots.

### 3. Simplifying Surface APIs

- Replace `InteractionState` with two clearer types:
  - `InputState` (current frame, immediate mouse/keyboard snapshot).
  - `FrameExchange` (double-buffered cross-frame metadata).
- Update `WidgetContext` to pull hover/press information from `FrameExchange.prev` instead of ad-hoc hit testing against mutable vectors. The `WidgetContext` methods (`isHovered`, `registerClickable`, etc.) simply forward into the new structs.
- Revisit layout data structures while adopting the arena. Rather than storing a full `std.ArrayList(WidgetData)` inside every `LayoutFrame`, consider a lighter tree representation:
  - Each `LayoutNode` allocated from the arena stores the widget payload plus `first_child` / `next_sibling` indices. This deletes the `children.append(...)` / ownership transfer shuffle and reduces the amount of state we push/pull on the layout stack.
  - If we keep array-style children for now, we still gain the benefit of using `FrameList` so we no longer need per-node allocators or manual deinit.

These changes shrink the number of moving parts while keeping external ergonomics (e.g. `ui.button(...)` API) intact.

## Implementation Checklist

1. **Lay the foundation**
   - Add `FrameArena` to `UI`.
   - Convert layout-stack allocations (`LayoutFrame`, `WidgetData` lists, measurement buffers) to use the arena allocator.
   - Expose a `ui.frameAllocator()` helper if needed for custom widgets.

2. **Introduce FrameExchange**
   - Define `FrameExchange`, `FrameSnapshot`, `ClickableRecord`, `ScrollRegion`, etc.
   - Update `UI.beginFrame/endFrame` to swap/clear snapshots alongside the command buffer reset.
   - Replace `InteractionState` storage with the new structures; keep existing `StateStore` untouched.

3. **Update widget/runtime APIs**
   - Rework `WidgetContext` and widget implementations (`button`, `text_input`, etc.) to record output exclusively through `FrameExchange`.
   - Migrate input handlers to read hover/press info from `FrameExchange.prev`.
   - Ensure scroll momentum updates and wheel registration happen via snapshot helpers (e.g. `frame_exchange.emitScrollRegion(...)`).

4. **Clean up the layout builder**
   - Optional but recommended: introduce arena-backed `LayoutNode` representation to avoid nested `ArrayList` ownership semantics.
   - Remove the now-obsolete manual `deinit` calls and any redundant state in `LayoutFrame`.

5. **Testing / validation**
   - Add instrumentation helpers to confirm the arena is rewound each frame (e.g. assert `arena.cursor <= capacity` after layout).
   - Stress-test nested layouts and multiple scroll regions to verify hover/click behaviour matches or improves on the current implementation.

## API / Behaviour Notes
- Expect `UI` to expose hooks such as `pub fn frameAllocator(self: *UI) std.mem.Allocator` for custom widget authors who need scratch space.
- `WidgetContext.isHovered()` will now consult `FrameExchange.prev` (hover computed using last frame’s boxes), so hover-aware widgets must tolerate the one-frame delay just like Clay. We can optionally provide both `isHoveredPrev()` and `isHoveredNow(bounds)` if needed.
- `InteractionState` disappears; instead, the public API becomes centred around `InputState` (current frame) and `FrameExchange` (what crosses the boundary). This may break private users that poked at `interaction` directly, which is acceptable in pursuit of a clearer design.

## Risks / Open Questions
- **Arena growth policy:** The bump allocator must cap runaway growth. We should capture metrics and perhaps add a debug toggle to dump peak usage per frame.
- **De-duplicating IDs:** When multiple widgets register the same id, we need a deterministic rule for which bounding box wins. Clay keeps the last declaration; we should document and enforce our own rule.
- **Custom widgets:** Third-party widgets that store pointers into per-frame data must be revalidated. The arena reset will invalidate raw pointers once the frame ends, so we should document this constraint.

## Desired Outcome

After these changes we should be able to describe the runtime succinctly:

1. `FrameArena.beginFrame` resets all transient memory.
2. `FrameExchange.beginFrame` swaps snapshots and precomputes hover/click state from last frame’s data.
3. Layout builds a tree using the frame arena, emits commands, and records next-frame metadata through `FrameExchange.next`.
4. `FrameArena.endFrame` can optionally collect statistics; `FrameExchange.next` is carried across the boundary for the following frame.

No more ad-hoc frees, no more mystery lifetime issues, and a single structure to audit whenever cross-frame behaviour changes.
