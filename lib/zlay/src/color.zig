const std = @import("std");

/// RGBA color representation
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
    
    /// Create color from RGB values (alpha = 255)
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    
    /// Create color from RGBA values
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    
    /// Create color from hex value (0xRRGGBB or 0xRRGGBBAA)
    pub fn hex(value: u32) Color {
        if (value <= 0xFFFFFF) {
            // RGB format
            return .{
                .r = @intCast((value >> 16) & 0xFF),
                .g = @intCast((value >> 8) & 0xFF),
                .b = @intCast(value & 0xFF),
                .a = 255,
            };
        } else {
            // RGBA format
            return .{
                .r = @intCast((value >> 24) & 0xFF),
                .g = @intCast((value >> 16) & 0xFF),
                .b = @intCast((value >> 8) & 0xFF),
                .a = @intCast(value & 0xFF),
            };
        }
    }
    
    /// Common colors
    pub const white = Color.rgb(255, 255, 255);
    pub const black = Color.rgb(0, 0, 0);
    pub const red = Color.rgb(255, 0, 0);
    pub const green = Color.rgb(0, 255, 0);
    pub const blue = Color.rgb(0, 0, 255);
    pub const yellow = Color.rgb(255, 255, 0);
    pub const cyan = Color.rgb(0, 255, 255);
    pub const magenta = Color.rgb(255, 0, 255);
    pub const transparent = Color.rgba(0, 0, 0, 0);
};

test "color basics" {
    const c1 = Color.rgb(255, 128, 64);
    try std.testing.expectEqual(@as(u8, 255), c1.r);
    try std.testing.expectEqual(@as(u8, 128), c1.g);
    try std.testing.expectEqual(@as(u8, 64), c1.b);
    try std.testing.expectEqual(@as(u8, 255), c1.a);
    
    const c2 = Color.rgba(128, 64, 32, 192);
    try std.testing.expectEqual(@as(u8, 128), c2.r);
    try std.testing.expectEqual(@as(u8, 64), c2.g);
    try std.testing.expectEqual(@as(u8, 32), c2.b);
    try std.testing.expectEqual(@as(u8, 192), c2.a);
    
    const c3 = Color.hex(0xFF8040);
    try std.testing.expectEqual(@as(u8, 255), c3.r);
    try std.testing.expectEqual(@as(u8, 128), c3.g);
    try std.testing.expectEqual(@as(u8, 64), c3.b);
    try std.testing.expectEqual(@as(u8, 255), c3.a);
    
    const c4 = Color.hex(0x80402080);
    try std.testing.expectEqual(@as(u8, 128), c4.r);
    try std.testing.expectEqual(@as(u8, 64), c4.g);
    try std.testing.expectEqual(@as(u8, 32), c4.b);
    try std.testing.expectEqual(@as(u8, 128), c4.a);
}