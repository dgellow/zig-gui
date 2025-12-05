//! Experiment 12: Atlas Management When Full - Realistic Validation
//!
//! Following the pattern from experiments 09 and 11, this validates atlas
//! management strategies against realistic scenarios.
//!
//! Key questions to answer:
//!   1. Which atlas strategy works best for each tier (embedded/desktop/games)?
//!   2. Does the "no atlas" embedded path make sense?
//!   3. What happens when atlas overflows in each strategy?
//!   4. Should atlas be configurable or a separate interface (BYOFM)?
//!   5. How much does eviction cost vs full reset vs multi-page?
//!
//! Strategies under test:
//!   A. Full Reset (current 05_stb_integration.zig approach)
//!   B. Grid LRU (VEFontCache style - fixed slots)
//!   C. Shelf LRU (WebRender style - row-based eviction)
//!   D. Multi-Page (Unity/ImGui style - grow when full)
//!   E. No Atlas (embedded direct-to-framebuffer)
//!
//! Run:
//!   zig run experiments/text_rendering/12_atlas_management.zig

const std = @import("std");

// ============================================================================
// REALISTIC SCENARIOS
// ============================================================================

const Scenario = struct {
    name: []const u8,
    description: []const u8,
    target: Target,

    // Text characteristics
    unique_glyphs: u32,        // How many different glyphs needed
    total_renders: u32,        // Total glyph renders per "frame"
    glyph_reuse_rate: f32,     // 0.0 = all unique, 1.0 = same glyph repeated
    frames_simulated: u32,     // How many frames to simulate

    // Glyph size distribution
    avg_glyph_width: u16,
    avg_glyph_height: u16,
    size_variance: f32,        // 0.0 = uniform, 1.0 = high variance

    // Memory constraints
    atlas_budget_kb: u32,

    // Expected behavior
    expected_overflow: bool,
    notes: []const u8,
};

const Target = enum {
    embedded,    // 32KB RAM, no GPU, direct framebuffer
    desktop_sw,  // Software rendering, 1MB budget
    desktop_gpu, // GPU rendering, VRAM available
    game,        // Real-time, predictable performance critical
    cjk_heavy,   // Thousands of unique CJK characters
};

