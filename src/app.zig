const std = @import("std");
const tracked = @import("tracked.zig");
const gui_mod = @import("gui.zig");
const GUI = gui_mod.GUI;
const GUIConfig = gui_mod.GUIConfig;

/// Execution modes for the hybrid architecture
///
/// Same API, different performance characteristics:
/// - event_driven: 0% idle CPU (blocks on events) - perfect for desktop apps
/// - game_loop: Continuous 60+ FPS - perfect for games
/// - minimal: Ultra-low resource usage - perfect for embedded
/// - server_side: Headless rendering - perfect for SSR/testing
pub const ExecutionMode = enum {
    /// Desktop applications: 0% idle CPU (blocks on events)
    event_driven,

    /// Games and animations: Continuous 60+ FPS rendering
    game_loop,

    /// Embedded systems: Ultra-low resource usage
    minimal,

    /// Headless rendering: Single render pass
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
    target_fps: u32 = 60,

    /// Enable subsystems
    enable_animations: bool = false,
    enable_accessibility: bool = false,

    /// Initial DPI scale factor
    dpi_scale: f32 = 1.0,
};

/// Event types that can trigger UI updates
pub const EventType = enum {
    redraw_needed,
    input,
    timer,
    custom,
    quit,
};

/// Event data passed to the application
pub const Event = struct {
    type: EventType,
    data: ?*anyopaque = null,
    timestamp: u64 = 0,
};

/// UI function signature for rendering the interface
pub fn UIFunction(comptime State: type) type {
    return *const fn (gui: *GUI, state: *State) anyerror!void;
}

// ============================================================================
// HeadlessPlatform - For testing and server-side rendering
// ============================================================================

/// Headless platform for testing - no window, no real events
///
/// Returns quit after max_frames, useful for tests.
pub const HeadlessPlatform = struct {
    frame_count: u32 = 0,
    max_frames: u32 = 1,

    pub fn init() HeadlessPlatform {
        return .{};
    }

    pub fn deinit(_: *HeadlessPlatform) void {}

    /// Returns redraw_needed until max_frames, then quit
    pub fn waitForEvent(self: *HeadlessPlatform) !Event {
        self.frame_count += 1;
        if (self.frame_count > self.max_frames) {
            return Event{ .type = .quit };
        }
        return Event{ .type = .redraw_needed };
    }

    /// Always returns null (no events in headless mode)
    pub fn pollEvent(_: *HeadlessPlatform) ?Event {
        return null;
    }
};

// ============================================================================
// App - The core application structure
// ============================================================================

