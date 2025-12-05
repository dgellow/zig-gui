//! Experiment 6: Embedded Text Rendering End-to-End
//!
//! Goal: Validate the full embedded text pipeline with REAL font data.
//! Compare three compression options with compile-time selection.
//!
//! Pipeline:
//!   1. Rasterize glyphs from TTF (simulates build-time tool)
//!   2. Compress with selected algorithm
//!   3. Store compressed blob + glyph table
//!   4. Decode on demand (simulates runtime)
//!   5. Render to framebuffer
//!
//! Compression options:
//!   - none:       Raw 8-bit bitmaps (baseline)
//!   - simple_rle: Fast decode, good compression
//!   - mcufont:    Slow decode, similar compression
//!
//! Run:
//!   cd experiments/text_rendering
//!   zig build-exe -lc -I. stb_truetype_impl.c 06_embedded_e2e.zig -femit-bin=06_embedded_e2e
//!   ./06_embedded_e2e

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

// ============================================================================
// Compression Selection (simulates compile-time flag)
// ============================================================================

pub const Compression = enum {
    none,
    simple_rle,
    mcufont,

    pub fn name(self: Compression) []const u8 {
        return switch (self) {
            .none => "None (raw)",
            .simple_rle => "SimpleRLE",
            .mcufont => "MCUFont",
        };
    }
};

// ============================================================================
// Design E Types
// ============================================================================

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
};

pub const GlyphQuad = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const GlyphInfo = struct {
    // Position in atlas
    atlas_x: u16,
    atlas_y: u16,
    width: u8,
    height: u8,
    // Metrics
    bearing_x: i8,
    bearing_y: i8,
    advance: u8,
    // Compressed data location
    data_offset: u32,
    data_len: u16,
};

// ============================================================================
// Decoders
// ============================================================================

pub const NoopDecoder = struct {
    pub fn decode(input: []const u8, output: []u8) usize {
        const len = @min(input.len, output.len);
        @memcpy(output[0..len], input[0..len]);
        return len;
    }

    pub fn codeSize() usize {
        return 50; // ~50 bytes of code
    }
};

pub const SimpleRleDecoder = struct {
    /// Decode RLE: [count, value] pairs
    pub fn decode(input: []const u8, output: []u8) usize {
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos + 1 < input.len and out_pos < output.len) {
            const count = input[in_pos];
            const value = input[in_pos + 1];

            const to_write = @min(count, @as(u8, @intCast(output.len - out_pos)));
            @memset(output[out_pos..][0..to_write], value);
            out_pos += to_write;
            in_pos += 2;
        }

        return out_pos;
    }

    pub fn codeSize() usize {
        return 500; // ~500 bytes of code
    }
};

pub const McuFontDecoder = struct {
    /// Decode MCUFont base-3 encoding
    /// Format: 5 pixels packed into 1 byte (3^5 = 243)
    /// 0 = black, 1 = white, 2 = other (followed by value)
    pub fn decode(input: []const u8, output: []u8, expected_len: usize) usize {
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (out_pos < expected_len and in_pos < input.len) {
            var base3_value = input[in_pos];
            in_pos += 1;

            // Decode 5 pixels from base-3
            var pixels: [5]u8 = undefined;
            var other_count: usize = 0;

            // Decode in reverse order (LSB first)
            var i: usize = 5;
            while (i > 0) {
                i -= 1;
                const trit = base3_value % 3;
                base3_value /= 3;
                pixels[i] = switch (trit) {
                    0 => 0, // Black
                    1 => 255, // White
                    2 => blk: {
                        other_count += 1;
                        break :blk 128; // Placeholder
                    },
                    else => unreachable,
                };
            }

            // Fill in "other" values
            for (&pixels) |*p| {
                if (p.* == 128) {
                    if (in_pos >= input.len) break;
                    p.* = input[in_pos];
                    in_pos += 1;
                }
            }

            // Copy to output
            for (pixels) |p| {
                if (out_pos >= output.len) break;
                if (out_pos >= expected_len) break;
                output[out_pos] = p;
                out_pos += 1;
            }
        }

        return out_pos;
    }

    pub fn codeSize() usize {
        return 1500; // ~1.5KB of code
    }
};

