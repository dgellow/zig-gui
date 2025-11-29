const std = @import("std");

/// Tracked value wrapper for reactive state management.
///
/// Tracked(T) wraps any value with a version counter that increments on every write.
/// This enables O(1) state changes and O(N) change detection where N = field count.
///
/// Memory overhead: 4 bytes per field (version counter).
/// Write cost: O(1) - just increment version.
/// Read cost: O(1) - direct field access.
///
/// ## Example
///
/// ```zig
/// const AppState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
///     name: Tracked([]const u8) = .{ .value = "World" },
/// };
///
/// fn myApp(gui: *GUI, state: *AppState) !void {
///     try gui.text("Counter: {}", .{state.counter.get()});
///
///     if (try gui.button("Increment")) {
///         state.counter.set(state.counter.get() + 1);
///     }
/// }
/// ```
///
/// ## Design Rationale
///
/// This pattern is inspired by SolidJS signals and Svelte 5 runes:
/// - Zero allocations on state change
/// - Works identically across all execution modes (event-driven, game-loop, minimal)
/// - Future-proof: can migrate to comptime Reactive(T) without breaking changes
///
/// See docs/STATE_MANAGEMENT.md for full analysis.
pub fn Tracked(comptime T: type) type {
    return struct {
        /// The wrapped value
        value: T = undefined,

        /// Version counter - incremented on every write
        /// Using u32 for balance between overflow time and memory
        /// At 60 FPS continuous writes, wraps after ~2.2 years
        _v: u32 = 0,

        const Self = @This();

        /// Initialize with a value
        pub fn init(initial: T) Self {
            return .{ .value = initial, ._v = 0 };
        }

        /// Read the current value - O(1)
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Write a new value - O(1), increments version
        pub inline fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            self._v +%= 1; // Wrapping add - safe overflow
        }

        /// Set only if value changed (requires equality comparison)
        /// Returns true if value was changed
        pub inline fn setIfChanged(self: *Self, new_value: T) bool {
            if (std.meta.eql(self.value, new_value)) return false;
            self.set(new_value);
            return true;
        }

        /// Get mutable pointer to value - assumes mutation will happen
        /// Use for in-place modification of complex types (arrays, structs)
        ///
        /// Example:
        /// ```zig
        /// state.items.ptr().append(.{ .name = "New" }) catch {};
        /// ```
        pub inline fn ptr(self: *Self) *T {
            self._v +%= 1; // Assume mutation
            return &self.value;
        }

        /// Get current version number (for fine-grained tracking)
        pub inline fn version(self: *const Self) u32 {
            return self._v;
        }

        /// Update value using a function - increments version once
        pub inline fn update(self: *Self, f: fn (T) T) void {
            self.value = f(self.value);
            self._v +%= 1;
        }

        /// Update value using a function with context
        pub inline fn updateCtx(self: *Self, ctx: anytype, f: fn (@TypeOf(ctx), T) T) void {
            self.value = f(ctx, self.value);
            self._v +%= 1;
        }
    };
}

/// Compute combined version of all Tracked fields in a struct.
/// Returns a u64 that changes whenever any Tracked field changes.
///
/// Complexity: O(N) where N = number of fields (NOT data size)
///
/// Example:
/// ```zig
/// var last_version: u64 = 0;
/// if (computeStateVersion(&state) != last_version) {
///     // State changed, need to re-render
/// }
/// ```
pub fn computeStateVersion(state: anytype) u64 {
    const State = @TypeOf(state.*);
    var version: u64 = 0;

    inline for (std.meta.fields(State)) |field| {
        const field_ptr = &@field(state.*, field.name);
        const FieldType = @TypeOf(field_ptr.*);

        // Check if this field has a _v member (is Tracked)
        if (@hasField(FieldType, "_v")) {
            version +%= field_ptr._v;
        }
    }

    return version;
}

/// Check if state changed since last check and update last_version.
/// Returns true if any Tracked field changed.
///
/// Example:
/// ```zig
/// var last_version: u64 = 0;
/// while (app.isRunning()) {
///     const event = try app.waitForEvent();
///     handleEvent(event, &state);
///
///     if (stateChanged(&state, &last_version)) {
///         try app.render(ui_fn, &state);
///     }
/// }
/// ```
pub fn stateChanged(state: anytype, last_version: *u64) bool {
    const current = computeStateVersion(state);
    if (current != last_version.*) {
        last_version.* = current;
        return true;
    }
    return false;
}

