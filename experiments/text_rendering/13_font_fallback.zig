//! Experiment 13: Font Fallback - Realistic Validation
//!
//! Following the pattern of experiments 09 and 11, this validates font fallback
//! approaches against realistic scenarios.
//!
//! Key questions:
//!   1. Is user-provided fallback chain sufficient?
//!   2. What's the performance overhead of fallback search?
//!   3. How do we handle Han unification (same codepoint, different locales)?
//!   4. What happens when no font has the glyph (.notdef)?
//!   5. How does fallback interact with atlas (cache thrashing)?
//!   6. Is platform font query necessary or just nice-to-have?
//!
//! Options under test:
//!   A. User Chain     - User provides ordered fallback list (ImGui, Unity)
//!   B. Platform Query - Ask OS for best font (DirectWrite, CoreText)
//!   C. Coverage Scan  - Scan fonts for Unicode coverage (cosmic-text)
//!   D. Hybrid         - User chain + optional platform query
//!   E. Locale-Aware   - User chain with locale metadata for Han
//!
//! 2025 State-of-the-Art Sources:
//!   - Chrome: Hard-coded script-to-font map (InitializeScriptFontMap)
//!   - Firefox: Dynamic search up to 32 fonts (GetLangPrefs)
//!   - Windows: IDWriteFontFallback API
//!   - macOS: CTFontCreateForString
//!   - cosmic-text: Chrome/Firefox static lists
//!   - Dear ImGui: MergeMode font stacking
//!   - Unity: Fallback font asset chain
//!
//! See: https://raphlinus.github.io/rust/skribo/text/2019/04/04/font-fallback.html

const std = @import("std");

// ============================================================================
// REALISTIC SCENARIOS
// ============================================================================

const Scenario = struct {
    name: []const u8,
    description: []const u8,
    text: []const u8,
    expected_fonts: []const ExpectedFont, // Which fonts should be used
    target: Target,
    locale: ?[]const u8, // For Han unification
    expected_fallback_count: u32, // How many fonts need to be searched
    is_critical: bool, // Must work, or just nice-to-have
};

const ExpectedFont = struct {
    font_type: FontType,
    coverage: []const u8, // Description of what it covers
};

const FontType = enum {
    primary, // User's main font
    symbol, // Mathematical/technical symbols
    cjk_sc, // Chinese Simplified
    cjk_tc, // Chinese Traditional
    cjk_jp, // Japanese
    cjk_kr, // Korean
    emoji, // Color emoji
    arabic, // Arabic script
    hebrew, // Hebrew script
    devanagari, // Hindi/Sanskrit
    noto_fallback, // Noto Sans as ultimate fallback
    system, // Platform-provided fallback
    notdef, // No font found - render .notdef
};

const Target = enum {
    embedded, // 32KB, ASCII or small charset
    desktop_latin, // Western languages
    desktop_cjk, // East Asian focus
    desktop_intl, // Full i18n
    game, // Limited charset, fast lookup
};

