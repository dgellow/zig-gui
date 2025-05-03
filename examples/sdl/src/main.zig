const std = @import("std");

const c = @import("c.zig").mod;
const gui = @import("gui");
const SDLRenderer = @import("SDLRenderer.zig");

// Sample application code
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize SDL (application owns SDL)
    if (c.SDL_Init(c.SDL_INIT_VIDEO)) {
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Create window and renderer (owned by application)
    const window = c.SDL_CreateWindow("SDL Demo", 800, 600, 0) orelse return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    const sdl_renderer = c.SDL_CreateRenderer(window, null) orelse return error.RendererCreationFailed;
    defer c.SDL_DestroyRenderer(sdl_renderer);

    // Create gui renderer adapter (wraps SDL renderer)
    var renderer = try SDLRenderer.init(allocator, sdl_renderer);
    defer renderer.deinit();

    // Initialize GUI with SDL renderer adapter
    var ui = try gui.GUI.init(allocator, &renderer.renderer_interface, .{});
    defer ui.deinit();

    // Create a root container
    var container = try gui.components.Container.create(allocator);
    ui.setRootView(&container.view);

    // Add a blue rectangle
    var rect = try gui.components.Rectangle.create(allocator);
    rect.setStyle(.{
        .background_color = gui.Color.fromRGBA(0, 0, 255, 255),
        .width = 200,
        .height = 100,
        .margin = gui.EdgeInsets{ .left = 50, .top = 50 },
    });
    try container.addChild(&rect.view);

    // Basic event loop (application owns the event loop)
    var running = true;
    while (running) {
        // Process events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                running = false;
                break;
            }
            // Forward events to UI
            ui.processEvent(event);
        }

        // Render frame
        ui.frame(1.0 / 60.0);
    }
}
