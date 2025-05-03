const std = @import("std");
const sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});
const gui = @import("gui");

// Sample application code
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize SDL (application owns SDL)
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) {
        return error.SDLInitFailed;
    }
    defer sdl.SDL_Quit();

    // Create window and renderer (owned by application)
    var window = sdl.SDL_CreateWindow("SDL Demo", sdl.SDL_WINDOWPOS_UNDEFINED, sdl.SDL_WINDOWPOS_UNDEFINED, 800, 600, sdl.SDL_WINDOW_SHOWN) orelse return error.WindowCreationFailed;
    defer sdl.SDL_DestroyWindow(window);

    var sdl_renderer = sdl.SDL_CreateRenderer(window, -1, sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC) orelse return error.RendererCreationFailed;
    defer sdl.SDL_DestroyRenderer(sdl_renderer);

    // Create gui renderer adapter (wraps SDL renderer)
    var renderer = try gui.renderers.SdlRenderer.init(allocator, sdl_renderer);
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
        .background_color = gui.Color.fromRgba(0, 0, 255, 255),
        .width = 200,
        .height = 100,
        .margin = gui.EdgeInsets{ .left = 50, .top = 50 },
    });
    try container.addChild(&rect.view);

    // Basic event loop (application owns the event loop)
    var running = true;
    while (running) {
        // Process events
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl.SDL_QUIT) {
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
