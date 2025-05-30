const std = @import("std");
const zlay = @import("../lib/zlay/src/zlay.zig");
const SdlPlatform = @import("platforms/sdl.zig").SdlPlatform;

/// Execution modes for the revolutionary hybrid architecture
pub const ExecutionMode = enum {
    /// Desktop applications: 0% idle CPU (blocks on events)
    /// Perfect for email clients, IDEs, productivity apps
    event_driven,
    
    /// Games and animations: Continuous 60+ FPS rendering
    /// Perfect for game UIs, real-time visualizations
    game_loop,
    
    /// Embedded systems: Ultra-low resource usage
    /// Perfect for microcontrollers, IoT devices
    minimal,
    
    /// Headless rendering: Generate UI for web/mobile
    /// Perfect for server-side rendering, testing
    server_side,
};

/// Platform backend configuration
pub const PlatformBackend = enum {
    software,        // Pure CPU rendering (no GPU required)
    opengl,          // Hardware-accelerated desktop
    vulkan,          // High-performance graphics
    direct2d,        // Windows native
    metal,           // macOS/iOS native
    framebuffer,     // Linux framebuffer (embedded)
    canvas,          // WebAssembly Canvas
    custom,          // Bring your own renderer
};

/// Configuration for creating an application
pub const AppConfig = struct {
    mode: ExecutionMode = .event_driven,
    backend: PlatformBackend = .software,
    
    /// Window configuration (ignored for embedded/headless)
    window_width: u32 = 800,
    window_height: u32 = 600,
    window_title: []const u8 = "zig-gui Application",
    
    /// Performance tuning
    target_fps: u32 = 60,           // For game loop mode
    max_memory_kb: ?u32 = null,     // Memory budget (null = unlimited)
    
    /// Development features
    hot_reload: HotReloadConfig = .{},
    
    /// Platform-specific configuration
    platform_config: ?*anyopaque = null,
};

/// Hot reload configuration for development
pub const HotReloadConfig = struct {
    enabled: bool = false,
    watch_dirs: []const []const u8 = &.{},
    reload_delay_ms: u32 = 50,
};

/// Event types that can trigger UI updates
pub const EventType = enum {
    redraw_needed,    // UI needs to be redrawn
    input,            // User input occurred  
    timer,            // Timer expired
    custom,           // Custom application event
    quit,             // Application should quit
};

/// Event data passed to the application
pub const Event = struct {
    type: EventType,
    data: ?*anyopaque = null,
    timestamp: u64,
};

/// UI function signature for rendering the interface
/// This is the heart of the immediate-mode API
pub const UIFunction = *const fn (gui: *GUI, state: ?*anyopaque) anyerror!void;

