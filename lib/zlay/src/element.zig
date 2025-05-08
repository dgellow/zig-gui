const std = @import("std");
const Style = @import("style.zig").Style;

/// Element types
pub const Element = struct {
    /// Element type
    pub const Type = enum {
        container,
        box,
        text,
        button,
        image,
        input,
        slider,
        toggle,
        custom,
    };

    /// Overflow behavior
    pub const Overflow = enum {
        /// Content that overflows is visible
        visible,
        
        /// Content that overflows is hidden (clipped)
        hidden,
        
        /// Content that overflows can be scrolled
        scroll,
        
        /// Content that overflows is scrollable if needed
        auto,
    };
    
    /// Element type
    type: Type,
    
    /// Optional element ID
    id: ?[]const u8 = null,
    
    /// Optional parent element index
    parent: ?usize = null,
    
    /// Children element indices
    children: std.ArrayList(usize),
    
    /// Element style
    style: Style = .{},
    
    /// Layout properties
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    
    /// Width as a percentage of parent (0-100)
    /// When set, takes precedence over fixed width
    width_percent: ?f32 = null,
    
    /// Height as a percentage of parent (0-100)
    /// When set, takes precedence over fixed height
    height_percent: ?f32 = null,
    
    /// Min/max dimensions
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    
    /// Custom user data
    user_data: ?*anyopaque = null,
    
    /// Is the element visible
    visible: bool = true,
    
    /// Is the element enabled for interaction
    enabled: bool = true,
    
    /// Text content (for text elements)
    text: ?[]const u8 = null,
    
    /// Element specific flags
    flags: u32 = 0,
    
    /// Layout dirty flag (set when element needs re-layout)
    layout_dirty: bool = true,
    
    /// Content size (computed during layout - may be larger than element size for scrollable containers)
    content_width: f32 = 0,
    content_height: f32 = 0,
    
    /// Scroll position (for scrollable containers)
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    
    /// Overflow behavior
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    
    /// Initialize a new Element with default values
    pub fn init() Element {
        return Element{
            .type = .box,
            .children = std.ArrayList(usize).init(std.heap.page_allocator), // Will be replaced when used
            .overflow_x = .visible,
            .overflow_y = .visible,
            .scroll_x = 0,
            .scroll_y = 0,
        };
    }
    
    /// Create a new Element with defaults
    pub fn create(allocator: std.mem.Allocator, element_type: Type) !Element {
        var element = init();
        element.type = element_type;
        element.children = std.ArrayList(usize).init(allocator);
        return element;
    }
    
    /// Clean up any resources held by the element
    pub fn deinit(self: *Element) void {
        // Free any resources the element owns
        self.children.deinit();
        
        // Clear other fields to default values
        self.id = null;
        self.parent = null;
        self.style = .{};
        self.x = 0;
        self.y = 0;
        self.width = 0;
        self.height = 0;
        self.width_percent = null;
        self.height_percent = null;
        self.min_width = null;
        self.min_height = null;
        self.max_width = null;
        self.max_height = null;
        self.user_data = null;
        self.visible = true;
        self.enabled = true;
        self.text = null;
        self.flags = 0;
        self.layout_dirty = true;
        self.content_width = 0;
        self.content_height = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.overflow_x = .visible;
        self.overflow_y = .visible;
    }
    
    /// Set text content
    pub fn setText(self: *Element, text: []const u8, allocator: std.mem.Allocator) !void {
        self.text = try allocator.dupe(u8, text);
        self.layout_dirty = true;
    }
    
    /// Set style
    pub fn setStyle(self: *Element, style: Style) void {
        self.style = style;
        self.layout_dirty = true;
    }
    
    /// Get content dimensions
    pub fn getContentSize(self: Element) struct { width: f32, height: f32 } {
        return .{
            .width = self.content_width,
            .height = self.content_height,
        };
    }
    
    /// Get element bounds with padding
    pub fn getPaddedBounds(self: Element) struct { x: f32, y: f32, width: f32, height: f32 } {
        return .{
            .x = self.x + self.style.padding_left,
            .y = self.y + self.style.padding_top,
            .width = self.width - self.style.padding_left - self.style.padding_right,
            .height = self.height - self.style.padding_top - self.style.padding_bottom,
        };
    }
    
    /// Returns true if this element is scrollable in the x direction
    pub fn isScrollableX(self: Element) bool {
        return self.overflow_x == .scroll or 
               (self.overflow_x == .auto and self.content_width > self.width);
    }
    
    /// Returns true if this element is scrollable in the y direction
    pub fn isScrollableY(self: Element) bool {
        return self.overflow_y == .scroll or 
               (self.overflow_y == .auto and self.content_height > self.height);
    }
    
    /// Returns how far this container can be scrolled in the X direction
    pub fn getMaxScrollX(self: Element) f32 {
        return @max(0.0, self.content_width - self.width + self.style.padding_left + self.style.padding_right);
    }
    
    /// Returns how far this container can be scrolled in the Y direction
    pub fn getMaxScrollY(self: Element) f32 {
        return @max(0.0, self.content_height - self.height + self.style.padding_top + self.style.padding_bottom);
    }
    
    /// Set scrolling behavior for both axes
    pub fn setOverflow(self: *Element, overflow: Overflow) void {
        self.overflow_x = overflow;
        self.overflow_y = overflow;
        self.layout_dirty = true;
    }
    
    /// Set horizontal scrolling behavior
    pub fn setOverflowX(self: *Element, overflow: Overflow) void {
        self.overflow_x = overflow;
        self.layout_dirty = true;
    }
    
    /// Set vertical scrolling behavior
    pub fn setOverflowY(self: *Element, overflow: Overflow) void {
        self.overflow_y = overflow;
        self.layout_dirty = true;
    }
    
    /// Set scroll position (with bounds checking)
    pub fn setScrollPosition(self: *Element, x: f32, y: f32) void {
        // Clamp scroll position to valid range
        self.scroll_x = @min(@max(0.0, x), self.getMaxScrollX());
        self.scroll_y = @min(@max(0.0, y), self.getMaxScrollY());
    }
    
    /// Scroll by a relative amount (with bounds checking)
    pub fn scrollBy(self: *Element, delta_x: f32, delta_y: f32) void {
        self.setScrollPosition(self.scroll_x + delta_x, self.scroll_y + delta_y);
    }
    
    /// Scroll to the beginning
    pub fn scrollToBeginning(self: *Element) void {
        self.scroll_x = 0;
        self.scroll_y = 0;
    }
    
    /// Scroll to the end
    pub fn scrollToEnd(self: *Element) void {
        self.scroll_x = self.getMaxScrollX();
        self.scroll_y = self.getMaxScrollY();
    }
    
    /// Get content rectangle in local space (accounting for scroll position)
    pub fn getContentRect(self: Element) struct { x: f32, y: f32, width: f32, height: f32 } {
        const padded = self.getPaddedBounds();
        return .{
            .x = padded.x - self.scroll_x,
            .y = padded.y - self.scroll_y,
            .width = self.content_width,
            .height = self.content_height,
        };
    }
    
    /// Returns true if content is clipped (either hidden or scrollable)
    pub fn isContentClipped(self: Element) bool {
        return self.overflow_x != .visible or self.overflow_y != .visible;
    }
    
    /// Returns true if the element is culled (outside the visible area of a scrollable container)
    /// This uses bit 0 of the flags field which is set during the scrollOffset application
    pub fn isCulled(self: Element) bool {
        return (self.flags & @as(u32, 1)) != 0;
    }
    
    /// Set or clear the culled flag 
    pub fn setCulled(self: *Element, culled: bool) void {
        if (culled) {
            self.flags |= @as(u32, 1);  // Set bit 0
        } else {
            self.flags &= ~@as(u32, 1); // Clear bit 0
        }
    }
};

test "element basics" {
    var element = Element{
        .type = .box,
        .id = "test",
        .width = 100,
        .height = 50,
        .children = std.ArrayList(usize).init(std.testing.allocator),
    };
    defer element.children.deinit();
    
    try std.testing.expectEqual(Element.Type.box, element.type);
    try std.testing.expectEqualStrings("test", element.id.?);
    try std.testing.expectEqual(@as(f32, 100), element.width);
    try std.testing.expectEqual(@as(f32, 50), element.height);
    
    // Test style setting
    var style = Style{};
    style.background_color = Style.defaultTextColor;
    style.setPadding(10);
    element.setStyle(style);
    
    try std.testing.expectEqual(@as(f32, 10), element.style.padding_left);
    try std.testing.expect(element.layout_dirty);
    
    // Test padded bounds
    const bounds = element.getPaddedBounds();
    try std.testing.expectEqual(@as(f32, 10), bounds.x);
    try std.testing.expectEqual(@as(f32, 10), bounds.y);
    try std.testing.expectEqual(@as(f32, 80), bounds.width);
    try std.testing.expectEqual(@as(f32, 30), bounds.height);
}