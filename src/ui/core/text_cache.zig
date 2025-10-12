const std = @import("std");
const layout_mod = @import("../layout.zig");
const c_api = @import("../../renderer/c_api.zig");
const c = c_api.c;

/// Key for text measurement cache
/// Includes all parameters that affect text measurement
const CacheKey = struct {
    text_hash: u64,
    font_size: u32, // Store as bits to avoid floating point comparison
    max_width: u32, // Store as bits
    scale: u32, // Store as bits

    fn init(text: []const u8, font_size: f32, max_width: f32, scale: f32) CacheKey {
        return .{
            .text_hash = std.hash.Wyhash.hash(0, text),
            .font_size = @bitCast(font_size),
            .max_width = @bitCast(max_width),
            .scale = @bitCast(scale),
        };
    }

    fn eql(a: CacheKey, b: CacheKey) bool {
        return a.text_hash == b.text_hash and
            a.font_size == b.font_size and
            a.max_width == b.max_width and
            a.scale == b.scale;
    }

    fn hash(key: CacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.text_hash));
        hasher.update(std.mem.asBytes(&key.font_size));
        hasher.update(std.mem.asBytes(&key.max_width));
        hasher.update(std.mem.asBytes(&key.scale));
        return hasher.final();
    }
};

/// Cached text size result
const CacheValue = struct {
    width: f32,
    height: f32,
};

/// Statistics for cache performance
pub const CacheStats = struct {
    hits: u32 = 0,
    misses: u32 = 0,
    unique_entries: u32 = 0,
};

/// Frame-scoped text measurement cache
/// Uses the frame arena for storage, so it's automatically cleared each frame
pub const TextCache = struct {
    map: std.AutoHashMapUnmanaged(CacheKey, CacheValue),
    stats: CacheStats,

    pub fn init() TextCache {
        return .{
            .map = .{},
            .stats = .{},
        };
    }

    pub fn deinit(self: *TextCache, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    /// Begin a new frame - reset stats only, keep cached measurements
    /// The cache persists across frames for better performance
    /// Call invalidate() if font configuration or scale changes
    pub fn beginFrame(self: *TextCache, persistent_allocator: std.mem.Allocator) void {
        // Reset per-frame stats but keep the cache entries
        self.stats.hits = 0;
        self.stats.misses = 0;
        self.stats.unique_entries = @intCast(self.map.count());

        // Pre-allocate based on typical usage (can tune this)
        // Use persistent allocator because frame arena doesn't support reallocation
        if (self.map.capacity() == 0) {
            self.map.ensureTotalCapacity(persistent_allocator, 128) catch {};
        }
    }

    /// Invalidate the entire cache (call when font configuration or scale changes)
    pub fn invalidate(self: *TextCache) void {
        self.map.clearRetainingCapacity();
        self.stats.unique_entries = 0;
    }

    /// Measure text with caching
    pub fn measureText(
        self: *TextCache,
        allocator: std.mem.Allocator,
        ctx: *c.mcore_context_t,
        text: []const u8,
        font_size: f32,
        max_width: f32,
        scale: f32,
    ) layout_mod.Size {
        const key = CacheKey.init(text, font_size, max_width, scale);

        // Check cache
        if (self.map.get(key)) |cached| {
            self.stats.hits += 1;
            return .{ .width = cached.width, .height = cached.height };
        }

        // Cache miss - measure and store
        self.stats.misses += 1;

        var size: c.mcore_text_size_t = undefined;
        c.mcore_measure_text(ctx, text.ptr, font_size, max_width, &size);

        const value = CacheValue{
            .width = size.width,
            .height = size.height,
        };

        // Store in cache
        self.map.put(allocator, key, value) catch {
            // If allocation fails, just return the result without caching
            return .{ .width = size.width, .height = size.height };
        };

        self.stats.unique_entries = @intCast(self.map.count());
        return .{ .width = size.width, .height = size.height };
    }

    /// Get current cache statistics
    pub fn getStats(self: *const TextCache) CacheStats {
        return self.stats;
    }

    /// Get cache hit rate as a percentage (0-100)
    pub fn getHitRate(self: *const TextCache) f32 {
        const total = self.stats.hits + self.stats.misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.stats.hits)) / @as(f32, @floatFromInt(total)) * 100.0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TextCache - basic caching" {
    var cache = TextCache.init();
    defer cache.deinit(std.testing.allocator);

    cache.beginFrame(std.testing.allocator);

    // We can't actually test measurement without a real context,
    // but we can test the key generation and cache behavior
    const key1 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const key2 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const key3 = CacheKey.init("world", 14.0, 100.0, 1.0);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
}

test "TextCache - key sensitivity" {
    // Different text
    const k1 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const k2 = CacheKey.init("world", 14.0, 100.0, 1.0);
    try std.testing.expect(!k1.eql(k2));

    // Different font size
    const k3 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const k4 = CacheKey.init("hello", 16.0, 100.0, 1.0);
    try std.testing.expect(!k3.eql(k4));

    // Different max width
    const k5 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const k6 = CacheKey.init("hello", 14.0, 200.0, 1.0);
    try std.testing.expect(!k5.eql(k6));

    // Different scale
    const k7 = CacheKey.init("hello", 14.0, 100.0, 1.0);
    const k8 = CacheKey.init("hello", 14.0, 100.0, 2.0);
    try std.testing.expect(!k7.eql(k8));
}
