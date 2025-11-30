const std = @import("std");
const RenderContext = @import("renderer.zig").RenderContext;
const RendererInterface = @import("renderer.zig").RendererInterface;
const Color = @import("core/color.zig").Color;
const Rect = @import("core/geometry.zig").Rect;
const Point = @import("core/geometry.zig").Point;
const Paint = @import("core/paint.zig").Paint;
const LayoutEngine = @import("layout.zig").LayoutEngine;
const StyleSystem = @import("style.zig").StyleSystem;
const EventManager = @import("events.zig").EventManager;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const AssetManager = @import("asset.zig").AssetManager;
// const View = @import("components/view.zig").View; // Removed - moving to immediate-mode API
const profiler = @import("profiler.zig");

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
/// State Management: Use Tracked(T) for reactive state.
/// See DESIGN.md for the design rationale.
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

    // root_view: ?*View, // Removed - moving to immediate-mode API

    config: GUIConfig,
    running: bool,

    // Frame state
    in_frame: bool = false,

    // =========================================================================
    // Immediate-Mode State
    // =========================================================================

    /// Current cursor position for auto-layout
    im_cursor_x: f32 = 0,
    im_cursor_y: f32 = 0,

    /// Layout parameters
    im_line_height: f32 = 24,
    im_padding: f32 = 8,
    im_spacing: f32 = 4,

    /// Mouse state (updated by platform)
    im_mouse_x: f32 = 0,
    im_mouse_y: f32 = 0,
    im_mouse_down: bool = false,
    im_mouse_was_down: bool = false,

    /// Widget interaction state
    im_hot_id: u64 = 0, // Widget currently under mouse
    im_active_id: u64 = 0, // Widget being interacted with

    /// ID generation
    im_id_counter: u64 = 0,

    /// Text formatting buffer (for fmt args)
    im_text_buffer: [1024]u8 = undefined,

    /// Initialize the GUI system (headless mode, no renderer)
    /// Use initWithRenderer() if you have a platform renderer ready.
    pub fn init(allocator: std.mem.Allocator, config: GUIConfig) !*GUI {
        return initInternal(allocator, null, config);
    }

    /// Initialize the GUI system with a renderer
    pub fn initWithRenderer(allocator: std.mem.Allocator, renderer: *RendererInterface, config: GUIConfig) !*GUI {
        return initInternal(allocator, renderer, config);
    }

    /// Internal initialization
    fn initInternal(allocator: std.mem.Allocator, renderer: ?*RendererInterface, config: GUIConfig) !*GUI {
        const gui = try allocator.create(GUI);
        errdefer allocator.destroy(gui);

        // Initialize subsystems (zlay v2.0 - 4-14x faster!)
        const layout_engine_val = try LayoutEngine.init(allocator);
        const layout_engine = try allocator.create(LayoutEngine);
        layout_engine.* = layout_engine_val;
        errdefer {
            layout_engine.deinit();
            allocator.destroy(layout_engine);
        }

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

        self.asset_manager.deinit();
        self.event_manager.deinit();
        self.style_system.deinit();
        self.layout_engine.deinit();
        self.allocator.destroy(self.layout_engine);

        // Clean up self
        self.allocator.destroy(self);
    }

    // /// Set the root view for the UI hierarchy
    // /// Removed - moving to immediate-mode API
    // pub fn setRootView(self: *GUI, view: *View) void {
    //     self.root_view = view;
    //     self.layout_engine.markDirty(view);
    // }

    // =========================================================================
    // Frame Management (used by App)
    // =========================================================================

    /// Begin a new frame
    pub fn beginFrame(self: *GUI) !void {
        profiler.zone(@src(), "GUI.beginFrame", .{});
        defer profiler.endZone();

        self.in_frame = true;

        // Reset immediate-mode cursor
        self.im_cursor_x = self.im_padding;
        self.im_cursor_y = self.im_padding;

        // Reset ID counter for this frame
        self.im_id_counter = 0;

        // Clear hot ID (will be set during rendering)
        self.im_hot_id = 0;

        // Process any queued events
        {
            profiler.zone(@src(), "EventManager.processEvents", .{});
            defer profiler.endZone();
            self.event_manager.processEvents();
        }

        // Process asset loading requests
        {
            profiler.zone(@src(), "AssetManager.processLoadingRequests", .{});
            defer profiler.endZone();
            self.asset_manager.processLoadingRequests() catch |err| {
                std.log.err("Error processing asset loading requests: {s}", .{@errorName(err)});
            };
        }

        // Begin renderer frame if available
        if (self.renderer) |renderer| {
            profiler.zone(@src(), "Renderer.beginFrame", .{});
            defer profiler.endZone();
            const frame_width: f32 = @floatFromInt(self.config.window_width);
            const frame_height: f32 = @floatFromInt(self.config.window_height);
            renderer.vtable.beginFrame(renderer, frame_width, frame_height);
        }
    }

    /// End frame and present
    pub fn endFrame(self: *GUI) !void {
        profiler.zone(@src(), "GUI.endFrame", .{});
        defer profiler.endZone();

        // Layout is computed during widget rendering in immediate-mode
        // No separate layout pass needed

        // Render if we have a renderer
        if (self.renderer) |renderer| {
            // Removed root_view painting - moving to immediate-mode API
            // if (self.root_view) |root| {
            //     profiler.zone(@src(), "Renderer.paint", .{});
            //     defer profiler.endZone();
            //     const render_context = RenderContext{
            //         .renderer = renderer,
            //         .style_system = self.style_system,
            //     };
            //     self.paintView(root, &render_context);
            // }
            {
                profiler.zone(@src(), "Renderer.endFrame", .{});
                defer profiler.endZone();
                renderer.vtable.endFrame(renderer);
            }
        }

        // Update mouse state for next frame
        self.im_mouse_was_down = self.im_mouse_down;

        // Clear active widget if mouse released
        if (!self.im_mouse_down) {
            self.im_active_id = 0;
        }

        self.in_frame = false;
    }

    // =========================================================================
    // Input State (set by platform, read by widgets)
    // =========================================================================

    /// Update mouse position (called by platform)
    pub fn setMousePosition(self: *GUI, x: f32, y: f32) void {
        self.im_mouse_x = x;
        self.im_mouse_y = y;
    }

    /// Update mouse button state (called by platform)
    pub fn setMouseButton(self: *GUI, down: bool) void {
        self.im_mouse_down = down;
    }

    /// Handle raw input data
    pub fn handleInput(self: *GUI, _: ?*anyopaque) void {
        _ = self;
        // Immediate-mode: widgets are rebuilt each frame, no need to mark dirty
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
    // Immediate-Mode UI API
    // =========================================================================

    /// Generate a unique ID for a widget based on label
    fn generateId(self: *GUI, label: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(label);
        hasher.update(std.mem.asBytes(&self.im_id_counter));
        self.im_id_counter += 1;
        return hasher.final();
    }

    /// Check if a point is inside a rectangle
    fn pointInRect(x: f32, y: f32, rect: Rect) bool {
        return x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height;
    }

    /// Check if mouse clicked (was down, now up)
    fn mouseClicked(self: *GUI) bool {
        return self.im_mouse_was_down and !self.im_mouse_down;
    }

    /// Check if mouse just pressed (wasn't down, now down)
    fn mousePressed(self: *GUI) bool {
        return !self.im_mouse_was_down and self.im_mouse_down;
    }

    /// Advance cursor to next line
    pub fn newLine(self: *GUI) void {
        self.im_cursor_x = self.im_padding;
        self.im_cursor_y += self.im_line_height + self.im_spacing;
    }

    /// Set cursor position explicitly
    pub fn setCursor(self: *GUI, x: f32, y: f32) void {
        self.im_cursor_x = x;
        self.im_cursor_y = y;
    }

    /// Create a text element with format string
    pub fn text(self: *GUI, comptime fmt: []const u8, args: anytype) !void {
        const formatted = std.fmt.bufPrint(&self.im_text_buffer, fmt, args) catch |err| {
            std.log.err("Text format error: {}", .{err});
            return;
        };

        self.textRaw(formatted);
    }

    /// Create a text element with raw string
    pub fn textRaw(self: *GUI, str: []const u8) void {
        // Calculate text dimensions (approximate: 8 pixels per character)
        const char_width: f32 = 8;
        const text_width = @as(f32, @floatFromInt(str.len)) * char_width;
        const text_height = self.im_line_height;

        // Draw text if we have a renderer
        if (self.renderer) |renderer| {
            const position = Point{
                .x = self.im_cursor_x,
                .y = self.im_cursor_y + text_height * 0.75, // Baseline offset
            };

            const paint = Paint{
                .color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
            };

            renderer.vtable.drawText(renderer, str, position, paint);
        }

        // Advance cursor
        self.im_cursor_x += text_width + self.im_spacing;

        // Wrap if too wide
        const window_width: f32 = @floatFromInt(self.config.window_width);
        if (self.im_cursor_x > window_width - self.im_padding) {
            self.newLine();
        }
    }

    /// Create a button and return if clicked
    ///
    /// Example:
    /// ```zig
    /// if (try gui.button("Click me")) {
    ///     state.counter.set(state.counter.get() + 1);
    /// }
    /// ```
    pub fn button(self: *GUI, label: []const u8) !bool {
        const id = self.generateId(label);

        // Calculate button dimensions
        const char_width: f32 = 8;
        const text_width = @as(f32, @floatFromInt(label.len)) * char_width;
        const button_width = text_width + self.im_padding * 2;
        const button_height = self.im_line_height + self.im_padding;

        const rect = Rect{
            .x = self.im_cursor_x,
            .y = self.im_cursor_y,
            .width = button_width,
            .height = button_height,
        };

        // Check if mouse is over button
        const is_hot = pointInRect(self.im_mouse_x, self.im_mouse_y, rect);
        if (is_hot) {
            self.im_hot_id = id;
        }

        // Handle interaction
        var clicked = false;
        const is_active = self.im_active_id == id;

        if (is_hot) {
            if (self.mousePressed()) {
                self.im_active_id = id;
            }
        }

        if (is_active and is_hot and self.mouseClicked()) {
            clicked = true;
        }

        // Draw button if we have a renderer
        if (self.renderer) |renderer| {
            // Background color based on state
            const bg_color = if (is_active and is_hot)
                Color{ .r = 80, .g = 80, .b = 120, .a = 255 } // Pressed
            else if (is_hot)
                Color{ .r = 70, .g = 70, .b = 100, .a = 255 } // Hover
            else
                Color{ .r = 50, .g = 50, .b = 80, .a = 255 }; // Normal

            const bg_paint = Paint{ .color = bg_color };
            renderer.vtable.drawRoundRect(renderer, rect, 4.0, bg_paint);

            // Text
            const text_position = Point{
                .x = rect.x + self.im_padding,
                .y = rect.y + button_height * 0.7,
            };

            const text_paint = Paint{
                .color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
            };

            renderer.vtable.drawText(renderer, label, text_position, text_paint);
        }

        // Advance cursor
        self.im_cursor_x += button_width + self.im_spacing;

        // Wrap if too wide
        const window_width: f32 = @floatFromInt(self.config.window_width);
        if (self.im_cursor_x > window_width - self.im_padding) {
            self.newLine();
        }

        return clicked;
    }

    /// Create a checkbox
    pub fn checkbox(self: *GUI, checked: bool) !bool {
        const id = self.generateId("checkbox");

        const size: f32 = 20;
        const rect = Rect{
            .x = self.im_cursor_x,
            .y = self.im_cursor_y,
            .width = size,
            .height = size,
        };

        // Check if mouse is over checkbox
        const is_hot = pointInRect(self.im_mouse_x, self.im_mouse_y, rect);
        if (is_hot) {
            self.im_hot_id = id;
        }

        // Handle interaction
        var toggled = false;
        const is_active = self.im_active_id == id;

        if (is_hot) {
            if (self.mousePressed()) {
                self.im_active_id = id;
            }
        }

        if (is_active and is_hot and self.mouseClicked()) {
            toggled = true;
        }

        // Draw checkbox if we have a renderer
        if (self.renderer) |renderer| {
            // Background
            const bg_color = if (is_hot)
                Color{ .r = 70, .g = 70, .b = 100, .a = 255 }
            else
                Color{ .r = 50, .g = 50, .b = 80, .a = 255 };

            renderer.vtable.drawRoundRect(renderer, rect, 3.0, Paint{ .color = bg_color });

            // Checkmark if checked
            if (checked) {
                const inner_rect = Rect{
                    .x = rect.x + 4,
                    .y = rect.y + 4,
                    .width = size - 8,
                    .height = size - 8,
                };
                const check_color = Color{ .r = 100, .g = 200, .b = 100, .a = 255 };
                renderer.vtable.drawRoundRect(renderer, inner_rect, 2.0, Paint{ .color = check_color });
            }
        }

        // Advance cursor
        self.im_cursor_x += size + self.im_spacing;

        return toggled;
    }

    /// Create a horizontal separator
    pub fn separator(self: *GUI) void {
        self.newLine();

        const window_width: f32 = @floatFromInt(self.config.window_width);
        const rect = Rect{
            .x = self.im_padding,
            .y = self.im_cursor_y,
            .width = window_width - self.im_padding * 2,
            .height = 1,
        };

        if (self.renderer) |renderer| {
            const color = Color{ .r = 80, .g = 80, .b = 100, .a = 255 };
            renderer.vtable.drawRect(renderer, rect, Paint{ .color = color });
        }

        self.im_cursor_y += self.im_spacing;
    }

    /// Text input configuration
    pub const TextInputConfig = struct {
        width: f32 = 200,
        max_length: usize = 256,
    };

    /// Create a text input field
    /// Returns true if the input is focused (clicked)
    ///
    /// Note: Full keyboard input requires keyboard event handling (not yet implemented)
    /// For now, this renders the input box and detects focus
    ///
    /// Example:
    /// ```zig
    /// var buffer: [256]u8 = undefined;
    /// const focused = try gui.textInput(&buffer, state.text.get(), .{});
    /// if (focused) {
    ///     // Handle keyboard input when event system supports it
    /// }
    /// ```
    pub fn textInput(self: *GUI, buffer: []u8, current_text: []const u8, config: TextInputConfig) !bool {
        _ = buffer;
        const id = self.generateId("textinput");

        const input_width = config.width;
        const input_height = self.im_line_height + self.im_padding;

        const rect = Rect{
            .x = self.im_cursor_x,
            .y = self.im_cursor_y,
            .width = input_width,
            .height = input_height,
        };

        // Check if mouse is over input
        const is_hot = pointInRect(self.im_mouse_x, self.im_mouse_y, rect);
        if (is_hot) {
            self.im_hot_id = id;
        }

        // Handle interaction
        var focused = false;
        const is_active = self.im_active_id == id;

        if (is_hot and self.mouseClicked()) {
            self.im_active_id = id;
            focused = true;
        }

        // Draw text input if we have a renderer
        if (self.renderer) |renderer| {
            // Background color based on state
            const bg_color = if (is_active)
                Color{ .r = 60, .g = 60, .b = 90, .a = 255 } // Focused
            else if (is_hot)
                Color{ .r = 55, .g = 55, .b = 85, .a = 255 } // Hover
            else
                Color{ .r = 40, .g = 40, .b = 70, .a = 255 }; // Normal

            const bg_paint = Paint{ .color = bg_color };
            renderer.vtable.drawRoundRect(renderer, rect, 3.0, bg_paint);

            // Draw current text
            if (current_text.len > 0) {
                const text_position = Point{
                    .x = rect.x + self.im_padding / 2,
                    .y = rect.y + input_height * 0.7,
                };

                const text_paint = Paint{
                    .color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                };

                renderer.vtable.drawText(renderer, current_text, text_position, text_paint);
            }

            // Draw cursor if focused
            if (is_active) {
                const cursor_x = rect.x + self.im_padding / 2 +
                    @as(f32, @floatFromInt(current_text.len)) * 8.0; // Approximate char width
                const cursor_rect = Rect{
                    .x = cursor_x,
                    .y = rect.y + 4,
                    .width = 2,
                    .height = input_height - 8,
                };

                const cursor_color = Color{ .r = 200, .g = 200, .b = 255, .a = 255 };
                renderer.vtable.drawRect(renderer, cursor_rect, Paint{ .color = cursor_color });
            }
        }

        // Advance cursor
        self.im_cursor_x += input_width + self.im_spacing;

        // Wrap if too wide
        const window_width: f32 = @floatFromInt(self.config.window_width);
        if (self.im_cursor_x > window_width - self.im_padding) {
            self.newLine();
        }

        return focused;
    }

    /// Begin a horizontal layout group
    pub fn beginRow(self: *GUI) void {
        // Row is the default, so just reset to start of line
        self.im_cursor_x = self.im_padding;
    }

    /// End a horizontal layout group
    pub fn endRow(self: *GUI) void {
        self.newLine();
    }

    /// Container configuration
    pub const ContainerConfig = struct {
        padding: f32 = 8,
        background_color: ?Color = null,
        border_color: ?Color = null,
        border_width: f32 = 0,
        border_radius: f32 = 0,
    };

    /// Begin a container group
    /// Containers provide visual grouping and padding for child widgets
    pub fn beginContainer(self: *GUI, config: ContainerConfig) void {
        // Save current cursor position (container top-left)
        const container_x = self.im_cursor_x;
        const container_y = self.im_cursor_y;

        // Apply container padding
        self.im_cursor_x += config.padding;
        self.im_cursor_y += config.padding;

        // Store container info for endContainer
        // For now, we'll just track the padding amount
        // A full implementation would use a stack for nested containers
        _ = container_x;
        _ = container_y;
    }

    /// End a container group
    /// Draws the container background and border if configured
    pub fn endContainer(self: *GUI, config: ContainerConfig) void {
        // For now, just apply bottom padding
        self.im_cursor_y += config.padding;
        self.newLine();

        // TODO: Draw container background/border
        // This would require tracking container bounds from beginContainer
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    // /// Paint a view and its children
    // /// Removed - moving to immediate-mode API
    // fn paintView(self: *GUI, view: *View, context: *const RenderContext) void {
    //     // Skip if not visible
    //     if (!view.isVisible()) return;
    //
    //     // Save renderer state
    //     if (self.renderer) |renderer| {
    //         renderer.vtable.save(renderer);
    //         renderer.vtable.clip(renderer, view.rect);
    //     }
    //
    //     // Paint view
    //     view.vtable.paint(view, context);
    //
    //     // Paint children
    //     for (view.children.items) |child| {
    //         self.paintView(child, context);
    //     }
    //
    //     // Restore renderer state
    //     if (self.renderer) |renderer| {
    //         renderer.vtable.restore(renderer);
    //     }
    // }
};

// ============================================================================
// Tests
// ============================================================================

test "GUI immediate-mode ID generation" {
    // Test that IDs are unique for different labels
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    const id1 = gui.generateId("button1");
    const id2 = gui.generateId("button2");
    const id3 = gui.generateId("button1"); // Same label, different counter

    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != id3); // Different because counter advanced
}

