//! Layout Engine - Two-Pass Dirty Bit Implementation
//!
//! High-performance flexbox layout with incremental updates.
//!
//! ## Algorithm: Two-Pass Dirty Tracking
//!
//! Pass 1 (bottom-up marking):
//!   When a node's style changes, mark it dirty and propagate up to ancestors,
//!   stopping at fixed-size containers (they won't affect parent layout) or
//!   already-dirty nodes (ancestors already marked).
//!
//! Pass 2 (top-down computation):
//!   Starting from root, compute layout and recurse only into:
//!   - Dirty children (their style changed)
//!   - Children whose size changed (parent resize affects them)
//!
//! ## Optimizations
//!
//! - SIMD constraint clamping (vectorized min/max)
//! - Layout caching (skip unchanged elements)
//! - SoA data layout (cache-friendly traversal)
//! - Free list recycling (no allocation churn)
//!
//! ## Embedded Configuration
//!
//! For embedded systems with limited RAM, configure at build time:
//!   zig build -Dmax_layout_elements=64
//!
//! Memory usage scales with max_layout_elements:
//!   - 64 elements:  ~9KB (fits in 32KB embedded)
//!   - 256 elements: ~36KB
//!   - 4096 elements (default): ~580KB

const std = @import("std");
const build_options = @import("build_options");
const flexbox = @import("flexbox.zig");
const cache = @import("cache.zig");
const dirty_tracking = @import("dirty_tracking.zig");
const simd = @import("simd.zig");
const geometry = @import("../core/geometry.zig");

const Rect = geometry.Rect;
const Size = geometry.Size;
const FlexStyle = flexbox.FlexStyle;
const LayoutResult = flexbox.LayoutResult;
const LayoutCacheEntry = cache.LayoutCacheEntry;
const CacheStats = cache.CacheStats;
const DirtyBits = dirty_tracking.DirtyBits;

/// Maximum number of elements in the layout tree
/// Configurable via build option: -Dmax_layout_elements=N
pub const MAX_ELEMENTS: u32 = build_options.max_layout_elements;

/// Null index sentinel
const NULL_INDEX: u32 = 0xFFFFFFFF;

/// Stack buffer size for small child counts (avoids heap allocation)
const STACK_CHILDREN_MAX: usize = 32;

/// Epsilon for float comparison in size change detection
const SIZE_EPSILON: f32 = 0.001;

/// Check if a style represents a fixed-size element (both dimensions explicit)
fn isFixedSize(style: FlexStyle) bool {
    return style.width >= 0 and style.height >= 0;
}

/// Check if two sizes are approximately equal (within epsilon)
fn sizesApproxEqual(a: Size, b: Size) bool {
    return @abs(a.width - b.width) < SIZE_EPSILON and
        @abs(a.height - b.height) < SIZE_EPSILON;
}