/// Find which fields changed by comparing current versions to stored versions.
/// Useful for minimal mode partial updates.
///
/// Returns a slice of field indices that changed.
pub fn findChangedFields(
    state: anytype,
    last_versions: []u32,
    changed_buffer: []usize,
) []usize {
    const State = @TypeOf(state.*);
    var changed_count: usize = 0;

    inline for (std.meta.fields(State), 0..) |field, i| {
        const field_ptr = &@field(state.*, field.name);
        const FieldType = @TypeOf(field_ptr.*);

        if (@hasField(FieldType, "_v")) {
            if (field_ptr._v != last_versions[i]) {
                last_versions[i] = field_ptr._v;
                if (changed_count < changed_buffer.len) {
                    changed_buffer[changed_count] = i;
                    changed_count += 1;
                }
            }
        }
    }

    return changed_buffer[0..changed_count];
}

/// Capture current versions of all Tracked fields.
/// Useful for initializing last_versions array.
pub fn captureFieldVersions(state: anytype, versions: []u32) void {
    const State = @TypeOf(state.*);

    inline for (std.meta.fields(State), 0..) |field, i| {
        const field_ptr = &@field(state.*, field.name);
        const FieldType = @TypeOf(field_ptr.*);

        if (@hasField(FieldType, "_v")) {
            if (i < versions.len) {
                versions[i] = field_ptr._v;
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Tracked basic operations" {
    var counter = Tracked(i32).init(0);

    // Initial state
    try std.testing.expectEqual(@as(i32, 0), counter.get());
    try std.testing.expectEqual(@as(u32, 0), counter.version());

    // Set increments version
    counter.set(42);
    try std.testing.expectEqual(@as(i32, 42), counter.get());
    try std.testing.expectEqual(@as(u32, 1), counter.version());

    // Another set
    counter.set(100);
    try std.testing.expectEqual(@as(i32, 100), counter.get());
    try std.testing.expectEqual(@as(u32, 2), counter.version());
}

test "Tracked setIfChanged" {
    var counter = Tracked(i32).init(10);

    // Setting same value doesn't increment
    const changed1 = counter.setIfChanged(10);
    try std.testing.expect(!changed1);
    try std.testing.expectEqual(@as(u32, 0), counter.version());

    // Setting different value increments
    const changed2 = counter.setIfChanged(20);
    try std.testing.expect(changed2);
    try std.testing.expectEqual(@as(u32, 1), counter.version());
}

test "Tracked ptr mutation" {
    const Item = struct { x: i32, y: i32 };
    var item = Tracked(Item).init(.{ .x = 0, .y = 0 });

    // ptr() increments version
    item.ptr().x = 10;
    try std.testing.expectEqual(@as(i32, 10), item.get().x);
    try std.testing.expectEqual(@as(u32, 1), item.version());

    // Another ptr() call
    item.ptr().y = 20;
    try std.testing.expectEqual(@as(i32, 20), item.get().y);
    try std.testing.expectEqual(@as(u32, 2), item.version());
}

test "Tracked with array" {
    var arr = Tracked([3]i32).init(.{ 1, 2, 3 });

    // Modify via ptr
    arr.ptr()[1] = 42;
    try std.testing.expectEqual(@as(i32, 42), arr.get()[1]);
}

test "computeStateVersion" {
    const State = struct {
        a: Tracked(i32) = .{ .value = 0 },
        b: Tracked(i32) = .{ .value = 0 },
        plain: i32 = 0, // Not tracked
    };

    var state = State{};

    const v1 = computeStateVersion(&state);
    try std.testing.expectEqual(@as(u64, 0), v1);

    state.a.set(1);
    const v2 = computeStateVersion(&state);
    try std.testing.expectEqual(@as(u64, 1), v2);

    state.b.set(2);
    const v3 = computeStateVersion(&state);
    try std.testing.expectEqual(@as(u64, 2), v3);

    // Plain field doesn't affect version
    state.plain = 999;
    const v4 = computeStateVersion(&state);
    try std.testing.expectEqual(@as(u64, 2), v4);
}

test "stateChanged" {
    const State = struct {
        counter: Tracked(i32) = .{ .value = 0 },
    };

    var state = State{};
    var last_version: u64 = 0;

    // Initial check - no change yet (version is 0)
    const changed1 = stateChanged(&state, &last_version);
    try std.testing.expect(!changed1);

    // Modify state
    state.counter.set(1);

    // Now should detect change
    const changed2 = stateChanged(&state, &last_version);
    try std.testing.expect(changed2);

    // No more changes
    const changed3 = stateChanged(&state, &last_version);
    try std.testing.expect(!changed3);
}

test "version wrapping" {
    var counter = Tracked(i32){ .value = 0, ._v = std.math.maxInt(u32) };

    // Should wrap without panic
    counter.set(1);
    try std.testing.expectEqual(@as(u32, 0), counter.version());

    counter.set(2);
    try std.testing.expectEqual(@as(u32, 1), counter.version());
}

test "Tracked with slice" {
    var name = Tracked([]const u8).init("hello");

    try std.testing.expectEqualStrings("hello", name.get());

    name.set("world");
    try std.testing.expectEqualStrings("world", name.get());
    try std.testing.expectEqual(@as(u32, 1), name.version());
}