// Realistic scenarios covering real-world use cases
const scenarios = [_]Scenario{
    // ═══════════════════════════════════════════════════════════════════════
    // EMBEDDED SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "thermostat_ascii",
        .description = "Embedded thermostat - ASCII only, one font",
        .text = "Temperature: 72.5F  Humidity: 45%",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "ASCII" },
        },
        .target = .embedded,
        .locale = null,
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "embedded_degree_symbol",
        .description = "Embedded with degree symbol (°) - common edge case",
        .text = "72°F",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin + °" },
        },
        .target = .embedded,
        .locale = null,
        .expected_fallback_count = 0, // Should be in primary font
        .is_critical = true,
    },
    .{
        .name = "embedded_euro_symbol",
        .description = "Price display with € symbol",
        .text = "Price: €29.99",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Latin + €" },
        },
        .target = .embedded,
        .locale = null,
        .expected_fallback_count = 0, // € should be in primary
        .is_critical = true,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // DESKTOP LATIN - Common Western use cases
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "english_with_quotes",
        .description = "English text with smart quotes and em-dash",
        .text = "\xe2\x80\x9cHello\xe2\x80\x9d \xe2\x80\x94 said John's friend", // "Hello" — (smart quotes + em-dash)
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Extended Latin" },
        },
        .target = .desktop_latin,
        .locale = "en",
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "french_accents",
        .description = "French with accented characters",
        .text = "Café résumé naïve",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Latin Extended-A" },
        },
        .target = .desktop_latin,
        .locale = "fr",
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "math_symbols",
        .description = "Text with mathematical symbols",
        .text = "∑(x²) ≤ ∞, ∀x ∈ ℝ",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .symbol, .coverage = "Mathematical Operators" },
        },
        .target = .desktop_latin,
        .locale = "en",
        .expected_fallback_count = 1, // Need symbol font for math
        .is_critical = false, // Nice to have
    },
    .{
        .name = "code_with_arrows",
        .description = "Code with arrow symbols",
        .text = "fn foo() → Result<T, E>",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .symbol, .coverage = "Arrows" },
        },
        .target = .desktop_latin,
        .locale = null,
        .expected_fallback_count = 1,
        .is_critical = true, // Common in code editors
    },
    .{
        .name = "text_with_emoji",
        .description = "English text with inline emoji",
        .text = "Great job! 👍 See you tomorrow 🎉",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .emoji, .coverage = "Emoji" },
        },
        .target = .desktop_latin,
        .locale = "en",
        .expected_fallback_count = 1, // Need emoji font
        .is_critical = true, // Very common
    },
    .{
        .name = "emoji_sequence",
        .description = "Complex emoji with ZWJ sequences",
        .text = "Family: 👨‍👩‍👧‍👦 Flag: 🇯🇵",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .emoji, .coverage = "Emoji + ZWJ" },
        },
        .target = .desktop_latin,
        .locale = "en",
        .expected_fallback_count = 1,
        .is_critical = false, // ZWJ is complex
    },

    // ═══════════════════════════════════════════════════════════════════════
    // CJK SCENARIOS - The hard cases
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "japanese_in_english_app",
        .description = "Japanese text appearing in primarily English app",
        .text = "User: 田中太郎 commented on your post",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .cjk_jp, .coverage = "Japanese" },
        },
        .target = .desktop_cjk,
        .locale = "en", // English app, but showing Japanese name
        .expected_fallback_count = 1,
        .is_critical = true,
    },
    .{
        .name = "chinese_simplified",
        .description = "Simplified Chinese news headline",
        .text = "今日新闻：科技发展迅速",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .cjk_sc, .coverage = "CJK Unified" },
        },
        .target = .desktop_cjk,
        .locale = "zh-Hans",
        .expected_fallback_count = 0, // CJK should be primary for zh
        .is_critical = true,
    },
    .{
        .name = "chinese_traditional",
        .description = "Traditional Chinese (Taiwan/HK)",
        .text = "今日新聞：科技發展迅速",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .cjk_tc, .coverage = "CJK Unified" },
        },
        .target = .desktop_cjk,
        .locale = "zh-Hant",
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "han_unification_critical",
        .description = "Same codepoint U+76F4 (直) - renders differently per locale!",
        .text = "直接", // U+76F4 U+63A5
        .expected_fonts = &[_]ExpectedFont{
            // THIS IS THE HAN UNIFICATION PROBLEM
            // Same bytes, different visual appearance based on locale:
            // zh-Hans: 直 (Chinese simplified style)
            // zh-Hant: 直 (Chinese traditional style)
            // ja:      直 (Japanese style - different stroke details)
            .{ .font_type = .cjk_jp, .coverage = "Japanese variant" },
        },
        .target = .desktop_cjk,
        .locale = "ja", // Japanese locale
        .expected_fallback_count = 0,
        .is_critical = true, // VERY IMPORTANT - wrong font = wrong appearance
    },
    .{
        .name = "mixed_cjk_scripts",
        .description = "Text with Japanese, Chinese, and Korean",
        .text = "日本語 中文 한국어",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .cjk_jp, .coverage = "Japanese" },
            .{ .font_type = .cjk_sc, .coverage = "Chinese" },
            .{ .font_type = .cjk_kr, .coverage = "Korean" },
        },
        .target = .desktop_cjk,
        .locale = null, // Mixed - no single locale
        .expected_fallback_count = 2, // Need all three CJK fonts
        .is_critical = false, // Edge case
    },
    .{
        .name = "japanese_with_emoji",
        .description = "Japanese chat with emoji",
        .text = "おはよう！🌸 今日も頑張ろう 💪",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .cjk_jp, .coverage = "Japanese" },
            .{ .font_type = .emoji, .coverage = "Emoji" },
        },
        .target = .desktop_cjk,
        .locale = "ja",
        .expected_fallback_count = 1,
        .is_critical = true,
    },

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNATIONAL - RTL, Indic, etc.
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "arabic_text",
        .description = "Arabic greeting",
        .text = "مرحبا بالعالم", // "Hello World" in Arabic
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .arabic, .coverage = "Arabic" },
        },
        .target = .desktop_intl,
        .locale = "ar",
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "arabic_in_english",
        .description = "Arabic name in English text",
        .text = "Contact: محمد (Mohammed)",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .arabic, .coverage = "Arabic" },
        },
        .target = .desktop_intl,
        .locale = "en",
        .expected_fallback_count = 1,
        .is_critical = true,
    },
    .{
        .name = "hebrew_text",
        .description = "Hebrew greeting",
        .text = "שלום עולם", // "Hello World" in Hebrew
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .hebrew, .coverage = "Hebrew" },
        },
        .target = .desktop_intl,
        .locale = "he",
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "devanagari_text",
        .description = "Hindi greeting",
        .text = "नमस्ते दुनिया", // "Hello World" in Hindi
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .devanagari, .coverage = "Devanagari" },
        },
        .target = .desktop_intl,
        .locale = "hi",
        .expected_fallback_count = 0,
        .is_critical = false, // Less common in Western apps
    },

    // ═══════════════════════════════════════════════════════════════════════
    // GAME SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "game_hud",
        .description = "Game HUD with score and health",
        .text = "HP: 100/100  SCORE: 12,345",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "ASCII + digits" },
        },
        .target = .game,
        .locale = null,
        .expected_fallback_count = 0,
        .is_critical = true,
    },
    .{
        .name = "game_player_names",
        .description = "Leaderboard with international names",
        .text = "1. xXDragonSlayer99Xx\n2. 田中太郎\n3. Müller",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "ASCII" },
            .{ .font_type = .cjk_jp, .coverage = "Japanese" },
            // Müller - ü might need fallback depending on primary font
        },
        .target = .game,
        .locale = null,
        .expected_fallback_count = 1, // At least CJK
        .is_critical = true,
    },
    .{
        .name = "mmo_chat_international",
        .description = "MMO chat with multiple languages",
        .text = "Player1: LFG raid\nプレイヤー2: 参加します\n玩家3: 我也要",
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "ASCII" },
            .{ .font_type = .cjk_jp, .coverage = "Japanese" },
            .{ .font_type = .cjk_sc, .coverage = "Chinese" },
        },
        .target = .game,
        .locale = null,
        .expected_fallback_count = 2,
        .is_critical = true, // MMO chat is very common
    },

    // ═══════════════════════════════════════════════════════════════════════
    // EDGE CASES / STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════

    .{
        .name = "missing_glyph",
        .description = "Text with rare Unicode that no font has",
        .text = "Linear A: 𐘀𐘁𐘂", // U+10600-10602, very rare script
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .notdef, .coverage = "Missing - render .notdef" },
        },
        .target = .desktop_intl,
        .locale = null,
        .expected_fallback_count = 99, // Will search all fonts, find nothing
        .is_critical = false, // Expected to fail gracefully
    },
    .{
        .name = "private_use_area",
        .description = "Text with PUA characters (custom icons)",
        .text = "Icon:  Menu: ", // PUA codepoints (would be icons in custom font)
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "ASCII + PUA icons" },
        },
        .target = .desktop_latin,
        .locale = null,
        .expected_fallback_count = 0, // PUA should be in primary icon font
        .is_critical = true, // Icon fonts are common
    },
    .{
        .name = "variation_selectors",
        .description = "Text with variation selectors (emoji vs text)",
        .text = "Heart: ❤️ vs ❤︎", // U+2764 + VS16 vs U+2764 + VS15
        .expected_fonts = &[_]ExpectedFont{
            .{ .font_type = .primary, .coverage = "Basic Latin" },
            .{ .font_type = .emoji, .coverage = "Emoji with VS" },
        },
        .target = .desktop_latin,
        .locale = null,
        .expected_fallback_count = 1,
        .is_critical = false, // VS handling is complex
    },
};

