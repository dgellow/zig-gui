const std = @import("std");
const Color = @import("core/color.zig").Color;
const Point = @import("core/geometry.zig").Point;
const Rect = @import("core/geometry.zig").Rect;

/// Value types that can be animated
pub const ValueType = enum {
    float,
    integer,
    color,
    point,
    rect,
};

/// Union that can hold any animatable value
pub const ValueUnion = union(ValueType) {
    float: f32,
    integer: i32,
    color: Color,
    point: Point,
    rect: Rect,

    /// Interpolate between this value and another
    pub fn interpolate(self: ValueUnion, other: ValueUnion, t: f32) ValueUnion {
        switch (self) {
            .float => |start| {
                if (other != .float) return self;
                return ValueUnion{ .float = start + (other.float - start) * t };
            },
            .integer => |start| {
                if (other != .integer) return self;
                const end = other.integer;
                return ValueUnion{ .integer = start + @as(i32, @as(f32, end - start) * t) };
            },
            .color => |start| {
                if (other != .color) return self;
                const end = other.color;
                return ValueUnion{ .color = Color{
                    .r = @intFromFloat(@as(f32, start.r) + @as(f32, end.r - start.r) * t),
                    .g = @intFromFloat(@as(f32, start.g) + @as(f32, end.g - start.g) * t),
                    .b = @intFromFloat(@as(f32, start.b) + @as(f32, end.b - start.b) * t),
                    .a = @intFromFloat(@as(f32, start.a) + @as(f32, end.a - start.a) * t),
                } };
            },
            .point => |start| {
                if (other != .point) return self;
                const end = other.point;
                return ValueUnion{ .point = Point{
                    .x = start.x + (end.x - start.x) * t,
                    .y = start.y + (end.y - start.y) * t,
                } };
            },
            .rect => |start| {
                if (other != .rect) return self;
                const end = other.rect;
                return ValueUnion{ .rect = Rect{
                    .x = start.x + (end.x - start.x) * t,
                    .y = start.y + (end.y - start.y) * t,
                    .width = start.width + (end.width - start.width) * t,
                    .height = start.height + (end.height - start.height) * t,
                } };
            },
        }
    }
};

/// Animation object representing a single property animation
pub const Animation = struct {
    property: []const u8,
    target: *anyopaque,
    setter: *const fn (*anyopaque, []const u8, ValueUnion) void,
    getter: *const fn (*anyopaque, []const u8) ValueUnion,

    start_value: ValueUnion,
    end_value: ValueUnion,
    value_type: ValueType,

    duration: f32,
    current_time: f32 = 0,
    easing_function: *const fn (f32) f32 = linearEasing,
    on_complete: ?*const fn (*Animation) void = null,

    // For object pooling
    next_in_pool: ?*Animation = null,

    /// Check if animation is complete
    pub fn isComplete(self: *Animation) bool {
        return self.current_time >= self.duration;
    }

    /// Advance animation by time delta
    pub fn advance(self: *Animation, dt: f32) void {
        self.current_time += dt;

        // Clamp time to duration
        if (self.current_time > self.duration) {
            self.current_time = self.duration;
        }

        // Calculate progress (0.0 to 1.0)
        const progress = self.current_time / self.duration;

        // Apply easing function
        const eased_progress = self.easing_function(progress);

        // Interpolate between start and end values
        const current_value = self.start_value.interpolate(self.end_value, eased_progress);

        // Apply to target property
        self.setter(self.target, self.property, current_value);

        // Call completion callback if animation just finished
        if (self.isComplete() and self.on_complete != null) {
            self.on_complete.?(self);
        }
    }

    /// Set completion callback
    pub fn onComplete(self: *Animation, callback: fn (*Animation) void) *Animation {
        self.on_complete = callback;
        return self;
    }

    /// Set easing function
    pub fn withEasing(self: *Animation, easing: fn (f32) f32) *Animation {
        self.easing_function = easing;
        return self;
    }

    /// Reset animation for reuse from pool
    fn reset(self: *Animation) void {
        self.current_time = 0;
        self.on_complete = null;
        self.easing_function = linearEasing;
        self.next_in_pool = null;
    }
};

