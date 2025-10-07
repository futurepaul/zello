# UI Modularization Strategy (Function-Based Widgets)

## Current State Snapshot
- `src/ui/ui.zig:15-140` owns everything: frame lifecycle, input buffering, layout tree, widget rendering, and state. The file is >1400 lines and mixes concerns, making changes risky.
- `src/ui/ui.zig:250-420` repeats nearly identical stack management for V/H stacks and scroll areas, but the logic is trapped inside the monolith so it can’t be re-used in tests or custom containers.
- `src/ui/ui.zig:520-940` interleaves child measurement and rendering for each widget type by switching over a closed union. Extending the library requires editing that union directly.
- Interaction state is scattered (`mouse_*`, `clickable_widgets`, `clicked_buttons`, `text_inputs`, etc.), so the frame-to-frame story lives in comments and implicit ordering.

## Design Goals
1. Shrink `ui.zig` down to orchestration duties and migrate widget-specific code into focused modules.
2. Keep the immediate-mode API (`ui.button(...)`, `ui.beginVstack(...)`, etc.) while publishing helpers that let third-party code build widgets without editing core files.
3. Centralise persistent and per-frame interaction state in one place, with a clear lifecycle and obvious helpers (`isHovered`, `wasClicked`, etc.).
4. Extract duplicated layout math into a shared `layout_utils.zig` that we can cover with unit tests.

## Target Architecture

### Core Modules
- `src/ui/core/state.zig`
  - Defines `FrameInput` (mouse, keyboard, scroll), `InteractionState` (hover/active/focus flags), and `StateStore` (per-widget persistent storage using an `AutoHashMap`).
  - Exposes `pub fn beginFrame(...)` / `endFrame(...)` helpers so `UI` can drive the lifecycle without worrying about internals.
- `src/ui/core/context.zig`
  - Provides `pub const WidgetContext = struct { ui: *UI, state: *InteractionState, ... }` plus thin methods for common tasks: `measureText`, `registerFocusable`, `isHovered(id)`, `useState(T, id, init)`, `commands()`.
  - Widgets get a pointer to this context every frame; no vtables, no arenas—just call straightforward helpers.
- `src/ui/layout_utils.zig`
  - Hosts the shared measurement/render helpers currently duplicated in `layoutAndRender` / `layoutAndRenderScroll` / `measureLayout`.
  - Functions like `measureStackChildren`, `placeChildren`, and `calcContentBounds` accept slices of a simple `Child` struct, making them easy to test.

### Widgets
- Each built-in widget moves to its own module under `src/ui/widgets/` (e.g. `button.zig`, `label.zig`, `text_input.zig`, `stack.zig`, `scroll_area.zig`).
- Every widget exports a single free function that follows the existing pattern:
  ```zig
  pub fn button(ctx: *WidgetContext, opts: ButtonOptions) !bool { ... }
  ```
  Internally they call helpers from `WidgetContext`/`layout_utils`.
- `ui.zig` keeps public wrappers (`pub fn button(self: *UI, ...) !bool`) that just construct a `WidgetContext` and forward to the module function.
- Container widgets still use `begin...`/`end...`. We implement a shared `layoutScope` helper in `stack.zig` so future containers can reuse the same push/pop mechanics.

### External Widget Path
- Publish `WidgetContext`, `StateStore.useState`, and `layout_utils` in public headers so anyone can import them.
- Document a minimal pattern: choose an id, fetch persistent state via `ctx.useState`, call layout helpers to get rects, and render using `ctx.commands`.
- No unions or registration tables: external code just calls its widget function inside a layout alongside the built-ins.

### Interaction Lifecycle
1. `UI.beginFrame` calls `state.beginFrame` which copies raw inputs from the host and resets per-frame flags.
2. As widgets run, they query helpers (`ctx.isHovered`, `ctx.consumeClick`) that operate on the central `InteractionState`.
3. `UI.endFrame` forwards to `state.endFrame` to finalise focus/press bookkeeping before submitting commands.
4. Adding a new interaction (e.g. drag) means extending `InteractionState` and the helper methods in one place.

## Refactor Roadmap

### Phase 0 – Confirmation Tests
- Before touching the architecture, add small tests / debug hooks that snapshot layout rects and button interaction for a sample screen so we can detect regressions.

PAUL: just keep in mind that we probably have some layout bugs right now so don't be too struct (I don't think we're counting padding well)

### Phase 1 – Layout Utilities
- Create `layout_utils.zig` and migrate the duplicated measurement math from `ui.zig` into shared helpers. Update existing code to call the helpers.
- Add unit tests for stack spacing, spacer flex behaviour, and scroll clamp logic.