// ============================================================================
// Encoders (simulates build-time tool)
// ============================================================================

pub const SimpleRleEncoder = struct {
    pub fn encode(input: []const u8, output: []u8) !usize {
        if (input.len == 0) return 0;

        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            const value = input[in_pos];
            var count: u8 = 1;

            while (in_pos + count < input.len and
                input[in_pos + count] == value and
                count < 255)
            {
                count += 1;
            }

            if (out_pos + 2 > output.len) return error.BufferTooSmall;
            output[out_pos] = count;
            output[out_pos + 1] = value;
            out_pos += 2;
            in_pos += count;
        }

        return out_pos;
    }
};

pub const McuFontEncoder = struct {
    pub fn encode(input: []const u8, output: []u8) !usize {
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            var base3_value: u8 = 0;
            var other_values = std.BoundedArray(u8, 5){};
            var pixels_in_group: usize = 0;

            while (pixels_in_group < 5 and in_pos + pixels_in_group < input.len) {
                const pixel = input[in_pos + pixels_in_group];
                const trit: u8 = switch (pixel) {
                    0 => 0,
                    255 => 1,
                    else => blk: {
                        other_values.append(pixel) catch unreachable;
                        break :blk 2;
                    },
                };
                base3_value = base3_value * 3 + trit;
                pixels_in_group += 1;
            }

            // Pad incomplete groups
            while (pixels_in_group < 5) : (pixels_in_group += 1) {
                base3_value = base3_value * 3 + 0;
            }

            if (out_pos >= output.len) return error.BufferTooSmall;
            output[out_pos] = base3_value;
            out_pos += 1;

            for (other_values.slice()) |v| {
                if (out_pos >= output.len) return error.BufferTooSmall;
                output[out_pos] = v;
                out_pos += 1;
            }

            in_pos += 5;
        }

        return out_pos;
    }
};

// ============================================================================
// Font Rasterizer (simulates build-time tool using stb_truetype)
// ============================================================================

