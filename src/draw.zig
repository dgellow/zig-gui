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
        if (self.layer_stack.pop()) |prev| {
            self.current_layer = prev;
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