test "GUI point in rect" {
    const rect = Rect{ .x = 10, .y = 10, .width = 100, .height = 50 };

    // Inside
    try std.testing.expect(GUI.pointInRect(50, 30, rect));

    // Outside
    try std.testing.expect(!GUI.pointInRect(5, 5, rect));
    try std.testing.expect(!GUI.pointInRect(150, 30, rect));
    try std.testing.expect(!GUI.pointInRect(50, 100, rect));
}

test "GUI button interaction" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Initially, no button is clicked
    const clicked1 = try gui.button("Test Button");
    try std.testing.expect(!clicked1);

    // Simulate mouse over button (approximate position)
    gui.setMousePosition(50, 12);

    // Mouse down - button should not click yet
    gui.setMouseButton(true);
    const clicked2 = try gui.button("Test Button");
    try std.testing.expect(!clicked2);

    // Mouse up - button should click
    gui.setMouseButton(false);

    try gui.endFrame();
}

test "GUI text rendering" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Text should render without error
    try gui.text("Hello, {s}!", .{"World"});

    // Cursor should advance
    const cursor_before = gui.im_cursor_x;
    gui.textRaw("More text");
    const cursor_after = gui.im_cursor_x;

    try std.testing.expect(cursor_after > cursor_before);

    try gui.endFrame();
}

