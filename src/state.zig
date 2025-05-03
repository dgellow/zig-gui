const std = @import("std");
const View = @import("components/view.zig").View;

/// A type-erased value that can store any type
pub const StateValue = struct {
    data: *anyopaque,
    type_id: std.builtin.TypeId,

    deinit_fn: *const fn (*anyopaque) void,
    clone_fn: *const fn (*anyopaque) *anyopaque,
    equal_fn: *const fn (*anyopaque, *anyopaque) bool,

    /// Create a new StateValue from a value of any type
    pub fn init(allocator: std.mem.Allocator, value: anytype) !StateValue {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        // Create a copy of the value
        const ptr = try allocator.create(T);
        ptr.* = value;

        return StateValue{
            .data = ptr,
            .type_id = type_info,
            .deinit_fn = struct {
                fn deinit(data: *anyopaque) void {
                    const typed_ptr: *T = @ptrCast(@alignCast(data));
                    allocator.destroy(typed_ptr);
                }
            }.deinit,
            .clone_fn = struct {
                fn clone(data: *anyopaque) *anyopaque {
                    const typed_ptr: *T = @ptrCast(@alignCast(data));
                    const new_ptr = allocator.create(T) catch unreachable;
                    new_ptr.* = typed_ptr.*;
                    return new_ptr;
                }
            }.clone,
            .equal_fn = struct {
                fn equal(a: *anyopaque, b: *anyopaque) bool {
                    const typed_a: *T = @ptrCast(@alignCast(a));
                    const typed_b: *T = @ptrCast(@alignCast(b));
                    return typed_a.* == typed_b.*;
                }
            }.equal,
        };
    }

    /// Free resources used by this StateValue
    pub fn deinit(self: *StateValue) void {
        self.deinit_fn(self.data);
    }

    /// Create a deep copy of this StateValue
    pub fn clone(self: *const StateValue) StateValue {
        return StateValue{
            .data = self.clone_fn(self.data),
            .type_id = self.type_id,
            .deinit_fn = self.deinit_fn,
            .clone_fn = self.clone_fn,
            .equal_fn = self.equal_fn,
        };
    }

    /// Check if two StateValues are equal
    pub fn equal(self: *const StateValue, other: *const StateValue) bool {
        if (self.type_id != other.type_id) return false;
        return self.equal_fn(self.data, other.data);
    }

    /// Get the value as a specific type
    pub fn get(self: *const StateValue, comptime T: type) ?T {
        const type_info = @typeInfo(T);
        if (self.type_id != type_info) return null;

        const typed_ptr: *T = @ptrCast(@alignCast(self.data));
        return typed_ptr.*;
    }
};

/// Callback for observing state changes
pub const StateObserver = struct {
    callback: *const fn (*anyopaque, *const StateValue) void,
    context: *anyopaque,
};

/// Type-safe handle for accessing state
pub fn StateHandle(comptime T: type) type {
    return struct {
        store: *StateStore,
        key: []const u8,

        const Self = @This();

        /// Get the current value, or null if type mismatch
        pub fn get(self: *const Self) ?T {
            return self.store.get(T, self.key);
        }

        /// Update the value
        pub fn set(self: *Self, value: T) !void {
            try self.store.set(self.key, value);
        }

        /// Register an observer for changes to this state
        pub fn observe(self: *Self, callback: fn (*anyopaque, T) void, context: *anyopaque) !void {
            const wrapper = struct {
                original_callback: *const fn (*anyopaque, T) void,
                original_context: *anyopaque,

                fn wrappedCallback(ctx: *anyopaque, value: *const StateValue) void {
                    const this: *@This() = @ptrCast(@alignCast(ctx));
                    if (value.get(T)) |typed_value| {
                        this.original_callback(this.original_context, typed_value);
                    }
                }
            }{
                .original_callback = callback,
                .original_context = context,
            };

            const observer = StateObserver{
                .callback = wrapper.wrappedCallback,
                .context = &wrapper,
            };

            try self.store.addObserver(self.key, observer);
        }

        /// Clean up resources used by this handle
        pub fn deinit(self: *Self) void {
            self.store.allocator.free(self.key);
        }
    };
}

