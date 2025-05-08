const std = @import("std");
const Color = @import("color.zig").Color;

/// Command type for rendering
pub const CommandType = enum {
    none,
    rect,
    rounded_rect,
    text,
    image,
    path,
    clip,
    restore,
};

/// Rendering command
pub const Command = struct {
    type: CommandType,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    color: Color = Color.black,
    radius: f32 = 0,
    text: ?[]const u8 = null,
    font_size: f32 = 16,
    image_id: ?u32 = null,
    line_width: f32 = 1,
};

/// Renderer interface for drawing elements
pub const Renderer = struct {
    /// Function pointers for renderer implementation
    vtable: *const VTable,
    
    /// User data for the renderer
    user_data: ?*anyopaque = null,
    
    /// Virtual table for renderer implementations
    pub const VTable = struct {
        /// Begin rendering frame
        beginFrame: *const fn (renderer: *Renderer) void,
        
        /// End rendering frame
        endFrame: *const fn (renderer: *Renderer) void,
        
        /// Clear screen with color
        clear: *const fn (renderer: *Renderer, color: Color) void,
        
        /// Draw a rectangle
        drawRect: *const fn (renderer: *Renderer, x: f32, y: f32, width: f32, height: f32, fill: Color) void,
        
        /// Draw a rounded rectangle
        drawRoundedRect: *const fn (renderer: *Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: Color) void,
        
        /// Draw text
        drawText: *const fn (renderer: *Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: Color) void,
        
        /// Draw image
        drawImage: *const fn (renderer: *Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void,
        
        /// Begin clip region
        clipBegin: *const fn (renderer: *Renderer, x: f32, y: f32, width: f32, height: f32) void,
        
        /// End clip region
        clipEnd: *const fn (renderer: *Renderer) void,
    };
    
    /// Begin rendering frame
    pub fn beginFrame(self: *Renderer) void {
        self.vtable.beginFrame(self);
    }
    
    /// End rendering frame
    pub fn endFrame(self: *Renderer) void {
        self.vtable.endFrame(self);
    }
    
    /// Clear screen with color
    pub fn clear(self: *Renderer, color: Color) void {
        self.vtable.clear(self, color);
    }
    
    /// Draw a rectangle
    pub fn drawRect(self: *Renderer, x: f32, y: f32, width: f32, height: f32, fill: Color) void {
        self.vtable.drawRect(self, x, y, width, height, fill);
    }
    
    /// Draw a rounded rectangle
    pub fn drawRoundedRect(self: *Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: Color) void {
        self.vtable.drawRoundedRect(self, x, y, width, height, radius, fill);
    }
    
    /// Draw text
    pub fn drawText(self: *Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: Color) void {
        self.vtable.drawText(self, text, x, y, font_size, color);
    }
    
    /// Draw image
    pub fn drawImage(self: *Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        self.vtable.drawImage(self, image_id, x, y, width, height);
    }
    
    /// Begin clip region
    pub fn clipBegin(self: *Renderer, x: f32, y: f32, width: f32, height: f32) void {
        self.vtable.clipBegin(self, x, y, width, height);
    }
    
    /// End clip region
    pub fn clipEnd(self: *Renderer) void {
        self.vtable.clipEnd(self);
    }
};