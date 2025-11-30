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

        // Check if this field is a struct with _v member (is Tracked)
        switch (@typeInfo(FieldType)) {
            .Struct => {
                if (@hasField(FieldType, "_v")) {
                    version +%= field_ptr._v;
                }
            },
            else => {},
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
// Reactive(T) - O(1) Global Change Detection (Option E)
// ============================================================================

/// Reactive state wrapper that enables O(1) global change detection.
///
/// While Tracked(T) provides O(N) change detection (where N = field count),
/// Reactive(T) adds a single global version counter that's incremented
/// on ANY field change, enabling O(1) "did anything change?" checks.
///
/// ## Usage
///
/// ```zig
/// // Define state with Tracked fields
/// const InnerState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
///     name: Tracked([]const u8) = .{ .value = "World" },
/// };
///
/// // Wrap with Reactive for O(1) change detection
/// var state = Reactive(InnerState).init();
///
/// // Access values via inner
/// const count = state.inner.counter.get();
///
/// // Set values via Reactive.set() to bump global version
/// state.set(.counter, 42);
///
/// // O(1) change detection
/// if (state.changed(&last_version)) {
///     // Something changed, re-render
/// }
/// ```
///
/// ## Performance
///
/// - Memory: sizeof(T) + 8 bytes (global version u64)
/// - Write: O(1) - increment both field and global versions
/// - Global change check: O(1) - single comparison
/// - Per-field change check: Still available via inner.field.version()
///
/// ## Migration from Tracked
///
/// Reactive is a non-breaking upgrade from plain Tracked:
/// 1. Wrap your state type: `Reactive(MyState).init()`
/// 2. Change `state.field.set(v)` to `state.set(.field, v)`
/// 3. Change `stateChanged(&state, &v)` to `state.changed(&v)`
///
pub fn Reactive(comptime Inner: type) type {
    return struct {
        /// The wrapped state struct with Tracked fields
        inner: Inner = .{},

        /// Global version counter - incremented on ANY field change
        /// This enables O(1) "did anything change?" checks
        _global_version: u64 = 0,

        const Self = @This();

        /// Initialize with default values
        pub fn init() Self {
            return .{};
        }

        /// Initialize with specific inner state
        pub fn initWith(inner_state: Inner) Self {
            return .{ .inner = inner_state };
        }

        /// Set a Tracked field value, incrementing both field and global versions.
        ///
        /// Example:
        /// ```zig
        /// state.set(.counter, 42);
        /// state.set(.name, "Hello");
        /// ```
        pub fn set(self: *Self, comptime field: std.meta.FieldEnum(Inner), value: anytype) void {
            const field_ptr = &@field(self.inner, @tagName(field));

            // Set the value (increments field._v)
            field_ptr.set(value);

            // Also increment global version
            self._global_version +%= 1;
        }

        /// Get a Tracked field value (shortcut for inner.field.get())
        pub fn get(self: *const Self, comptime field: std.meta.FieldEnum(Inner)) FieldValueType(field) {
            const field_ptr = &@field(self.inner, @tagName(field));
            return field_ptr.get();
        }

        /// Get mutable pointer to field value, incrementing both versions
        pub fn ptr(self: *Self, comptime field: std.meta.FieldEnum(Inner)) FieldPtrType(field) {
            const field_ptr = &@field(self.inner, @tagName(field));
            self._global_version +%= 1;
            return field_ptr.ptr();
        }

        /// Check if ANY field changed since last check (O(1))
        ///
        /// This is the key advantage of Reactive over plain Tracked:
        /// - Tracked: O(N) to check all fields
        /// - Reactive: O(1) single comparison
        pub fn changed(self: *const Self, last_version: *u64) bool {
            if (self._global_version != last_version.*) {
                last_version.* = self._global_version;
                return true;
            }
            return false;
        }

        /// Get current global version
        pub fn globalVersion(self: *const Self) u64 {
            return self._global_version;
        }

        // Helper to get the value type of a Tracked field
        fn FieldValueType(comptime field: std.meta.FieldEnum(Inner)) type {
            const field_info = std.meta.fields(Inner)[@intFromEnum(field)];
            const FieldType = field_info.type;
            // Extract T from Tracked(T)
            return @TypeOf(@as(FieldType, undefined).value);
        }

        // Helper to get the pointer type for a Tracked field
        fn FieldPtrType(comptime field: std.meta.FieldEnum(Inner)) type {
            const ValueType = FieldValueType(field);
            return *ValueType;
        }
    };
}

/// Check if a Reactive state changed (convenience function)
pub fn reactiveChanged(state: anytype, last_version: *u64) bool {
    return state.changed(last_version);
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

// ============================================================================
// Reactive Tests
// ============================================================================

test "Reactive basic operations" {
    const InnerState = struct {
        counter: Tracked(i32) = .{ .value = 0 },
        name: Tracked([]const u8) = .{ .value = "test" },
    };

    var state = Reactive(InnerState).init();

    // Initial values
    try std.testing.expectEqual(@as(i32, 0), state.get(.counter));
    try std.testing.expectEqualStrings("test", state.get(.name));
    try std.testing.expectEqual(@as(u64, 0), state.globalVersion());

    // Set via Reactive.set()
    state.set(.counter, 42);
    try std.testing.expectEqual(@as(i32, 42), state.get(.counter));
    try std.testing.expectEqual(@as(u64, 1), state.globalVersion());

    // Set another field
    state.set(.name, "hello");
    try std.testing.expectEqualStrings("hello", state.get(.name));
    try std.testing.expectEqual(@as(u64, 2), state.globalVersion());
}

test "Reactive O(1) change detection" {
    const InnerState = struct {
        a: Tracked(i32) = .{ .value = 0 },
        b: Tracked(i32) = .{ .value = 0 },
        c: Tracked(i32) = .{ .value = 0 },
    };

    var state = Reactive(InnerState).init();
    var last_version: u64 = 0;

    // Initially no change
    try std.testing.expect(!state.changed(&last_version));

    // Any field change is detected in O(1)
    state.set(.b, 100);
    try std.testing.expect(state.changed(&last_version));

    // No more changes
    try std.testing.expect(!state.changed(&last_version));

    // Multiple changes still O(1) to detect
    state.set(.a, 1);
    state.set(.c, 2);
    try std.testing.expect(state.changed(&last_version));
}

test "Reactive inner access" {
    const InnerState = struct {
        counter: Tracked(i32) = .{ .value = 0 },
    };

    var state = Reactive(InnerState).init();

    // Can still access inner directly for read
    try std.testing.expectEqual(@as(i32, 0), state.inner.counter.get());
    try std.testing.expectEqual(@as(u32, 0), state.inner.counter.version());

    // Set via Reactive
    state.set(.counter, 42);

    // Field version is also updated
    try std.testing.expectEqual(@as(u32, 1), state.inner.counter.version());
}

test "Reactive ptr mutation" {
    const Item = struct { x: i32, y: i32 };
    const InnerState = struct {
        item: Tracked(Item) = .{ .value = .{ .x = 0, .y = 0 } },
    };

    var state = Reactive(InnerState).init();

    // Modify via ptr (bumps both versions)
    state.ptr(.item).x = 10;
    try std.testing.expectEqual(@as(i32, 10), state.get(.item).x);
    try std.testing.expectEqual(@as(u64, 1), state.globalVersion());
}
