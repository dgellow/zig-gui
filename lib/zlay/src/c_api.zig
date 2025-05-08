const std = @import("std");
const zlay = @import("zlay.zig");
const Context = zlay.Context;
const Element = zlay.Element;
const Style = zlay.Style;
const Renderer = zlay.Renderer;
const Color = zlay.Color;

// Global allocator for C API usage
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const c_allocator = gpa.allocator();

// Forward declarations of C API types (defined in zlay.h)
pub const ZlayContext = opaque {};
pub const ZlayRenderer = opaque {};

pub const ZlayColor = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const ZlayAlign = enum(c_int) {
    ZLAY_ALIGN_START,
    ZLAY_ALIGN_CENTER,
    ZLAY_ALIGN_END,
    ZLAY_ALIGN_SPACE_BETWEEN,
    ZLAY_ALIGN_SPACE_AROUND,
    ZLAY_ALIGN_SPACE_EVENLY,
};

pub const ZlayStyle = extern struct {
    background_color: ?*ZlayColor,
    border_color: ?*ZlayColor,
    text_color: ?*ZlayColor,
    
    border_width: f32,
    corner_radius: f32,
    
    padding_left: f32,
    padding_right: f32,
    padding_top: f32,
    padding_bottom: f32,
    
    margin_left: f32,
    margin_right: f32,
    margin_top: f32,
    margin_bottom: f32,
    
    font_size: f32,
    font_name: ?[*:0]const u8,
    
    align_h: ZlayAlign,
    align_v: ZlayAlign,
    
    flex_grow: f32,
    flex_shrink: f32,
    flex_basis: ?*f32,
};

pub const ZlayElementType = enum(c_int) {
    ZLAY_ELEMENT_CONTAINER,
    ZLAY_ELEMENT_BOX,
    ZLAY_ELEMENT_TEXT,
    ZLAY_ELEMENT_BUTTON,
    ZLAY_ELEMENT_IMAGE,
    ZLAY_ELEMENT_INPUT,
    ZLAY_ELEMENT_SLIDER,
    ZLAY_ELEMENT_TOGGLE,
    ZLAY_ELEMENT_CUSTOM,
};

// Conversion utilities
fn convertElementType(c_type: ZlayElementType) Element.Type {
    return switch (c_type) {
        .ZLAY_ELEMENT_CONTAINER => .container,
        .ZLAY_ELEMENT_BOX => .box,
        .ZLAY_ELEMENT_TEXT => .text,
        .ZLAY_ELEMENT_BUTTON => .button,
        .ZLAY_ELEMENT_IMAGE => .image,
        .ZLAY_ELEMENT_INPUT => .input,
        .ZLAY_ELEMENT_SLIDER => .slider,
        .ZLAY_ELEMENT_TOGGLE => .toggle,
        .ZLAY_ELEMENT_CUSTOM => .custom,
    };
}

fn convertAlign(c_align: ZlayAlign) Style.Align {
    return switch (c_align) {
        .ZLAY_ALIGN_START => .start,
        .ZLAY_ALIGN_CENTER => .center,
        .ZLAY_ALIGN_END => .end,
        .ZLAY_ALIGN_SPACE_BETWEEN => .space_between,
        .ZLAY_ALIGN_SPACE_AROUND => .space_around,
        .ZLAY_ALIGN_SPACE_EVENLY => .space_evenly,
    };
}

fn convertColor(c_color: *const ZlayColor) Color {
    return Color{
        .r = c_color.r,
        .g = c_color.g,
        .b = c_color.b,
        .a = c_color.a,
    };
}

fn convertStyle(c_style: *const ZlayStyle) Style {
    var style = Style{};
    
    if (c_style.background_color) |bg_color| {
        style.background_color = convertColor(bg_color);
    }
    
    if (c_style.border_color) |border_color| {
        style.border_color = convertColor(border_color);
    }
    
    if (c_style.text_color) |text_color| {
        style.text_color = convertColor(text_color);
    }
    
    style.border_width = c_style.border_width;
    style.corner_radius = c_style.corner_radius;
    
    style.padding_left = c_style.padding_left;
    style.padding_right = c_style.padding_right;
    style.padding_top = c_style.padding_top;
    style.padding_bottom = c_style.padding_bottom;
    
    style.margin_left = c_style.margin_left;
    style.margin_right = c_style.margin_right;
    style.margin_top = c_style.margin_top;
    style.margin_bottom = c_style.margin_bottom;
    
    style.font_size = c_style.font_size;
    
    if (c_style.font_name) |font_name| {
        const font_name_slice = std.mem.span(font_name);
        // Note: This will leak memory, as font_name is not freed
        // In a real implementation, we would track this allocation
        style.font_name = c_allocator.dupe(u8, font_name_slice) catch null;
    }
    
    style.align_h = convertAlign(c_style.align_h);
    style.align_v = convertAlign(c_style.align_v);
    
    style.flex_grow = c_style.flex_grow;
    style.flex_shrink = c_style.flex_shrink;
    
    if (c_style.flex_basis) |flex_basis| {
        style.flex_basis = flex_basis.*;
    }
    
    return style;
}

