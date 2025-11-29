//! CPU Usage Test - Validates 0% idle CPU claim
//!
//! This test proves the revolutionary architecture works:
//! - Blocks on waitEvent() → 0% CPU
//! - Only wakes when event occurs
//! - Measures actual CPU time vs wall time

const std = @import("std");
const testing = std.testing;
const app_mod = @import("app.zig");
const tracked = @import("tracked.zig");
const test_platform_mod = @import("test_platform.zig");

const App = app_mod.App;
const HeadlessPlatform = app_mod.HeadlessPlatform;
const BlockingTestPlatform = test_platform_mod.BlockingTestPlatform;
const Event = app_mod.Event;
const Tracked = tracked.Tracked;

/// Convert rusage to nanoseconds (user + system time)
fn rusageToNanos(rusage: std.posix.rusage) i64 {
    const user_ns = @as(i64, rusage.utime.tv_sec) * std.time.ns_per_s +
                    @as(i64, rusage.utime.tv_usec) * std.time.ns_per_us;
    const sys_ns = @as(i64, rusage.stime.tv_sec) * std.time.ns_per_s +
                   @as(i64, rusage.stime.tv_usec) * std.time.ns_per_us;
    return user_ns + sys_ns;
}

/// Background thread that injects event after delay
const DelayedEventInjector = struct {
    platform: *BlockingTestPlatform,
    delay_ms: u64,

    fn run(self: *const DelayedEventInjector) void {
        std.time.sleep(self.delay_ms * std.time.ns_per_ms);
        self.platform.injectEvent(.{ .type = .input, .timestamp = 0 });
    }
};

test "event-driven mode: 0% CPU when idle (blocking verification)" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) {
        // getrusage only on POSIX systems
        std.debug.print("Skipping CPU test - requires Linux/macOS\n", .{});
        return error.SkipZigTest;
    }

    std.debug.print("\n=== Testing Revolutionary 0% Idle CPU Architecture ===\n", .{});

    var platform = try BlockingTestPlatform.init(testing.allocator);
    defer platform.deinit();

    // Spawn thread to inject event after 100ms
    const injector = DelayedEventInjector{
        .platform = platform,
        .delay_ms = 100,
    };

    const thread = try std.Thread.spawn(.{}, DelayedEventInjector.run, .{&injector});
    defer thread.join();

    // Measure CPU time BEFORE waiting
    const rusage_before = try std.posix.getrusage(std.posix.rusage.SELF);
    const cpu_before_ns = rusageToNanos(rusage_before);
    const wall_before = std.time.nanoTimestamp();

    // THIS IS THE CRITICAL TEST: waitEvent() should block
    const event = try platform.interface().waitEvent();

    // Measure CPU time AFTER waiting
    const rusage_after = try std.posix.getrusage(std.posix.rusage.SELF);
    const cpu_after_ns = rusageToNanos(rusage_after);
    const wall_after = std.time.nanoTimestamp();

    // Calculate deltas
    const cpu_delta_ns = cpu_after_ns - cpu_before_ns;
    const wall_delta_ns = wall_after - wall_before;
    const wall_delta_ms = @divTrunc(wall_delta_ns, std.time.ns_per_ms);

    // Calculate CPU usage percentage
    const cpu_percent = (@as(f64, @floatFromInt(cpu_delta_ns)) /
                        @as(f64, @floatFromInt(wall_delta_ns))) * 100.0;

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Wall time: {}ms\n", .{wall_delta_ms});
    std.debug.print("  CPU time:  {d:.3}ms\n", .{@as(f64, @floatFromInt(cpu_delta_ns)) / std.time.ns_per_ms});
    std.debug.print("  CPU usage: {d:.6}%\n", .{cpu_percent});

    // Verify event was received
    try testing.expectEqual(Event.EventType.input, event.type);

    // Verify we actually waited ~100ms wall time
    try testing.expect(wall_delta_ms >= 90); // At least 90ms (accounting for scheduling jitter)
    try testing.expect(wall_delta_ms <= 200); // But not too long

    // THE REVOLUTIONARY CLAIM: CPU usage should be near 0%
    // Allow up to 5% to account for:
    // - Thread scheduling overhead
    // - Test harness overhead
    // - Event injection overhead
    try testing.expect(cpu_percent < 5.0);

    std.debug.print("\n✅ VERIFIED: Event-driven mode achieves near-0% idle CPU!\n", .{});
    std.debug.print("   While blocked for {}ms, used only {d:.6}% CPU\n", .{wall_delta_ms, cpu_percent});
}

test "state version change detection prevents unnecessary renders" {
    const TestState = struct {
        counter: Tracked(i32) = .{ .value = 0 },
        name: Tracked([]const u8) = .{ .value = "test" },
    };

    var state = TestState{};
    var last_version: u64 = 0;

    // Initial version
    const v1 = tracked.computeStateVersion(&state);
    try testing.expect(!tracked.stateChanged(&state, &last_version));

    // Change counter → version should change
    state.counter.set(42);
    const v2 = tracked.computeStateVersion(&state);
    try testing.expect(v2 != v1);
    try testing.expect(tracked.stateChanged(&state, &last_version));

    // No change → version should stay same
    try testing.expect(!tracked.stateChanged(&state, &last_version));

    // Change name → version should change again
    state.name.set("changed");
    try testing.expect(tracked.stateChanged(&state, &last_version));

    std.debug.print("\n✅ State version tracking correctly detects changes\n", .{});
}

test "HeadlessPlatform supports event injection for testing" {
    var platform = HeadlessPlatform.init();

    // Inject test events
    platform.injectEvent(.{ .type = .input, .timestamp = 100 });
    platform.injectEvent(.{ .type = .redraw_needed, .timestamp = 200 });
    platform.injectRedraw();

    // Poll events
    const e1 = platform.interface().pollEvent();
    try testing.expect(e1 != null);
    try testing.expectEqual(Event.EventType.input, e1.?.type);

    const e2 = platform.interface().pollEvent();
    try testing.expect(e2 != null);
    try testing.expectEqual(Event.EventType.redraw_needed, e2.?.type);

    const e3 = platform.interface().pollEvent();
    try testing.expect(e3 != null);
    try testing.expectEqual(Event.EventType.redraw_needed, e3.?.type);

    // No more events
    const e4 = platform.interface().pollEvent();
    try testing.expect(e4 == null);

    std.debug.print("\n✅ HeadlessPlatform event injection works correctly\n", .{});
}
