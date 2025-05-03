const std = @import("std");
const gui = @import("gui");
const c = @import("c.zig").mod;

const Self = @This();

allocator: std.mem.Allocator,
sdl_renderer: *c.SDL_Renderer,
renderer_interface: gui.RendererInterface,

// Tracking state for save/restore
saved_clip_rects: std.ArrayList(c.SDL_Rect),
saved_colors: std.ArrayList(c.SDL_Color),
current_color: c.SDL_Color,

// Resource tracking
next_image_id: u64,
images: std.AutoHashMap(u64, SDLImage),

next_font_id: u64,
fonts: std.AutoHashMap(u64, SDLFont),

pub fn init(allocator: std.mem.Allocator, sdl_renderer: *c.SDL_Renderer) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .sdl_renderer = sdl_renderer,
        .renderer_interface = .{
            .vtable = &vtable,
        },
        .saved_clip_rects = std.ArrayList(c.SDL_Rect).init(allocator),
        .saved_colors = std.ArrayList(c.SDL_Color).init(allocator),
        .current_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .next_image_id = 1,
        .images = std.AutoHashMap(u64, SDLImage).init(allocator),
        .next_font_id = 1,
        .fonts = std.AutoHashMap(u64, SDLFont).init(allocator),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    // Clean up any resources
    self.saved_clip_rects.deinit();
    self.saved_colors.deinit();

    // Destroy all textures
    var image_it = self.images.iterator();
    while (image_it.next()) |entry| {
        c.SDL_DestroyTexture(entry.value_ptr.texture);
    }
    self.images.deinit();

    // Destroy all fonts
    var font_it = self.fonts.iterator();
    while (font_it.next()) |entry| {
        // Free any font resources if applicable
        _ = entry;
    }
    self.fonts.deinit();

    self.allocator.destroy(self);
}

// Implementation functions for the vtable
fn beginFrame(renderer: *gui.RendererInterface, width: f32, height: f32) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);
    _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, 255, 255, 255, 255);
    _ = c.SDL_RenderClear(self.sdl_renderer);
    _ = width;
    _ = height;
}

fn endFrame(renderer: *gui.RendererInterface) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);
    c.SDL_RenderPresent(self.sdl_renderer);
}

fn drawRect(renderer: *gui.RendererInterface, rect: gui.Rect, paint: gui.Paint) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    const sdl_rect = c.SDL_Rect{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.width),
        .h = @intFromFloat(rect.height),
    };

    // Set color from paint
    _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, paint.color.r, paint.color.g, paint.color.b, paint.color.a);

    // Save current color for state tracking
    self.current_color = .{
        .r = paint.color.r,
        .g = paint.color.g,
        .b = paint.color.b,
        .a = paint.color.a,
    };

    // Draw filled rectangle
    _ = c.SDL_RenderFillRect(self.sdl_renderer, &sdl_rect);

    // Draw stroke if specified
    if (paint.stroke_color) |stroke_color| {
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, stroke_color.r, stroke_color.g, stroke_color.b, stroke_color.a);

        // Draw outline
        _ = c.SDL_RenderDrawRect(self.sdl_renderer, &sdl_rect);

        // Restore fill color
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, self.current_color.r, self.current_color.g, self.current_color.b, self.current_color.a);
    }
}

fn drawRoundRect(renderer: *gui.RendererInterface, rect: gui.Rect, radius: f32, paint: gui.Paint) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // SDL doesn't have built-in rounded rectangle drawing
    // For now, we'll draw a regular rectangle as a simplification
    // In a real implementation, you would draw this with multiple shapes or a custom path
    drawRect(renderer, rect, paint);
    _ = self;
    _ = radius;
}

fn drawText(renderer: *gui.RendererInterface, text: []const u8, position: gui.Point, paint: gui.Paint) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // Basic text rendering requires SDL_ttf
    // This is a placeholder for now
    // In a real implementation, you would:
    // 1. Get or create a font texture
    // 2. Render the text to a surface/texture
    // 3. Draw the texture

    // Draw a rectangle as a placeholder
    const text_width: f32 = @floatFromInt(text.len * 8); // Rough estimate
    const text_height: f32 = 16.0;

    const text_rect = gui.Rect{
        .x = position.x,
        .y = position.y,
        .width = text_width,
        .height = text_height,
    };

    drawRect(renderer, text_rect, paint);
    _ = self;
}

