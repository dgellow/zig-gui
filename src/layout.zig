//! High-Performance Layout Engine powered by zlay v2.0
//!
//! This is a thin wrapper around zlay v2.0's layout engine.
//!
//! Performance (VALIDATED - all 31 tests passing):
//! - Email Client (81 elements): 0.073μs per element (5.7x faster than Taffy)
//! - Game HUD (47 elements): 0.107μs per element (3.9x faster than Taffy)
//! - Stress Test (1011 elements): 0.032μs per element (13.1x faster than Taffy)
//!
//! Features:
//! - Spineless traversal (9.33x speedup - only process dirty elements)
//! - SIMD constraint clamping (1.95x speedup)
//! - Layout caching (2-5x speedup on incremental updates)
//! - Memory efficient (176 bytes per element)
//!
//! See lib/zlay/HONEST_VALIDATION_RESULTS.md for complete validation.

const std = @import("std");
const zlay = @import("zlay");
const Rect = @import("core/geometry.zig").Rect;

// Re-export zlay v2.0 types with friendly names
pub const LayoutEngine = zlay.layout_engine_v2.LayoutEngine;
pub const FlexStyle = zlay.flexbox.FlexStyle;
pub const FlexDirection = zlay.flexbox.FlexDirection;
pub const JustifyContent = zlay.flexbox.JustifyContent;
pub const AlignItems = zlay.flexbox.AlignItems;
pub const LayoutResult = zlay.flexbox.LayoutResult;
pub const CacheStats = zlay.cache.CacheStats;
pub const DirtyQueue = zlay.dirty_tracking.DirtyQueue;

// Convenience wrapper for zig-gui specific usage patterns
pub const LayoutWrapper = struct {
    engine: LayoutEngine,
    id_map: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) !LayoutWrapper {
        return .{
            .engine = try LayoutEngine.init(allocator),
            .id_map = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutWrapper) void {
        self.engine.deinit();
        self.id_map.deinit();
    }

    pub fn beginFrame(self: *LayoutWrapper) void {
        self.engine.beginFrame();
        self.id_map.clearRetainingCapacity();
    }

    /// Add element with ID tracking
    pub fn addElement(
        self: *LayoutWrapper,
        id: []const u8,
        parent_id: ?[]const u8,
        style: FlexStyle,
    ) !u32 {
        const parent_index = if (parent_id) |pid|
            self.id_map.get(pid)
        else
            null;

        const index = try self.engine.addElement(parent_index, style);
        try self.id_map.put(id, index);
        return index;
    }

    pub fn computeLayout(self: *LayoutWrapper, width: f32, height: f32) !void {
        try self.engine.computeLayout(width, height);
    }

    pub fn getLayout(self: *const LayoutWrapper, id: []const u8) ?Rect {
        const index = self.id_map.get(id) orelse return null;
        const rect = self.engine.getRect(index);
        return Rect{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
    }

    pub fn markDirty(self: *LayoutWrapper, id: []const u8) void {
        const index = self.id_map.get(id) orelse return;
        self.engine.markDirty(index);
    }

    pub fn updateStyle(self: *LayoutWrapper, id: []const u8, style: FlexStyle) void {
        const index = self.id_map.get(id) orelse return;
        self.engine.setStyle(index, style);
    }

    pub fn getCacheStats(self: *const LayoutWrapper) CacheStats {
        return self.engine.getCacheStats();
    }

    pub fn getDirtyCount(self: *const LayoutWrapper) usize {
        return self.engine.getDirtyCount();
    }

    pub fn getElementCount(self: *const LayoutWrapper) u32 {
        return self.engine.getElementCount();
    }
};

test "LayoutEngine: basic usage" {
    const testing = std.testing;

    var wrapper = try LayoutWrapper.init(testing.allocator);
    defer wrapper.deinit();

    wrapper.beginFrame();

    // Create root
    _ = try wrapper.addElement("root", null, .{
        .direction = .column,
        .width = 800,
        .height = 600,
    });

    // Add children
    _ = try wrapper.addElement("child1", "root", .{ .height = 50 });
    _ = try wrapper.addElement("child2", "root", .{ .height = 30 });

    // Compute layout (FAST!)
    try wrapper.computeLayout(800, 600);

    // Verify
    const child1 = wrapper.getLayout("child1");
    const child2 = wrapper.getLayout("child2");

    try testing.expect(child1 != null);
    try testing.expect(child2 != null);

    try testing.expectEqual(@as(f32, 0), child1.?.y);
    try testing.expectEqual(@as(f32, 50), child1.?.height);

    try testing.expectEqual(@as(f32, 50), child2.?.y);
    try testing.expectEqual(@as(f32, 30), child2.?.height);
}
