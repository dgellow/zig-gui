//! Counter Example - Event-Driven Mode
//!
//! Demonstrates:
//! - Event-driven execution (0% idle CPU)
//! - Tracked(T) state management
//! - Immediate-mode widget API
//! - Button clicks and text display

const std = @import("std");
const zig_gui = @import("zig-gui");

const App = zig_gui.App;
const GUI = zig_gui.GUI;
const Tracked = zig_gui.Tracked;
const HeadlessPlatform = zig_gui.HeadlessPlatform;

/// Application state with reactive Tracked fields
const CounterState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
    clicks: Tracked(u32) = .{ .value = 0 },
    name: Tracked([]const u8) = .{ .value = "World" },
};

/// UI function - called every frame or when state changes
fn counterUI(gui: *GUI, state: *CounterState) !void {
    // Title
    try gui.text("=== Counter Example ===", .{});
    gui.newLine();
    gui.separator();

    // Display current counter value
    try gui.text("Counter: {}", .{state.counter.get()});
    gui.newLine();

    // Buttons to modify counter
    gui.beginRow();
    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1);
        state.clicks.set(state.clicks.get() + 1);
    }

    if (try gui.button("Decrement")) {
        state.counter.set(state.counter.get() - 1);
        state.clicks.set(state.clicks.get() + 1);
    }

    if (try gui.button("Reset")) {
        state.counter.set(0);
        state.clicks.set(state.clicks.get() + 1);
    }
    gui.endRow();

    gui.separator();

    // Stats
    try gui.text("Total clicks: {}", .{state.clicks.get()});
    gui.newLine();

    // Greeting
    try gui.text("Hello, {s}!", .{state.name.get()});
    gui.newLine();

    // Checkbox example
    const checked = state.counter.get() > 10;
    if (try gui.checkbox(checked)) {
        // Toggle would happen here if we tracked checkbox state
    }
    try gui.text("Counter > 10", .{});
    gui.newLine();

    gui.separator();

    // Exit button
    if (try gui.button("Exit")) {
        gui.requestExit();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Counter Example (Event-Driven Mode) ===\n\n", .{});
    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Event-driven execution (0% CPU when idle)\n", .{});
    std.debug.print("- Tracked(T) reactive state management\n", .{});
    std.debug.print("- Immediate-mode widget API\n", .{});
    std.debug.print("\nNote: Running with HeadlessPlatform (no rendering)\n", .{});
    std.debug.print("      For visual output, use SdlPlatform or similar\n\n", .{});

    // Create platform (owns OS resources)
    var platform = HeadlessPlatform.init();

    // Inject some test events to demonstrate interaction
    platform.injectEvent(.{ .type = .input, .timestamp = 0 });
    platform.max_frames = 5; // Run for 5 frames for demo

    // Create app (borrows platform via interface)
    var app = try App(CounterState).init(
        allocator,
        platform.interface(),
        .{ .mode = .event_driven },
    );
    defer app.deinit();

    // Application state
    var state = CounterState{};

    std.debug.print("Running counter example...\n\n", .{});

    // Run app - blocks on events, renders only when needed
    try app.run(counterUI, &state);

    std.debug.print("\n=== Example Complete ===\n", .{});
    std.debug.print("Final counter value: {}\n", .{state.counter.get()});
    std.debug.print("Total clicks: {}\n", .{state.clicks.get()});
}
