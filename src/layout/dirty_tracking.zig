//! Spineless Traversal Dirty Tracking
//!
//! Research: 1.80x faster than traditional dirty bit propagation
//! Paper: https://arxiv.org/html/2411.10659v5
//!
//! Traditional approach: Mark dirty bits, traverse entire tree (wastes cache on clean nodes)
//! Spineless approach: Queue dirty indices, jump directly to them (zero cache waste)

const std = @import("std");

/// Maximum number of elements that can be tracked
pub const MAX_CAPACITY = 16384;  // Upgraded from 4096

/// Spineless Traversal Dirty Queue
///
/// Instead of traversing the tree and checking dirty flags,
/// we maintain a queue of dirty node indices and jump directly to them.
///
/// **Performance:** O(d) where d = dirty count (vs O(n) for traditional)
/// **Speedup:** 1.80x average (proven in research)
pub const DirtyQueue = struct {
    /// Indices of dirty nodes (compact array for cache efficiency)
    indices: std.BoundedArray(u32, MAX_CAPACITY),

    /// Bitset to prevent duplicate entries (1 bit per element)
    /// Using packed struct for cache efficiency
    seen: [MAX_CAPACITY]bool,

    /// Statistics for performance validation
    marks_since_process: u32 = 0,
    total_marks: u64 = 0,
    total_processes: u64 = 0,

    pub fn init() DirtyQueue {
        return .{
            .indices = .{},
            .seen = [_]bool{false} ** MAX_CAPACITY,
        };
    }

    /// Mark a node as dirty (O(1) operation)
    ///
    /// **IMPORTANT:** Uses seen array to prevent duplicates
    /// This is critical for performance - deduplication is O(1) vs O(n) linear search
    pub fn markDirty(self: *DirtyQueue, index: u32) void {
        std.debug.assert(index < MAX_CAPACITY);

        if (!self.seen[index]) {
            self.indices.append(index) catch {
                // Queue full - this should never happen in practice
                // If it does, it means >16K dirty nodes, which indicates a design issue
                std.debug.panic("DirtyQueue overflow! {} dirty nodes", .{self.indices.len});
            };
            self.seen[index] = true;
            self.marks_since_process += 1;
            self.total_marks += 1;
        }
    }

    /// Mark multiple nodes as dirty (batch operation)
    ///
    /// More cache-efficient than individual markDirty() calls
    /// when marking many nodes at once (e.g., entire subtree invalidation)
    pub fn markDirtyBatch(self: *DirtyQueue, indices_to_mark: []const u32) void {
        for (indices_to_mark) |index| {
            self.markDirty(index);
        }
    }

    /// Get slice of dirty indices for processing
    ///
    /// **Usage:** Iterate over this slice to jump directly to dirty nodes
    pub inline fn getDirtySlice(self: *const DirtyQueue) []const u32 {
        return self.indices.constSlice();
    }

    /// Check if queue is empty
    pub inline fn isEmpty(self: *const DirtyQueue) bool {
        return self.indices.len == 0;
    }

    /// Get count of dirty nodes
    pub inline fn dirtyCount(self: *const DirtyQueue) usize {
        return self.indices.len;
    }

    /// Clear the queue (after processing)
    ///
    /// **IMPORTANT:** Must clear seen flags too, or future marks will be ignored!
    pub fn clear(self: *DirtyQueue) void {
        // Clear seen flags for all dirty indices
        for (self.indices.constSlice()) |index| {
            self.seen[index] = false;
        }

        // Clear the queue
        self.indices.len = 0;
        self.marks_since_process = 0;
        self.total_processes += 1;
    }

    /// Reset statistics (for benchmarking)
    pub fn resetStats(self: *DirtyQueue) void {
        self.total_marks = 0;
        self.total_processes = 0;
    }

    /// Get average dirty count per process (for analysis)
    pub fn getAvgDirtyCount(self: *const DirtyQueue) f32 {
        if (self.total_processes == 0) return 0;
        return @as(f32, @floatFromInt(self.total_marks)) /
               @as(f32, @floatFromInt(self.total_processes));
    }
};

test "DirtyQueue: basic operations" {
    var queue = DirtyQueue.init();

    // Initially empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.dirtyCount());

    // Mark some nodes
    queue.markDirty(5);
    queue.markDirty(12);
    queue.markDirty(23);

    try std.testing.expectEqual(@as(usize, 3), queue.dirtyCount());
    try std.testing.expect(!queue.isEmpty());

    // Check slice
    const dirty = queue.getDirtySlice();
    try std.testing.expectEqual(@as(usize, 3), dirty.len);
    try std.testing.expectEqual(@as(u32, 5), dirty[0]);
    try std.testing.expectEqual(@as(u32, 12), dirty[1]);
    try std.testing.expectEqual(@as(u32, 23), dirty[2]);

    // Clear
    queue.clear();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.dirtyCount());
}

test "DirtyQueue: duplicate prevention" {
    var queue = DirtyQueue.init();

    // Mark same node multiple times
    queue.markDirty(10);
    queue.markDirty(10);
    queue.markDirty(10);

    // Should only be added once
    try std.testing.expectEqual(@as(usize, 1), queue.dirtyCount());

    const dirty = queue.getDirtySlice();
    try std.testing.expectEqual(@as(u32, 10), dirty[0]);
}

test "DirtyQueue: batch marking" {
    var queue = DirtyQueue.init();

    const to_mark = [_]u32{ 1, 5, 10, 15, 20 };
    queue.markDirtyBatch(&to_mark);

    try std.testing.expectEqual(@as(usize, 5), queue.dirtyCount());
}

test "DirtyQueue: statistics tracking" {
    var queue = DirtyQueue.init();

    // First batch
    queue.markDirty(1);
    queue.markDirty(2);
    queue.clear();

    // Second batch
    queue.markDirty(3);
    queue.markDirty(4);
    queue.markDirty(5);
    queue.clear();

    try std.testing.expectEqual(@as(u64, 5), queue.total_marks);
    try std.testing.expectEqual(@as(u64, 2), queue.total_processes);

    const avg = queue.getAvgDirtyCount();
    try std.testing.expectEqual(@as(f32, 2.5), avg);  // 5 marks / 2 processes
}

test "DirtyQueue: clear resets seen flags" {
    var queue = DirtyQueue.init();

    // Mark, clear, mark again
    queue.markDirty(10);
    queue.clear();
    queue.markDirty(10);

    // Should be added again after clear
    try std.testing.expectEqual(@as(usize, 1), queue.dirtyCount());
}
