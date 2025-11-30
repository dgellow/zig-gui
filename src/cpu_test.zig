//! CPU Usage Test - Validates 0% idle CPU claim
//!
//! This test proves the revolutionary architecture works:
//! - Blocks on waitEvent() → 0% CPU
//! - Only wakes when event occurs
//! - Measures actual CPU time vs wall time

const std = @import("std");
const testing = std.testing;
const app_mod = @import("app.zig");
const gui_mod = @import("gui.zig");
const tracked = @import("tracked.zig");
const test_platform_mod = @import("test_platform.zig");

const App = app_mod.App;
const HeadlessPlatform = app_mod.HeadlessPlatform;
const BlockingTestPlatform = test_platform_mod.BlockingTestPlatform;
const Event = app_mod.Event;
const GUI = gui_mod.GUI;
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
    const rusage_before = std.posix.getrusage(0); // 0 = RUSAGE_SELF
    const cpu_before_ns = rusageToNanos(rusage_before);
    const wall_before = std.time.nanoTimestamp();

    // THIS IS THE CRITICAL TEST: waitEvent() should block
    const event = try platform.interface().waitEvent();

    // Measure CPU time AFTER waiting
    const rusage_after = std.posix.getrusage(0); // 0 = RUSAGE_SELF
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
    try testing.expectEqual(app_mod.EventType.input, event.type);

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
    try testing.expectEqual(app_mod.EventType.input, e1.?.type);

    const e2 = platform.interface().pollEvent();
    try testing.expect(e2 != null);
    try testing.expectEqual(app_mod.EventType.redraw_needed, e2.?.type);

    const e3 = platform.interface().pollEvent();
    try testing.expect(e3 != null);
    try testing.expectEqual(app_mod.EventType.redraw_needed, e3.?.type);

    // No more events
    const e4 = platform.interface().pollEvent();
    try testing.expect(e4 == null);

    std.debug.print("\n✅ HeadlessPlatform event injection works correctly\n", .{});
}

const GameState = struct {
    frame_count: Tracked(u32) = .{ .value = 0 },
    health: Tracked(i32) = .{ .value = 100 },
    mana: Tracked(i32) = .{ .value = 50 },
    score: Tracked(u64) = .{ .value = 0 },
};

fn gameUI(gui: *GUI, state: *GameState) !void {
    _ = gui;
    // Simulate typical game HUD rendering
    state.frame_count.set(state.frame_count.get() + 1);

    // Simulate state updates every frame
    if (state.frame_count.get() % 10 == 0) {
        state.health.set(state.health.get() - 1);
        state.mana.set(state.mana.get() + 1);
        state.score.set(state.score.get() + 100);
    }
}

test "game loop mode: <4ms frame time (250 FPS capability)" {
    std.debug.print("\n=== Testing Game Loop Performance ===\n", .{});

    var platform = HeadlessPlatform.init();
    platform.max_frames = 1001; // Run 1000 frames + initial

    var app = try app_mod.App(GameState).init(
        testing.allocator,
        platform.interface(),
        .{ .mode = .game_loop, .target_fps = 250 }, // Target 250 FPS (4ms)
    );
    defer app.deinit();

    var state = GameState{};

    // Measure 1000 frames
    const test_frames: u32 = 1000;
    var frame_times: [1000]i128 = undefined;

    var frame_idx: u32 = 0;
    while (frame_idx < test_frames) : (frame_idx += 1) {
        const frame_start = std.time.nanoTimestamp();

        // Simulate one game loop iteration
        app.processEvents();
        try app.renderFrame(gameUI, &state);

        const frame_end = std.time.nanoTimestamp();
        frame_times[frame_idx] = frame_end - frame_start;
    }

    // Calculate statistics
    var total_time: i128 = 0;
    var max_frame_time: i128 = 0;
    var min_frame_time: i128 = std.math.maxInt(i128);

    for (frame_times) |ft| {
        total_time += ft;
        if (ft > max_frame_time) max_frame_time = ft;
        if (ft < min_frame_time) min_frame_time = ft;
    }

    const avg_frame_time_ns = @divTrunc(total_time, test_frames);
    const avg_frame_time_ms = @as(f64, @floatFromInt(avg_frame_time_ns)) / std.time.ns_per_ms;
    const max_frame_time_ms = @as(f64, @floatFromInt(max_frame_time)) / std.time.ns_per_ms;
    const min_frame_time_ms = @as(f64, @floatFromInt(min_frame_time)) / std.time.ns_per_ms;
    const fps_capability = 1000.0 / avg_frame_time_ms;

    std.debug.print("\nResults ({} frames):\n", .{test_frames});
    std.debug.print("  Avg frame time: {d:.3}ms\n", .{avg_frame_time_ms});
    std.debug.print("  Min frame time: {d:.3}ms\n", .{min_frame_time_ms});
    std.debug.print("  Max frame time: {d:.3}ms\n", .{max_frame_time_ms});
    std.debug.print("  FPS capability: {d:.1}\n", .{fps_capability});

    // Verify design target: <4ms per frame (250 FPS)
    const target_frame_time_ms = 4.0;
    try testing.expect(avg_frame_time_ms < target_frame_time_ms);

    // Verify capable of 120+ FPS minimum
    try testing.expect(fps_capability >= 120.0);

    std.debug.print("\n✅ VERIFIED: Game loop achieves <4ms frame time target!\n", .{});
    std.debug.print("   Average: {d:.3}ms/frame = {d:.0} FPS capability\n", .{ avg_frame_time_ms, fps_capability });
}
