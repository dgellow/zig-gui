//! Experiment 1: Bitmap Font Baseline
//!
//! Goal: Establish the simplest possible text rendering approach.
//! Measure code size, memory, and performance as a baseline.
//!
//! This implements a fixed 8x16 bitmap font for ASCII (95 printable chars).

const std = @import("std");

// ============================================================================
// Minimal Bitmap Font Format
// ============================================================================

/// A minimal bitmap font: fixed size, 1-bit per pixel, ASCII only.
/// This is the absolute baseline - the simplest thing that works.
pub const BitmapFont = struct {
    /// Glyph width in pixels
    glyph_width: u8,
    /// Glyph height in pixels
    glyph_height: u8,
    /// First character code (typically 32 = space)
    first_char: u8,
    /// Number of characters
    char_count: u8,
    /// Packed 1-bit bitmap data (row-major, MSB first)
    /// Size = glyph_width * glyph_height * char_count / 8
    data: []const u8,

    /// Get glyph bitmap for a character
    pub fn getGlyph(self: BitmapFont, char: u8) ?GlyphBitmap {
        if (char < self.first_char or char >= self.first_char + self.char_count) {
            return null;
        }
        const index = char - self.first_char;
        const bits_per_glyph = @as(usize, self.glyph_width) * self.glyph_height;
        const bytes_per_glyph = (bits_per_glyph + 7) / 8;
        const offset = @as(usize, index) * bytes_per_glyph;

        return GlyphBitmap{
            .width = self.glyph_width,
            .height = self.glyph_height,
            .data = self.data[offset..][0..bytes_per_glyph],
        };
    }

    /// Calculate total memory for font data
    pub fn dataSize(self: BitmapFont) usize {
        const bits_per_glyph = @as(usize, self.glyph_width) * self.glyph_height;
        const bytes_per_glyph = (bits_per_glyph + 7) / 8;
        return bytes_per_glyph * self.char_count;
    }
};

pub const GlyphBitmap = struct {
    width: u8,
    height: u8,
    data: []const u8,

    /// Get pixel at (x, y). Returns true if pixel is set.
    pub fn getPixel(self: GlyphBitmap, x: u8, y: u8) bool {
        if (x >= self.width or y >= self.height) return false;
        const bit_index = @as(usize, y) * self.width + x;
        const byte_index = bit_index / 8;
        const bit_offset: u3 = @intCast(7 - (bit_index % 8)); // MSB first
        return (self.data[byte_index] >> bit_offset) & 1 == 1;
    }
};

// ============================================================================
// Sample 8x8 Font (subset for testing)
// ============================================================================

/// Minimal 8x8 font - just a few characters for testing
/// In real use, you'd embed a complete font with @embedFile
const sample_font_data = blk: {
    // Each character is 8 bytes (8x8 pixels, 1 bit each)
    // Space, A, B, C, 0, 1, 2
    var data: [7 * 8]u8 = undefined;

    // Space (all zeros)
    @memset(data[0..8], 0);

    // 'A' - simple triangle shape
    data[8..16].* = .{
        0b00011000, // row 0:    ##
        0b00100100, // row 1:   #  #
        0b01000010, // row 2:  #    #
        0b01111110, // row 3:  ######
        0b01000010, // row 4:  #    #
        0b01000010, // row 5:  #    #
        0b01000010, // row 6:  #    #
        0b00000000, // row 7:
    };

    // 'B'
    data[16..24].* = .{
        0b01111100, // row 0:  #####
        0b01000010, // row 1:  #    #
        0b01000010, // row 2:  #    #
        0b01111100, // row 3:  #####
        0b01000010, // row 4:  #    #
        0b01000010, // row 5:  #    #
        0b01111100, // row 6:  #####
        0b00000000, // row 7:
    };

    // 'C'
    data[24..32].* = .{
        0b00111100, // row 0:   ####
        0b01000010, // row 1:  #    #
        0b01000000, // row 2:  #
        0b01000000, // row 3:  #
        0b01000000, // row 4:  #
        0b01000010, // row 5:  #    #
        0b00111100, // row 6:   ####
        0b00000000, // row 7:
    };

    // '0'
    data[32..40].* = .{
        0b00111100, // row 0:   ####
        0b01000010, // row 1:  #    #
        0b01000110, // row 2:  #   ##
        0b01001010, // row 3:  #  # #
        0b01010010, // row 4:  # #  #
        0b01100010, // row 5:  ##   #
        0b00111100, // row 6:   ####
        0b00000000, // row 7:
    };

    // '1'
    data[40..48].* = .{
        0b00001000, // row 0:     #
        0b00011000, // row 1:    ##
        0b00101000, // row 2:   # #
        0b00001000, // row 3:     #
        0b00001000, // row 4:     #
        0b00001000, // row 5:     #
        0b00111110, // row 6:   #####
        0b00000000, // row 7:
    };

    // '2'
    data[48..56].* = .{
        0b00111100, // row 0:   ####
        0b01000010, // row 1:  #    #
        0b00000010, // row 2:       #
        0b00001100, // row 3:     ##
        0b00110000, // row 4:   ##
        0b01000000, // row 5:  #
        0b01111110, // row 6:  ######
        0b00000000, // row 7:
    };

    break :blk data;
};

