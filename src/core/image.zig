pub const ImageHandle = struct {
    id: u64,
    pub const invalid = ImageHandle{ .id = 0 };
    pub fn isValid(self: ImageHandle) bool {
        return self.id != 0;
    }
};

pub const ImageFormat = enum {
    rgba8888, // 8 bits per channel, 32 bits per pixel
    rgbx8888, // 8 bits per channel, no alpha, 32 bits per pixel
    rgb888, // 8 bits per channel, 24 bits per pixel
    bgra8888, // 8 bits per channel, swapped red/blue, 32 bits per pixel
    gray8, // 8-bit grayscale
    alpha8, // 8-bit alpha only

    pub fn bytesPerPixel(self: ImageFormat) u8 {
        return switch (self) {
            .rgba8888, .rgbx8888, .bgra8888 => 4,
            .rgb888 => 3,
            .gray8, .alpha8 => 1,
        };
    }

    pub fn hasAlpha(self: ImageFormat) bool {
        return switch (self) {
            .rgba8888, .bgra8888, .alpha8 => true,
            else => false,
        };
    }
};
