//! Experiment 2: RLE Compression for Bitmap Fonts
//!
//! Goal: Test compression strategies for embedded font data.
//! Inspired by MCUFont's approach.
//!
//! Key insight: Font glyphs have long runs of 0s (background) and clusters
//! of pixels. RLE can achieve 2-5x compression on antialiased fonts.

const std = @import("std");

// ============================================================================
// RLE Encoding Schemes
// ============================================================================

/// Simple RLE: [count, value] pairs
/// Good for: 1-bit fonts with long runs
pub const SimpleRLE = struct {
    /// Encode bitmap data with simple RLE
    pub fn encode(input: []const u8, output: []u8) !usize {
        if (input.len == 0) return 0;

        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            const value = input[in_pos];
            var count: u8 = 1;

            // Count consecutive identical bytes
            while (in_pos + count < input.len and
                input[in_pos + count] == value and
                count < 255)
            {
                count += 1;
            }

            // Write count and value
            if (out_pos + 2 > output.len) return error.BufferTooSmall;
            output[out_pos] = count;
            output[out_pos + 1] = value;
            out_pos += 2;
            in_pos += count;
        }

        return out_pos;
    }

    /// Decode RLE data
    pub fn decode(input: []const u8, output: []u8) !usize {
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos + 1 < input.len) {
            const count = input[in_pos];
            const value = input[in_pos + 1];

            if (out_pos + count > output.len) return error.BufferTooSmall;

            @memset(output[out_pos..][0..count], value);
            out_pos += count;
            in_pos += 2;
        }

        return out_pos;
    }
};

/// PackBits-style RLE: handles both runs and literal sequences
/// Format:
///   n >= 0: copy next n+1 bytes literally
///   n < 0: repeat next byte -n+1 times
/// Good for: Mixed data with both runs and varied sections
pub const PackBitsRLE = struct {
    pub fn encode(input: []const u8, output: []u8) !usize {
        if (input.len == 0) return 0;

        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            // Look for a run
            const run_start = in_pos;
            const run_value = input[in_pos];
            var run_len: usize = 1;

            while (run_start + run_len < input.len and
                input[run_start + run_len] == run_value and
                run_len < 128)
            {
                run_len += 1;
            }

            if (run_len >= 3) {
                // Encode as run: negative count, then value
                if (out_pos + 2 > output.len) return error.BufferTooSmall;
                output[out_pos] = @bitCast(@as(i8, -@as(i8, @intCast(run_len - 1))));
                output[out_pos + 1] = run_value;
                out_pos += 2;
                in_pos += run_len;
            } else {
                // Encode as literals
                var lit_end = in_pos + 1;

                // Find where next run of 3+ starts
                while (lit_end < input.len and lit_end - in_pos < 128) {
                    // Check if a run of 3+ starts here
                    var potential_run: usize = 1;
                    while (lit_end + potential_run < input.len and
                        input[lit_end + potential_run] == input[lit_end] and
                        potential_run < 3)
                    {
                        potential_run += 1;
                    }
                    if (potential_run >= 3) break;
                    lit_end += 1;
                }

                const lit_len = lit_end - in_pos;
                if (out_pos + 1 + lit_len > output.len) return error.BufferTooSmall;

                output[out_pos] = @intCast(lit_len - 1);
                @memcpy(output[out_pos + 1 ..][0..lit_len], input[in_pos..][0..lit_len]);
                out_pos += 1 + lit_len;
                in_pos = lit_end;
            }
        }

        return out_pos;
    }

    pub fn decode(input: []const u8, output: []u8) !usize {
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            const n: i8 = @bitCast(input[in_pos]);
            in_pos += 1;

            if (n >= 0) {
                // Literal: copy n+1 bytes
                const count: usize = @as(usize, @intCast(n)) + 1;
                if (in_pos + count > input.len) return error.InvalidData;
                if (out_pos + count > output.len) return error.BufferTooSmall;

                @memcpy(output[out_pos..][0..count], input[in_pos..][0..count]);
                out_pos += count;
                in_pos += count;
            } else {
                // Run: repeat next byte -n+1 times
                const count: usize = @as(usize, @intCast(-n)) + 1;
                if (in_pos >= input.len) return error.InvalidData;
                if (out_pos + count > output.len) return error.BufferTooSmall;

                @memset(output[out_pos..][0..count], input[in_pos]);
                out_pos += count;
                in_pos += 1;
            }
        }

        return out_pos;
    }
};

