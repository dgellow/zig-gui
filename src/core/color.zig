pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn fromRGBA(r: u8, g: u8, b: u8, a: u8) Color {
        return Color{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromRGB(r: u8, g: u8, b: u8) Color {
        return Color{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn toHex(self: Color) u32 {
        return (@as(u32, self.a) << 24) | (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }
};
