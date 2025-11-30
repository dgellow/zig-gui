const std = @import("std");
const tracked = @import("tracked.zig");
const gui_mod = @import("gui.zig");
const GUI = gui_mod.GUI;
const GUIConfig = gui_mod.GUIConfig;
const profiler = @import("profiler.zig");

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

    /// Performance tuning
    target_fps: u32 = 60,

    /// Enable subsystems
    enable_animations: bool = false,
    enable_accessibility: bool = false,

    /// Initial DPI scale factor
    dpi_scale: f32 = 1.0,

    /// Development features
    hot_reload: bool = false,
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

    pub fn requiresRedraw(self: Event) bool {
        return self.type == .redraw_needed or self.type == .input;
    }
};

/// UI function signature for rendering the interface
pub fn UIFunction(comptime State: type) type {
    return *const fn (gui: *GUI, state: *State) anyerror!void;
}

// ============================================================================
// PlatformInterface - Runtime vtable for platform dispatch
// ============================================================================

/// Platform interface (vtable for runtime dispatch)
///
/// This enables runtime platform selection, which is essential for:
/// - C API compatibility (can't use comptime from C)
/// - Game engine integration (platform determined at runtime)
/// - Testing (inject HeadlessPlatform without recompilation)
///
/// Example:
/// ```zig
/// // Platform created first - owns OS resources
/// var platform = try SdlPlatform.init(allocator, config);
/// defer platform.deinit();
///
/// // App borrows platform via interface (vtable)
/// var app = try App(MyState).init(allocator, platform.interface(), .{});
/// defer app.deinit();
///
/// try app.run(myUI, &state);
/// ```
pub const PlatformInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Wait for next event (blocking) - achieves 0% idle CPU
        waitEvent: *const fn (ptr: *anyopaque) anyerror!Event,

        /// Poll for event (non-blocking) - for game loop mode
        pollEvent: *const fn (ptr: *anyopaque) ?Event,

        /// Present/swap buffers
        present: *const fn (ptr: *anyopaque) void,
    };

    /// Wait for event via vtable dispatch
    pub fn waitEvent(self: PlatformInterface) !Event {
        return self.vtable.waitEvent(self.ptr);
    }

    /// Poll for event via vtable dispatch
    pub fn pollEvent(self: PlatformInterface) ?Event {
        return self.vtable.pollEvent(self.ptr);
    }

    /// Present frame via vtable dispatch
    pub fn present(self: PlatformInterface) void {
        self.vtable.present(self.ptr);
    }
};

// ============================================================================
// HeadlessPlatform - For testing and server-side rendering
// ============================================================================

