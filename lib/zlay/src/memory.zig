const std = @import("std");
const Element = @import("element.zig").Element;

/// Memory pool for efficient element allocation and reuse
pub const ElementPool = struct {
    /// Allocator used for pool allocation
    allocator: std.mem.Allocator,
    
    /// Pool of free elements that can be reused
    free_elements: std.ArrayList(*Element),
    
    /// Total number of elements allocated (active + free)
    total_allocated: usize = 0,
    
    /// Statistics for pool usage
    stats: PoolStats = .{},
    
    /// Pool statistics
    pub const PoolStats = struct {
        /// Number of allocations from the pool
        allocations: usize = 0,
        
        /// Number of deallocations back to the pool
        deallocations: usize = 0,
        
        /// Number of cache hits (reused elements)
        cache_hits: usize = 0,
        
        /// Number of cache misses (new allocations)
        cache_misses: usize = 0,
        
        /// Peak number of active elements
        peak_elements: usize = 0,
        
        /// Reset statistics
        pub fn reset(self: *PoolStats) void {
            self.allocations = 0;
            self.deallocations = 0;
            self.cache_hits = 0;
            self.cache_misses = 0;
            // Don't reset peak_elements to maintain all-time peak
        }
    };
    
    /// Create a new element pool
    pub fn init(allocator: std.mem.Allocator) ElementPool {
        return .{
            .allocator = allocator,
            .free_elements = std.ArrayList(*Element).init(allocator),
        };
    }
    
    /// Free all resources associated with the pool
    pub fn deinit(self: *ElementPool) void {
        // Free all elements in the free list
        for (self.free_elements.items) |element| {
            self.allocator.destroy(element);
        }
        
        self.free_elements.deinit();
        self.total_allocated = 0;
    }
    
    /// Preallocate a number of elements to avoid allocations during rendering
    pub fn reserve(self: *ElementPool, count: usize) !void {
        try self.free_elements.ensureTotalCapacity(count);
        
        const current_free = self.free_elements.items.len;
        const to_allocate = count - current_free;
        
        if (to_allocate <= 0) {
            return;
        }
        
        // Allocate new elements
        var i: usize = 0;
        while (i < to_allocate) : (i += 1) {
            const element = try self.allocator.create(Element);
            element.* = Element.init();
            try self.free_elements.append(element);
        }
        
        self.total_allocated += to_allocate;
    }
    
    /// Get an element from the pool, or allocate a new one if none is available
    pub fn acquire(self: *ElementPool) !*Element {
        self.stats.allocations += 1;
        
        // Current active elements
        const active_elements = self.total_allocated - self.free_elements.items.len;
        
        // Update peak element count
        if (active_elements + 1 > self.stats.peak_elements) {
            self.stats.peak_elements = active_elements + 1;
        }
        
        // If we have a free element, reuse it
        if (self.free_elements.items.len > 0) {
            self.stats.cache_hits += 1;
            // Pop directly accesses the last item before removing it
            const element_ptr = self.free_elements.items[self.free_elements.items.len - 1];
            _ = self.free_elements.pop();
            element_ptr.* = Element.init();
            return element_ptr;
        }
        
        // Otherwise allocate a new one
        self.stats.cache_misses += 1;
        const element = try self.allocator.create(Element);
        // Initialize the element
        element.* = Element.init();
        self.total_allocated += 1;
        
        return element;
    }
    
    /// Return an element to the pool for reuse
    pub fn release(self: *ElementPool, element: *Element) !void {
        self.stats.deallocations += 1;
        
        // Clear any resources held by the element
        element.deinit();
        
        // Add it back to the free list
        try self.free_elements.append(element);
    }
    
    /// Get the current number of free elements in the pool
    pub fn freeCount(self: *const ElementPool) usize {
        return self.free_elements.items.len;
    }
    
    /// Get the current number of active (in-use) elements from the pool
    pub fn activeCount(self: *const ElementPool) usize {
        return self.total_allocated - self.free_elements.items.len;
    }
    
    /// Reset the pool statistics
    pub fn resetStats(self: *ElementPool) void {
        self.stats.reset();
    }
};

