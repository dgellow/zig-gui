//! Order Maintenance Data Structure
//!
//! Maintains a total order over elements with O(1) operations:
//! - insert(x, after_y): Insert x immediately after y
//! - remove(x): Remove x from the order
//! - compare(x, y): Return ordering of x vs y
//!
//! This is the key data structure enabling Spineless Traversal.
//! Without it, we'd need O(n) tree traversal to determine processing order.
//!
//! Implementation: Two-level structure with lazy relabeling
//! - Top level: Linked list of buckets with sparse labels
//! - Bottom level: Elements within buckets with dense labels
//!
//! Reference: Dietz & Sleator, "Two Algorithms for Maintaining Order in a List" (1987)
//! Used in: Spineless Traversal for Layout Invalidation (PLDI 2025)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Label type - 64 bits for ~2^64 elements without overflow
const Label = u64;

/// Maximum elements per bucket before splitting
const BUCKET_CAPACITY = 64;

/// Label space per bucket (determines relabeling frequency)
const LABEL_SPACE: Label = std.math.maxInt(Label) / 1024;

/// An element in the order
pub const OrderedElement = struct {
    /// Global label for O(1) comparison
    /// Comparison: if label_a < label_b then a comes before b
    label: Label = 0,

    /// Bucket this element belongs to
    bucket_idx: u32 = 0,

    /// Index within bucket
    bucket_pos: u16 = 0,

    /// Is this element currently in the order?
    active: bool = false,

    /// User data (layout node index)
    node_idx: u32 = 0,
};

/// A bucket in the top-level list
const Bucket = struct {
    /// Base label for this bucket
    base_label: Label = 0,

    /// Elements in this bucket (indices into element array)
    elements: std.BoundedArray(u32, BUCKET_CAPACITY) = .{},

    /// Next bucket in list (0xFFFFFFFF = none)
    next: u32 = 0xFFFFFFFF,

    /// Previous bucket in list
    prev: u32 = 0xFFFFFFFF,
};

