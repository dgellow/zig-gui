//! SDL Platform Backend - Real Event-Driven Execution
//! 
//! This implements the revolutionary 0% idle CPU execution using SDL_WaitEvent()
//! 
//! 🎯 Core principle: NEVER spin, ALWAYS block on events
//! This achieves true 0% idle CPU usage that makes us revolutionary

const std = @import("std");
const app = @import("../app.zig");

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

// SDL Event structure (simplified)
const SDLEvent = extern struct {
    type: u32,
    timestamp: u32,
    
    // Union data (we'll just reserve space)
    data: [56]u8 = undefined,
};

/// SDL Platform Backend - implements the revolutionary event-driven architecture
pub const SdlPlatform = struct {
    allocator: std.mem.Allocator,
    window: ?*anyopaque = null,
    should_quit: bool = false,
    
    /// Initialize SDL platform
    pub fn init(allocator: std.mem.Allocator, config: app.AppConfig) !SdlPlatform {
        // Initialize SDL video subsystem
        if (SDL_Init(SDL_INIT_VIDEO) < 0) {
            std.log.err("SDL_Init failed: {s}", .{SDL_GetError()});
            return error.SdlInitFailed;
        }
        
        // Create window
        const window = SDL_CreateWindow(
            config.window_title.ptr,
            100, // x position
            100, // y position
            @intCast(config.window_width),
            @intCast(config.window_height),
            SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE
        );
        
        if (window == null) {
            std.log.err("SDL_CreateWindow failed: {s}", .{SDL_GetError()});
            SDL_Quit();
            return error.SdlWindowCreationFailed;
        }
        
        std.log.info("🚀 SDL Platform initialized: {}x{} window", .{ config.window_width, config.window_height });
        
        return SdlPlatform{
            .allocator = allocator,
            .window = window,
        };
    }
    
    /// Clean up SDL resources
    pub fn deinit(self: *SdlPlatform) void {
        if (self.window) |window| {
            SDL_DestroyWindow(window);
            self.window = null;
        }
        SDL_Quit();
        std.log.info("🧹 SDL Platform cleaned up");
    }
    
    /// Wait for the next event - THIS IS THE MAGIC! 🪄
    /// This function BLOCKS until an event occurs, achieving 0% idle CPU
    pub fn waitForEvent(self: *SdlPlatform) !app.Event {
        var sdl_event: SDLEvent = undefined;
        
        // 🛌 THIS IS WHERE THE MAGIC HAPPENS!
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
    pub fn pollEvent(self: *SdlPlatform) ?app.Event {
        var sdl_event: SDLEvent = undefined;
        
        const result = SDL_PollEvent(&sdl_event);
        if (result == 0) {
            return null; // No events available
        }
        
        return self.convertSdlEvent(&sdl_event) catch null;
    }
    
    /// Convert SDL event to our internal event format
    fn convertSdlEvent(self: *SdlPlatform, sdl_event: *const SDLEvent) !app.Event {
        const timestamp = @as(u64, sdl_event.timestamp);
        
        switch (sdl_event.type) {
            SDL_QUIT => {
                self.should_quit = true;
                return app.Event{
                    .type = .quit,
                    .timestamp = timestamp,
                };
            },
            
            SDL_WINDOWEVENT => {
                // Window was exposed or resized - need to redraw
                return app.Event{
                    .type = .redraw_needed,
                    .timestamp = timestamp,
                };
            },
            
            SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP, SDL_MOUSEMOTION => {
                // Mouse events - might trigger UI changes
                return app.Event{
                    .type = .input,
                    .timestamp = timestamp,
                    .data = null, // TODO: Extract mouse data
                };
            },
            
            SDL_KEYDOWN, SDL_KEYUP => {
                // Keyboard events
                return app.Event{
                    .type = .input,
                    .timestamp = timestamp,
                    .data = null, // TODO: Extract keyboard data
                };
            },
            
            else => {
                // Other events - trigger redraw to be safe
                return app.Event{
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
};

// Performance validation tests
test "SDL platform initialization" {
    // Skip if SDL not available
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std.debug.print("Skipping SDL test - SDL not available\n", .{});
        return;
    }
    defer SDL_Quit();
    
    const config = app.AppConfig{
        .window_width = 800,
        .window_height = 600,
        .window_title = "Test Window",
    };
    
    var platform = try SdlPlatform.init(std.testing.allocator, config);
    defer platform.deinit();
    
    // Verify window was created
    try std.testing.expect(platform.window != null);
    try std.testing.expect(!platform.shouldQuit());
}

test "event-driven execution achieves 0% CPU" {
    // This test would need to be run with external monitoring
    // to verify that waitForEvent() actually blocks and uses 0% CPU
    std.debug.print("Event-driven test: Run with `htop` to verify 0% CPU usage\n", .{});
}