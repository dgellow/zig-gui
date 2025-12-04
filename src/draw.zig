//! Draw System - BYOR (Bring Your Own Renderer) Architecture
//!
//! zig-gui outputs draw commands; users implement rendering however they want.
//! Inspired by Dear ImGui's backend system.
//!
//! Pipeline: Widget Calls → Layout Compute → Draw Generation → Backend Render
//!
//! See DESIGN.md "Draw System" section for full documentation.

const std = @import("std");
const geometry = @import("core/geometry.zig");
const color_mod = @import("core/color.zig");

pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Color = color_mod.Color;

// =============================================================================
// Draw Primitives
// =============================================================================

/// Union of all drawable primitives
pub const DrawPrimitive = union(enum) {
    /// Filled rectangle (backgrounds, buttons)
    fill_rect: FillRect,

    /// Stroked rectangle (borders, outlines)
    stroke_rect: StrokeRect,

    /// Text rendering
    text: TextDraw,

    /// Line segment
    line: LineDraw,

    /// Custom vertices (advanced: gradients, custom shapes)
    vertices: VerticesDraw,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
        corner_radius: f32 = 0,
    };

    pub const StrokeRect = struct {
        rect: Rect,
        color: Color,
        stroke_width: f32 = 1,
        corner_radius: f32 = 0,
    };

    pub const TextDraw = struct {
        position: Point,
        text: []const u8, // Pointer to string (lifetime: frame)
        color: Color,
        font_size: f32 = 14,
        font_id: u16 = 0, // Backend-specific font handle
    };

    pub const LineDraw = struct {
        start: Point,
        end: Point,
        color: Color,
        width: f32 = 1,
    };

    pub const VerticesDraw = struct {
        vertices: []const Vertex,
        indices: []const u16,
        texture_id: u32 = 0, // 0 = no texture
    };

    pub const Vertex = struct {
        pos: [2]f32,
        uv: [2]f32 = .{ 0, 0 },
        color: [4]u8, // RGBA
    };
};

// =============================================================================
// Draw Command
// =============================================================================

/// A single draw command with rendering context
pub const DrawCommand = struct {
    /// The primitive to draw
    primitive: DrawPrimitive,

    /// Clip rectangle (null = no clipping)
    clip_rect: ?Rect = null,

    /// Layer for z-ordering (higher = on top)
    layer: u16 = 0,

    /// Source widget ID (for debugging, hit testing)
    widget_id: u32 = 0,
};

// =============================================================================
// Draw List
// =============================================================================