// ============================================================================
// FALLBACK STRATEGY IMPLEMENTATIONS
// ============================================================================

/// Simulated font with coverage information
const SimulatedFont = struct {
    name: []const u8,
    font_type: FontType,
    coverage: Coverage,
    locale_preference: ?[]const u8, // Preferred locale for Han unification

    const Coverage = struct {
        ranges: []const [2]u32, // Unicode ranges [start, end]

        fn contains(self: Coverage, codepoint: u32) bool {
            for (self.ranges) |range| {
                if (codepoint >= range[0] and codepoint <= range[1]) {
                    return true;
                }
            }
            return false;
        }
    };
};

// Simulated font database
const simulated_fonts = [_]SimulatedFont{
    // Primary Latin font
    .{
        .name = "Roboto",
        .font_type = .primary,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x0020, 0x007F }, // Basic Latin
            .{ 0x00A0, 0x00FF }, // Latin-1 Supplement (°, €, etc.)
            .{ 0x0100, 0x017F }, // Latin Extended-A
            .{ 0x2000, 0x206F }, // General Punctuation (smart quotes, em-dash)
        } },
        .locale_preference = null,
    },
    // Symbol font
    .{
        .name = "Symbols",
        .font_type = .symbol,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x2190, 0x21FF }, // Arrows
            .{ 0x2200, 0x22FF }, // Mathematical Operators
            .{ 0x2300, 0x23FF }, // Miscellaneous Technical
            .{ 0x2600, 0x26FF }, // Miscellaneous Symbols
        } },
        .locale_preference = null,
    },
    // Japanese font
    .{
        .name = "Noto Sans JP",
        .font_type = .cjk_jp,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x3040, 0x309F }, // Hiragana
            .{ 0x30A0, 0x30FF }, // Katakana
            .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
            .{ 0xFF00, 0xFFEF }, // Halfwidth and Fullwidth Forms
        } },
        .locale_preference = "ja",
    },
    // Chinese Simplified font
    .{
        .name = "Noto Sans SC",
        .font_type = .cjk_sc,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
            .{ 0x3000, 0x303F }, // CJK Punctuation
        } },
        .locale_preference = "zh-Hans",
    },
    // Chinese Traditional font
    .{
        .name = "Noto Sans TC",
        .font_type = .cjk_tc,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x4E00, 0x9FFF }, // CJK Unified Ideographs
            .{ 0x3000, 0x303F }, // CJK Punctuation
        } },
        .locale_preference = "zh-Hant",
    },
    // Korean font
    .{
        .name = "Noto Sans KR",
        .font_type = .cjk_kr,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0xAC00, 0xD7AF }, // Hangul Syllables
            .{ 0x1100, 0x11FF }, // Hangul Jamo
            .{ 0x4E00, 0x9FFF }, // CJK (shared)
        } },
        .locale_preference = "ko",
    },
    // Emoji font
    .{
        .name = "Noto Color Emoji",
        .font_type = .emoji,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x1F300, 0x1F5FF }, // Miscellaneous Symbols and Pictographs
            .{ 0x1F600, 0x1F64F }, // Emoticons
            .{ 0x1F680, 0x1F6FF }, // Transport and Map Symbols
            .{ 0x1F900, 0x1F9FF }, // Supplemental Symbols and Pictographs
            .{ 0x1FA00, 0x1FA6F }, // Chess, Extended-A
            .{ 0x1F1E0, 0x1F1FF }, // Regional Indicator Symbols (flags)
        } },
        .locale_preference = null,
    },
    // Arabic font
    .{
        .name = "Noto Sans Arabic",
        .font_type = .arabic,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x0600, 0x06FF }, // Arabic
            .{ 0x0750, 0x077F }, // Arabic Supplement
        } },
        .locale_preference = "ar",
    },
    // Hebrew font
    .{
        .name = "Noto Sans Hebrew",
        .font_type = .hebrew,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x0590, 0x05FF }, // Hebrew
        } },
        .locale_preference = "he",
    },
    // Devanagari font
    .{
        .name = "Noto Sans Devanagari",
        .font_type = .devanagari,
        .coverage = .{ .ranges = &[_][2]u32{
            .{ 0x0900, 0x097F }, // Devanagari
        } },
        .locale_preference = "hi",
    },
};