/// Layout engine with two-pass dirty tracking
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    // =========================================================================
    // Tree structure (hot data - frequently accessed during traversal)
    // =========================================================================
    parent: [MAX_ELEMENTS]u32,
    first_child: [MAX_ELEMENTS]u32,
    next_sibling: [MAX_ELEMENTS]u32,
    child_count: [MAX_ELEMENTS]u16,

    // =========================================================================
    // Layout state (hot data)
    // =========================================================================
    flex_styles: [MAX_ELEMENTS]FlexStyle,
    computed_rects: [MAX_ELEMENTS]Rect,
    style_versions: [MAX_ELEMENTS]u64,

    // =========================================================================
    // Cache (warm data - accessed on cache hit)
    // =========================================================================
    layout_cache: [MAX_ELEMENTS]LayoutCacheEntry,

    // =========================================================================
    // Dirty tracking (two-pass algorithm)
    // =========================================================================
    dirty_bits: DirtyBits,

    // =========================================================================
    // Metadata
    // =========================================================================
    element_count: u32,
    global_style_version: u64,
    cache_stats: CacheStats,
    free_list: std.BoundedArray(u32, MAX_ELEMENTS),

    pub fn init(allocator: std.mem.Allocator) !LayoutEngine {
        const arena = std.heap.ArenaAllocator.init(allocator);

        return LayoutEngine{
            .allocator = allocator,
            .arena = arena,
            .parent = [_]u32{NULL_INDEX} ** MAX_ELEMENTS,
            .first_child = [_]u32{NULL_INDEX} ** MAX_ELEMENTS,
            .next_sibling = [_]u32{NULL_INDEX} ** MAX_ELEMENTS,
            .child_count = [_]u16{0} ** MAX_ELEMENTS,
            .flex_styles = [_]FlexStyle{.{}} ** MAX_ELEMENTS,
            .computed_rects = [_]Rect{Rect.zero()} ** MAX_ELEMENTS,
            .style_versions = [_]u64{0} ** MAX_ELEMENTS,
            .layout_cache = [_]LayoutCacheEntry{.{}} ** MAX_ELEMENTS,
            .dirty_bits = DirtyBits.init(),
            .element_count = 0,
            .global_style_version = 1,
            .cache_stats = .{},
            .free_list = .{},
        };
    }

    pub fn deinit(self: *LayoutEngine) void {
        self.arena.deinit();
    }

    /// Reset for new frame
    pub fn beginFrame(self: *LayoutEngine) void {
        _ = self.arena.reset(.retain_capacity);
        // Note: We don't clear dirty_bits here - they persist across frames
        // and are cleared during computeLayout as nodes are processed
    }

    // =========================================================================
    // Element Management
    // =========================================================================

    /// Add element to the tree
    pub fn addElement(self: *LayoutEngine, parent_index: ?u32, style: FlexStyle) !u32 {
        const index = try self.allocateIndex();

        // Initialize tree structure
        self.first_child[index] = NULL_INDEX;
        self.next_sibling[index] = NULL_INDEX;
        self.child_count[index] = 0;

        // Set style
        self.flex_styles[index] = style;
        self.style_versions[index] = self.global_style_version;

        // Link to parent
        if (parent_index) |parent| {
            self.parent[index] = parent;
            self.linkChild(parent, index);
            self.markDirty(parent);
        } else {
            self.parent[index] = NULL_INDEX;
        }

        // New element is dirty
        self.markDirty(index);

        return index;
    }

    /// Remove element from tree (recursively removes children)
    pub fn removeElement(self: *LayoutEngine, index: u32) void {
        // Recursively remove all children
        var child = self.first_child[index];
        while (child != NULL_INDEX) {
            const next = self.next_sibling[child];
            self.removeElement(child);
            child = next;
        }

        // Unlink from parent
        const parent = self.parent[index];
        if (parent != NULL_INDEX) {
            self.unlinkChild(parent, index);
            self.markDirty(parent);
        }

        // Clear element data
        self.parent[index] = NULL_INDEX;
        self.first_child[index] = NULL_INDEX;
        self.next_sibling[index] = NULL_INDEX;
        self.child_count[index] = 0;
        self.flex_styles[index] = .{};
        self.computed_rects[index] = Rect.zero();
        self.layout_cache[index].invalidate();
        self.dirty_bits.clearDirty(index);

        // Add to free list for reuse
        self.free_list.append(index) catch {};
    }

    /// Move element to new parent
    pub fn reparent(self: *LayoutEngine, index: u32, new_parent: u32) void {
        const old_parent = self.parent[index];
        if (old_parent == new_parent) return;

        // Unlink from old parent
        if (old_parent != NULL_INDEX) {
            self.unlinkChild(old_parent, index);
            self.markDirty(old_parent);
        }

        // Link to new parent
        self.linkChild(new_parent, index);
        self.parent[index] = new_parent;
        self.markDirty(new_parent);
        self.markDirty(index);
    }

    /// Reorder siblings
    pub fn reorderSiblings(self: *LayoutEngine, parent: u32, new_order: []const u32) void {
        if (new_order.len == 0) return;

        self.first_child[parent] = new_order[0];
        for (new_order[0 .. new_order.len - 1], new_order[1..]) |current, next| {
            self.next_sibling[current] = next;
        }
        self.next_sibling[new_order[new_order.len - 1]] = NULL_INDEX;

        self.markDirty(parent);
    }

    // =========================================================================
    // Pass 1: Bottom-Up Dirty Marking
    // =========================================================================

    /// Mark element and ancestors as dirty (stops at fixed-size or already-dirty)
    pub fn markDirty(self: *LayoutEngine, index: u32) void {
        // Mark the node itself
        self.dirty_bits.markDirty(index);

        // Propagate up to ancestors
        var current = self.parent[index];
        while (current != NULL_INDEX) {
            // Already dirty? Ancestors must be too, stop here
            if (self.dirty_bits.isDirty(current)) break;

            self.dirty_bits.markDirty(current);

            // Fixed-size container? Won't affect parent layout, stop here
            if (isFixedSize(self.flex_styles[current])) break;

            current = self.parent[current];
        }
    }

    /// Update element style (marks dirty with proper propagation)
    pub fn setStyle(self: *LayoutEngine, index: u32, style: FlexStyle) void {
        self.flex_styles[index] = style;
        self.style_versions[index] = self.global_style_version;
        self.global_style_version += 1;
        self.markDirty(index);
    }

    // =========================================================================
    // Pass 2: Top-Down Layout Computation
    // =========================================================================

    /// Compute layout for all dirty elements using two-pass algorithm
    pub fn computeLayout(self: *LayoutEngine, available_width: f32, available_height: f32) !void {
        // No elements? Nothing to do
        if (self.element_count == 0) return;

        // Root not dirty? Nothing to do
        if (!self.dirty_bits.isDirty(0)) return;

        // Top-down traversal from root
        try self.computeNode(0, available_width, available_height);
    }

    /// Compute layout for a node and recurse into dirty/size-changed children
    fn computeNode(self: *LayoutEngine, index: u32, available_width: f32, available_height: f32) std.mem.Allocator.Error!void {
        if (self.child_count[index] == 0) {
            // Leaf element - compute intrinsic size
            self.computeLeafLayout(index, available_width, available_height);
        } else {
            // Container - compute flexbox layout
            try self.computeContainerLayout(index, available_width, available_height);
        }

        // Clear dirty bit after processing
        self.dirty_bits.clearDirty(index);
    }

    /// Compute layout for a leaf element
    fn computeLeafLayout(self: *LayoutEngine, index: u32, available_width: f32, available_height: f32) void {
        // Check cache first
        const cached = &self.layout_cache[index];
        const style_version = self.style_versions[index];

        if (cached.isValid(available_width, available_height, style_version)) {
            self.cache_stats.recordHit();
            const cached_size = cached.getSize();
            self.computed_rects[index].width = cached_size.width;
            self.computed_rects[index].height = cached_size.height;
            return;
        }

        self.cache_stats.recordMiss();

        const style = self.flex_styles[index];

        // Determine size: explicit > min > 0
        const width = if (style.width >= 0) style.width else style.min_width;
        const height = if (style.height >= 0) style.height else style.min_height;

        self.computed_rects[index].width = width;
        self.computed_rects[index].height = height;

        cached.update(available_width, available_height, style_version, width, height);
    }

    /// Compute flexbox layout for a container and its children
    fn computeContainerLayout(self: *LayoutEngine, index: u32, available_width: f32, available_height: f32) std.mem.Allocator.Error!void {
        const child_count = self.child_count[index];
        const style = self.flex_styles[index];
        const style_version = self.style_versions[index];

        // Determine container dimensions
        const container_width = if (style.width >= 0) style.width else available_width;
        const container_height = if (style.height >= 0) style.height else available_height;

        // Check cache first
        const cached = &self.layout_cache[index];
        if (cached.isValid(container_width, container_height, style_version)) {
            self.cache_stats.recordHit();
            const cached_size = cached.getSize();
            self.computed_rects[index].width = cached_size.width;
            self.computed_rects[index].height = cached_size.height;

            // Even on cache hit, we must clear dirty bits for all descendants
            self.clearDescendantDirtyBits(index);
            return;
        }

        self.cache_stats.recordMiss();

        // Use stack buffers for small child counts, heap for large
        var children_stack: [STACK_CHILDREN_MAX]u32 = undefined;
        var old_sizes_stack: [STACK_CHILDREN_MAX]Size = undefined;
        var styles_stack: [STACK_CHILDREN_MAX]FlexStyle = undefined;
        var results_stack: [STACK_CHILDREN_MAX]LayoutResult = undefined;

        const use_heap = child_count > STACK_CHILDREN_MAX;

        const children = if (use_heap)
            try self.arena.allocator().alloc(u32, child_count)
        else
            children_stack[0..child_count];
        defer if (use_heap) self.arena.allocator().free(children);

        const old_sizes = if (use_heap)
            try self.arena.allocator().alloc(Size, child_count)
        else
            old_sizes_stack[0..child_count];
        defer if (use_heap) self.arena.allocator().free(old_sizes);

        const children_styles = if (use_heap)
            try self.arena.allocator().alloc(FlexStyle, child_count)
        else
            styles_stack[0..child_count];
        defer if (use_heap) self.arena.allocator().free(children_styles);

        const children_results = if (use_heap)
            try self.arena.allocator().alloc(LayoutResult, child_count)
        else
            results_stack[0..child_count];
        defer if (use_heap) self.arena.allocator().free(children_results);

        // Collect children indices, old sizes, and styles in single pass
        var i: usize = 0;
        var child = self.first_child[index];
        while (child != NULL_INDEX) : (i += 1) {
            children[i] = child;
            old_sizes[i] = .{
                .width = self.computed_rects[child].width,
                .height = self.computed_rects[child].height,
            };
            children_styles[i] = self.flex_styles[child];
            child = self.next_sibling[child];
        }

        // Compute flexbox layout
        try flexbox.computeFlexLayout(
            self.arena.allocator(),
            container_width,
            container_height,
            style,
            children_styles,
            children_results,
        );

        // Apply results to children
        for (children, 0..) |child_index, j| {
            const result = children_results[j];
            self.computed_rects[child_index] = .{
                .x = result.x,
                .y = result.y,
                .width = result.width,
                .height = result.height,
            };
        }

        // Recurse into children that are dirty OR whose size changed
        for (children, 0..) |child_index, j| {
            const is_container = self.child_count[child_index] > 0;

            if (!is_container) {
                // Leaf node - just clear dirty bit (no children to layout)
                self.dirty_bits.clearDirty(child_index);
                continue;
            }

            const is_dirty = self.dirty_bits.isDirty(child_index);
            const new_size = Size{
                .width = self.computed_rects[child_index].width,
                .height = self.computed_rects[child_index].height,
            };
            const size_changed = !sizesApproxEqual(new_size, old_sizes[j]);

            if (is_dirty or size_changed) {
                try self.computeNode(child_index, new_size.width, new_size.height);
            } else {
                // Not dirty and size didn't change - clear dirty bits recursively
                self.clearDescendantDirtyBits(child_index);
            }
        }

        // Container size: use explicit size or compute from children + padding
        const padding_h = style.padding_left + style.padding_right;
        const padding_v = style.padding_top + style.padding_bottom;

        const final_width = if (style.width >= 0) style.width else blk: {
            var max_x: f32 = 0;
            for (children_results) |result| {
                max_x = @max(max_x, result.x + result.width);
            }
            break :blk max_x + padding_h;
        };

        const final_height = if (style.height >= 0) style.height else blk: {
            var max_y: f32 = 0;
            for (children_results) |result| {
                max_y = @max(max_y, result.y + result.height);
            }
            break :blk max_y + padding_v;
        };

        self.computed_rects[index].width = final_width;
        self.computed_rects[index].height = final_height;

        // Update cache
        cached.update(container_width, container_height, style_version, final_width, final_height);
    }

    /// Clear dirty bits for a node and all its descendants
    fn clearDescendantDirtyBits(self: *LayoutEngine, index: u32) void {
        self.dirty_bits.clearDirty(index);

        var child = self.first_child[index];
        while (child != NULL_INDEX) {
            self.clearDescendantDirtyBits(child);
            child = self.next_sibling[child];
        }
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fn allocateIndex(self: *LayoutEngine) !u32 {
        if (self.free_list.len > 0) {
            return self.free_list.pop();
        }

        if (self.element_count >= MAX_ELEMENTS) {
            return error.TooManyElements;
        }

        const index = self.element_count;
        self.element_count += 1;
        return index;
    }

    fn linkChild(self: *LayoutEngine, parent: u32, child: u32) void {
        if (self.first_child[parent] == NULL_INDEX) {
            self.first_child[parent] = child;
        } else {
            var sibling = self.first_child[parent];
            while (self.next_sibling[sibling] != NULL_INDEX) {
                sibling = self.next_sibling[sibling];
            }
            self.next_sibling[sibling] = child;
        }
        self.child_count[parent] += 1;
    }

    fn unlinkChild(self: *LayoutEngine, parent: u32, child: u32) void {
        if (self.first_child[parent] == child) {
            self.first_child[parent] = self.next_sibling[child];
        } else {
            var prev = self.first_child[parent];
            while (prev != NULL_INDEX and self.next_sibling[prev] != child) {
                prev = self.next_sibling[prev];
            }
            if (prev != NULL_INDEX) {
                self.next_sibling[prev] = self.next_sibling[child];
            }
        }
        self.next_sibling[child] = NULL_INDEX;
        self.child_count[parent] -|= 1;
    }

    // =========================================================================
    // Public Queries
    // =========================================================================

    pub fn getRect(self: *const LayoutEngine, index: u32) Rect {
        return self.computed_rects[index];
    }

    pub fn getCacheStats(self: *const LayoutEngine) CacheStats {
        return self.cache_stats;
    }

    pub fn resetCacheStats(self: *LayoutEngine) void {
        self.cache_stats.reset();
    }

    pub fn getElementCount(self: *const LayoutEngine) u32 {
        return self.element_count;
    }

    pub fn getDirtyCount(self: *const LayoutEngine) usize {
        return self.dirty_bits.dirtyCount();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LayoutEngine: basic element creation" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
    });

    try std.testing.expectEqual(@as(u32, 0), root);
    try std.testing.expectEqual(@as(u32, 1), engine.getElementCount());
}