/// Application with typed State and Platform
///
/// Platform must provide:
/// - waitForEvent(*Platform) !Event  - blocking wait for event
/// - pollEvent(*Platform) ?Event     - non-blocking poll
///
/// Example:
/// ```zig
/// const MyState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
/// };
///
/// // For real apps with SDL:
/// var platform = try SdlPlatform.init(allocator, config);
/// var app = try App(MyState, SdlPlatform).init(allocator, &platform, config);
///
/// // For tests:
/// var platform = HeadlessPlatform.init();
/// var app = try App(MyState, HeadlessPlatform).init(allocator, &platform, config);
/// ```
pub fn App(comptime State: type, comptime Platform: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: AppConfig,
        gui: *GUI,
        platform: *Platform,

        // State tracking for efficient re-renders
        last_state_version: u64 = 0,

        // For minimal mode: per-field change tracking
        field_versions: [MAX_FIELDS]u32 = [_]u32{0} ** MAX_FIELDS,

        // Application state
        running: bool = true,
        frame_count: u64 = 0,

        // Performance tracking
        perf_stats: PerformanceStats = .{},

        const MAX_FIELDS = 64;

        /// Initialize application with platform
        pub fn init(allocator: std.mem.Allocator, platform: *Platform, config: AppConfig) !*Self {
            const app = try allocator.create(Self);
            errdefer allocator.destroy(app);

            const gui_config = GUIConfig{
                .window_width = config.window_width,
                .window_height = config.window_height,
                .window_title = config.window_title,
                .enable_animations = config.enable_animations,
                .enable_accessibility = config.enable_accessibility,
                .dpi_scale = config.dpi_scale,
            };

            const gui = try GUI.init(allocator, gui_config);
            errdefer gui.deinit();

            app.* = .{
                .allocator = allocator,
                .config = config,
                .gui = gui,
                .platform = platform,
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

        /// Main application loop
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
        /// Blocks on platform.waitForEvent() - true idle efficiency.
        fn runEventDriven(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            // Initial render
            try self.renderFrame(ui_function, state);

            while (self.isRunning()) {
                const start_time = std.time.nanoTimestamp();

                // Block until event (0% CPU while waiting)
                const event = self.platform.waitForEvent() catch |err| {
                    std.log.err("Platform event error: {}", .{err});
                    continue;
                };

                // Process the event
                self.processEvent(event);

                // Only render if state changed OR explicit redraw needed
                if (event.type == .redraw_needed or tracked.stateChanged(state, &self.last_state_version)) {
                    try self.renderFrame(ui_function, state);
                }

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
                while (self.platform.pollEvent()) |event| {
                    self.processEvent(event);
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
        fn runMinimal(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            tracked.captureFieldVersions(state, &self.field_versions);
            try self.renderFrame(ui_function, state);

            while (self.isRunning()) {
                const event = self.platform.waitForEvent() catch continue;

                if (event.type == .quit) {
                    self.running = false;
                    break;
                }

                if (event.type == .redraw_needed or tracked.stateChanged(state, &self.last_state_version)) {
                    var changed_buffer: [MAX_FIELDS]usize = undefined;
                    _ = tracked.findChangedFields(state, &self.field_versions, &changed_buffer);
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
        fn processEvent(self: *Self, event: Event) void {
            switch (event.type) {
                .quit => self.running = false,
                .input => self.gui.handleInput(event.data),
                .redraw_needed, .timer, .custom => {},
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

test "HeadlessPlatform returns quit after max_frames" {
    var platform = HeadlessPlatform{ .max_frames = 2 };

    // First two calls return redraw_needed
    const e1 = try platform.waitForEvent();
    try std.testing.expectEqual(EventType.redraw_needed, e1.type);

    const e2 = try platform.waitForEvent();
    try std.testing.expectEqual(EventType.redraw_needed, e2.type);

    // Third call returns quit
    const e3 = try platform.waitForEvent();
    try std.testing.expectEqual(EventType.quit, e3.type);
}

test "HeadlessPlatform pollEvent always null" {
    var platform = HeadlessPlatform.init();
    try std.testing.expect(platform.pollEvent() == null);
}

test "App with HeadlessPlatform runs and exits" {
    const TestState = struct {
        counter: tracked.Tracked(i32) = .{ .value = 0 },
    };

    var platform = HeadlessPlatform{ .max_frames = 1 };
    var app = try App(TestState, HeadlessPlatform).init(
        std.testing.allocator,
        &platform,
        .{ .mode = .event_driven },
    );
    defer app.deinit();

    var state = TestState{};

    const testUI = struct {
        fn render(gui: *GUI, s: *TestState) !void {
            _ = gui;
            s.counter.set(s.counter.get() + 1);
        }
    }.render;

    try app.run(testUI, &state);

    // Should have rendered at least once
    try std.testing.expect(app.frame_count >= 1);
}

test "App server_side mode renders once" {
    const TestState = struct {
        rendered: tracked.Tracked(bool) = .{ .value = false },
    };

    var platform = HeadlessPlatform.init();
    var app = try App(TestState, HeadlessPlatform).init(
        std.testing.allocator,
        &platform,
        .{ .mode = .server_side },
    );
    defer app.deinit();

    var state = TestState{};

    const testUI = struct {
        fn render(gui: *GUI, s: *TestState) !void {
            _ = gui;
            s.rendered.set(true);
        }
    }.render;

    try app.run(testUI, &state);

    try std.testing.expect(state.rendered.get());
    try std.testing.expectEqual(@as(u64, 1), app.frame_count);
    try std.testing.expect(!app.isRunning());
}

test "ExecutionMode enum values" {
    try std.testing.expect(@TypeOf(ExecutionMode.event_driven) == ExecutionMode);
    try std.testing.expect(@TypeOf(ExecutionMode.game_loop) == ExecutionMode);
    try std.testing.expect(@TypeOf(ExecutionMode.minimal) == ExecutionMode);
    try std.testing.expect(@TypeOf(ExecutionMode.server_side) == ExecutionMode);
}

test "AppConfig default values" {
    const config = AppConfig{};

    try std.testing.expectEqual(ExecutionMode.event_driven, config.mode);
    try std.testing.expectEqual(@as(u32, 800), config.window_width);
    try std.testing.expectEqual(@as(u32, 600), config.window_height);
    try std.testing.expectEqual(@as(u32, 60), config.target_fps);
}

test "PerformanceStats initialization" {
    const stats = PerformanceStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.last_frame_time_ns);
    try std.testing.expectEqual(@as(u32, 0), stats.current_fps);
}