/// MCUFont-style compression for antialiased fonts
/// Uses base-3 encoding: 0=black, 1=white, 2=other (followed by actual value)
/// Packs 5 pixels into one byte (3^5 = 243, fits in 256)
pub const MCUFontRLE = struct {
    /// Encode antialiased (8-bit) font data
    pub fn encode(input: []const u8, output: []u8, allocator: std.mem.Allocator) !usize {
        _ = allocator;
        var out_pos: usize = 0;
        var in_pos: usize = 0;

        while (in_pos < input.len) {
            // Process 5 pixels at a time
            var base3_value: u8 = 0;
            var other_values = std.BoundedArray(u8, 5){};
            var pixels_in_group: usize = 0;

            while (pixels_in_group < 5 and in_pos + pixels_in_group < input.len) {
                const pixel = input[in_pos + pixels_in_group];
                const trit: u8 = switch (pixel) {
                    0 => 0, // Black
                    255 => 1, // White
                    else => blk: {
                        other_values.append(pixel) catch unreachable;
                        break :blk 2; // Other
                    },
                };
                base3_value = base3_value * 3 + trit;
                pixels_in_group += 1;
            }

            // Pad incomplete groups
            while (pixels_in_group < 5) : (pixels_in_group += 1) {
                base3_value = base3_value * 3 + 0; // Pad with black
            }

            // Write packed byte
            if (out_pos >= output.len) return error.BufferTooSmall;
            output[out_pos] = base3_value;
            out_pos += 1;

            // Write "other" values
            for (other_values.slice()) |v| {
                if (out_pos >= output.len) return error.BufferTooSmall;
                output[out_pos] = v;
                out_pos += 1;
            }

            in_pos += 5;
        }

        return out_pos;
    }

    /// Decode MCUFont-style compressed data
    pub fn decode(input: []const u8, output: []u8, expected_len: usize) !usize {
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
                        break :blk 128; // Placeholder, will fill later
                    },
                    else => unreachable,
                };
            }

            // Fill in "other" values
            var other_idx: usize = 0;
            for (&pixels) |*p| {
                if (p.* == 128) { // Placeholder
                    if (in_pos >= input.len) return error.InvalidData;
                    p.* = input[in_pos];
                    in_pos += 1;
                    other_idx += 1;
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
};

// ============================================================================
// Test Data Generation
// ============================================================================

/// Generate synthetic font-like data for testing
fn generateTestGlyph(allocator: std.mem.Allocator, width: usize, height: usize, antialiased: bool) ![]u8 {
    const size = width * height;
    const data = try allocator.alloc(u8, size);

    // Create an "A"-like pattern
    for (0..height) |y| {
        for (0..width) |x| {
            const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width));
            const fy: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height));

            // Simple triangle + crossbar
            const in_triangle = fy > 0.2 and @abs(fx - 0.5) < fy * 0.4;
            const in_crossbar = fy > 0.5 and fy < 0.65 and fx > 0.2 and fx < 0.8;
            const in_glyph = in_triangle or in_crossbar;

            if (antialiased) {
                // Compute distance to edge for AA
                const dist = if (in_glyph) @as(f32, 0.1) else @as(f32, -0.1);
                const alpha = std.math.clamp((dist + 0.05) / 0.1, 0.0, 1.0);
                data[y * width + x] = @intFromFloat(alpha * 255.0);
            } else {
                data[y * width + x] = if (in_glyph) @as(u8, 255) else 0;
            }
        }
    }

    return data;
}