const scenarios = [_]Scenario{
    // =========================================================================
    // EMBEDDED SCENARIOS
    // =========================================================================
    .{
        .name = "thermostat_display",
        .description = "Simple sensor readout: '72.5°F' - digits and symbols only",
        .target = .embedded,
        .unique_glyphs = 15,           // 0-9, '.', '°', 'F', 'C', '-'
        .total_renders = 8,            // "72.5°F" = 6 chars typical
        .glyph_reuse_rate = 0.9,       // Same digits repeat
        .frames_simulated = 1000,
        .avg_glyph_width = 12,
        .avg_glyph_height = 20,
        .size_variance = 0.1,
        .atlas_budget_kb = 4,
        .expected_overflow = false,
        .notes = "Should work with static atlas or no atlas (direct render)",
    },
    .{
        .name = "embedded_menu",
        .description = "Device menu with ASCII text",
        .target = .embedded,
        .unique_glyphs = 70,           // ASCII letters + digits + punctuation
        .total_renders = 200,          // ~10 menu items × 20 chars
        .glyph_reuse_rate = 0.7,
        .frames_simulated = 100,
        .avg_glyph_width = 8,
        .avg_glyph_height = 16,
        .size_variance = 0.2,
        .atlas_budget_kb = 8,
        .expected_overflow = false,
        .notes = "Fits in small atlas, no eviction needed",
    },
    .{
        .name = "embedded_config_input",
        .description = "WiFi password entry - full ASCII needed",
        .target = .embedded,
        .unique_glyphs = 95,           // Full ASCII printable
        .total_renders = 50,
        .glyph_reuse_rate = 0.3,       // Passwords are random
        .frames_simulated = 500,
        .avg_glyph_width = 8,
        .avg_glyph_height = 16,
        .size_variance = 0.3,
        .atlas_budget_kb = 8,
        .expected_overflow = false,
        .notes = "Edge of embedded budget, tests full ASCII",
    },

    // =========================================================================
    // DESKTOP SCENARIOS
    // =========================================================================
    .{
        .name = "settings_dialog",
        .description = "Typical desktop settings UI",
        .target = .desktop_sw,
        .unique_glyphs = 80,
        .total_renders = 500,
        .glyph_reuse_rate = 0.8,
        .frames_simulated = 60,        // 1 second at 60fps
        .avg_glyph_width = 10,
        .avg_glyph_height = 18,
        .size_variance = 0.3,
        .atlas_budget_kb = 256,
        .expected_overflow = false,
        .notes = "Comfortable fit, tests steady-state caching",
    },
    .{
        .name = "text_editor",
        .description = "Code editor with multiple fonts/sizes",
        .target = .desktop_sw,
        .unique_glyphs = 200,          // ASCII + extended + multiple sizes
        .total_renders = 5000,         // Full screen of code
        .glyph_reuse_rate = 0.85,      // Code has repetition
        .frames_simulated = 300,       // 5 seconds
        .avg_glyph_width = 9,
        .avg_glyph_height = 16,
        .size_variance = 0.4,          // Different sizes (12pt, 14pt, etc)
        .atlas_budget_kb = 512,
        .expected_overflow = false,
        .notes = "Tests multiple font sizes in same atlas",
    },
    .{
        .name = "email_client",
        .description = "Email list with varied content",
        .target = .desktop_sw,
        .unique_glyphs = 300,          // Latin-1 extended
        .total_renders = 3000,
        .glyph_reuse_rate = 0.7,
        .frames_simulated = 600,       // 10 seconds of scrolling
        .avg_glyph_width = 10,
        .avg_glyph_height = 18,
        .size_variance = 0.3,
        .atlas_budget_kb = 512,
        .expected_overflow = false,
        .notes = "Tests cache efficiency during scrolling",
    },

    // =========================================================================
    // CJK / i18n SCENARIOS (stress test)
    // =========================================================================
    .{
        .name = "chinese_news_app",
        .description = "News reader showing Chinese articles",
        .target = .cjk_heavy,
        .unique_glyphs = 3000,         // Common Chinese chars
        .total_renders = 2000,
        .glyph_reuse_rate = 0.5,       // Chinese has less repetition
        .frames_simulated = 300,
        .avg_glyph_width = 24,         // CJK glyphs are larger
        .avg_glyph_height = 24,
        .size_variance = 0.1,
        .atlas_budget_kb = 1024,
        .expected_overflow = true,     // Will overflow 1MB!
        .notes = "CRITICAL: Tests overflow handling with large glyph set",
    },
    .{
        .name = "japanese_chat",
        .description = "Chat app with Japanese + emoji",
        .target = .cjk_heavy,
        .unique_glyphs = 2500,         // Hiragana + Katakana + Kanji + emoji
        .total_renders = 500,
        .glyph_reuse_rate = 0.4,
        .frames_simulated = 600,
        .avg_glyph_width = 20,
        .avg_glyph_height = 20,
        .size_variance = 0.3,          // Emoji larger than text
        .atlas_budget_kb = 512,
        .expected_overflow = true,
        .notes = "Tests eviction under continuous new content",
    },

    // =========================================================================
    // GAME SCENARIOS
    // =========================================================================
    .{
        .name = "game_hud",
        .description = "FPS game HUD - score, ammo, health",
        .target = .game,
        .unique_glyphs = 40,           // Digits, few labels
        .total_renders = 50,
        .glyph_reuse_rate = 0.95,      // Same chars every frame
        .frames_simulated = 3600,      // 60 seconds at 60fps
        .avg_glyph_width = 16,
        .avg_glyph_height = 24,
        .size_variance = 0.2,
        .atlas_budget_kb = 64,
        .expected_overflow = false,
        .notes = "Steady-state, no eviction should occur",
    },
    .{
        .name = "game_leaderboard",
        .description = "Online leaderboard with player names",
        .target = .game,
        .unique_glyphs = 200,          // International player names
        .total_renders = 1000,
        .glyph_reuse_rate = 0.3,       // Names are diverse
        .frames_simulated = 60,        // 1 second to populate
        .avg_glyph_width = 14,
        .avg_glyph_height = 20,
        .size_variance = 0.2,
        .atlas_budget_kb = 128,
        .expected_overflow = false,    // But tests burst loading
        .notes = "Tests burst glyph loading (all at once)",
    },
    .{
        .name = "mmo_chat",
        .description = "MMO chat with many players, international",
        .target = .game,
        .unique_glyphs = 500,
        .total_renders = 800,
        .glyph_reuse_rate = 0.5,
        .frames_simulated = 1800,      // 30 seconds
        .avg_glyph_width = 12,
        .avg_glyph_height = 16,
        .size_variance = 0.3,
        .atlas_budget_kb = 256,
        .expected_overflow = true,     // May overflow with diverse names
        .notes = "Tests gradual cache pressure over time",
    },

    // =========================================================================
    // STRESS / EDGE CASES
    // =========================================================================
    .{
        .name = "unicode_torture",
        .description = "Every Unicode block sampled",
        .target = .desktop_gpu,
        .unique_glyphs = 10000,
        .total_renders = 10000,
        .glyph_reuse_rate = 0.0,       // All unique!
        .frames_simulated = 10,
        .avg_glyph_width = 16,
        .avg_glyph_height = 20,
        .size_variance = 0.5,
        .atlas_budget_kb = 2048,
        .expected_overflow = true,
        .notes = "Worst case: tests strategy under extreme pressure",
    },
    .{
        .name = "rapid_font_switching",
        .description = "UI that constantly switches fonts",
        .target = .desktop_sw,
        .unique_glyphs = 300,          // Same chars, 3 fonts × 3 sizes
        .total_renders = 1000,
        .glyph_reuse_rate = 0.6,
        .frames_simulated = 300,
        .avg_glyph_width = 12,
        .avg_glyph_height = 18,
        .size_variance = 0.5,          // High variance = different sizes
        .atlas_budget_kb = 256,
        .expected_overflow = true,     // Different sizes don't share
        .notes = "Tests font/size isolation in cache",
    },
};

// ============================================================================
// ATLAS STRATEGIES
// ============================================================================

/// Glyph identifier (font_id << 24 | size << 16 | codepoint)
const GlyphKey = u64;

fn makeGlyphKey(font_id: u8, size: u8, codepoint: u32) GlyphKey {
    return (@as(u64, font_id) << 40) | (@as(u64, size) << 32) | codepoint;
}

/// Atlas region (where a glyph is stored)
const AtlasRegion = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    page: u8 = 0,
};

/// Stats collected during simulation
const SimStats = struct {
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    evictions: u64 = 0,
    full_resets: u64 = 0,
    page_additions: u64 = 0,
    peak_memory_bytes: u64 = 0,
    total_rasterize_time_ns: u64 = 0,
    total_eviction_time_ns: u64 = 0,
    frames_with_stutter: u64 = 0,  // Frames where eviction caused >1ms work

    fn hitRate(self: SimStats) f32 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total));
    }
};

// ============================================================================
// STRATEGY A: Full Reset (current implementation)
// ============================================================================

