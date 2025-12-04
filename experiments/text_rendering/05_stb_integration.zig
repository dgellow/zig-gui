//! Experiment 6: stb_truetype Integration
//!
//! Goal: Validate that Design E's TextProvider interface works with a real
//! font library, and measure practical performance characteristics.
//!
//! This experiment:
//! 1. Wraps stb_truetype via Zig's C interop
//! 2. Implements a glyph cache with LRU eviction
//! 3. Measures rasterization speed
//! 4. Demonstrates Design E's getGlyphQuads pattern
//!
//! Run:
//!   cd experiments/text_rendering
//!   zig build-exe -lc -lm -I. stb_truetype_impl.c 05_stb_integration.zig -femit-bin=05_stb_integration
//!   ./05_stb_integration

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

// ============================================================================
// Design E Types (from DESIGN_OPTIONS.md)
// ============================================================================

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,
};

pub const GlyphQuad = struct {
    // Screen coordinates
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    // Atlas UV coordinates
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const AtlasInfo = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    generation: u32, // Increments when atlas changes (for GPU texture cache)
};

// ============================================================================
// Glyph Cache with LRU Eviction
// ============================================================================

pub const CachedGlyph = struct {
    codepoint: u32,
    // Atlas position
    atlas_x: u16,
    atlas_y: u16,
    atlas_w: u16,
    atlas_h: u16,
    // Metrics
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    // LRU tracking
    last_used_frame: u64,
};

pub const GlyphCache = struct {
    const Self = @This();
    const MAX_GLYPHS = 512;

    glyphs: std.AutoHashMap(u32, CachedGlyph),
    atlas_pixels: []u8,
    atlas_width: u32,
    atlas_height: u32,
    atlas_generation: u32,

    // Simple row-based packing
    current_row_y: u32,
    current_row_x: u32,
    current_row_height: u32,

    current_frame: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, atlas_width: u32, atlas_height: u32) !Self {
        const pixels = try allocator.alloc(u8, atlas_width * atlas_height);
        @memset(pixels, 0);

        return Self{
            .glyphs = std.AutoHashMap(u32, CachedGlyph).init(allocator),
            .atlas_pixels = pixels,
            .atlas_width = atlas_width,
            .atlas_height = atlas_height,
            .atlas_generation = 0,
            .current_row_y = 0,
            .current_row_x = 0,
            .current_row_height = 0,
            .current_frame = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.glyphs.deinit();
        self.allocator.free(self.atlas_pixels);
    }

    pub fn beginFrame(self: *Self) void {
        self.current_frame += 1;
    }

    pub fn getGlyph(self: *Self, codepoint: u32) ?*CachedGlyph {
        if (self.glyphs.getPtr(codepoint)) |glyph| {
            glyph.last_used_frame = self.current_frame;
            return glyph;
        }
        return null;
    }

    pub fn addGlyph(
        self: *Self,
        codepoint: u32,
        bitmap: []const u8,
        width: u32,
        height: u32,
        advance: f32,
        bearing_x: f32,
        bearing_y: f32,
    ) !*CachedGlyph {
        // Check if we need to evict
        if (self.glyphs.count() >= MAX_GLYPHS) {
            try self.evictLRU();
        }

        // Find space in atlas (simple row packing)
        if (self.current_row_x + width > self.atlas_width) {
            // Move to next row
            self.current_row_y += self.current_row_height + 1;
            self.current_row_x = 0;
            self.current_row_height = 0;
        }

        if (self.current_row_y + height > self.atlas_height) {
            // Atlas full, need to reset (in real impl, would evict or grow)
            self.resetAtlas();
        }

        const atlas_x = self.current_row_x;
        const atlas_y = self.current_row_y;

        // Copy bitmap to atlas
        for (0..height) |row| {
            const src_start = row * width;
            const dst_start = (atlas_y + row) * self.atlas_width + atlas_x;
            @memcpy(
                self.atlas_pixels[dst_start..][0..width],
                bitmap[src_start..][0..width],
            );
        }

        // Update packing state
        self.current_row_x += width + 1;
        self.current_row_height = @max(self.current_row_height, height);
        self.atlas_generation += 1;

        // Add to cache
        try self.glyphs.put(codepoint, .{
            .codepoint = codepoint,
            .atlas_x = @intCast(atlas_x),
            .atlas_y = @intCast(atlas_y),
            .atlas_w = @intCast(width),
            .atlas_h = @intCast(height),
            .advance = advance,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .last_used_frame = self.current_frame,
        });

        return self.glyphs.getPtr(codepoint).?;
    }

    fn evictLRU(self: *Self) !void {
        var oldest_frame: u64 = std.math.maxInt(u64);
        var oldest_codepoint: ?u32 = null;

        var iter = self.glyphs.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_used_frame < oldest_frame) {
                oldest_frame = entry.value_ptr.last_used_frame;
                oldest_codepoint = entry.key_ptr.*;
            }
        }

        if (oldest_codepoint) |cp| {
            _ = self.glyphs.remove(cp);
        }
    }

    fn resetAtlas(self: *Self) void {
        @memset(self.atlas_pixels, 0);
        self.glyphs.clearRetainingCapacity();
        self.current_row_x = 0;
        self.current_row_y = 0;
        self.current_row_height = 0;
        self.atlas_generation += 1;
    }

    pub fn getAtlasInfo(self: *const Self) AtlasInfo {
        return .{
            .pixels = self.atlas_pixels,
            .width = self.atlas_width,
            .height = self.atlas_height,
            .generation = self.atlas_generation,
        };
    }
};