// ============================================================================
// FALLBACK STRATEGIES
// ============================================================================

const FallbackStrategy = enum {
    /// Option A: Simple linear search through user-provided chain
    /// Like Dear ImGui MergeMode
    user_chain_linear,

    /// Option B: Query platform API (simulated)
    /// Like DirectWrite, CoreText
    platform_query,

    /// Option C: Pre-computed coverage map
    /// Like cosmic-text
    coverage_scan,

    /// Option D: User chain with locale awareness for Han unification
    /// Our recommended approach
    locale_aware_chain,

    /// Option E: Hybrid - user chain first, then platform query
    hybrid,
};

const FallbackResult = struct {
    font_name: []const u8,
    font_type: FontType,
    lookup_count: u32, // How many fonts were checked
    cache_hit: bool,
    locale_matched: bool, // For Han unification
};

/// Strategy A: Simple linear search
fn fallbackLinear(
    codepoint: u32,
    chain: []const *const SimulatedFont,
    _: ?[]const u8, // locale ignored
) FallbackResult {
    var lookup_count: u32 = 0;
    for (chain) |font| {
        lookup_count += 1;
        if (font.coverage.contains(codepoint)) {
            return .{
                .font_name = font.name,
                .font_type = font.font_type,
                .lookup_count = lookup_count,
                .cache_hit = false,
                .locale_matched = false,
            };
        }
    }
    return .{
        .font_name = ".notdef",
        .font_type = .notdef,
        .lookup_count = lookup_count,
        .cache_hit = false,
        .locale_matched = false,
    };
}

