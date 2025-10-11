# TEXT_CACHING_PLAN

This plan assumes the changes from `BETTER_CROSS_FRAME_MEMORY_STUFF_PLAN.md` have landed: a reusable per-frame arena exists, cross-frame interaction state is handled through the new frame exchange, and widgets have access to a predictable frame allocator. We will stage text measurement optimizations on top of that foundation so caching has the memory disciplines it needs.

## Goals
- Stop recomputing identical text metrics multiple times per frame by introducing a lightweight cache keyed by text content plus layout parameters.
- Provide tooling to observe cache effectiveness (miss counts, fallbacks) so we can justify further investment.
- Lay the groundwork for optional cross-frame caching in Rust without committing to the complexity until profiling supports it.

## Prerequisites
- Frame arena available from `UI.beginFrame()` and exposed through `WidgetContext` for temporary allocations.
- `FrameExchange` (or successor) established so per-frame stats have a well-defined reset point.
- Basic diagnostics overlay pattern (or equivalent) so cache counters can be surfaced to developers.

## Phase 1 – Instrument Current Behaviour
1. Add counters inside the Rust text measurement path (`text::measure_text`) for:
   - total measure requests per frame,
   - unique `(text, font_size, max_width, scale)` pairs per frame,
   - reflow-related measurements (where `max_width` changes).
2. Expose the counters to Zig through a small FFI struct queried once per frame.
3. Render the numbers in the existing stats/debug overlay to establish a baseline before caching.

## Phase 2 – Frame-Scoped Cache in Zig (Arena Backed)
1. Define a hash key struct in Zig that hashes:
   - text bytes (explicit length),
   - font size,
   - max width,
   - device scale (if applicable).
2. Allocate an open-addressing hash table out of the frame arena during `UI.beginFrame()` with capacity sized to expected widget count (allowing growth if needed).
3. Replace direct calls to `layout_utils.measureText()` with a cached version:
   - On cache hit: return the stored `Size`.
   - On miss: call into Rust, store the result, bump miss counter.
4. Ensure all widget measurement paths (buttons, labels, text inputs, custom widgets) go through the cached helper.
5. Add instrumentation for cache hits/misses and clear it alongside other per-frame stats.

## Phase 3 – API Touch Points and Safety
1. Update `WidgetContext.measureText()` to use the cache while keeping the signature unchanged for widget authors.
2. Provide an escape hatch (`WidgetContext.measureTextUncached()` or similar) for rare cases where callers must bypass caching (e.g. time-sensitive profiling).
3. Audit cursor positioning helpers and ensure they continue to call the Rust `measure_text_to_byte_offset()` function directly—no caching there yet to avoid prematurely storing per-offset metrics.

## Phase 4 – Stress Testing & Tooling
1. Build the proposed “long text reflow” demo:
   - Render multiple paragraphs in a scroll area.
   - Show cache counters (hits, misses, unique keys) in the overlay.
   - Trigger resize animations to validate cache behaviour.
2. Run the demo before and after enabling the cache to confirm that repeated frames hit the cache and the miss counter plateaus.
3. Capture peak cache occupancy to fine-tune the default table size and look for pathological key distributions.

## Phase 5 – Explore Cross-Frame Caching (Optional Follow-Up)
1. If profiling still shows significant recomputation, prototype a Rust-side cache using the existing `TextContext`:
   - Store recently built `Layout` objects keyed by the same hash (now including scale).
   - Attach a generation counter; reuse entries if font configuration matches and max width is unchanged.
   - Evict via simple LRU or generation aging.
2. Surface invalidation triggers (font changes, scale changes, window resize) so Zig can notify Rust when to flush.
3. Reconcile with frame cache: either let Zig skip caching when Rust reports a hit, or downgrade the Zig cache to a cheap pointer lookup that just orchestrates the Rust cache.

## Open Questions / Future Work
- Word-level caching (Clay-style) would let us own wrapping logic, but we should gate it on data from the instrumentation phases.
- Consider caching `measure_text_to_byte_offset` results if the cursor-math profiling shows it dominates input latency.
- Evaluate hashing strategy for large strings; we may want to store stable IDs for static strings to avoid hashing every frame.
- Decide whether cache counters belong in the accessibility or frame exchange snapshot for consistency with other per-frame diagnostics.

With this plan, text caching becomes a staged effort: first we gain visibility, then we exploit the new frame arena for cheap per-frame reuse, and finally we only step into cross-frame work if the numbers continue to justify it.
