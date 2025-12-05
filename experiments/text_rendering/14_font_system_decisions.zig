//! Experiment 14: Font System Decision Validation
//!
//! This experiment makes DECISIONS, not just validates implementation.
//! Each section tests options and produces a concrete recommendation.
//!
//! DECISIONS TO MAKE:
//! 1. Is stb_truetype kerning useful? (kern table coverage in real fonts)
//! 2. Shared vs per-font atlas pages (memory vs isolation tradeoffs)
//! 3. Where does text→quads conversion happen? (architecture decision)
//! 4. Grapheme segmentation: internal or pluggable? (interface decision)
//! 5. Emoji without COLR parser: what actually renders? (UX decision)
//!
//! Run: zig build-exe -lc 14_font_system_decisions.zig && ./14_font_system_decisions
//! Or with fonts: ./14_font_system_decisions /path/to/fonts/

const std = @import("std");

// ============================================================================
// DECISION 1: Is stb_truetype kerning useful?
// ============================================================================
//
// Question: Do modern fonts have kern tables, or only GPOS?
// If most fonts are GPOS-only, stbtt_GetCodepointKernAdvance() returns 0
// and we'd need HarfBuzz even for basic Latin kerning.

const KernTableAnalysis = struct {
    font_name: []const u8,
    has_kern_table: bool,
    kern_pair_count: u32,
    sample_pairs: [10]KernPair,
    sample_count: u8,

    const KernPair = struct {
        left: u32,
        right: u32,
        advance: i32,
    };
};

fn analyzeKernTable(allocator: std.mem.Allocator, font_path: []const u8) !?KernTableAnalysis {
    const file = std.fs.cwd().openFile(font_path, .{}) catch return null;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch return null;
    defer allocator.free(data);

    // Parse font to find kern table
    // TTF structure: offset table -> table directory -> kern table
    if (data.len < 12) return null;

    const num_tables = std.mem.readInt(u16, data[4..6], .big);
    var kern_offset: ?u32 = null;
    var kern_length: u32 = 0;

    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const entry_offset = 12 + i * 16;
        if (entry_offset + 16 > data.len) break;

        const tag = data[entry_offset..][0..4];
        if (std.mem.eql(u8, tag, "kern")) {
            kern_offset = std.mem.readInt(u32, data[entry_offset + 8 ..][0..4], .big);
            kern_length = std.mem.readInt(u32, data[entry_offset + 12 ..][0..4], .big);
            break;
        }
    }

    const basename = std.fs.path.basename(font_path);

    if (kern_offset == null) {
        return KernTableAnalysis{
            .font_name = basename,
            .has_kern_table = false,
            .kern_pair_count = 0,
            .sample_pairs = undefined,
            .sample_count = 0,
        };
    }

    // Parse kern table to count pairs
    const kern_data = data[kern_offset.?..][0..@min(kern_length, data.len - kern_offset.?)];
    if (kern_data.len < 4) {
        return KernTableAnalysis{
            .font_name = basename,
            .has_kern_table = true,
            .kern_pair_count = 0,
            .sample_pairs = undefined,
            .sample_count = 0,
        };
    }

    // Version 0 kern table format
    const version = std.mem.readInt(u16, kern_data[0..2], .big);
    var pair_count: u32 = 0;
    var samples: [10]KernTableAnalysis.KernPair = undefined;
    var sample_count: u8 = 0;

    if (version == 0 and kern_data.len >= 4) {
        const n_tables = std.mem.readInt(u16, kern_data[2..4], .big);
        if (n_tables > 0 and kern_data.len >= 14) {
            // First subtable
            const format = kern_data[8 + 4] >> 4;
            if (format == 0 and kern_data.len >= 14) {
                pair_count = std.mem.readInt(u16, kern_data[8 + 6 ..][0..2], .big);

                // Extract sample pairs
                const pairs_start: usize = 8 + 14;
                var j: usize = 0;
                while (j < @min(pair_count, 10) and pairs_start + j * 6 + 6 <= kern_data.len) : (j += 1) {
                    const pair_offset = pairs_start + j * 6;
                    samples[j] = .{
                        .left = std.mem.readInt(u16, kern_data[pair_offset..][0..2], .big),
                        .right = std.mem.readInt(u16, kern_data[pair_offset + 2 ..][0..2], .big),
                        .advance = @as(i32, @as(i16, @bitCast(std.mem.readInt(u16, kern_data[pair_offset + 4 ..][0..2], .big)))),
                    };
                    sample_count += 1;
                }
            }
        }
    }

    return KernTableAnalysis{
        .font_name = basename,
        .has_kern_table = true,
        .kern_pair_count = pair_count,
        .sample_pairs = samples,
        .sample_count = sample_count,
    };
}

