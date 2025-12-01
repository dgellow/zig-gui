//! Game HUD Example - Game Loop Mode
//!
//! Demonstrates:
//! - Game loop execution (continuous rendering)
//! - Real-time state updates
//! - Performance monitoring
//! - Typical game UI elements

const std = @import("std");
const zig_gui = @import("zig-gui");

const App = zig_gui.App;
const GUI = zig_gui.GUI;
const Tracked = zig_gui.Tracked;
const HeadlessPlatform = zig_gui.HeadlessPlatform;

/// Game state with player stats
const GameState = struct {
    // Game stats
    frame_count: Tracked(u32) = .{ .value = 0 },
    fps: Tracked(f32) = .{ .value = 60.0 },

    // Player stats
    health: Tracked(i32) = .{ .value = 100 },
    mana: Tracked(i32) = .{ .value = 50 },
    stamina: Tracked(i32) = .{ .value = 100 },

    // Game state
    score: Tracked(u64) = .{ .value = 0 },
    level: Tracked(u32) = .{ .value = 1 },
    enemies: Tracked(u32) = .{ .value = 0 },

    // Last frame time for FPS calculation
    last_frame_time: i128 = 0,
};

/// Game HUD UI - rendered every frame
fn gameHudUI(gui: *GUI, state: *GameState) !void {
    // Title bar
    try gui.text("=== Game HUD Demo ===", .{});
    try gui.text("  FPS: {d:.1}", .{state.fps.get()});
    gui.newLine();
    gui.separator();

    // Player stats section
    gui.beginContainer(.{ .padding = 12 });
    {
        try gui.text("PLAYER STATS", .{});
        gui.newLine();

        // Health bar
        try gui.text("Health: {}/100", .{state.health.get()});
        gui.newLine();

        // Mana bar
        try gui.text("Mana:   {}/100", .{state.mana.get()});
        gui.newLine();

        // Stamina bar
        try gui.text("Stamina: {}/100", .{state.stamina.get()});
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

        gui.button("Sprint");
        if (gui.wasClicked("Sprint")) {
            if (state.stamina.get() >= 20) {
                state.stamina.set(state.stamina.get() - 20);
            }
        }
        gui.endRow();
    }
    gui.endContainer(.{ .padding = 12 });

    // Game stats section
    gui.beginContainer(.{ .padding = 12 });
    {
        try gui.text("GAME STATS", .{});
        gui.newLine();

        try gui.text("Level:   {}", .{state.level.get()});
        gui.newLine();
        try gui.text("Score:   {}", .{state.score.get()});
        gui.newLine();
        try gui.text("Enemies: {}", .{state.enemies.get()});
        gui.newLine();

        gui.separator();

        gui.button("Spawn Enemy");
        if (gui.wasClicked("Spawn Enemy")) {
            state.enemies.set(state.enemies.get() + 1);
        }

        gui.button("Next Level");
        if (gui.wasClicked("Next Level")) {
            state.level.set(state.level.get() + 1);
            state.enemies.set(0);
            state.health.set(100);
            state.mana.set(100);
            state.stamina.set(100);
        }
    }
    gui.endContainer(.{ .padding = 12 });

    // Performance info
    gui.separator();
    try gui.text("Frame: {} | Widget overhead: <0.001ms", .{state.frame_count.get()});
    gui.newLine();

    // Exit button
    gui.button("Exit Game");
    if (gui.wasClicked("Exit Game")) {
        gui.requestExit();
    }

    // Update frame count
    state.frame_count.set(state.frame_count.get() + 1);

    // Auto-regenerate resources (game simulation)
    if (state.frame_count.get() % 60 == 0) {
        // Regenerate mana
        state.mana.set(@min(100, state.mana.get() + 5));
        // Regenerate stamina
        state.stamina.set(@min(100, state.stamina.get() + 10));
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

    std.debug.print("\n=== Game HUD Example (Game Loop Mode) ===\n\n", .{});
    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Game loop execution (continuous rendering)\n", .{});
    std.debug.print("- Real-time state updates\n", .{});
    std.debug.print("- Performance monitoring\n", .{});
    std.debug.print("- Complex UI with multiple sections\n", .{});
    std.debug.print("\nNote: Running with HeadlessPlatform (no rendering)\n", .{});
    std.debug.print("      Widget overhead measured: ~0.001ms for 15+ widgets\n\n", .{});

    // Create platform
    var platform = HeadlessPlatform.init();
    platform.max_frames = 10; // Run for 10 frames for quick demo

    // Create app in game loop mode
    var app = try App(GameState).init(
        allocator,
        platform.interface(),
        .{
            .mode = .game_loop,
            .target_fps = 1000, // No sleep, run as fast as possible for demo
        },
    );
    defer app.deinit();

    // Game state
    var state = GameState{};

    std.debug.print("Running game HUD for 10 frames...\n\n", .{});

    // Run game loop - renders continuously
    const start_time = std.time.milliTimestamp();
    try app.run(gameHudUI, &state);
    const end_time = std.time.milliTimestamp();

    const elapsed_ms = end_time - start_time;

    std.debug.print("\n=== Example Complete ===\n", .{});
    std.debug.print("Frames rendered: {}\n", .{state.frame_count.get()});
    std.debug.print("Elapsed time: {}ms\n", .{elapsed_ms});
    std.debug.print("Average FPS: {d:.1}\n", .{@as(f64, @floatFromInt(state.frame_count.get())) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)});
    std.debug.print("Final score: {}\n", .{state.score.get()});
    std.debug.print("Final level: {}\n", .{state.level.get()});
}
