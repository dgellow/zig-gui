//! BlockingTestPlatform - Actually blocks for CPU testing
//!
//! Unlike HeadlessPlatform (deterministic), this platform TRULY blocks
//! on waitEvent() using a condition variable, allowing CPU usage verification.

const std = @import("std");
const app_mod = @import("app.zig");
const PlatformInterface = app_mod.PlatformInterface;
const Event = app_mod.Event;

pub const BlockingTestPlatform = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    event_queue: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    should_quit: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*BlockingTestPlatform {
        const self = try allocator.create(BlockingTestPlatform);
        self.* = .{
            .event_queue = std.ArrayList(Event).init(allocator),
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *BlockingTestPlatform) void {
        self.event_queue.deinit();
        self.allocator.destroy(self);
    }

    /// Get platform interface for passing to App
    pub fn interface(self: *BlockingTestPlatform) PlatformInterface {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Inject event from another thread (thread-safe)
    pub fn injectEvent(self: *BlockingTestPlatform, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.event_queue.append(event) catch return;
        self.cond.signal(); // Wake up waitEvent()
    }

    /// Request platform to quit
    pub fn requestQuit(self: *BlockingTestPlatform) void {
        self.injectEvent(.{ .type = .quit });
    }

    // VTable implementation
    const vtable = PlatformInterface.VTable{
        .waitEvent = waitEventImpl,
        .pollEvent = pollEventImpl,
        .present = presentImpl,
    };

    /// THIS ACTUALLY BLOCKS using condition variable
    fn waitEventImpl(ptr: *anyopaque) !Event {
        const self: *BlockingTestPlatform = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Wait until event available
        while (self.event_queue.items.len == 0) {
            self.cond.wait(&self.mutex);  // ← TRUE BLOCKING - 0% CPU!
        }

        return self.event_queue.orderedRemove(0);
    }

    fn pollEventImpl(ptr: *anyopaque) ?Event {
        const self: *BlockingTestPlatform = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }

        return null;
    }

    fn presentImpl(_: *anyopaque) void {
        // No-op for test platform
    }
};
