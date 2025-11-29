const std = @import("std");
const RenderContext = @import("renderer.zig").RenderContext;
const RendererInterface = @import("renderer.zig").RendererInterface;
const Color = @import("core/color.zig").Color;
const Rect = @import("core/geometry.zig").Rect;
const LayoutEngine = @import("layout.zig").LayoutEngine;
const StyleSystem = @import("style.zig").StyleSystem;
const EventManager = @import("events.zig").EventManager;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const AssetManager = @import("asset.zig").AssetManager;
const View = @import("components/view.zig").View;
const app = @import("app.zig");

/// Configuration options for GUI initialization
pub const GUIConfig = struct {
    /// Window dimensions for rendering context (if applicable)
    window_width: u32 = 800,
    window_height: u32 = 600,

    /// Window title (if applicable)
    window_title: []const u8 = "zig-gui Application",

    /// Enable animation system (can be disabled for constrained environments)
    enable_animations: bool = false,

    /// Enable accessibility (can be disabled for constrained environments)
    enable_accessibility: bool = false,

    /// Initial DPI scale factor
    dpi_scale: f32 = 1.0,

    /// Initial theme name
    theme_name: []const u8 = "default",

    /// Default capacity for various collections to reduce reallocations
    default_capacity: u32 = 32,
};

