# FRAME_ARENA_WINS

## Goal
Convert all per-frame layout allocations to use the FrameArena allocator, eliminating manual `defer ... .deinit()` calls and ownership transfer issues.

## Per-Frame Allocations to Convert

### 1. `layout_stack: std.ArrayList(LayoutFrame)` (ui.zig:46)
**Current:** Uses general allocator (`self.allocator`)
**Change:** Use `self.frame_arena.allocator()` during initialization
**Impact:** Layout stack is built fresh each frame, perfect for arena

### 2. `LayoutFrame.children: std.ArrayList(WidgetData)` (ui.zig:1132)
**Current:** Created with empty `std.ArrayList(WidgetData){}`, uses general allocator
**Change:** Initialize with frame arena allocator
**Impact:** Removes 3 `defer frame.children.deinit(self.allocator)` calls

### 3. `WidgetData.layout.children: std.ArrayList(WidgetData)` (ui.zig:1102)
**Current:** Transferred from parent frame's children list
**Change:** Already uses frame arena once parent uses it
**Impact:** No ownership transfer issues

### 4. `WidgetData.scroll_layout.children: std.ArrayList(WidgetData)` (ui.zig:1111)
**Current:** Transferred from parent frame's children list
**Change:** Already uses frame arena once parent uses it
**Impact:** No ownership transfer issues

### 5. `FlexContainer.children: std.ArrayList(FlexChild)` (flex.zig:20)
**Current:** Uses allocator passed to `FlexContainer.init()`
**Change:** Pass frame arena allocator to FlexContainer
**Impact:** Removes ~10+ `flex.deinit()` calls throughout layout code

### 6. `flex.layout_children()` return value `[]Rect` (flex.zig:46)
**Current:** Uses `allocator.alloc()`, caller must free with `defer self.allocator.free(rects)`
**Change:** Use frame arena allocator
**Impact:** Removes 3 `defer self.allocator.free(rects)` calls

## Implementation Plan

### Phase 1: Update FlexContainer (flex.zig)
1. Keep allocator-based API (FlexContainer already takes allocator)
2. No changes needed to FlexContainer itself
3. Just pass frame arena allocator when creating FlexContainer instances

### Phase 2: Update UI Layout Initialization (ui.zig)
1. Change `beginStack()` to initialize children with frame allocator:
   ```zig
   .children = std.ArrayList(WidgetData).init(self.frameAllocator()),
   ```
2. Remove all `defer frame.children.deinit(self.allocator)` calls
3. Keep ownership transfer as-is (but now it's all in the arena)

### Phase 3: Update Layout and Render Functions (ui.zig)
1. Change `FlexContainer.init()` calls to use frame allocator:
   ```zig
   var flex = flex_mod.FlexContainer.init(self.frameAllocator(), axis);
   ```
2. Remove all `flex.deinit()` calls (no longer needed)
3. Remove all `defer self.allocator.free(rects)` calls after `flex.layout_children()`

### Phase 4: Clean Up (ui.zig)
1. Find any remaining manual deinit/free calls for layout structures
2. Verify no layout-related allocations use general allocator
3. Test thoroughly with nested layouts and scroll areas

## Expected Deletions

- ❌ Remove 3× `defer frame.children.deinit(self.allocator)`
- ❌ Remove 10+ `flex.deinit()` calls
- ❌ Remove 3× `defer self.allocator.free(rects)`
- ❌ Remove ownership transfer concerns

## Testing Strategy

1. Run showcase app (tests nested layouts, scroll areas, all widgets)
2. Run hello_world example (tests basic layout)
3. Verify no memory leaks (arena should show stable peak usage)
4. Test rapid layout changes (buttons, text input, scrolling)

## Risk Assessment

**Low Risk:**
- FlexContainer already uses passed allocator, just changing which one
- LayoutFrame children already use ArrayList pattern
- Arena reset handles all cleanup automatically

**Validation:**
- If we miss a conversion, compilation will fail (good!)
- If we forget to remove a deinit, it's a no-op on arena memory (safe)

## Success Criteria

✅ All layout structures use frame arena allocator
✅ No manual deinit/free calls for per-frame layout data
✅ Showcase app runs without errors
✅ No change in visual behavior
✅ Cleaner, simpler code
