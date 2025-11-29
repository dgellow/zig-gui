const std = @import("std");

/// Core data-oriented types for the zlay layout engine
/// Designed for maximum cache efficiency and SIMD opportunities

/// 2D point with f32 precision
pub const Point = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    
    pub const ZERO = Point{ .x = 0.0, .y = 0.0 };
    
    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
    
    pub fn sub(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
    
    pub fn mul(self: Point, scalar: f32) Point {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }
    
    pub fn distance(self: Point, other: Point) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// 2D size with f32 precision
pub const Size = struct {
    width: f32 = 0.0,
    height: f32 = 0.0,
    
    pub const ZERO = Size{ .width = 0.0, .height = 0.0 };
    pub const INFINITE = Size{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
    
    pub fn area(self: Size) f32 {
        return self.width * self.height;
    }
    
    pub fn aspectRatio(self: Size) f32 {
        if (self.height == 0.0) return std.math.inf(f32);
        return self.width / self.height;
    }
    
    pub fn isEmpty(self: Size) bool {
        return self.width <= 0.0 or self.height <= 0.0;
    }
    
    pub fn min(self: Size, other: Size) Size {
        return .{
            .width = @min(self.width, other.width),
            .height = @min(self.height, other.height),
        };
    }
    
    pub fn max(self: Size, other: Size) Size {
        return .{
            .width = @max(self.width, other.width),
            .height = @max(self.height, other.height),
        };
    }
};

/// Rectangle combining position and size
pub const Rect = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 0.0,
    height: f32 = 0.0,
    
    pub const ZERO = Rect{ .x = 0.0, .y = 0.0, .width = 0.0, .height = 0.0 };
    
    pub fn fromPointSize(point: Point, rect_size: Size) Rect {
        return .{ .x = point.x, .y = point.y, .width = rect_size.width, .height = rect_size.height };
    }
    
    pub fn topLeft(self: Rect) Point {
        return .{ .x = self.x, .y = self.y };
    }
    
    pub fn topRight(self: Rect) Point {
        return .{ .x = self.x + self.width, .y = self.y };
    }
    
    pub fn bottomLeft(self: Rect) Point {
        return .{ .x = self.x, .y = self.y + self.height };
    }
    
    pub fn bottomRight(self: Rect) Point {
        return .{ .x = self.x + self.width, .y = self.y + self.height };
    }
    
    pub fn center(self: Rect) Point {
        return .{ .x = self.x + self.width * 0.5, .y = self.y + self.height * 0.5 };
    }
    
    pub fn size(self: Rect) Size {
        return .{ .width = self.width, .height = self.height };
    }
    
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and 
               point.x < self.x + self.width and
               point.y >= self.y and 
               point.y < self.y + self.height;
    }
    
    pub fn intersects(self: Rect, other: Rect) bool {
        return !(self.x + self.width <= other.x or
                other.x + other.width <= self.x or
                self.y + self.height <= other.y or
                other.y + other.height <= self.y);
    }
    
    pub fn intersection(self: Rect, other: Rect) Rect {
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(self.x + self.width, other.x + other.width);
        const bottom = @min(self.y + self.height, other.y + other.height);
        
        if (left >= right or top >= bottom) {
            return ZERO;
        }
        
        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    }
};