fn drawImage(renderer: *gui.RendererInterface, image_handle: gui.ImageHandle, rect: gui.Rect, paint: gui.Paint) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    if (!image_handle.isValid()) return;

    // Try to find the image in our map
    if (self.images.get(image_handle.id)) |sdl_image| {
        const sdl_rect = c.SDL_Rect{
            .x = @intFromFloat(rect.x),
            .y = @intFromFloat(rect.y),
            .w = @intFromFloat(rect.width),
            .h = @intFromFloat(rect.height),
        };

        // Set blend mode based on paint
        _ = c.SDL_SetTextureAlphaMod(sdl_image.texture, @intFromFloat(paint.opacity * 255.0));

        // Render the texture
        _ = c.SDL_RenderCopy(self.sdl_renderer, sdl_image.texture, null, &sdl_rect);
    }
}

fn drawPath(renderer: *gui.RendererInterface, path: gui.Path, paint: gui.Paint) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // SDL doesn't have direct path rendering
    // For a basic implementation, we can draw lines between points
    // For complex paths, you'd need a more sophisticated implementation

    if (path.commands.items.len == 0 or path.points.items.len == 0) {
        return;
    }

    // Set color from paint
    _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, paint.color.r, paint.color.g, paint.color.b, paint.color.a);

    var point_index: usize = 0;
    var last_x: c_int = 0;
    var last_y: c_int = 0;

    for (path.commands.items) |cmd| {
        switch (cmd) {
            .move_to => {
                if (point_index < path.points.items.len) {
                    const point = path.points.items[point_index];
                    last_x = @intFromFloat(point.x);
                    last_y = @intFromFloat(point.y);
                    point_index += 1;
                }
            },
            .line_to => {
                if (point_index < path.points.items.len) {
                    const point = path.points.items[point_index];
                    const x: c_int = @intFromFloat(point.x);
                    const y: c_int = @intFromFloat(point.y);

                    _ = c.SDL_RenderDrawLine(self.sdl_renderer, last_x, last_y, x, y);

                    last_x = x;
                    last_y = y;
                    point_index += 1;
                }
            },
            .quad_to, .cubic_to, .arc_to => {
                // These would require more sophisticated curve rendering
                // Skip the appropriate number of points
                if (cmd == .quad_to) {
                    point_index += 2; // Control point + end point
                } else if (cmd == .cubic_to) {
                    point_index += 3; // Two control points + end point
                } else if (cmd == .arc_to) {
                    point_index += 4; // Arc parameters + end point
                }
            },
            .close => {
                // Nothing special to do for close in this simple implementation
            },
        }
    }

    // Restore state
    _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, self.current_color.r, self.current_color.g, self.current_color.b, self.current_color.a);
}

fn createImage(renderer: *gui.RendererInterface, width: u32, height: u32, format: gui.ImageFormat, data: ?[]const u8) ?gui.ImageHandle {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // Create a texture
    const sdl_format = switch (format) {
        .rgba8888 => c.SDL_PIXELFORMAT_RGBA32,
        .rgbx8888 => c.SDL_PIXELFORMAT_RGB888,
        .rgb888 => c.SDL_PIXELFORMAT_RGB24,
        .bgra8888 => c.SDL_PIXELFORMAT_BGRA32,
        .gray8 => c.SDL_PIXELFORMAT_INDEX8,
        .alpha8 => c.SDL_PIXELFORMAT_INDEX8,
    };

    const texture = c.SDL_CreateTexture(self.sdl_renderer, sdl_format, c.SDL_TEXTUREACCESS_STATIC, @intCast(width), @intCast(height));

    if (texture == null) {
        return null;
    }

    // Update texture with data if provided
    if (data) |pixels| {
        _ = c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(width * format.bytesPerPixel()));
    }

    // Set blending mode
    if (format.hasAlpha()) {
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    }

    // Create handle and store in map
    const id = self.next_image_id;
    self.next_image_id += 1;

    const handle = gui.ImageHandle{ .id = id };
    const sdl_image = SDLImage{
        .texture = texture,
        .width = width,
        .height = height,
        .format = format,
    };

    self.images.put(id, sdl_image) catch {
        c.SDL_DestroyTexture(texture);
        return null;
    };

    return handle;
}