/// Arena allocator extension with utility methods for pooling
pub const ArenaPool = struct {
    /// Underlying arena allocator
    arena: std.heap.ArenaAllocator,
    
    /// Create a new arena pool
    pub fn init(parent_allocator: std.mem.Allocator) ArenaPool {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
        };
    }
    
    /// Free all memory in the arena
    pub fn deinit(self: *ArenaPool) void {
        self.arena.deinit();
    }
    
    /// Reset the arena, keeping allocated memory for reuse
    /// Returns the number of bytes retained
    pub fn reset(self: *ArenaPool) usize {
        // Get the current capacity before reset
        const prev_capacity = self.getCapacity();
        
        // Reset the arena but keep capacity
        _ = self.arena.reset(.retain_capacity);
        
        return prev_capacity;
    }
    
    /// Get the arena allocator
    pub fn allocator(self: *ArenaPool) std.mem.Allocator {
        return self.arena.allocator();
    }
    
    /// Get the current capacity of the arena
    pub fn getCapacity(self: *ArenaPool) usize {
        return self.arena.queryCapacity();
    }
};

/// Memory pool for ID strings with deduplication 
pub const StringPool = struct {
    /// Allocator used for pool allocation
    allocator: std.mem.Allocator,
    
    /// Map of string content to interned string
    strings: std.StringHashMap([]const u8),
    
    /// Create a new string pool
    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    /// Free all resources associated with the pool
    pub fn deinit(self: *StringPool) void {
        // Free all interned strings
        var it = self.strings.valueIterator();
        while (it.next()) |string| {
            self.allocator.free(string.*);
        }
        
        self.strings.deinit();
    }
    
    /// Intern a string, returning a unique instance
    pub fn intern(self: *StringPool, string: []const u8) ![]const u8 {
        // Check if we already have this string
        if (self.strings.get(string)) |existing| {
            return existing;
        }
        
        // Create a new copy
        const owned = try self.allocator.dupe(u8, string);
        try self.strings.put(owned, owned);
        
        return owned;
    }
    
    /// Get the number of unique strings in the pool
    pub fn count(self: *const StringPool) usize {
        return self.strings.count();
    }
    
    /// Check if a string exists in the pool
    pub fn contains(self: *const StringPool, string: []const u8) bool {
        return self.strings.contains(string);
    }
};

// Tests for memory pools
test "element pool basic" {
    var pool = ElementPool.init(std.testing.allocator);
    defer pool.deinit();
    
    // Initial state
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
    
    // Acquire an element
    const element1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());
    
    // Release the element
    try pool.release(element1);
    try std.testing.expectEqual(@as(usize, 1), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
    
    // Acquire another element (should reuse the one we released)
    const element2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());
    
    // Release it again
    try pool.release(element2);
    
    // Stats
    try std.testing.expectEqual(@as(usize, 2), pool.stats.allocations);
    try std.testing.expectEqual(@as(usize, 2), pool.stats.deallocations);
    try std.testing.expectEqual(@as(usize, 1), pool.stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), pool.stats.cache_misses);
    try std.testing.expectEqual(@as(usize, 1), pool.stats.peak_elements);
}

test "element pool preallocation" {
    var pool = ElementPool.init(std.testing.allocator);
    defer pool.deinit();
    
    // Preallocate 10 elements
    try pool.reserve(10);
    try std.testing.expectEqual(@as(usize, 10), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
    
    // Acquire 5 elements
    var elements: [5]*Element = undefined;
    for (0..5) |i| {
        elements[i] = try pool.acquire();
    }
    
    try std.testing.expectEqual(@as(usize, 5), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 5), pool.activeCount());
    
    // Release them all
    for (0..5) |i| {
        try pool.release(elements[i]);
    }
    
    try std.testing.expectEqual(@as(usize, 10), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "arena pool" {
    var pool = ArenaPool.init(std.testing.allocator);
    defer pool.deinit();
    
    const allocator = pool.allocator();
    
    // Allocate some memory
    _ = try allocator.alloc(u8, 1000);
    _ = try allocator.alloc(u8, 2000);
    
    // Reset and check capacity
    const capacity = pool.reset();
    try std.testing.expect(capacity >= 3000);
    
    // Allocate again and verify we can still use the arena
    const buf = try allocator.alloc(u8, 1500);
    for (0..buf.len) |i| {
        buf[i] = @truncate(i);
    }
}

test "string pool" {
    var pool = StringPool.init(std.testing.allocator);
    defer pool.deinit();
    
    // Basic interning
    const str1 = try pool.intern("hello");
    try std.testing.expectEqualStrings("hello", str1);
    try std.testing.expectEqual(@as(usize, 1), pool.count());
    
    // Interning the same string again should return the same pointer
    const str2 = try pool.intern("hello");
    try std.testing.expectEqual(str1.ptr, str2.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.count());
    
    // Different string should be different
    const str3 = try pool.intern("world");
    try std.testing.expect(str1.ptr != str3.ptr);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    
    // Check contains
    try std.testing.expect(pool.contains("hello"));
    try std.testing.expect(pool.contains("world"));
    try std.testing.expect(!pool.contains("foo"));
}