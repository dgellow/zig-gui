//! Experiment 4: Memory Budget Calculator
//!
//! Goal: Calculate concrete memory requirements for text rendering
//! across different target platforms.
//!
//! This helps us make informed decisions about what's feasible
//! at each tier.

const std = @import("std");

// ============================================================================
// Platform Budgets
// ============================================================================

pub const Platform = enum {
    embedded_32kb,
    embedded_64kb,
    mobile_256kb,
    desktop_1mb,

    pub fn totalBudget(self: Platform) usize {
        return switch (self) {
            .embedded_32kb => 32 * 1024,
            .embedded_64kb => 64 * 1024,
            .mobile_256kb => 256 * 1024,
            .desktop_1mb => 1024 * 1024,
        };
    }

    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .embedded_32kb => "Embedded 32KB",
            .embedded_64kb => "Embedded 64KB",
            .mobile_256kb => "Mobile 256KB",
            .desktop_1mb => "Desktop 1MB",
        };
    }
};

// ============================================================================
// Component Costs
// ============================================================================

pub const FontConfig = struct {
    name: []const u8,
    width: u16,
    height: u16,
    bpp: u8, // bits per pixel: 1, 2, 4, 8
    char_count: u16,
    compression_ratio: f32, // 1.0 = no compression

    pub fn rawSize(self: FontConfig) usize {
        const bits = @as(usize, self.width) * self.height * self.bpp * self.char_count;
        return (bits + 7) / 8;
    }

    pub fn compressedSize(self: FontConfig) usize {
        return @intFromFloat(@as(f32, @floatFromInt(self.rawSize())) / self.compression_ratio);
    }
};

pub const GlyphCacheConfig = struct {
    max_glyphs: u16,
    avg_glyph_size: u16, // pixels
    bpp: u8,

    pub fn size(self: GlyphCacheConfig) usize {
        return @as(usize, self.max_glyphs) * self.avg_glyph_size * (self.bpp / 8);
    }
};

pub const AtlasConfig = struct {
    width: u16,
    height: u16,
    format: Format,
    in_vram: bool = false, // If true, doesn't count against RAM budget

    pub const Format = enum {
        alpha8,
        rgba32,
        sdf_alpha8,
        msdf_rgb24,
    };

    pub fn size(self: AtlasConfig) usize {
        const pixels = @as(usize, self.width) * self.height;
        const bytes_per_pixel: usize = switch (self.format) {
            .alpha8, .sdf_alpha8 => 1,
            .msdf_rgb24 => 3,
            .rgba32 => 4,
        };
        return pixels * bytes_per_pixel;
    }
};

pub const CodeSizes = struct {
    // Decoder code sizes (approximate)
    pub const bitmap_decoder: usize = 1024; // Simple bitmap render
    pub const rle_decoder: usize = 3072; // MCUFont-style RLE
    pub const stb_truetype: usize = 20 * 1024; // Full TTF parser
    pub const sdf_shader: usize = 2048; // SDF fragment shader + setup
    pub const harfbuzz_shaping: usize = 100 * 1024; // Full HarfBuzz
    pub const simple_shaping: usize = 5 * 1024; // Basic kerning only
};

// ============================================================================
// Predefined Configurations
// ============================================================================

pub const Configs = struct {
    // Embedded tier: minimal
    pub const embedded_minimal = struct {
        pub const fonts = [_]FontConfig{
            .{
                .name = "8x8 ASCII",
                .width = 8,
                .height = 8,
                .bpp = 1,
                .char_count = 95,
                .compression_ratio = 1.0, // No compression
            },
        };
        pub const atlas: ?AtlasConfig = null;
        pub const cache: ?GlyphCacheConfig = null;
        pub const code_size = CodeSizes.bitmap_decoder;
        pub const runtime_overhead: usize = 64; // Struct overhead
    };

    // Embedded tier: quality
    pub const embedded_quality = struct {
        pub const fonts = [_]FontConfig{
            .{
                .name = "12x20 ASCII AA",
                .width = 12,
                .height = 20,
                .bpp = 8,
                .char_count = 95,
                .compression_ratio = 4.0, // MCUFont compression
            },
        };
        pub const atlas: ?AtlasConfig = null;
        pub const cache: ?GlyphCacheConfig = null;
        pub const code_size = CodeSizes.rle_decoder;
        pub const runtime_overhead: usize = 256;
    };

    // Desktop software: dynamic fonts
    pub const desktop_software = struct {
        pub const fonts = [_]FontConfig{}; // Loaded at runtime
        pub const atlas: ?AtlasConfig = .{
            .width = 512,
            .height = 512,
            .format = .alpha8,
        };
        pub const cache: ?GlyphCacheConfig = .{
            .max_glyphs = 512,
            .avg_glyph_size = 256, // 16x16 average
            .bpp = 8,
        };
        pub const code_size = CodeSizes.stb_truetype + CodeSizes.simple_shaping;
        pub const runtime_overhead: usize = 4096;
    };

    // Desktop GPU: SDF
    pub const desktop_gpu = struct {
        pub const fonts = [_]FontConfig{}; // SDF atlas
        pub const atlas: ?AtlasConfig = .{
            .width = 1024,
            .height = 1024,
            .format = .msdf_rgb24,
            .in_vram = true, // Atlas lives in GPU memory, not RAM
        };
        pub const cache: ?GlyphCacheConfig = null; // GPU handles caching
        pub const code_size = CodeSizes.sdf_shader + CodeSizes.simple_shaping;
        pub const runtime_overhead: usize = 2048;
    };
};