test "LayoutEngine: tree structure" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{ .direction = .column });
    const child1 = try engine.addElement(root, .{ .height = 50 });
    const child2 = try engine.addElement(root, .{ .height = 30 });

    try std.testing.expectEqual(@as(u32, 3), engine.getElementCount());
    try std.testing.expectEqual(@as(u16, 2), engine.child_count[root]);
    try std.testing.expectEqual(child1, engine.first_child[root]);
    try std.testing.expectEqual(child2, engine.next_sibling[child1]);
}

test "LayoutEngine: simple layout computation" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{
        .direction = .column,
        .justify_content = .flex_start,
        .gap = 10,
    });

    _ = try engine.addElement(root, .{ .height = 50 });
    _ = try engine.addElement(root, .{ .height = 30 });

    try engine.computeLayout(400, 600);

    const child1_rect = engine.getRect(1);
    const child2_rect = engine.getRect(2);

    try std.testing.expectEqual(@as(f32, 0), child1_rect.y);
    try std.testing.expectEqual(@as(f32, 50), child1_rect.height);
    try std.testing.expectEqual(@as(f32, 60), child2_rect.y); // 50 + 10 gap
    try std.testing.expectEqual(@as(f32, 30), child2_rect.height);
}

test "LayoutEngine: dirty marking stops at fixed-size" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // Create: root -> fixed_container -> child
    const root = try engine.addElement(null, .{ .direction = .column });
    const fixed = try engine.addElement(root, .{
        .direction = .column,
        .width = 200,
        .height = 100, // Fixed size!
    });
    const child = try engine.addElement(fixed, .{ .height = 50 });

    // Initial layout
    try engine.computeLayout(400, 600);

    // All dirty bits should be cleared
    try std.testing.expect(!engine.dirty_bits.isDirty(root));
    try std.testing.expect(!engine.dirty_bits.isDirty(fixed));
    try std.testing.expect(!engine.dirty_bits.isDirty(child));

    // Modify child
    engine.setStyle(child, .{ .height = 60 });

    // Child and fixed should be dirty, but NOT root (fixed is fixed-size)
    try std.testing.expect(engine.dirty_bits.isDirty(child));
    try std.testing.expect(engine.dirty_bits.isDirty(fixed));
    try std.testing.expect(!engine.dirty_bits.isDirty(root));
}