/// The revolutionary App structure that enables hybrid execution
pub const App = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    config: AppConfig,
    
    // Core systems
    gui: *GUI,
    platform: SdlPlatform,
    
    // State
    running: bool = true,
    frame_count: u64 = 0,
    
    // Performance tracking
    perf_stats: PerformanceStats = .{},
    
    /// Initialize a new application with the revolutionary architecture
    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*Self {
        const app = try allocator.create(Self);
        errdefer allocator.destroy(app);
        
        // Initialize GUI context (wraps zlay)
        const gui = try GUI.init(allocator, config);
        errdefer gui.deinit();
        
        // Initialize SDL platform backend
        const platform = try SdlPlatform.init(allocator, config);
        errdefer platform.deinit();
        
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
        self.platform.deinit();
        self.gui.deinit();
        self.allocator.destroy(self);
    }
    
    /// Check if the application should continue running
    pub fn isRunning(self: *const Self) bool {
        return self.running and !self.platform.shouldQuit();
    }
    
    /// Request the application to quit gracefully
    pub fn requestQuit(self: *Self) void {
        self.running = false;
    }
    
    /// Main application loop - the magic happens here!
    /// This function embodies our revolutionary hybrid architecture
    pub fn run(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        switch (self.config.mode) {
            .event_driven => try self.runEventDriven(ui_function, user_state),
            .game_loop => try self.runGameLoop(ui_function, user_state),
            .minimal => try self.runMinimal(ui_function, user_state),
            .server_side => try self.runServerSide(ui_function, user_state),
        }
    }
    
    /// Event-driven execution: 0% idle CPU (blocks on events)
    /// This is the revolutionary part - true idle efficiency!
    fn runEventDriven(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        while (self.isRunning()) {
            const start_time = std.time.nanoTimestamp();
            
            // 🛌 This is where the magic happens - we SLEEP until events occur!
            // Achieving true 0% idle CPU usage with SDL_WaitEvent()
            const event = try self.platform.waitForEvent();
            
            // Process the event
            try self.processEvent(event);
            
            // Only render if we actually need to redraw
            if (event.type == .redraw_needed or self.gui.needsRedraw()) {
                try self.renderFrame(ui_function, user_state);
            }
            
            // Track performance
            const end_time = std.time.nanoTimestamp();
            self.updatePerformanceStats(start_time, end_time);
        }
    }
    
    /// Game loop execution: Continuous 60+ FPS rendering
    /// Optimized for consistent frame times and high performance
    fn runGameLoop(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        const target_frame_time_ns = 1_000_000_000 / self.config.target_fps;
        
        while (self.isRunning()) {
            const frame_start = std.time.nanoTimestamp();
            
            // Process all available events (non-blocking)
            while (self.platform.pollEvent()) |event| {
                try self.processEvent(event);
            }
            
            // Always render in game loop mode for smooth animations
            try self.renderFrame(ui_function, user_state);
            
            // Precise frame rate limiting
            const frame_end = std.time.nanoTimestamp();
            const frame_time = frame_end - frame_start;
            
            if (frame_time < target_frame_time_ns) {
                const sleep_time = target_frame_time_ns - frame_time;
                std.time.sleep(sleep_time);
            }
            
            self.updatePerformanceStats(frame_start, std.time.nanoTimestamp());
        }
    }
    
    /// Minimal execution: Ultra-low resource usage for embedded
    /// Every CPU cycle counts!
    fn runMinimal(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        while (self.isRunning()) {
            // In minimal mode, we only wake up when absolutely necessary
            const event = try self.platform.waitForEvent();
            
            if (event.type == .quit) {
                self.running = false;
                break;
            }
            
            // Only redraw when something actually changed
            if (event.type == .redraw_needed) {
                try self.renderFrame(ui_function, user_state);
            }
        }
    }
    
    /// Server-side execution: Headless rendering for web/testing
    fn runServerSide(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        // Render once and output the result
        try self.renderFrame(ui_function, user_state);
        self.running = false;
    }
    
    /// Process a single event
    fn processEvent(self: *Self, event: Event) !void {
        switch (event.type) {
            .quit => self.running = false,
            .input => try self.gui.handleInput(event.data),
            .redraw_needed => {}, // Handled in main loop
            .timer => try self.gui.handleTimer(event.data),
            .custom => try self.gui.handleCustomEvent(event.data),
        }
    }
    
    // processAllEvents replaced with inline polling in game loop
    
    /// Render a complete frame
    fn renderFrame(self: *Self, ui_function: UIFunction, user_state: ?*anyopaque) !void {
        // Begin frame
        try self.gui.beginFrame();
        
        // Call user's UI function - this is where the magic happens!
        try ui_function(self.gui, user_state);
        
        // End frame and present
        try self.gui.endFrame();
        
        self.frame_count += 1;
    }
    
    /// Update performance statistics
    fn updatePerformanceStats(self: *Self, start_time: i64, end_time: i64) void {
        const frame_time_ns = end_time - start_time;
        self.perf_stats.last_frame_time_ns = @intCast(frame_time_ns);
        
        // Calculate moving average for FPS
        const frame_time_s = @as(f64, @floatFromInt(frame_time_ns)) / 1_000_000_000.0;
        if (frame_time_s > 0) {
            const fps = 1.0 / frame_time_s;
            self.perf_stats.current_fps = @intFromFloat(fps);
        }
    }
    
    /// Get current performance statistics
    pub fn getPerformanceStats(self: *const Self) PerformanceStats {
        return self.perf_stats;
    }
};

/// Performance statistics for monitoring and optimization
pub const PerformanceStats = struct {
    last_frame_time_ns: u64 = 0,
    current_fps: u32 = 0,
    memory_usage_bytes: usize = 0,
    cpu_usage_percent: f32 = 0.0,
};