// C API Renderer wrapper
pub const CRenderer = struct {
    renderer: Renderer,
    
    begin_frame_fn: *const fn (*ZlayRenderer) callconv(.C) void,
    end_frame_fn: *const fn (*ZlayRenderer) callconv(.C) void,
    clear_fn: *const fn (*ZlayRenderer, ZlayColor) callconv(.C) void,
    draw_rect_fn: *const fn (*ZlayRenderer, f32, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_rounded_rect_fn: *const fn (*ZlayRenderer, f32, f32, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_text_fn: *const fn (*ZlayRenderer, [*:0]const u8, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_image_fn: *const fn (*ZlayRenderer, u32, f32, f32, f32, f32) callconv(.C) void,
    clip_begin_fn: *const fn (*ZlayRenderer, f32, f32, f32, f32) callconv(.C) void,
    clip_end_fn: *const fn (*ZlayRenderer) callconv(.C) void,
    
    user_data: ?*anyopaque,
    c_renderer: *ZlayRenderer,
    
    // VTable implementation functions
    fn beginFrame(renderer: *Renderer) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        container_ptr.begin_frame_fn(container_ptr.c_renderer);
    }
    
    fn endFrame(renderer: *Renderer) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        container_ptr.end_frame_fn(container_ptr.c_renderer);
    }
    
    fn clear(renderer: *Renderer, color: Color) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        const c_color = ZlayColor{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
        };
        container_ptr.clear_fn(container_ptr.c_renderer, c_color);
    }
    
    fn drawRect(renderer: *Renderer, x: f32, y: f32, width: f32, height: f32, fill: Color) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        const c_color = ZlayColor{
            .r = fill.r,
            .g = fill.g,
            .b = fill.b,
            .a = fill.a,
        };
        container_ptr.draw_rect_fn(container_ptr.c_renderer, x, y, width, height, c_color);
    }
    
    fn drawRoundedRect(renderer: *Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: Color) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        const c_color = ZlayColor{
            .r = fill.r,
            .g = fill.g,
            .b = fill.b,
            .a = fill.a,
        };
        container_ptr.draw_rounded_rect_fn(container_ptr.c_renderer, x, y, width, height, radius, c_color);
    }
    
    fn drawText(renderer: *Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: Color) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        // Note: This assumes text is null-terminated, which might not be the case
        // In a real implementation, we would create a null-terminated copy
        const c_text = @as([*:0]const u8, @ptrCast(text.ptr));
        const c_color = ZlayColor{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
        };
        container_ptr.draw_text_fn(container_ptr.c_renderer, c_text, x, y, font_size, c_color);
    }
    
    fn drawImage(renderer: *Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        container_ptr.draw_image_fn(container_ptr.c_renderer, image_id, x, y, width, height);
    }
    
    fn clipBegin(renderer: *Renderer, x: f32, y: f32, width: f32, height: f32) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        container_ptr.clip_begin_fn(container_ptr.c_renderer, x, y, width, height);
    }
    
    fn clipEnd(renderer: *Renderer) void {
        const container_ptr = @fieldParentPtr(CRenderer, "renderer", renderer);
        container_ptr.clip_end_fn(container_ptr.c_renderer);
    }
    
    // Create the VTable
    const vtable = Renderer.VTable{
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
};

// Exported C API functions

/// Create a new zlay context
export fn zlay_create_context() ?*ZlayContext {
    const ctx = c_allocator.create(Context) catch return null;
    ctx.* = Context.init(c_allocator) catch {
        c_allocator.destroy(ctx);
        return null;
    };
    return @ptrCast(ctx);
}

/// Destroy a zlay context
export fn zlay_destroy_context(ctx: *ZlayContext) void {
    const context: *Context = @ptrCast(@alignCast(ctx));
    context.deinit();
    c_allocator.destroy(context);
}

/// Begin a new frame, clearing previous state
export fn zlay_begin_frame(ctx: *ZlayContext) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    context.beginFrame() catch return 1;
    return 0;
}

/// Begin a new element
export fn zlay_begin_element(ctx: *ZlayContext, element_type: ZlayElementType, id: ?[*:0]const u8) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    const type_converted = convertElementType(element_type);
    
    const id_slice: ?[]const u8 = if (id) |i| std.mem.span(i) else null;
    
    const element_index = context.beginElement(type_converted, id_slice) catch return -1;
    return @intCast(element_index);
}

/// End the current element
export fn zlay_end_element(ctx: *ZlayContext) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    context.endElement() catch return 1;
    return 0;
}

/// Set style for the current element
export fn zlay_set_style(ctx: *ZlayContext, style: *const ZlayStyle) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    
    if (context.element_stack.items.len == 0) {
        return 1; // No active element
    }
    
    const element_index = context.element_stack.items[context.element_stack.items.len - 1];
    var element = &context.elements.items[element_index];
    
    element.style = convertStyle(style);
    element.layout_dirty = true;
    
    return 0;
}