test "LayoutEngine: size change cascades to children" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // root -> container (flex-grow) -> grandchild
    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
    });
    const container = try engine.addElement(root, .{
        .direction = .column,
        .flex_grow = 1, // Will resize with parent
    });
    const grandchild = try engine.addElement(container, .{
        .flex_grow = 1,
    });

    try engine.computeLayout(400, 600);

    const container_rect = engine.getRect(container);
    const grandchild_rect = engine.getRect(grandchild);

    // Container should fill root, grandchild should fill container
    try std.testing.expectEqual(@as(f32, 600), container_rect.height);
    try std.testing.expectEqual(@as(f32, 600), grandchild_rect.height);
}

test "LayoutEngine: removeElement" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{ .direction = .column });
    const child1 = try engine.addElement(root, .{ .height = 50 });
    const child2 = try engine.addElement(root, .{ .height = 30 });

    try std.testing.expectEqual(@as(u16, 2), engine.child_count[root]);

    engine.removeElement(child1);

    try std.testing.expectEqual(@as(u16, 1), engine.child_count[root]);
    try std.testing.expectEqual(child2, engine.first_child[root]);
    try std.testing.expectEqual(@as(usize, 1), engine.free_list.len);
}

test "LayoutEngine: reparent" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{ .direction = .column });
    const container1 = try engine.addElement(root, .{ .direction = .row });
    const container2 = try engine.addElement(root, .{ .direction = .row });
    const child = try engine.addElement(container1, .{ .height = 50 });

    try std.testing.expectEqual(@as(u16, 1), engine.child_count[container1]);
    try std.testing.expectEqual(@as(u16, 0), engine.child_count[container2]);

    engine.reparent(child, container2);

    try std.testing.expectEqual(@as(u16, 0), engine.child_count[container1]);
    try std.testing.expectEqual(@as(u16, 1), engine.child_count[container2]);
    try std.testing.expectEqual(container2, engine.parent[child]);
}