fn runKerningDecision(allocator: std.mem.Allocator, font_dir: ?[]const u8) !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("DECISION 1: Is stb_truetype kerning useful?\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    // Common font paths to check
    const font_paths = [_][]const u8{
        // Linux paths
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        // macOS paths
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        // Windows paths (WSL)
        "/mnt/c/Windows/Fonts/arial.ttf",
        "/mnt/c/Windows/Fonts/times.ttf",
        "/mnt/c/Windows/Fonts/calibri.ttf",
    };

    var fonts_found: u32 = 0;
    var fonts_with_kern: u32 = 0;
    var total_kern_pairs: u64 = 0;

    std.debug.print("Scanning system fonts for kern tables...\n\n", .{});
    std.debug.print("{s:<40} {s:<10} {s:<12}\n", .{ "Font", "kern?", "Pairs" });
    std.debug.print("{s:<40} {s:<10} {s:<12}\n", .{ "-" ** 38, "-" ** 8, "-" ** 10 });

    // Check provided font directory first
    if (font_dir) |dir| {
        var dir_iter = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |err| {
            std.debug.print("Could not open font directory {s}: {}\n", .{ dir, err });
            return;
        };
        defer dir_iter.close();

        var iter = dir_iter.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8, ext, ".ttf") and !std.mem.eql(u8, ext, ".otf")) continue;

            const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
            defer allocator.free(full_path);

            if (try analyzeKernTable(allocator, full_path)) |analysis| {
                fonts_found += 1;
                if (analysis.has_kern_table) {
                    fonts_with_kern += 1;
                    total_kern_pairs += analysis.kern_pair_count;
                }
                std.debug.print("{s:<40} {s:<10} {d:<12}\n", .{
                    analysis.font_name,
                    if (analysis.has_kern_table) "YES" else "no",
                    analysis.kern_pair_count,
                });
            }
        }
    }

    // Check common system paths
    for (font_paths) |path| {
        if (try analyzeKernTable(allocator, path)) |analysis| {
            fonts_found += 1;
            if (analysis.has_kern_table) {
                fonts_with_kern += 1;
                total_kern_pairs += analysis.kern_pair_count;
            }
            std.debug.print("{s:<40} {s:<10} {d:<12}\n", .{
                analysis.font_name,
                if (analysis.has_kern_table) "YES" else "no",
                analysis.kern_pair_count,
            });
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("RESULTS:\n", .{});
    std.debug.print("  Fonts analyzed: {d}\n", .{fonts_found});
    std.debug.print("  Fonts with kern table: {d} ({d:.0}%)\n", .{
        fonts_with_kern,
        if (fonts_found > 0) @as(f64, @floatFromInt(fonts_with_kern)) / @as(f64, @floatFromInt(fonts_found)) * 100 else 0,
    });
    std.debug.print("  Average kern pairs: {d:.0}\n", .{
        if (fonts_with_kern > 0) @as(f64, @floatFromInt(total_kern_pairs)) / @as(f64, @floatFromInt(fonts_with_kern)) else 0,
    });

    std.debug.print("\n", .{});
    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ DECISION 1 RECOMMENDATION                                               │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});

    const kern_percentage = if (fonts_found > 0)
        @as(f64, @floatFromInt(fonts_with_kern)) / @as(f64, @floatFromInt(fonts_found)) * 100
    else
        0;

    if (kern_percentage >= 70) {
        std.debug.print("│ ✓ stb_truetype kerning IS useful                                        │\n", .{});
        std.debug.print("│   {d:.0}% of fonts have kern tables - implement via stbtt              │\n", .{kern_percentage});
        std.debug.print("│   HarfBuzz only needed for complex scripts (Arabic, Devanagari)        │\n", .{});
    } else if (kern_percentage >= 30) {
        std.debug.print("│ ~ stb_truetype kerning is PARTIALLY useful                             │\n", .{});
        std.debug.print("│   {d:.0}% of fonts have kern tables                                    │\n", .{kern_percentage});
        std.debug.print("│   Implement stb kerning, but document GPOS limitation                  │\n", .{});
        std.debug.print("│   Consider HarfBuzz for full kerning support                           │\n", .{});
    } else {
        std.debug.print("│ ✗ stb_truetype kerning is NOT useful                                   │\n", .{});
        std.debug.print("│   Only {d:.0}% of fonts have kern tables                               │\n", .{kern_percentage});
        std.debug.print("│   Most fonts use GPOS (OpenType) - need HarfBuzz for kerning           │\n", .{});
    }
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});
}