/// Animation system for handling property animations
pub const AnimationSystem = struct {
    allocator: std.mem.Allocator,

    running_animations: std.ArrayList(*Animation),
    free_pool_head: ?*Animation = null, // Linked list of free animations
    total_created: usize = 0,

    /// Initialize animation system
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*AnimationSystem {
        const system = try allocator.create(AnimationSystem);
        system.* = .{
            .allocator = allocator,
            .running_animations = std.ArrayList(*Animation).init(allocator),
        };

        // Pre-allocate animation capacity
        try system.running_animations.ensureTotalCapacity(capacity);

        return system;
    }

    /// Free resources used by animation system
    pub fn deinit(self: *AnimationSystem) void {
        // Free all running animations
        for (self.running_animations.items) |animation| {
            self.allocator.destroy(animation);
        }
        self.running_animations.deinit();

        // Free all animations in pool
        var current = self.free_pool_head;
        while (current) |animation| {
            const next = animation.next_in_pool;
            self.allocator.destroy(animation);
            current = next;
        }

        // Free self
        self.allocator.destroy(self);
    }

    /// Get an animation from the pool or create a new one
    fn getAnimation(self: *AnimationSystem) !*Animation {
        // Check if we have a free animation in the pool
        if (self.free_pool_head) |animation| {
            // Remove from pool
            self.free_pool_head = animation.next_in_pool;
            animation.reset();
            return animation;
        }

        // Create a new animation
        const animation = try self.allocator.create(Animation);
        self.total_created += 1;
        return animation;
    }

    /// Return an animation to the pool
    fn returnToPool(self: *AnimationSystem, animation: *Animation) void {
        animation.reset();
        animation.next_in_pool = self.free_pool_head;
        self.free_pool_head = animation;
    }

    /// Animate a property with easing over time
    pub fn animate(self: *AnimationSystem, target: *anyopaque, property: []const u8, end_value: anytype, duration_ms: u32, setter: fn (*anyopaque, []const u8, ValueUnion) void, getter: fn (*anyopaque, []const u8) ValueUnion) !*Animation {
        // Get the current value
        const start_value = getter(target, property);

        // Convert end value to ValueUnion
        const T = @TypeOf(end_value);
        const value_type = switch (@typeInfo(T)) {
            .Float => ValueType.float,
            .Int => ValueType.integer,
            .Struct => blk: {
                if (T == Color) break :blk ValueType.color;
                if (T == Point) break :blk ValueType.point;
                if (T == Rect) break :blk ValueType.rect;
                @compileError("Unsupported type for animation: " ++ @typeName(T));
            },
            else => @compileError("Unsupported type for animation: " ++ @typeName(T)),
        };

        // Create ValueUnion for end value
        const end_value_union = switch (value_type) {
            .float => ValueUnion{ .float = @floatCast(end_value) },
            .integer => ValueUnion{ .integer = @intCast(end_value) },
            .color => ValueUnion{ .color = end_value },
            .point => ValueUnion{ .point = end_value },
            .rect => ValueUnion{ .rect = end_value },
        };

        // Get animation from pool
        const animation = try self.getAnimation();

        // Configure the animation
        animation.* = .{
            .property = property,
            .target = target,
            .setter = setter,
            .getter = getter,
            .start_value = start_value,
            .end_value = end_value_union,
            .value_type = value_type,
            .duration = @as(f32, duration_ms) / 1000.0, // Convert ms to seconds
            .current_time = 0,
            .easing_function = linearEasing,
            .on_complete = null,
            .next_in_pool = null,
        };

        // Add to running animations
        try self.running_animations.append(animation);

        return animation;
    }

    /// Update all running animations
    pub fn update(self: *AnimationSystem, dt: f32) void {
        var i: usize = 0;
        while (i < self.running_animations.items.len) {
            const animation = self.running_animations.items[i];

            animation.advance(dt);

            if (animation.isComplete()) {
                // Remove from running list
                _ = self.running_animations.swapRemove(i);

                // Return to pool
                self.returnToPool(animation);
            } else {
                i += 1;
            }
        }
    }

    /// Stop all animations targeting a specific object
    pub fn stopAnimations(self: *AnimationSystem, target: *anyopaque) void {
        var i: usize = 0;
        while (i < self.running_animations.items.len) {
            const animation = self.running_animations.items[i];

            if (animation.target == target) {
                // Remove from running list
                _ = self.running_animations.swapRemove(i);

                // Return to pool
                self.returnToPool(animation);
            } else {
                i += 1;
            }
        }
    }

    /// Stop a specific animation
    pub fn stopAnimation(self: *AnimationSystem, animation: *Animation) void {
        for (self.running_animations.items, 0..) |anim, i| {
            if (anim == animation) {
                // Remove from running list
                _ = self.running_animations.swapRemove(i);

                // Return to pool
                self.returnToPool(animation);
                return;
            }
        }
    }
};

//
// Easing functions
//

/// Linear easing (no easing)
pub fn linearEasing(t: f32) f32 {
    return t;
}

/// Quadratic ease in
pub fn easeInQuad(t: f32) f32 {
    return t * t;
}

/// Quadratic ease out
pub fn easeOutQuad(t: f32) f32 {
    return t * (2 - t);
}

/// Quadratic ease in-out
pub fn easeInOutQuad(t: f32) f32 {
    return if (t < 0.5) 2 * t * t else -1 + (4 - 2 * t) * t;
}

/// Cubic ease in
pub fn easeInCubic(t: f32) f32 {
    return t * t * t;
}

/// Cubic ease out
pub fn easeOutCubic(t: f32) f32 {
    const t1 = t - 1;
    return t1 * t1 * t1 + 1;
}

/// Cubic ease in-out
pub fn easeInOutCubic(t: f32) f32 {
    if (t < 0.5) {
        return 4 * t * t * t;
    } else {
        const t1 = (t - 1);
        return 0.5 * t1 * t1 * t1 + 1;
    }
}

/// Elastic ease out
pub fn easeOutElastic(t: f32) f32 {
    const p: f32 = 0.3;
    return @exp(-10 * t) * @sin((t - p / 4) * (2 * std.math.pi) / p) + 1;
}

/// Bounce ease out
pub fn easeOutBounce(t: f32) f32 {
    if (t < 1 / 2.75) {
        return 7.5625 * t * t;
    } else if (t < 2 / 2.75) {
        const t1 = t - 1.5 / 2.75;
        return 7.5625 * t1 * t1 + 0.75;
    } else if (t < 2.5 / 2.75) {
        const t1 = t - 2.25 / 2.75;
        return 7.5625 * t1 * t1 + 0.9375;
    } else {
        const t1 = t - 2.625 / 2.75;
        return 7.5625 * t1 * t1 + 0.984375;
    }
}
