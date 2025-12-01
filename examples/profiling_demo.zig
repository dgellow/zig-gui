//! Profiling Demo - Demonstrating Zero-Cost Profiling System
//!
//! This example demonstrates:
//! - Profiling initialization and configuration
//! - Zone-based hierarchical profiling
//! - Frame-based analysis
//! - JSON export for chrome://tracing visualization
//! - Performance statistics
//!
//! Build with profiling ENABLED:
//!   zig build profiling-demo -Denable_profiling=true
//!
//! Build with profiling DISABLED (zero cost):
//!   zig build profiling-demo
//!
//! After running, open profile.json in chrome://tracing

const std = @import("std");
const zig_gui = @import("zig-gui");

const App = zig_gui.App;
const GUI = zig_gui.GUI;
const Tracked = zig_gui.Tracked;
const HeadlessPlatform = zig_gui.HeadlessPlatform;
const profiler = zig_gui.profiler;

/// Application state with typical game HUD data
const GameState = struct {
    // Game stats
    frame_count: Tracked(u32) = .{ .value = 0 },
    fps: Tracked(f32) = .{ .value = 60.0 },

    // Player stats
    health: Tracked(i32) = .{ .value = 100 },
    mana: Tracked(i32) = .{ .value = 50 },
    score: Tracked(u64) = .{ .value = 0 },
    level: Tracked(u32) = .{ .value = 1 },

    // Performance tracking
    last_frame_time: i128 = 0,
};

/// Simulated physics calculation (to show profiling zones)
fn physicsUpdate(dt: f32) void {
    profiler.zone(@src(), "physicsUpdate", .{});
    defer profiler.endZone();

    // Simulate collision detection
    {
        profiler.zone(@src(), "collisionDetection", .{});
        defer profiler.endZone();

        var sum: f32 = 0;
        for (0..100) |i| {
            sum += @as(f32, @floatFromInt(i)) * dt;
        }
        std.mem.doNotOptimizeAway(sum);
    }

    // Simulate physics integration
    {
        profiler.zone(@src(), "physicsIntegration", .{});
        defer profiler.endZone();

        var sum: f32 = 0;
        for (0..50) |i| {
            sum += std.math.sqrt(@as(f32, @floatFromInt(i + 1)));
        }
        std.mem.doNotOptimizeAway(sum);
    }
}

/// Simulated AI processing (to show profiling zones)
fn aiUpdate() void {
    profiler.zone(@src(), "aiUpdate", .{});
    defer profiler.endZone();

    // Simulate pathfinding
    {
        profiler.zone(@src(), "pathfinding", .{});
        defer profiler.endZone();

        var sum: u64 = 0;
        for (0..75) |i| {
            sum +%= i * i;
        }
        std.mem.doNotOptimizeAway(sum);
    }

    // Simulate decision making
    {
        profiler.zone(@src(), "decisionMaking", .{});
        defer profiler.endZone();

        var sum: u32 = 0;
        for (0..30) |i| {
            sum +%= @as(u32, @intCast(i % 256));
        }
        std.mem.doNotOptimizeAway(sum);
    }
}