/// Accumulates draw commands during frame rendering
pub const DrawList = struct {
    commands: std.ArrayList(DrawCommand),
    allocator: std.mem.Allocator,

    // State stacks for hierarchical rendering
    clip_stack: std.BoundedArray(Rect, 16) = .{},
    layer_stack: std.BoundedArray(u16, 16) = .{},

    current_layer: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{
            .commands = std.ArrayList(DrawCommand).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.commands.deinit();
    }

    pub fn clear(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.clip_stack.len = 0;
        self.layer_stack.len = 0;
        self.current_layer = 0;
    }

    /// Get the number of commands in the list
    pub fn commandCount(self: *const DrawList) usize {
        return self.commands.items.len;
    }

    // === Drawing functions ===

    pub fn addFilledRect(self: *DrawList, rect: Rect, draw_color: Color) void {
        self.addFilledRectEx(rect, draw_color, 0);
    }

    pub fn addFilledRectEx(self: *DrawList, rect: Rect, draw_color: Color, corner_radius: f32) void {
        self.commands.append(.{
            .primitive = .{ .fill_rect = .{
                .rect = rect,
                .color = draw_color,
                .corner_radius = corner_radius,
            } },
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addStrokeRect(self: *DrawList, rect: Rect, draw_color: Color, width: f32) void {
        self.addStrokeRectEx(rect, draw_color, width, 0);
    }

    pub fn addStrokeRectEx(self: *DrawList, rect: Rect, draw_color: Color, width: f32, corner_radius: f32) void {
        self.commands.append(.{
            .primitive = .{ .stroke_rect = .{
                .rect = rect,
                .color = draw_color,
                .stroke_width = width,
                .corner_radius = corner_radius,
            } },
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addText(self: *DrawList, pos: Point, text: []const u8, draw_color: Color) void {
        self.addTextEx(pos, text, draw_color, 14, 0);
    }

    pub fn addTextEx(self: *DrawList, pos: Point, text: []const u8, draw_color: Color, font_size: f32, font_id: u16) void {
        self.commands.append(.{
            .primitive = .{ .text = .{
                .position = pos,
                .text = text,
                .color = draw_color,
                .font_size = font_size,
                .font_id = font_id,
            } },
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addLine(self: *DrawList, start: Point, end: Point, draw_color: Color, width: f32) void {
        self.commands.append(.{
            .primitive = .{ .line = .{
                .start = start,
                .end = end,
                .color = draw_color,
                .width = width,
            } },
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addVertices(self: *DrawList, vertices: []const DrawPrimitive.Vertex, indices: []const u16, texture_id: u32) void {
        self.commands.append(.{
            .primitive = .{ .vertices = .{
                .vertices = vertices,
                .indices = indices,
                .texture_id = texture_id,
            } },
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    // === Clip stack ===

    pub fn pushClip(self: *DrawList, rect: Rect) void {
        const clipped = if (self.currentClip()) |current|
            rectIntersect(rect, current)
        else
            rect;
        self.clip_stack.append(clipped) catch {};
    }

    pub fn popClip(self: *DrawList) void {
        _ = self.clip_stack.pop();
    }

    pub fn currentClip(self: *const DrawList) ?Rect {
        if (self.clip_stack.len == 0) return null;
        return self.clip_stack.buffer[self.clip_stack.len - 1];
    }

    // === Layer stack ===

    pub fn pushLayer(self: *DrawList) void {
        self.layer_stack.append(self.current_layer) catch {};
        self.current_layer += 1;
    }

    pub fn popLayer(self: *DrawList) void {
        if (self.layer_stack.len > 0) {
            self.current_layer = self.layer_stack.pop();
        }
    }

    /// Get commands slice for iteration
    pub fn getCommands(self: *const DrawList) []const DrawCommand {
        return self.commands.items;
    }
};

// =============================================================================
// Draw Data
// =============================================================================

/// Output passed to render backends
pub const DrawData = struct {
    /// All draw commands for this frame
    commands: []const DrawCommand,

    /// Display dimensions
    display_size: Size,

    /// Framebuffer scale (for high-DPI: 2.0 on Retina)
    framebuffer_scale: f32 = 1.0,

    /// Total vertex count (for backends that pre-allocate)
    total_vertex_count: u32 = 0,

    /// Total index count
    total_index_count: u32 = 0,

    /// Check if there are any commands to render
    pub fn isEmpty(self: *const DrawData) bool {
        return self.commands.len == 0;
    }

    /// Get the number of draw commands
    pub fn commandCount(self: *const DrawData) usize {
        return self.commands.len;
    }
};

// =============================================================================
// Render Backend Interface
// =============================================================================

/// Vtable interface for render backends
pub const RenderBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called at start of frame
        beginFrame: *const fn (ptr: *anyopaque, data: *const DrawData) void,

        /// Render all commands
        render: *const fn (ptr: *anyopaque, data: *const DrawData) void,

        /// Called at end of frame (present, swap buffers)
        endFrame: *const fn (ptr: *anyopaque) void,

        /// Create texture from pixel data, returns texture ID
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, pixels: []const u8) u32,

        /// Destroy texture
        destroyTexture: *const fn (ptr: *anyopaque, texture_id: u32) void,

        /// Get text dimensions (for layout)
        measureText: *const fn (ptr: *anyopaque, text: []const u8, font_size: f32, font_id: u16) Size,
    };

    // Convenience wrappers
    pub fn beginFrame(self: RenderBackend, data: *const DrawData) void {
        self.vtable.beginFrame(self.ptr, data);
    }

    pub fn render(self: RenderBackend, data: *const DrawData) void {
        self.vtable.render(self.ptr, data);
    }

    pub fn endFrame(self: RenderBackend) void {
        self.vtable.endFrame(self.ptr);
    }

    pub fn createTexture(self: RenderBackend, width: u32, height: u32, pixels: []const u8) u32 {
        return self.vtable.createTexture(self.ptr, width, height, pixels);
    }

    pub fn destroyTexture(self: RenderBackend, texture_id: u32) void {
        self.vtable.destroyTexture(self.ptr, texture_id);
    }

    pub fn measureText(self: RenderBackend, text: []const u8, font_size: f32, font_id: u16) Size {
        return self.vtable.measureText(self.ptr, text, font_size, font_id);
    }
};

// =============================================================================
// Widget Render Info
// =============================================================================

/// Render information stored during widget calls
pub const WidgetRenderInfo = struct {
    /// Widget type for dispatch
    widget_type: WidgetType,

    /// Display label (for buttons, text)
    /// Points to comptime string = zero cost
    /// Points to runtime string = must outlive frame
    label: ?[]const u8 = null,

    /// Colors (null = use theme defaults)
    background_color: ?Color = null,
    text_color: ?Color = null,
    border_color: ?Color = null,

    /// Visual state
    is_hovered: bool = false,
    is_pressed: bool = false,
    is_focused: bool = false,
    is_disabled: bool = false,

    pub const WidgetType = enum(u8) {
        container,
        button,
        text,
        text_input,
        checkbox,
        slider,
        separator,
        image,
        custom,
    };
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute intersection of two rectangles
pub fn rectIntersect(a: Rect, b: Rect) Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.width, b.x + b.width);
    const y2 = @min(a.y + a.height, b.y + b.height);

    if (x2 <= x1 or y2 <= y1) {
        return Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    return Rect{
        .x = x1,
        .y = y1,
        .width = x2 - x1,
        .height = y2 - y1,
    };
}

/// Convert Color to ARGB u32 format
pub fn colorToARGB(c: Color) u32 {
    return (@as(u32, c.a) << 24) | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
}

/// Convert Color to RGBA u32 format
pub fn colorToRGBA(c: Color) u32 {
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | @as(u32, c.a);
}

// =============================================================================
// Null/Test Backend
// =============================================================================

/// A no-op backend useful for testing and headless rendering
pub const NullBackend = struct {
    render_count: u32 = 0,
    last_command_count: usize = 0,

    pub fn init() NullBackend {
        return .{};
    }

    pub fn interface(self: *NullBackend) RenderBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = RenderBackend.VTable{
        .beginFrame = beginFrameImpl,
        .render = renderImpl,
        .endFrame = endFrameImpl,
        .createTexture = createTextureImpl,
        .destroyTexture = destroyTextureImpl,
        .measureText = measureTextImpl,
    };

    fn beginFrameImpl(_: *anyopaque, _: *const DrawData) void {}

    fn renderImpl(ptr: *anyopaque, data: *const DrawData) void {
        const self: *NullBackend = @ptrCast(@alignCast(ptr));
        self.render_count += 1;
        self.last_command_count = data.commands.len;
    }

    fn endFrameImpl(_: *anyopaque) void {}

    fn createTextureImpl(_: *anyopaque, _: u32, _: u32, _: []const u8) u32 {
        return 1; // Return dummy texture ID
    }

    fn destroyTextureImpl(_: *anyopaque, _: u32) void {}

    fn measureTextImpl(_: *anyopaque, text: []const u8, font_size: f32, _: u16) Size {
        // Simple approximation: 0.6 * font_size per character
        const char_width = font_size * 0.6;
        return Size{
            .width = @as(f32, @floatFromInt(text.len)) * char_width,
            .height = font_size,
        };
    }
};

// =============================================================================
// Software Rasterizer Backend
// =============================================================================

/// A software rasterizer that renders to a pixel buffer.
/// Suitable for embedded systems, headless testing, and image output.
pub const SoftwareBackend = struct {
    pixels: []u32, // ARGB format
    width: u32,
    height: u32,
    clear_color: u32 = 0xFF000000, // Opaque black

    pub fn init(pixels: []u32, width: u32, height: u32) SoftwareBackend {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    /// Create a backend with its own allocated buffer
    pub fn initAlloc(allocator: std.mem.Allocator, width: u32, height: u32) !SoftwareBackend {
        const pixels = try allocator.alloc(u32, width * height);
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *SoftwareBackend, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn interface(self: *SoftwareBackend) RenderBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = RenderBackend.VTable{
        .beginFrame = beginFrameImpl,
        .render = renderImpl,
        .endFrame = endFrameImpl,
        .createTexture = createTextureImpl,
        .destroyTexture = destroyTextureImpl,
        .measureText = measureTextImpl,
    };

    fn beginFrameImpl(ptr: *anyopaque, _: *const DrawData) void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));
        // Clear to background color
        @memset(self.pixels, self.clear_color);
    }

    fn renderImpl(ptr: *anyopaque, data: *const DrawData) void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));

        for (data.commands) |cmd| {
            switch (cmd.primitive) {
                .fill_rect => |r| self.renderFillRect(r, cmd.clip_rect),
                .stroke_rect => |r| self.renderStrokeRect(r, cmd.clip_rect),
                .line => |l| self.renderLine(l, cmd.clip_rect),
                .text => {}, // Text rendering requires font atlas - skip for now
                .vertices => {}, // Complex - skip for basic implementation
            }
        }
    }

    fn endFrameImpl(_: *anyopaque) void {}

    fn createTextureImpl(_: *anyopaque, _: u32, _: u32, _: []const u8) u32 {
        return 1;
    }

    fn destroyTextureImpl(_: *anyopaque, _: u32) void {}

    fn measureTextImpl(_: *anyopaque, text: []const u8, font_size: f32, _: u16) Size {
        const char_width = font_size * 0.6;
        return Size{
            .width = @as(f32, @floatFromInt(text.len)) * char_width,
            .height = font_size,
        };
    }

    // === Rendering primitives ===

    fn renderFillRect(self: *SoftwareBackend, r: DrawPrimitive.FillRect, clip: ?Rect) void {
        const bounds = self.clipRect(r.rect, clip);
        if (bounds.width <= 0 or bounds.height <= 0) return;

        const color = colorToARGB(r.color);
        const x0 = self.clampX(bounds.x);
        const y0 = self.clampY(bounds.y);
        const x1 = self.clampX(bounds.x + bounds.width);
        const y1 = self.clampY(bounds.y + bounds.height);

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                self.blendPixel(x, y, color);
            }
        }
    }

    fn renderStrokeRect(self: *SoftwareBackend, r: DrawPrimitive.StrokeRect, clip: ?Rect) void {
        const bounds = self.clipRect(r.rect, clip);
        if (bounds.width <= 0 or bounds.height <= 0) return;

        const color = colorToARGB(r.color);
        const stroke = @max(1, @as(u32, @intFromFloat(r.stroke_width)));

        const x0 = self.clampX(bounds.x);
        const y0 = self.clampY(bounds.y);
        const x1 = self.clampX(bounds.x + bounds.width);
        const y1 = self.clampY(bounds.y + bounds.height);

        // Top edge
        self.fillHorizontalLine(x0, x1, y0, stroke, color);
        // Bottom edge
        if (y1 > y0 + stroke) {
            self.fillHorizontalLine(x0, x1, y1 - stroke, stroke, color);
        }
        // Left edge
        self.fillVerticalLine(x0, y0, y1, stroke, color);
        // Right edge
        if (x1 > x0 + stroke) {
            self.fillVerticalLine(x1 - stroke, y0, y1, stroke, color);
        }
    }

    fn renderLine(self: *SoftwareBackend, l: DrawPrimitive.LineDraw, clip: ?Rect) void {
        _ = clip; // TODO: proper line clipping

        const color = colorToARGB(l.color);
        const x0_f = l.start.x;
        const y0_f = l.start.y;
        const x1_f = l.end.x;
        const y1_f = l.end.y;

        // Bresenham's line algorithm
        const x0_i: i32 = @intFromFloat(x0_f);
        const y0_i: i32 = @intFromFloat(y0_f);
        const x1_i: i32 = @intFromFloat(x1_f);
        const y1_i: i32 = @intFromFloat(y1_f);

        const dx: i32 = @intCast(@abs(x1_i - x0_i));
        const dy: i32 = -@as(i32, @intCast(@abs(y1_i - y0_i)));
        const sx: i32 = if (x0_i < x1_i) 1 else -1;
        const sy: i32 = if (y0_i < y1_i) 1 else -1;
        var err = dx + dy;

        var x = x0_i;
        var y = y0_i;

        while (true) {
            if (x >= 0 and y >= 0 and x < @as(i32, @intCast(self.width)) and y < @as(i32, @intCast(self.height))) {
                self.blendPixel(@intCast(x), @intCast(y), color);
            }

            if (x == x1_i and y == y1_i) break;

            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    // === Helper functions ===

    fn clipRect(self: *SoftwareBackend, rect: Rect, clip: ?Rect) Rect {
        var result = rect;
        if (clip) |c| {
            result = rectIntersect(result, c);
        }
        // Also clip to screen bounds
        return rectIntersect(result, Rect{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        });
    }

    fn clampX(self: *SoftwareBackend, x: f32) u32 {
        if (x < 0) return 0;
        const xi: u32 = @intFromFloat(x);
        return @min(xi, self.width);
    }

    fn clampY(self: *SoftwareBackend, y: f32) u32 {
        if (y < 0) return 0;
        const yi: u32 = @intFromFloat(y);
        return @min(yi, self.height);
    }

    fn fillHorizontalLine(self: *SoftwareBackend, x0: u32, x1: u32, y: u32, thickness: u32, color: u32) void {
        var yi = y;
        const y_end = @min(y + thickness, self.height);
        while (yi < y_end) : (yi += 1) {
            var xi = x0;
            while (xi < x1) : (xi += 1) {
                self.blendPixel(xi, yi, color);
            }
        }
    }

    fn fillVerticalLine(self: *SoftwareBackend, x: u32, y0: u32, y1: u32, thickness: u32, color: u32) void {
        var xi = x;
        const x_end = @min(x + thickness, self.width);
        while (xi < x_end) : (xi += 1) {
            var yi = y0;
            while (yi < y1) : (yi += 1) {
                self.blendPixel(xi, yi, color);
            }
        }
    }

    fn blendPixel(self: *SoftwareBackend, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;

        const idx = y * self.width + x;
        const src_a = (color >> 24) & 0xFF;

        if (src_a == 255) {
            // Fully opaque - just write
            self.pixels[idx] = color;
        } else if (src_a > 0) {
            // Alpha blend
            const dst = self.pixels[idx];
            const dst_r = (dst >> 16) & 0xFF;
            const dst_g = (dst >> 8) & 0xFF;
            const dst_b = dst & 0xFF;

            const src_r = (color >> 16) & 0xFF;
            const src_g = (color >> 8) & 0xFF;
            const src_b = color & 0xFF;

            const inv_a = 255 - src_a;
            const out_r = (src_r * src_a + dst_r * inv_a) / 255;
            const out_g = (src_g * src_a + dst_g * inv_a) / 255;
            const out_b = (src_b * src_a + dst_b * inv_a) / 255;

            self.pixels[idx] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
        }
    }

    // === Image output ===

    /// Write the framebuffer to a PPM file (P3 format - ASCII)
    pub fn writePPM(self: *const SoftwareBackend, writer: anytype) !void {
        try writer.print("P3\n{} {}\n255\n", .{ self.width, self.height });

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const pixel = self.pixels[y * self.width + x];
                const r = (pixel >> 16) & 0xFF;
                const g = (pixel >> 8) & 0xFF;
                const b = pixel & 0xFF;
                try writer.print("{} {} {} ", .{ r, g, b });
            }
            try writer.print("\n", .{});
        }
    }

    /// Get pixel at (x, y) - for testing
    pub fn getPixel(self: *const SoftwareBackend, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[y * self.width + x];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DrawList basic operations" {
    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Add some primitives
    draw_list.addFilledRect(
        .{ .x = 0, .y = 0, .width = 100, .height = 50 },
        Color.fromRGB(255, 0, 0),
    );

    draw_list.addText(
        .{ .x = 10, .y = 10 },
        "Hello",
        Color.fromRGB(0, 0, 0),
    );

    draw_list.addLine(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
        Color.fromRGB(0, 255, 0),
        2.0,
    );

    try std.testing.expectEqual(@as(usize, 3), draw_list.commandCount());
}

test "DrawList clip stack" {
    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // No clip initially
    try std.testing.expectEqual(@as(?Rect, null), draw_list.currentClip());

    // Push a clip
    draw_list.pushClip(.{ .x = 10, .y = 10, .width = 100, .height = 100 });
    const clip1 = draw_list.currentClip().?;
    try std.testing.expectEqual(@as(f32, 10), clip1.x);
    try std.testing.expectEqual(@as(f32, 100), clip1.width);

    // Push nested clip (should intersect)
    draw_list.pushClip(.{ .x = 50, .y = 50, .width = 200, .height = 200 });
    const clip2 = draw_list.currentClip().?;
    try std.testing.expectEqual(@as(f32, 50), clip2.x);
    try std.testing.expectEqual(@as(f32, 60), clip2.width); // 10+100 - 50 = 60

    // Pop returns to outer clip
    draw_list.popClip();
    const clip3 = draw_list.currentClip().?;
    try std.testing.expectEqual(@as(f32, 10), clip3.x);

    // Pop removes all clips
    draw_list.popClip();
    try std.testing.expectEqual(@as(?Rect, null), draw_list.currentClip());
}

test "DrawList layer stack" {
    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    try std.testing.expectEqual(@as(u16, 0), draw_list.current_layer);

    draw_list.pushLayer();
    try std.testing.expectEqual(@as(u16, 1), draw_list.current_layer);

    draw_list.pushLayer();
    try std.testing.expectEqual(@as(u16, 2), draw_list.current_layer);

    draw_list.popLayer();
    try std.testing.expectEqual(@as(u16, 1), draw_list.current_layer);

    draw_list.popLayer();
    try std.testing.expectEqual(@as(u16, 0), draw_list.current_layer);
}

test "DrawList commands include clip and layer" {
    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Add command without clip
    draw_list.addFilledRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, Color.fromRGB(255, 0, 0));

    // Push clip and layer, add another command
    draw_list.pushClip(.{ .x = 5, .y = 5, .width = 50, .height = 50 });
    draw_list.pushLayer();
    draw_list.addFilledRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, Color.fromRGB(0, 255, 0));

    const commands = draw_list.getCommands();
    try std.testing.expectEqual(@as(usize, 2), commands.len);

    // First command: no clip, layer 0
    try std.testing.expectEqual(@as(?Rect, null), commands[0].clip_rect);
    try std.testing.expectEqual(@as(u16, 0), commands[0].layer);

    // Second command: has clip, layer 1
    try std.testing.expect(commands[1].clip_rect != null);
    try std.testing.expectEqual(@as(u16, 1), commands[1].layer);
}

test "rectIntersect" {
    // Overlapping rectangles
    const a = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const b = Rect{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const result = rectIntersect(a, b);

    try std.testing.expectEqual(@as(f32, 50), result.x);
    try std.testing.expectEqual(@as(f32, 50), result.y);
    try std.testing.expectEqual(@as(f32, 50), result.width);
    try std.testing.expectEqual(@as(f32, 50), result.height);

    // Non-overlapping rectangles
    const c = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const d = Rect{ .x = 20, .y = 20, .width = 10, .height = 10 };
    const empty = rectIntersect(c, d);

    try std.testing.expectEqual(@as(f32, 0), empty.width);
    try std.testing.expectEqual(@as(f32, 0), empty.height);
}

test "NullBackend" {
    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    draw_list.addFilledRect(.{ .x = 0, .y = 0, .width = 100, .height = 50 }, Color.fromRGB(255, 0, 0));
    draw_list.addText(.{ .x = 10, .y = 10 }, "Test", Color.fromRGB(0, 0, 0));

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 800, .height = 600 },
    };

    var backend = NullBackend.init();
    const iface = backend.interface();

    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    try std.testing.expectEqual(@as(u32, 1), backend.render_count);
    try std.testing.expectEqual(@as(usize, 2), backend.last_command_count);

    // Test measureText
    const text_size = iface.measureText("Hello", 14.0, 0);
    try std.testing.expect(text_size.width > 0);
    try std.testing.expectEqual(@as(f32, 14.0), text_size.height);
}

test "colorToARGB" {
    const c = Color.fromRGBA(255, 128, 64, 200);
    const argb = colorToARGB(c);

    // ARGB: A=200, R=255, G=128, B=64
    try std.testing.expectEqual(@as(u32, 0xC8FF8040), argb);
}

test "DrawData isEmpty" {
    const empty_data = DrawData{
        .commands = &[_]DrawCommand{},
        .display_size = .{ .width = 800, .height = 600 },
    };
    try std.testing.expect(empty_data.isEmpty());

    const allocator = std.testing.allocator;
    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();
    draw_list.addFilledRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, Color.fromRGB(255, 0, 0));

    const non_empty_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 800, .height = 600 },
    };
    try std.testing.expect(!non_empty_data.isEmpty());
}

// =============================================================================
// SoftwareBackend Tests
// =============================================================================

test "SoftwareBackend fills rectangle" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 100, 100);
    defer backend.deinit(allocator);

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Draw a red rectangle at (10, 10) size 20x20
    draw_list.addFilledRect(
        .{ .x = 10, .y = 10, .width = 20, .height = 20 },
        Color.fromRGB(255, 0, 0),
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 100, .height = 100 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Check pixel inside rectangle is red (0xFFFF0000 in ARGB)
    const inside = backend.getPixel(15, 15);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), inside);

    // Check pixel outside rectangle is black (clear color)
    const outside = backend.getPixel(5, 5);
    try std.testing.expectEqual(@as(u32, 0xFF000000), outside);
}