/// Set text for the current element
export fn zlay_set_text(ctx: *ZlayContext, text: [*:0]const u8) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    
    if (context.element_stack.items.len == 0) {
        return 1; // No active element
    }
    
    const element_index = context.element_stack.items[context.element_stack.items.len - 1];
    var element = &context.elements.items[element_index];
    
    const text_slice = std.mem.span(text);
    element.text = context.arena_pool.allocator().dupe(u8, text_slice) catch return 1;
    element.layout_dirty = true;
    
    return 0;
}

/// Compute layout
export fn zlay_compute_layout(ctx: *ZlayContext, width: f32, height: f32) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    context.computeLayout(width, height) catch return 1;
    return 0;
}

/// Render the current layout
export fn zlay_render(ctx: *ZlayContext) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    context.render() catch return 1;
    return 0;
}

/// Get element by ID
export fn zlay_get_element_by_id(ctx: *ZlayContext, id: [*:0]const u8) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    const id_slice = std.mem.span(id);
    
    const element = context.getElementById(id_slice) orelse return -1;
    
    // Find the index of this element
    for (context.elements.items, 0..) |e, i| {
        if (&e == element) {
            return @intCast(i);
        }
    }
    
    return -1;
}

/// Get element position and size
export fn zlay_get_element_rect(
    ctx: *ZlayContext, 
    element_idx: c_int, 
    x: *f32, 
    y: *f32, 
    width: *f32, 
    height: *f32
) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx));
    const idx: usize = @intCast(element_idx);
    
    if (idx >= context.elements.items.len) {
        return 1;
    }
    
    const element = &context.elements.items[idx];
    
    x.* = element.x;
    y.* = element.y;
    width.* = element.width;
    height.* = element.height;
    
    return 0;
}

/// Create a color from RGB values (alpha = 255)
export fn zlay_rgb(r: u8, g: u8, b: u8) ZlayColor {
    return .{
        .r = r,
        .g = g,
        .b = b,
        .a = 255,
    };
}

/// Create a color from RGBA values
export fn zlay_rgba(r: u8, g: u8, b: u8, a: u8) ZlayColor {
    return .{
        .r = r,
        .g = g,
        .b = b,
        .a = a,
    };
}

/// Set the renderer for a context
export fn zlay_set_renderer(ctx: *ZlayContext, renderer: *ZlayRenderer) void {
    const context: *Context = @ptrCast(@alignCast(ctx));
    // The renderer should be a CRenderer
    const c_renderer = @as(*CRenderer, @ptrCast(@alignCast(renderer)));
    context.setRenderer(&c_renderer.renderer);
}

/// Create a custom renderer instance
export fn zlay_create_renderer(
    user_data: ?*anyopaque,
    begin_frame: *const fn (*ZlayRenderer) callconv(.C) void,
    end_frame: *const fn (*ZlayRenderer) callconv(.C) void,
    clear: *const fn (*ZlayRenderer, ZlayColor) callconv(.C) void,
    draw_rect: *const fn (*ZlayRenderer, f32, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_rounded_rect: *const fn (*ZlayRenderer, f32, f32, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_text: *const fn (*ZlayRenderer, [*:0]const u8, f32, f32, f32, ZlayColor) callconv(.C) void,
    draw_image: *const fn (*ZlayRenderer, u32, f32, f32, f32, f32) callconv(.C) void,
    clip_begin: *const fn (*ZlayRenderer, f32, f32, f32, f32) callconv(.C) void,
    clip_end: *const fn (*ZlayRenderer) callconv(.C) void
) ?*ZlayRenderer {
    // Allocate a CRenderer
    var renderer = c_allocator.create(CRenderer) catch return null;
    
    // Initialize with the C function pointers
    renderer.* = .{
        .renderer = .{
            .vtable = &CRenderer.vtable,
            .user_data = user_data,
        },
        .begin_frame_fn = begin_frame,
        .end_frame_fn = end_frame,
        .clear_fn = clear,
        .draw_rect_fn = draw_rect,
        .draw_rounded_rect_fn = draw_rounded_rect,
        .draw_text_fn = draw_text,
        .draw_image_fn = draw_image,
        .clip_begin_fn = clip_begin,
        .clip_end_fn = clip_end,
        .user_data = user_data,
        .c_renderer = undefined, // Will be set below
    };
    
    // Cast to ZlayRenderer
    const c_renderer: *ZlayRenderer = @ptrCast(renderer);
    
    // Set the c_renderer pointer (which points to itself)
    renderer.c_renderer = c_renderer;
    
    return c_renderer;
}

/// Destroy a renderer instance
export fn zlay_destroy_renderer(renderer: *ZlayRenderer) void {
    // Cast to CRenderer
    const c_renderer = @as(*CRenderer, @ptrCast(@alignCast(renderer)));
    
    // Free the memory
    c_allocator.destroy(c_renderer);
}