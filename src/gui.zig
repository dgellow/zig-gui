const std = @import("std");
const RenderContext = @import("renderer.zig").RenderContext;
const RendererInterface = @import("renderer.zig").RendererInterface;
const Color = @import("core/color.zig").Color;
const Rect = @import("core/geometry.zig").Rect;
const Point = @import("core/geometry.zig").Point;
const Size = @import("core/geometry.zig").Size;
const Paint = @import("core/paint.zig").Paint;
const LayoutEngine = @import("layout.zig").LayoutEngine;
const FlexStyle = @import("layout.zig").FlexStyle;
const StyleSystem = @import("style.zig").StyleSystem;
const EventManager = @import("events.zig").EventManager;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const AssetManager = @import("asset.zig").AssetManager;
const WidgetId = @import("widget_id.zig").WidgetId;
const IdStack = @import("widget_id.zig").IdStack;
const profiler = @import("profiler.zig");

// Draw system imports
const draw = @import("draw.zig");
const DrawList = draw.DrawList;
const DrawData = draw.DrawData;

/// Maximum number of widgets (matches layout engine)
const MAX_WIDGETS = @import("layout/engine.zig").MAX_ELEMENTS;

/// Widget type enumeration for metadata
const WidgetType = enum(u8) {
    root,
    container,
    button,
    text,
    checkbox,
    text_input,
    separator,
};