test "SoftwareBackend strokes rectangle" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 100, 100);
    defer backend.deinit(allocator);

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Draw a green stroked rectangle at (10, 10) size 30x30, stroke width 2
    draw_list.addStrokeRectEx(
        .{ .x = 10, .y = 10, .width = 30, .height = 30 },
        Color.fromRGB(0, 255, 0),
        2,
        0,
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 100, .height = 100 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Check pixel on top edge is green
    const top_edge = backend.getPixel(20, 10);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), top_edge);

    // Check pixel on left edge is green
    const left_edge = backend.getPixel(10, 20);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), left_edge);

    // Check pixel inside (not on edge) is black
    const inside = backend.getPixel(25, 25);
    try std.testing.expectEqual(@as(u32, 0xFF000000), inside);
}

test "SoftwareBackend draws line" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 100, 100);
    defer backend.deinit(allocator);

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Draw a diagonal blue line from (0,0) to (50,50)
    draw_list.addLine(
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 50 },
        Color.fromRGB(0, 0, 255),
        1,
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 100, .height = 100 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Diagonal line should have pixels along y=x
    const on_line = backend.getPixel(25, 25);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), on_line);

    // Off the line should be black
    const off_line = backend.getPixel(25, 10);
    try std.testing.expectEqual(@as(u32, 0xFF000000), off_line);
}

