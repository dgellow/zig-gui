const std = @import("std");
const zlay = @import("zlay");
const c = @import("c.zig");

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

pub fn main() !void {
    // Initialize SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "Zlay SDL Example",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        c.SDL_WINDOW_SHOWN,
    );
    if (window == null) {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowCreationFailed;
    }
    defer c.SDL_DestroyWindow(window);

    // Create renderer
    const sdl_renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC);
    if (sdl_renderer == null) {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererCreationFailed;
    }
    defer c.SDL_DestroyRenderer(sdl_renderer);

    // General purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zlay
    var ctx = try zlay.init(allocator);
    defer ctx.deinit();

    // Create zlay SDL renderer
    var renderer = SDLRenderer.create(sdl_renderer);
    ctx.setRenderer(&renderer.renderer);

    // Main loop
    var quit = false;
    var event: c.SDL_Event = undefined;
    while (!quit) {
        // Process events
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => quit = true,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        quit = true;
                    }
                },
                else => {},
            }
        }

        // Clear screen
        _ = c.SDL_SetRenderDrawColor(sdl_renderer, 240, 240, 240, 255);
        _ = c.SDL_RenderClear(sdl_renderer);

        // Begin zlay frame
        try ctx.beginFrame();

        // Define UI
        try createUI(&ctx);

        // Layout
        try ctx.computeLayout(@floatFromInt(WINDOW_WIDTH), @floatFromInt(WINDOW_HEIGHT));

        // Render UI
        try ctx.render();

        // Swap buffers
        c.SDL_RenderPresent(sdl_renderer);

        // Small delay to avoid maxing CPU
        c.SDL_Delay(16);
    }
}

/// Create the UI for the current frame
fn createUI(ctx: *zlay.Context) !void {
    // Root container
    const root_idx = try ctx.beginElement(.container, "root");
    
    // Header
    const header_idx = try ctx.beginElement(.container, "header");
    {
        ctx.elements.items[header_idx].style.background_color = zlay.Color.rgb(50, 50, 200);
        ctx.elements.items[header_idx].style.setPadding(10);
        
        // Logo
        const logo_idx = try ctx.beginElement(.box, "logo");
        ctx.elements.items[logo_idx].style.background_color = zlay.Color.rgb(200, 50, 50);
        ctx.elements.items[logo_idx].style.corner_radius = 5;
        try ctx.endElement(); // logo
        
        // Title
        const title_idx = try ctx.beginElement(.text, "title");
        ctx.elements.items[title_idx].text = "Zlay SDL Example";
        ctx.elements.items[title_idx].style.text_color = zlay.Color.white;
        ctx.elements.items[title_idx].style.font_size = 24;
        try ctx.endElement(); // title
    }
    try ctx.endElement(); // header
    
    // Content
    const content_idx = try ctx.beginElement(.container, "content");
    {
        ctx.elements.items[content_idx].style.setPadding(20);
        ctx.elements.items[content_idx].style.background_color = zlay.Color.rgb(240, 240, 240);
        
        // Button
        const button_idx = try ctx.beginElement(.button, "button");
        ctx.elements.items[button_idx].text = "Click Me";
        ctx.elements.items[button_idx].style.background_color = zlay.Color.rgb(50, 150, 50);
        ctx.elements.items[button_idx].style.text_color = zlay.Color.white;
        ctx.elements.items[button_idx].style.corner_radius = 5;
        ctx.elements.items[button_idx].style.setPadding(10);
        try ctx.endElement(); // button
    }
    try ctx.endElement(); // content
    
    // Footer
    const footer_idx = try ctx.beginElement(.container, "footer");
    {
        ctx.elements.items[footer_idx].style.background_color = zlay.Color.rgb(50, 50, 50);
        ctx.elements.items[footer_idx].style.setPadding(10);
        
        // Footer text
        const footer_text_idx = try ctx.beginElement(.text, "footer_text");
        ctx.elements.items[footer_text_idx].text = "Zlay - A Zig Layout Library";
        ctx.elements.items[footer_text_idx].style.text_color = zlay.Color.rgb(200, 200, 200);
        try ctx.endElement(); // footer_text
    }
    try ctx.endElement(); // footer
    
    // End root
    try ctx.endElement(); // root
}

