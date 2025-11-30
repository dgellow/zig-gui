const std = @import("std");
const builtin = @import("builtin");

/// Widget identifier - a 4-byte hash for tracking widget identity.
///
/// Provides three ways to create IDs:
/// - `from()`: Comptime string hashing (zero runtime cost for Zig users)
/// - `runtime()`: Runtime string hashing (for C API and dynamic strings)
/// - `indexed()`: Combine a base ID with an index (for loops)
///
/// Memory: 4 bytes per ID.
///
/// ## Example
///
/// ```zig
/// // Comptime (zero cost)
/// const settings_id = WidgetId.from("settings");
///
/// // Runtime (C API)
/// const dynamic_id = WidgetId.runtime(user_string);
///
/// // Loops
/// for (items, 0..) |_, i| {
///     const item_id = WidgetId.from("item").indexed(i);
/// }
/// ```
pub const WidgetId = packed struct {
    hash: u32,

    const Self = @This();

    /// Create ID from comptime string - zero runtime cost.
    /// Hash is computed at compile time.
    pub fn from(comptime label: []const u8) Self {
        return .{ .hash = comptime @as(u32, @truncate(std.hash.Wyhash.hash(0, label))) };
    }

    /// Create ID from runtime string - for C API and dynamic cases.
    pub fn runtime(label: []const u8) Self {
        return .{ .hash = @as(u32, @truncate(std.hash.Wyhash.hash(0, label))) };
    }

    /// Combine this ID with an index - for use in loops.
    /// Uses golden ratio mixing for good distribution.
    pub fn indexed(self: Self, index: usize) Self {
        return .{ .hash = self.hash ^ (@as(u32, @truncate(index)) *% 0x9e3779b9) };
    }

    /// Combine with another ID (for nested scoping).
    pub fn combine(self: Self, other: Self) Self {
        return .{ .hash = self.hash ^ other.hash };
    }

    /// Compare two IDs for equality.
    pub fn eql(self: Self, other: Self) bool {
        return self.hash == other.hash;
    }
};

