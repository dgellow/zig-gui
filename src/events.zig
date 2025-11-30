const std = @import("std");
const Point = @import("core/geometry.zig").Point;
const Rect = @import("core/geometry.zig").Rect;

/// Event types that can be dispatched through the UI
pub const EventType = enum {
    // Mouse events
    mouse_down,
    mouse_up,
    mouse_move,
    mouse_enter,
    mouse_leave,
    click,
    double_click,

    // Touch events
    touch_down,
    touch_up,
    touch_move,

    // Keyboard events
    key_down,
    key_up,
    char_input,

    // Focus events
    focus,
    blur,

    // Drag events
    drag_start,
    drag,
    drag_end,
    drop,

    // Scroll events
    scroll,

    // Component events
    resize,

    // UI events
    value_change,
    selection_change,

    // Special events
    custom,
};

/// Input event from platform input system
pub const InputEvent = union(enum) {
    mouse: MouseEvent,
    key: KeyEvent,
    touch: TouchEvent,
    scroll: ScrollEvent,
    text: TextEvent,

    pub const MouseEvent = struct {
        action: MouseAction,
        button: MouseButton,
        position: Point,
        modifiers: KeyModifiers,
        timestamp: u64,
    };

    pub const KeyEvent = struct {
        action: KeyAction,
        key: Key,
        modifiers: KeyModifiers,
        timestamp: u64,
    };

    pub const TouchEvent = struct {
        action: TouchAction,
        pointer_id: u32,
        position: Point,
        timestamp: u64,
    };

    pub const ScrollEvent = struct {
        delta_x: f32,
        delta_y: f32,
        position: Point,
        timestamp: u64,
    };

    pub const TextEvent = struct {
        text: []const u8,
        timestamp: u64,
    };
};

/// Enum for mouse buttons
pub const MouseButton = enum {
    left,
    right,
    middle,
    x1,
    x2,
};

/// Enum for key actions
pub const KeyAction = enum {
    press,
    release,
    repeat,
};

/// Enum for mouse actions
pub const MouseAction = enum {
    press,
    release,
    move,
};

/// Enum for touch actions
pub const TouchAction = enum {
    down,
    up,
    move,
    cancel,
};

/// Key codes (simplified)
pub const Key = enum {
    unknown,

    // Alphabet
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // Numbers
    n0,
    n1,
    n2,
    n3,
    n4,
    n5,
    n6,
    n7,
    n8,
    n9,

    // Function keys
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Special keys
    escape,
    tab,
    caps_lock,
    shift,
    ctrl,
    alt,
    space,
    enter,
    backspace,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    left,
    right,
    up,
    down,
};

/// Keyboard modifier flags
pub const KeyModifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn none() KeyModifiers {
        return .{};
    }
};