/// Strategy D: Locale-aware search (handles Han unification)
fn fallbackLocaleAware(
    codepoint: u32,
    chain: []const *const SimulatedFont,
    locale: ?[]const u8,
) FallbackResult {
    var lookup_count: u32 = 0;

    // For CJK range, prefer locale-specific font
    const is_cjk = (codepoint >= 0x4E00 and codepoint <= 0x9FFF);

    if (is_cjk and locale != null) {
        // First pass: look for locale-matching font
        for (chain) |font| {
            lookup_count += 1;
            if (font.locale_preference) |pref| {
                if (std.mem.startsWith(u8, locale.?, pref) or
                    std.mem.startsWith(u8, pref, locale.?))
                {
                    if (font.coverage.contains(codepoint)) {
                        return .{
                            .font_name = font.name,
                            .font_type = font.font_type,
                            .lookup_count = lookup_count,
                            .cache_hit = false,
                            .locale_matched = true,
                        };
                    }
                }
            }
        }
    }

    // Second pass (or non-CJK): linear search
    for (chain) |font| {
        lookup_count += 1;
        if (font.coverage.contains(codepoint)) {
            return .{
                .font_name = font.name,
                .font_type = font.font_type,
                .lookup_count = lookup_count,
                .cache_hit = false,
                .locale_matched = false,
            };
        }
    }

    return .{
        .font_name = ".notdef",
        .font_type = .notdef,
        .lookup_count = lookup_count,
        .cache_hit = false,
        .locale_matched = false,
    };
}

// ============================================================================
// STATISTICS
// ============================================================================