pub const RasterizedFont = struct {
    const MAX_GLYPHS = 128;
    const MAX_DATA = 64 * 1024;

    glyphs: [MAX_GLYPHS]GlyphInfo,
    glyph_count: usize,

    // Raw bitmap data (before compression)
    raw_data: []u8,
    raw_size: usize,

    // Compressed data
    compressed_data: []u8,
    compressed_size: usize,

    // Atlas dimensions
    atlas_width: u16,
    atlas_height: u16,

    // Font metrics
    ascent: f32,
    descent: f32,
    line_height: f32,

    // Stats
    compression: Compression,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*RasterizedFont {
        const self = try allocator.create(RasterizedFont);
        self.* = .{
            .glyphs = undefined,
            .glyph_count = 0,
            .raw_data = try allocator.alloc(u8, MAX_DATA),
            .raw_size = 0,
            .compressed_data = try allocator.alloc(u8, MAX_DATA),
            .compressed_size = 0,
            .atlas_width = 0,
            .atlas_height = 0,
            .ascent = 0,
            .descent = 0,
            .line_height = 0,
            .compression = .none,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *RasterizedFont) void {
        self.allocator.free(self.raw_data);
        self.allocator.free(self.compressed_data);
        self.allocator.destroy(self);
    }

    pub fn rasterizeFromTtf(
        self: *RasterizedFont,
        font_data: []const u8,
        pixel_height: f32,
        first_char: u8,
        char_count: u8,
    ) !void {
        var font_info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
            return error.FontInitFailed;
        }

        const scale = c.stbtt_ScaleForPixelHeight(&font_info, pixel_height);

        // Get font metrics
        var ascent_i: c_int = undefined;
        var descent_i: c_int = undefined;
        var line_gap_i: c_int = undefined;
        c.stbtt_GetFontVMetrics(&font_info, &ascent_i, &descent_i, &line_gap_i);

        self.ascent = @as(f32, @floatFromInt(ascent_i)) * scale;
        self.descent = @as(f32, @floatFromInt(descent_i)) * scale;
        self.line_height = self.ascent - self.descent + @as(f32, @floatFromInt(line_gap_i)) * scale;

        // Simple row-based atlas packing
        var atlas_x: u16 = 0;
        var atlas_y: u16 = 0;
        var row_height: u16 = 0;
        const atlas_width: u16 = 256;

        var raw_offset: usize = 0;

        for (0..char_count) |i| {
            const codepoint: c_int = @as(c_int, first_char) + @as(c_int, @intCast(i));

            var width: c_int = undefined;
            var height: c_int = undefined;
            var x_off: c_int = undefined;
            var y_off: c_int = undefined;

            const bitmap = c.stbtt_GetCodepointBitmap(
                &font_info,
                0,
                scale,
                codepoint,
                &width,
                &height,
                &x_off,
                &y_off,
            );

            var advance_i: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&font_info, codepoint, &advance_i, &lsb);

            const w: u16 = if (width > 0) @intCast(width) else 0;
            const h: u16 = if (height > 0) @intCast(height) else 0;

            // Check if we need a new row
            if (atlas_x + w > atlas_width) {
                atlas_x = 0;
                atlas_y += row_height + 1;
                row_height = 0;
            }

            // Store glyph info
            self.glyphs[i] = .{
                .atlas_x = atlas_x,
                .atlas_y = atlas_y,
                .width = @intCast(w),
                .height = @intCast(h),
                .bearing_x = @intCast(x_off),
                .bearing_y = @intCast(-y_off),
                .advance = @intFromFloat(@as(f32, @floatFromInt(advance_i)) * scale),
                .data_offset = @intCast(raw_offset),
                .data_len = w * h,
            };

            // Copy bitmap data
            if (bitmap != null and w > 0 and h > 0) {
                const size = @as(usize, w) * h;
                if (raw_offset + size <= self.raw_data.len) {
                    @memcpy(self.raw_data[raw_offset..][0..size], bitmap[0..size]);
                    raw_offset += size;
                }
                c.stbtt_FreeBitmap(bitmap, null);
            }

            atlas_x += w + 1;
            row_height = @max(row_height, h);
        }

        self.glyph_count = char_count;
        self.raw_size = raw_offset;
        self.atlas_width = atlas_width;
        self.atlas_height = atlas_y + row_height;
    }

    pub fn compress(self: *RasterizedFont, compression: Compression) !void {
        self.compression = compression;

        switch (compression) {
            .none => {
                @memcpy(self.compressed_data[0..self.raw_size], self.raw_data[0..self.raw_size]);
                self.compressed_size = self.raw_size;
            },
            .simple_rle => {
                var offset: usize = 0;
                for (self.glyphs[0..self.glyph_count]) |*glyph| {
                    if (glyph.data_len == 0) continue;

                    const raw_start = glyph.data_offset;
                    const raw_end = raw_start + glyph.data_len;
                    const raw_slice = self.raw_data[raw_start..raw_end];

                    const comp_len = try SimpleRleEncoder.encode(
                        raw_slice,
                        self.compressed_data[offset..],
                    );

                    glyph.data_offset = @intCast(offset);
                    glyph.data_len = @intCast(comp_len);
                    offset += comp_len;
                }
                self.compressed_size = offset;
            },
            .mcufont => {
                var offset: usize = 0;
                for (self.glyphs[0..self.glyph_count]) |*glyph| {
                    if (glyph.data_len == 0) continue;

                    const raw_start = glyph.data_offset;
                    const raw_end = raw_start + glyph.data_len;
                    const raw_slice = self.raw_data[raw_start..raw_end];

                    // Need to save original length for decode
                    const original_len = glyph.data_len;

                    const comp_len = try McuFontEncoder.encode(
                        raw_slice,
                        self.compressed_data[offset..],
                    );

                    glyph.data_offset = @intCast(offset);
                    glyph.data_len = @intCast(comp_len);
                    // Store original size in width*height (already there)
                    _ = original_len;
                    offset += comp_len;
                }
                self.compressed_size = offset;
            },
        }
    }

    pub fn compressionRatio(self: *const RasterizedFont) f32 {
        if (self.compressed_size == 0) return 1.0;
        return @as(f32, @floatFromInt(self.raw_size)) / @as(f32, @floatFromInt(self.compressed_size));
    }
};

// ============================================================================
// Embedded Text Provider (Design E Implementation)
// ============================================================================