/// Sample font for testing - maps: space=0, A=1, B=2, C=3, 0=4, 1=5, 2=6
pub const sample_font = BitmapFont{
    .glyph_width = 8,
    .glyph_height = 8,
    .first_char = 32, // Start at space
    .char_count = 7, // Only 7 chars for demo
    .data = &sample_font_data,
};

// ============================================================================
// Simple Software Framebuffer
// ============================================================================

pub const Framebuffer = struct {
    pixels: []u32, // ARGB format
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Framebuffer {
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0xFF000000); // Opaque black
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn setPixel(self: *Framebuffer, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        self.pixels[uy * self.width + ux] = color;
    }

    pub fn clear(self: *Framebuffer, color: u32) void {
        @memset(self.pixels, color);
    }
};

// ============================================================================
// Text Rendering
// ============================================================================

pub const TextRenderer = struct {
    font: BitmapFont,

    pub fn init(font: BitmapFont) TextRenderer {
        return .{ .font = font };
    }

    /// Render a single character. Returns advance width.
    pub fn renderChar(self: TextRenderer, fb: *Framebuffer, char: u8, x: i32, y: i32, color: u32) u8 {
        const glyph = self.font.getGlyph(char) orelse return self.font.glyph_width;

        var py: u8 = 0;
        while (py < glyph.height) : (py += 1) {
            var px: u8 = 0;
            while (px < glyph.width) : (px += 1) {
                if (glyph.getPixel(px, py)) {
                    fb.setPixel(x + px, y + py, color);
                }
            }
        }

        return self.font.glyph_width; // Fixed-width font
    }

    /// Render a string. Returns total width.
    pub fn renderText(self: TextRenderer, fb: *Framebuffer, text: []const u8, x: i32, y: i32, color: u32) i32 {
        var cursor_x = x;
        for (text) |char| {
            const advance = self.renderChar(fb, char, cursor_x, y, color);
            cursor_x += advance;
        }
        return cursor_x - x;
    }

    /// Measure text width without rendering
    pub fn measureText(self: TextRenderer, text: []const u8) u32 {
        // For fixed-width font, it's just length * glyph_width
        return @as(u32, @intCast(text.len)) * self.font.glyph_width;
    }
};

// ============================================================================
// Memory Analysis
// ============================================================================

pub fn analyzeMemory(comptime font: BitmapFont) void {
    const bits_per_glyph = @as(usize, font.glyph_width) * font.glyph_height;
    const bytes_per_glyph = (bits_per_glyph + 7) / 8;

    std.debug.print("\n=== Memory Analysis: Bitmap Font ===\n", .{});
    std.debug.print("Glyph size: {}x{} = {} bits = {} bytes\n", .{
        font.glyph_width,
        font.glyph_height,
        bits_per_glyph,
        bytes_per_glyph,
    });
    std.debug.print("Character count: {}\n", .{font.char_count});
    std.debug.print("Total font data: {} bytes\n", .{bytes_per_glyph * font.char_count});

    // Project to full ASCII (95 printable chars)
    const ascii_size = bytes_per_glyph * 95;
    std.debug.print("\nProjected for full ASCII (95 chars): {} bytes\n", .{ascii_size});

    // Project to 8x16 font (more readable)
    const font_8x16_bytes = (8 * 16 / 8) * 95;
    std.debug.print("Projected for 8x16 ASCII: {} bytes ({} KB)\n", .{
        font_8x16_bytes,
        font_8x16_bytes / 1024,
    });

    // Project with 2-bit antialiasing
    const font_8x16_2bit = (8 * 16 * 2 / 8) * 95;
    std.debug.print("Projected for 8x16 ASCII (2-bit AA): {} bytes ({} KB)\n", .{
        font_8x16_2bit,
        font_8x16_2bit / 1024,
    });

    // Project with 8-bit antialiasing
    const font_8x16_8bit = 8 * 16 * 95;
    std.debug.print("Projected for 8x16 ASCII (8-bit AA): {} bytes ({} KB)\n", .{
        font_8x16_8bit,
        font_8x16_8bit / 1024,
    });

    std.debug.print("\n32KB embedded budget breakdown:\n", .{});
    std.debug.print("  1-bit 8x16:   {} bytes = {d:.1}% of budget\n", .{
        font_8x16_bytes,
        @as(f32, @floatFromInt(font_8x16_bytes)) / 32768.0 * 100.0,
    });
    std.debug.print("  8-bit 8x16:   {} bytes = {d:.1}% of budget\n", .{
        font_8x16_8bit,
        @as(f32, @floatFromInt(font_8x16_8bit)) / 32768.0 * 100.0,
    });
}