/// Edge insets (padding/margin) with f32 precision
pub const EdgeInsets = struct {
    left: f32 = 0.0,
    top: f32 = 0.0,
    right: f32 = 0.0,
    bottom: f32 = 0.0,
    
    pub const ZERO = EdgeInsets{};
    
    pub fn all(value: f32) EdgeInsets {
        return .{ .left = value, .top = value, .right = value, .bottom = value };
    }
    
    pub fn horizontal(value: f32) EdgeInsets {
        return .{ .left = value, .right = value };
    }
    
    pub fn vertical(value: f32) EdgeInsets {
        return .{ .top = value, .bottom = value };
    }
    
    pub fn symmetric(h_value: f32, v_value: f32) EdgeInsets {
        return .{ .left = h_value, .right = h_value, .top = v_value, .bottom = v_value };
    }
    
    pub fn totalWidth(self: EdgeInsets) f32 {
        return self.left + self.right;
    }
    
    pub fn totalHeight(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
    
    pub fn shrinkSize(self: EdgeInsets, size: Size) Size {
        return .{
            .width = @max(0.0, size.width - self.totalWidth()),
            .height = @max(0.0, size.height - self.totalHeight()),
        };
    }
    
    pub fn expandSize(self: EdgeInsets, size: Size) Size {
        return .{
            .width = size.width + self.totalWidth(),
            .height = size.height + self.totalHeight(),
        };
    }
    
    pub fn shrinkRect(self: EdgeInsets, rect: Rect) Rect {
        return .{
            .x = rect.x + self.left,
            .y = rect.y + self.top,
            .width = @max(0.0, rect.width - self.totalWidth()),
            .height = @max(0.0, rect.height - self.totalHeight()),
        };
    }
};

/// RGBA color with f32 components for precision
pub const Color = struct {
    r: f32 = 0.0,
    g: f32 = 0.0, 
    b: f32 = 0.0,
    a: f32 = 1.0,
    
    // Common colors as constants
    pub const TRANSPARENT = Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
    pub const BLACK = Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const WHITE = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const RED = Color{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const GREEN = Color{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const BLUE = Color{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
    
    /// Create color from 8-bit RGB values
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1.0,
        };
    }
    
    /// Create color from 8-bit RGBA values
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
    
    /// Create color from HSV values
    pub fn hsv(h: f32, s: f32, v: f32) Color {
        const c = v * s;
        const h_prime = h / 60.0;
        const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
        const m = v - c;
        
        var rgb_vals: [3]f32 = undefined;
        if (h_prime < 1.0) {
            rgb_vals = .{ c, x, 0.0 };
        } else if (h_prime < 2.0) {
            rgb_vals = .{ x, c, 0.0 };
        } else if (h_prime < 3.0) {
            rgb_vals = .{ 0.0, c, x };
        } else if (h_prime < 4.0) {
            rgb_vals = .{ 0.0, x, c };
        } else if (h_prime < 5.0) {
            rgb_vals = .{ x, 0.0, c };
        } else {
            rgb_vals = .{ c, 0.0, x };
        }
        
        return .{
            .r = rgb_vals[0] + m,
            .g = rgb_vals[1] + m,
            .b = rgb_vals[2] + m,
            .a = 1.0,
        };
    }
    
    /// Convert to 32-bit RGBA integer
    pub fn toRGBA32(self: Color) u32 {
        const r: u32 = @intFromFloat(@round(self.r * 255.0));
        const g: u32 = @intFromFloat(@round(self.g * 255.0));
        const b: u32 = @intFromFloat(@round(self.b * 255.0));
        const a: u32 = @intFromFloat(@round(self.a * 255.0));
        
        return (a << 24) | (r << 16) | (g << 8) | b;
    }
    
    /// Linear interpolation between two colors
    pub fn lerp(self: Color, other: Color, t: f32) Color {
        const t_clamped = @max(0.0, @min(1.0, t));
        const inv_t = 1.0 - t_clamped;
        
        return .{
            .r = self.r * inv_t + other.r * t_clamped,
            .g = self.g * inv_t + other.g * t_clamped,
            .b = self.b * inv_t + other.b * t_clamped,
            .a = self.a * inv_t + other.a * t_clamped,
        };
    }
    
    /// Premultiply alpha for more accurate blending
    pub fn premultiplyAlpha(self: Color) Color {
        return .{
            .r = self.r * self.a,
            .g = self.g * self.a,
            .b = self.b * self.a,
            .a = self.a,
        };
    }
};

/// Element type enumeration for data-oriented storage
pub const ElementType = enum(u8) {
    container = 0,
    text = 1,
    button = 2,
    slider = 3,
    image = 4,
    custom = 255,
    
    /// Get the maximum number of element types for array sizing
    pub fn maxTypes() comptime_int {
        return @typeInfo(ElementType).Enum.fields.len;
    }
};

/// Layout direction for containers
pub const FlexDirection = enum(u8) {
    row = 0,
    column = 1,
    row_reverse = 2,
    column_reverse = 3,
};

/// Alignment options
pub const Alignment = enum(u8) {
    start = 0,
    center = 1,
    end = 2,
    stretch = 3,
};

/// Justification options for main axis
pub const Justification = enum(u8) {
    start = 0,
    center = 1,
    end = 2,
    space_between = 3,
    space_around = 4,
    space_evenly = 5,
};

/// Element ID type - using u32 for memory efficiency
pub const ElementId = u32;

/// Invalid element ID constant
pub const INVALID_ELEMENT_ID: ElementId = std.math.maxInt(ElementId);

// Compile-time validation of our core types
comptime {
    // Ensure our basic types are the expected size for cache efficiency
    const assert = std.debug.assert;
    
    // Point should be 8 bytes (2 * f32)
    assert(@sizeOf(Point) == 8);
    
    // Size should be 8 bytes (2 * f32)
    assert(@sizeOf(Size) == 8);
    
    // Rect should be 16 bytes (4 * f32)
    assert(@sizeOf(Rect) == 16);
    
    // Color should be 16 bytes (4 * f32)
    assert(@sizeOf(Color) == 16);
    
    // EdgeInsets should be 16 bytes (4 * f32)
    assert(@sizeOf(EdgeInsets) == 16);
    
    // Enums should be single bytes for memory efficiency
    assert(@sizeOf(ElementType) == 1);
    assert(@sizeOf(FlexDirection) == 1);
    assert(@sizeOf(Alignment) == 1);
    assert(@sizeOf(Justification) == 1);
    
    // ElementId should be 4 bytes
    assert(@sizeOf(ElementId) == 4);
}

// Unit tests for our core types
test "Point operations" {
    const testing = std.testing;
    
    const p1 = Point{ .x = 1.0, .y = 2.0 };
    const p2 = Point{ .x = 3.0, .y = 4.0 };
    
    const sum = p1.add(p2);
    try testing.expect(sum.x == 4.0 and sum.y == 6.0);
    
    const diff = p2.sub(p1);
    try testing.expect(diff.x == 2.0 and diff.y == 2.0);
    
    const scaled = p1.mul(2.0);
    try testing.expect(scaled.x == 2.0 and scaled.y == 4.0);
    
    const dist = p1.distance(p2);
    try testing.expect(@abs(dist - 2.828427) < 0.001);
}

test "Size operations" {
    const testing = std.testing;
    
    const s1 = Size{ .width = 10.0, .height = 20.0 };
    const s2 = Size{ .width = 5.0, .height = 15.0 };
    
    try testing.expect(s1.area() == 200.0);
    try testing.expect(@abs(s1.aspectRatio() - 0.5) < 0.001);
    try testing.expect(!s1.isEmpty());
    
    const min_size = s1.min(s2);
    try testing.expect(min_size.width == 5.0 and min_size.height == 15.0);
    
    const max_size = s1.max(s2);
    try testing.expect(max_size.width == 10.0 and max_size.height == 20.0);
}

test "Rect operations" {
    const testing = std.testing;
    
    const rect = Rect{ .x = 10.0, .y = 20.0, .width = 100.0, .height = 50.0 };
    
    const center_point = rect.center();
    try testing.expect(center_point.x == 60.0 and center_point.y == 45.0);
    
    const inside_point = Point{ .x = 50.0, .y = 30.0 };
    const outside_point = Point{ .x = 5.0, .y = 30.0 };
    
    try testing.expect(rect.contains(inside_point));
    try testing.expect(!rect.contains(outside_point));
    
    const other_rect = Rect{ .x = 50.0, .y = 30.0, .width = 100.0, .height = 50.0 };
    try testing.expect(rect.intersects(other_rect));
    
    const intersection = rect.intersection(other_rect);
    try testing.expect(intersection.x == 50.0 and intersection.y == 30.0);
    try testing.expect(intersection.width == 60.0 and intersection.height == 40.0);
}

test "Color creation and conversion" {
    const testing = std.testing;
    
    const red = Color.rgb(255, 0, 0);
    try testing.expect(red.r == 1.0 and red.g == 0.0 and red.b == 0.0 and red.a == 1.0);
    
    const rgba = Color.rgba(128, 64, 192, 128);
    try testing.expect(@abs(rgba.r - 128.0/255.0) < 0.001);
    try testing.expect(@abs(rgba.a - 128.0/255.0) < 0.001);
    
    const rgba32 = red.toRGBA32();
    try testing.expect(rgba32 == 0xFFFF0000); // ARGB format: A=FF, R=FF, G=00, B=00
    
    const lerped = Color.BLACK.lerp(Color.WHITE, 0.5);
    try testing.expect(@abs(lerped.r - 0.5) < 0.001);
    try testing.expect(@abs(lerped.g - 0.5) < 0.001);
    try testing.expect(@abs(lerped.b - 0.5) < 0.001);
}

test "EdgeInsets operations" {
    const testing = std.testing;
    
    const insets = EdgeInsets.symmetric(10.0, 5.0);
    try testing.expect(insets.left == 10.0 and insets.right == 10.0);
    try testing.expect(insets.top == 5.0 and insets.bottom == 5.0);
    
    try testing.expect(insets.totalWidth() == 20.0);
    try testing.expect(insets.totalHeight() == 10.0);
    
    const size = Size{ .width = 100.0, .height = 50.0 };
    const shrunk = insets.shrinkSize(size);
    try testing.expect(shrunk.width == 80.0 and shrunk.height == 40.0);
    
    const expanded = insets.expandSize(size);
    try testing.expect(expanded.width == 120.0 and expanded.height == 60.0);
}