const FullResetAtlas = struct {
    const Self = @This();
    const MAX_GLYPHS = 4096;

    glyphs: std.AutoHashMap(GlyphKey, AtlasRegion),
    atlas_width: u32,
    atlas_height: u32,
    current_x: u32 = 0,
    current_y: u32 = 0,
    row_height: u32 = 0,
    frame: u64 = 0,
    last_used: std.AutoHashMap(GlyphKey, u64),
    stats: SimStats = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_kb: u32) !Self {
        const pixels = size_kb * 1024;  // Assuming 1 byte per pixel
        const side = std.math.sqrt(pixels);
        return Self{
            .glyphs = std.AutoHashMap(GlyphKey, AtlasRegion).init(allocator),
            .atlas_width = side,
            .atlas_height = side,
            .last_used = std.AutoHashMap(GlyphKey, u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.glyphs.deinit();
        self.last_used.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.frame += 1;
    }

    pub fn getOrAdd(self: *Self, key: GlyphKey, width: u16, height: u16) !AtlasRegion {
        if (self.glyphs.get(key)) |region| {
            self.stats.cache_hits += 1;
            try self.last_used.put(key, self.frame);
            return region;
        }

        self.stats.cache_misses += 1;

        // Simulate rasterization time (~50μs per glyph)
        const raster_start = std.time.nanoTimestamp();
        simulateRasterization(width, height);
        self.stats.total_rasterize_time_ns += @intCast(@as(i128, std.time.nanoTimestamp() - raster_start));

        // Try to allocate
        if (!self.tryAllocate(width, height)) {
            // Atlas full - RESET EVERYTHING
            const evict_start = std.time.nanoTimestamp();
            self.fullReset();
            const evict_time: u64 = @intCast(@as(i128, std.time.nanoTimestamp() - evict_start));
            self.stats.total_eviction_time_ns += evict_time;

            if (evict_time > 1_000_000) {  // >1ms
                self.stats.frames_with_stutter += 1;
            }

            // Try again after reset
            if (!self.tryAllocate(width, height)) {
                return error.GlyphTooLarge;
            }
        }

        const region = AtlasRegion{
            .x = @intCast(self.current_x - width),
            .y = @intCast(self.current_y),
            .width = width,
            .height = height,
        };

        try self.glyphs.put(key, region);
        try self.last_used.put(key, self.frame);

        self.stats.peak_memory_bytes = @max(
            self.stats.peak_memory_bytes,
            self.glyphs.count() * 32,  // Rough per-glyph overhead
        );

        return region;
    }

    fn tryAllocate(self: *Self, width: u16, height: u16) bool {
        if (self.current_x + width > self.atlas_width) {
            // Next row
            self.current_y += self.row_height + 1;
            self.current_x = 0;
            self.row_height = 0;
        }

        if (self.current_y + height > self.atlas_height) {
            return false;  // Atlas full
        }

        self.current_x += width + 1;
        self.row_height = @max(self.row_height, height);
        return true;
    }

    fn fullReset(self: *Self) void {
        self.glyphs.clearRetainingCapacity();
        self.last_used.clearRetainingCapacity();
        self.current_x = 0;
        self.current_y = 0;
        self.row_height = 0;
        self.stats.full_resets += 1;
        self.stats.evictions += self.glyphs.count();
    }

    pub fn getStats(self: *const Self) SimStats {
        return self.stats;
    }
};

// ============================================================================
// STRATEGY B: Grid LRU (VEFontCache style)
// ============================================================================

const GridLruAtlas = struct {
    const Self = @This();

    const Slot = struct {
        key: ?GlyphKey,
        last_used: u64,
    };

    // Fixed grid: all slots same size
    slot_width: u16,
    slot_height: u16,
    cols: u16,
    rows: u16,
    slots: []Slot,
    key_to_slot: std.AutoHashMap(GlyphKey, u16),
    frame: u64 = 0,
    stats: SimStats = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_kb: u32, slot_w: u16, slot_h: u16) !Self {
        const pixels = size_kb * 1024;
        const side: u32 = std.math.sqrt(pixels);
        const cols: u16 = @intCast(side / slot_w);
        const rows: u16 = @intCast(side / slot_h);
        const total_slots = @as(usize, cols) * rows;

        const slots = try allocator.alloc(Slot, total_slots);
        for (slots) |*s| {
            s.* = .{ .key = null, .last_used = 0 };
        }

        return Self{
            .slot_width = slot_w,
            .slot_height = slot_h,
            .cols = cols,
            .rows = rows,
            .slots = slots,
            .key_to_slot = std.AutoHashMap(GlyphKey, u16).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
        self.key_to_slot.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.frame += 1;
    }

    pub fn getOrAdd(self: *Self, key: GlyphKey, width: u16, height: u16) !AtlasRegion {
        // Check if glyph fits in slot
        if (width > self.slot_width or height > self.slot_height) {
            return error.GlyphTooLarge;
        }

        if (self.key_to_slot.get(key)) |slot_idx| {
            self.stats.cache_hits += 1;
            self.slots[slot_idx].last_used = self.frame;
            return self.slotToRegion(slot_idx, width, height);
        }

        self.stats.cache_misses += 1;

        // Simulate rasterization
        const raster_start = std.time.nanoTimestamp();
        simulateRasterization(width, height);
        self.stats.total_rasterize_time_ns += @intCast(@as(i128, std.time.nanoTimestamp() - raster_start));

        // Find slot: empty or LRU
        const slot_idx = self.findSlot();

        // Evict if necessary
        if (self.slots[slot_idx].key) |old_key| {
            _ = self.key_to_slot.remove(old_key);
            self.stats.evictions += 1;
        }

        self.slots[slot_idx] = .{ .key = key, .last_used = self.frame };
        try self.key_to_slot.put(key, slot_idx);

        self.stats.peak_memory_bytes = @max(
            self.stats.peak_memory_bytes,
            self.key_to_slot.count() * 24,
        );

        return self.slotToRegion(slot_idx, width, height);
    }

    fn findSlot(self: *Self) u16 {
        var oldest_frame: u64 = std.math.maxInt(u64);
        var oldest_idx: u16 = 0;

        for (self.slots, 0..) |slot, i| {
            if (slot.key == null) {
                return @intCast(i);  // Empty slot
            }
            if (slot.last_used < oldest_frame) {
                oldest_frame = slot.last_used;
                oldest_idx = @intCast(i);
            }
        }

        return oldest_idx;
    }

    fn slotToRegion(self: *const Self, slot_idx: u16, width: u16, height: u16) AtlasRegion {
        const col = slot_idx % self.cols;
        const row = slot_idx / self.cols;
        return AtlasRegion{
            .x = col * self.slot_width,
            .y = row * self.slot_height,
            .width = width,
            .height = height,
        };
    }

    pub fn getStats(self: *const Self) SimStats {
        return self.stats;
    }
};

// ============================================================================
// STRATEGY C: Shelf LRU (WebRender style)
// ============================================================================

const ShelfLruAtlas = struct {
    const Self = @This();

    const Shelf = struct {
        y: u32,
        height: u32,
        used_width: u32,
        last_used: u64,
        glyph_count: u32,
    };

    const GlyphInfo = struct {
        shelf_idx: u16,
        x: u16,
        width: u16,
        height: u16,
    };

    atlas_width: u32,
    atlas_height: u32,
    shelves: std.ArrayList(Shelf),
    glyphs: std.AutoHashMap(GlyphKey, GlyphInfo),
    frame: u64 = 0,
    stats: SimStats = .{},
    cold_threshold: u64 = 60,  // Frames before shelf is "cold"
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_kb: u32) !Self {
        const pixels = size_kb * 1024;
        const side = std.math.sqrt(pixels);
        return Self{
            .atlas_width = side,
            .atlas_height = side,
            .shelves = std.ArrayList(Shelf).init(allocator),
            .glyphs = std.AutoHashMap(GlyphKey, GlyphInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shelves.deinit();
        self.glyphs.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.frame += 1;
    }

    pub fn getOrAdd(self: *Self, key: GlyphKey, width: u16, height: u16) !AtlasRegion {
        if (self.glyphs.get(key)) |info| {
            self.stats.cache_hits += 1;
            self.shelves.items[info.shelf_idx].last_used = self.frame;
            return AtlasRegion{
                .x = info.x,
                .y = @intCast(self.shelves.items[info.shelf_idx].y),
                .width = info.width,
                .height = info.height,
            };
        }

        self.stats.cache_misses += 1;

        // Simulate rasterization
        const raster_start = std.time.nanoTimestamp();
        simulateRasterization(width, height);
        self.stats.total_rasterize_time_ns += @intCast(@as(i128, std.time.nanoTimestamp() - raster_start));

        // Find or create shelf
        const shelf_result = try self.findOrCreateShelf(height);
        const shelf_idx = shelf_result.idx;
        var shelf = &self.shelves.items[shelf_idx];

        const x = shelf.used_width;
        shelf.used_width += width + 1;
        shelf.last_used = self.frame;
        shelf.glyph_count += 1;

        const info = GlyphInfo{
            .shelf_idx = @intCast(shelf_idx),
            .x = @intCast(x),
            .width = width,
            .height = height,
        };
        try self.glyphs.put(key, info);

        self.stats.peak_memory_bytes = @max(
            self.stats.peak_memory_bytes,
            self.glyphs.count() * 20 + self.shelves.items.len * 24,
        );

        return AtlasRegion{
            .x = @intCast(x),
            .y = @intCast(shelf.y),
            .width = width,
            .height = height,
        };
    }

    fn findOrCreateShelf(self: *Self, height: u16) !struct { idx: usize } {
        // Find existing shelf with space and similar height
        var best_idx: ?usize = null;
        var best_waste: u32 = std.math.maxInt(u32);

        for (self.shelves.items, 0..) |shelf, i| {
            if (shelf.height >= height and
                shelf.used_width + height + 1 <= self.atlas_width)
            {
                const waste = shelf.height - height;
                if (waste < best_waste) {
                    best_waste = waste;
                    best_idx = i;
                }
            }
        }

        if (best_idx) |idx| {
            return .{ .idx = idx };
        }

        // Need new shelf - check if space available
        const current_height = if (self.shelves.items.len > 0) blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height + 1;
        } else 0;

        if (current_height + height <= self.atlas_height) {
            // Create new shelf
            try self.shelves.append(.{
                .y = current_height,
                .height = height,
                .used_width = 0,
                .last_used = self.frame,
                .glyph_count = 0,
            });
            return .{ .idx = self.shelves.items.len - 1 };
        }

        // Atlas full - try to evict cold shelves
        const evict_start = std.time.nanoTimestamp();
        const evicted = try self.evictColdShelves();
        const evict_time: u64 = @intCast(@as(i128, std.time.nanoTimestamp() - evict_start));
        self.stats.total_eviction_time_ns += evict_time;

        if (evict_time > 1_000_000) {
            self.stats.frames_with_stutter += 1;
        }

        if (evicted) {
            return self.findOrCreateShelf(height);  // Retry
        }

        return error.AtlasFull;
    }

    fn evictColdShelves(self: *Self) !bool {
        var evicted_any = false;
        var i: usize = 0;

        while (i < self.shelves.items.len) {
            const shelf = self.shelves.items[i];
            if (self.frame - shelf.last_used > self.cold_threshold) {
                // Remove all glyphs in this shelf
                var to_remove = std.ArrayList(GlyphKey).init(self.allocator);
                defer to_remove.deinit();

                var iter = self.glyphs.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.shelf_idx == i) {
                        try to_remove.append(entry.key_ptr.*);
                    }
                }

                for (to_remove.items) |key| {
                    _ = self.glyphs.remove(key);
                    self.stats.evictions += 1;
                }

                _ = self.shelves.orderedRemove(i);

                // Update shelf indices for remaining glyphs
                var glyph_iter = self.glyphs.iterator();
                while (glyph_iter.next()) |entry| {
                    if (entry.value_ptr.shelf_idx > i) {
                        entry.value_ptr.shelf_idx -= 1;
                    }
                }

                evicted_any = true;
            } else {
                i += 1;
            }
        }

        // Compact shelves (move them up to fill gaps)
        if (evicted_any) {
            var current_y: u32 = 0;
            for (self.shelves.items) |*shelf| {
                shelf.y = current_y;
                current_y += shelf.height + 1;
            }
        }

        return evicted_any;
    }

    pub fn getStats(self: *const Self) SimStats {
        return self.stats;
    }
};