/// Metadata for each widget (for reconciliation)
const WidgetMeta = struct {
    parent_hash: u32 = 0, // Parent's widget ID hash
    sibling_order: u16 = 0, // Position among siblings
    widget_type: WidgetType = .root,
};

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
    im_clicked_id: u64 = 0, // Widget clicked this frame (0 = none)

    /// Text formatting buffer (for fmt args)
    im_text_buffer: [1024]u8 = undefined,

    // =========================================================================
    // Immediate Mode Reconciliation (bridges immediate API with retained layout)
    // =========================================================================

    /// Widget ID → Layout index mapping (persistent across frames)
    widget_to_layout: std.AutoHashMap(u32, u32),

    /// Layout index → Widget metadata (for parent tracking, reordering)
    widget_meta: [MAX_WIDGETS]WidgetMeta = [_]WidgetMeta{.{}} ** MAX_WIDGETS,

    /// Which layout indices were "seen" this frame
    seen_this_frame: std.StaticBitSet(MAX_WIDGETS) = std.StaticBitSet(MAX_WIDGETS).initEmpty(),

    /// ID stack for hierarchical widget scoping
    id_stack: IdStack = IdStack.init(null),

    /// Current parent stack (layout indices)
    parent_stack: std.BoundedArray(u32, 64) = .{},

    /// Root widget ID (created once)
    root_layout_index: ?u32 = null,

    // =========================================================================
    // Draw System (BYOR - Bring Your Own Renderer)
    // =========================================================================

    /// Draw command list - accumulates rendering commands during widget calls
    draw_list: DrawList,

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
            .widget_to_layout = std.AutoHashMap(u32, u32).init(allocator),
            .draw_list = DrawList.init(allocator),
        };

        return gui;
    }

    /// Clean up all resources used by the GUI
    pub fn deinit(self: *GUI) void {
        // Clean up draw system
        self.draw_list.deinit();

        // Clean up reconciliation structures
        self.widget_to_layout.deinit();
        self.id_stack.deinit();

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

        // Clear draw list for new frame
        self.draw_list.clear();

        // Reset immediate-mode cursor
        self.im_cursor_x = self.im_padding;
        self.im_cursor_y = self.im_padding;

        // Clear hot ID (will be set during rendering)
        self.im_hot_id = 0;

        // Clear clicked ID from previous frame
        self.im_clicked_id = 0;

        // === Immediate Mode Reconciliation ===
        // Clear the "seen this frame" tracking
        self.seen_this_frame = std.StaticBitSet(MAX_WIDGETS).initEmpty();

        // Clear ID stack for fresh frame
        self.id_stack.clear();

        // Reset parent stack with root
        self.parent_stack.len = 0;

        // Ensure root element exists
        if (self.root_layout_index == null) {
            const root_index = try self.layout_engine.addElement(null, .{
                .direction = .column,
                .width = @floatFromInt(self.config.window_width),
                .height = @floatFromInt(self.config.window_height),
            });
            self.root_layout_index = root_index;
            try self.widget_to_layout.put(0, root_index); // Hash 0 = root
        }

        // Start with root as current parent
        self.parent_stack.appendAssumeCapacity(self.root_layout_index.?);
        self.seen_this_frame.set(self.root_layout_index.?);

        // Begin layout frame
        self.layout_engine.beginFrame();

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

        // === Immediate Mode Reconciliation ===
        // Remove widgets that weren't seen this frame
        {
            profiler.zone(@src(), "GUI.reconcileWidgets", .{});
            defer profiler.endZone();

            var to_remove = std.ArrayList(u32).init(self.allocator);
            defer to_remove.deinit();

            var iter = self.widget_to_layout.iterator();
            while (iter.next()) |entry| {
                const layout_index = entry.value_ptr.*;
                if (!self.seen_this_frame.isSet(layout_index)) {
                    to_remove.append(entry.key_ptr.*) catch {};
                }
            }

            for (to_remove.items) |widget_hash| {
                if (self.widget_to_layout.get(widget_hash)) |layout_index| {
                    self.layout_engine.removeElement(layout_index);
                    _ = self.widget_to_layout.remove(widget_hash);
                }
            }
        }

        // Compute layout for dirty elements
        {
            profiler.zone(@src(), "GUI.computeLayout", .{});
            defer profiler.endZone();

            const frame_width: f32 = @floatFromInt(self.config.window_width);
            const frame_height: f32 = @floatFromInt(self.config.window_height);
            try self.layout_engine.computeLayout(frame_width, frame_height);
        }

        // Render if we have a renderer
        if (self.renderer) |renderer| {
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
    // Draw System Output (BYOR - Bring Your Own Renderer)
    // =========================================================================

    /// Get draw data for rendering with a custom backend.
    ///
    /// Call this after endFrame() to get the accumulated draw commands
    /// for rendering with any BYOR-compatible backend.
    ///
    /// Example:
    /// ```zig
    /// gui.beginFrame();
    /// // ... widget calls ...
    /// gui.endFrame();
    ///
    /// const draw_data = gui.getDrawData();
    /// my_backend.render(&draw_data);
    /// ```
    pub fn getDrawData(self: *const GUI) DrawData {
        return DrawData{
            .commands = self.draw_list.getCommands(),
            .display_size = Size{
                .width = @floatFromInt(self.config.window_width),
                .height = @floatFromInt(self.config.window_height),
            },
        };
    }

    /// Get the number of draw commands accumulated this frame.
    /// Useful for debugging and performance monitoring.
    pub fn getDrawCommandCount(self: *const GUI) usize {
        return self.draw_list.commandCount();
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
    // Widget ID Management (for immediate-mode reconciliation)
    // =========================================================================

    /// Push an ID scope onto the stack (comptime version - zero cost)
    pub fn pushId(self: *GUI, comptime label: []const u8) void {
        self.id_stack.push(label);
    }

    /// Push an index onto the ID stack (for loops)
    pub fn pushIndex(self: *GUI, index: usize) void {
        self.id_stack.pushIndex(index);
    }

    /// Pop the most recent ID from the stack
    pub fn popId(self: *GUI) void {
        self.id_stack.pop();
    }

    /// Get or create a layout element for a widget
    /// Returns the layout index for the widget
    fn getOrCreateElement(self: *GUI, widget_hash: u32, widget_type: WidgetType, style: FlexStyle) !u32 {
        const current_parent_layout = if (self.parent_stack.len > 0)
            self.parent_stack.buffer[self.parent_stack.len - 1]
        else
            self.root_layout_index orelse 0;

        const current_parent_hash = self.id_stack.getCurrentHash();

        if (self.widget_to_layout.get(widget_hash)) |existing_index| {
            // Widget exists - check if parent changed (re-parenting needed)
            const meta = &self.widget_meta[existing_index];
            if (meta.parent_hash != current_parent_hash) {
                // Re-parent the widget
                self.layout_engine.reparent(existing_index, current_parent_layout);
                meta.parent_hash = current_parent_hash;
            }

            // Update style if needed
            self.layout_engine.setStyle(existing_index, style);

            // Mark as seen
            self.seen_this_frame.set(existing_index);
            return existing_index;
        }

        // New widget - create layout element
        const new_index = try self.layout_engine.addElement(current_parent_layout, style);

        try self.widget_to_layout.put(widget_hash, new_index);
        self.widget_meta[new_index] = .{
            .parent_hash = current_parent_hash,
            .sibling_order = 0,
            .widget_type = widget_type,
        };

        // Mark as seen
        self.seen_this_frame.set(new_index);

        return new_index;
    }

    /// Get the computed rect for a widget by its hash
    pub fn getWidgetRect(self: *GUI, widget_hash: u32) ?Rect {
        if (self.widget_to_layout.get(widget_hash)) |layout_index| {
            return self.layout_engine.getRect(layout_index);
        }
        return null;
    }

    // =========================================================================
    // Container API (design-aligned: auto ID scope push)
    // =========================================================================

    /// Begin a container with comptime label - auto-pushes ID scope
    /// Children inherit this container's scope automatically.
    ///
    /// Example:
    /// ```zig
    /// gui.begin("toolbar", .{ .direction = .row });
    /// defer gui.end();
    /// if (gui.button("file")) { ... }  // ID: toolbar ^ file
    /// ```
    pub fn begin(self: *GUI, comptime label: []const u8, style: FlexStyle) void {
        self.beginCore(comptime WidgetId.from(label).hash, style);
    }

    /// Begin a container with index - for loops
    ///
    /// Example:
    /// ```zig
    /// for (items, 0..) |item, i| {
    ///     gui.beginIndexed("item", i, .{ .height = 40 });
    ///     defer gui.end();
    ///     // ...
    /// }
    /// ```
    pub fn beginIndexed(self: *GUI, comptime label: []const u8, index: usize, style: FlexStyle) void {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        self.beginCore(indexed_hash, style);
    }

    /// Begin a container with runtime string - for dynamic content
    pub fn beginDynamic(self: *GUI, label: []const u8, style: FlexStyle) void {
        self.beginCore(WidgetId.runtime(label).hash, style);
    }

    /// Begin a container with pre-computed ID - for C API interop
    pub fn beginById(self: *GUI, id: u32, style: FlexStyle) void {
        self.beginCore(id, style);
    }

    /// Core container begin - takes pre-computed hash
    fn beginCore(self: *GUI, id_hash: u32, style: FlexStyle) void {
        // Combine with current scope
        const final_id = self.id_stack.combine(id_hash);

        // Create/update layout element
        const layout_idx = self.getOrCreateElement(final_id, .container, style) catch return;

        // Push ID scope (so children inherit this container's scope)
        self.id_stack.pushHash(id_hash);

        // Push as current parent (so children are laid out inside this container)
        self.parent_stack.append(layout_idx) catch return;
    }

    /// End a container - pops ID scope and parent stack
    pub fn end(self: *GUI) void {
        // Pop parent stack
        if (self.parent_stack.len > 0) {
            self.parent_stack.len -= 1;
        }

        // Pop ID scope
        self.id_stack.pop();
    }

    // =========================================================================
    // Widget API (design-aligned: comptime labels with variants)
    // =========================================================================

    /// Create a widget with comptime label - zero runtime cost
    pub fn widget(self: *GUI, comptime label: []const u8, style: FlexStyle) !void {
        return self.widgetCore(comptime WidgetId.from(label).hash, style);
    }

    /// Create a widget with index - for loops
    pub fn widgetIndexed(self: *GUI, comptime label: []const u8, index: usize, style: FlexStyle) !void {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        return self.widgetCore(indexed_hash, style);
    }

    /// Create a widget with runtime string - for dynamic content
    pub fn widgetDynamic(self: *GUI, label: []const u8, style: FlexStyle) !void {
        return self.widgetCore(WidgetId.runtime(label).hash, style);
    }

    /// Create a widget with pre-computed ID - for C API interop
    pub fn widgetById(self: *GUI, id: u32, style: FlexStyle) !void {
        return self.widgetCore(id, style);
    }

    /// Core widget creation - takes pre-computed hash
    fn widgetCore(self: *GUI, id_hash: u32, style: FlexStyle) !void {
        const final_id = self.id_stack.combine(id_hash);
        _ = try self.getOrCreateElement(final_id, .container, style);
    }

    // =========================================================================
    // Immediate-Mode Rendering Helpers
    // =========================================================================

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

        const position = Point{
            .x = self.im_cursor_x,
            .y = self.im_cursor_y + text_height * 0.75, // Baseline offset
        };

        const text_color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

        // Emit to draw list (new BYOR system)
        self.draw_list.addText(position, str, text_color);

        // Also draw via legacy renderer if present
        if (self.renderer) |renderer| {
            renderer.vtable.drawText(renderer, str, position, Paint{ .color = text_color });
        }

        // Advance cursor
        self.im_cursor_x += text_width + self.im_spacing;

        // Wrap if too wide
        const window_width: f32 = @floatFromInt(self.config.window_width);
        if (self.im_cursor_x > window_width - self.im_padding) {
            self.newLine();
        }
    }

    /// Declare a button widget with comptime label.
    /// Use wasClicked() to check if it was clicked.
    ///
    /// Example:
    /// ```zig
    /// gui.button("Click me");
    /// if (gui.wasClicked("Click me")) {
    ///     state.counter.set(state.counter.get() + 1);
    /// }
    /// ```
    pub fn button(self: *GUI, comptime label: []const u8) void {
        self.buttonCore(comptime WidgetId.from(label).hash, label);
    }

    /// Declare a button with index - for loops
    pub fn buttonIndexed(self: *GUI, comptime label: []const u8, index: usize) void {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        self.buttonCore(indexed_hash, label);
    }

    /// Declare a button with runtime string - for dynamic content
    pub fn buttonDynamic(self: *GUI, label: []const u8) void {
        self.buttonCore(WidgetId.runtime(label).hash, label);
    }

    /// Declare a button with pre-computed ID - for C API interop
    pub fn buttonById(self: *GUI, id: u32, display_label: []const u8) void {
        self.buttonCore(id, display_label);
    }

    /// Core button implementation - takes pre-computed hash
    fn buttonCore(self: *GUI, id_hash: u32, display_label: []const u8) void {
        // Combine with current ID scope
        const final_id: u64 = self.id_stack.combine(id_hash);

        // Calculate button dimensions
        const char_width: f32 = 8;
        const text_width = @as(f32, @floatFromInt(display_label.len)) * char_width;
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
            self.im_hot_id = final_id;
        }

        // Handle interaction
        const is_active = self.im_active_id == final_id;

        if (is_hot) {
            if (self.mousePressed()) {
                self.im_active_id = final_id;
            }
        }

        if (is_active and is_hot and self.mouseClicked()) {
            self.im_clicked_id = final_id;
        }

        // Determine colors based on state
        const bg_color = if (is_active and is_hot)
            Color{ .r = 80, .g = 80, .b = 120, .a = 255 } // Pressed
        else if (is_hot)
            Color{ .r = 70, .g = 70, .b = 100, .a = 255 } // Hover
        else
            Color{ .r = 50, .g = 50, .b = 80, .a = 255 }; // Normal

        const text_color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

        const text_position = Point{
            .x = rect.x + self.im_padding,
            .y = rect.y + button_height * 0.7,
        };

        // Emit to draw list (new BYOR system)
        self.draw_list.addFilledRectEx(rect, bg_color, 4.0);
        self.draw_list.addText(text_position, display_label, text_color);

        // Also draw via legacy renderer if present
        if (self.renderer) |renderer| {
            renderer.vtable.drawRoundRect(renderer, rect, 4.0, Paint{ .color = bg_color });
            renderer.vtable.drawText(renderer, display_label, text_position, Paint{ .color = text_color });
        }

        // Advance cursor
        self.im_cursor_x += button_width + self.im_spacing;

        // Wrap if too wide
        const window_width: f32 = @floatFromInt(self.config.window_width);
        if (self.im_cursor_x > window_width - self.im_padding) {
            self.newLine();
        }
    }

    // =========================================================================
    // Interaction Query Functions
    // =========================================================================

    /// Check if widget with comptime label was clicked this frame
    pub fn wasClicked(self: *const GUI, comptime label: []const u8) bool {
        const id: u64 = self.id_stack.combine(comptime WidgetId.from(label).hash);
        return self.im_clicked_id == id and id != 0;
    }

    /// Check if widget with index was clicked this frame
    pub fn wasClickedIndexed(self: *const GUI, comptime label: []const u8, index: usize) bool {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        const id: u64 = self.id_stack.combine(indexed_hash);
        return self.im_clicked_id == id and id != 0;
    }

    /// Check if widget with runtime string was clicked this frame
    pub fn wasClickedDynamic(self: *const GUI, label: []const u8) bool {
        const id: u64 = self.id_stack.combine(WidgetId.runtime(label).hash);
        return self.im_clicked_id == id and id != 0;
    }

    /// Check if widget with pre-computed ID was clicked this frame
    pub fn wasClickedId(self: *const GUI, id_hash: u32) bool {
        const id: u64 = self.id_stack.combine(id_hash);
        return self.im_clicked_id == id and id != 0;
    }

    /// Check if widget with comptime label is hovered
    pub fn isHovered(self: *const GUI, comptime label: []const u8) bool {
        const id: u64 = self.id_stack.combine(comptime WidgetId.from(label).hash);
        return self.im_hot_id == id and id != 0;
    }

    /// Check if widget with index is hovered
    pub fn isHoveredIndexed(self: *const GUI, comptime label: []const u8, index: usize) bool {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        const id: u64 = self.id_stack.combine(indexed_hash);
        return self.im_hot_id == id and id != 0;
    }

    /// Check if widget with runtime string is hovered
    pub fn isHoveredDynamic(self: *const GUI, label: []const u8) bool {
        const id: u64 = self.id_stack.combine(WidgetId.runtime(label).hash);
        return self.im_hot_id == id and id != 0;
    }

    /// Check if widget with pre-computed ID is hovered
    pub fn isHoveredId(self: *const GUI, id_hash: u32) bool {
        const id: u64 = self.id_stack.combine(id_hash);
        return self.im_hot_id == id and id != 0;
    }

    /// Check if widget with comptime label is being pressed
    pub fn isPressed(self: *const GUI, comptime label: []const u8) bool {
        const id: u64 = self.id_stack.combine(comptime WidgetId.from(label).hash);
        return self.im_active_id == id and id != 0;
    }

    /// Check if widget with index is being pressed
    pub fn isPressedIndexed(self: *const GUI, comptime label: []const u8, index: usize) bool {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        const id: u64 = self.id_stack.combine(indexed_hash);
        return self.im_active_id == id and id != 0;
    }

    /// Check if widget with runtime string is being pressed
    pub fn isPressedDynamic(self: *const GUI, label: []const u8) bool {
        const id: u64 = self.id_stack.combine(WidgetId.runtime(label).hash);
        return self.im_active_id == id and id != 0;
    }

    /// Check if widget with pre-computed ID is being pressed
    pub fn isPressedId(self: *const GUI, id_hash: u32) bool {
        const id: u64 = self.id_stack.combine(id_hash);
        return self.im_active_id == id and id != 0;
    }

    // =========================================================================
    // Checkbox Widget
    // =========================================================================

    /// Create a checkbox with comptime label
    pub fn checkbox(self: *GUI, comptime label: []const u8, checked: bool) bool {
        return self.checkboxCore(comptime WidgetId.from(label).hash, checked);
    }

    /// Create a checkbox with index - for loops
    pub fn checkboxIndexed(self: *GUI, comptime label: []const u8, index: usize, checked: bool) bool {
        const base_hash = comptime WidgetId.from(label).hash;
        const indexed_hash = base_hash ^ (@as(u32, @truncate(index)) +% 1) *% 0x9e3779b9;
        return self.checkboxCore(indexed_hash, checked);
    }

    /// Core checkbox implementation
    fn checkboxCore(self: *GUI, id_hash: u32, checked: bool) bool {
        const final_id: u64 = self.id_stack.combine(id_hash);

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
            self.im_hot_id = final_id;
        }

        // Handle interaction
        var toggled = false;
        const is_active = self.im_active_id == final_id;

        if (is_hot) {
            if (self.mousePressed()) {
                self.im_active_id = final_id;
            }
        }

        if (is_active and is_hot and self.mouseClicked()) {
            toggled = true;
        }

        // Determine colors based on state
        const bg_color = if (is_hot)
            Color{ .r = 70, .g = 70, .b = 100, .a = 255 }
        else
            Color{ .r = 50, .g = 50, .b = 80, .a = 255 };

        // Emit to draw list (new BYOR system)
        self.draw_list.addFilledRectEx(rect, bg_color, 3.0);

        if (checked) {
            const inner_rect = Rect{
                .x = rect.x + 4,
                .y = rect.y + 4,
                .width = size - 8,
                .height = size - 8,
            };
            const check_color = Color{ .r = 100, .g = 200, .b = 100, .a = 255 };
            self.draw_list.addFilledRectEx(inner_rect, check_color, 2.0);
        }

        // Also draw via legacy renderer if present
        if (self.renderer) |renderer| {
            renderer.vtable.drawRoundRect(renderer, rect, 3.0, Paint{ .color = bg_color });

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

        const color = Color{ .r = 80, .g = 80, .b = 100, .a = 255 };

        // Emit to draw list (new BYOR system)
        self.draw_list.addFilledRect(rect, color);

        // Also draw via legacy renderer if present
        if (self.renderer) |renderer| {
            renderer.vtable.drawRect(renderer, rect, Paint{ .color = color });
        }

        self.im_cursor_y += self.im_spacing;
    }

    /// Text input configuration
    pub const TextInputConfig = struct {
        width: f32 = 200,
        max_length: usize = 256,
    };

    /// Create a text input field with comptime label
    /// Returns true if the input is focused (clicked)
    ///
    /// Note: Full keyboard input requires keyboard event handling (not yet implemented)
    /// For now, this renders the input box and detects focus
    ///
    /// Example:
    /// ```zig
    /// var buffer: [256]u8 = undefined;
    /// const focused = gui.textInput("my_input", &buffer, state.text.get(), .{});
    /// if (focused) {
    ///     // Handle keyboard input when event system supports it
    /// }
    /// ```
    pub fn textInput(self: *GUI, comptime label: []const u8, buffer: []u8, current_text: []const u8, config: TextInputConfig) bool {
        return self.textInputCore(comptime WidgetId.from(label).hash, buffer, current_text, config);
    }

    /// Core text input implementation
    fn textInputCore(self: *GUI, id_hash: u32, buffer: []u8, current_text: []const u8, config: TextInputConfig) bool {
        _ = buffer;
        const id: u64 = self.id_stack.combine(id_hash);

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

        // Determine colors based on state
        const bg_color = if (is_active)
            Color{ .r = 60, .g = 60, .b = 90, .a = 255 } // Focused
        else if (is_hot)
            Color{ .r = 55, .g = 55, .b = 85, .a = 255 } // Hover
        else
            Color{ .r = 40, .g = 40, .b = 70, .a = 255 }; // Normal

        const text_color = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const cursor_color = Color{ .r = 200, .g = 200, .b = 255, .a = 255 };

        // Emit to draw list (new BYOR system)
        self.draw_list.addFilledRectEx(rect, bg_color, 3.0);

        if (current_text.len > 0) {
            const text_position = Point{
                .x = rect.x + self.im_padding / 2,
                .y = rect.y + input_height * 0.7,
            };
            self.draw_list.addText(text_position, current_text, text_color);
        }

        if (is_active) {
            const cursor_x = rect.x + self.im_padding / 2 +
                @as(f32, @floatFromInt(current_text.len)) * 8.0;
            const cursor_rect = Rect{
                .x = cursor_x,
                .y = rect.y + 4,
                .width = 2,
                .height = input_height - 8,
            };
            self.draw_list.addFilledRect(cursor_rect, cursor_color);
        }

        // Also draw via legacy renderer if present
        if (self.renderer) |renderer| {
            renderer.vtable.drawRoundRect(renderer, rect, 3.0, Paint{ .color = bg_color });

            if (current_text.len > 0) {
                const text_position = Point{
                    .x = rect.x + self.im_padding / 2,
                    .y = rect.y + input_height * 0.7,
                };
                renderer.vtable.drawText(renderer, current_text, text_position, Paint{ .color = text_color });
            }

            if (is_active) {
                const cursor_x = rect.x + self.im_padding / 2 +
                    @as(f32, @floatFromInt(current_text.len)) * 8.0;
                const cursor_rect = Rect{
                    .x = cursor_x,
                    .y = rect.y + 4,
                    .width = 2,
                    .height = input_height - 8,
                };
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

test "GUI point in rect" {
    const rect = Rect{ .x = 10, .y = 10, .width = 100, .height = 50 };

    // Inside
    try std.testing.expect(GUI.pointInRect(50, 30, rect));

    // Outside
    try std.testing.expect(!GUI.pointInRect(5, 5, rect));
    try std.testing.expect(!GUI.pointInRect(150, 30, rect));
    try std.testing.expect(!GUI.pointInRect(50, 100, rect));
}

test "GUI button with comptime label" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Initially, no button is clicked
    gui.button("Test Button");
    try std.testing.expect(!gui.wasClicked("Test Button"));

    // Simulate mouse over button (approximate position)
    gui.setMousePosition(50, 12);

    // Mouse down - button should not click yet (click happens on release)
    gui.setMouseButton(true);
    gui.button("Test Button 2");
    try std.testing.expect(!gui.wasClicked("Test Button 2"));

    // Mouse up - button state is tracked internally
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

test "GUI checkbox with comptime label" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Initially unchecked, not toggled
    const toggled1 = gui.checkbox("my_checkbox", false);
    try std.testing.expect(!toggled1);

    // Simulate click on checkbox
    gui.setMousePosition(10, 10); // Approximate checkbox position
    gui.setMouseButton(true);
    const toggled2 = gui.checkbox("my_checkbox", false);
    try std.testing.expect(!toggled2); // Not toggled yet (mouse still down)

    try gui.endFrame();
}

test "GUI begin/end container scoping" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Begin a container - should auto-push ID scope
    gui.begin("toolbar", .{ .direction = .row });

    // ID stack should have depth 1 (root + toolbar)
    try std.testing.expect(gui.id_stack.getDepth() == 1);

    // End container - should pop ID scope
    gui.end();

    // ID stack should be back to 0
    try std.testing.expect(gui.id_stack.getDepth() == 0);

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
    _ = gui.button("Click");
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
    const focused1 = gui.textInput("my_input", &buffer, "Hello", .{});
    try std.testing.expect(!focused1);

    // Click on text input (approximate position)
    gui.setMousePosition(100, 12);
    gui.setMouseButton(true);
    _ = gui.textInput("my_input", &buffer, "Hello", .{});

    // Release mouse - should become focused
    gui.setMouseButton(false);

    try gui.endFrame();
}

// ============================================================================
// Draw System Integration Tests
// ============================================================================

test "GUI emits draw commands for widgets" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    // Render some widgets
    try gui.text("Hello, World!", .{});
    gui.button("Click me");
    _ = gui.checkbox("my_checkbox", true);
    gui.separator();

    try gui.endFrame();

    // Should have accumulated draw commands
    const draw_data = gui.getDrawData();
    try std.testing.expect(!draw_data.isEmpty());

    // Count expected commands:
    // - text: 1 text command
    // - button: 1 filled rect + 1 text = 2 commands
    // - checkbox (checked): 1 filled rect + 1 inner rect = 2 commands
    // - separator: 1 filled rect
    // Total: 6 commands
    try std.testing.expectEqual(@as(usize, 6), draw_data.commandCount());
}

test "GUI draw commands have correct primitives" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    try gui.beginFrame();

    gui.button("Test");

    try gui.endFrame();

    const draw_data = gui.getDrawData();
    const commands = draw_data.commands;

    // Button emits: filled rect (background) + text (label)
    try std.testing.expectEqual(@as(usize, 2), commands.len);

    // First command should be a filled rect
    try std.testing.expect(commands[0].primitive == .fill_rect);

    // Second command should be text
    try std.testing.expect(commands[1].primitive == .text);
}