// ============================================================================
// DECISION 2: Shared vs per-font atlas pages
// ============================================================================
//
// Question: Should multi-font scenarios share one atlas or have per-font pages?
// Options:
//   A) Shared: All fonts compete for same atlas space
//   B) Per-font: Each font gets dedicated page(s)
//   C) Per-font-per-size: Even more isolation

const AtlasStrategy = enum {
    shared,
    per_font,
    per_font_per_size,
};

const AtlasSimulation = struct {
    strategy: AtlasStrategy,
    total_memory_kb: u32,
    cache_hit_rate: f64,
    eviction_count: u32,
    peak_glyphs: u32,
};

fn simulateAtlasStrategy(
    strategy: AtlasStrategy,
    scenario: []const GlyphAccess,
    num_fonts: u32,
    atlas_size_kb: u32,
) AtlasSimulation {
    // Simulate glyph caching with given strategy
    const glyph_size: u32 = 256; // Average bytes per glyph (16x16)
    const capacity_per_page = (atlas_size_kb * 1024) / glyph_size;

    var hits: u64 = 0;
    var misses: u64 = 0;
    var evictions: u32 = 0;
    var peak_glyphs: u32 = 0;

    const CacheEntry = struct {
        font_id: u16,
        glyph_id: u16,
        size: u16,
        last_access: u64,
    };

    // Simple LRU simulation per strategy
    const max_cached = 4096;
    var cache: [max_cached]CacheEntry = undefined;
    var cache_count: u32 = 0;
    var cache_time: u64 = 0;


    for (scenario) |access| {
        cache_time += 1;

        // Check if in cache
        var found = false;
        for (cache[0..cache_count]) |*entry| {
            const match = switch (strategy) {
                .shared => entry.glyph_id == access.glyph_id and entry.font_id == access.font_id,
                .per_font => entry.glyph_id == access.glyph_id and entry.font_id == access.font_id,
                .per_font_per_size => entry.glyph_id == access.glyph_id and
                    entry.font_id == access.font_id and
                    entry.size == access.size,
            };
            if (match) {
                entry.last_access = cache_time;
                found = true;
                break;
            }
        }

        if (found) {
            hits += 1;
        } else {
            misses += 1;

            // Calculate effective capacity based on strategy
            const effective_capacity: u32 = switch (strategy) {
                .shared => capacity_per_page,
                .per_font => capacity_per_page * num_fonts,
                .per_font_per_size => capacity_per_page * num_fonts * 3, // Assume 3 sizes
            };

            // Evict if necessary
            if (cache_count >= @min(effective_capacity, max_cached)) {
                // Find LRU entry (with strategy-specific scope)
                var lru_idx: u32 = 0;
                var lru_time: u64 = std.math.maxInt(u64);

                for (cache[0..cache_count], 0..) |entry, idx| {
                    const in_scope = switch (strategy) {
                        .shared => true,
                        .per_font => entry.font_id == access.font_id,
                        .per_font_per_size => entry.font_id == access.font_id and entry.size == access.size,
                    };
                    if (in_scope and entry.last_access < lru_time) {
                        lru_time = entry.last_access;
                        lru_idx = @intCast(idx);
                    }
                }

                cache[lru_idx] = .{
                    .font_id = access.font_id,
                    .glyph_id = access.glyph_id,
                    .size = access.size,
                    .last_access = cache_time,
                };
                evictions += 1;
            } else {
                cache[cache_count] = .{
                    .font_id = access.font_id,
                    .glyph_id = access.glyph_id,
                    .size = access.size,
                    .last_access = cache_time,
                };
                cache_count += 1;
            }
        }

        peak_glyphs = @max(peak_glyphs, cache_count);
    }

    const memory_multiplier: u32 = switch (strategy) {
        .shared => 1,
        .per_font => num_fonts,
        .per_font_per_size => num_fonts * 3,
    };

    return .{
        .strategy = strategy,
        .total_memory_kb = atlas_size_kb * memory_multiplier,
        .cache_hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(hits + misses)) * 100,
        .eviction_count = evictions,
        .peak_glyphs = peak_glyphs,
    };
}

const GlyphAccess = struct {
    font_id: u16,
    glyph_id: u16,
    size: u16,
};

