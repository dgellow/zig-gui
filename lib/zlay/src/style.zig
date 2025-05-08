const std = @import("std");
const Color = @import("color.zig").Color;

/// Style properties for elements
pub const Style = struct {
    /// Background color
    background_color: ?Color = null,
    
    /// Border color
    border_color: ?Color = null,
    
    /// Text color
    text_color: ?Color = null,
    
    /// Border width
    border_width: f32 = 0,
    
    /// Corner radius
    corner_radius: f32 = 0,
    
    /// Padding
    padding_left: f32 = 0,
    padding_right: f32 = 0,
    padding_top: f32 = 0,
    padding_bottom: f32 = 0,
    
    /// Margin
    margin_left: f32 = 0,
    margin_right: f32 = 0,
    margin_top: f32 = 0,
    margin_bottom: f32 = 0,
    
    /// Font properties
    font_size: f32 = 16,
    font_name: ?[]const u8 = null,
    
    /// Layout direction for container elements
    direction: Direction = .column,
    
    /// Layout properties
    align_h: Align = .start,
    align_v: Align = .start,
    
    /// Flex properties
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: ?f32 = null,
    
    /// Enable clipping of children to this element's bounds
    clip: bool = false,
    
    /// Default text color
    pub const defaultTextColor = Color.black;
    
    /// Layout direction
    pub const Direction = enum {
        /// Elements laid out horizontally (left to right)
        row,
        
        /// Elements laid out vertically (top to bottom)
        column
    };
    
    /// Alignment options
    pub const Align = enum {
        start,
        center,
        end,
        space_between,
        space_around,
        space_evenly
    };
    
    /// Set uniform padding on all sides
    pub fn setPadding(self: *Style, padding: f32) void {
        self.padding_left = padding;
        self.padding_right = padding;
        self.padding_top = padding;
        self.padding_bottom = padding;
    }
    
    /// Set uniform margin on all sides
    pub fn setMargin(self: *Style, margin: f32) void {
        self.margin_left = margin;
        self.margin_right = margin;
        self.margin_top = margin;
        self.margin_bottom = margin;
    }
    
    /// Set horizontal padding
    pub fn setPaddingH(self: *Style, padding: f32) void {
        self.padding_left = padding;
        self.padding_right = padding;
    }
    
    /// Set vertical padding
    pub fn setPaddingV(self: *Style, padding: f32) void {
        self.padding_top = padding;
        self.padding_bottom = padding;
    }
    
    /// Set horizontal margin
    pub fn setMarginH(self: *Style, margin: f32) void {
        self.margin_left = margin;
        self.margin_right = margin;
    }
    
    /// Set vertical margin
    pub fn setMarginV(self: *Style, margin: f32) void {
        self.margin_top = margin;
        self.margin_bottom = margin;
    }
    
    /// Create a simple style with background color
    pub fn background(color: Color) Style {
        var style = Style{};
        style.background_color = color;
        return style;
    }
    
    /// Create a button style
    pub fn button(bg_color: Color, text_color: Color) Style {
        var style = Style{};
        style.background_color = bg_color;
        style.text_color = text_color;
        style.corner_radius = 5;
        style.setPadding(10);
        return style;
    }
    
    /// Create a container style
    pub fn container(bg_color: ?Color) Style {
        var style = Style{};
        style.background_color = bg_color;
        style.setPadding(10);
        return style;
    }
    
    /// Copy style
    pub fn clone(self: Style) Style {
        return self;
    }
};

test "style basics" {
    var style = Style{};
    
    style.setPadding(10);
    try std.testing.expectEqual(@as(f32, 10), style.padding_left);
    try std.testing.expectEqual(@as(f32, 10), style.padding_right);
    try std.testing.expectEqual(@as(f32, 10), style.padding_top);
    try std.testing.expectEqual(@as(f32, 10), style.padding_bottom);
    
    style.setMargin(5);
    try std.testing.expectEqual(@as(f32, 5), style.margin_left);
    try std.testing.expectEqual(@as(f32, 5), style.margin_right);
    try std.testing.expectEqual(@as(f32, 5), style.margin_top);
    try std.testing.expectEqual(@as(f32, 5), style.margin_bottom);
    
    // Test factory methods
    const button_style = Style.button(Color.blue, Color.white);
    try std.testing.expect(button_style.background_color != null);
    try std.testing.expectEqual(Color.blue, button_style.background_color.?);
    try std.testing.expectEqual(Color.white, button_style.text_color.?);
    try std.testing.expectEqual(@as(f32, 5), button_style.corner_radius);
}