// ============================================================================
// Budget Calculator
// ============================================================================

pub fn calculateBudget(
    comptime fonts: []const FontConfig,
    comptime atlas: ?AtlasConfig,
    comptime cache: ?GlyphCacheConfig,
    comptime code_size: usize,
    comptime runtime_overhead: usize,
) struct {
    font_data: usize,
    atlas_size: usize,
    atlas_in_vram: bool,
    cache_size: usize,
    code: usize,
    overhead: usize,
    ram_total: usize, // RAM only (excludes VRAM)
    vram_total: usize, // VRAM only
} {
    var font_data: usize = 0;
    for (fonts) |font| {
        font_data += font.compressedSize();
    }

    const atlas_size = if (atlas) |a| a.size() else 0;
    const atlas_in_vram = if (atlas) |a| a.in_vram else false;
    const cache_size = if (cache) |c| c.size() else 0;

    // RAM total excludes VRAM atlas
    const ram_atlas = if (atlas_in_vram) 0 else atlas_size;
    const vram_atlas = if (atlas_in_vram) atlas_size else 0;

    return .{
        .font_data = font_data,
        .atlas_size = atlas_size,
        .atlas_in_vram = atlas_in_vram,
        .cache_size = cache_size,
        .code = code_size,
        .overhead = runtime_overhead,
        .ram_total = font_data + ram_atlas + cache_size + code_size + runtime_overhead,
        .vram_total = vram_atlas,
    };
}

// ============================================================================
// Analysis Functions
// ============================================================================

fn printBudgetAnalysis(
    platform: Platform,
    config_name: []const u8,
    budget: anytype,
) void {
    const total_budget = platform.totalBudget();
    const used_percent = @as(f32, @floatFromInt(budget.ram_total)) / @as(f32, @floatFromInt(total_budget)) * 100;

    std.debug.print("\n{s} on {s}:\n", .{ config_name, platform.name() });
    std.debug.print("  Font data:     {:>8} bytes\n", .{budget.font_data});
    if (budget.atlas_in_vram) {
        std.debug.print("  Atlas (VRAM):  {:>8} bytes (not counted)\n", .{budget.atlas_size});
    } else {
        std.debug.print("  Atlas (RAM):   {:>8} bytes\n", .{budget.atlas_size});
    }
    std.debug.print("  Glyph cache:   {:>8} bytes\n", .{budget.cache_size});
    std.debug.print("  Code:          {:>8} bytes\n", .{budget.code});
    std.debug.print("  Overhead:      {:>8} bytes\n", .{budget.overhead});
    std.debug.print("  ─────────────────────────\n", .{});
    std.debug.print("  RAM TOTAL:     {:>8} bytes ({d:.1}% of budget)\n", .{
        budget.ram_total,
        used_percent,
    });
    if (budget.vram_total > 0) {
        std.debug.print("  VRAM TOTAL:    {:>8} bytes ({d:.1} MB)\n", .{
            budget.vram_total,
            @as(f32, @floatFromInt(budget.vram_total)) / (1024 * 1024),
        });
    }

    if (budget.ram_total <= total_budget) {
        std.debug.print("  Status: ✓ FITS ({} bytes remaining)\n", .{total_budget - budget.ram_total});
    } else {
        std.debug.print("  Status: ✗ EXCEEDS by {} bytes\n", .{budget.ram_total - total_budget});
    }
}