/// SDL Renderer implementation for zlay
const SDLRenderer = struct {
    renderer: zlay.Renderer,
    sdl_renderer: *c.SDL_Renderer,
    
    const vtable = zlay.Renderer.VTable{
        .beginFrame = beginFrame,
        .endFrame = endFrame,
        .clear = clear,
        .drawRect = drawRect,
        .drawRoundedRect = drawRoundedRect,
        .drawText = drawText,
        .drawImage = drawImage,
        .clipBegin = clipBegin,
        .clipEnd = clipEnd,
    };
    
    fn create(sdl_renderer: ?*c.SDL_Renderer) SDLRenderer {
        return .{
            .renderer = .{
                .vtable = &vtable,
                .user_data = null,
            },
            .sdl_renderer = sdl_renderer.?,
        };
    }
    
    fn beginFrame(renderer: *zlay.Renderer) void {
        _ = renderer;
        // Nothing to do, SDL frame begins with SDL_RenderClear
    }
    
    fn endFrame(renderer: *zlay.Renderer) void {
        _ = renderer;
        // Nothing to do, SDL frame ends with SDL_RenderPresent
    }
    
    fn clear(renderer: *zlay.Renderer, color: zlay.Color) void {
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.r, color.g, color.b, color.a);
        _ = c.SDL_RenderClear(self.sdl_renderer);
    }
    
    fn drawRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, fill: zlay.Color) void {
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, fill.r, fill.g, fill.b, fill.a);
        
        const rect = c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(width),
            .h = @intFromFloat(height),
        };
        
        _ = c.SDL_RenderFillRect(self.sdl_renderer, &rect);
    }
    
    fn drawRoundedRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: zlay.Color) void {
        // Simple implementation - for true rounded corners we'd use SDL_gfx or draw our own
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, fill.r, fill.g, fill.b, fill.a);
        
        const rect = c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(width),
            .h = @intFromFloat(height),
        };
        
        _ = c.SDL_RenderFillRect(self.sdl_renderer, &rect);
        
        // This is where we'd add the rounded corners
        // For now, we just draw a normal rectangle
        _ = radius; // Unused
    }
    
    fn drawText(renderer: *zlay.Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: zlay.Color) void {
        // In a real implementation, we'd render text using SDL_ttf
        // For this simple example, we just draw a colored rectangle to represent text
        
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.r, color.g, color.b, color.a);
        
        const text_width = @as(f32, @floatFromInt(text.len)) * font_size * 0.5;
        const text_height = font_size;
        
        const rect = c.SDL_Rect{
            .x = @intFromFloat(x - text_width / 2),
            .y = @intFromFloat(y - text_height / 2),
            .w = @intFromFloat(text_width),
            .h = @intFromFloat(text_height),
        };
        
        _ = c.SDL_RenderFillRect(self.sdl_renderer, &rect);
    }
    
    fn drawImage(renderer: *zlay.Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        // In a real implementation, we'd load and render textures
        // For this simple example, we just draw an outline
        
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, 255, 0, 255, 255); // Magenta outline for images
        
        const rect = c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(width),
            .h = @intFromFloat(height),
        };
        
        _ = c.SDL_RenderDrawRect(self.sdl_renderer, &rect);
        
        // Just to use image_id to avoid unused var warning
        if (image_id == 0) {
            _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, 200, 0, 200, 255);
        }
    }
    
    fn clipBegin(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32) void {
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        
        const rect = c.SDL_Rect{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(width),
            .h = @intFromFloat(height),
        };
        
        _ = c.SDL_RenderSetClipRect(self.sdl_renderer, &rect);
    }
    
    fn clipEnd(renderer: *zlay.Renderer) void {
        const self = @fieldParentPtr(SDLRenderer, "renderer", renderer);
        _ = c.SDL_RenderSetClipRect(self.sdl_renderer, null);
    }
};