/// Component-local state management
pub const ComponentState = struct {
    allocator: std.mem.Allocator,
    component_id: u64,
    states: std.ArrayList(StateValue),
    effects: std.ArrayList(Effect),

    /// Create a new ComponentState for a component
    pub fn init(allocator: std.mem.Allocator, component_id: u64) !*ComponentState {
        const state = try allocator.create(ComponentState);
        state.* = .{
            .allocator = allocator,
            .component_id = component_id,
            .states = std.ArrayList(StateValue).init(allocator),
            .effects = std.ArrayList(Effect).init(allocator),
        };
        return state;
    }

    /// Free resources used by this ComponentState
    pub fn deinit(self: *ComponentState) void {
        // Clean up all states
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.deinit();

        // Run cleanup functions for effects
        for (self.effects.items) |*effect| {
            if (effect.cleanup) |cleanup| {
                cleanup();
            }
        }
        self.effects.deinit();

        self.allocator.destroy(self);
    }

    /// Create or retrieve component-local state (similar to React useState)
    pub fn useState(self: *ComponentState, comptime T: type, initial_value: T) !*T {
        const state_index = self.states.items.len;

        // If this is a new state hook, initialize it
        if (state_index >= self.states.items.len) {
            const state_value = try StateValue.init(self.allocator, initial_value);
            try self.states.append(state_value);
        }

        // Return a pointer to the state value
        const state_value = &self.states.items[state_index];
        return @ptrCast(@alignCast(state_value.data));
    }

    /// Register a side effect (similar to React useEffect)
    pub fn useEffect(self: *ComponentState, deps: anytype, callback: fn () ?fn () void) !void {
        const effect_index = self.effects.items.len;

        // If this is a new effect hook, initialize it
        if (effect_index >= self.effects.items.len) {
            try self.effects.append(.{
                .dependencies = try self.hashDependencies(deps),
                .cleanup = null,
            });
        }

        const effect = &self.effects.items[effect_index];
        const new_deps_hash = try self.hashDependencies(deps);

        // Run effect if dependencies changed
        if (effect.dependencies != new_deps_hash) {
            // Run cleanup if exists
            if (effect.cleanup) |cleanup| {
                cleanup();
            }

            // Run the effect and store any cleanup function
            effect.cleanup = callback();
            effect.dependencies = new_deps_hash;
        }
    }

    // Helper to create a hash of dependencies
    fn hashDependencies(self: *ComponentState, deps: anytype) !u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Get tuple elements and hash each one
        inline for (std.meta.fields(@TypeOf(deps))) |field| {
            if (@typeInfo(@TypeOf(@field(deps, field.name))) == .Pointer) {
                // Hash pointer address if it's a pointer
                std.hash.autoHash(&hasher, @intFromPtr(@field(deps, field.name)));
            } else {
                // Otherwise hash the value
                std.hash.autoHash(&hasher, @field(deps, field.name));
            }
        }

        _ = self; // unused
        return hasher.final();
    }

    const Effect = struct {
        dependencies: u64,
        cleanup: ?*const fn () void,
    };
};