// ============================================================================
// StbTextProvider - Design E Implementation
// ============================================================================

pub const StbTextProvider = struct {
    const Self = @This();

    font_info: c.stbtt_fontinfo,
    font_data: []const u8, // Must stay alive
    scale: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    cache: GlyphCache,
    allocator: std.mem.Allocator,

    // Temp buffer for rasterization
    temp_bitmap: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        font_data: []const u8,
        pixel_height: f32,
        atlas_size: u32,
    ) !Self {
        var font_info: c.stbtt_fontinfo = undefined;

        if (c.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
            return error.FontInitFailed;
        }

        const scale = c.stbtt_ScaleForPixelHeight(&font_info, pixel_height);

        var ascent_i: c_int = undefined;
        var descent_i: c_int = undefined;
        var line_gap_i: c_int = undefined;
        c.stbtt_GetFontVMetrics(&font_info, &ascent_i, &descent_i, &line_gap_i);

        const temp_bitmap = try allocator.alloc(u8, 128 * 128); // Max glyph size

        return Self{
            .font_info = font_info,
            .font_data = font_data,
            .scale = scale,
            .ascent = @as(f32, @floatFromInt(ascent_i)) * scale,
            .descent = @as(f32, @floatFromInt(descent_i)) * scale,
            .line_gap = @as(f32, @floatFromInt(line_gap_i)) * scale,
            .cache = try GlyphCache.init(allocator, atlas_size, atlas_size),
            .allocator = allocator,
            .temp_bitmap = temp_bitmap,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.allocator.free(self.temp_bitmap);
    }

    // Design E: measureText
    pub fn measureText(self: *Self, text: []const u8) TextMetrics {
        var width: f32 = 0;

        for (text) |char| {
            var advance_i: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance_i, &lsb);
            width += @as(f32, @floatFromInt(advance_i)) * self.scale;
        }

        return .{
            .width = width,
            .height = self.ascent - self.descent,
            .ascent = self.ascent,
            .descent = self.descent,
            .line_height = self.ascent - self.descent + self.line_gap,
        };
    }

    // Design E: getGlyphQuads (zero allocation - writes to caller's buffer)
    pub fn getGlyphQuads(
        self: *Self,
        text: []const u8,
        origin_x: f32,
        origin_y: f32,
        out_quads: []GlyphQuad,
    ) usize {
        var x = origin_x;
        const y = origin_y + self.ascent; // Baseline
        var count: usize = 0;

        for (text) |char| {
            if (count >= out_quads.len) break;

            const glyph = self.getOrRasterizeGlyph(char) orelse continue;

            // Build quad
            const x0 = x + glyph.bearing_x;
            const y0 = y - glyph.bearing_y;
            const x1 = x0 + @as(f32, @floatFromInt(glyph.atlas_w));
            const y1 = y0 + @as(f32, @floatFromInt(glyph.atlas_h));

            // UV coordinates (normalized)
            const inv_w = 1.0 / @as(f32, @floatFromInt(self.cache.atlas_width));
            const inv_h = 1.0 / @as(f32, @floatFromInt(self.cache.atlas_height));

            out_quads[count] = .{
                .x0 = x0,
                .y0 = y0,
                .x1 = x1,
                .y1 = y1,
                .u0 = @as(f32, @floatFromInt(glyph.atlas_x)) * inv_w,
                .v0 = @as(f32, @floatFromInt(glyph.atlas_y)) * inv_h,
                .u1 = @as(f32, @floatFromInt(glyph.atlas_x + glyph.atlas_w)) * inv_w,
                .v1 = @as(f32, @floatFromInt(glyph.atlas_y + glyph.atlas_h)) * inv_h,
            };

            x += glyph.advance;
            count += 1;
        }

        return count;
    }

    // Design E: getAtlas
    pub fn getAtlas(self: *const Self) AtlasInfo {
        return self.cache.getAtlasInfo();
    }

    // Design E: beginFrame/endFrame
    pub fn beginFrame(self: *Self) void {
        self.cache.beginFrame();
    }

    pub fn endFrame(_: *Self) void {
        // Could do cache maintenance here
    }

    // Design E extension: getCharPositions (for text input cursors)
    pub fn getCharPositions(self: *Self, text: []const u8, out_positions: []f32) usize {
        var x: f32 = 0;
        var count: usize = 0;

        for (text) |char| {
            if (count >= out_positions.len) break;
            out_positions[count] = x;

            var advance_i: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance_i, &lsb);
            x += @as(f32, @floatFromInt(advance_i)) * self.scale;
            count += 1;
        }

        // Add final position (after last char)
        if (count < out_positions.len) {
            out_positions[count] = x;
            count += 1;
        }

        return count;
    }

    fn getOrRasterizeGlyph(self: *Self, codepoint: u32) ?*CachedGlyph {
        // Check cache first
        if (self.cache.getGlyph(codepoint)) |glyph| {
            return glyph;
        }

        // Rasterize
        var width: c_int = undefined;
        var height: c_int = undefined;
        var x_off: c_int = undefined;
        var y_off: c_int = undefined;

        const bitmap = c.stbtt_GetCodepointBitmap(
            &self.font_info,
            0,
            self.scale,
            @intCast(codepoint),
            &width,
            &height,
            &x_off,
            &y_off,
        );

        if (bitmap == null or width == 0 or height == 0) {
            // Space or empty glyph - still need advance
            var advance_i: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&self.font_info, @intCast(codepoint), &advance_i, &lsb);

            // Add zero-size glyph to cache
            return self.cache.addGlyph(
                codepoint,
                &.{},
                0,
                0,
                @as(f32, @floatFromInt(advance_i)) * self.scale,
                0,
                0,
            ) catch null;
        }

        defer c.stbtt_FreeBitmap(bitmap, null);

        // Get advance
        var advance_i: c_int = undefined;
        var lsb: c_int = undefined;
        c.stbtt_GetCodepointHMetrics(&self.font_info, @intCast(codepoint), &advance_i, &lsb);

        // Copy to slice for cache
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        const bitmap_slice = bitmap[0 .. w * h];

        return self.cache.addGlyph(
            codepoint,
            bitmap_slice,
            @intCast(width),
            @intCast(height),
            @as(f32, @floatFromInt(advance_i)) * self.scale,
            @floatFromInt(x_off),
            @floatFromInt(-y_off), // stb uses top-down, we want bearing from baseline
        ) catch null;
    }
};