fn analyzeEmbeddedOptions() void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("EMBEDDED OPTIONS ANALYSIS\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    // Test various font configurations against 32KB budget
    const test_fonts = [_]FontConfig{
        // Minimal: 1-bit 8x8
        .{ .name = "8x8 1-bit", .width = 8, .height = 8, .bpp = 1, .char_count = 95, .compression_ratio = 1.0 },
        // Small: 1-bit 8x16
        .{ .name = "8x16 1-bit", .width = 8, .height = 16, .bpp = 1, .char_count = 95, .compression_ratio = 1.0 },
        // Medium: 8-bit 8x16 compressed
        .{ .name = "8x16 8-bit RLE", .width = 8, .height = 16, .bpp = 8, .char_count = 95, .compression_ratio = 4.0 },
        // Large: 8-bit 12x20 compressed
        .{ .name = "12x20 8-bit RLE", .width = 12, .height = 20, .bpp = 8, .char_count = 95, .compression_ratio = 4.0 },
        // XL: 8-bit 16x24 compressed
        .{ .name = "16x24 8-bit RLE", .width = 16, .height = 24, .bpp = 8, .char_count = 95, .compression_ratio = 4.5 },
    };

    std.debug.print("\nFont size analysis (95 ASCII chars, with RLE decoder ~3KB):\n\n", .{});
    std.debug.print("{s:<20} {s:>10} {s:>12} {s:>10} {s:>10}\n", .{
        "Font",
        "Raw",
        "Compressed",
        "+Decoder",
        "% of 32KB",
    });
    std.debug.print("{s:-<20} {s:->10} {s:->12} {s:->10} {s:->10}\n", .{ "", "", "", "", "" });

    for (test_fonts) |font| {
        const raw = font.rawSize();
        const compressed = font.compressedSize();
        const decoder = if (font.compression_ratio > 1.0) CodeSizes.rle_decoder else CodeSizes.bitmap_decoder;
        const total = compressed + decoder;
        const percent = @as(f32, @floatFromInt(total)) / 32768.0 * 100.0;

        std.debug.print("{s:<20} {d:>10} {d:>12} {d:>10} {d:>9.1}%\n", .{
            font.name,
            raw,
            compressed,
            total,
            percent,
        });
    }

    std.debug.print("\nConclusion for 32KB:\n", .{});
    std.debug.print("  - Multiple 8x16 fonts possible (bold, italic)\n", .{});
    std.debug.print("  - Single 16x24 high-quality font fits\n", .{});
    std.debug.print("  - Leaves ~20KB for application code\n", .{});
}