/// Order Maintenance structure
pub fn OrderMaintenance(comptime max_elements: u32) type {
    return struct {
        const Self = @This();

        /// All elements (indexed by element ID)
        elements: [max_elements]OrderedElement = [_]OrderedElement{.{}} ** max_elements,

        /// Buckets for two-level structure
        buckets: std.BoundedArray(Bucket, max_elements / BUCKET_CAPACITY + 1) = .{},

        /// Free bucket indices for reuse
        free_buckets: std.BoundedArray(u32, max_elements / BUCKET_CAPACITY + 1) = .{},

        /// Head of bucket list
        head_bucket: u32 = 0xFFFFFFFF,

        /// Tail of bucket list
        tail_bucket: u32 = 0xFFFFFFFF,

        /// Number of active elements
        count: u32 = 0,

        /// Statistics for performance analysis
        relabel_count: u64 = 0,
        comparison_count: u64 = 0,

        /// Initialize the order maintenance structure
        pub fn init() Self {
            return Self{};
        }

        /// Insert element at the very beginning of the order
        pub fn insertFirst(self: *Self, element_idx: u32, node_idx: u32) void {
            if (self.head_bucket == 0xFFFFFFFF) {
                // First element ever - create initial bucket
                const bucket_idx = self.allocateBucket();
                self.buckets.buffer[bucket_idx].base_label = LABEL_SPACE;
                self.head_bucket = bucket_idx;
                self.tail_bucket = bucket_idx;
            }

            self.insertIntoBucket(self.head_bucket, 0, element_idx, node_idx);
        }

        /// Insert element immediately after another element
        /// This is the core operation for maintaining tree order
        pub fn insertAfter(self: *Self, element_idx: u32, after_idx: u32, node_idx: u32) void {
            const after = &self.elements[after_idx];
            std.debug.assert(after.active);

            const bucket_idx = after.bucket_idx;
            const insert_pos = after.bucket_pos + 1;

            self.insertIntoBucket(bucket_idx, insert_pos, element_idx, node_idx);
        }

        /// Insert into a specific bucket at a specific position
        fn insertIntoBucket(self: *Self, bucket_idx: u32, pos: u16, element_idx: u32, node_idx: u32) void {
            var bucket = &self.buckets.buffer[bucket_idx];

            // Check if bucket needs splitting
            if (bucket.elements.len >= BUCKET_CAPACITY) {
                const new_bucket_idx = self.splitBucket(bucket_idx);

                // Determine which bucket to insert into
                if (pos >= BUCKET_CAPACITY / 2) {
                    self.insertIntoBucket(new_bucket_idx, pos - BUCKET_CAPACITY / 2, element_idx, node_idx);
                    return;
                }
                // Otherwise continue with original bucket
                bucket = &self.buckets.buffer[bucket_idx];
            }

            // Insert element into bucket
            const actual_pos = @min(pos, @as(u16, @intCast(bucket.elements.len)));

            // Shift existing elements
            if (actual_pos < bucket.elements.len) {
                // Make room by shifting
                bucket.elements.append(0) catch unreachable;
                var i: usize = bucket.elements.len - 1;
                while (i > actual_pos) : (i -= 1) {
                    bucket.elements.buffer[i] = bucket.elements.buffer[i - 1];
                    // Update shifted element's position AND label
                    const shifted_elem_idx = bucket.elements.buffer[i];
                    self.elements[shifted_elem_idx].bucket_pos = @intCast(i);
                    self.relabelElement(shifted_elem_idx);
                }
                bucket.elements.buffer[actual_pos] = element_idx;
            } else {
                bucket.elements.append(element_idx) catch unreachable;
            }

            // Configure the element
            const elem = &self.elements[element_idx];
            elem.bucket_idx = bucket_idx;
            elem.bucket_pos = actual_pos;
            elem.node_idx = node_idx;
            elem.active = true;

            // Compute label
            self.relabelElement(element_idx);

            self.count += 1;
        }

        /// Split a bucket that's full
        fn splitBucket(self: *Self, bucket_idx: u32) u32 {
            self.relabel_count += 1;

            const new_bucket_idx = self.allocateBucket();
            var old_bucket = &self.buckets.buffer[bucket_idx];
            var new_bucket = &self.buckets.buffer[new_bucket_idx];

            // Move second half to new bucket
            const split_point = BUCKET_CAPACITY / 2;
            for (old_bucket.elements.buffer[split_point..old_bucket.elements.len], 0..) |elem_idx, i| {
                new_bucket.elements.append(elem_idx) catch unreachable;
                self.elements[elem_idx].bucket_idx = new_bucket_idx;
                self.elements[elem_idx].bucket_pos = @intCast(i);
            }
            old_bucket.elements.len = split_point;

            // Link new bucket after old bucket
            new_bucket.prev = bucket_idx;
            new_bucket.next = old_bucket.next;
            if (old_bucket.next != 0xFFFFFFFF) {
                self.buckets.buffer[old_bucket.next].prev = new_bucket_idx;
            } else {
                self.tail_bucket = new_bucket_idx;
            }
            old_bucket.next = new_bucket_idx;

            // Assign label between old bucket and next
            const next_label = if (new_bucket.next != 0xFFFFFFFF)
                self.buckets.buffer[new_bucket.next].base_label
            else
                std.math.maxInt(Label);

            new_bucket.base_label = old_bucket.base_label + (next_label - old_bucket.base_label) / 2;

            // Relabel elements in new bucket
            for (new_bucket.elements.constSlice()) |elem_idx| {
                self.relabelElement(elem_idx);
            }

            return new_bucket_idx;
        }

        /// Compute label for an element based on bucket and position
        fn relabelElement(self: *Self, element_idx: u32) void {
            const elem = &self.elements[element_idx];
            const bucket = &self.buckets.buffer[elem.bucket_idx];

            // Label = bucket base + position within bucket * spacing
            const spacing = LABEL_SPACE / (BUCKET_CAPACITY + 1);
            elem.label = bucket.base_label + @as(Label, elem.bucket_pos + 1) * spacing;
        }

        /// Remove element from the order
        pub fn remove(self: *Self, element_idx: u32) void {
            const elem = &self.elements[element_idx];
            if (!elem.active) return;

            var bucket = &self.buckets.buffer[elem.bucket_idx];

            // Remove from bucket
            const pos = elem.bucket_pos;
            for (pos..bucket.elements.len - 1) |i| {
                bucket.elements.buffer[i] = bucket.elements.buffer[i + 1];
                self.elements[bucket.elements.buffer[i]].bucket_pos = @intCast(i);
            }
            bucket.elements.len -= 1;

            // If bucket is empty, remove it
            if (bucket.elements.len == 0) {
                self.freeBucket(elem.bucket_idx);
            }

            elem.active = false;
            self.count -= 1;
        }

        /// Compare two elements: returns true if a comes before b
        /// This is O(1) - just compare labels!
        pub fn comesBefore(self: *Self, a_idx: u32, b_idx: u32) bool {
            self.comparison_count += 1;
            return self.elements[a_idx].label < self.elements[b_idx].label;
        }

        /// Get the label for an element (for external priority queues)
        pub fn getLabel(self: *const Self, element_idx: u32) Label {
            return self.elements[element_idx].label;
        }

        /// Check if element is in the order
        pub fn isActive(self: *const Self, element_idx: u32) bool {
            return self.elements[element_idx].active;
        }

        /// Allocate a new bucket
        fn allocateBucket(self: *Self) u32 {
            if (self.free_buckets.len > 0) {
                return self.free_buckets.pop();
            }
            const idx: u32 = @intCast(self.buckets.len);
            self.buckets.append(.{}) catch unreachable;
            return idx;
        }

        /// Free a bucket for reuse
        fn freeBucket(self: *Self, bucket_idx: u32) void {
            const bucket = &self.buckets.buffer[bucket_idx];

            // Unlink from list
            if (bucket.prev != 0xFFFFFFFF) {
                self.buckets.buffer[bucket.prev].next = bucket.next;
            } else {
                self.head_bucket = bucket.next;
            }

            if (bucket.next != 0xFFFFFFFF) {
                self.buckets.buffer[bucket.next].prev = bucket.prev;
            } else {
                self.tail_bucket = bucket.prev;
            }

            // Reset and add to free list
            bucket.* = .{};
            self.free_buckets.append(bucket_idx) catch {};
        }

        /// Get statistics
        pub fn getStats(self: *const Self) struct { count: u32, relabels: u64, comparisons: u64 } {
            return .{
                .count = self.count,
                .relabels = self.relabel_count,
                .comparisons = self.comparison_count,
            };
        }

        /// Reset statistics
        pub fn resetStats(self: *Self) void {
            self.relabel_count = 0;
            self.comparison_count = 0;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "OrderMaintenance: basic insert and compare" {
    var om = OrderMaintenance(1024).init();

    // Insert elements in order: 0, 1, 2
    om.insertFirst(0, 100);
    om.insertAfter(1, 0, 101);
    om.insertAfter(2, 1, 102);

    // Verify order
    try std.testing.expect(om.comesBefore(0, 1));
    try std.testing.expect(om.comesBefore(1, 2));
    try std.testing.expect(om.comesBefore(0, 2));

    // Reverse should be false
    try std.testing.expect(!om.comesBefore(1, 0));
    try std.testing.expect(!om.comesBefore(2, 1));
    try std.testing.expect(!om.comesBefore(2, 0));
}

test "OrderMaintenance: insert in middle" {
    var om = OrderMaintenance(1024).init();

    // Insert 0, 2, then 1 between them
    om.insertFirst(0, 100);
    om.insertAfter(2, 0, 102);
    om.insertAfter(1, 0, 101); // Insert after 0, before 2

    // Verify order: 0 < 1 < 2
    try std.testing.expect(om.comesBefore(0, 1));
    try std.testing.expect(om.comesBefore(1, 2));
    try std.testing.expect(om.comesBefore(0, 2));
}

test "OrderMaintenance: remove element" {
    var om = OrderMaintenance(1024).init();

    om.insertFirst(0, 100);
    om.insertAfter(1, 0, 101);
    om.insertAfter(2, 1, 102);

    try std.testing.expectEqual(@as(u32, 3), om.count);

    // Remove middle element
    om.remove(1);

    try std.testing.expectEqual(@as(u32, 2), om.count);
    try std.testing.expect(!om.isActive(1));
    try std.testing.expect(om.isActive(0));
    try std.testing.expect(om.isActive(2));

    // Order of remaining elements preserved
    try std.testing.expect(om.comesBefore(0, 2));
}

test "OrderMaintenance: bucket splitting" {
    var om = OrderMaintenance(1024).init();

    // Insert enough elements to trigger bucket split
    om.insertFirst(0, 0);
    var prev: u32 = 0;

    for (1..100) |i| {
        const idx: u32 = @intCast(i);
        om.insertAfter(idx, prev, idx);
        prev = idx;
    }

    // Verify all elements in correct order
    for (0..99) |i| {
        const a: u32 = @intCast(i);
        const b: u32 = @intCast(i + 1);
        try std.testing.expect(om.comesBefore(a, b));
    }

    // Should have triggered at least one relabel (bucket split)
    const stats = om.getStats();
    try std.testing.expect(stats.relabels > 0);
}

test "OrderMaintenance: tree-order simulation" {
    var om = OrderMaintenance(1024).init();

    // Simulate tree:
    //       0
    //      / \
    //     1   4
    //    / \
    //   2   3

    // Pre-order traversal: 0, 1, 2, 3, 4
    om.insertFirst(0, 0); // root
    om.insertAfter(1, 0, 1); // first child of 0
    om.insertAfter(2, 1, 2); // first child of 1
    om.insertAfter(3, 2, 3); // second child of 1 (after 2)
    om.insertAfter(4, 3, 4); // second child of 0 (after entire subtree of 1)

    // Verify pre-order: 0 < 1 < 2 < 3 < 4
    try std.testing.expect(om.comesBefore(0, 1));
    try std.testing.expect(om.comesBefore(1, 2));
    try std.testing.expect(om.comesBefore(2, 3));
    try std.testing.expect(om.comesBefore(3, 4));
}