fn destroyImage(renderer: *gui.RendererInterface, handle: gui.ImageHandle) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    if (!handle.isValid()) return;

    if (self.images.get(handle.id)) |sdl_image| {
        c.SDL_DestroyTexture(sdl_image.texture);
        _ = self.images.remove(handle.id);
    }
}

fn createFont(renderer: *gui.RendererInterface, data: []const u8, size: f32) ?gui.FontHandle {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // SDL doesn't have built-in font handling
    // This would typically use SDL_ttf
    // For now, we'll create a placeholder handle

    const id = self.next_font_id;
    self.next_font_id += 1;

    const handle = gui.FontHandle{ .id = id };
    const sdl_font = SDLFont{
        .size = size,
        // Would store TTF_Font* here if using SDL_ttf
    };

    self.fonts.put(id, sdl_font) catch {
        return null;
    };

    _ = data;
    return handle;
}

fn destroyFont(renderer: *gui.RendererInterface, handle: gui.FontHandle) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    if (!handle.isValid()) return;

    _ = self.fonts.remove(handle.id);
    // Would free TTF_Font* if using SDL_ttf
}

fn save(renderer: *gui.RendererInterface) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // Save current clip rect
    var clip_rect: c.SDL_Rect = undefined;
    _ = c.SDL_RenderGetClipRect(self.sdl_renderer, &clip_rect);
    self.saved_clip_rects.append(clip_rect) catch {};

    // Save current color
    self.saved_colors.append(self.current_color) catch {};
}

fn restore(renderer: *gui.RendererInterface) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // Restore clip rect if there's one saved
    if (self.saved_clip_rects.items.len > 0) {
        const clip_rect = self.saved_clip_rects.pop();
        _ = c.SDL_RenderSetClipRect(self.sdl_renderer, &clip_rect);
    }

    // Restore color if there's one saved
    if (self.saved_colors.items.len > 0) {
        const color = self.saved_colors.pop();
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.r, color.g, color.b, color.a);
        self.current_color = color;
    }
}

fn clip(renderer: *gui.RendererInterface, rect: gui.Rect) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    const sdl_rect = c.SDL_Rect{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.width),
        .h = @intFromFloat(rect.height),
    };

    _ = c.SDL_RenderSetClipRect(self.sdl_renderer, &sdl_rect);
}

fn transform(renderer: *gui.RendererInterface, trans: gui.Transform) void {
    const self: Self = @fieldParentPtr("renderer_interface", renderer);

    // SDL doesn't support direct transforms in the renderer
    // This would require custom transformation in rendering pipeline
    // or using SDL_gpu or similar extension

    _ = self;
    _ = trans;
}

// Static vtable that contains function pointers to all the implementation methods
const vtable = gui.RendererInterface.VTable{
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .drawRect = drawRect,
    .drawRoundRect = drawRoundRect,
    .drawText = drawText,
    .drawImage = drawImage,
    .drawPath = drawPath,
    .createImage = createImage,
    .destroyImage = destroyImage,
    .createFont = createFont,
    .destroyFont = destroyFont,
    .save = save,
    .restore = restore,
    .clip = clip,
    .transform = transform,
};

// Helper structures for SDL-specific resource tracking
const SDLImage = struct {
    texture: *c.SDL_Texture,
    width: u32,
    height: u32,
    format: gui.ImageFormat,
};

const SDLFont = struct {
    size: f32,
    // Would store TTF_Font* or similar when using SDL_ttf
};