test "SoftwareBackend respects clipping" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 100, 100);
    defer backend.deinit(allocator);

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Push a clip rect that only allows 20x20 starting at (30,30)
    draw_list.pushClip(.{ .x = 30, .y = 30, .width = 20, .height = 20 });

    // Try to draw a large rectangle - should be clipped
    draw_list.addFilledRect(
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        Color.fromRGB(255, 255, 0),
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 100, .height = 100 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Pixel inside clip region should be yellow
    const inside_clip = backend.getPixel(35, 35);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), inside_clip);

    // Pixel outside clip region should be black (not rendered)
    const outside_clip = backend.getPixel(10, 10);
    try std.testing.expectEqual(@as(u32, 0xFF000000), outside_clip);
}

test "SoftwareBackend alpha blending" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 100, 100);
    defer backend.deinit(allocator);

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Draw solid red background
    draw_list.addFilledRect(
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        Color.fromRGB(255, 0, 0),
    );

    // Draw semi-transparent blue on top (50% alpha)
    draw_list.addFilledRect(
        .{ .x = 25, .y = 25, .width = 50, .height = 50 },
        Color.fromRGBA(0, 0, 255, 128),
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 100, .height = 100 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Outside the blue rect - pure red
    const pure_red = backend.getPixel(10, 10);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pure_red);

    // Inside the blue rect - blended (red + blue at ~50% = purple-ish)
    const blended = backend.getPixel(50, 50);
    const r = (blended >> 16) & 0xFF;
    const g = (blended >> 8) & 0xFF;
    const b = blended & 0xFF;

    // Red should be reduced, blue should be present
    try std.testing.expect(r > 100 and r < 200); // ~127
    try std.testing.expectEqual(@as(u32, 0), g);
    try std.testing.expect(b > 100 and b < 200); // ~128
}