test "GUI draw list clears between frames" {
    const gui = try GUI.init(std.testing.allocator, .{});
    defer gui.deinit();

    // Frame 1
    try gui.beginFrame();
    gui.button("Button1");
    try gui.endFrame();
    const count1 = gui.getDrawCommandCount();

    // Frame 2 (with more widgets)
    try gui.beginFrame();
    gui.button("Button2");
    gui.button("Button3");
    try gui.endFrame();
    const count2 = gui.getDrawCommandCount();

    // Frame 2 should have more commands than frame 1
    // And frame 2 count should NOT include frame 1 commands
    try std.testing.expect(count2 > count1);
    try std.testing.expectEqual(@as(usize, 4), count2); // 2 buttons * 2 commands each
}

test "GUI + SoftwareBackend integration" {
    const gui = try GUI.init(std.testing.allocator, .{
        .window_width = 200,
        .window_height = 150,
    });
    defer gui.deinit();

    // Create software backend
    var backend = try draw.SoftwareBackend.initAlloc(std.testing.allocator, 200, 150);
    defer backend.deinit(std.testing.allocator);
    backend.clear_color = 0xFF1a1a2e; // Dark background

    // Render a frame with widgets
    try gui.beginFrame();
    gui.button("Hello");
    gui.separator();
    _ = gui.checkbox("check", true);
    try gui.endFrame();

    // Get draw data and render to software backend
    const draw_data = gui.getDrawData();
    const iface = backend.interface();

    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Verify pixels were rendered
    // Background should be dark (clear color)
    const bg_pixel = backend.getPixel(0, 0);
    try std.testing.expectEqual(@as(u32, 0xFF1a1a2e), bg_pixel);

    // Button should be at cursor position (im_padding=8, im_cursor_y=8)
    // Button background color is 0x323250 (RGB 50, 50, 80)
    const button_pixel = backend.getPixel(15, 15);
    try std.testing.expect(button_pixel != bg_pixel); // Something was drawn there
}

test "GUI display size matches config" {
    const gui = try GUI.init(std.testing.allocator, .{
        .window_width = 1920,
        .window_height = 1080,
    });
    defer gui.deinit();

    try gui.beginFrame();
    try gui.endFrame();

    const draw_data = gui.getDrawData();
    try std.testing.expectEqual(@as(f32, 1920), draw_data.display_size.width);
    try std.testing.expectEqual(@as(f32, 1080), draw_data.display_size.height);
}