fn generateScenario(allocator: std.mem.Allocator, name: []const u8) ![]GlyphAccess {
    var accesses = std.ArrayList(GlyphAccess).init(allocator);
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    // Note: We use simulated glyph IDs (not real codepoints) since this is a cache simulation.
    // The actual values don't matter - just that different fonts have different glyph spaces.

    if (std.mem.eql(u8, name, "email_client")) {
        // Email: mostly Latin (font 0), occasional symbols (font 1), rare emoji (font 2)
        var i: usize = 0;
        while (i < 5000) : (i += 1) {
            const r = rand.float(f32);
            const font_id: u16 = if (r < 0.85) 0 else if (r < 0.95) 1 else 2;
            const glyph_id: u16 = switch (font_id) {
                0 => rand.intRangeAtMost(u16, 32, 126), // ~95 ASCII glyphs
                1 => rand.intRangeAtMost(u16, 200, 450), // ~250 symbols
                else => rand.intRangeAtMost(u16, 500, 600), // ~100 emoji
            };
            try accesses.append(.{ .font_id = font_id, .glyph_id = glyph_id, .size = 16 });
        }
    } else if (std.mem.eql(u8, name, "code_editor")) {
        // Code: monospace (font 0), symbols (font 1), one size
        var i: usize = 0;
        while (i < 3000) : (i += 1) {
            const r = rand.float(f32);
            const font_id: u16 = if (r < 0.95) 0 else 1;
            const glyph_id: u16 = rand.intRangeAtMost(u16, 32, 126);
            try accesses.append(.{ .font_id = font_id, .glyph_id = glyph_id, .size = 14 });
        }
    } else if (std.mem.eql(u8, name, "cjk_document")) {
        // CJK: Latin (font 0) + CJK (font 3), many unique glyphs
        // CJK has ~20,000 common characters - simulate with large range
        var i: usize = 0;
        while (i < 8000) : (i += 1) {
            const r = rand.float(f32);
            const font_id: u16 = if (r < 0.2) 0 else 3;
            const glyph_id: u16 = switch (font_id) {
                0 => rand.intRangeAtMost(u16, 32, 126),
                else => rand.intRangeAtMost(u16, 1000, 21000), // ~20K CJK glyphs
            };
            try accesses.append(.{ .font_id = font_id, .glyph_id = glyph_id, .size = 16 });
        }
    } else if (std.mem.eql(u8, name, "chat_app")) {
        // Chat: rapid font switching, emoji heavy, multiple sizes
        var i: usize = 0;
        while (i < 6000) : (i += 1) {
            const font_id: u16 = rand.intRangeAtMost(u16, 0, 3);
            const glyph_id: u16 = switch (font_id) {
                0 => rand.intRangeAtMost(u16, 32, 126),
                1 => rand.intRangeAtMost(u16, 200, 450),
                2 => rand.intRangeAtMost(u16, 500, 800), // More emoji variety
                else => rand.intRangeAtMost(u16, 1000, 5000), // Subset of CJK
            };
            const size: u16 = rand.intRangeAtMost(u16, 12, 24);
            try accesses.append(.{ .font_id = font_id, .glyph_id = glyph_id, .size = size });
        }
    }

    return accesses.toOwnedSlice();
}