/// ID stack for hierarchical widget scoping.
///
/// Enables parent-child relationships in widget IDs:
/// - Push parent scope with `push()` or `pushIndex()`
/// - Child widgets combine their ID with the stack's current hash
/// - Pop to return to parent scope
///
/// Memory: 68 bytes (16-deep stack + depth + current_hash).
/// Debug mode adds path tracking for collision diagnostics.
///
/// ## Example
///
/// ```zig
/// var stack = IdStack.init(allocator);
///
/// stack.push("settings_panel");
/// defer stack.pop();
///
/// // Widget ID = hash("settings_panel") ^ hash("save_button")
/// const button_id = stack.combine(WidgetId.from("save_button"));
/// ```
pub const IdStack = struct {
    /// Stack of previous hashes for restoration on pop
    stack: [MAX_DEPTH]u32 = undefined,

    /// Current stack depth
    depth: u8 = 0,

    /// Current combined hash of all pushed IDs
    current_hash: u32 = 0,

    /// Debug-only: path of string labels for collision diagnostics
    debug_path: DebugPath = if (is_debug) .{} else {},

    /// Debug-only: allocator for path strings
    debug_allocator: DebugAllocator = if (is_debug) null else {},

    const Self = @This();
    const MAX_DEPTH: usize = 16;

    const is_debug = builtin.mode == .Debug;
    const DebugPath = if (is_debug) std.ArrayList([]const u8) else void;
    const DebugAllocator = if (is_debug) ?std.mem.Allocator else void;

    /// Initialize an ID stack.
    /// In debug mode, allocator is used for path tracking.
    pub fn init(allocator: ?std.mem.Allocator) Self {
        var self = Self{};
        if (is_debug) {
            self.debug_allocator = allocator;
            if (allocator) |alloc| {
                self.debug_path = std.ArrayList([]const u8).init(alloc);
            }
        }
        return self;
    }

    /// Clean up resources (debug mode only).
    pub fn deinit(self: *Self) void {
        if (is_debug) {
            if (self.debug_allocator != null) {
                self.debug_path.deinit();
            }
        }
    }

    /// Push a string ID onto the stack (comptime version - zero cost hash).
    pub fn push(self: *Self, comptime label: []const u8) void {
        self.pushHash(comptime @as(u32, @truncate(std.hash.Wyhash.hash(0, label))));
        if (is_debug) {
            if (self.debug_allocator != null) {
                self.debug_path.append(label) catch {};
            }
        }
    }

    /// Push a runtime string ID onto the stack.
    pub fn pushRuntime(self: *Self, label: []const u8) void {
        self.pushHash(@as(u32, @truncate(std.hash.Wyhash.hash(0, label))));
        if (is_debug) {
            if (self.debug_allocator != null) {
                self.debug_path.append(label) catch {};
            }
        }
    }

    /// Push an index onto the stack (for loops).
    pub fn pushIndex(self: *Self, index: usize) void {
        self.pushHash(@as(u32, @truncate(index)));
        // Note: In debug mode, we could store the index as a string,
        // but for now we just skip it in the path
    }

    /// Push a WidgetId onto the stack.
    pub fn pushId(self: *Self, id: WidgetId) void {
        self.pushHash(id.hash);
    }

    /// Internal: push a raw hash value.
    fn pushHash(self: *Self, hash: u32) void {
        if (self.depth >= MAX_DEPTH) {
            // Stack overflow - in release, silently ignore
            // In debug, this would be a good place for a warning
            return;
        }

        // Save current hash for restoration
        self.stack[self.depth] = self.current_hash;
        self.depth += 1;

        // Combine with new hash using XOR + golden ratio mixing
        self.current_hash ^= hash *% 0x9e3779b9;
    }

    /// Pop the most recent ID from the stack.
    pub fn pop(self: *Self) void {
        if (self.depth == 0) {
            // Stack underflow - silently ignore
            return;
        }

        self.depth -= 1;
        self.current_hash = self.stack[self.depth];

        if (is_debug) {
            if (self.debug_allocator != null and self.debug_path.items.len > 0) {
                _ = self.debug_path.pop();
            }
        }
    }

    /// Clear the stack to initial state.
    pub fn clear(self: *Self) void {
        self.depth = 0;
        self.current_hash = 0;
        if (is_debug) {
            if (self.debug_allocator != null) {
                self.debug_path.clearRetainingCapacity();
            }
        }
    }

    /// Combine the current stack hash with a widget ID.
    /// Returns the final ID to use for the widget.
    pub fn combine(self: *const Self, widget_id: WidgetId) WidgetId {
        return .{ .hash = self.current_hash ^ widget_id.hash };
    }

    /// Combine with a comptime label directly.
    pub fn combineLabel(self: *const Self, comptime label: []const u8) WidgetId {
        const widget_hash = comptime @as(u32, @truncate(std.hash.Wyhash.hash(0, label)));
        return .{ .hash = self.current_hash ^ widget_hash };
    }

    /// Get current depth.
    pub fn getDepth(self: *const Self) u8 {
        return self.depth;
    }

    /// Get current hash (for debugging).
    pub fn getCurrentHash(self: *const Self) u32 {
        return self.current_hash;
    }

    /// Get debug path as string (debug builds only).
    /// Returns empty string in release builds.
    pub fn getDebugPath(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        if (!is_debug) {
            return allocator.alloc(u8, 0);
        }

        if (self.debug_allocator == null or self.debug_path.items.len == 0) {
            return allocator.alloc(u8, 0);
        }

        // Calculate total length
        var total_len: usize = 0;
        for (self.debug_path.items, 0..) |item, i| {
            total_len += item.len;
            if (i < self.debug_path.items.len - 1) {
                total_len += 3; // " > "
            }
        }

        // Build the path string
        var result = try allocator.alloc(u8, total_len);
        var offset: usize = 0;

        for (self.debug_path.items, 0..) |item, i| {
            @memcpy(result[offset .. offset + item.len], item);
            offset += item.len;

            if (i < self.debug_path.items.len - 1) {
                @memcpy(result[offset .. offset + 3], " > ");
                offset += 3;
            }
        }

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WidgetId.from creates consistent comptime hashes" {
    const id1 = WidgetId.from("button");
    const id2 = WidgetId.from("button");
    const id3 = WidgetId.from("checkbox");

    // Same string = same hash
    try std.testing.expectEqual(id1.hash, id2.hash);

    // Different string = different hash
    try std.testing.expect(id1.hash != id3.hash);
}

test "WidgetId.runtime matches comptime for same string" {
    const comptime_id = WidgetId.from("settings");
    const runtime_id = WidgetId.runtime("settings");

    try std.testing.expectEqual(comptime_id.hash, runtime_id.hash);
}

test "WidgetId.indexed creates unique IDs for different indices" {
    const base = WidgetId.from("item");

    const id0 = base.indexed(0);
    const id1 = base.indexed(1);
    const id2 = base.indexed(2);

    // Each index produces a different ID
    try std.testing.expect(id0.hash != id1.hash);
    try std.testing.expect(id1.hash != id2.hash);
    try std.testing.expect(id0.hash != id2.hash);

    // Same index produces same ID
    const id1_again = base.indexed(1);
    try std.testing.expectEqual(id1.hash, id1_again.hash);
}

test "WidgetId.combine is commutative" {
    const a = WidgetId.from("panel");
    const b = WidgetId.from("button");

    // XOR is commutative, so combine order shouldn't matter
    const ab = a.combine(b);
    const ba = b.combine(a);

    try std.testing.expectEqual(ab.hash, ba.hash);
}

test "WidgetId.eql works correctly" {
    const id1 = WidgetId.from("test");
    const id2 = WidgetId.from("test");
    const id3 = WidgetId.from("other");

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}

test "WidgetId size is 4 bytes" {
    try std.testing.expectEqual(@sizeOf(WidgetId), 4);
}

test "IdStack basic push/pop" {
    var stack = IdStack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expectEqual(@as(u8, 0), stack.getDepth());
    try std.testing.expectEqual(@as(u32, 0), stack.getCurrentHash());

    stack.push("level1");
    try std.testing.expectEqual(@as(u8, 1), stack.getDepth());
    try std.testing.expect(stack.getCurrentHash() != 0);

    const hash_after_level1 = stack.getCurrentHash();

    stack.push("level2");
    try std.testing.expectEqual(@as(u8, 2), stack.getDepth());
    try std.testing.expect(stack.getCurrentHash() != hash_after_level1);

    stack.pop();
    try std.testing.expectEqual(@as(u8, 1), stack.getDepth());
    try std.testing.expectEqual(hash_after_level1, stack.getCurrentHash());

    stack.pop();
    try std.testing.expectEqual(@as(u8, 0), stack.getDepth());
    try std.testing.expectEqual(@as(u32, 0), stack.getCurrentHash());
}

test "IdStack pushIndex" {
    var stack = IdStack.init(null);

    stack.push("items");
    const base_hash = stack.getCurrentHash();

    stack.pushIndex(0);
    const hash_with_0 = stack.getCurrentHash();
    stack.pop();

    stack.pushIndex(1);
    const hash_with_1 = stack.getCurrentHash();
    stack.pop();

    // Different indices = different hashes
    try std.testing.expect(hash_with_0 != hash_with_1);
    try std.testing.expect(hash_with_0 != base_hash);
    try std.testing.expect(hash_with_1 != base_hash);
}

test "IdStack combine produces unique widget IDs" {
    var stack = IdStack.init(null);

    // Widget in root
    const button_in_root = stack.combine(WidgetId.from("button"));

    // Widget in panel
    stack.push("panel");
    const button_in_panel = stack.combine(WidgetId.from("button"));
    stack.pop();

    // Same widget label, different context = different ID
    try std.testing.expect(!button_in_root.eql(button_in_panel));
}

test "IdStack combineLabel" {
    var stack = IdStack.init(null);

    stack.push("panel");

    const id1 = stack.combine(WidgetId.from("button"));
    const id2 = stack.combineLabel("button");

    // Both methods should produce the same ID
    try std.testing.expectEqual(id1.hash, id2.hash);
}

test "IdStack clear resets state" {
    var stack = IdStack.init(null);

    stack.push("a");
    stack.push("b");
    stack.push("c");

    try std.testing.expectEqual(@as(u8, 3), stack.getDepth());
    try std.testing.expect(stack.getCurrentHash() != 0);

    stack.clear();

    try std.testing.expectEqual(@as(u8, 0), stack.getDepth());
    try std.testing.expectEqual(@as(u32, 0), stack.getCurrentHash());
}

test "IdStack handles underflow gracefully" {
    var stack = IdStack.init(null);

    // Pop on empty stack should not crash
    stack.pop();
    stack.pop();
    stack.pop();

    try std.testing.expectEqual(@as(u8, 0), stack.getDepth());
}

test "IdStack handles overflow gracefully" {
    var stack = IdStack.init(null);

    // Push more than MAX_DEPTH times
    for (0..20) |_| {
        stack.push("level");
    }

    // Should cap at MAX_DEPTH (16)
    try std.testing.expect(stack.getDepth() <= 16);
}

test "IdStack pushRuntime matches push for same string" {
    var stack1 = IdStack.init(null);
    var stack2 = IdStack.init(null);

    stack1.push("test_label");
    stack2.pushRuntime("test_label");

    try std.testing.expectEqual(stack1.getCurrentHash(), stack2.getCurrentHash());
}

test "IdStack pushId" {
    var stack = IdStack.init(null);

    const id = WidgetId.from("custom");
    stack.pushId(id);

    const expected_hash = id.hash *% 0x9e3779b9; // XOR with 0 then multiply
    try std.testing.expectEqual(expected_hash, stack.getCurrentHash());
}

test "IdStack debug path in debug mode" {
    // This test verifies debug functionality doesn't crash
    // Actual path content depends on build mode
    var stack = IdStack.init(std.testing.allocator);
    defer stack.deinit();

    stack.push("parent");
    stack.push("child");

    const path = try stack.getDebugPath(std.testing.allocator);
    defer std.testing.allocator.free(path);

    // In debug mode, path should be "parent > child"
    // In release mode, path is empty
    if (builtin.mode == .Debug) {
        try std.testing.expectEqualStrings("parent > child", path);
    } else {
        try std.testing.expectEqual(@as(usize, 0), path.len);
    }
}

test "IdStack real-world usage pattern" {
    // Simulate a typical UI hierarchy
    var stack = IdStack.init(null);

    // Root panel
    stack.push("settings_panel");

    // First button in panel
    const save_id = stack.combineLabel("save");

    // Second button in panel
    const cancel_id = stack.combineLabel("cancel");

    // Loop of items
    stack.push("item_list");
    var item_ids: [3]WidgetId = undefined;
    for (0..3) |i| {
        stack.pushIndex(i);
        item_ids[i] = stack.combineLabel("delete");
        stack.pop();
    }
    stack.pop(); // item_list

    stack.pop(); // settings_panel

    // Verify all IDs are unique
    try std.testing.expect(!save_id.eql(cancel_id));
    try std.testing.expect(!item_ids[0].eql(item_ids[1]));
    try std.testing.expect(!item_ids[1].eql(item_ids[2]));
    try std.testing.expect(!item_ids[0].eql(save_id));
}