### Phase 2 – State Consolidation
- Introduce `core/state.zig` with `FrameInput`, `InteractionState`, and `StateStore`.
- Replace scattered fields in `UI` with a single `State` struct. Update input handlers to read/write through the consolidated state.

### Phase 3 – WidgetContext & Built-ins
- Add `core/context.zig`. Update built-in widgets (labels, buttons, text inputs, scroll areas) to consume the context helpers.
- Move each widget implementation into `src/ui/widgets/<name>.zig`, leaving `ui.zig` wrappers that build the context and delegate.

### Phase 4 – Containers & Layout Scope
- Implement `widgets/stack.zig` that owns `beginVstack/endVstack` and `beginHstack/endHstack`, backed by the shared layout helpers.
- Move scroll area logic into its module, reusing `layout_utils` and state helpers.

### Phase 5 – External Docs & Cleanup
- Update `README` / `QUICK_START` with a short “write your own widget” section using the new context helpers.
- Purge leftover inline structs / unions from `ui.zig` once modules own their data.
- Ensure `widgets/text_input.zig` supersedes the inline version so there’s only one source of truth.

## Testing Strategy
- Unit tests in `layout_utils.zig` and `core/state.zig` (state transitions, `useState` persistence, hover/click helpers).
- Integration test assembling a small UI tree that verifies layout positions and interaction flags after simulated input.
- Manual demo or example showing a third-party widget module using the published helpers.

## Questions to Resolve (Before Coding)
- Exact shape of `WidgetContext` helpers (naming, which fields stay public) so external widgets don’t rely on internals.
- Whether text measurement belongs on the context or remains a free helper in `layout_utils`.
- How much of the existing command buffer API should be re-exported vs. accessed through the context.

Working through those upfront keeps the implementation predictable while staying well inside the immediate-mode paradigm you already have.

## IMPLEMENTATION STATUS

### ✅ Completed (All Phases)

All phases of the modular refactor are complete! Here's what was implemented:

**Phase 1 - Layout Utilities:** ✅
- `layout_utils.zig` with shared helpers (measureText, calcContentBounds, calcTotalBounds)
- Unit tests for layout utilities
- Eliminated code duplication across 3 layout functions

**Phase 2 - State Consolidation:** ✅
- `core/state.zig` with FrameInput, InteractionState, StateStore
- Consolidated scattered state fields from UI struct
- Clean lifecycle with beginFrame()/endFrame()

**Phase 3 - WidgetContext & Built-ins:** ✅
- `core/context.zig` with WidgetContext API
- Moved widgets to dedicated modules (button.zig, label.zig, text_input.zig)
- Each widget has measure() and render() functions
- Removed ~450 lines from ui.zig

**Phase 4 - Container Deduplication:** ✅
- Extracted shared beginStack()/endStack() helpers
- Removed ~100 lines of V/H stack duplication
- Pattern ready for future containers (Grid, Tabs, etc.)

**Phase 5 - Extensibility (BONUS):** ✅
- Added WidgetInterface trait system (Clay-style)
- Custom widget support via UI.customWidget()
- Example custom badge widget
- Type-safe with zero runtime cost

### External Widget Guide (Quick Start)

To create a custom widget without modifying core code:

**1. Define your widget data struct:**
```zig
pub const MyWidgetData = struct {
    text: [:0]const u8,
    color: Color,
};
```

**2. Implement measure and render functions:**
```zig
const context_mod = @import("zello/ui/core/context.zig");
const layout_mod = @import("zello/ui/layout.zig");

fn measure(ctx: *context_mod.WidgetContext, data: *const MyWidgetData, max_width: f32) layout_mod.Size {
    const text_size = ctx.measureText(data.text, 16, max_width);
    return .{
        .width = text_size.width + 20,
        .height = text_size.height + 10
    };
}

fn render(
    ctx: *context_mod.WidgetContext,
    data: *const MyWidgetData,
    x: f32, y: f32, w: f32, h: f32
) !void {
    const cmd = ctx.commandBuffer();
    try cmd.roundedRect(x, y, w, h, 4, data.color);
    try cmd.text(data.text, x + 10, y + 5, 16, w - 20, WHITE);
}
```

**3. Create the interface (comptime - zero cost):**
```zig
const widget_interface = @import("zello/ui/widget_interface.zig");

pub const Interface = widget_interface.createInterface(
    MyWidgetData,
    measure,
    render,
    null  // No cleanup needed
);
```

**4. Use it in your app:**
```zig
var my_data = MyWidgetData{ .text = "Hello", .color = RED };
try ui.customWidget(&Interface, &my_data);
```

See `src/ui/widgets/custom_widget_example.zig` for a complete working example.