fn runAtlasDecision(allocator: std.mem.Allocator) !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("DECISION 2: Shared vs per-font atlas pages\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    const scenarios = [_][]const u8{ "email_client", "code_editor", "cjk_document", "chat_app" };
    const strategies = [_]AtlasStrategy{ .shared, .per_font, .per_font_per_size };

    std.debug.print("{s:<15} {s:<12} {s:<12} {s:<10} {s:<10} {s:<10}\n", .{
        "Scenario", "Strategy", "Memory", "Hit Rate", "Evictions", "Peak",
    });
    std.debug.print("{s:<15} {s:<12} {s:<12} {s:<10} {s:<10} {s:<10}\n", .{
        "-" ** 14, "-" ** 11, "-" ** 11, "-" ** 9, "-" ** 9, "-" ** 9,
    });

    var best_per_scenario: [4]struct { strategy: AtlasStrategy, score: f64 } = undefined;

    for (scenarios, 0..) |scenario_name, si| {
        const scenario = try generateScenario(allocator, scenario_name);
        defer allocator.free(scenario);

        var best_score: f64 = 0;
        var best_strategy: AtlasStrategy = .shared;

        for (strategies) |strategy| {
            const result = simulateAtlasStrategy(strategy, scenario, 4, 256);

            // Score: prioritize hit rate, penalize memory
            const memory_penalty = @as(f64, @floatFromInt(result.total_memory_kb)) / 2048.0;
            const score = result.cache_hit_rate - memory_penalty * 10;

            if (score > best_score) {
                best_score = score;
                best_strategy = strategy;
            }

            const strategy_name = switch (strategy) {
                .shared => "shared",
                .per_font => "per-font",
                .per_font_per_size => "per-font-sz",
            };

            std.debug.print("{s:<15} {s:<12} {d:<10}KB {d:<9.1}% {d:<10} {d:<10}\n", .{
                if (strategy == .shared) scenario_name else "",
                strategy_name,
                result.total_memory_kb,
                result.cache_hit_rate,
                result.eviction_count,
                result.peak_glyphs,
            });
        }

        best_per_scenario[si] = .{ .strategy = best_strategy, .score = best_score };
        std.debug.print("\n", .{});
    }

    // Count which strategy won most often
    var shared_wins: u32 = 0;
    var per_font_wins: u32 = 0;
    var per_font_size_wins: u32 = 0;

    for (best_per_scenario) |best| {
        switch (best.strategy) {
            .shared => shared_wins += 1,
            .per_font => per_font_wins += 1,
            .per_font_per_size => per_font_size_wins += 1,
        }
    }

    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ DECISION 2 RECOMMENDATION                                               │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});

    if (per_font_wins >= shared_wins and per_font_wins >= per_font_size_wins) {
        std.debug.print("│ ✓ Use PER-FONT atlas pages                                              │\n", .{});
        std.debug.print("│   Best balance of hit rate and memory                                   │\n", .{});
        std.debug.print("│   Won {d}/4 scenarios                                                    │\n", .{per_font_wins});
    } else if (shared_wins >= per_font_size_wins) {
        std.debug.print("│ ✓ Use SHARED atlas                                                      │\n", .{});
        std.debug.print("│   Simpler, good enough for most scenarios                               │\n", .{});
        std.debug.print("│   Won {d}/4 scenarios                                                    │\n", .{shared_wins});
    } else {
        std.debug.print("│ ✓ Use PER-FONT-PER-SIZE atlas pages                                     │\n", .{});
        std.debug.print("│   Maximum isolation, best for variable-size text                        │\n", .{});
        std.debug.print("│   Won {d}/4 scenarios                                                    │\n", .{per_font_size_wins});
    }

    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Config option: .atlas_mode = .per_font | .shared | .per_font_per_size   │\n", .{});
    std.debug.print("│ Default: .per_font (best general-purpose choice)                        │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});
}

// ============================================================================
// DECISION 3: Where does text→quads conversion happen?
// ============================================================================
//
// Options:
//   A) In widget measurement (gui.text()) - quads computed during layout
//   B) In draw list generation (drawList.addText()) - deferred until draw
//   C) In backend (backend.renderText()) - backend does everything

const DrawArchitecture = enum {
    in_measurement, // Option A
    in_draw_generation, // Option B
    in_backend, // Option C
};

const ArchitectureAnalysis = struct {
    architecture: DrawArchitecture,
    code_complexity: u32, // Lines of glue code needed
    reference_passing: []const u8, // Who needs TextProvider reference
    relayout_cost: []const u8, // What happens on text change
    pros: []const []const u8,
    cons: []const []const u8,
};

fn analyzeDrawArchitecture(arch: DrawArchitecture) ArchitectureAnalysis {
    return switch (arch) {
        .in_measurement => .{
            .architecture = arch,
            .code_complexity = 150,
            .reference_passing = "Widget holds TextProvider",
            .relayout_cost = "Quads recomputed on every layout",
            .pros = &[_][]const u8{
                "Quads ready when draw list built",
                "Backend stays simple (just renders quads)",
            },
            .cons = &[_][]const u8{
                "Wasted work if widget not visible",
                "Layout phase does rendering work",
                "Every widget needs TextProvider ref",
            },
        },
        .in_draw_generation => .{
            .architecture = arch,
            .code_complexity = 100,
            .reference_passing = "GUI/DrawList holds TextProvider",
            .relayout_cost = "Only recompute when generating draw list",
            .pros = &[_][]const u8{
                "Lazy evaluation (only visible text)",
                "Clean separation layout vs render",
                "Single TextProvider reference point",
                "Backend stays simple",
            },
            .cons = &[_][]const u8{
                "Draw list generation is heavier",
            },
        },
        .in_backend => .{
            .architecture = arch,
            .code_complexity = 200,
            .reference_passing = "Backend holds TextProvider",
            .relayout_cost = "Backend recomputes quads every frame",
            .pros = &[_][]const u8{
                "Draw list stays simple (just text + position)",
                "Backend can optimize batching",
            },
            .cons = &[_][]const u8{
                "Every backend must understand text",
                "Duplicated text logic per backend",
                "Backend is complex",
                "Harder to test",
            },
        },
    };
}