// ============================================================================
// Performance Benchmark
// ============================================================================

pub fn benchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Performance Benchmark ===\n", .{});

    var fb = try Framebuffer.init(allocator, 320, 240);
    defer fb.deinit(allocator);

    const renderer = TextRenderer.init(sample_font);

    // Warm up
    _ = renderer.renderText(&fb, "ABC", 0, 0, 0xFFFFFFFF);

    // Benchmark single character
    const char_iterations = 100_000;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < char_iterations) : (i += 1) {
        _ = renderer.renderChar(&fb, 'A', 0, 0, 0xFFFFFFFF);
    }
    const char_ns = timer.read();
    const ns_per_char = char_ns / char_iterations;

    std.debug.print("Single char render: {} ns/char\n", .{ns_per_char});

    // Benchmark string
    const text = "ABC 012";
    const string_iterations = 10_000;
    timer.reset();
    i = 0;
    while (i < string_iterations) : (i += 1) {
        _ = renderer.renderText(&fb, text, 0, 0, 0xFFFFFFFF);
    }
    const string_ns = timer.read();
    const ns_per_string = string_ns / string_iterations;
    const ns_per_char_in_string = ns_per_string / text.len;

    std.debug.print("String render (7 chars): {} ns total, {} ns/char\n", .{
        ns_per_string,
        ns_per_char_in_string,
    });

    // Benchmark measure (no render)
    const measure_iterations = 1_000_000;
    timer.reset();
    i = 0;
    while (i < measure_iterations) : (i += 1) {
        _ = renderer.measureText(text);
    }
    const measure_ns = timer.read();

    std.debug.print("Measure text: {} ns\n", .{measure_ns / measure_iterations});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Experiment 1: Bitmap Font Baseline\n", .{});
    std.debug.print("==================================\n", .{});

    // Memory analysis
    analyzeMemory(sample_font);

    // Performance benchmark
    try benchmark(allocator);

    // Visual test - print ASCII art of rendered 'A'
    std.debug.print("\n=== Visual Test: 'A' glyph ===\n", .{});
    if (sample_font.getGlyph('A')) |glyph| {
        var y: u8 = 0;
        while (y < glyph.height) : (y += 1) {
            var x: u8 = 0;
            while (x < glyph.width) : (x += 1) {
                const char: u8 = if (glyph.getPixel(x, y)) '#' else '.';
                std.debug.print("{c}", .{char});
            }
            std.debug.print("\n", .{});
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "glyph lookup" {
    const font = sample_font;

    // Space should exist
    try std.testing.expect(font.getGlyph(' ') != null);

    // Character before range should not exist
    try std.testing.expect(font.getGlyph(31) == null);

    // Character after range should not exist
    try std.testing.expect(font.getGlyph('D') == null);
}

test "glyph pixel access" {
    const font = sample_font;
    const glyph_a = font.getGlyph('A').?;

    // Check some known pixels from our 'A' definition
    // Row 0: 0b00011000 - bits 3,4 should be set
    try std.testing.expect(glyph_a.getPixel(3, 0) == true);
    try std.testing.expect(glyph_a.getPixel(4, 0) == true);
    try std.testing.expect(glyph_a.getPixel(0, 0) == false);
    try std.testing.expect(glyph_a.getPixel(7, 0) == false);
}

test "measure text" {
    const renderer = TextRenderer.init(sample_font);

    // 5 characters at 8 pixels each = 40
    try std.testing.expectEqual(@as(u32, 40), renderer.measureText("ABCAB"));

    // Empty string
    try std.testing.expectEqual(@as(u32, 0), renderer.measureText(""));
}
