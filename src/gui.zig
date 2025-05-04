const std = @import("std");
const state = @import("state.zig");
const RenderContext = @import("renderer.zig").RenderContext;
const RendererInterface = @import("renderer.zig").RendererInterface;
const Color = @import("core/color.zig").Color;
const Rect = @import("core/geometry.zig").Rect;
const LayoutEngine = @import("layout.zig").LayoutEngine;
const StyleSystem = @import("style.zig").StyleSystem;
const EventManager = @import("events.zig").EventManager;
const StateStore = @import("state.zig").StateStore;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const AssetManager = @import("asset.zig").AssetManager;
const View = @import("components/view.zig").View;

/// Configuration options for GUI initialization
pub const GUIConfig = struct {
    /// Window dimensions for rendering context (if applicable)
    window_width: u32 = 800,
    window_height: u32 = 600,

    /// Window title (if applicable)
    window_title: []const u8 = "ZigUI Application",

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
pub const GUI = struct {
    allocator: std.mem.Allocator,
    renderer: *RendererInterface,
    layout_engine: *LayoutEngine,
    style_system: *StyleSystem,
    event_manager: *EventManager,
    state_store: *StateStore,
    animation_system: ?*AnimationSystem,
    asset_manager: *AssetManager,

    root_view: ?*View,

    config: GUIConfig,
    running: bool,

    /// Initialize the GUI system with the provided renderer and configuration
    pub fn init(allocator: std.mem.Allocator, renderer: *RendererInterface, config: GUIConfig) !*GUI {
        // Create GUI instance
        const gui = try allocator.create(GUI);
        errdefer allocator.destroy(gui);

        // Initialize subsystems
        const layout_engine = try LayoutEngine.init(allocator, config.default_capacity);
        errdefer layout_engine.deinit();

        const style_system = try StyleSystem.init(allocator, config.theme_name);
        errdefer style_system.deinit();

        const event_manager = try EventManager.init(allocator, config.default_capacity);
        errdefer event_manager.deinit();

        const state_store = try StateStore.init(allocator);
        errdefer state_store.deinit();

        const asset_manager = try AssetManager.init(allocator);
        errdefer asset_manager.deinit();

        // Initialize animation system if enabled
        var animation_system: ?*AnimationSystem = null;
        if (config.enable_animations) {
            animation_system = try AnimationSystem.init(allocator, config.default_capacity);
            errdefer if (animation_system) |as| as.deinit();
        }

        // Initialize GUI
        gui.* = .{
            .allocator = allocator,
            .renderer = renderer,
            .layout_engine = layout_engine,
            .style_system = style_system,
            .event_manager = event_manager,
            .state_store = state_store,
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
        self.state_store.deinit();
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

    /// Process input, update state, calculate layout, and render a frame
    pub fn frame(self: *GUI, dt: f32) !void {
        // Skip if no root view
        if (self.root_view == null) return;

        // Process any queued events
        self.event_manager.processEvents();

        // Process asset loading requests
        self.asset_manager.processLoadingRequests() catch |err| {
            std.log.err("Error processing asset loading requests: {s}", .{@errorName(err)});
        };

        // Update animations if enabled
        if (self.animation_system) |animation_system| {
            animation_system.update(dt);
        }

        // Calculate layout if needed
        if (self.layout_engine.needsLayout()) {
            try self.layout_engine.calculateLayout(self.root_view.?);
        }

        // Render frame
        const frame_width: f32 = @floatFromInt(self.config.window_width);
        const frame_height: f32 = @floatFromInt(self.config.window_height);

        self.renderer.vtable.beginFrame(self.renderer, frame_width, frame_height);

        // Create render context
        const render_context = RenderContext{
            .renderer = self.renderer,
            .style_system = self.style_system,
        };

        // Paint view hierarchy
        self.paintView(self.root_view.?, &render_context);

        self.renderer.vtable.endFrame(self.renderer);
    }

    /// Process a platform event by forwarding it to the event manager
    pub fn processEvent(self: *GUI, platform_event: anytype) void {
        self.event_manager.addPlatformEvent(platform_event);
    }

    /// Check if the GUI is requesting to exit (e.g. from a Quit event)
    pub fn shouldExit(self: *GUI) bool {
        return !self.running;
    }

    /// Request application exit
    pub fn requestExit(self: *GUI) void {
        self.running = false;
    }

    // Internal helper functions

    /// Paint a view and its children
    fn paintView(self: *GUI, view: *View, context: *const RenderContext) void {
        // Skip if not visible
        if (!view.isVisible()) return;

        // Save renderer state
        self.renderer.vtable.save(self.renderer);

        // Clip to view bounds
        self.renderer.vtable.clip(self.renderer, view.rect);

        // Paint view
        view.vtable.paint(view, context);

        // Paint children
        for (view.children.items) |child| {
            self.paintView(child, context);
        }

        // Restore renderer state
        self.renderer.vtable.restore(self.renderer);
    }
};

/// Helper function to bind a state value to a component property
pub fn bind(view: *View, property: []const u8, state_handle: anytype, transform_fn: anytype) !void {
    return state.bind(view, property, state_handle, transform_fn);
}