test "LayoutEngine: free list reuse" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{ .direction = .column });
    const child1 = try engine.addElement(root, .{ .height = 50 });

    engine.removeElement(child1);
    try std.testing.expectEqual(@as(usize, 1), engine.free_list.len);

    const child2 = try engine.addElement(root, .{ .height = 60 });
    try std.testing.expectEqual(child1, child2); // Reused index
    try std.testing.expectEqual(@as(usize, 0), engine.free_list.len);
}

test "LayoutEngine: cache hit on root-level leaf" {
    // NOTE: Only root-level leaves use computeLeafLayout and its cache.
    // Nested leaves are computed by flexbox (different algorithm that
    // accounts for flex-grow, flex-shrink, available space, etc.)
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // Create a single leaf element at root (no parent container)
    const leaf = try engine.addElement(null, .{
        .width = 100,
        .height = 50,
    });

    engine.resetCacheStats();
    try engine.computeLayout(400, 600);

    const stats1 = engine.getCacheStats();
    try std.testing.expect(stats1.misses > 0); // First compute = miss

    // Re-mark dirty and compute again with same constraints
    engine.dirty_bits.markDirty(leaf);
    engine.resetCacheStats();
    try engine.computeLayout(400, 600);

    const stats2 = engine.getCacheStats();
    try std.testing.expect(stats2.hits > 0); // Second compute = hit
}