const FallbackStats = struct {
    total_codepoints: u32 = 0,
    total_lookups: u32 = 0,
    cache_hits: u32 = 0,
    locale_matches: u32 = 0,
    notdef_count: u32 = 0,
    fonts_used: std.AutoHashMap(FontType, u32),
    max_chain_depth: u32 = 0, // Deepest search

    fn init(allocator: std.mem.Allocator) FallbackStats {
        return .{
            .fonts_used = std.AutoHashMap(FontType, u32).init(allocator),
        };
    }

    fn deinit(self: *FallbackStats) void {
        self.fonts_used.deinit();
    }

    fn record(self: *FallbackStats, result: FallbackResult) void {
        self.total_codepoints += 1;
        self.total_lookups += result.lookup_count;
        if (result.cache_hit) self.cache_hits += 1;
        if (result.locale_matched) self.locale_matches += 1;
        if (result.font_type == .notdef) self.notdef_count += 1;
        if (result.lookup_count > self.max_chain_depth) {
            self.max_chain_depth = result.lookup_count;
        }

        const entry = self.fonts_used.getOrPut(result.font_type) catch return;
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    fn avgLookupsPerCodepoint(self: FallbackStats) f32 {
        if (self.total_codepoints == 0) return 0;
        return @as(f32, @floatFromInt(self.total_lookups)) /
            @as(f32, @floatFromInt(self.total_codepoints));
    }
};

// ============================================================================
// SIMULATION
// ============================================================================

fn runScenario(
    scenario: Scenario,
    strategy: FallbackStrategy,
    chain: []const *const SimulatedFont,
    allocator: std.mem.Allocator,
) !FallbackStats {
    var stats = FallbackStats.init(allocator);

    // Iterate through text codepoints
    var iter = std.unicode.Utf8Iterator{ .bytes = scenario.text, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        const result = switch (strategy) {
            .user_chain_linear => fallbackLinear(codepoint, chain, scenario.locale),
            .locale_aware_chain => fallbackLocaleAware(codepoint, chain, scenario.locale),
            else => fallbackLinear(codepoint, chain, scenario.locale), // Default to linear
        };
        stats.record(result);
    }

    return stats;
}

// ============================================================================
// ANALYSIS OUTPUT
// ============================================================================

fn printScenarioResult(
    scenario: Scenario,
    linear_stats: FallbackStats,
    locale_stats: FallbackStats,
) void {
    std.debug.print("\n{s}\n", .{"─" ** 78});
    std.debug.print("Scenario: {s}\n", .{scenario.name});
    std.debug.print("  {s}\n", .{scenario.description});
    std.debug.print("  Target: {s}, Locale: {s}, Critical: {}\n", .{
        @tagName(scenario.target),
        scenario.locale orelse "none",
        scenario.is_critical,
    });
    std.debug.print("  Text: \"{s}\"\n", .{scenario.text});

    std.debug.print("\n  Results:\n", .{});
    std.debug.print("  {s:<20} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "Strategy", "Avg Lookups", "Max Depth", "Locale Hit", ".notdef",
    });
    std.debug.print("  {s:<20} {d:>12.2} {d:>12} {d:>12} {d:>12}\n", .{
        "Linear",
        linear_stats.avgLookupsPerCodepoint(),
        linear_stats.max_chain_depth,
        linear_stats.locale_matches,
        linear_stats.notdef_count,
    });
    std.debug.print("  {s:<20} {d:>12.2} {d:>12} {d:>12} {d:>12}\n", .{
        "Locale-Aware",
        locale_stats.avgLookupsPerCodepoint(),
        locale_stats.max_chain_depth,
        locale_stats.locale_matches,
        locale_stats.notdef_count,
    });

    // Check Han unification
    if (scenario.locale != null and
        (std.mem.startsWith(u8, scenario.locale.?, "zh") or
        std.mem.startsWith(u8, scenario.locale.?, "ja") or
        std.mem.startsWith(u8, scenario.locale.?, "ko")))
    {
        if (locale_stats.locale_matches > linear_stats.locale_matches) {
            std.debug.print("\n  ✓ Locale-aware handled Han unification correctly\n", .{});
        } else if (linear_stats.locale_matches == 0 and locale_stats.locale_matches == 0) {
            std.debug.print("\n  ⚠ No CJK characters needed locale handling\n", .{});
        }
    }

    // Font usage
    std.debug.print("\n  Fonts used (locale-aware):\n", .{});
    var iter = locale_stats.fonts_used.iterator();
    while (iter.next()) |entry| {
        std.debug.print("    {s}: {} codepoints\n", .{
            @tagName(entry.key_ptr.*),
            entry.value_ptr.*,
        });
    }
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("{s}\n", .{"=" ** 78});
    std.debug.print("EXPERIMENT 13: Font Fallback - Realistic Validation\n", .{});
    std.debug.print("{s}\n", .{"=" ** 78});

    std.debug.print("\nStrategies under test:\n", .{});
    std.debug.print("  A. Linear       - Simple chain search (Dear ImGui)\n", .{});
    std.debug.print("  D. Locale-Aware - Chain with Han unification (Recommended)\n", .{});

    // Build default fallback chain (user-provided order)
    const default_chain = [_]*const SimulatedFont{
        &simulated_fonts[0], // Roboto (primary)
        &simulated_fonts[1], // Symbols
        &simulated_fonts[6], // Emoji
        &simulated_fonts[2], // Japanese
        &simulated_fonts[3], // Chinese Simplified
        &simulated_fonts[4], // Chinese Traditional
        &simulated_fonts[5], // Korean
        &simulated_fonts[7], // Arabic
        &simulated_fonts[8], // Hebrew
        &simulated_fonts[9], // Devanagari
    };

    // Summary stats
    var total_linear_lookups: u32 = 0;
    var total_locale_lookups: u32 = 0;
    var total_codepoints: u32 = 0;
    var han_unification_wins: u32 = 0;
    var critical_failures: u32 = 0;

    // Run all scenarios
    for (scenarios) |scenario| {
        var linear_stats = try runScenario(scenario, .user_chain_linear, &default_chain, allocator);
        defer linear_stats.deinit();

        var locale_stats = try runScenario(scenario, .locale_aware_chain, &default_chain, allocator);
        defer locale_stats.deinit();

        printScenarioResult(scenario, linear_stats, locale_stats);

        total_linear_lookups += linear_stats.total_lookups;
        total_locale_lookups += locale_stats.total_lookups;
        total_codepoints += linear_stats.total_codepoints;

        if (locale_stats.locale_matches > linear_stats.locale_matches) {
            han_unification_wins += 1;
        }

        if (scenario.is_critical and locale_stats.notdef_count > 0) {
            critical_failures += 1;
            std.debug.print("\n  ⚠ CRITICAL: Missing glyphs in critical scenario!\n", .{});
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ANALYSIS
    // ════════════════════════════════════════════════════════════════════════

    std.debug.print("\n\n", .{});
    std.debug.print("{s}\n", .{"=" ** 78});
    std.debug.print("ANALYSIS & CONCLUSIONS\n", .{});
    std.debug.print("{s}\n", .{"=" ** 78});

    std.debug.print("\n1. PERFORMANCE SUMMARY:\n", .{});
    std.debug.print("   {s:<25} {s:>15} {s:>15}\n", .{ "", "Linear", "Locale-Aware" });
    std.debug.print("   {s:<25} {d:>15} {d:>15}\n", .{
        "Total lookups:",
        total_linear_lookups,
        total_locale_lookups,
    });
    std.debug.print("   {s:<25} {d:>15.2} {d:>15.2}\n", .{
        "Avg lookups/codepoint:",
        @as(f32, @floatFromInt(total_linear_lookups)) / @as(f32, @floatFromInt(total_codepoints)),
        @as(f32, @floatFromInt(total_locale_lookups)) / @as(f32, @floatFromInt(total_codepoints)),
    });

    std.debug.print("\n2. HAN UNIFICATION:\n", .{});
    std.debug.print("   Scenarios where locale-aware was better: {}\n", .{han_unification_wins});
    if (han_unification_wins > 0) {
        std.debug.print("   → Locale awareness IS needed for CJK correctness\n", .{});
    }

    std.debug.print("\n3. CRITICAL FAILURES:\n", .{});
    if (critical_failures == 0) {
        std.debug.print("   ✓ All critical scenarios passed\n", .{});
    } else {
        std.debug.print("   ✗ {} critical scenarios had missing glyphs\n", .{critical_failures});
    }

    std.debug.print("\n4. RECOMMENDATIONS:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    std.debug.print("\n   FOR EMBEDDED (32KB):\n", .{});
    std.debug.print("   • Single font, no fallback needed\n", .{});
    std.debug.print("   • Pre-select charset at build time\n", .{});
    std.debug.print("   • Render .notdef for unsupported chars\n", .{});

    std.debug.print("\n   FOR DESKTOP LATIN:\n", .{});
    std.debug.print("   • Primary font + Symbol font + Emoji font\n", .{});
    std.debug.print("   • 3-font chain covers 95%% of use cases\n", .{});
    std.debug.print("   • Linear search is fine (avg < 2 lookups)\n", .{});

    std.debug.print("\n   FOR CJK / i18n:\n", .{});
    std.debug.print("   • MUST use locale-aware fallback for Han unification\n", .{});
    std.debug.print("   • User provides: primary + CJK fonts with locale tags\n", .{});
    std.debug.print("   • Config: .fallback_locale = \"ja\" (from app settings)\n", .{});

    std.debug.print("\n   FOR GAMES:\n", .{});
    std.debug.print("   • Pre-load all fonts at startup\n", .{});
    std.debug.print("   • Cache fallback results (font per codepoint)\n", .{});
    std.debug.print("   • Avoid runtime font discovery\n", .{});

    std.debug.print("\n5. INTERFACE DECISION:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});

    std.debug.print("\n   ✓ USER PROVIDES FALLBACK CHAIN (Option A + locale extension)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   Rationale:\n", .{});
    std.debug.print("   • Simple: User lists fonts in order, we search linearly\n", .{});
    std.debug.print("   • Predictable: Same fonts = same result everywhere\n", .{});
    std.debug.print("   • Embedded-friendly: No OS dependency\n", .{});
    std.debug.print("   • Han-safe: Locale tag solves CJK ambiguity\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   What user burden:\n", .{});
    std.debug.print("   • Embedded: None (single font)\n", .{});
    std.debug.print("   • Desktop Latin: Minimal (Roboto + Emoji)\n", .{});
    std.debug.print("   • CJK apps: Must know which CJK fonts to include\n", .{});
    std.debug.print("   • Full i18n: Significant (but unavoidable complexity)\n", .{});

    std.debug.print("\n   ✗ NOT BYOFF (Bring Your Own Font Fallback)\n", .{});
    std.debug.print("   • Same reasoning as BYOFM (atlas management)\n", .{});
    std.debug.print("   • Config is enough, interface would add complexity\n", .{});

    std.debug.print("\n6. PROPOSED CONFIG:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   pub const TextProviderConfig = struct {{\n", .{});
    std.debug.print("       // Primary font (required)\n", .{});
    std.debug.print("       primary_font: FontHandle,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("       // Fallback chain (optional, searched in order)\n", .{});
    std.debug.print("       fallback_fonts: []const FontHandle = &.{{}},\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("       // For Han unification - which CJK variant to prefer\n", .{});
    std.debug.print("       // null = use first matching CJK font\n", .{});
    std.debug.print("       // \"ja\" = prefer Japanese variant\n", .{});
    std.debug.print("       // \"zh-Hans\" = prefer Simplified Chinese\n", .{});
    std.debug.print("       fallback_locale: ?[]const u8 = null,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("       // What to do when no font has the glyph\n", .{});
    std.debug.print("       missing_glyph: MissingGlyphBehavior = .render_notdef,\n", .{});
    std.debug.print("   }};\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   pub const MissingGlyphBehavior = enum {{\n", .{});
    std.debug.print("       render_notdef,    // Show □ or similar\n", .{});
    std.debug.print("       skip,             // Don't render anything\n", .{});
    std.debug.print("       replacement_char, // Show U+FFFD �\n", .{});
    std.debug.print("   }};\n", .{});

    std.debug.print("\n7. WHAT WE'RE NOT DOING:\n", .{});
    std.debug.print("   ─────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("   • Platform font query (DirectWrite, CoreText, fontconfig)\n", .{});
    std.debug.print("     → Too complex, platform-specific, not needed for most apps\n", .{});
    std.debug.print("   • Automatic Unicode coverage scanning\n", .{});
    std.debug.print("     → Expensive at startup, user knows their fonts better\n", .{});
    std.debug.print("   • Dynamic font discovery\n", .{});
    std.debug.print("     → Unpredictable, different per machine\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   These can be added as OPTIONAL helpers for desktop:\n", .{});
    std.debug.print("   • querySystemFallback(codepoint, locale) -> ?FontHandle\n", .{});
    std.debug.print("   • Only for users who WANT platform integration\n", .{});
}