/// Game HUD UI - demonstrates widget profiling overhead
fn gameHudUI(gui: *GUI, state: *GameState) !void {
    profiler.zone(@src(), "gameHudUI", .{});
    defer profiler.endZone();

    // Title section
    {
        profiler.zone(@src(), "titleSection", .{});
        defer profiler.endZone();
        try gui.text("=== Profiling Demo (Game HUD) ===", .{});
        try gui.text("  Frame: {} | FPS: {d:.1}", .{ state.frame_count.get(), state.fps.get() });
        gui.newLine();
        gui.separator();
    }

    // Player stats section
    {
        profiler.zone(@src(), "playerStatsSection", .{});
        defer profiler.endZone();

        gui.beginContainer(.{ .padding = 12 });
        {
            try gui.text("PLAYER STATS", .{});
            gui.newLine();

            try gui.text("Health:  {}/100", .{state.health.get()});
            gui.newLine();
            try gui.text("Mana:    {}/100", .{state.mana.get()});
            gui.newLine();
            try gui.text("Level:   {}", .{state.level.get()});
            gui.newLine();
            try gui.text("Score:   {}", .{state.score.get()});
            gui.newLine();

            gui.separator();

            // Action buttons
            gui.beginRow();

            gui.button("Heal");
            if (gui.wasClicked("Heal")) {
                state.health.set(@min(100, state.health.get() + 25));
            }

            gui.button("Cast Spell");
            if (gui.wasClicked("Cast Spell")) {
                if (state.mana.get() >= 10) {
                    state.mana.set(state.mana.get() - 10);
                    state.score.set(state.score.get() + 50);
                }
            }

            gui.button("Level Up");
            if (gui.wasClicked("Level Up")) {
                state.level.set(state.level.get() + 1);
                state.health.set(100);
                state.mana.set(100);
            }

            gui.endRow();
        }
        gui.endContainer(.{ .padding = 12 });
    }

    // Profiling info section
    if (profiler.enabled) {
        profiler.zone(@src(), "profilingInfoSection", .{});
        defer profiler.endZone();

        gui.separator();
        const stats = profiler.getFrameStats();
        try gui.text("PROFILING STATS", .{});
        gui.newLine();
        try gui.text("Frames:   {}", .{stats.frame_count});
        gui.newLine();
        try gui.text("Avg FPS:  {d:.1}", .{stats.current_fps});
        gui.newLine();
        try gui.text("Frame MS: {d:.3}ms", .{stats.avg_frame_time_ms});
        gui.newLine();
        try gui.text("Min MS:   {d:.3}ms", .{stats.min_frame_time_ms});
        gui.newLine();
        try gui.text("Max MS:   {d:.3}ms", .{stats.max_frame_time_ms});
        gui.newLine();
    }

    // Exit button
    gui.separator();
    gui.button("Exit & Export Profile");
    if (gui.wasClicked("Exit & Export Profile")) {
        gui.requestExit();
    }

    // Update frame count
    state.frame_count.set(state.frame_count.get() + 1);

    // Auto-regenerate resources
    if (state.frame_count.get() % 60 == 0) {
        state.mana.set(@min(100, state.mana.get() + 5));
    }

    // Calculate FPS
    const now = std.time.nanoTimestamp();
    if (state.last_frame_time != 0) {
        const delta = now - state.last_frame_time;
        const fps = 1_000_000_000.0 / @as(f64, @floatFromInt(delta));
        state.fps.set(@floatCast(fps));
    }
    state.last_frame_time = now;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  zig-gui Profiling & Tracing Demo                               ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    if (profiler.enabled) {
        std.debug.print("✅ Profiling ENABLED\n", .{});
        std.debug.print("   • Zone-based hierarchical profiling\n", .{});
        std.debug.print("   • Frame-based analysis\n", .{});
        std.debug.print("   • ~15-50ns overhead per zone\n", .{});
        std.debug.print("   • JSON export for chrome://tracing\n", .{});
    } else {
        std.debug.print("🚫 Profiling DISABLED (zero cost)\n", .{});
        std.debug.print("   • All profiling code optimized away\n", .{});
        std.debug.print("   • Zero runtime overhead\n", .{});
        std.debug.print("   • Zero binary size increase\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("   To enable profiling:\n", .{});
        std.debug.print("   zig build profiling-demo -Denable_profiling=true\n", .{});
    }
    std.debug.print("\n", .{});

    // Initialize profiler (does nothing if disabled)
    try profiler.init(allocator, .{
        .max_zones_per_frame = 10_000,
        .max_frames_in_history = 600,
        .auto_export_on_exit = false,
    });
    defer profiler.deinit();

    // Create platform
    var platform = HeadlessPlatform.init();
    platform.max_frames = 100; // Run 100 frames for demo

    // Create app in game loop mode
    var app = try App(GameState).init(
        allocator,
        platform.interface(),
        .{
            .mode = .game_loop,
            .target_fps = 1000, // Run as fast as possible for demo
        },
    );
    defer app.deinit();

    // Game state
    var state = GameState{};

    std.debug.print("Running game loop for 100 frames...\n", .{});
    std.debug.print("(Simulating physics, AI, and HUD rendering)\n\n", .{});

    // Custom game loop with profiling zones
    const loop_start = std.time.milliTimestamp();

    while (app.isRunning()) {
        profiler.frameStart();
        defer profiler.frameEnd();

        // Process events
        app.processEvents();

        // Simulate game systems
        {
            profiler.zone(@src(), "gameSystems", .{});
            defer profiler.endZone();

            physicsUpdate(0.016); // ~60 FPS delta
            aiUpdate();
        }

        // Render UI
        try app.renderFrame(gameHudUI, &state);
    }

    const loop_end = std.time.milliTimestamp();
    const elapsed_ms = loop_end - loop_start;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Results                                                         ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Frames rendered: {}\n", .{state.frame_count.get()});
    std.debug.print("Elapsed time:    {}ms\n", .{elapsed_ms});
    std.debug.print("Average FPS:     {d:.1}\n", .{@as(f64, @floatFromInt(state.frame_count.get())) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)});

    if (profiler.enabled) {
        std.debug.print("\n", .{});
        const stats = profiler.getFrameStats();
        std.debug.print("Profiling Statistics:\n", .{});
        std.debug.print("  Total frames:     {}\n", .{stats.frame_count});
        std.debug.print("  Avg frame time:   {d:.3}ms\n", .{stats.avg_frame_time_ms});
        std.debug.print("  Min frame time:   {d:.3}ms\n", .{stats.min_frame_time_ms});
        std.debug.print("  Max frame time:   {d:.3}ms\n", .{stats.max_frame_time_ms});
        std.debug.print("  Avg FPS:          {d:.1}\n", .{stats.current_fps});

        // Export profiling data
        std.debug.print("\n", .{});
        std.debug.print("Exporting profiling data...\n", .{});
        try profiler.exportJSON("profile.json");

        std.debug.print("✅ Exported to profile.json\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("To visualize:\n", .{});
        std.debug.print("  1. Open Chrome/Chromium\n", .{});
        std.debug.print("  2. Navigate to chrome://tracing\n", .{});
        std.debug.print("  3. Click 'Load' and select profile.json\n", .{});
        std.debug.print("  4. Explore the hierarchical timeline!\n", .{});
    }

    std.debug.print("\n", .{});
    std.debug.print("Final game state:\n", .{});
    std.debug.print("  Level:  {}\n", .{state.level.get()});
    std.debug.print("  Score:  {}\n", .{state.score.get()});
    std.debug.print("  Health: {}/100\n", .{state.health.get()});
    std.debug.print("  Mana:   {}/100\n", .{state.mana.get()});
    std.debug.print("\n", .{});
}