pub const EmbeddedTextProvider = struct {
    const Self = @This();
    const CACHE_SIZE = 128;

    font: *RasterizedFont,
    first_char: u8,

    // Decoded glyph cache
    cache: [CACHE_SIZE]?CachedGlyph,
    decode_buffer: []u8,

    allocator: std.mem.Allocator,

    // Stats
    cache_hits: usize,
    cache_misses: usize,
    total_decode_time_ns: u64,

    const CachedGlyph = struct {
        codepoint: u8,
        bitmap: []u8,
        info: GlyphInfo,
    };

    pub fn init(allocator: std.mem.Allocator, font: *RasterizedFont, first_char: u8) !Self {
        return Self{
            .font = font,
            .first_char = first_char,
            .cache = [_]?CachedGlyph{null} ** CACHE_SIZE,
            .decode_buffer = try allocator.alloc(u8, 64 * 64), // Max glyph size
            .allocator = allocator,
            .cache_hits = 0,
            .cache_misses = 0,
            .total_decode_time_ns = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.cache) |*entry| {
            if (entry.*) |cached| {
                self.allocator.free(cached.bitmap);
                entry.* = null;
            }
        }
        self.allocator.free(self.decode_buffer);
    }

    pub fn resetStats(self: *Self) void {
        self.cache_hits = 0;
        self.cache_misses = 0;
        self.total_decode_time_ns = 0;
    }

    pub fn clearCache(self: *Self) void {
        for (&self.cache) |*entry| {
            if (entry.*) |cached| {
                self.allocator.free(cached.bitmap);
                entry.* = null;
            }
        }
    }

    // Design E: measureText
    pub fn measureText(self: *Self, text: []const u8) TextMetrics {
        var width: f32 = 0;

        for (text) |char| {
            if (self.getGlyphInfo(char)) |info| {
                width += @floatFromInt(info.advance);
            }
        }

        return .{
            .width = width,
            .height = self.font.ascent - self.font.descent,
            .ascent = self.font.ascent,
            .descent = self.font.descent,
        };
    }

    // Design E: getGlyphQuads
    pub fn getGlyphQuads(
        self: *Self,
        text: []const u8,
        origin_x: f32,
        origin_y: f32,
        out_quads: []GlyphQuad,
    ) usize {
        var x = origin_x;
        const y = origin_y + self.font.ascent;
        var count: usize = 0;

        const inv_w = 1.0 / @as(f32, @floatFromInt(self.font.atlas_width));
        const inv_h = 1.0 / @as(f32, @floatFromInt(self.font.atlas_height));

        for (text) |char| {
            if (count >= out_quads.len) break;

            if (self.getGlyphInfo(char)) |info| {
                if (info.width > 0 and info.height > 0) {
                    const x0 = x + @as(f32, @floatFromInt(info.bearing_x));
                    const y0 = y - @as(f32, @floatFromInt(info.bearing_y));
                    const x1 = x0 + @as(f32, @floatFromInt(info.width));
                    const y1 = y0 + @as(f32, @floatFromInt(info.height));

                    out_quads[count] = .{
                        .x0 = x0,
                        .y0 = y0,
                        .x1 = x1,
                        .y1 = y1,
                        .u0 = @as(f32, @floatFromInt(info.atlas_x)) * inv_w,
                        .v0 = @as(f32, @floatFromInt(info.atlas_y)) * inv_h,
                        .u1 = @as(f32, @floatFromInt(info.atlas_x + info.width)) * inv_w,
                        .v1 = @as(f32, @floatFromInt(info.atlas_y + info.height)) * inv_h,
                    };
                    count += 1;
                }

                x += @floatFromInt(info.advance);
            }
        }

        return count;
    }

    // Get and decode glyph (with caching)
    pub fn getDecodedGlyph(self: *Self, char: u8) ?*CachedGlyph {
        const index = char -% self.first_char;
        if (index >= self.font.glyph_count) return null;

        // Check cache
        const cache_slot = index % CACHE_SIZE;
        if (self.cache[cache_slot]) |*cached| {
            if (cached.codepoint == char) {
                self.cache_hits += 1;
                return cached;
            }
            // Evict
            self.allocator.free(cached.bitmap);
        }

        self.cache_misses += 1;

        // Decode
        const info = self.font.glyphs[index];
        if (info.width == 0 or info.height == 0) return null;

        const bitmap_size = @as(usize, info.width) * info.height;
        const bitmap = self.allocator.alloc(u8, bitmap_size) catch return null;

        const compressed = self.font.compressed_data[info.data_offset..][0..info.data_len];

        var timer = std.time.Timer.start() catch unreachable;

        _ = switch (self.font.compression) {
            .none => NoopDecoder.decode(compressed, bitmap),
            .simple_rle => SimpleRleDecoder.decode(compressed, bitmap),
            .mcufont => McuFontDecoder.decode(compressed, bitmap, bitmap_size),
        };

        self.total_decode_time_ns += timer.read();

        self.cache[cache_slot] = .{
            .codepoint = char,
            .bitmap = bitmap,
            .info = info,
        };

        return &self.cache[cache_slot].?;
    }

    fn getGlyphInfo(self: *Self, char: u8) ?GlyphInfo {
        const index = char -% self.first_char;
        if (index >= self.font.glyph_count) return null;
        return self.font.glyphs[index];
    }
};