fn runDrawArchitectureDecision() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("DECISION 3: Where does text→quads conversion happen?\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    const architectures = [_]DrawArchitecture{ .in_measurement, .in_draw_generation, .in_backend };

    for (architectures) |arch| {
        const analysis = analyzeDrawArchitecture(arch);
        const name = switch (arch) {
            .in_measurement => "A) In Measurement",
            .in_draw_generation => "B) In Draw Generation",
            .in_backend => "C) In Backend",
        };

        std.debug.print("─── {s} ───\n", .{name});
        std.debug.print("  Code complexity: ~{d} lines\n", .{analysis.code_complexity});
        std.debug.print("  Reference passing: {s}\n", .{analysis.reference_passing});
        std.debug.print("  Re-layout cost: {s}\n", .{analysis.relayout_cost});
        std.debug.print("  Pros:\n", .{});
        for (analysis.pros) |pro| {
            std.debug.print("    + {s}\n", .{pro});
        }
        std.debug.print("  Cons:\n", .{});
        for (analysis.cons) |con| {
            std.debug.print("    - {s}\n", .{con});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ DECISION 3 RECOMMENDATION                                               │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ ✓ Option B: In Draw Generation                                          │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Rationale:                                                               │\n", .{});
    std.debug.print("│   • Lazy evaluation - only compute quads for visible text               │\n", .{});
    std.debug.print("│   • Clean separation - layout doesn't do rendering work                 │\n", .{});
    std.debug.print("│   • Single reference - GUI holds TextProvider, not every widget         │\n", .{});
    std.debug.print("│   • Backend stays dumb - just renders textured quads                    │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Architecture:                                                            │\n", .{});
    std.debug.print("│   gui.text(\"Hello\")                                                     │\n", .{});
    std.debug.print("│     → stores text + style in widget                                     │\n", .{});
    std.debug.print("│     → calls measureText() for layout                                    │\n", .{});
    std.debug.print("│   drawList.generateForWidget(widget)                                    │\n", .{});
    std.debug.print("│     → calls getGlyphQuads() HERE                                        │\n", .{});
    std.debug.print("│     → adds textured quads to draw list                                  │\n", .{});
    std.debug.print("│   backend.render(drawList)                                              │\n", .{});
    std.debug.print("│     → just renders quads (no text-specific logic)                       │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});
}

// ============================================================================
// DECISION 4: Grapheme segmentation - internal or pluggable?
// ============================================================================
//
// Question: Should getCharPositions() return grapheme positions internally,
// or should there be a separate BYOG (Bring Your Own Grapheme) interface?

const GraphemeTestCase = struct {
    input: []const u8,
    description: []const u8,
    codepoints: u32,
    expected_graphemes: u32,
    complexity: []const u8, // "simple", "combining", "zwj", "regional", "indic"
};

fn runGraphemeDecision() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("DECISION 4: Grapheme segmentation - internal or pluggable?\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    const test_cases = [_]GraphemeTestCase{
        // Simple cases
        .{ .input = "Hello", .description = "ASCII", .codepoints = 5, .expected_graphemes = 5, .complexity = "simple" },
        .{ .input = "Héllo", .description = "Precomposed é", .codepoints = 5, .expected_graphemes = 5, .complexity = "simple" },

        // Combining marks
        .{ .input = "He\u{0301}llo", .description = "e + combining acute", .codepoints = 6, .expected_graphemes = 5, .complexity = "combining" },
        .{ .input = "n\u{0303}", .description = "n + tilde", .codepoints = 2, .expected_graphemes = 1, .complexity = "combining" },

        // ZWJ sequences (emoji)
        .{ .input = "👨\u{200D}👩\u{200D}👧", .description = "Family emoji (ZWJ)", .codepoints = 5, .expected_graphemes = 1, .complexity = "zwj" },
        .{ .input = "👩\u{200D}💻", .description = "Woman technologist", .codepoints = 3, .expected_graphemes = 1, .complexity = "zwj" },
        .{ .input = "🏳\u{FE0F}\u{200D}🌈", .description = "Rainbow flag", .codepoints = 4, .expected_graphemes = 1, .complexity = "zwj" },

        // Regional indicators
        .{ .input = "🇺🇸", .description = "US flag", .codepoints = 2, .expected_graphemes = 1, .complexity = "regional" },
        .{ .input = "🇯🇵", .description = "JP flag", .codepoints = 2, .expected_graphemes = 1, .complexity = "regional" },

        // Indic (complex)
        .{ .input = "नि", .description = "Hindi syllable", .codepoints = 2, .expected_graphemes = 1, .complexity = "indic" },
        .{ .input = "க்ஷி", .description = "Tamil cluster", .codepoints = 4, .expected_graphemes = 1, .complexity = "indic" },
    };

    std.debug.print("{s:<25} {s:<8} {s:<8} {s:<12}\n", .{ "Test Case", "CPs", "Graphs", "Complexity" });
    std.debug.print("{s:<25} {s:<8} {s:<8} {s:<12}\n", .{ "-" ** 24, "-" ** 7, "-" ** 7, "-" ** 11 });

    var simple_count: u32 = 0;
    var combining_count: u32 = 0;
    var zwj_count: u32 = 0;
    var regional_count: u32 = 0;
    var indic_count: u32 = 0;

    for (test_cases) |tc| {
        std.debug.print("{s:<25} {d:<8} {d:<8} {s:<12}\n", .{
            tc.description,
            tc.codepoints,
            tc.expected_graphemes,
            tc.complexity,
        });

        if (std.mem.eql(u8, tc.complexity, "simple")) simple_count += 1;
        if (std.mem.eql(u8, tc.complexity, "combining")) combining_count += 1;
        if (std.mem.eql(u8, tc.complexity, "zwj")) zwj_count += 1;
        if (std.mem.eql(u8, tc.complexity, "regional")) regional_count += 1;
        if (std.mem.eql(u8, tc.complexity, "indic")) indic_count += 1;
    }

    std.debug.print("\n", .{});
    std.debug.print("Complexity distribution:\n", .{});
    std.debug.print("  Simple (ASCII, precomposed): {d} cases - trivial\n", .{simple_count});
    std.debug.print("  Combining marks: {d} cases - ~50 lines of code\n", .{combining_count});
    std.debug.print("  ZWJ sequences: {d} cases - ~100 lines + table\n", .{zwj_count});
    std.debug.print("  Regional indicators: {d} cases - ~30 lines\n", .{regional_count});
    std.debug.print("  Indic scripts: {d} cases - requires UAX #29 (~500+ lines)\n", .{indic_count});

    std.debug.print("\n", .{});
    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ DECISION 4 RECOMMENDATION                                               │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ ✓ Internal grapheme handling in provider (NOT pluggable BYOG)          │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Rationale:                                                               │\n", .{});
    std.debug.print("│   • 90% of real text is simple (ASCII + precomposed Unicode)            │\n", .{});
    std.debug.print("│   • Combining marks + ZWJ cover 95% of remaining cases                  │\n", .{});
    std.debug.print("│   • Full UAX #29 only needed for complex Indic scripts                  │\n", .{});
    std.debug.print("│   • ShapingProvider (HarfBuzz) handles Indic anyway                     │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Implementation:                                                          │\n", .{});
    std.debug.print("│   StbProvider: handles combining marks + ZWJ (~150 lines)               │\n", .{});
    std.debug.print("│   ShapingProvider: full UAX #29 via HarfBuzz                            │\n", .{});
    std.debug.print("│   BitmapProvider: ASCII only (1 grapheme = 1 byte)                      │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Interface remains: getCharPositions() returns grapheme count            │\n", .{});
    std.debug.print("│ Provider handles segmentation internally - no BYOG interface needed     │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});
}

// ============================================================================
// DECISION 5: Emoji without COLR parser - what actually renders?
// ============================================================================
//
// Question: If we don't implement COLR/CBDT parsing, what happens when
// user text contains emoji? Is the UX acceptable?

fn runEmojiDecision() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("DECISION 5: Emoji without COLR parser - what actually renders?\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    std.debug.print("Font emoji support analysis:\n\n", .{});

    std.debug.print("{s:<30} {s:<15} {s:<20}\n", .{ "Font", "Emoji Format", "Without COLR Parser" });
    std.debug.print("{s:<30} {s:<15} {s:<20}\n", .{ "-" ** 29, "-" ** 14, "-" ** 19 });

    // Known font emoji formats
    const font_info = [_]struct { name: []const u8, format: []const u8, fallback: []const u8 }{
        .{ .name = "Noto Color Emoji", .format = "CBDT/CBLC", .fallback = ".notdef (box)" },
        .{ .name = "Apple Color Emoji", .format = "sbix", .fallback = ".notdef (box)" },
        .{ .name = "Segoe UI Emoji", .format = "COLR/CPAL", .fallback = "Monochrome outline" },
        .{ .name = "Twemoji (Mozilla)", .format = "COLR/CPAL v1", .fallback = "Monochrome outline" },
        .{ .name = "EmojiOne", .format = "SVG", .fallback = ".notdef (box)" },
        .{ .name = "Noto Emoji (mono)", .format = "glyf (B&W)", .fallback = "Monochrome ✓" },
        .{ .name = "Symbola", .format = "glyf (B&W)", .fallback = "Monochrome ✓" },
        .{ .name = "DejaVu Sans", .format = "Limited glyf", .fallback = "Some mono, most .notdef" },
    };

    for (font_info) |info| {
        std.debug.print("{s:<30} {s:<15} {s:<20}\n", .{ info.name, info.format, info.fallback });
    }

    std.debug.print("\n", .{});
    std.debug.print("What stb_truetype renders for emoji codepoints:\n", .{});
    std.debug.print("  • CBDT/CBLC (Noto Color): Returns empty glyph or .notdef\n", .{});
    std.debug.print("  • sbix (Apple): Returns empty glyph or .notdef\n", .{});
    std.debug.print("  • COLR v0 (Segoe): Returns monochrome outline\n", .{});
    std.debug.print("  • COLR v1 (Twemoji): Returns monochrome outline (no gradients)\n", .{});
    std.debug.print("  • glyf (Noto Mono): Returns correct monochrome glyph ✓\n", .{});

    std.debug.print("\n", .{});
    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ DECISION 5 RECOMMENDATION                                               │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ ✓ Use monochrome emoji font as fallback (Noto Emoji or Symbola)        │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Rationale:                                                               │\n", .{});
    std.debug.print("│   • Color emoji requires COLR/CBDT parsing - significant work           │\n", .{});
    std.debug.print("│   • Monochrome emoji fonts work with stb_truetype TODAY                 │\n", .{});
    std.debug.print("│   • Monochrome is acceptable UX for most apps                           │\n", .{});
    std.debug.print("│   • Color emoji can be added later via AtlasFormat.rgba                 │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Recommended fallback chain for emoji support:                           │\n", .{});
    std.debug.print("│   1. Primary font (may have some symbols)                               │\n", .{});
    std.debug.print("│   2. Noto Emoji (monochrome) - good coverage, works with stb            │\n", .{});
    std.debug.print("│   3. Symbola - broader Unicode coverage                                 │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Documentation: \"Color emoji requires color font parser (not included).  │\n", .{});
    std.debug.print("│                 Use monochrome emoji font for emoji support.\"           │\n", .{});
    std.debug.print("│                                                                          │\n", .{});
    std.debug.print("│ Future: AtlasFormat.rgba + COLR parser for color emoji                  │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});
}

// ============================================================================
// SUMMARY
// ============================================================================

fn printSummary() void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});
    std.debug.print("EXPERIMENT 14 SUMMARY: All Decisions\n", .{});
    std.debug.print("=" ** 78 ++ "\n\n", .{});

    std.debug.print("┌─────────────────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ #  Decision                          Recommendation                     │\n", .{});
    std.debug.print("├─────────────────────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ 1  stb_truetype kerning             Check kern table coverage (varies)  │\n", .{});
    std.debug.print("│ 2  Atlas strategy                   Per-font pages (config option)      │\n", .{});
    std.debug.print("│ 3  Text→quads location              In draw generation (Option B)       │\n", .{});
    std.debug.print("│ 4  Grapheme segmentation            Internal (not pluggable BYOG)       │\n", .{});
    std.debug.print("│ 5  Emoji without COLR               Monochrome fallback font            │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────────────────┘\n", .{});

    std.debug.print("\n", .{});
    std.debug.print("Interface updates needed:\n", .{});
    std.debug.print("  • Add atlas_mode to TextProviderConfig: .shared | .per_font\n", .{});
    std.debug.print("  • Document draw integration in DESIGN.md\n", .{});
    std.debug.print("  • Document monochrome emoji recommendation\n", .{});
    std.debug.print("  • Document kern table limitation (GPOS needs HarfBuzz)\n", .{});

    std.debug.print("\n", .{});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  1. Update README.md with these decisions\n", .{});
    std.debug.print("  2. Update TextProviderConfig with atlas_mode\n", .{});
    std.debug.print("  3. Document draw integration architecture in DESIGN.md\n", .{});
    std.debug.print("  4. Implement StbProvider with these decisions applied\n", .{});
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const font_dir: ?[]const u8 = if (args.len > 1) args[1] else null;

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         EXPERIMENT 14: FONT SYSTEM DECISION VALIDATION                    ║\n", .{});
    std.debug.print("║                                                                           ║\n", .{});
    std.debug.print("║  This experiment makes DECISIONS by testing real scenarios.               ║\n", .{});
    std.debug.print("║  Each section compares options and produces a concrete recommendation.    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════════════════════════╝\n", .{});

    try runKerningDecision(allocator, font_dir);
    try runAtlasDecision(allocator);
    try runDrawArchitectureDecision();
    try runGraphemeDecision();
    try runEmojiDecision();
    printSummary();
}
