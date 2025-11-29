//! Revolutionary SDL Demo - Real 0% Idle CPU Event-Driven Execution
//!
//! This demo showcases our REAL revolutionary achievement:
//! 🎯 0% idle CPU usage through SDL_WaitEvent() blocking
//! ⚡ Immediate-mode API with Tracked Signals state management
//! 🚀 True event-driven desktop application architecture
//!
//! Run `htop` in another terminal to verify 0% CPU when idle!

const std = @import("std");
const root = @import("../src/root.zig");
const App = root.App;
const GUI = root.GUI;
const Tracked = root.Tracked;

/// Demo state using Tracked Signals - 4 bytes overhead per field, zero allocations
const DemoState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
    clicks: Tracked(u32) = .{ .value = 0 },

    pub fn increment(self: *DemoState) void {
        self.counter.set(self.counter.get() + 1);
        self.clicks.set(self.clicks.get() + 1);
    }
};

/// Revolutionary immediate-mode UI function
/// Notice the simplicity - Tracked Signals handle all state management!
fn revolutionaryUI(gui: *GUI, state: *DemoState) !void {
    // Simple immediate-mode API with Tracked state
    // Framework automatically detects changes via version counters

    // Title text
    try gui.text("🚀 Revolutionary UI Demo", .{});

    // Counter display - reads via .get()
    try gui.text("Counter: {}", .{state.counter.get()});

    // Click count
    try gui.text("Total clicks: {}", .{state.clicks.get()});

    // Interactive button - updates via .set() (O(1), zero allocations)
    if (try gui.button("Click me! (+1)")) {
        state.increment();
        std.log.info("🎉 Button clicked! Counter: {}, Total clicks: {}", .{
            state.counter.get(),
            state.clicks.get(),
        });
    }

    try gui.text("Close window or press Ctrl+C to quit", .{});
    try gui.text("🔥 Check CPU usage with 'htop' - should be 0% when idle!", .{});
}

pub fn main() !void {
    std.log.info("🚀 Starting Revolutionary SDL Demo...", .{});
    std.log.info("⚡ Event-driven execution with 0% idle CPU usage", .{});
    std.log.info("📊 Open 'htop' in another terminal to monitor CPU usage", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Create our revolutionary app with event-driven execution
    // App is generic over state type for type-safe UI functions
    var revolutionary_app = try App(DemoState).init(gpa.allocator(), .{
        .mode = .event_driven, // 🎯 This achieves 0% idle CPU!
        .window_width = 600,
        .window_height = 400,
        .window_title = "Revolutionary UI - 0% Idle CPU Demo",
    });
    defer revolutionary_app.deinit();

    // Application state with Tracked fields
    var state = DemoState{};

    std.log.info("🎮 Demo running! The app will use 0% CPU when you're not interacting with it.", .{});
    std.log.info("🎯 Click the button to see instant response with minimal CPU usage.", .{});
    std.log.info("🛌 When idle, the app sleeps via SDL_WaitEvent() - achieving 0% CPU!", .{});
    std.log.info("📈 State changes tracked via Tracked Signals - O(1) writes, O(N) change detection", .{});

    // Run the revolutionary event-driven loop!
    // Framework automatically uses stateChanged() to skip unnecessary renders
    try revolutionary_app.run(revolutionaryUI, &state);

    std.log.info("👋 Revolutionary demo completed. Final state: Counter={}, Clicks={}", .{
        state.counter.get(),
        state.clicks.get(),
    });
}