/// Main GUI manager that coordinates all subsystems
///
/// State Management: Use Tracked(T) for reactive state instead of the legacy StateStore.
/// See docs/STATE_MANAGEMENT.md for the design rationale.
///
/// Example:
/// ```zig
/// const AppState = struct {
///     counter: Tracked(i32) = .{ .value = 0 },
///     name: Tracked([]const u8) = .{ .value = "World" },
/// };
///
/// fn myUI(gui: *GUI, state: *AppState) !void {
///     // Access state with .get()
///     try gui.text("Hello, {s}!", .{state.name.get()});
///
///     // Update state with .set() - automatically tracked
///     if (try gui.button("Click me")) {
///         state.counter.set(state.counter.get() + 1);
///     }
/// }
/// ```
pub const GUI = struct {
    allocator: std.mem.Allocator,
    renderer: ?*RendererInterface,
    layout_engine: *LayoutEngine,
    style_system: *StyleSystem,
    event_manager: *EventManager,
    animation_system: ?*AnimationSystem,
    asset_manager: *AssetManager,

    root_view: ?*View,

    config: GUIConfig,
    running: bool,

    // Frame state
    in_frame: bool = false,

    /// Initialize the GUI system with a renderer
    pub fn init(allocator: std.mem.Allocator, renderer: *RendererInterface, config: GUIConfig) !*GUI {
        return initInternal(allocator, renderer, config);
    }

    /// Initialize the GUI system without a renderer (for headless/testing)
    /// State management uses Tracked(T) - no StateStore needed
    pub fn initWithoutStateStore(allocator: std.mem.Allocator, config: GUIConfig) !*GUI {
        return initInternal(allocator, null, config);
    }

    /// Internal initialization
    fn initInternal(allocator: std.mem.Allocator, renderer: ?*RendererInterface, config: GUIConfig) !*GUI {
        const gui = try allocator.create(GUI);
        errdefer allocator.destroy(gui);

        // Initialize subsystems
        const layout_engine = try LayoutEngine.init(allocator, config.default_capacity);
        errdefer layout_engine.deinit();

        const style_system = try StyleSystem.init(allocator, config.theme_name);
        errdefer style_system.deinit();

        const event_manager = try EventManager.init(allocator, config.default_capacity);
        errdefer event_manager.deinit();

        const asset_manager = try AssetManager.init(allocator);
        errdefer asset_manager.deinit();

        // Initialize animation system if enabled
        var animation_system: ?*AnimationSystem = null;
        if (config.enable_animations) {
            animation_system = try AnimationSystem.init(allocator, config.default_capacity);
        }

        gui.* = .{
            .allocator = allocator,
            .renderer = renderer,
            .layout_engine = layout_engine,
            .style_system = style_system,
            .event_manager = event_manager,
            .animation_system = animation_system,
            .asset_manager = asset_manager,
            .root_view = null,
            .config = config,
            .running = true,
        };

        return gui;
    }

    /// Clean up all resources used by the GUI
    pub fn deinit(self: *GUI) void {
        // Clean up all subsystems in reverse order of creation
        if (self.animation_system) |animation_system| {
            animation_system.deinit();
        }

        // Clean up hierarchy if any
        if (self.root_view) |root| {
            root.deinit();
        }

        self.asset_manager.deinit();
        self.event_manager.deinit();
        self.style_system.deinit();
        self.layout_engine.deinit();

        // Clean up self
        self.allocator.destroy(self);
    }

    /// Set the root view for the UI hierarchy
    pub fn setRootView(self: *GUI, view: *View) void {
        self.root_view = view;
        self.layout_engine.markDirty(view);
    }

    // =========================================================================
    // Frame Management (used by App)
    // =========================================================================

    /// Begin a new frame
    pub fn beginFrame(self: *GUI) !void {
        self.in_frame = true;

        // Process any queued events
        self.event_manager.processEvents();

        // Process asset loading requests
        self.asset_manager.processLoadingRequests() catch |err| {
            std.log.err("Error processing asset loading requests: {s}", .{@errorName(err)});
        };

        // Begin renderer frame if available
        if (self.renderer) |renderer| {
            const frame_width: f32 = @floatFromInt(self.config.window_width);
            const frame_height: f32 = @floatFromInt(self.config.window_height);
            renderer.vtable.beginFrame(renderer, frame_width, frame_height);
        }
    }

    /// End frame and present
    pub fn endFrame(self: *GUI) !void {
        // Calculate layout if needed
        if (self.layout_engine.needsLayout()) {
            if (self.root_view) |root| {
                try self.layout_engine.calculateLayout(root);
            }
        }

        // Render if we have a renderer and root view
        if (self.renderer) |renderer| {
            if (self.root_view) |root| {
                const render_context = RenderContext{
                    .renderer = renderer,
                    .style_system = self.style_system,
                };
                self.paintView(root, &render_context);
            }
            renderer.vtable.endFrame(renderer);
        }

        self.in_frame = false;
    }

    /// Process input, update state, calculate layout, and render a frame (legacy)
    pub fn frame(self: *GUI, dt: f32) !void {
        // Skip if no root view
        if (self.root_view == null) return;

        // Update animations if enabled
        if (self.animation_system) |animation_system| {
            animation_system.update(dt);
        }

        try self.beginFrame();
        try self.endFrame();
    }

    // =========================================================================
    // Event Handling
    // =========================================================================

    /// Wait for the next event (blocks, 0% CPU while waiting)
    /// Returns null if no event available or error occurred
    pub fn waitForEvent(self: *GUI) ?app.Event {
        _ = self;
        // TODO: Integrate with platform backend (SDL_WaitEvent)
        // For now, return a placeholder redraw event
        return app.Event{
            .type = .redraw_needed,
            .timestamp = @intCast(std.time.milliTimestamp()),
        };
    }

    /// Poll for event without blocking (for game loop mode)
    pub fn pollEvent(self: *GUI) ?app.Event {
        _ = self;
        // TODO: Integrate with platform backend (SDL_PollEvent)
        return null;
    }

    /// Handle raw input data
    pub fn handleInput(self: *GUI, input_data: ?*anyopaque) void {
        _ = input_data;
        // Mark for redraw since input might change UI state
        self.layout_engine.markDirty(self.root_view orelse return);
    }

    /// Process a platform event by forwarding it to the event manager
    pub fn processEvent(self: *GUI, platform_event: anytype) void {
        self.event_manager.addPlatformEvent(platform_event);
    }

    // =========================================================================
    // Application Control
    // =========================================================================

    /// Check if the GUI is requesting to exit
    pub fn shouldExit(self: *GUI) bool {
        return !self.running;
    }

    /// Request application exit
    pub fn requestExit(self: *GUI) void {
        self.running = false;
    }

    // =========================================================================
    // Immediate-Mode UI API (TODO: Expand)
    // =========================================================================

    /// Create a text element
    pub fn text(self: *GUI, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        _ = fmt;
        _ = args;
        // TODO: Implement immediate-mode text
    }

    /// Create a button and return if clicked
    pub fn button(self: *GUI, label: []const u8) !bool {
        _ = self;
        _ = label;
        // TODO: Implement immediate-mode button
        return false;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// Paint a view and its children
    fn paintView(self: *GUI, view: *View, context: *const RenderContext) void {
        // Skip if not visible
        if (!view.isVisible()) return;

        // Save renderer state
        if (self.renderer) |renderer| {
            renderer.vtable.save(renderer);
            renderer.vtable.clip(renderer, view.rect);
        }

        // Paint view
        view.vtable.paint(view, context);

        // Paint children
        for (view.children.items) |child| {
            self.paintView(child, context);
        }

        // Restore renderer state
        if (self.renderer) |renderer| {
            renderer.vtable.restore(renderer);
        }
    }
};
