# Single-Pass Layout/Render Proposal

## Motivation
- Mirror raylib-style immediate UIs where widgets emit draw calls as they are declared, eliminating the deferred tree we currently build in `src/ui/ui.zig`.
- Reduce per-frame allocations (`LayoutFrame.children`, nested `std.ArrayList`) and simplify debugging by keeping layout state strictly on the stack.
- Explore feasibility; even if we ultimately keep the two-phase layout, knowing the delta clarifies why the current architecture exists.

## Current Runtime Shape
- Declaration pass records widgets into `LayoutFrame.children` and `WidgetData` so closing a container (`endVstack`, `endScrollArea`) can perform measuring/layout/render (`src/ui/ui.zig:260` – `src/ui/ui.zig:596`).
- Flex sizing requires iterating the recorded children twice: once to measure intrinsic sizes, once to compute final positions and emit commands (`flex_mod.FlexContainer` plus `layoutAndRender`).
- Rendering functions (`widgets/*/render`) assume they receive final bounds; they do not own layout negotiation and depend on the second pass routing that information.
- Scroll areas, focus, and interaction bookkeeping piggy-back on the render traversal to register hit-test rectangles and scroll regions.

## What “Single Pass” Implies
- As soon as user code calls `ui.button(...)`, we must know its absolute bounds so we can render it and advance the layout cursor before the next widget.
- Each container must stream its children without allocating per-child structures that live past the declaration call stack.
- Any layout algorithm that depends on future siblings (flex grow/shrink, alignment, wrap) must either (a) pre-compute the needed aggregates before emitting the first child or (b) change semantics to avoid forward-looking information.

## Required Architectural Changes
1. **Replace Deferred Frames With Streaming Layout Cursors**
   - Introduce `LayoutCursor` structs that track current offset, remaining space, and aggregate grow/shrink weights for the open container.
   - `begin*` pushes a cursor; `end*` asserts no pending space and pops. No `LayoutFrame.children` or `WidgetData` allocations survive the function call.
   - Widgets read/write cursor state directly (e.g. `cursor.takeFixed(size)`, `cursor.takeFlex(weight)`).

2. **Rework Flex Solver**
   - The existing `FlexContainer` collects every child then solves; we instead need a two-stage cursor:
     1. **Pre-scan phase**: as each child is declared, call a lightweight `measure()` that updates aggregated totals (fixed sizes, flex weights) but does not emit commands. The result is stored on the cursor, not in a heap array.
     2. **Emit phase**: still inside the same call stack, when we have enough information (either after pre-scan completes or once remaining space becomes deterministic), call the widget’s `render()` immediately.
   - For strict “single pass” we need to restructure APIs so widgets hand back lambdas/closures that can be invoked later within the same container scope, or we accept a localized double loop inside the container but without allocating persistent arrays. (Raylib’s immediate UI effectively does this.)

3. **Widget API Adjustments**
   - Merge `measure()`/`render()` for simple widgets into a single `emit(bounds_hint, cursor)` entry point that:
     - Queries measurements from the renderer (`measureText`) as needed.
     - Writes commands via `CommandBuffer` once its bounds are finalized.
   - Scroll areas and custom widgets must expose hooks that let the container request “intrinsic size” without immediately rendering, then render later in the same scope once the scroll viewport is known.

4. **Command Buffer & Interaction Hooks**
   - Since render happens inline, widgets must register clickables/scroll regions at emit time rather than during the second traversal. This means `frame_exchange.recordClickable` stays, but we must ensure each widget calls it during its single entry point.
   - Accessibility tree construction also moves into the inline widget call (no change in responsibilities, but we lose the opportunity to traverse a second time for debugging).

5. **Scroll Areas**
   - Current design wraps children into a nested `LayoutFrame` and later calls `layoutAndRenderScroll`. In a streaming world we need a dedicated cursor that:
     - Computes content extent while walking children.
     - Applies scroll offset immediately when emitting commands.
   - Persisted scroll state (`ScrollArea`) remains, but the API must surface current offset to the inline renderer so it can translate commands on the fly.

6. **Stateful Widgets & Custom Layouts**
   - Any widget that currently stores expensive measurement results in `WidgetData` (e.g. text input buffer) must be refactored to either:
     - Cache those values in persistent widget state (`StateStore`) before render, or
     - Recompute on demand inside the single call.
   - Custom widget API should expose a `SinglePassWidget` trait (e.g. `pub fn emit(ctx: *WidgetContext, cursor: *LayoutCursor, opts: ...)`) to guarantee users can hook into the new model.

## Incremental Migration Plan
1. Build `LayoutCursor` abstractions alongside the existing `LayoutFrame`; hide them behind feature flags.
2. Convert the simplest container (`beginVstack` / `endVstack`) and basic widgets (label, spacer) to stream without allocating `WidgetData`.
3. Extend the cursor to support flex grow/shrink by adding the pre-scan + emit steps; verify parity with existing layout tests.
4. Port interactive widgets (button, text input) ensuring they still register clickables/focus correctly via inline calls.
5. Migrate scroll areas and floating layouts, adapting scroll offsets and clipping to be applied during inline emission.
6. Delete `LayoutFrame`/`WidgetData` scaffolding once all widgets use the new streaming APIs.

## Risks & Trade-offs
- **Algorithmic complexity:** Flex-style distribution inherently needs aggregate knowledge. Either we accept a localized two-loop structure per container or simplify layout semantics (e.g. forbid grow+shrink mixes) to stay purely single pass.
- **Hot allocation pressure:** While we eliminate the big per-frame arrays, some widgets may end up allocating temporary buffers more often because they can’t stash them in deferred `WidgetData`.
- **Custom widget breakage:** Third-party widgets relying on the old `measure` + `render` split must be rewritten; we would need migration shims.
- **Debug tooling:** Current debug overlays leverage the deferred tree to draw bounds. Inline emission means we must emit debug commands immediately, which may make certain overlays harder to implement without replay capability.

## When It’s Worth Doing
- Target platforms with extremely tight memory budgets where the existing per-frame arrays are too expensive.
- Integrations that need to interleave UI rendering with other immediate-mode drawing APIs without buffering commands.
- Cases where we want to short-circuit layout early (e.g. stop once visible region is saturated) since inline emission can naturally break out mid-container.

For now this remains an exploratory path; the deferred two-pass approach keeps flex semantics straightforward and matches how `FrameExchange` expects hover/click data to arrive. This document should help evaluate whether the additional complexity buys us meaningful wins before committing to an overhaul.
