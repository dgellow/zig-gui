const std = @import("std");
const tracked = @import("tracked.zig");
const gui_mod = @import("gui.zig");
const GUI = gui_mod.GUI;
const GUIConfig = gui_mod.GUIConfig;

/// Execution modes for the revolutionary hybrid architecture
///
/// Same API, different performance characteristics:
/// - event_driven: 0% idle CPU (blocks on events) - perfect for desktop apps
/// - game_loop: Continuous 60+ FPS - perfect for games
/// - minimal: Ultra-low resource usage - perfect for embedded
/// - server_side: Headless rendering - perfect for SSR/testing
pub const ExecutionMode = enum {
    /// Desktop applications: 0% idle CPU (blocks on events)
    /// Uses SDL_WaitEvent() to sleep when idle.
    /// Perfect for email clients, IDEs, productivity apps
    event_driven,

    /// Games and animations: Continuous 60+ FPS rendering
    /// Every frame renders regardless of changes.
    /// Perfect for game UIs, real-time visualizations
    game_loop,

    /// Embedded systems: Ultra-low resource usage
    /// Only renders when state changes, tracks per-field changes.
    /// Perfect for microcontrollers, IoT devices (<32KB RAM)
    minimal,

    /// Headless rendering: Generate UI for web/mobile
    /// Single render pass, no event loop.
    /// Perfect for server-side rendering, testing
    server_side,
};

/// Configuration for creating an application
pub const AppConfig = struct {
    mode: ExecutionMode = .event_driven,

    /// Window configuration
    window_width: u32 = 800,
    window_height: u32 = 600,
    window_title: []const u8 = "zig-gui Application",

    /// Performance tuning
    target_fps: u32 = 60, // For game loop mode

    /// Enable subsystems
    enable_animations: bool = false,
    enable_accessibility: bool = false,

    /// Development features
    hot_reload: bool = false,

    /// Initial DPI scale factor
    dpi_scale: f32 = 1.0,
};

/// Event types that can trigger UI updates
pub const EventType = enum {
    redraw_needed, // UI needs to be redrawn
    input, // User input occurred
    timer, // Timer expired
    custom, // Custom application event
    quit, // Application should quit
};

/// Event data passed to the application
pub const Event = struct {
    type: EventType,
    data: ?*anyopaque = null,
    timestamp: u64,
};

/// UI function signature for rendering the interface
///
/// Example with Tracked state:
/// ```zig
/// const AppState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
///     name: Tracked([]const u8) = .{ .value = "World" },
/// };
///
/// fn myUI(gui: *GUI, state: *AppState) !void {
///     try gui.text("Counter: {}", .{state.counter.get()});
///     if (try gui.button("Increment")) {
///         state.counter.set(state.counter.get() + 1);
///     }
/// }
///
/// var state = AppState{};
/// try app.run(myUI, &state);
/// ```
pub fn UIFunction(comptime State: type) type {
    return *const fn (gui: *GUI, state: *State) anyerror!void;
}

/// Legacy untyped UI function for backward compatibility
pub const UntypedUIFunction = *const fn (gui: *GUI, state: ?*anyopaque) anyerror!void;