test "LayoutEngine: cache hit on unchanged container" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // Create container with children
    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
    });
    _ = try engine.addElement(root, .{ .height = 50 });
    _ = try engine.addElement(root, .{ .height = 30 });

    // First compute - cache misses
    engine.resetCacheStats();
    try engine.computeLayout(400, 600);

    const stats1 = engine.getCacheStats();
    try std.testing.expect(stats1.misses > 0);

    // Re-mark dirty and compute again with same constraints
    engine.dirty_bits.markDirty(0); // Mark root dirty
    engine.resetCacheStats();
    try engine.computeLayout(400, 600);

    const stats2 = engine.getCacheStats();
    try std.testing.expect(stats2.hits > 0); // Container cache hit
}

test "LayoutEngine: nested leaves computed by flexbox not computeLeafLayout" {
    // Nested leaves are computed by flexbox, which correctly handles
    // flex-grow, flex-shrink, and available space. This is different from
    // computeLeafLayout which just uses explicit/min sizes.
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
        .align_items = .stretch, // Stretch children on cross-axis
    });

    // Leaf with flex_grow = 1 and no explicit height
    // computeLeafLayout would give height = min_height = 0
    // Flexbox correctly stretches it to fill container
    const leaf = try engine.addElement(root, .{
        .flex_grow = 1,
        // width and height are both -1 (auto)
    });

    try engine.computeLayout(400, 600);

    const leaf_rect = engine.getRect(leaf);
    // Flexbox stretched the leaf to fill the 600px container (main axis)
    try std.testing.expectEqual(@as(f32, 600), leaf_rect.height);
    // Width stretched to container width (cross axis, align_items = stretch)
    try std.testing.expectEqual(@as(f32, 400), leaf_rect.width);
}

test "LayoutEngine: epsilon size comparison" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // Create nested structure
    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
    });
    const container = try engine.addElement(root, .{
        .direction = .column,
        .flex_grow = 1,
    });
    _ = try engine.addElement(container, .{ .flex_grow = 1 });

    try engine.computeLayout(400, 600);

    // Verify sizes are computed
    const container_rect = engine.getRect(container);
    try std.testing.expectEqual(@as(f32, 600), container_rect.height);
}

test "LayoutEngine: stack buffer for small child counts" {
    var engine = try LayoutEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.beginFrame();

    // Create container with children (less than STACK_CHILDREN_MAX)
    const root = try engine.addElement(null, .{
        .direction = .column,
        .width = 400,
        .height = 600,
    });

    // Add 10 children (well under the 32 stack limit)
    var expected_y: f32 = 0;
    for (0..10) |_| {
        _ = try engine.addElement(root, .{ .height = 20 });
    }

    try engine.computeLayout(400, 600);

    // Verify children are laid out correctly
    for (1..11) |i| {
        const rect = engine.getRect(@intCast(i));
        try std.testing.expectEqual(expected_y, rect.y);
        try std.testing.expectEqual(@as(f32, 20), rect.height);
        expected_y += 20;
    }
}
