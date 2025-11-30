//! Layout Cache - Aggressive caching for layout results
//!
//! Research shows layout caching can provide 2-5x speedup for incremental updates.
//! We cache layout results keyed by constraints and style version.

const std = @import("std");
const core = @import("../../../src/root.zig").core;

const Size = core.Size;
const Rect = core.Rect;

/// Cache entry for a single element's layout result
///
/// Memory: 48 bytes (fits in one cache line with other hot data)
pub const LayoutCacheEntry = struct {
    /// Input constraints hash (to detect cache invalidation)
    available_width: f32 = -1.0,
    available_height: f32 = -1.0,

    /// Style version (incremented on style changes)
    style_version: u64 = 0,

    /// Cached layout result
    computed_width: f32 = 0,
    computed_height: f32 = 0,

    /// Cache metadata
    valid: bool = false,
    _padding: [7]u8 = undefined,  // Align to 48 bytes

    /// Check if cache entry is valid for given inputs
    pub inline fn isValid(
        self: *const LayoutCacheEntry,
        avail_w: f32,
        avail_h: f32,
        style_ver: u64,
    ) bool {
        return self.valid and
               self.available_width == avail_w and
               self.available_height == avail_h and
               self.style_version == style_ver;
    }

    /// Invalidate this cache entry
    pub inline fn invalidate(self: *LayoutCacheEntry) void {
        self.valid = false;
    }

    /// Update cache with new result
    pub fn update(
        self: *LayoutCacheEntry,
        avail_w: f32,
        avail_h: f32,
        style_ver: u64,
        result_w: f32,
        result_h: f32,
    ) void {
        self.available_width = avail_w;
        self.available_height = avail_h;
        self.style_version = style_ver;
        self.computed_width = result_w;
        self.computed_height = result_h;
        self.valid = true;
    }

    /// Get cached size (assumes isValid check passed)
    pub inline fn getSize(self: *const LayoutCacheEntry) Size {
        return Size{
            .width = self.computed_width,
            .height = self.computed_height,
        };
    }
};

/// Statistics for cache performance analysis
pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    invalidations: u64 = 0,

    pub fn reset(self: *CacheStats) void {
        self.* = .{};
    }

    pub fn recordHit(self: *CacheStats) void {
        self.hits += 1;
    }

    pub fn recordMiss(self: *CacheStats) void {
        self.misses += 1;
    }

    pub fn recordInvalidation(self: *CacheStats) void {
        self.invalidations += 1;
    }

    pub fn getHitRate(self: *const CacheStats) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }
};

comptime {
    // Verify cache entry size
    const size = @sizeOf(LayoutCacheEntry);
    if (size != 48) {
        @compileError(std.fmt.comptimePrint(
            "LayoutCacheEntry size changed! Expected 48 bytes, got {} bytes",
            .{size}
        ));
    }
}

test "LayoutCacheEntry: basic operations" {
    var entry = LayoutCacheEntry{};

    // Initially invalid
    try std.testing.expect(!entry.isValid(100, 200, 1));

    // Update cache
    entry.update(100, 200, 1, 50, 75);

    // Now valid
    try std.testing.expect(entry.isValid(100, 200, 1));
    try std.testing.expect(entry.valid);

    const size = entry.getSize();
    try std.testing.expectEqual(@as(f32, 50), size.width);
    try std.testing.expectEqual(@as(f32, 75), size.height);

    // Different constraints = invalid
    try std.testing.expect(!entry.isValid(150, 200, 1));
    try std.testing.expect(!entry.isValid(100, 250, 1));

    // Different style version = invalid
    try std.testing.expect(!entry.isValid(100, 200, 2));
}

test "LayoutCacheEntry: invalidation" {
    var entry = LayoutCacheEntry{};
    entry.update(100, 200, 1, 50, 75);

    try std.testing.expect(entry.valid);

    entry.invalidate();
    try std.testing.expect(!entry.valid);
    try std.testing.expect(!entry.isValid(100, 200, 1));
}

test "CacheStats: hit rate calculation" {
    var stats = CacheStats{};

    // No accesses yet
    try std.testing.expectEqual(@as(f32, 0), stats.getHitRate());

    // Record some hits and misses
    stats.recordHit();
    stats.recordHit();
    stats.recordHit();
    stats.recordMiss();

    // Hit rate = 3/4 = 0.75
    const rate = stats.getHitRate();
    try std.testing.expect(rate > 0.74 and rate < 0.76);
}