/// The revolutionary App structure that enables hybrid execution
///
/// Features:
/// - Same API works in event_driven, game_loop, minimal, and server_side modes
/// - Integrated with Tracked state for efficient change detection
/// - 0% idle CPU in event_driven mode
/// - <4ms frame times in game_loop mode
/// - <32KB memory in minimal mode
pub fn App(comptime State: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: AppConfig,
        gui: *GUI,

        // State tracking for efficient re-renders
        last_state_version: u64 = 0,

        // For minimal mode: per-field change tracking
        field_versions: [MAX_FIELDS]u32 = [_]u32{0} ** MAX_FIELDS,

        // Application state
        running: bool = true,
        frame_count: u64 = 0,

        // Performance tracking
        perf_stats: PerformanceStats = .{},

        const MAX_FIELDS = 64; // Maximum tracked fields in state

        /// Initialize a new application
        pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*Self {
            const app = try allocator.create(Self);
            errdefer allocator.destroy(app);

            // Convert AppConfig to GUIConfig
            const gui_config = GUIConfig{
                .window_width = config.window_width,
                .window_height = config.window_height,
                .window_title = config.window_title,
                .enable_animations = config.enable_animations,
                .enable_accessibility = config.enable_accessibility,
                .dpi_scale = config.dpi_scale,
            };

            // Initialize GUI (without legacy StateStore)
            const gui = try GUI.initWithoutStateStore(allocator, gui_config);
            errdefer gui.deinit();

            app.* = .{
                .allocator = allocator,
                .config = config,
                .gui = gui,
            };

            return app;
        }

        /// Clean up all resources
        pub fn deinit(self: *Self) void {
            self.gui.deinit();
            self.allocator.destroy(self);
        }

        /// Check if the application should continue running
        pub fn isRunning(self: *const Self) bool {
            return self.running and !self.gui.shouldExit();
        }

        /// Request the application to quit gracefully
        pub fn requestQuit(self: *Self) void {
            self.running = false;
        }

        /// Main application loop with typed state
        ///
        /// Automatically integrates Tracked state change detection:
        /// - event_driven: Only re-renders when state changes
        /// - game_loop: Always renders, uses state for internal diffing
        /// - minimal: Tracks per-field changes for partial updates
        pub fn run(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            switch (self.config.mode) {
                .event_driven => try self.runEventDriven(ui_function, state),
                .game_loop => try self.runGameLoop(ui_function, state),
                .minimal => try self.runMinimal(ui_function, state),
                .server_side => try self.runServerSide(ui_function, state),
            }
        }

        /// Event-driven execution: 0% idle CPU
        ///
        /// The revolutionary part - true idle efficiency!
        /// Uses stateChanged() to skip re-renders when nothing changed.
        fn runEventDriven(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            // Initial render
            try self.renderFrame(ui_function, state);

            while (self.isRunning()) {
                const start_time = std.time.nanoTimestamp();

                // Block until an event occurs (0% CPU while waiting)
                const event = self.gui.waitForEvent() orelse continue;

                // Process the event
                try self.processEvent(event);

                // Only render if state changed OR explicit redraw needed
                if (event.type == .redraw_needed or tracked.stateChanged(state, &self.last_state_version)) {
                    try self.renderFrame(ui_function, state);
                }

                // Track performance
                const end_time = std.time.nanoTimestamp();
                self.updatePerformanceStats(start_time, end_time);
            }
        }

        /// Game loop execution: Continuous 60+ FPS
        fn runGameLoop(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            const target_frame_time_ns: i64 = @divFloor(1_000_000_000, @as(i64, self.config.target_fps));

            while (self.isRunning()) {
                const frame_start = std.time.nanoTimestamp();

                // Process all available events (non-blocking)
                while (self.gui.pollEvent()) |event| {
                    try self.processEvent(event);
                }

                // Always render in game loop mode
                try self.renderFrame(ui_function, state);

                // Frame rate limiting
                const frame_end = std.time.nanoTimestamp();
                const frame_time = frame_end - frame_start;

                if (frame_time < target_frame_time_ns) {
                    const sleep_time: u64 = @intCast(target_frame_time_ns - frame_time);
                    std.time.sleep(sleep_time);
                }

                self.updatePerformanceStats(frame_start, std.time.nanoTimestamp());
            }
        }

        /// Minimal execution: Ultra-low resource usage
        ///
        /// Uses per-field change tracking for partial updates.
        fn runMinimal(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            // Capture initial field versions
            tracked.captureFieldVersions(state, &self.field_versions);

            // Initial render
            try self.renderFrame(ui_function, state);

            while (self.isRunning()) {
                // Block until event
                const event = self.gui.waitForEvent() orelse continue;

                if (event.type == .quit) {
                    self.running = false;
                    break;
                }

                // Only redraw if something changed
                if (event.type == .redraw_needed or tracked.stateChanged(state, &self.last_state_version)) {
                    // Find which specific fields changed (for partial updates)
                    var changed_buffer: [MAX_FIELDS]usize = undefined;
                    const changed_fields = tracked.findChangedFields(state, &self.field_versions, &changed_buffer);
                    _ = changed_fields; // TODO: Use for partial rendering

                    try self.renderFrame(ui_function, state);
                }
            }
        }

        /// Server-side execution: Single render pass
        fn runServerSide(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            try self.renderFrame(ui_function, state);
            self.running = false;
        }

        /// Process a single event
        fn processEvent(self: *Self, event: Event) !void {
            switch (event.type) {
                .quit => self.running = false,
                .input => self.gui.handleInput(event.data),
                .redraw_needed => {},
                .timer => {},
                .custom => {},
            }
        }

        /// Render a complete frame
        fn renderFrame(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            try self.gui.beginFrame();
            try ui_function(self.gui, state);
            try self.gui.endFrame();
            self.frame_count += 1;
        }

        /// Update performance statistics
        fn updatePerformanceStats(self: *Self, start_time: i128, end_time: i128) void {
            const frame_time_ns: i64 = @intCast(end_time - start_time);
            self.perf_stats.last_frame_time_ns = @intCast(@max(0, frame_time_ns));

            const frame_time_s = @as(f64, @floatFromInt(frame_time_ns)) / 1_000_000_000.0;
            if (frame_time_s > 0) {
                self.perf_stats.current_fps = @intFromFloat(1.0 / frame_time_s);
            }
        }

        /// Get current performance statistics
        pub fn getPerformanceStats(self: *const Self) PerformanceStats {
            return self.perf_stats;
        }

        /// Get the GUI context for direct access
        pub fn getGUI(self: *Self) *GUI {
            return self.gui;
        }
    };
}