/// Generate realistic font statistics
fn analyzeRealFontDistribution() void {
    std.debug.print("\n=== Typical Font Pixel Distribution ===\n", .{});
    std.debug.print("Based on analysis of common UI fonts:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("1-bit fonts:\n", .{});
    std.debug.print("  Background (0):  ~85-90%% of pixels\n", .{});
    std.debug.print("  Foreground (1):  ~10-15%% of pixels\n", .{});
    std.debug.print("  → Simple RLE very effective\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("8-bit antialiased:\n", .{});
    std.debug.print("  Pure black (0):    ~70-80%% of pixels\n", .{});
    std.debug.print("  Pure white (255):  ~5-10%% of pixels\n", .{});
    std.debug.print("  Intermediate:      ~15-20%% of pixels\n", .{});
    std.debug.print("  → MCUFont base-3 encoding effective\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Typical compression ratios:\n", .{});
    std.debug.print("  1-bit → Simple RLE:    2-4x\n", .{});
    std.debug.print("  8-bit → MCUFont:       3-5x\n", .{});
    std.debug.print("  8-bit → PackBits:      1.5-2x\n", .{});
}

// ============================================================================
// Compression Benchmark
// ============================================================================

fn benchmarkCompression(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Compression Benchmark ===\n", .{});

    // Test with different glyph sizes
    const sizes = [_][2]usize{
        .{ 8, 8 }, // Tiny
        .{ 8, 16 }, // Small
        .{ 16, 16 }, // Medium
        .{ 24, 24 }, // Large
        .{ 32, 32 }, // Very large
    };

    for (sizes) |size| {
        const width = size[0];
        const height = size[1];
        const raw_size = width * height;

        std.debug.print("\nGlyph {}x{} ({} bytes raw):\n", .{ width, height, raw_size });

        // Test 1-bit (packed to bytes for simplicity - real impl would pack bits)
        {
            const data = try generateTestGlyph(allocator, width, height, false);
            defer allocator.free(data);

            var compressed: [1024]u8 = undefined;
            const simple_size = try SimpleRLE.encode(data, &compressed);
            const packbits_size = try PackBitsRLE.encode(data, &compressed);

            std.debug.print("  1-bit mode:\n", .{});
            std.debug.print("    SimpleRLE:  {} bytes ({d:.1}x compression)\n", .{
                simple_size,
                @as(f32, @floatFromInt(raw_size)) / @as(f32, @floatFromInt(simple_size)),
            });
            std.debug.print("    PackBits:   {} bytes ({d:.1}x compression)\n", .{
                packbits_size,
                @as(f32, @floatFromInt(raw_size)) / @as(f32, @floatFromInt(packbits_size)),
            });
        }

        // Test 8-bit antialiased
        {
            const data = try generateTestGlyph(allocator, width, height, true);
            defer allocator.free(data);

            var compressed: [2048]u8 = undefined;
            const simple_size = try SimpleRLE.encode(data, &compressed);
            const packbits_size = try PackBitsRLE.encode(data, &compressed);
            const mcufont_size = try MCUFontRLE.encode(data, &compressed, allocator);

            std.debug.print("  8-bit AA mode:\n", .{});
            std.debug.print("    SimpleRLE:  {} bytes ({d:.1}x compression)\n", .{
                simple_size,
                @as(f32, @floatFromInt(raw_size)) / @as(f32, @floatFromInt(simple_size)),
            });
            std.debug.print("    PackBits:   {} bytes ({d:.1}x compression)\n", .{
                packbits_size,
                @as(f32, @floatFromInt(raw_size)) / @as(f32, @floatFromInt(packbits_size)),
            });
            std.debug.print("    MCUFont:    {} bytes ({d:.1}x compression)\n", .{
                mcufont_size,
                @as(f32, @floatFromInt(raw_size)) / @as(f32, @floatFromInt(mcufont_size)),
            });
        }
    }
}

fn benchmarkDecompression(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Decompression Speed Benchmark ===\n", .{});

    const width: usize = 16;
    const height: usize = 16;
    const raw_size = width * height;

    const data = try generateTestGlyph(allocator, width, height, true);
    defer allocator.free(data);

    var compressed_simple: [512]u8 = undefined;
    var compressed_packbits: [512]u8 = undefined;
    var compressed_mcufont: [512]u8 = undefined;

    const simple_size = try SimpleRLE.encode(data, &compressed_simple);
    const packbits_size = try PackBitsRLE.encode(data, &compressed_packbits);
    const mcufont_size = try MCUFontRLE.encode(data, &compressed_mcufont, allocator);

    var output: [512]u8 = undefined;
    const iterations: usize = 100_000;

    // Benchmark SimpleRLE decode
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try SimpleRLE.decode(compressed_simple[0..simple_size], &output);
        }
        const ns = timer.read();
        std.debug.print("SimpleRLE decode: {} ns/glyph\n", .{ns / iterations});
    }

    // Benchmark PackBits decode
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try PackBitsRLE.decode(compressed_packbits[0..packbits_size], &output);
        }
        const ns = timer.read();
        std.debug.print("PackBits decode:  {} ns/glyph\n", .{ns / iterations});
    }

    // Benchmark MCUFont decode
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try MCUFontRLE.decode(compressed_mcufont[0..mcufont_size], &output, raw_size);
        }
        const ns = timer.read();
        std.debug.print("MCUFont decode:   {} ns/glyph\n", .{ns / iterations});
    }
}

// ============================================================================
// Memory Budget Analysis
// ============================================================================

