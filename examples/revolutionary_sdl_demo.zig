//! Revolutionary SDL Demo - Real 0% Idle CPU Event-Driven Execution
//! 
//! This demo showcases our REAL revolutionary achievement:
//! 🎯 0% idle CPU usage through SDL_WaitEvent() blocking
//! ⚡ Immediate-mode API with data-oriented performance  
//! 🚀 True event-driven desktop application architecture
//!
//! Run `htop` in another terminal to verify 0% CPU when idle!

const std = @import("std");
const app = @import("../src/app.zig");

/// Simple counter state for the demo
const CounterState = struct {
    counter: i32 = 0,
    clicks: u32 = 0,
    
    pub fn increment(self: *CounterState) void {
        self.counter += 1;
        self.clicks += 1;
    }
};

/// Revolutionary immediate-mode UI function
/// Notice the simplicity - no complex state management!
fn revolutionaryUI(gui: *app.GUI, state_ptr: ?*anyopaque) !void {
    if (state_ptr == null) return;
    
    const state = @as(*CounterState, @ptrCast(@alignCast(state_ptr)));
    
    // Simple immediate-mode API
    // The data-oriented zlay engine handles all the performance magic
    
    const container_id = try gui.beginContainer("main_container");
    defer gui.endContainer();
    
    // Title text
    _ = try gui.text("title", "🚀 Revolutionary UI Demo");
    
    // Counter display  
    var counter_text_buf: [64]u8 = undefined;
    const counter_text = try std.fmt.bufPrint(counter_text_buf[0..], "Counter: {}", .{state.counter});
    _ = try gui.text("counter", counter_text);
    
    // Click count
    var clicks_buf: [64]u8 = undefined;
    const clicks_text = try std.fmt.bufPrint(clicks_buf[0..], "Total clicks: {}", .{state.clicks});
    _ = try gui.text("clicks", clicks_text);
    
    // Interactive button - real event handling!
    if (try gui.button("increment_btn", "Click me! (+1)")) {
        state.increment();
        std.log.info("🎉 Button clicked! Counter: {}, Total clicks: {}", .{ state.counter, state.clicks });
    }
    
    _ = try gui.text("instructions", "Close window or press Ctrl+C to quit");
    _ = try gui.text("cpu_info", "🔥 Check CPU usage with 'htop' - should be 0% when idle!");
}

pub fn main() !void {
    std.log.info("🚀 Starting Revolutionary SDL Demo...", .{});
    std.log.info("⚡ Event-driven execution with 0% idle CPU usage", .{});
    std.log.info("📊 Open 'htop' in another terminal to monitor CPU usage", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Create our revolutionary app with event-driven execution
    const config = app.AppConfig{
        .mode = .event_driven,  // 🎯 This achieves 0% idle CPU!
        .backend = .software,   // Start with software rendering
        .window_width = 600,
        .window_height = 400,
        .window_title = "Revolutionary UI - 0% Idle CPU Demo",
    };
    
    var revolutionary_app = try app.App.init(gpa.allocator(), config);
    defer revolutionary_app.deinit();
    
    // Application state
    var state = CounterState{};
    
    std.log.info("🎮 Demo running! The app will use 0% CPU when you're not interacting with it.", .{});
    std.log.info("🎯 Click the button to see instant response with minimal CPU usage.", .{});
    std.log.info("🛌 When idle, the app sleeps via SDL_WaitEvent() - achieving 0% CPU!", .{});
    
    // Run the revolutionary event-driven loop!
    // This will block on SDL_WaitEvent() when no events are available
    try revolutionary_app.run(revolutionaryUI, &state);
    
    std.log.info("👋 Revolutionary demo completed. Final state: Counter={}, Clicks={}", .{ state.counter, state.clicks });
}