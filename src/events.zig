const std = @import("std");
const View = @import("components/view.zig").View;
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

/// Phase of event propagation
pub const EventPhase = enum {
    capture, // Top-down phase
    target, // At the target component
    bubble, // Bottom-up phase
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

/// UI event dispatched to components
pub const UIEvent = struct {
    type: EventType,
    phase: EventPhase,
    target: *View,
    current_target: *View,
    cancelled: bool = false,
    // Event-specific data stored as a tagged union
    data: EventData,
    timestamp: u64,

    /// Cancel event bubbling/capturing
    pub fn stopPropagation(self: *UIEvent) void {
        self.cancelled = true;
    }
};

/// Event data specific to different event types
pub const EventData = union(enum) {
    mouse: MouseData,
    key: KeyData,
    touch: TouchData,
    scroll: ScrollData,
    text: TextData,
    focus: FocusData,
    value: ValueData,
    custom: CustomData,

    pub const MouseData = struct {
        button: MouseButton,
        position: Point,
        modifiers: KeyModifiers,
    };

    pub const KeyData = struct {
        key: Key,
        modifiers: KeyModifiers,
    };

    pub const TouchData = struct {
        pointer_id: u32,
        position: Point,
    };

    pub const ScrollData = struct {
        delta_x: f32,
        delta_y: f32,
        position: Point,
    };

    pub const TextData = struct {
        text: []const u8,
    };

    pub const FocusData = struct {
        old_focus: ?*View,
    };

    pub const ValueData = struct {
        old_value: ?*anyopaque,
        new_value: ?*anyopaque,
        value_type_id: std.builtin.TypeId,
    };

    pub const CustomData = struct {
        data: ?*anyopaque,
        data_type_id: std.builtin.TypeId,
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

/// Event listener for custom event handling
pub const EventListener = struct {
    callback: *const fn (event: *UIEvent, context: ?*anyopaque) void,
    context: ?*anyopaque,
};

/// The event manager responsible for processing input and dispatching UI events
pub const EventManager = struct {
    allocator: std.mem.Allocator,

    input_events: std.ArrayList(InputEvent),
    ui_events: std.ArrayList(UIEvent),

    listeners: std.AutoHashMap(EventType, std.ArrayList(*EventListener)),

    focused_view: ?*View = null,
    hovered_view: ?*View = null,

    capture_view: ?*View = null,

    timestamp_counter: u64 = 0,

    /// Initialize a new event manager
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*EventManager {
        const manager = try allocator.create(EventManager);
        errdefer allocator.destroy(manager);

        manager.* = .{
            .allocator = allocator,
            .input_events = std.ArrayList(InputEvent).init(allocator),
            .ui_events = std.ArrayList(UIEvent).init(allocator),
            .listeners = std.AutoHashMap(EventType, std.ArrayList(*EventListener)).init(allocator),
            .focused_view = null,
            .hovered_view = null,
            .capture_view = null,
            .timestamp_counter = 0,
        };

        // Pre-allocate capacity for events
        try manager.input_events.ensureTotalCapacity(capacity);
        try manager.ui_events.ensureTotalCapacity(capacity);

        return manager;
    }

    /// Free all resources used by the event manager
    pub fn deinit(self: *EventManager) void {
        self.input_events.deinit();
        self.ui_events.deinit();

        // Free all listener arrays
        var listener_it = self.listeners.valueIterator();
        while (listener_it.next()) |listener_array| {
            listener_array.deinit();
        }
        self.listeners.deinit();

        self.allocator.destroy(self);
    }

    /// Process all queued input events and dispatch UI events
    pub fn processEvents(self: *EventManager) void {
        // Process raw input events
        for (self.input_events.items) |event| {
            self.processInputEvent(event);
        }
        self.input_events.clearRetainingCapacity();

        // Dispatch UI events
        for (self.ui_events.items) |*event| {
            self.dispatchUIEvent(event);
        }
        self.ui_events.clearRetainingCapacity();
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

    /// Add a UI event for dispatching
    pub fn addUIEvent(self: *EventManager, event: UIEvent) void {
        self.ui_events.append(event) catch {
            std.log.err("Failed to add UI event", .{});
        };
    }

    /// Register a listener for a specific event type
    pub fn addEventListener(self: *EventManager, event_type: EventType, listener: *EventListener) !void {
        var listeners_entry = try self.listeners.getOrPut(event_type);
        if (!listeners_entry.found_existing) {
            listeners_entry.value_ptr.* = std.ArrayList(*EventListener).init(self.allocator);
        }

        try listeners_entry.value_ptr.append(listener);
    }

    /// Remove a listener for a specific event type
    pub fn removeEventListener(self: *EventManager, event_type: EventType, listener: *EventListener) void {
        if (self.listeners.getEntry(event_type)) |entry| {
            var listeners = &entry.value_ptr.*;

            // Find and remove the listener
            for (listeners.items, 0..) |item, index| {
                if (item == listener) {
                    _ = listeners.orderedRemove(index);
                    break;
                }
            }
        }
    }

    /// Set the focus to a specific view
    pub fn setFocus(self: *EventManager, view: ?*View) void {
        if (self.focused_view == view) return;

        const old_focus = self.focused_view;
        self.focused_view = view;

        // Create blur event for old focus
        if (old_focus != null) {
            const blur_event = UIEvent{
                .type = .blur,
                .phase = .target,
                .target = old_focus.?,
                .current_target = old_focus.?,
                .data = .{ .focus = .{ .old_focus = view } },
                .timestamp = self.getTimestamp(),
            };
            self.addUIEvent(blur_event);
        }

        // Create focus event for new focus
        if (view != null) {
            const focus_event = UIEvent{
                .type = .focus,
                .phase = .target,
                .target = view.?,
                .current_target = view.?,
                .data = .{ .focus = .{ .old_focus = old_focus } },
                .timestamp = self.getTimestamp(),
            };
            self.addUIEvent(focus_event);
        }
    }

    /// Start mouse/touch capture on a specific view
    pub fn setCapture(self: *EventManager, view: ?*View) void {
        self.capture_view = view;
    }

    /// Process an input event and generate corresponding UI events
    fn processInputEvent(self: *EventManager, event: InputEvent) void {
        switch (event) {
            .mouse => |mouse_event| self.processMouseEvent(mouse_event),
            .key => |key_event| self.processKeyEvent(key_event),
            .touch => |touch_event| self.processTouchEvent(touch_event),
            .scroll => |scroll_event| self.processScrollEvent(scroll_event),
            .text => |text_event| self.processTextEvent(text_event),
        }
    }

    /// Process a mouse input event
    fn processMouseEvent(self: *EventManager, event: InputEvent.MouseEvent) void {
        // If we have a capture view, all events go to it
        if (self.capture_view) |view| {
            // Create mouse event data
            const data = EventData{ .mouse = .{
                .button = event.button,
                .position = event.position,
                .modifiers = event.modifiers,
            } };

            const ui_event = UIEvent{
                .type = switch (event.action) {
                    .press => .mouse_down,
                    .release => .mouse_up,
                    .move => .mouse_move,
                },
                .phase = .target,
                .target = view,
                .current_target = view,
                .data = data,
                .timestamp = event.timestamp,
            };

            self.addUIEvent(ui_event);
            return;
        }

        // Otherwise, do hit testing to find the target view
        // This would be expanded in a real implementation
        // For now, just create a mouse event without a target
        // This is a placeholder for demonstration purposes
    }

    /// Process a keyboard input event
    fn processKeyEvent(self: *EventManager, event: InputEvent.KeyEvent) void {
        // Send key events to the focused view if any
        if (self.focused_view) |view| {
            const data = EventData{ .key = .{
                .key = event.key,
                .modifiers = event.modifiers,
            } };

            const ui_event = UIEvent{
                .type = switch (event.action) {
                    .press => .key_down,
                    .release => .key_up,
                    .repeat => .key_down, // We use key_down for repeats too
                },
                .phase = .target,
                .target = view,
                .current_target = view,
                .data = data,
                .timestamp = event.timestamp,
            };

            self.addUIEvent(ui_event);
        }
    }

    /// Process a touch input event
    fn processTouchEvent(self: *EventManager, event: InputEvent.TouchEvent) void {
        _ = self;
        _ = event;

        // Similar to mouse events, but with touch-specific handling
        // This would be expanded in a real implementation
    }

    /// Process a scroll input event
    fn processScrollEvent(self: *EventManager, event: InputEvent.ScrollEvent) void {
        _ = self;
        _ = event;
        // Find the view under the scroll position and send event
        // This would be expanded in a real implementation
    }

    /// Process a text input event
    fn processTextEvent(self: *EventManager, event: InputEvent.TextEvent) void {
        // Send text input to the focused view if any
        if (self.focused_view) |view| {
            const data = EventData{ .text = .{
                .text = event.text,
            } };

            const ui_event = UIEvent{
                .type = .char_input,
                .phase = .target,
                .target = view,
                .current_target = view,
                .data = data,
                .timestamp = event.timestamp,
            };

            self.addUIEvent(ui_event);
        }
    }

    /// Dispatch a UI event through the component hierarchy
    fn dispatchUIEvent(self: *EventManager, event: *UIEvent) void {
        const target = event.target;

        // Capture phase - events flow down from root to target
        if (!event.cancelled) {
            event.phase = .capture;

            // Build path from root to target
            var path = std.ArrayList(*View).init(self.allocator);
            defer path.deinit();

            var current: ?*View = target;
            while (current) |node| {
                path.insert(0, node) catch break;
                current = node.parent;
            }

            // Dispatch to each node in the path except the target
            if (path.items.len > 1) {
                for (path.items[0 .. path.items.len - 1]) |node| {
                    event.current_target = node;
                    if (!self.deliverEventToView(event)) {
                        break; // Event was cancelled
                    }
                }
            }
        }

        // Target phase - event reaches the target
        if (!event.cancelled) {
            event.phase = .target;
            event.current_target = target;
            _ = self.deliverEventToView(event);
        }

        // Bubble phase - events flow up from target to root
        if (!event.cancelled) {
            event.phase = .bubble;

            var current: ?*View = target.parent;
            while (current) |node| {
                event.current_target = node;
                if (!self.deliverEventToView(event)) {
                    break; // Event was cancelled
                }
                current = node.parent;
            }
        }

        // Notify global listeners
        if (!event.cancelled) {
            if (self.listeners.get(event.type)) |listeners| {
                for (listeners.items) |listener| {
                    listener.callback(event, listener.context);
                    if (event.cancelled) break;
                }
            }
        }
    }

    /// Deliver an event to a specific view
    fn deliverEventToView(self: *EventManager, event: *UIEvent) bool {
        _ = self;

        const view = event.current_target;

        // Call the view's event handler
        const handled = view.vtable.handleEvent(view, event);
        if (handled) {
            event.cancelled = true; // Event was handled
        }

        // Return false if event propagation was cancelled
        return !event.cancelled;
    }

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