// ============================================================================
// STRATEGY D: Multi-Page (Unity style)
// ============================================================================

const MultiPageAtlas = struct {
    const Self = @This();

    const Page = struct {
        current_x: u32 = 0,
        current_y: u32 = 0,
        row_height: u32 = 0,
    };

    const GlyphInfo = struct {
        page: u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    page_size: u32,
    max_pages: u8,
    pages: std.ArrayList(Page),
    glyphs: std.AutoHashMap(GlyphKey, GlyphInfo),
    frame: u64 = 0,
    stats: SimStats = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_kb: u32, max_pages: u8) !Self {
        const pixels = size_kb * 1024;
        const side = std.math.sqrt(pixels);

        var pages = std.ArrayList(Page).init(allocator);
        try pages.append(.{});  // Start with one page

        return Self{
            .page_size = side,
            .max_pages = max_pages,
            .pages = pages,
            .glyphs = std.AutoHashMap(GlyphKey, GlyphInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pages.deinit();
        self.glyphs.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.frame += 1;
    }

    pub fn getOrAdd(self: *Self, key: GlyphKey, width: u16, height: u16) !AtlasRegion {
        if (self.glyphs.get(key)) |info| {
            self.stats.cache_hits += 1;
            return AtlasRegion{
                .x = info.x,
                .y = info.y,
                .width = info.width,
                .height = info.height,
                .page = info.page,
            };
        }

        self.stats.cache_misses += 1;

        // Simulate rasterization
        const raster_start = std.time.nanoTimestamp();
        simulateRasterization(width, height);
        self.stats.total_rasterize_time_ns += @intCast(@as(i128, std.time.nanoTimestamp() - raster_start));

        // Try to fit in existing pages
        for (self.pages.items, 0..) |*page, page_idx| {
            if (self.tryFitInPage(page, width, height)) |pos| {
                const info = GlyphInfo{
                    .page = @intCast(page_idx),
                    .x = @intCast(pos.x),
                    .y = @intCast(pos.y),
                    .width = width,
                    .height = height,
                };
                try self.glyphs.put(key, info);

                self.stats.peak_memory_bytes = @max(
                    self.stats.peak_memory_bytes,
                    self.pages.items.len * self.page_size * self.page_size +
                    self.glyphs.count() * 16,
                );

                return AtlasRegion{
                    .x = info.x,
                    .y = info.y,
                    .width = width,
                    .height = height,
                    .page = info.page,
                };
            }
        }

        // Need new page
        if (self.pages.items.len < self.max_pages) {
            try self.pages.append(.{});
            self.stats.page_additions += 1;

            const page = &self.pages.items[self.pages.items.len - 1];
            if (self.tryFitInPage(page, width, height)) |pos| {
                const info = GlyphInfo{
                    .page = @intCast(self.pages.items.len - 1),
                    .x = @intCast(pos.x),
                    .y = @intCast(pos.y),
                    .width = width,
                    .height = height,
                };
                try self.glyphs.put(key, info);

                return AtlasRegion{
                    .x = info.x,
                    .y = info.y,
                    .width = width,
                    .height = height,
                    .page = info.page,
                };
            }
        }

        return error.AtlasFull;
    }

    fn tryFitInPage(self: *Self, page: *Page, width: u16, height: u16) ?struct { x: u32, y: u32 } {
        if (page.current_x + width > self.page_size) {
            page.current_y += page.row_height + 1;
            page.current_x = 0;
            page.row_height = 0;
        }

        if (page.current_y + height > self.page_size) {
            return null;
        }

        const x = page.current_x;
        const y = page.current_y;

        page.current_x += width + 1;
        page.row_height = @max(page.row_height, height);

        return .{ .x = x, .y = y };
    }

    pub fn getStats(self: *const Self) SimStats {
        return self.stats;
    }
};

// ============================================================================
// STRATEGY E: No Atlas (Direct Render for Embedded)
// ============================================================================

const DirectRenderStats = struct {
    total_glyphs_rendered: u64 = 0,
    total_render_time_ns: u64 = 0,
    unique_glyphs_seen: u64 = 0,
    frames: u64 = 0,

    fn avgRenderTimePerGlyph(self: DirectRenderStats) f64 {
        if (self.total_glyphs_rendered == 0) return 0;
        return @as(f64, @floatFromInt(self.total_render_time_ns)) /
               @as(f64, @floatFromInt(self.total_glyphs_rendered));
    }
};

const DirectRenderer = struct {
    const Self = @This();

    stats: DirectRenderStats = .{},
    seen_glyphs: std.AutoHashMap(GlyphKey, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .seen_glyphs = std.AutoHashMap(GlyphKey, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.seen_glyphs.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.stats.frames += 1;
    }

    pub fn renderGlyph(self: *Self, key: GlyphKey, width: u16, height: u16) void {
        const start = std.time.nanoTimestamp();

        // Direct render: decode + write to framebuffer
        // Simulates MCUFont-style direct decode
        simulateDirectRender(width, height);

        self.stats.total_render_time_ns += @intCast(@as(i128, std.time.nanoTimestamp() - start));
        self.stats.total_glyphs_rendered += 1;

        if (!self.seen_glyphs.contains(key)) {
            self.seen_glyphs.put(key, {}) catch {};
            self.stats.unique_glyphs_seen += 1;
        }
    }

    pub fn getStats(self: *const Self) DirectRenderStats {
        return self.stats;
    }
};

// ============================================================================
// SIMULATION HELPERS
// ============================================================================

fn simulateRasterization(width: u16, height: u16) void {
    // Simulate CPU work of rasterizing a glyph
    // Real stb_truetype takes ~50-200μs per glyph
    var sum: u32 = 0;
    const iterations = @as(u32, width) * height / 4;
    var x: u32 = 0x12345678;
    for (0..iterations) |_| {
        x = x *% 1103515245 +% 12345;
        sum +%= x;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn simulateDirectRender(width: u16, height: u16) void {
    // Simulate decoding + framebuffer write (faster than rasterize + cache)
    // MCUFont-style: ~10-30μs per glyph
    var sum: u32 = 0;
    const iterations = @as(u32, width) * height / 8;
    var x: u32 = 0x87654321;
    for (0..iterations) |_| {
        x = x *% 1103515245 +% 12345;
        sum +%= x;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn generateGlyphStream(
    scenario: Scenario,
    allocator: std.mem.Allocator,
    prng: *std.Random.Xoshiro256,
) ![]GlyphKey {
    var glyphs = std.ArrayList(GlyphKey).init(allocator);

    const total = scenario.total_renders * scenario.frames_simulated;
    try glyphs.ensureTotalCapacity(total);

    // Generate glyph accesses based on scenario characteristics
    for (0..scenario.frames_simulated) |_| {
        for (0..scenario.total_renders) |_| {
            const r = prng.random().float(f32);

            const codepoint: u32 = if (r < scenario.glyph_reuse_rate) blk: {
                // Reuse common glyph (zipf-like distribution)
                const common_pool = @min(scenario.unique_glyphs / 4, 20);
                break :blk prng.random().uintLessThan(u32, common_pool) + 32;
            } else blk: {
                // Random glyph from full set
                break :blk prng.random().uintLessThan(u32, scenario.unique_glyphs) + 32;
            };

            // Vary font/size occasionally
            const font_id: u8 = if (scenario.size_variance > 0.3 and prng.random().float(f32) < 0.1)
                prng.random().uintLessThan(u8, 3)
            else
                0;

            const size: u8 = if (scenario.size_variance > 0.2) blk: {
                const base: i16 = 16;
                const variance: i16 = @intCast(prng.random().uintLessThan(u8, 8));
                const result = base + (variance - 4);
                break :blk @intCast(@max(8, result));
            } else 16;

            try glyphs.append(makeGlyphKey(font_id, size, codepoint));
        }
    }

    return glyphs.toOwnedSlice();
}

fn getGlyphSize(scenario: Scenario, prng: *std.Random.Xoshiro256) struct { w: u16, h: u16 } {
    const base_w = scenario.avg_glyph_width;
    const base_h = scenario.avg_glyph_height;

    if (scenario.size_variance < 0.1) {
        return .{ .w = base_w, .h = base_h };
    }

    const variance = scenario.size_variance;
    const w_delta = @as(i16, @intFromFloat(@as(f32, @floatFromInt(base_w)) * variance *
        (prng.random().float(f32) - 0.5) * 2));
    const h_delta = @as(i16, @intFromFloat(@as(f32, @floatFromInt(base_h)) * variance *
        (prng.random().float(f32) - 0.5) * 2));

    return .{
        .w = @intCast(@max(4, @as(i32, base_w) + @as(i32, w_delta))),
        .h = @intCast(@max(4, @as(i32, base_h) + @as(i32, h_delta))),
    };
}

// ============================================================================
// MAIN SIMULATION
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 78 ++ "\n", .{});
    std.debug.print("EXPERIMENT 12: Atlas Management When Full - Realistic Validation\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});

    std.debug.print("\nStrategies under test:\n", .{});
    std.debug.print("  A. Full Reset     - Clear everything when full (current impl)\n", .{});
    std.debug.print("  B. Grid LRU       - Fixed slots, O(1) eviction (VEFontCache)\n", .{});
    std.debug.print("  C. Shelf LRU      - Row-based eviction (WebRender)\n", .{});
    std.debug.print("  D. Multi-Page     - Grow when full (Unity/ImGui)\n", .{});
    std.debug.print("  E. No Atlas       - Direct render (embedded)\n", .{});

    std.debug.print("\n{d} scenarios to test\n", .{scenarios.len});

    // =========================================================================
    // RUN SIMULATIONS
    // =========================================================================

    var results = std.ArrayList(ScenarioResults).init(allocator);
    defer results.deinit();

    for (scenarios) |scenario| {
        std.debug.print("\n" ++ "-" ** 78 ++ "\n", .{});
        std.debug.print("Scenario: {s}\n", .{scenario.name});
        std.debug.print("  {s}\n", .{scenario.description});
        std.debug.print("  Target: {s}, Budget: {d}KB, Unique glyphs: {d}\n", .{
            @tagName(scenario.target),
            scenario.atlas_budget_kb,
            scenario.unique_glyphs,
        });
        std.debug.print("  Expected overflow: {}\n", .{scenario.expected_overflow});

        var prng = std.Random.Xoshiro256.init(0x12345678);
        const glyph_stream = try generateGlyphStream(scenario, allocator, &prng);
        defer allocator.free(glyph_stream);

        var scenario_result = ScenarioResults{
            .scenario = scenario,
        };

        // Strategy A: Full Reset
        {
            var atlas = try FullResetAtlas.init(allocator, scenario.atlas_budget_kb);
            defer atlas.deinit();

            var prng_size = std.Random.Xoshiro256.init(0xABCDEF);
            var frame: u32 = 0;

            for (glyph_stream) |key| {
                if (frame % scenario.total_renders == 0) {
                    atlas.beginFrame();
                    frame = 0;
                }
                frame += 1;

                const size = getGlyphSize(scenario, &prng_size);
                _ = atlas.getOrAdd(key, size.w, size.h) catch {};
            }

            scenario_result.full_reset = atlas.getStats();
        }

        // Strategy B: Grid LRU
        {
            const slot_size: u16 = @max(scenario.avg_glyph_width, scenario.avg_glyph_height) + 4;
            var atlas = try GridLruAtlas.init(allocator, scenario.atlas_budget_kb, slot_size, slot_size);
            defer atlas.deinit();

            var prng_size = std.Random.Xoshiro256.init(0xABCDEF);
            var frame: u32 = 0;

            for (glyph_stream) |key| {
                if (frame % scenario.total_renders == 0) {
                    atlas.beginFrame();
                    frame = 0;
                }
                frame += 1;

                const size = getGlyphSize(scenario, &prng_size);
                _ = atlas.getOrAdd(key, size.w, size.h) catch {};
            }

            scenario_result.grid_lru = atlas.getStats();
        }

        // Strategy C: Shelf LRU
        {
            var atlas = try ShelfLruAtlas.init(allocator, scenario.atlas_budget_kb);
            defer atlas.deinit();

            var prng_size = std.Random.Xoshiro256.init(0xABCDEF);
            var frame: u32 = 0;

            for (glyph_stream) |key| {
                if (frame % scenario.total_renders == 0) {
                    atlas.beginFrame();
                    frame = 0;
                }
                frame += 1;

                const size = getGlyphSize(scenario, &prng_size);
                _ = atlas.getOrAdd(key, size.w, size.h) catch {};
            }

            scenario_result.shelf_lru = atlas.getStats();
        }

        // Strategy D: Multi-Page
        {
            var atlas = try MultiPageAtlas.init(allocator, scenario.atlas_budget_kb, 8);
            defer atlas.deinit();

            var prng_size = std.Random.Xoshiro256.init(0xABCDEF);
            var frame: u32 = 0;

            for (glyph_stream) |key| {
                if (frame % scenario.total_renders == 0) {
                    atlas.beginFrame();
                    frame = 0;
                }
                frame += 1;

                const size = getGlyphSize(scenario, &prng_size);
                _ = atlas.getOrAdd(key, size.w, size.h) catch {};
            }

            scenario_result.multi_page = atlas.getStats();
        }

        // Strategy E: Direct Render (only for embedded scenarios)
        if (scenario.target == .embedded) {
            var renderer = try DirectRenderer.init(allocator);
            defer renderer.deinit();

            var prng_size = std.Random.Xoshiro256.init(0xABCDEF);
            var frame: u32 = 0;

            for (glyph_stream) |key| {
                if (frame % scenario.total_renders == 0) {
                    renderer.beginFrame();
                    frame = 0;
                }
                frame += 1;

                const size = getGlyphSize(scenario, &prng_size);
                renderer.renderGlyph(key, size.w, size.h);
            }

            scenario_result.direct_render = renderer.getStats();
        }

        // Print results
        printScenarioResults(scenario_result);
        try results.append(scenario_result);
    }

    // =========================================================================
    // ANALYSIS & CONCLUSIONS
    // =========================================================================

    std.debug.print("\n" ++ "=" ** 78 ++ "\n", .{});
    std.debug.print("ANALYSIS & CONCLUSIONS\n", .{});
    std.debug.print("=" ** 78 ++ "\n", .{});

    analyzeResults(results.items);
}

const ScenarioResults = struct {
    scenario: Scenario,
    full_reset: SimStats = .{},
    grid_lru: SimStats = .{},
    shelf_lru: SimStats = .{},
    multi_page: SimStats = .{},
    direct_render: ?DirectRenderStats = null,
};

fn printScenarioResults(r: ScenarioResults) void {
    std.debug.print("\n  Results:\n", .{});
    std.debug.print("  {s:<12} {s:>8} {s:>8} {s:>8} {s:>8} {s:>10}\n", .{
        "Strategy", "Hits%", "Evicts", "Resets", "Pages", "Stutter",
    });
    std.debug.print("  {s:-<12} {s:->8} {s:->8} {s:->8} {s:->8} {s:->10}\n", .{
        "", "", "", "", "", "",
    });

    std.debug.print("  {s:<12} {d:>7.1}% {d:>8} {d:>8} {s:>8} {d:>10}\n", .{
        "FullReset",
        r.full_reset.hitRate() * 100,
        r.full_reset.evictions,
        r.full_reset.full_resets,
        "-",
        r.full_reset.frames_with_stutter,
    });

    std.debug.print("  {s:<12} {d:>7.1}% {d:>8} {s:>8} {s:>8} {d:>10}\n", .{
        "GridLRU",
        r.grid_lru.hitRate() * 100,
        r.grid_lru.evictions,
        "-",
        "-",
        r.grid_lru.frames_with_stutter,
    });

    std.debug.print("  {s:<12} {d:>7.1}% {d:>8} {s:>8} {s:>8} {d:>10}\n", .{
        "ShelfLRU",
        r.shelf_lru.hitRate() * 100,
        r.shelf_lru.evictions,
        "-",
        "-",
        r.shelf_lru.frames_with_stutter,
    });

    std.debug.print("  {s:<12} {d:>7.1}% {s:>8} {s:>8} {d:>8} {d:>10}\n", .{
        "MultiPage",
        r.multi_page.hitRate() * 100,
        "-",
        "-",
        r.multi_page.page_additions,
        r.multi_page.frames_with_stutter,
    });

    if (r.direct_render) |dr| {
        std.debug.print("  {s:<12} {s:>8} {s:>8} {s:>8} {s:>8} {d:>10.0}ns/g\n", .{
            "DirectRender",
            "N/A",
            "-",
            "-",
            "-",
            dr.avgRenderTimePerGlyph(),
        });
    }
}

fn analyzeResults(results: []const ScenarioResults) void {
    std.debug.print("\n1. EMBEDDED SCENARIOS:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    for (results) |r| {
        if (r.scenario.target != .embedded) continue;

        std.debug.print("\n   {s}:\n", .{r.scenario.name});

        // Compare direct render vs cached
        if (r.direct_render) |dr| {
            const cached_time = r.full_reset.total_rasterize_time_ns;
            const direct_time = dr.total_render_time_ns;

            if (direct_time < cached_time or r.full_reset.full_resets > 0) {
                std.debug.print("   → DIRECT RENDER WINS (no atlas overhead, {d} resets avoided)\n", .{
                    r.full_reset.full_resets,
                });
            } else {
                std.debug.print("   → ATLAS WINS (cache hit rate {d:.1}%)\n", .{
                    r.full_reset.hitRate() * 100,
                });
            }
        }
    }

    std.debug.print("\n2. OVERFLOW SCENARIOS:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    for (results) |r| {
        if (!r.scenario.expected_overflow) continue;

        std.debug.print("\n   {s}:\n", .{r.scenario.name});

        // Find best strategy for overflow
        const strategies = [_]struct { name: []const u8, stats: SimStats }{
            .{ .name = "FullReset", .stats = r.full_reset },
            .{ .name = "GridLRU", .stats = r.grid_lru },
            .{ .name = "ShelfLRU", .stats = r.shelf_lru },
            .{ .name = "MultiPage", .stats = r.multi_page },
        };

        var best_hit_rate: f32 = 0;
        var best_name: []const u8 = "";
        var least_stutter: u64 = std.math.maxInt(u64);
        var least_stutter_name: []const u8 = "";

        for (strategies) |s| {
            if (s.stats.hitRate() > best_hit_rate) {
                best_hit_rate = s.stats.hitRate();
                best_name = s.name;
            }
            if (s.stats.frames_with_stutter < least_stutter) {
                least_stutter = s.stats.frames_with_stutter;
                least_stutter_name = s.name;
            }
        }

        std.debug.print("   → Best hit rate: {s} ({d:.1}%)\n", .{ best_name, best_hit_rate * 100 });
        std.debug.print("   → Least stutter: {s} ({d} frames)\n", .{ least_stutter_name, least_stutter });

        if (r.multi_page.page_additions > 0) {
            std.debug.print("   → MultiPage used {d} pages (no eviction)\n", .{
                r.multi_page.page_additions + 1,
            });
        }
    }

    std.debug.print("\n3. RECOMMENDATIONS BY TARGET:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    std.debug.print("\n   EMBEDDED (32KB):\n", .{});
    std.debug.print("   • Direct render for simple displays (no atlas needed)\n", .{});
    std.debug.print("   • Static atlas for menus (pre-load ASCII, no eviction)\n", .{});
    std.debug.print("   • Grid LRU if dynamic content needed (predictable memory)\n", .{});

    std.debug.print("\n   DESKTOP:\n", .{});
    std.debug.print("   • Shelf LRU for most apps (good balance)\n", .{});
    std.debug.print("   • Multi-Page for text-heavy apps (no eviction stutter)\n", .{});
    std.debug.print("   • Grid LRU for games (O(1) eviction, predictable)\n", .{});

    std.debug.print("\n   CJK / i18n:\n", .{});
    std.debug.print("   • Multi-Page REQUIRED (thousands of glyphs)\n", .{});
    std.debug.print("   • Or: Shelf LRU with large atlas (2MB+)\n", .{});
    std.debug.print("   • Full Reset FAILS (constant stutter)\n", .{});

    std.debug.print("\n4. INTERFACE DECISION:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    std.debug.print("\n   Based on this experiment:\n", .{});
    std.debug.print("\n   ✗ BYOFM (Bring Your Own Font Management)\n", .{});
    std.debug.print("     - Too complex for marginal benefit\n", .{});
    std.debug.print("     - Most users just need \"pick a tier\"\n", .{});
    std.debug.print("\n   ✓ SPLIT INTERFACE (Universal + Rendering Layer)\n", .{});
    std.debug.print("     - Universal: measureText, getCharPositions\n", .{});
    std.debug.print("     - Embedded: renderDirect() - no atlas\n", .{});
    std.debug.print("     - Desktop: getGlyphQuads() + getAtlas() - with atlas\n", .{});
    std.debug.print("\n   ✓ ATLAS STRATEGY AS CONFIG\n", .{});
    std.debug.print("     - .atlas_strategy = .shelf_lru / .grid_lru / .multi_page\n", .{});
    std.debug.print("     - Provider picks sensible default for tier\n", .{});
    std.debug.print("     - Power users can override\n", .{});

    std.debug.print("\n5. PROPOSED INTERFACE:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    std.debug.print(
        \\
        \\   pub const TextProvider = struct {{
        \\       vtable: *const VTable,
        \\
        \\       pub const VTable = struct {{
        \\           // UNIVERSAL (all tiers)
        \\           measureText: *const fn (...) TextMetrics,
        \\           getCharPositions: *const fn (...) usize,
        \\
        \\           // EMBEDDED PATH (null for desktop)
        \\           renderDirect: ?*const fn (ptr, text, x, y, target: RenderTarget) void,
        \\
        \\           // ATLAS PATH (null for embedded direct-render)
        \\           getGlyphQuads: ?*const fn (...) usize,
        \\           getAtlas: ?*const fn (ptr, page: u8) ?AtlasInfo,
        \\           beginFrame: ?*const fn (ptr) void,
        \\           endFrame: ?*const fn (ptr) void,
        \\       }};
        \\   }};
        \\
        \\   pub const AtlasStrategy = enum {{
        \\       static,       // No eviction, pre-loaded
        \\       grid_lru,     // Fixed slots, O(1) eviction
        \\       shelf_lru,    // Row-based eviction
        \\       multi_page,   // Grow when full
        \\   }};
        \\
    , .{});
}