test "SoftwareBackend end-to-end with multiple primitives" {
    const allocator = std.testing.allocator;
    var backend = try SoftwareBackend.initAlloc(allocator, 200, 150);
    defer backend.deinit(allocator);

    backend.clear_color = 0xFF333333; // Dark gray background

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    // Button background
    draw_list.addFilledRectEx(
        .{ .x = 20, .y = 20, .width = 160, .height = 40 },
        Color.fromRGB(66, 133, 244), // Google blue
        0,
    );

    // Button border
    draw_list.addStrokeRect(
        .{ .x = 20, .y = 20, .width = 160, .height = 40 },
        Color.fromRGB(255, 255, 255),
        2,
    );

    // A line underneath
    draw_list.addLine(
        .{ .x = 20, .y = 80 },
        .{ .x = 180, .y = 80 },
        Color.fromRGB(200, 200, 200),
        1,
    );

    // Another box
    draw_list.addFilledRect(
        .{ .x = 20, .y = 100, .width = 60, .height = 30 },
        Color.fromRGB(234, 67, 53), // Google red
    );

    const draw_data = DrawData{
        .commands = draw_list.getCommands(),
        .display_size = .{ .width = 200, .height = 150 },
    };

    const iface = backend.interface();
    iface.beginFrame(&draw_data);
    iface.render(&draw_data);
    iface.endFrame();

    // Verify some pixels
    // Background (outside all rects)
    try std.testing.expectEqual(@as(u32, 0xFF333333), backend.getPixel(5, 5));

    // Blue button interior
    const blue = backend.getPixel(100, 40);
    try std.testing.expectEqual(@as(u32, 0xFF4285F4), blue);

    // Red box
    const red = backend.getPixel(50, 115);
    try std.testing.expectEqual(@as(u32, 0xFFEA4335), red);

    // Line
    const line_pixel = backend.getPixel(100, 80);
    try std.testing.expectEqual(@as(u32, 0xFFC8C8C8), line_pixel);
}
