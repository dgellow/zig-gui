//! Two-Pass Dirty Bit Tracking
//!
//! Simple and efficient dirty tracking for incremental layout updates.
//!
//! Algorithm:
//! - Pass 1 (bottom-up): When style changes, mark node dirty and propagate
//!   up to ancestors, stopping at fixed-size containers or already-dirty nodes.
//! - Pass 2 (top-down): Traverse from root, recursing only into dirty subtrees
//!   or children whose size changed.
//!
//! We evaluated Spineless Traversal (https://arxiv.org/html/2411.10659v8) which
//! achieves 1.8x speedup in browser engines. However, it requires an order
//! maintenance data structure, adding memory and complexity. For UI toolkit
//! workloads (50-500 nodes vs browser's 10,000+), two-pass is simpler and sufficient.

const std = @import("std");

/// Maximum number of elements that can be tracked
/// Configured via build option: -Dmax_layout_elements=N
const build_options = @import("build_options");
pub const MAX_CAPACITY: u32 = build_options.max_layout_elements;

/// Two-Pass Dirty Bits
///
/// Simple bitset for tracking which nodes need layout recomputation.
/// Memory: MAX_CAPACITY / 8 bytes (e.g., 512 bytes for 4096 elements)
pub const DirtyBits = struct {
    /// Bitset of dirty nodes
    bits: std.StaticBitSet(MAX_CAPACITY),

    /// Statistics for performance analysis
    total_marks: u64 = 0,
    total_clears: u64 = 0,

    pub fn init() DirtyBits {
        return .{
            .bits = std.StaticBitSet(MAX_CAPACITY).initEmpty(),
        };
    }

    /// Mark a node as dirty (O(1) operation)
    pub inline fn markDirty(self: *DirtyBits, index: u32) void {
        std.debug.assert(index < MAX_CAPACITY);
        if (!self.bits.isSet(index)) {
            self.bits.set(index);
            self.total_marks += 1;
        }
    }

    /// Check if a node is dirty
    pub inline fn isDirty(self: *const DirtyBits, index: u32) bool {
        std.debug.assert(index < MAX_CAPACITY);
        return self.bits.isSet(index);
    }

    /// Clear dirty bit for a single node (called during top-down pass)
    pub inline fn clearDirty(self: *DirtyBits, index: u32) void {
        std.debug.assert(index < MAX_CAPACITY);
        self.bits.unset(index);
    }

    /// Clear all dirty bits (called after full layout)
    pub fn clearAll(self: *DirtyBits) void {
        self.bits = std.StaticBitSet(MAX_CAPACITY).initEmpty();
        self.total_clears += 1;
    }

    /// Check if any node is dirty
    pub inline fn anyDirty(self: *const DirtyBits) bool {
        return self.bits.count() > 0;
    }

    /// Get count of dirty nodes (for diagnostics)
    pub inline fn dirtyCount(self: *const DirtyBits) usize {
        return self.bits.count();
    }

    /// Reset statistics
    pub fn resetStats(self: *DirtyBits) void {
        self.total_marks = 0;
        self.total_clears = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DirtyBits: basic operations" {
    var dirty = DirtyBits.init();

    // Initially empty
    try std.testing.expect(!dirty.isDirty(0));
    try std.testing.expect(!dirty.isDirty(5));
    try std.testing.expect(!dirty.anyDirty());
    try std.testing.expectEqual(@as(usize, 0), dirty.dirtyCount());

    // Mark some nodes
    dirty.markDirty(5);
    dirty.markDirty(12);
    dirty.markDirty(23);

    try std.testing.expect(dirty.isDirty(5));
    try std.testing.expect(dirty.isDirty(12));
    try std.testing.expect(dirty.isDirty(23));
    try std.testing.expect(!dirty.isDirty(0));
    try std.testing.expect(dirty.anyDirty());
    try std.testing.expectEqual(@as(usize, 3), dirty.dirtyCount());
}

test "DirtyBits: clearDirty" {
    var dirty = DirtyBits.init();

    dirty.markDirty(10);
    dirty.markDirty(20);
    try std.testing.expectEqual(@as(usize, 2), dirty.dirtyCount());

    dirty.clearDirty(10);
    try std.testing.expect(!dirty.isDirty(10));
    try std.testing.expect(dirty.isDirty(20));
    try std.testing.expectEqual(@as(usize, 1), dirty.dirtyCount());
}

test "DirtyBits: clearAll" {
    var dirty = DirtyBits.init();

    dirty.markDirty(5);
    dirty.markDirty(10);
    dirty.markDirty(15);

    dirty.clearAll();

    try std.testing.expect(!dirty.isDirty(5));
    try std.testing.expect(!dirty.isDirty(10));
    try std.testing.expect(!dirty.isDirty(15));
    try std.testing.expect(!dirty.anyDirty());
}

test "DirtyBits: duplicate marking is idempotent" {
    var dirty = DirtyBits.init();

    dirty.markDirty(10);
    dirty.markDirty(10);
    dirty.markDirty(10);

    // Should only count as one dirty node
    try std.testing.expectEqual(@as(usize, 1), dirty.dirtyCount());

    // But stats track all mark calls (first one increments, rest don't)
    try std.testing.expectEqual(@as(u64, 1), dirty.total_marks);
}

test "DirtyBits: statistics" {
    var dirty = DirtyBits.init();

    dirty.markDirty(1);
    dirty.markDirty(2);
    dirty.clearAll();
    dirty.markDirty(3);
    dirty.clearAll();

    try std.testing.expectEqual(@as(u64, 3), dirty.total_marks);
    try std.testing.expectEqual(@as(u64, 2), dirty.total_clears);
}