/// The event manager responsible for processing platform input events
/// and maintaining current input state for immediate-mode GUI
pub const EventManager = struct {
    allocator: std.mem.Allocator,

    // Raw input events from platform (queued for processing)
    input_events: std.ArrayList(InputEvent),

    // Current input state (for immediate-mode widget queries)
    mouse_position: Point = .{ .x = 0, .y = 0 },
    mouse_buttons: [5]bool = [_]bool{false} ** 5, // indexed by MouseButton enum
    keys_down: std.AutoHashMap(Key, bool),
    modifiers: KeyModifiers = .{},

    // Text input accumulator (cleared each frame)
    text_buffer: std.ArrayList(u8),

    // Widget focus tracking (by ID hash, not pointer)
    focused_widget: ?u64 = null,

    // Timestamp counter
    timestamp_counter: u64 = 0,

    /// Initialize a new event manager
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*EventManager {
        const manager = try allocator.create(EventManager);
        errdefer allocator.destroy(manager);

        manager.* = .{
            .allocator = allocator,
            .input_events = std.ArrayList(InputEvent).init(allocator),
            .keys_down = std.AutoHashMap(Key, bool).init(allocator),
            .text_buffer = std.ArrayList(u8).init(allocator),
        };

        // Pre-allocate capacity for events
        try manager.input_events.ensureTotalCapacity(capacity);
        try manager.text_buffer.ensureTotalCapacity(256);

        return manager;
    }

    /// Free all resources used by the event manager
    pub fn deinit(self: *EventManager) void {
        self.input_events.deinit();
        self.keys_down.deinit();
        self.text_buffer.deinit();
        self.allocator.destroy(self);
    }

    /// Process all queued input events and update current state
    pub fn processEvents(self: *EventManager) void {
        // Clear text buffer from previous frame
        self.text_buffer.clearRetainingCapacity();

        // Process raw input events and update state
        for (self.input_events.items) |event| {
            switch (event) {
                .mouse => |mouse_event| {
                    self.mouse_position = mouse_event.position;
                    self.modifiers = mouse_event.modifiers;

                    const button_index = @intFromEnum(mouse_event.button);
                    switch (mouse_event.action) {
                        .press => self.mouse_buttons[button_index] = true,
                        .release => self.mouse_buttons[button_index] = false,
                        .move => {}, // Position already updated
                    }
                },
                .key => |key_event| {
                    self.modifiers = key_event.modifiers;

                    const is_down = key_event.action == .press or key_event.action == .repeat;
                    self.keys_down.put(key_event.key, is_down) catch {
                        std.log.err("Failed to update key state", .{});
                    };
                },
                .touch => |touch_event| {
                    _ = touch_event;
                    // TODO: Implement touch event handling
                },
                .scroll => |scroll_event| {
                    _ = scroll_event;
                    // TODO: Implement scroll event handling
                },
                .text => |text_event| {
                    self.text_buffer.appendSlice(text_event.text) catch {
                        std.log.err("Failed to append text input", .{});
                    };
                },
            }
        }

        self.input_events.clearRetainingCapacity();
    }

    /// Add a platform-specific event for processing
    pub fn addPlatformEvent(self: *EventManager, platform_event: anytype) void {
        const input_event = self.convertPlatformEvent(platform_event);
        if (input_event) |event| {
            self.addInputEvent(event);
        }
    }

    /// Add a raw input event for processing
    pub fn addInputEvent(self: *EventManager, event: InputEvent) void {
        self.input_events.append(event) catch {
            std.log.err("Failed to add input event", .{});
        };
    }

    // =========================================================================
    // Query API for immediate-mode widgets
    // =========================================================================

    /// Get current mouse position
    pub inline fn getMousePosition(self: *const EventManager) Point {
        return self.mouse_position;
    }

    /// Check if a mouse button is currently pressed
    pub inline fn isMouseButtonDown(self: *const EventManager, button: MouseButton) bool {
        return self.mouse_buttons[@intFromEnum(button)];
    }

    /// Check if a key is currently pressed
    pub inline fn isKeyDown(self: *const EventManager, key: Key) bool {
        return self.keys_down.get(key) orelse false;
    }

    /// Get current keyboard modifiers
    pub inline fn getModifiers(self: *const EventManager) KeyModifiers {
        return self.modifiers;
    }

    /// Get text input from this frame (for text input widgets)
    pub inline fn getTextInput(self: *const EventManager) []const u8 {
        return self.text_buffer.items;
    }

    /// Set focused widget (by ID hash)
    pub fn setFocus(self: *EventManager, widget_id: ?u64) void {
        self.focused_widget = widget_id;
    }

    /// Get currently focused widget ID
    pub inline fn getFocusedWidget(self: *const EventManager) ?u64 {
        return self.focused_widget;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// Convert a platform-specific event to our internal InputEvent format
    fn convertPlatformEvent(self: *EventManager, platform_event: anytype) ?InputEvent {
        // This needs to be implemented for each platform integration
        // For SDL, this would convert SDL_Event to InputEvent
        // For now, return null as a placeholder
        _ = self;
        _ = platform_event;
        return null;
    }

    /// Get a timestamp for events
    fn getTimestamp(self: *EventManager) u64 {
        self.timestamp_counter += 1;
        return self.timestamp_counter;
    }
};