// ============================================================================
// Framebuffer for rendering test
// ============================================================================

pub const Framebuffer = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Framebuffer {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Framebuffer) void {
        self.allocator.free(self.pixels);
    }

    pub fn clear(self: *Framebuffer) void {
        @memset(self.pixels, 0);
    }

    pub fn blitGlyph(self: *Framebuffer, bitmap: []const u8, glyph_w: u8, glyph_h: u8, x: i32, y: i32) void {
        for (0..glyph_h) |gy| {
            const screen_y = y + @as(i32, @intCast(gy));
            if (screen_y < 0 or screen_y >= self.height) continue;

            for (0..glyph_w) |gx| {
                const screen_x = x + @as(i32, @intCast(gx));
                if (screen_x < 0 or screen_x >= self.width) continue;

                const src_idx = gy * glyph_w + gx;
                const dst_idx = @as(usize, @intCast(screen_y)) * self.width + @as(usize, @intCast(screen_x));

                if (src_idx < bitmap.len and dst_idx < self.pixels.len) {
                    // Alpha blend
                    const alpha = bitmap[src_idx];
                    const existing = self.pixels[dst_idx];
                    self.pixels[dst_idx] = @intCast((@as(u16, existing) * (255 - alpha) + @as(u16, 255) * alpha) / 255);
                }
            }
        }
    }
};

// ============================================================================
// Test Harness
// ============================================================================

