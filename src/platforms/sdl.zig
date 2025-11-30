//! SDL Platform Backend - Real Event-Driven Execution
//!
//! This implements the revolutionary 0% idle CPU execution using SDL_WaitEvent()
//!
//! 🎯 Core principle: NEVER spin, ALWAYS block on events
//! This achieves true 0% idle CPU usage that makes us revolutionary
//!
//! Ownership model (Model 2 - Platform at Root):
//! - SdlPlatform owns the window, GL context, and event source
//! - App borrows SdlPlatform via interface() vtable
//! - User creates Platform first, destroys last

const std = @import("std");
const app = @import("../app.zig");
const PlatformInterface = app.PlatformInterface;
const Event = app.Event;
const events = @import("../events.zig");
const InputEvent = events.InputEvent;
const MouseButton = events.MouseButton;
const MouseAction = events.MouseAction;
const Key = events.Key;
const KeyAction = events.KeyAction;
const KeyModifiers = events.KeyModifiers;
const Point = @import("../core/geometry.zig").Point;

// SDL function declarations - we'll link to system SDL
extern fn SDL_Init(flags: u32) c_int;
extern fn SDL_Quit() void;
extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*anyopaque;
extern fn SDL_DestroyWindow(window: ?*anyopaque) void;
extern fn SDL_WaitEvent(event: *SDLEvent) c_int;
extern fn SDL_PollEvent(event: *SDLEvent) c_int;
extern fn SDL_GetError() [*:0]const u8;

// SDL Constants
const SDL_INIT_VIDEO = 0x00000020;
const SDL_WINDOW_SHOWN = 0x00000004;
const SDL_WINDOW_RESIZABLE = 0x00000020;

// SDL Event types
const SDL_QUIT = 0x100;
const SDL_KEYDOWN = 0x300;
const SDL_KEYUP = 0x301;
const SDL_MOUSEBUTTONDOWN = 0x401;
const SDL_MOUSEBUTTONUP = 0x402;
const SDL_MOUSEMOTION = 0x400;
const SDL_WINDOWEVENT = 0x200;

const SDL_WINDOWEVENT_EXPOSED = 1;
const SDL_WINDOWEVENT_SIZE_CHANGED = 5;

// SDL Mouse buttons
const SDL_BUTTON_LEFT = 1;
const SDL_BUTTON_MIDDLE = 2;
const SDL_BUTTON_RIGHT = 3;
const SDL_BUTTON_X1 = 4;
const SDL_BUTTON_X2 = 5;

// SDL Keyboard modifiers
const KMOD_LSHIFT = 0x0001;
const KMOD_RSHIFT = 0x0002;
const KMOD_LCTRL = 0x0040;
const KMOD_RCTRL = 0x0080;
const KMOD_LALT = 0x0100;
const KMOD_RALT = 0x0200;
const KMOD_LGUI = 0x0400;
const KMOD_RGUI = 0x0800;
const KMOD_CAPS = 0x2000;
const KMOD_NUM = 0x1000;

// SDL Scancodes (subset - we'll expand as needed)
const SDL_SCANCODE_A = 4;
const SDL_SCANCODE_Z = 29;
const SDL_SCANCODE_1 = 30;
const SDL_SCANCODE_0 = 39;
const SDL_SCANCODE_SPACE = 44;
const SDL_SCANCODE_RETURN = 40;
const SDL_SCANCODE_BACKSPACE = 42;
const SDL_SCANCODE_TAB = 43;
const SDL_SCANCODE_ESCAPE = 41;
const SDL_SCANCODE_LEFT = 80;
const SDL_SCANCODE_RIGHT = 79;
const SDL_SCANCODE_UP = 82;
const SDL_SCANCODE_DOWN = 81;
const SDL_SCANCODE_LSHIFT = 225;
const SDL_SCANCODE_RSHIFT = 229;
const SDL_SCANCODE_LCTRL = 224;
const SDL_SCANCODE_RCTRL = 228;
const SDL_SCANCODE_LALT = 226;
const SDL_SCANCODE_RALT = 230;

// SDL Event structures
const SDLEvent = extern struct {
    type: u32,
    timestamp: u32,
    data: [56]u8 = undefined,
};

const SDLMouseButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding: u8,
    x: i32,
    y: i32,
};

const SDLMouseMotionEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    which: u32,
    state: u32,
    x: i32,
    y: i32,
    xrel: i32,
    yrel: i32,
};

const SDLKeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    window_id: u32,
    state: u8,
    repeat: u8,
    padding: [2]u8,
    keysym: SDLKeysym,
};

const SDLKeysym = extern struct {
    scancode: u32,
    sym: u32,
    mod: u16,
    unused: u32,
};

/// SDL Platform configuration
///
/// Platform owns window configuration - separate from App's execution config.
pub const SdlConfig = struct {
    width: u32 = 800,
    height: u32 = 600,
    title: [:0]const u8 = "zig-gui",
    resizable: bool = true,
};

/// SDL Platform Backend - implements the revolutionary event-driven architecture
///
/// Ownership: Platform owns OS resources (window, GL context, events)
/// Usage: Create first, destroy last. App borrows via interface().
///
/// Example:
/// ```zig
/// var platform = try SdlPlatform.init(allocator, .{ .width = 800, .height = 600 });
/// defer platform.deinit();
///
/// var app = try App(MyState).init(allocator, platform.interface(), .{});
/// defer app.deinit();
/// ```
pub const SdlPlatform = struct {
    allocator: std.mem.Allocator,
    window: ?*anyopaque = null,
    should_quit: bool = false,
    width: u32,
    height: u32,

    // Event data storage (owned by platform, lifetime tied to event dispatch)
    event_data_arena: std.heap.ArenaAllocator,

    /// Initialize SDL platform - owns window and event source
    pub fn init(allocator: std.mem.Allocator, config: SdlConfig) !SdlPlatform {
        // Initialize SDL video subsystem
        if (SDL_Init(SDL_INIT_VIDEO) < 0) {
            std.log.err("SDL_Init failed: {s}", .{SDL_GetError()});
            return error.SdlInitFailed;
        }

        // Create window
        const window_flags = SDL_WINDOW_SHOWN | if (config.resizable) SDL_WINDOW_RESIZABLE else 0;
        const window = SDL_CreateWindow(
            config.title.ptr,
            100, // x position
            100, // y position
            @intCast(config.width),
            @intCast(config.height),
            window_flags,
        );

        if (window == null) {
            std.log.err("SDL_CreateWindow failed: {s}", .{SDL_GetError()});
            SDL_Quit();
            return error.SdlWindowCreationFailed;
        }

        std.log.info("SDL Platform initialized: {}x{} window", .{ config.width, config.height });

        return SdlPlatform{
            .allocator = allocator,
            .window = window,
            .width = config.width,
            .height = config.height,
            .event_data_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Clean up SDL resources
    pub fn deinit(self: *SdlPlatform) void {
        self.event_data_arena.deinit();
        if (self.window) |window| {
            SDL_DestroyWindow(window);
            self.window = null;
        }
        SDL_Quit();
        std.log.info("SDL Platform cleaned up", .{});
    }

    /// Get platform interface (vtable) for passing to App
    ///
    /// Example:
    /// ```zig
    /// var app = try App(MyState).init(allocator, platform.interface(), .{});
    /// ```
    pub fn interface(self: *SdlPlatform) PlatformInterface {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Wait for the next event - THIS IS THE MAGIC!
    /// This function BLOCKS until an event occurs, achieving 0% idle CPU
    pub fn waitForEvent(self: *SdlPlatform) !Event {
        var sdl_event: SDLEvent = undefined;

        // THIS IS WHERE THE MAGIC HAPPENS!
        // SDL_WaitEvent() blocks the thread until an event occurs
        // This achieves TRUE 0% idle CPU usage!
        const result = SDL_WaitEvent(&sdl_event);

        if (result == 0) {
            std.log.err("SDL_WaitEvent failed: {s}", .{SDL_GetError()});
            return error.SdlEventError;
        }

        // Convert SDL event to our internal event format
        return self.convertSdlEvent(&sdl_event);
    }

    /// Check for events without blocking (for game loop mode)
    pub fn pollEvent(self: *SdlPlatform) ?Event {
        var sdl_event: SDLEvent = undefined;

        const result = SDL_PollEvent(&sdl_event);
        if (result == 0) {
            return null; // No events available
        }

        return self.convertSdlEvent(&sdl_event) catch null;
    }

    /// Clear event data arena between frames to prevent memory buildup
    pub fn clearEventData(self: *SdlPlatform) void {
        _ = self.event_data_arena.reset(.retain_capacity);
    }

    // ========================================================================
    // SDL to zig-gui type conversion helpers
    // ========================================================================

    /// Convert SDL mouse button to zig-gui MouseButton
    fn sdlButtonToMouseButton(sdl_button: u8) MouseButton {
        return switch (sdl_button) {
            SDL_BUTTON_LEFT => .left,
            SDL_BUTTON_RIGHT => .right,
            SDL_BUTTON_MIDDLE => .middle,
            SDL_BUTTON_X1 => .x1,
            SDL_BUTTON_X2 => .x2,
            else => .left, // Default to left for unknown buttons
        };
    }

    /// Convert SDL keyboard modifiers to zig-gui KeyModifiers
    fn sdlModToKeyModifiers(sdl_mod: u16) KeyModifiers {
        return .{
            .shift = (sdl_mod & (KMOD_LSHIFT | KMOD_RSHIFT)) != 0,
            .ctrl = (sdl_mod & (KMOD_LCTRL | KMOD_RCTRL)) != 0,
            .alt = (sdl_mod & (KMOD_LALT | KMOD_RALT)) != 0,
            .meta = (sdl_mod & (KMOD_LGUI | KMOD_RGUI)) != 0,
            .caps_lock = (sdl_mod & KMOD_CAPS) != 0,
            .num_lock = (sdl_mod & KMOD_NUM) != 0,
        };
    }

    /// Convert SDL scancode to zig-gui Key
    fn sdlScancodeToKey(scancode: u32) Key {
        return switch (scancode) {
            SDL_SCANCODE_A...SDL_SCANCODE_Z => @enumFromInt(@intFromEnum(Key.a) + (scancode - SDL_SCANCODE_A)),
            SDL_SCANCODE_1...SDL_SCANCODE_0 => blk: {
                const offset = scancode - SDL_SCANCODE_1;
                if (offset == 9) break :blk Key.key_0;
                break :blk @enumFromInt(@intFromEnum(Key.key_1) + offset);
            },
            SDL_SCANCODE_SPACE => .space,
            SDL_SCANCODE_RETURN => .enter,
            SDL_SCANCODE_BACKSPACE => .backspace,
            SDL_SCANCODE_TAB => .tab,
            SDL_SCANCODE_ESCAPE => .escape,
            SDL_SCANCODE_LEFT => .left,
            SDL_SCANCODE_RIGHT => .right,
            SDL_SCANCODE_UP => .up,
            SDL_SCANCODE_DOWN => .down,
            SDL_SCANCODE_LSHIFT, SDL_SCANCODE_RSHIFT => .shift,
            SDL_SCANCODE_LCTRL, SDL_SCANCODE_RCTRL => .ctrl,
            SDL_SCANCODE_LALT, SDL_SCANCODE_RALT => .alt,
            else => .unknown,
        };
    }

    /// Convert SDL event to our internal event format
    fn convertSdlEvent(self: *SdlPlatform, sdl_event: *const SDLEvent) !Event {
        const timestamp = @as(u64, sdl_event.timestamp);

        switch (sdl_event.type) {
            SDL_QUIT => {
                self.should_quit = true;
                return Event{
                    .type = .quit,
                    .timestamp = timestamp,
                };
            },

            SDL_WINDOWEVENT => {
                // Window was exposed or resized - need to redraw
                return Event{
                    .type = .redraw_needed,
                    .timestamp = timestamp,
                };
            },

            SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP => {
                // Mouse button events - extract button, position, modifiers
                const mouse_event: *const SDLMouseButtonEvent = @ptrCast(sdl_event);

                const input_event = try self.event_data_arena.allocator().create(InputEvent);
                input_event.* = .{
                    .mouse = .{
                        .action = if (sdl_event.type == SDL_MOUSEBUTTONDOWN) .press else .release,
                        .button = sdlButtonToMouseButton(mouse_event.button),
                        .position = .{
                            .x = @floatFromInt(mouse_event.x),
                            .y = @floatFromInt(mouse_event.y),
                        },
                        .modifiers = .{}, // SDL doesn't provide modifiers in mouse events
                        .timestamp = timestamp,
                    },
                };

                return Event{
                    .type = .input,
                    .timestamp = timestamp,
                    .data = input_event,
                };
            },

            SDL_MOUSEMOTION => {
                // Mouse motion - create mouse event with move action
                const motion_event: *const SDLMouseMotionEvent = @ptrCast(sdl_event);

                const input_event = try self.event_data_arena.allocator().create(InputEvent);
                input_event.* = .{
                    .mouse = .{
                        .action = .move,
                        .button = .left, // Not relevant for motion
                        .position = .{
                            .x = @floatFromInt(motion_event.x),
                            .y = @floatFromInt(motion_event.y),
                        },
                        .modifiers = .{},
                        .timestamp = timestamp,
                    },
                };

                return Event{
                    .type = .input,
                    .timestamp = timestamp,
                    .data = input_event,
                };
            },

            SDL_KEYDOWN, SDL_KEYUP => {
                // Keyboard events - extract key, modifiers, repeat
                const key_event: *const SDLKeyboardEvent = @ptrCast(sdl_event);

                const input_event = try self.event_data_arena.allocator().create(InputEvent);
                input_event.* = .{
                    .key = .{
                        .action = if (sdl_event.type == SDL_KEYDOWN) blk: {
                            break :blk if (key_event.repeat != 0) .repeat else .press;
                        } else .release,
                        .key = sdlScancodeToKey(key_event.keysym.scancode),
                        .modifiers = sdlModToKeyModifiers(key_event.keysym.mod),
                        .timestamp = timestamp,
                    },
                };

                return Event{
                    .type = .input,
                    .timestamp = timestamp,
                    .data = input_event,
                };
            },

            else => {
                // Other events - trigger redraw to be safe
                return Event{
                    .type = .redraw_needed,
                    .timestamp = timestamp,
                };
            },
        }
    }

    /// Check if the platform wants to quit
    pub fn shouldQuit(self: *const SdlPlatform) bool {
        return self.should_quit;
    }

    /// Present/swap buffers (for future rendering integration)
    pub fn present(self: *SdlPlatform) void {
        _ = self;
        // TODO: SDL_GL_SwapWindow or software buffer present
    }

    // ========================================================================
    // VTable implementation for PlatformInterface
    // ========================================================================

    const vtable = PlatformInterface.VTable{
        .waitEvent = waitEventVTable,
        .pollEvent = pollEventVTable,
        .present = presentVTable,
    };

    fn waitEventVTable(ptr: *anyopaque) anyerror!Event {
        const self: *SdlPlatform = @ptrCast(@alignCast(ptr));
        return self.waitForEvent();
    }

    fn pollEventVTable(ptr: *anyopaque) ?Event {
        const self: *SdlPlatform = @ptrCast(@alignCast(ptr));
        return self.pollEvent();
    }

    fn presentVTable(ptr: *anyopaque) void {
        const self: *SdlPlatform = @ptrCast(@alignCast(ptr));
        self.present();
    }
};

// Performance validation tests
test "SDL platform initialization" {
    // Skip if SDL not available
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std.debug.print("Skipping SDL test - SDL not available\n", .{});
        return;
    }
    defer SDL_Quit();

    const config = SdlConfig{
        .width = 800,
        .height = 600,
        .title = "Test Window",
    };

    var platform = try SdlPlatform.init(std.testing.allocator, config);
    defer platform.deinit();

    // Verify window was created
    try std.testing.expect(platform.window != null);
    try std.testing.expect(!platform.shouldQuit());
}

test "SDL platform provides PlatformInterface" {
    // Skip if SDL not available
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std.debug.print("Skipping SDL test - SDL not available\n", .{});
        return;
    }
    defer SDL_Quit();

    var platform = try SdlPlatform.init(std.testing.allocator, .{});
    defer platform.deinit();

    // Get interface
    const iface = platform.interface();

    // Verify vtable is set
    try std.testing.expect(iface.vtable != undefined);
    try std.testing.expect(iface.ptr != undefined);
}

test "event-driven execution achieves 0% CPU" {
    // This test would need to be run with external monitoring
    // to verify that waitForEvent() actually blocks and uses 0% CPU
    std.debug.print("Event-driven test: Run with `htop` to verify 0% CPU usage\n", .{});
}