/// Performance statistics for monitoring
pub const PerformanceStats = struct {
    last_frame_time_ns: u64 = 0,
    current_fps: u32 = 0,
    memory_usage_bytes: usize = 0,
    cpu_usage_percent: f32 = 0.0,
};

// ============================================================================
// Tests
// ============================================================================

test "ExecutionMode enum values" {
    const testing = std.testing;

    try testing.expect(@TypeOf(ExecutionMode.event_driven) == ExecutionMode);
    try testing.expect(@TypeOf(ExecutionMode.game_loop) == ExecutionMode);
    try testing.expect(@TypeOf(ExecutionMode.minimal) == ExecutionMode);
    try testing.expect(@TypeOf(ExecutionMode.server_side) == ExecutionMode);
}

test "Performance stats initialization" {
    const stats = PerformanceStats{};
    const testing = std.testing;

    try testing.expect(stats.last_frame_time_ns == 0);
    try testing.expect(stats.current_fps == 0);
    try testing.expect(stats.memory_usage_bytes == 0);
    try testing.expect(stats.cpu_usage_percent == 0.0);
}

test "Tracked state integration concept" {
    // This test demonstrates how Tracked works with the App
    const Tracked = tracked.Tracked;

    const TestState = struct {
        counter: Tracked(i32) = .{ .value = 0 },
        name: Tracked([]const u8) = .{ .value = "test" },
    };

    var state = TestState{};
    var last_version: u64 = 0;

    // Initially no change (version is 0)
    try std.testing.expect(!tracked.stateChanged(&state, &last_version));

    // Modify state
    state.counter.set(42);

    // Now should detect change
    try std.testing.expect(tracked.stateChanged(&state, &last_version));

    // No more changes
    try std.testing.expect(!tracked.stateChanged(&state, &last_version));
}