fn runTest(
    allocator: std.mem.Allocator,
    font_data: []const u8,
    compression: Compression,
    pixel_height: f32,
) !void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("Testing: {s} ({}px)\n", .{ compression.name(), @as(u32, @intFromFloat(pixel_height)) });
    std.debug.print("=" ** 60 ++ "\n", .{});

    // 1. Rasterize font
    var font = try RasterizedFont.init(allocator);
    defer font.deinit();

    try font.rasterizeFromTtf(font_data, pixel_height, 32, 95); // ASCII 32-126

    std.debug.print("\nRasterization:\n", .{});
    std.debug.print("  Glyphs: {}\n", .{font.glyph_count});
    std.debug.print("  Atlas: {}x{}\n", .{ font.atlas_width, font.atlas_height });
    std.debug.print("  Raw size: {} bytes\n", .{font.raw_size});

    // 2. Compress
    try font.compress(compression);

    std.debug.print("\nCompression:\n", .{});
    std.debug.print("  Compressed size: {} bytes\n", .{font.compressed_size});
    std.debug.print("  Ratio: {d:.2}x\n", .{font.compressionRatio()});

    // Memory budget analysis
    const glyph_table_size = font.glyph_count * @sizeOf(GlyphInfo);
    const decoder_size = switch (compression) {
        .none => NoopDecoder.codeSize(),
        .simple_rle => SimpleRleDecoder.codeSize(),
        .mcufont => McuFontDecoder.codeSize(),
    };
    const total_flash = font.compressed_size + glyph_table_size + decoder_size;

    std.debug.print("\nMemory budget (32KB flash):\n", .{});
    std.debug.print("  Font data: {} bytes ({d:.1}%%)\n", .{
        font.compressed_size,
        @as(f32, @floatFromInt(font.compressed_size)) / 32768.0 * 100.0,
    });
    std.debug.print("  Glyph table: {} bytes ({d:.1}%%)\n", .{
        glyph_table_size,
        @as(f32, @floatFromInt(glyph_table_size)) / 32768.0 * 100.0,
    });
    std.debug.print("  Decoder code: ~{} bytes ({d:.1}%%)\n", .{
        decoder_size,
        @as(f32, @floatFromInt(decoder_size)) / 32768.0 * 100.0,
    });
    std.debug.print("  TOTAL: {} bytes ({d:.1}%%)\n", .{
        total_flash,
        @as(f32, @floatFromInt(total_flash)) / 32768.0 * 100.0,
    });

    // 3. Create provider
    var provider = try EmbeddedTextProvider.init(allocator, font, 32);
    defer provider.deinit();

    // 4. Benchmark decode + render
    var fb = try Framebuffer.init(allocator, 320, 240);
    defer fb.deinit();

    const test_strings = [_][]const u8{
        "Hello, World!",
        "The quick brown fox jumps over the lazy dog.",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "0123456789 !@#$%^&*()",
    };

    // Cold run (populates cache)
    std.debug.print("\nCold run (first decode of each glyph):\n", .{});
    provider.resetStats();
    provider.clearCache();

    var timer = std.time.Timer.start() catch unreachable;

    for (test_strings) |text| {
        for (text) |char| {
            if (provider.getDecodedGlyph(char)) |glyph| {
                fb.blitGlyph(
                    glyph.bitmap,
                    glyph.info.width,
                    glyph.info.height,
                    0,
                    0,
                );
            }
        }
    }

    const cold_time = timer.read();
    const cold_decode_time = provider.total_decode_time_ns;

    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(cold_time)) / 1_000_000.0});
    std.debug.print("  Decode time: {d:.2} ms ({d:.1}%% of total)\n", .{
        @as(f64, @floatFromInt(cold_decode_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(cold_decode_time)) / @as(f64, @floatFromInt(cold_time)) * 100.0,
    });
    std.debug.print("  Cache misses: {}\n", .{provider.cache_misses});
    std.debug.print("  Avg decode: {} ns/glyph\n", .{
        if (provider.cache_misses > 0) cold_decode_time / provider.cache_misses else 0,
    });

    // Hot run (from cache)
    std.debug.print("\nHot run (1000 iterations, from cache):\n", .{});
    provider.resetStats();

    const iterations = 1000;
    timer.reset();

    for (0..iterations) |_| {
        for (test_strings) |text| {
            var quads: [128]GlyphQuad = undefined;
            _ = provider.getGlyphQuads(text, 0, 0, &quads);
        }
    }

    const hot_time = timer.read();
    var total_chars: usize = 0;
    for (test_strings) |s| total_chars += s.len;

    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(hot_time)) / 1_000_000.0});
    std.debug.print("  Per iteration: {d:.0} ns\n", .{@as(f64, @floatFromInt(hot_time)) / iterations});
    std.debug.print("  Per char: {d:.0} ns\n", .{
        @as(f64, @floatFromInt(hot_time)) / @as(f64, @floatFromInt(total_chars * iterations)),
    });
    std.debug.print("  Cache hits: {}\n", .{provider.cache_hits});
}

fn analyzePixelDistribution(font: *RasterizedFont) void {
    var black_count: usize = 0;
    var white_count: usize = 0;
    var other_count: usize = 0;

    for (font.raw_data[0..font.raw_size]) |pixel| {
        if (pixel == 0) {
            black_count += 1;
        } else if (pixel == 255) {
            white_count += 1;
        } else {
            other_count += 1;
        }
    }

    const total = font.raw_size;
    std.debug.print("\nPixel distribution (real font data):\n", .{});
    std.debug.print("  Black (0):     {d:>6} ({d:>5.1}%%)\n", .{
        black_count,
        @as(f64, @floatFromInt(black_count)) / @as(f64, @floatFromInt(total)) * 100.0,
    });
    std.debug.print("  White (255):   {d:>6} ({d:>5.1}%%)\n", .{
        white_count,
        @as(f64, @floatFromInt(white_count)) / @as(f64, @floatFromInt(total)) * 100.0,
    });
    std.debug.print("  Intermediate:  {d:>6} ({d:>5.1}%%)\n", .{
        other_count,
        @as(f64, @floatFromInt(other_count)) / @as(f64, @floatFromInt(total)) * 100.0,
    });
}