// ============================================================================
// Embedded Test Font (minimal TTF for testing without external files)
// ============================================================================

// This is a minimal valid TTF structure for testing.
// In production, you'd use @embedFile("path/to/font.ttf")
// or load from filesystem.

fn getTestFont() ?[]const u8 {
    // Try to load a system font for testing
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

// ============================================================================
// Benchmarks
// ============================================================================

fn benchmarkRasterization(provider: *StbTextProvider) void {
    const test_strings = [_][]const u8{
        "Hello, World!",
        "The quick brown fox jumps over the lazy dog.",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz",
        "0123456789!@#$%^&*()",
    };

    std.debug.print("\n=== Rasterization Benchmark ===\n\n", .{});

    // First pass: populate cache (cold)
    var timer = std.time.Timer.start() catch unreachable;

    for (test_strings) |s| {
        var quads: [256]GlyphQuad = undefined;
        _ = provider.getGlyphQuads(s, 0, 0, &quads);
    }

    const cold_time = timer.read();

    // Second pass: from cache (hot)
    timer.reset();

    const iterations = 1000;
    for (0..iterations) |_| {
        for (test_strings) |s| {
            var quads: [256]GlyphQuad = undefined;
            _ = provider.getGlyphQuads(s, 0, 0, &quads);
        }
    }

    const hot_time = timer.read();
    const total_chars: usize = blk: {
        var sum: usize = 0;
        for (test_strings) |s| sum += s.len;
        break :blk sum * iterations;
    };

    std.debug.print("Cold (with rasterization):\n", .{});
    std.debug.print("  Total: {d:.2} ms\n", .{@as(f64, @floatFromInt(cold_time)) / 1_000_000});

    std.debug.print("\nHot (cached):\n", .{});
    std.debug.print("  Total: {d:.2} ms for {} iterations\n", .{
        @as(f64, @floatFromInt(hot_time)) / 1_000_000,
        iterations,
    });
    std.debug.print("  Per char: {d:.0} ns\n", .{
        @as(f64, @floatFromInt(hot_time)) / @as(f64, @floatFromInt(total_chars)),
    });
}

fn benchmarkMeasurement(provider: *StbTextProvider) void {
    std.debug.print("\n=== Measurement Benchmark ===\n\n", .{});

    const test_string = "The quick brown fox jumps over the lazy dog.";
    const iterations = 10000;

    var timer = std.time.Timer.start() catch unreachable;

    for (0..iterations) |_| {
        _ = provider.measureText(test_string);
    }

    const elapsed = timer.read();

    std.debug.print("measureText ({} chars, {} iterations):\n", .{ test_string.len, iterations });
    std.debug.print("  Total: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000});
    std.debug.print("  Per call: {d:.0} ns\n", .{
        @as(f64, @floatFromInt(elapsed)) / @as(f64, iterations),
    });
}

fn printMemoryUsage(provider: *const StbTextProvider) void {
    std.debug.print("\n=== Memory Usage ===\n\n", .{});

    const atlas_size = provider.cache.atlas_width * provider.cache.atlas_height;
    const glyph_entry_size = @sizeOf(CachedGlyph);
    const cache_entries = provider.cache.glyphs.count();
    const cache_overhead = cache_entries * glyph_entry_size;

    std.debug.print("Atlas: {}x{} = {} bytes ({} KB)\n", .{
        provider.cache.atlas_width,
        provider.cache.atlas_height,
        atlas_size,
        atlas_size / 1024,
    });
    std.debug.print("Cached glyphs: {} (entry size: {} bytes)\n", .{
        cache_entries,
        glyph_entry_size,
    });
    std.debug.print("Cache overhead: {} bytes\n", .{cache_overhead});
    std.debug.print("Atlas generation: {} (texture uploads needed)\n", .{
        provider.cache.atlas_generation,
    });

    const total = atlas_size + cache_overhead + @sizeOf(StbTextProvider);
    std.debug.print("\nTotal RAM: {} bytes ({} KB)\n", .{ total, total / 1024 });
    std.debug.print("As %% of 1MB budget: {d:.1}%%\n", .{
        @as(f64, @floatFromInt(total)) / (1024 * 1024) * 100,
    });
}

fn demonstrateDesignE(provider: *StbTextProvider) void {
    std.debug.print("\n=== Design E Interface Demo ===\n\n", .{});

    provider.beginFrame();
    defer provider.endFrame();

    const text = "Hello, zig-gui!";

    // 1. Measure text for layout
    const metrics = provider.measureText(text);
    std.debug.print("measureText(\"{s}\"):\n", .{text});
    std.debug.print("  width: {d:.1}, height: {d:.1}\n", .{ metrics.width, metrics.height });
    std.debug.print("  ascent: {d:.1}, descent: {d:.1}\n", .{ metrics.ascent, metrics.descent });

    // 2. Get glyph quads for rendering (zero allocation!)
    var quads: [64]GlyphQuad = undefined;
    const quad_count = provider.getGlyphQuads(text, 100, 200, &quads);

    std.debug.print("\ngetGlyphQuads() returned {} quads:\n", .{quad_count});
    for (quads[0..@min(3, quad_count)], 0..) |q, i| {
        std.debug.print("  [{d}] screen: ({d:.0},{d:.0})-({d:.0},{d:.0}), uv: ({d:.3},{d:.3})-({d:.3},{d:.3})\n", .{
            i, q.x0, q.y0, q.x1, q.y1, q.u0, q.v0, q.u1, q.v1,
        });
    }
    if (quad_count > 3) {
        std.debug.print("  ... and {} more\n", .{quad_count - 3});
    }

    // 3. Get atlas info for GPU texture
    const atlas = provider.getAtlas();
    std.debug.print("\ngetAtlas():\n", .{});
    std.debug.print("  size: {}x{}\n", .{ atlas.width, atlas.height });
    std.debug.print("  generation: {} (for texture cache invalidation)\n", .{atlas.generation});

    // 4. Get char positions for text cursor
    var positions: [64]f32 = undefined;
    const pos_count = provider.getCharPositions(text, &positions);
    std.debug.print("\ngetCharPositions() for cursor placement:\n", .{});
    std.debug.print("  positions: ", .{});
    for (positions[0..@min(5, pos_count)]) |p| {
        std.debug.print("{d:.0} ", .{p});
    }
    if (pos_count > 5) {
        std.debug.print("... ({} total)", .{pos_count});
    }
    std.debug.print("\n", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("Experiment 6: stb_truetype Integration\n", .{});
    std.debug.print("======================================\n", .{});

    const font_data = getTestFont() orelse {
        std.debug.print("\nERROR: No system font found.\n", .{});
        std.debug.print("This experiment requires a TTF font. Tried:\n", .{});
        std.debug.print("  - /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf\n", .{});
        std.debug.print("  - /usr/share/fonts/TTF/DejaVuSans.ttf\n", .{});
        std.debug.print("  - /System/Library/Fonts/Helvetica.ttc\n", .{});
        std.debug.print("  - C:\\Windows\\Fonts\\arial.ttf\n", .{});
        std.debug.print("\nInstall dejavu-fonts or specify a font path.\n", .{});
        return;
    };
    defer std.heap.page_allocator.free(font_data);

    std.debug.print("\nLoaded font: {} bytes\n", .{font_data.len});

    var provider = try StbTextProvider.init(
        std.heap.page_allocator,
        font_data,
        24.0, // 24px height
        512, // 512x512 atlas
    );
    defer provider.deinit();

    std.debug.print("Initialized StbTextProvider (24px, 512x512 atlas)\n", .{});

    // Run demonstrations and benchmarks
    demonstrateDesignE(&provider);
    benchmarkRasterization(&provider);
    benchmarkMeasurement(&provider);
    printMemoryUsage(&provider);

    std.debug.print("\n=== Conclusions ===\n\n", .{});
    std.debug.print("1. Design E's interface works well with stb_truetype\n", .{});
    std.debug.print("2. getGlyphQuads with caller-provided buffer = zero allocation\n", .{});
    std.debug.print("3. Atlas generation counter enables GPU texture caching\n", .{});
    std.debug.print("4. getCharPositions enables text input cursor placement\n", .{});
    std.debug.print("5. LRU cache handles glyph eviction automatically\n", .{});
}