test "GUI checkbox toggling" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Initially unchecked, not toggled
    const toggled1 = try gui.checkbox(false);
    try std.testing.expect(!toggled1);

    // Simulate click on checkbox
    gui.setMousePosition(10, 10); // Approximate checkbox position
    gui.setMouseButton(true);
    const toggled2 = try gui.checkbox(false);
    try std.testing.expect(!toggled2); // Not toggled yet (mouse still down)

    try gui.endFrame();
}

test "GUI container padding" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    const cursor_before = gui.im_cursor_x;

    // Begin container with padding
    gui.beginContainer(.{ .padding = 20 });

    // Cursor should be offset by padding
    try std.testing.expectEqual(cursor_before + 20, gui.im_cursor_x);

    // End container
    gui.endContainer(.{ .padding = 20 });

    try gui.endFrame();
}

test "GUI row layout" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    gui.beginRow();

    // Add widgets horizontally
    try gui.text("Label:", .{});
    const button_x = gui.im_cursor_x;
    _ = try gui.button("Click");
    const after_button_x = gui.im_cursor_x;

    // Button should be positioned after label
    try std.testing.expect(after_button_x > button_x);

    gui.endRow();

    // After row, should be on new line
    try std.testing.expect(gui.im_cursor_x == gui.im_padding);

    try gui.endFrame();
}

test "GUI text input focus" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    var buffer: [256]u8 = undefined;

    // Initially not focused
    const focused1 = try gui.textInput(&buffer, "Hello", .{});
    try std.testing.expect(!focused1);

    // Click on text input (approximate position)
    gui.setMousePosition(100, 12);
    gui.setMouseButton(true);
    _ = try gui.textInput(&buffer, "Hello", .{});

    // Release mouse - should become focused
    gui.setMouseButton(false);

    try gui.endFrame();
}