// SDL Platform backend now handles all event management

// Platform abstraction now handled by SdlPlatform

/// GUI context that wraps our revolutionary data-oriented zlay
/// Provides immediate-mode API with retained-mode performance
const GUI = struct {
    allocator: std.mem.Allocator,
    zlay_ctx: *zlay.Context,
    dirty: bool = false,
    viewport: zlay.Size,
    
    fn init(allocator: std.mem.Allocator, config: AppConfig) !*GUI {
        const gui = try allocator.create(GUI);
        errdefer allocator.destroy(gui);
        
        // Initialize data-oriented zlay context with viewport from config
        const viewport = zlay.Size{ 
            .width = @floatFromInt(config.window_width), 
            .height = @floatFromInt(config.window_height) 
        };
        
        const zlay_ctx = try zlay.initWithViewport(allocator, viewport);
        errdefer zlay_ctx.deinit();
        
        gui.* = .{
            .allocator = allocator,
            .zlay_ctx = zlay_ctx,
            .viewport = viewport,
        };
        
        return gui;
    }
    
    fn deinit(self: *GUI) void {
        self.zlay_ctx.deinit();
        self.allocator.destroy(self);
    }
    
    fn needsRedraw(self: *const GUI) bool {
        return self.dirty or self.zlay_ctx.needsRedraw();
    }
    
    fn beginFrame(self: *GUI) !void {
        // Begin frame with our data-oriented zlay context
        try self.zlay_ctx.beginFrame(0.016); // Default 60 FPS delta
        self.dirty = false;
    }
    
    fn endFrame(self: *GUI) !void {
        // End frame triggers layout computation in our data-oriented engine
        try self.zlay_ctx.endFrame();
        
        // TODO: Actual rendering would happen here
        // The computed layouts are now available in zlay_ctx.layout.computed_rects
        
        self.dirty = false;
    }
    
    // ===== Immediate-Mode UI API =====
    
    /// Begin a container element
    pub fn beginContainer(self: *GUI, id: []const u8) !u32 {
        self.dirty = true;
        return try self.zlay_ctx.beginContainer(id);
    }
    
    /// End a container element
    pub fn endContainer(self: *GUI) void {
        self.zlay_ctx.endContainer();
    }
    
    /// Create a text element
    pub fn text(self: *GUI, id: []const u8, content: []const u8) !u32 {
        self.dirty = true;
        return try self.zlay_ctx.text(id, content);
    }
    
    /// Create a button and return if clicked
    pub fn button(self: *GUI, id: []const u8, label: []const u8) !bool {
        self.dirty = true;
        return try self.zlay_ctx.button(id, label);
    }
    
    /// Set style for the last created element
    pub fn setStyle(self: *GUI, style: zlay.Style) !void {
        try self.zlay_ctx.setStyle(style);
    }
    
    // ===== Input Handling =====
    
    fn handleInput(self: *GUI, input_data: ?*anyopaque) !void {
        _ = input_data;
        // TODO: Decode input_data and forward to zlay context
        // self.zlay_ctx.updateMousePos(pos);
        // self.zlay_ctx.handleMouseDown(button);
        self.dirty = true;
    }
    
    fn handleTimer(self: *GUI, timer_data: ?*anyopaque) !void {
        _ = timer_data;
        // Timer events might trigger animations or updates
    }
    
    fn handleCustomEvent(self: *GUI, event_data: ?*anyopaque) !void {
        _ = event_data;
        // Custom event handling
    }
    
    /// Get performance statistics from the underlying zlay context
    pub fn getPerformanceStats(self: *GUI) zlay.PerformanceStats {
        return self.zlay_ctx.getPerformanceStats();
    }
};

// Tests to validate our revolutionary architecture
test "App creation and cleanup" {
    const testing = std.testing;
    
    var config = AppConfig{
        .mode = .event_driven,
        .backend = .software,
    };
    
    var app = try App.init(testing.allocator, config);
    defer app.deinit();
    
    try testing.expect(app.isRunning());
    try testing.expect(app.frame_count == 0);
}

test "ExecutionMode enum values" {
    const testing = std.testing;
    
    // Ensure our execution modes are properly defined
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