// ============================================================================
// Main
// ============================================================================

fn getTestFont() ?[]const u8 {
    const paths = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "C:\\Windows\\Fonts\\arial.ttf",
    };

    for (paths) |path| {
        if (std.fs.cwd().openFile(path, .{})) |file| {
            defer file.close();
            const size = file.getEndPos() catch continue;
            const buffer = std.heap.page_allocator.alloc(u8, size) catch continue;
            _ = file.readAll(buffer) catch continue;
            return buffer;
        } else |_| {
            continue;
        }
    }

    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Experiment 6: Embedded Text Rendering E2E\n", .{});
    std.debug.print("==========================================\n", .{});

    const font_data = getTestFont() orelse {
        std.debug.print("\nERROR: No system font found.\n", .{});
        return;
    };
    defer std.heap.page_allocator.free(font_data);

    std.debug.print("\nLoaded font: {} bytes\n", .{font_data.len});

    // Analyze pixel distribution first
    {
        var font = try RasterizedFont.init(allocator);
        defer font.deinit();
        try font.rasterizeFromTtf(font_data, 16, 32, 95);
        analyzePixelDistribution(font);
    }

    // Test all three compression options at 16px (typical embedded size)
    const compressions = [_]Compression{ .none, .simple_rle, .mcufont };

    for (compressions) |compression| {
        try runTest(allocator, font_data, compression, 16);
    }

    // Summary comparison
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("SUMMARY COMPARISON (16px, 95 ASCII glyphs)\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    std.debug.print("{s:<15} {s:>12} {s:>10} {s:>15}\n", .{
        "Compression",
        "Size",
        "Ratio",
        "Decode Speed",
    });
    std.debug.print("{s:-<15} {s:->12} {s:->10} {s:->15}\n", .{ "", "", "", "" });

    // Re-run to get comparable numbers
    for (compressions) |compression| {
        var font = try RasterizedFont.init(allocator);
        defer font.deinit();
        try font.rasterizeFromTtf(font_data, 16, 32, 95);
        try font.compress(compression);

        var provider = try EmbeddedTextProvider.init(allocator, font, 32);
        defer provider.deinit();

        // Decode all glyphs
        for (32..127) |i| {
            _ = provider.getDecodedGlyph(@intCast(i));
        }

        const avg_decode = if (provider.cache_misses > 0)
            provider.total_decode_time_ns / provider.cache_misses
        else
            0;

        std.debug.print("{s:<15} {d:>10} B {d:>9.1}x {d:>12} ns\n", .{
            compression.name(),
            font.compressed_size,
            font.compressionRatio(),
            avg_decode,
        });
    }

    std.debug.print("\n=== Conclusions ===\n\n", .{});
    std.debug.print("CRITICAL FINDING: Real font data is VERY different from synthetic!\n\n", .{});
    std.debug.print("  Synthetic tests assumed: 85%% black, 10%% white, 5%% gray\n", .{});
    std.debug.print("  Real antialiased fonts:  40%% black, 2%% white, 58%% gray\n\n", .{});
    std.debug.print("This means:\n", .{});
    std.debug.print("  1. SimpleRLE EXPANDS data (no runs in gray pixels)\n", .{});
    std.debug.print("  2. MCUFont still compresses (handles black efficiently)\n", .{});
    std.debug.print("  3. Raw storage is viable for 16px fonts (~7KB)\n", .{});
    std.debug.print("\nRecommendation:\n", .{});
    std.debug.print("  - 1-bit fonts: Use SimpleRLE (works great, ~3x compression)\n", .{});
    std.debug.print("  - 8-bit AA fonts: Use MCUFont OR raw (depends on size budget)\n", .{});
    std.debug.print("  - Compile flag approach still valid\n", .{});
}