/// Central store for managing application state
pub const StateStore = struct {
    allocator: std.mem.Allocator,

    global_store: std.StringHashMap(StateValue),
    local_stores: std.AutoHashMap(u64, *ComponentState),
    observers: std.StringHashMap(std.ArrayList(StateObserver)),

    /// Initialize the state store
    pub fn init(allocator: std.mem.Allocator) !*StateStore {
        const store = try allocator.create(StateStore);
        store.* = .{
            .allocator = allocator,
            .global_store = std.StringHashMap(StateValue).init(allocator),
            .local_stores = std.AutoHashMap(u64, *ComponentState).init(allocator),
            .observers = std.StringHashMap(std.ArrayList(StateObserver)).init(allocator),
        };
        return store;
    }

    /// Free all resources used by the state store
    pub fn deinit(self: *StateStore) void {
        // Clean up global state values
        var global_it = self.global_store.valueIterator();
        while (global_it.next()) |state_value| {
            state_value.deinit();
        }
        self.global_store.deinit();

        // Clean up local component states
        var local_it = self.local_stores.valueIterator();
        while (local_it.next()) |component_state| {
            component_state.*.deinit();
        }
        self.local_stores.deinit();

        // Clean up observers
        var observers_it = self.observers.valueIterator();
        while (observers_it.next()) |observer_list| {
            observer_list.deinit();
        }
        self.observers.deinit();

        self.allocator.destroy(self);
    }

    /// Create a new type-safe state handle
    pub fn createState(self: *StateStore, comptime T: type, key: []const u8, initial_value: T) !StateHandle(T) {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        // Check if state already exists
        if (!self.global_store.contains(key)) {
            const state_value = try StateValue.init(self.allocator, initial_value);
            try self.global_store.put(key_copy, state_value);
        }

        return StateHandle(T){
            .store = self,
            .key = key_copy,
        };
    }

    /// Get a state value with type safety
    pub fn get(self: *StateStore, comptime T: type, key: []const u8) ?T {
        if (self.global_store.get(key)) |state_value| {
            return state_value.get(T);
        }
        return null;
    }

    /// Set a state value with type safety
    pub fn set(self: *StateStore, key: []const u8, value: anytype) !void {
        const new_state = try StateValue.init(self.allocator, value);
        errdefer new_state.deinit();

        // If key exists, free old value
        if (self.global_store.getPtr(key)) |existing_state| {
            const changed = !existing_state.equal(&new_state);
            existing_state.deinit();
            existing_state.* = new_state;

            // Notify observers if value changed
            if (changed) {
                try self.notifyObservers(key);
            }
        } else {
            // Add new key
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);

            try self.global_store.put(key_copy, new_state);
            try self.notifyObservers(key);
        }
    }

    /// Get or create component-local state
    pub fn getComponentState(self: *StateStore, component_id: u64) !*ComponentState {
        const result = try self.local_stores.getOrPut(component_id);
        if (!result.found_existing) {
            result.value_ptr.* = try ComponentState.init(self.allocator, component_id);
        }
        return result.value_ptr.*;
    }

    /// Add an observer for a state key
    pub fn addObserver(self: *StateStore, key: []const u8, observer: StateObserver) !void {
        var observers_entry = try self.observers.getOrPut(key);
        if (!observers_entry.found_existing) {
            observers_entry.value_ptr.* = std.ArrayList(StateObserver).init(self.allocator);
        }

        try observers_entry.value_ptr.append(observer);
    }

    /// Remove an observer for a state key
    pub fn removeObserver(self: *StateStore, key: []const u8, context: *anyopaque) void {
        if (self.observers.getPtr(key)) |observers| {
            var i: usize = 0;
            while (i < observers.items.len) {
                if (observers.items[i].context == context) {
                    _ = observers.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Notify all observers for a state key
    fn notifyObservers(self: *StateStore, key: []const u8) !void {
        if (self.observers.get(key)) |observers| {
            if (self.global_store.get(key)) |state_value| {
                for (observers.items) |observer| {
                    observer.callback(observer.context, &state_value);
                }
            }
        }
    }
};

/// Function for binding a state to a component property
pub fn bind(view: *View, property: []const u8, state_handle: anytype, transform_fn: anytype) !void {
    const T = @typeInfo(@TypeOf(state_handle)).Pointer.child.T;

    const binding_context = try state_handle.store.allocator.create(BindingContext(T, @TypeOf(transform_fn)));
    binding_context.* = .{
        .view = view,
        .property = try state_handle.store.allocator.dupe(u8, property),
        .transform_fn = transform_fn,
    };

    try state_handle.observe(BindingContext(T, @TypeOf(transform_fn)).updateProperty, binding_context);

    // Initial update with current value
    if (state_handle.get()) |value| {
        binding_context.updateProperty(binding_context, value);
    }
}

/// Context for property binding
fn BindingContext(comptime T: type, comptime TransformFn: type) type {
    return struct {
        view: *View,
        property: []const u8,
        transform_fn: TransformFn,

        const Self = @This();

        fn updateProperty(context: *anyopaque, value: T) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const transformed = self.transform_fn(value);

            // Call setProperty on the view if available
            // This would be implemented in the component.zig
            if (@hasDecl(View, "setProperty")) {
                self.view.setProperty(self.property, transformed);
            }
        }

        fn deinit(self: *Self) void {
            const allocator = self.view.allocator;
            allocator.free(self.property);
            allocator.destroy(self);
        }
    };
}