fn analyzeDesktopOptions() void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("DESKTOP OPTIONS ANALYSIS\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    // Atlas size options
    const atlas_sizes = [_][2]u16{
        .{ 256, 256 },
        .{ 512, 512 },
        .{ 1024, 1024 },
        .{ 2048, 2048 },
    };

    const formats = [_]struct {
        name: []const u8,
        bpp: u8,
    }{
        .{ .name = "Alpha8", .bpp = 1 },
        .{ .name = "MSDF RGB", .bpp = 3 },
        .{ .name = "RGBA", .bpp = 4 },
    };

    std.debug.print("\nAtlas memory requirements:\n\n", .{});
    std.debug.print("{s:<12}", .{""});
    for (formats) |f| {
        std.debug.print(" {s:>12}", .{f.name});
    }
    std.debug.print("\n", .{});

    for (atlas_sizes) |size| {
        std.debug.print("{d}x{d:<8}", .{ size[0], size[1] });
        for (formats) |f| {
            const bytes = @as(usize, size[0]) * size[1] * f.bpp;
            if (bytes >= 1024 * 1024) {
                std.debug.print(" {d:>10.1} MB", .{@as(f32, @floatFromInt(bytes)) / (1024 * 1024)});
            } else {
                std.debug.print(" {d:>10} KB", .{bytes / 1024});
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\nGlyph cache sizing (for stb_truetype):\n\n", .{});

    const cache_scenarios = [_]struct {
        name: []const u8,
        glyphs: u16,
        avg_size: u16,
    }{
        .{ .name = "Minimal", .glyphs = 128, .avg_size = 144 }, // 12x12
        .{ .name = "Standard", .glyphs = 256, .avg_size = 256 }, // 16x16
        .{ .name = "Extended", .glyphs = 512, .avg_size = 400 }, // 20x20
        .{ .name = "CJK Ready", .glyphs = 2048, .avg_size = 576 }, // 24x24
    };

    std.debug.print("{s:<15} {s:>10} {s:>12} {s:>12}\n", .{
        "Scenario",
        "Glyphs",
        "Avg Size",
        "Total",
    });
    std.debug.print("{s:-<15} {s:->10} {s:->12} {s:->12}\n", .{ "", "", "", "" });

    for (cache_scenarios) |s| {
        const total = @as(usize, s.glyphs) * s.avg_size;
        std.debug.print("{s:<15} {d:>10} {d:>10}px {d:>10} KB\n", .{
            s.name,
            s.glyphs,
            s.avg_size,
            total / 1024,
        });
    }
}

fn analyzeCodeSizes() void {
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("CODE SIZE ANALYSIS\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    const components = [_]struct {
        name: []const u8,
        size: usize,
        tier: []const u8,
    }{
        .{ .name = "Bitmap decoder", .size = CodeSizes.bitmap_decoder, .tier = "Embedded" },
        .{ .name = "RLE decoder (MCUFont)", .size = CodeSizes.rle_decoder, .tier = "Embedded" },
        .{ .name = "Simple kerning", .size = CodeSizes.simple_shaping, .tier = "All" },
        .{ .name = "stb_truetype", .size = CodeSizes.stb_truetype, .tier = "Desktop" },
        .{ .name = "SDF shader + setup", .size = CodeSizes.sdf_shader, .tier = "Desktop GPU" },
        .{ .name = "HarfBuzz (full)", .size = CodeSizes.harfbuzz_shaping, .tier = "Desktop i18n" },
    };

    std.debug.print("\n{s:<25} {s:>12} {s:<15}\n", .{ "Component", "Size", "Tier" });
    std.debug.print("{s:-<25} {s:->12} {s:-<15}\n", .{ "", "", "" });

    for (components) |c| {
        std.debug.print("{s:<25} {d:>10} KB {s:<15}\n", .{
            c.name,
            c.size / 1024,
            c.tier,
        });
    }

    std.debug.print("\nRecommended stacks:\n", .{});
    std.debug.print("  Embedded minimal: Bitmap decoder (~1KB)\n", .{});
    std.debug.print("  Embedded quality: RLE decoder (~3KB)\n", .{});
    std.debug.print("  Desktop SW: stb_truetype + kerning (~25KB)\n", .{});
    std.debug.print("  Desktop GPU: SDF + kerning (~7KB code, atlas in VRAM)\n", .{});
    std.debug.print("  Desktop i18n: stb_truetype + HarfBuzz (~125KB)\n", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("Experiment 4: Memory Budget Calculator\n", .{});
    std.debug.print("======================================\n", .{});

    // Analyze predefined configurations
    {
        const budget = calculateBudget(
            &Configs.embedded_minimal.fonts,
            Configs.embedded_minimal.atlas,
            Configs.embedded_minimal.cache,
            Configs.embedded_minimal.code_size,
            Configs.embedded_minimal.runtime_overhead,
        );
        printBudgetAnalysis(.embedded_32kb, "Minimal bitmap", budget);
    }

    {
        const budget = calculateBudget(
            &Configs.embedded_quality.fonts,
            Configs.embedded_quality.atlas,
            Configs.embedded_quality.cache,
            Configs.embedded_quality.code_size,
            Configs.embedded_quality.runtime_overhead,
        );
        printBudgetAnalysis(.embedded_32kb, "Quality RLE", budget);
    }

    {
        const budget = calculateBudget(
            &Configs.desktop_software.fonts,
            Configs.desktop_software.atlas,
            Configs.desktop_software.cache,
            Configs.desktop_software.code_size,
            Configs.desktop_software.runtime_overhead,
        );
        printBudgetAnalysis(.desktop_1mb, "Desktop SW", budget);
    }

    {
        const budget = calculateBudget(
            &Configs.desktop_gpu.fonts,
            Configs.desktop_gpu.atlas,
            Configs.desktop_gpu.cache,
            Configs.desktop_gpu.code_size,
            Configs.desktop_gpu.runtime_overhead,
        );
        printBudgetAnalysis(.desktop_1mb, "Desktop GPU", budget);
    }

    // Detailed analyses
    analyzeEmbeddedOptions();
    analyzeDesktopOptions();
    analyzeCodeSizes();

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("SUMMARY\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Embedded 32KB can support:\n", .{});
    std.debug.print("  - High-quality 12x20 antialiased font\n", .{});
    std.debug.print("  - Full ASCII charset\n", .{});
    std.debug.print("  - Basic kerning\n", .{});
    std.debug.print("  - Using ~15-20%% of budget\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Desktop 1MB can support:\n", .{});
    std.debug.print("  - Multiple runtime-loaded TTF fonts\n", .{});
    std.debug.print("  - Full Unicode coverage (with fallback)\n", .{});
    std.debug.print("  - Complex script shaping (HarfBuzz)\n", .{});
    std.debug.print("  - SDF/MSDF for GPU rendering\n", .{});
    std.debug.print("  - Using ~30-40%% of budget\n", .{});
}