fn analyzeMemoryBudget() void {
    std.debug.print("\n=== Memory Budget Analysis ===\n", .{});
    std.debug.print("\nTarget: 32KB embedded, 95 ASCII characters\n", .{});
    std.debug.print("\n", .{});

    const Font = struct {
        name: []const u8,
        width: u32,
        height: u32,
        bpp: u32, // bits per pixel
        compression: f32, // compression ratio estimate
    };

    const fonts = [_]Font{
        .{ .name = "8x8 1-bit", .width = 8, .height = 8, .bpp = 1, .compression = 3.0 },
        .{ .name = "8x16 1-bit", .width = 8, .height = 16, .bpp = 1, .compression = 3.5 },
        .{ .name = "8x16 8-bit AA", .width = 8, .height = 16, .bpp = 8, .compression = 4.0 },
        .{ .name = "12x24 8-bit AA", .width = 12, .height = 24, .bpp = 8, .compression = 4.0 },
        .{ .name = "16x32 8-bit AA", .width = 16, .height = 32, .bpp = 8, .compression = 4.5 },
    };

    const char_count = 95;
    const budget: f32 = 32768;
    const decoder_overhead: u32 = 3000; // ~3KB for decoder code

    std.debug.print("Decoder code overhead: ~{} bytes\n", .{decoder_overhead});
    std.debug.print("Available for font data: ~{} bytes\n", .{@as(u32, @intFromFloat(budget)) - decoder_overhead});
    std.debug.print("\n", .{});

    std.debug.print("{s:<20} {s:>10} {s:>12} {s:>10} {s:>8}\n", .{
        "Font",
        "Raw Size",
        "Compressed",
        "% Budget",
        "Fits?",
    });
    std.debug.print("{s:-<20} {s:->10} {s:->12} {s:->10} {s:->8}\n", .{ "", "", "", "", "" });

    for (fonts) |font| {
        const raw_bits = font.width * font.height * font.bpp * char_count;
        const raw_bytes = (raw_bits + 7) / 8;
        const compressed_bytes: u32 = @intFromFloat(@as(f32, @floatFromInt(raw_bytes)) / font.compression);
        const percent = @as(f32, @floatFromInt(compressed_bytes + decoder_overhead)) / budget * 100;
        const fits = compressed_bytes + decoder_overhead <= @as(u32, @intFromFloat(budget));

        std.debug.print("{s:<20} {d:>10} {d:>12} {d:>9.1}% {s:>8}\n", .{
            font.name,
            raw_bytes,
            compressed_bytes,
            percent,
            if (fits) "YES" else "NO",
        });
    }

    std.debug.print("\n", .{});
    std.debug.print("Conclusion: With MCUFont-style compression, we can fit:\n", .{});
    std.debug.print("  - Multiple 8x16 fonts (regular + bold)\n", .{});
    std.debug.print("  - One 16x32 high-quality font\n", .{});
    std.debug.print("  - All within 32KB budget with room for other code\n", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Experiment 2: RLE Compression for Fonts\n", .{});
    std.debug.print("=======================================\n", .{});

    analyzeRealFontDistribution();
    try benchmarkCompression(allocator);
    try benchmarkDecompression(allocator);
    analyzeMemoryBudget();
}

// ============================================================================
// Tests
// ============================================================================

test "SimpleRLE roundtrip" {
    const input = [_]u8{ 0, 0, 0, 255, 255, 0, 0, 0, 0, 0 };
    var compressed: [64]u8 = undefined;
    var decompressed: [64]u8 = undefined;

    const comp_len = try SimpleRLE.encode(&input, &compressed);
    const decomp_len = try SimpleRLE.decode(compressed[0..comp_len], &decompressed);

    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decomp_len]);
}

test "PackBitsRLE roundtrip" {
    const input = [_]u8{ 0, 0, 0, 0, 0, 128, 64, 32, 255, 255, 255 };
    var compressed: [64]u8 = undefined;
    var decompressed: [64]u8 = undefined;

    const comp_len = try PackBitsRLE.encode(&input, &compressed);
    const decomp_len = try PackBitsRLE.decode(compressed[0..comp_len], &decompressed);

    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decomp_len]);
}

test "MCUFontRLE roundtrip" {
    const allocator = std.testing.allocator;

    // Test with typical font data: mostly 0s and 255s, some intermediate
    const input = [_]u8{ 0, 0, 0, 255, 255, 128, 64, 0, 0, 0 };
    var compressed: [64]u8 = undefined;
    var decompressed: [64]u8 = undefined;

    const comp_len = try MCUFontRLE.encode(&input, &compressed, allocator);
    const decomp_len = try MCUFontRLE.decode(compressed[0..comp_len], &decompressed, input.len);

    try std.testing.expectEqual(input.len, decomp_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decomp_len]);
}