/// Headless platform for testing - no window, no real events
///
/// Provides deterministic event injection for unit tests.
/// Returns quit after max_frames, useful for automated tests.
///
/// Example:
/// ```zig
/// var headless = HeadlessPlatform.init();
/// var app = try App(TestState).init(allocator, headless.interface(), .{});
/// defer app.deinit();
///
/// headless.injectClick(100, 50);  // Deterministic event injection
/// try app.run(testUI, &state);
/// ```
pub const HeadlessPlatform = struct {
    frame_count: u32 = 0,
    max_frames: u32 = 1,
    injected_events: std.BoundedArray(Event, 64) = .{},
    render_calls: u32 = 0,
    quit_sent: bool = false,

    pub fn init() HeadlessPlatform {
        return .{};
    }

    pub fn deinit(_: *HeadlessPlatform) void {}

    /// Get the platform interface (vtable) for passing to App
    pub fn interface(self: *HeadlessPlatform) PlatformInterface {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Inject an event for testing
    pub fn injectEvent(self: *HeadlessPlatform, event: Event) void {
        self.injected_events.append(event) catch {};
    }

    /// Inject a click event at specific coordinates
    pub fn injectClick(self: *HeadlessPlatform, x: i32, y: i32) void {
        _ = x;
        _ = y;
        self.injectEvent(.{ .type = .input });
    }

    /// Inject a redraw event
    pub fn injectRedraw(self: *HeadlessPlatform) void {
        self.injectEvent(.{ .type = .redraw_needed });
    }

    // VTable implementation
    const vtable = PlatformInterface.VTable{
        .waitEvent = waitEventImpl,
        .pollEvent = pollEventImpl,
        .present = presentImpl,
    };

    fn waitEventImpl(ptr: *anyopaque) !Event {
        const self: *HeadlessPlatform = @ptrCast(@alignCast(ptr));

        // Return injected events first
        if (self.injected_events.len > 0) {
            return self.injected_events.orderedRemove(0);
        }

        // Check if we've exceeded max_frames
        if (self.frame_count >= self.max_frames) {
            return Event{ .type = .quit };
        }

        // Increment frame count for event-driven mode (each wait is a frame)
        self.frame_count += 1;
        return Event{ .type = .redraw_needed };
    }

    fn pollEventImpl(ptr: *anyopaque) ?Event {
        const self: *HeadlessPlatform = @ptrCast(@alignCast(ptr));

        if (self.injected_events.len > 0) {
            return self.injected_events.orderedRemove(0);
        }

        // Check if we've exceeded max_frames (for game loop mode)
        // Only send quit event ONCE to avoid infinite loop in processEvents()
        if (self.frame_count >= self.max_frames and !self.quit_sent) {
            self.quit_sent = true;
            return Event{ .type = .quit };
        }

        return null;
    }

    fn presentImpl(ptr: *anyopaque) void {
        const self: *HeadlessPlatform = @ptrCast(@alignCast(ptr));
        self.render_calls += 1;

        // Increment frame count on present (once per frame)
        self.frame_count += 1;
    }
};

// ============================================================================
// App - The core application structure (Model 2: Platform at Root)
// ============================================================================

/// Application with typed State and runtime Platform interface
///
/// Ownership model (Platform at Root):
/// - Platform created first, user owns it (window, GL context, events)
/// - App borrows Platform via interface (vtable for runtime dispatch)
/// - App owns GUI, execution logic
/// - Destroy order: App first, Platform last
///
/// Example:
/// ```zig
/// const MyState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
/// };
///
/// // Platform created first - owns OS resources
/// var platform = try SdlPlatform.init(allocator, .{ .width = 800, .height = 600 });
/// defer platform.deinit();
///
/// // App borrows platform via interface (vtable)
/// var app = try App(MyState).init(allocator, platform.interface(), .{ .mode = .event_driven });
/// defer app.deinit();
///
/// var state = MyState{};
/// try app.run(myUI, &state);
/// ```
pub fn App(comptime State: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: AppConfig,
        gui: *GUI,
        platform: PlatformInterface, // Borrowed via vtable, not owned

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

        /// Initialize application with platform interface
        ///
        /// Platform must be initialized first and outlive the App.
        /// App borrows the platform via vtable interface.
        pub fn init(allocator: std.mem.Allocator, platform: PlatformInterface, config: AppConfig) !*Self {
            const app = try allocator.create(Self);
            errdefer allocator.destroy(app);

            const gui_config = GUIConfig{
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

        /// Clean up App resources (does NOT clean up platform - user owns that)
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

        /// Main application loop - dispatches to appropriate execution mode
        pub fn run(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            switch (self.config.mode) {
                .event_driven => try self.runEventDriven(ui_function, state),
                .game_loop => try self.runGameLoop(ui_function, state),
                .minimal => try self.runMinimal(ui_function, state),
                .server_side => try self.runServerSide(ui_function, state),
            }
        }

        /// Process events without blocking (for game loop integration)
        pub fn processEvents(self: *Self) void {
            while (self.platform.pollEvent()) |event| {
                self.processEvent(event);
            }
        }

        /// Render a single frame (for game loop integration)
        pub fn renderFrame(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            try self.renderFrameInternal(ui_function, state);
            self.platform.present();
        }

        /// Event-driven execution: 0% idle CPU
        ///
        /// Blocks on platform.waitEvent() via vtable - true idle efficiency.
        fn runEventDriven(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            profiler.zone(@src(), "runEventDriven", .{});
            defer profiler.endZone();

            // Initial render
            try self.renderFrameInternal(ui_function, state);

            while (self.isRunning()) {
                profiler.frameStart();
                defer profiler.frameEnd();

                const start_time = std.time.nanoTimestamp();

                // Block until event via vtable (0% CPU while waiting)
                const event = self.platform.waitEvent() catch |err| {
                    std.log.err("Platform event error: {}", .{err});
                    continue;
                };

                // Process the event
                {
                    profiler.zone(@src(), "processEvent", .{});
                    defer profiler.endZone();
                    self.processEvent(event);
                }

                // Only render if state changed OR explicit redraw needed
                if (event.requiresRedraw() or tracked.stateChanged(state, &self.last_state_version)) {
                    profiler.zone(@src(), "render", .{});
                    defer profiler.endZone();
                    try self.renderFrameInternal(ui_function, state);
                    self.platform.present();
                }

                const end_time = std.time.nanoTimestamp();
                self.updatePerformanceStats(start_time, end_time);
            }
        }

        /// Game loop execution: Continuous 60+ FPS
        fn runGameLoop(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            profiler.zone(@src(), "runGameLoop", .{});
            defer profiler.endZone();

            const target_frame_time_ns: i64 = @divFloor(1_000_000_000, @as(i64, self.config.target_fps));

            while (self.isRunning()) {
                profiler.frameStart();
                defer profiler.frameEnd();

                const frame_start = std.time.nanoTimestamp();

                // Process all available events (non-blocking via vtable)
                {
                    profiler.zone(@src(), "processEvents", .{});
                    defer profiler.endZone();
                    self.processEvents();
                }

                // Always render in game loop mode
                {
                    profiler.zone(@src(), "render", .{});
                    defer profiler.endZone();
                    try self.renderFrameInternal(ui_function, state);
                    self.platform.present();
                }

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
            try self.renderFrameInternal(ui_function, state);

            while (self.isRunning()) {
                const event = self.platform.waitEvent() catch continue;

                if (event.type == .quit) {
                    self.running = false;
                    break;
                }

                if (event.requiresRedraw() or tracked.stateChanged(state, &self.last_state_version)) {
                    var changed_buffer: [MAX_FIELDS]usize = undefined;
                    _ = tracked.findChangedFields(state, &self.field_versions, &changed_buffer);
                    try self.renderFrameInternal(ui_function, state);
                    self.platform.present();
                }
            }
        }

        /// Server-side execution: Single render pass
        fn runServerSide(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            try self.renderFrameInternal(ui_function, state);
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

        /// Render a complete frame (internal)
        fn renderFrameInternal(self: *Self, ui_function: UIFunction(State), state: *State) !void {
            profiler.zone(@src(), "renderFrameInternal", .{});
            defer profiler.endZone();

            {
                profiler.zone(@src(), "GUI.beginFrame", .{});
                defer profiler.endZone();
                try self.gui.beginFrame();
            }

            {
                profiler.zone(@src(), "uiFunction", .{});
                defer profiler.endZone();
                try ui_function(self.gui, state);
            }

            {
                profiler.zone(@src(), "GUI.endFrame", .{});
                defer profiler.endZone();
                try self.gui.endFrame();
            }

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

test "PlatformInterface vtable dispatch" {
    var headless = HeadlessPlatform{ .max_frames = 2 };
    const iface = headless.interface();

    // Test vtable dispatch works
    const e1 = try iface.waitEvent();
    try std.testing.expectEqual(EventType.redraw_needed, e1.type);

    const e2 = try iface.waitEvent();
    try std.testing.expectEqual(EventType.redraw_needed, e2.type);

    const e3 = try iface.waitEvent();
    try std.testing.expectEqual(EventType.quit, e3.type);
}

test "HeadlessPlatform event injection" {
    var headless = HeadlessPlatform.init();

    // Inject events
    headless.injectEvent(.{ .type = .input });
    headless.injectRedraw();

    const iface = headless.interface();

    // Should get injected events first
    const e1 = try iface.waitEvent();
    try std.testing.expectEqual(EventType.input, e1.type);

    const e2 = try iface.waitEvent();
    try std.testing.expectEqual(EventType.redraw_needed, e2.type);
}

test "HeadlessPlatform pollEvent" {
    var headless = HeadlessPlatform.init();
    const iface = headless.interface();

    // No events injected - poll returns null
    try std.testing.expect(iface.pollEvent() == null);

    // Inject event
    headless.injectEvent(.{ .type = .input });

    // Now poll returns the event
    const event = iface.pollEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(EventType.input, event.?.type);

    // And it's consumed
    try std.testing.expect(iface.pollEvent() == null);
}

test "App with HeadlessPlatform runs and exits" {
    const TestState = struct {
        counter: tracked.Tracked(i32) = .{ .value = 0 },
    };

    var headless = HeadlessPlatform{ .max_frames = 1 };
    var app = try App(TestState).init(
        std.testing.allocator,
        headless.interface(),
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

    var headless = HeadlessPlatform.init();
    var app = try App(TestState).init(
        std.testing.allocator,
        headless.interface(),
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

test "App game loop mode with processEvents/renderFrame" {
    const TestState = struct {
        frame: tracked.Tracked(u32) = .{ .value = 0 },
    };

    var headless = HeadlessPlatform.init();
    var app = try App(TestState).init(
        std.testing.allocator,
        headless.interface(),
        .{ .mode = .game_loop },
    );
    defer app.deinit();

    var state = TestState{};

    const testUI = struct {
        fn render(gui: *GUI, s: *TestState) !void {
            _ = gui;
            s.frame.set(s.frame.get() + 1);
        }
    }.render;

    // Simulate game loop usage
    for (0..3) |_| {
        app.processEvents();
        try app.renderFrame(testUI, &state);
    }

    try std.testing.expectEqual(@as(u32, 3), state.frame.get());
    try std.testing.expectEqual(@as(u64, 3), app.frame_count);
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
    try std.testing.expectEqual(@as(u32, 60), config.target_fps);
    try std.testing.expectEqual(false, config.hot_reload);
}

test "PerformanceStats initialization" {
    const stats = PerformanceStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.last_frame_time_ns);
    try std.testing.expectEqual(@as(u32, 0), stats.current_fps);
}

test "Event.requiresRedraw" {
    const redraw_event = Event{ .type = .redraw_needed };
    const input_event = Event{ .type = .input };
    const quit_event = Event{ .type = .quit };

    try std.testing.expect(redraw_event.requiresRedraw());
    try std.testing.expect(input_event.requiresRedraw());
    try std.testing.expect(!quit_event.requiresRedraw());
}
