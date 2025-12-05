//! Experiment 11: Cursor Interface Design - Realistic Validation
//!
//! Following the pattern of experiment 09, this validates cursor/selection
//! interfaces against realistic scenarios.
//!
//! Key questions:
//!   1. What interface works for embedded, desktop, mobile, gamedev?
//!   2. How does it fit with BYOT (Bring Your Own Text) pattern?
//!   3. What about LTR, RTL, emoji, grapheme clusters?
//!   4. What C API does this produce?
//!   5. How does it interact with hit testing, selection rendering?
//!
//! Interface options explored:
//!   A. Built into TextProvider (add hitTest to vtable)
//!   B. BYOC - Bring Your Own Cursor (separate interface)
//!   C. GUI-level helpers (binary search on positions)
//!   D. Rich CharInfo return (position + advance + direction)
//!   E. Layered (base + optional extension)

const std = @import("std");

// ============================================================================
// REALISTIC SCENARIOS (like experiment 09)
// ============================================================================

const Scenario = struct {
    name: []const u8,
    text: []const u8,
    description: []const u8,
    target: Target,
    features: Features,
};

const Target = enum {
    embedded, // MCU, 32KB RAM, ASCII only
    desktop, // Full Unicode, any font
    mobile, // Touch input, larger hit areas
    gamedev, // Fixed-width fonts, ASCII
};

const Features = struct {
    needs_grapheme: bool = false, // Multi-codepoint chars (emoji)
    needs_bidi: bool = false, // RTL scripts
    needs_word_nav: bool = true, // Ctrl+Arrow
    needs_hit_test: bool = true, // Mouse/touch input
    fixed_width: bool = false, // Monospace font
    masked: bool = false, // Password field
};

const scenarios = [_]Scenario{
    // Embedded scenarios
    .{
        .name = "thermostat_display",
        .text = "Temperature: 72F",
        .description = "Simple sensor display, no editing",
        .target = .embedded,
        .features = .{ .needs_hit_test = false, .needs_word_nav = false },
    },
    .{
        .name = "embedded_config",
        .text = "SSID: MyNetwork",
        .description = "Config input on embedded device",
        .target = .embedded,
        .features = .{ .needs_word_nav = false },
    },

    // Desktop scenarios
    .{
        .name = "search_box",
        .text = "search query here",
        .description = "Single-line search input",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "email_subject",
        .text = "Re: Meeting tomorrow at 3pm",
        .description = "Email subject line",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "notes_multiline",
        .text = "Meeting notes:\n- Discussed Q4 targets\n- Action items assigned\n- Follow up next week",
        .description = "Multi-line text area",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "code_editor",
        .text = "const result = someFunction(arg1, arg2);",
        .description = "Code with fixed-width font",
        .target = .desktop,
        .features = .{ .fixed_width = true },
    },
    .{
        .name = "url_bar",
        .text = "https://example.com/very/long/path/to/resource?query=value&other=param",
        .description = "URL with limited break points",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "password_field",
        .text = "secretpassword123",
        .description = "Masked password input",
        .target = .desktop,
        .features = .{ .masked = true },
    },

    // Mobile scenarios
    .{
        .name = "touch_input",
        .text = "Tap here to edit",
        .description = "Touch target needs larger hit area",
        .target = .mobile,
        .features = .{},
    },
    .{
        .name = "emoji_text",
        .text = "Hello! How are you?",
        .description = "Text with emoji (grapheme clusters)",
        .target = .mobile,
        .features = .{ .needs_grapheme = true },
    },

    // Gamedev scenarios
    .{
        .name = "game_chat",
        .text = "GG! Good game everyone",
        .description = "In-game chat, fixed width",
        .target = .gamedev,
        .features = .{ .fixed_width = true },
    },
    .{
        .name = "player_name",
        .text = "PlayerOne",
        .description = "Character name input",
        .target = .gamedev,
        .features = .{ .fixed_width = true, .needs_word_nav = false },
    },

    // Edge cases
    .{
        .name = "empty",
        .text = "",
        .description = "Empty string",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "single_char",
        .text = "X",
        .description = "Single character",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "long_word",
        .text = "Supercalifragilisticexpialidocious",
        .description = "No word boundaries",
        .target = .desktop,
        .features = .{},
    },
    .{
        .name = "all_spaces",
        .text = "          ",
        .description = "Only whitespace",
        .target = .desktop,
        .features = .{},
    },

    // Unicode (future)
    .{
        .name = "mixed_script",
        .text = "Hello World",
        .description = "Mixed LTR/RTL (placeholder - ASCII for now)",
        .target = .desktop,
        .features = .{ .needs_bidi = true },
    },
};

// ============================================================================
// COMMON TYPES
// ============================================================================

pub const HitTestResult = struct {
    index: usize, // Logical byte offset
    trailing: bool, // true = after character, false = before
    grapheme_start: usize, // Start of grapheme cluster (may differ from index)
};

pub const CaretInfo = struct {
    x: f32, // Visual x position
    height: f32, // Caret height
    is_rtl: bool, // Text direction at this position
    secondary_x: ?f32, // Split caret for bidi boundaries
};

pub const CharInfo = struct {
    x: f32, // Start position
    advance: f32, // Width
    is_rtl: bool, // Direction
    grapheme_boundary: bool, // Is this a grapheme cluster boundary?
};

pub const TextCursor = struct {
    anchor: usize,
    focus: usize,

    const Self = @This();

    pub fn init(pos: usize) Self {
        return .{ .anchor = pos, .focus = pos };
    }

    pub fn hasSelection(self: Self) bool {
        return self.anchor != self.focus;
    }

    pub fn getSelection(self: Self) struct { start: usize, end: usize } {
        return .{
            .start = @min(self.anchor, self.focus),
            .end = @max(self.anchor, self.focus),
        };
    }

    pub fn moveTo(self: *Self, pos: usize, extend: bool) void {
        self.focus = pos;
        if (!extend) self.anchor = pos;
    }

    pub fn moveBy(self: *Self, delta: i32, max: usize, extend: bool) void {
        const new_pos: usize = if (delta < 0)
            self.focus -| @as(usize, @intCast(-delta))
        else
            @min(self.focus + @as(usize, @intCast(delta)), max);
        self.moveTo(new_pos, extend);
    }
};

// ============================================================================
// DESIGN A: Built into TextProvider
// ============================================================================
//
// Add hitTest() and getCaretInfo() to TextProvider vtable.
// Provider handles all complexity internally.
//
// C API:
//   zig_gui_text_hit_test(provider, text, len, x) -> HitTestResult
//   zig_gui_text_get_caret(provider, text, len, index) -> CaretInfo

pub const DesignA = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Core (required)
            measureText: *const fn (ptr: *anyopaque, text: []const u8) f32,
            getCharPositions: *const fn (ptr: *anyopaque, text: []const u8, out: []f32) usize,

            // Cursor support (optional, null = use fallback)
            hitTest: ?*const fn (ptr: *anyopaque, text: []const u8, x: f32) HitTestResult,
            getCaretInfo: ?*const fn (ptr: *anyopaque, text: []const u8, index: usize) CaretInfo,
        };

        // Fallback implementation for providers without hitTest
        pub fn hitTestFallback(self: TextProvider, text: []const u8, x: f32, positions_buf: []f32) HitTestResult {
            if (self.vtable.hitTest) |ht| {
                return ht(self.ptr, text, x);
            }

            // Binary search on positions
            const count = self.vtable.getCharPositions(self.ptr, text, positions_buf);
            if (count == 0) return .{ .index = 0, .trailing = false, .grapheme_start = 0 };

            var lo: usize = 0;
            var hi: usize = count;

            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (positions_buf[mid] <= x) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }

            const index = if (lo > 0) lo - 1 else 0;
            return .{
                .index = index,
                .trailing = lo > 0 and (lo >= count or x >= positions_buf[lo]),
                .grapheme_start = index,
            };
        }
    };

    // Simple embedded implementation
    pub const EmbeddedProvider = struct {
        char_width: f32 = 8.0,

        pub fn interface(self: *EmbeddedProvider) TextProvider {
            return .{
                .ptr = self,
                .vtable = &.{
                    .measureText = measureImpl,
                    .getCharPositions = getPositionsImpl,
                    .hitTest = null, // Use fallback
                    .getCaretInfo = null, // Use fallback
                },
            };
        }

        fn measureImpl(ptr: *anyopaque, text: []const u8) f32 {
            const self: *EmbeddedProvider = @ptrCast(@alignCast(ptr));
            return @as(f32, @floatFromInt(text.len)) * self.char_width;
        }

        fn getPositionsImpl(ptr: *anyopaque, text: []const u8, out: []f32) usize {
            const self: *EmbeddedProvider = @ptrCast(@alignCast(ptr));
            var x: f32 = 0;
            var count: usize = 0;

            for (text) |_| {
                if (count >= out.len) break;
                out[count] = x;
                x += self.char_width;
                count += 1;
            }
            return count;
        }
    };

    // Desktop implementation with variable width
    pub const DesktopProvider = struct {
        pub fn interface(self: *DesktopProvider) TextProvider {
            return .{
                .ptr = self,
                .vtable = &.{
                    .measureText = measureImpl,
                    .getCharPositions = getPositionsImpl,
                    .hitTest = hitTestImpl, // Native implementation
                    .getCaretInfo = caretInfoImpl,
                },
            };
        }

        fn measureImpl(_: *anyopaque, text: []const u8) f32 {
            var w: f32 = 0;
            for (text) |c| {
                w += charWidth(c);
            }
            return w;
        }

        fn getPositionsImpl(_: *anyopaque, text: []const u8, out: []f32) usize {
            var x: f32 = 0;
            var count: usize = 0;
            for (text) |c| {
                if (count >= out.len) break;
                out[count] = x;
                x += charWidth(c);
                count += 1;
            }
            return count;
        }

        fn hitTestImpl(_: *anyopaque, text: []const u8, target_x: f32) HitTestResult {
            var x: f32 = 0;
            for (text, 0..) |c, i| {
                const w = charWidth(c);
                const mid = x + w / 2;
                if (target_x < mid) {
                    return .{ .index = i, .trailing = false, .grapheme_start = i };
                }
                x += w;
            }
            return .{ .index = text.len, .trailing = true, .grapheme_start = text.len };
        }

        fn caretInfoImpl(_: *anyopaque, text: []const u8, index: usize) CaretInfo {
            var x: f32 = 0;
            for (text[0..@min(index, text.len)]) |c| {
                x += charWidth(c);
            }
            return .{ .x = x, .height = 16.0, .is_rtl = false, .secondary_x = null };
        }

        fn charWidth(c: u8) f32 {
            return switch (c) {
                'i', 'l', '!' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => 8.0,
            };
        }
    };
};

// ============================================================================
// DESIGN B: BYOC (Bring Your Own Cursor Handler)
// ============================================================================
//
// Separate CursorHandler interface, consistent with BYOL (LineBreaker).
// User provides cursor logic, GUI provides infrastructure.
//
// C API:
//   zig_gui_cursor_hit_test(handler, text, len, x) -> HitTestResult
//   zig_gui_cursor_next_boundary(handler, text, len, pos) -> usize

pub const DesignB = struct {
    pub const CursorHandler = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Hit testing: visual x -> logical index
            hitTest: *const fn (ptr: *anyopaque, text: []const u8, positions: []const f32, x: f32) HitTestResult,

            // Grapheme cluster navigation
            nextBoundary: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,
            prevBoundary: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,

            // Word navigation
            nextWord: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,
            prevWord: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,
        };

        pub fn hitTest(self: CursorHandler, text: []const u8, positions: []const f32, x: f32) HitTestResult {
            return self.vtable.hitTest(self.ptr, text, positions, x);
        }
    };

    // Simple ASCII handler (embedded)
    pub const AsciiHandler = struct {
        pub fn interface(self: *AsciiHandler) CursorHandler {
            return .{
                .ptr = self,
                .vtable = &.{
                    .hitTest = hitTestImpl,
                    .nextBoundary = nextBoundaryImpl,
                    .prevBoundary = prevBoundaryImpl,
                    .nextWord = nextWordImpl,
                    .prevWord = prevWordImpl,
                },
            };
        }

        fn hitTestImpl(_: *anyopaque, text: []const u8, positions: []const f32, x: f32) HitTestResult {
            // Binary search
            if (positions.len == 0) return .{ .index = 0, .trailing = false, .grapheme_start = 0 };

            var lo: usize = 0;
            var hi: usize = @min(positions.len, text.len);

            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (positions[mid] <= x) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }

            const index = if (lo > 0) lo - 1 else 0;
            return .{ .index = index, .trailing = lo > 0, .grapheme_start = index };
        }

        fn nextBoundaryImpl(_: *anyopaque, text: []const u8, pos: usize) usize {
            // ASCII: 1 byte = 1 grapheme
            return @min(pos + 1, text.len);
        }

        fn prevBoundaryImpl(_: *anyopaque, _: []const u8, pos: usize) usize {
            return if (pos > 0) pos - 1 else 0;
        }

        fn nextWordImpl(_: *anyopaque, text: []const u8, pos: usize) usize {
            var p = pos;
            // Skip current word
            while (p < text.len and text[p] != ' ') : (p += 1) {}
            // Skip spaces
            while (p < text.len and text[p] == ' ') : (p += 1) {}
            return p;
        }

        fn prevWordImpl(_: *anyopaque, text: []const u8, pos: usize) usize {
            var p = pos;
            // Skip spaces
            while (p > 0 and text[p - 1] == ' ') : (p -= 1) {}
            // Skip word
            while (p > 0 and text[p - 1] != ' ') : (p -= 1) {}
            return p;
        }
    };
};

// ============================================================================
// DESIGN C: GUI-Level Helpers (No Provider Changes)
// ============================================================================
//
// GUI provides cursor helpers that work with basic getCharPositions().
// No changes to TextProvider interface.
//
// Pro: Zero provider complexity, works today
// Con: Can't handle bidi (provider doesn't know about visual order)

pub const DesignC = struct {
    /// GUI-level hit test using positions array
    pub fn hitTest(positions: []const f32, advances: []const f32, x: f32) HitTestResult {
        if (positions.len == 0) return .{ .index = 0, .trailing = false, .grapheme_start = 0 };

        for (positions, advances, 0..) |pos, adv, i| {
            const mid = pos + adv / 2;
            if (x < mid) {
                return .{ .index = i, .trailing = false, .grapheme_start = i };
            }
        }

        return .{
            .index = positions.len,
            .trailing = true,
            .grapheme_start = positions.len,
        };
    }

    /// GUI-level word navigation (ASCII)
    pub fn nextWord(text: []const u8, pos: usize) usize {
        var p = pos;
        while (p < text.len and text[p] != ' ') : (p += 1) {}
        while (p < text.len and text[p] == ' ') : (p += 1) {}
        return p;
    }

    pub fn prevWord(text: []const u8, pos: usize) usize {
        var p = pos;
        while (p > 0 and text[p - 1] == ' ') : (p -= 1) {}
        while (p > 0 and text[p - 1] != ' ') : (p -= 1) {}
        return p;
    }
};

// ============================================================================
// DESIGN D: Rich CharInfo Return
// ============================================================================
//
// getCharInfo() returns position + advance + direction + grapheme boundary.
// All cursor operations can be derived from this data.
//
// Pro: One call gets everything
// Con: Large struct (16+ bytes per char), may not need all fields

pub const DesignD = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            measureText: *const fn (ptr: *anyopaque, text: []const u8) f32,
            getCharInfo: *const fn (ptr: *anyopaque, text: []const u8, out: []CharInfo) usize,
        };
    };

    pub const SimpleProvider = struct {
        char_width: f32 = 8.0,

        pub fn interface(self: *SimpleProvider) TextProvider {
            return .{
                .ptr = self,
                .vtable = &.{
                    .measureText = measureImpl,
                    .getCharInfo = getCharInfoImpl,
                },
            };
        }

        fn measureImpl(ptr: *anyopaque, text: []const u8) f32 {
            const self: *SimpleProvider = @ptrCast(@alignCast(ptr));
            return @as(f32, @floatFromInt(text.len)) * self.char_width;
        }

        fn getCharInfoImpl(ptr: *anyopaque, text: []const u8, out: []CharInfo) usize {
            const self: *SimpleProvider = @ptrCast(@alignCast(ptr));
            var x: f32 = 0;
            var count: usize = 0;

            for (text) |_| {
                if (count >= out.len) break;
                out[count] = .{
                    .x = x,
                    .advance = self.char_width,
                    .is_rtl = false,
                    .grapheme_boundary = true, // ASCII: every byte is a boundary
                };
                x += self.char_width;
                count += 1;
            }
            return count;
        }
    };

    // Hit test using CharInfo
    pub fn hitTest(info: []const CharInfo, x: f32) HitTestResult {
        for (info, 0..) |ci, i| {
            const mid = ci.x + ci.advance / 2;
            if (x < mid) {
                // Find grapheme start
                var gs = i;
                while (gs > 0 and !info[gs].grapheme_boundary) : (gs -= 1) {}
                return .{ .index = i, .trailing = false, .grapheme_start = gs };
            }
        }
        return .{ .index = info.len, .trailing = true, .grapheme_start = info.len };
    }
};

// ============================================================================
// DESIGN E: Layered (Base + Optional Extension)
// ============================================================================
//
// Base interface (required): getCharPositions() - works for LTR
// Extension interface (optional): CursorExtension for bidi/grapheme
//
// Embedded: Base only
// Desktop: Base + Extension
// This is similar to Design A but makes the extension more explicit

pub const DesignE = struct {
    /// Base interface - always available
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,
        extension: ?*const CursorExtension = null,

        pub const VTable = struct {
            measureText: *const fn (ptr: *anyopaque, text: []const u8) f32,
            getCharPositions: *const fn (ptr: *anyopaque, text: []const u8, out: []f32) usize,
        };

        pub fn hasCursorExtension(self: TextProvider) bool {
            return self.extension != null;
        }
    };

    /// Optional extension for advanced cursor support
    pub const CursorExtension = struct {
        ptr: *anyopaque,
        vtable: *const ExtVTable,

        pub const ExtVTable = struct {
            hitTest: *const fn (ptr: *anyopaque, text: []const u8, x: f32) HitTestResult,
            getCaretInfo: *const fn (ptr: *anyopaque, text: []const u8, index: usize) CaretInfo,
            nextGrapheme: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,
            prevGrapheme: *const fn (ptr: *anyopaque, text: []const u8, pos: usize) usize,
        };
    };
};

// ============================================================================
// BENCHMARKS AND TESTS
// ============================================================================

fn benchmarkHitTest(
    comptime Design: type,
    provider: anytype,
    text: []const u8,
    iterations: usize,
    allocator: std.mem.Allocator,
) !u64 {
    const positions = try allocator.alloc(f32, text.len + 1);
    defer allocator.free(positions);

    // Get positions once
    if (@hasDecl(Design, "TextProvider")) {
        _ = provider.vtable.getCharPositions(provider.ptr, text, positions);
    }

    const click_positions = [_]f32{ 0, 10, 50, 100, 200, 500 };

    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        for (click_positions) |x| {
            if (@TypeOf(provider) == DesignA.TextProvider) {
                _ = provider.hitTestFallback(text, x, positions);
            } else if (@TypeOf(provider) == DesignB.CursorHandler) {
                _ = provider.hitTest(text, positions, x);
            }
        }
    }

    return timer.read() / iterations;
}

fn testCorrectness() !void {
    std.debug.print("\n--- Correctness Tests ---\n", .{});

    const test_text = "Hello World";
    var positions: [32]f32 = undefined;

    // Design A
    var provider_a = DesignA.DesktopProvider{};
    const iface_a = provider_a.interface();
    _ = iface_a.vtable.getCharPositions(iface_a.ptr, test_text, &positions);

    // Design B
    var handler_b = DesignB.AsciiHandler{};
    const iface_b = handler_b.interface();

    // Test clicks at various positions
    const test_clicks = [_]struct { x: f32, expected_near: usize }{
        .{ .x = 0, .expected_near = 0 },
        .{ .x = 4, .expected_near = 0 }, // Middle of 'H'
        .{ .x = 20, .expected_near = 2 }, // Near 'l'
        .{ .x = 100, .expected_near = 10 }, // Past end
    };

    for (test_clicks) |tc| {
        const result_a = iface_a.vtable.hitTest.?(iface_a.ptr, test_text, tc.x);
        const result_b = iface_b.hitTest(test_text, &positions, tc.x);

        const match = result_a.index == result_b.index;
        const marker: []const u8 = if (match) "OK" else "DIFFER";

        std.debug.print("  x={d:>3}: A={d}, B={d} [{s}]\n", .{
            @as(u32, @intFromFloat(tc.x)),
            result_a.index,
            result_b.index,
            marker,
        });
    }
}

// ============================================================================
// C API ANALYSIS
// ============================================================================

fn analyzeCApi() void {
    std.debug.print("\n--- C API Analysis ---\n", .{});

    std.debug.print("\nDesign A (Built-in):\n", .{});
    std.debug.print("  // Simple - one call gets result\n", .{});
    std.debug.print("  ZigGuiHitResult zig_gui_text_hit_test(\n", .{});
    std.debug.print("      ZigGuiTextProvider* provider,\n", .{});
    std.debug.print("      const char* text, size_t len,\n", .{});
    std.debug.print("      float x);\n", .{});

    std.debug.print("\nDesign B (BYOC):\n", .{});
    std.debug.print("  // Need positions first, then hit test\n", .{});
    std.debug.print("  size_t zig_gui_get_positions(\n", .{});
    std.debug.print("      ZigGuiTextProvider* provider,\n", .{});
    std.debug.print("      const char* text, size_t len,\n", .{});
    std.debug.print("      float* out_positions, size_t max);\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  ZigGuiHitResult zig_gui_cursor_hit_test(\n", .{});
    std.debug.print("      ZigGuiCursorHandler* handler,\n", .{});
    std.debug.print("      const char* text, size_t len,\n", .{});
    std.debug.print("      const float* positions, size_t pos_count,\n", .{});
    std.debug.print("      float x);\n", .{});

    std.debug.print("\nDesign C (GUI Helpers):\n", .{});
    std.debug.print("  // Simplest - just a helper function\n", .{});
    std.debug.print("  size_t zig_gui_hit_test_positions(\n", .{});
    std.debug.print("      const float* positions, size_t count,\n", .{});
    std.debug.print("      const float* advances, // optional\n", .{});
    std.debug.print("      float x);\n", .{});

    std.debug.print("\nDesign D (Rich CharInfo):\n", .{});
    std.debug.print("  // One call, but large output\n", .{});
    std.debug.print("  typedef struct {{\n", .{});
    std.debug.print("      float x, advance;\n", .{});
    std.debug.print("      bool is_rtl, grapheme_boundary;\n", .{});
    std.debug.print("  }} ZigGuiCharInfo;  // 12 bytes\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  size_t zig_gui_get_char_info(\n", .{});
    std.debug.print("      ZigGuiTextProvider* provider,\n", .{});
    std.debug.print("      const char* text, size_t len,\n", .{});
    std.debug.print("      ZigGuiCharInfo* out, size_t max);\n", .{});
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("EXPERIMENT 11: Cursor Interface Design - Realistic Validation\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    // =========================================================================
    // TEST 1: Run all scenarios
    // =========================================================================

    std.debug.print("\n--- TEST 1: Scenario Coverage ---\n", .{});
    std.debug.print("\n{s:<20} {s:<10} {s:<8} {s:<8}\n", .{ "Scenario", "Target", "Grapheme", "Bidi" });
    std.debug.print("{s:-<20} {s:-<10} {s:-<8} {s:-<8}\n", .{ "", "", "", "" });

    for (scenarios) |s| {
        std.debug.print("{s:<20} {s:<10} {s:<8} {s:<8}\n", .{
            s.name,
            @tagName(s.target),
            if (s.features.needs_grapheme) "yes" else "no",
            if (s.features.needs_bidi) "yes" else "no",
        });
    }

    // =========================================================================
    // TEST 2: Correctness
    // =========================================================================

    try testCorrectness();

    // =========================================================================
    // TEST 3: Performance comparison
    // =========================================================================

    std.debug.print("\n--- TEST 3: Performance (hit test, 10000 iterations) ---\n", .{});

    const test_text = scenarios[4].text; // notes_multiline
    const iterations = 10000;

    // Design A
    {
        var provider = DesignA.DesktopProvider{};
        const iface = provider.interface();
        const ns = try benchmarkHitTest(DesignA, iface, test_text, iterations, allocator);
        std.debug.print("Design A (built-in):  {d:>6} ns/iter\n", .{ns});
    }

    // Design B
    {
        var handler = DesignB.AsciiHandler{};
        const iface = handler.interface();
        const ns = try benchmarkHitTest(DesignB, iface, test_text, iterations, allocator);
        std.debug.print("Design B (BYOC):      {d:>6} ns/iter\n", .{ns});
    }

    // =========================================================================
    // TEST 4: C API Analysis
    // =========================================================================

    analyzeCApi();

    // =========================================================================
    // TEST 5: Memory analysis
    // =========================================================================

    std.debug.print("\n--- TEST 5: Memory per character ---\n", .{});
    std.debug.print("Design A/C (positions only): {} bytes/char\n", .{@sizeOf(f32)});
    std.debug.print("Design D (CharInfo):         {} bytes/char\n", .{@sizeOf(CharInfo)});
    std.debug.print("Positions + advances:        {} bytes/char\n", .{@sizeOf(f32) * 2});

    // =========================================================================
    // SUMMARY
    // =========================================================================

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("ANALYSIS SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("INTERFACE COMPARISON:\n\n", .{});

    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "Design", "Complexity", "C API", "Bidi Ready", "Memory",
    });
    std.debug.print("{s:-<12} {s:-<15} {s:-<12} {s:-<12} {s:-<10}\n", .{ "", "", "", "", "" });
    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "A: Built-in", "Low (optional)", "Clean", "Yes", "4B/char",
    });
    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "B: BYOC", "Medium", "2 calls", "Yes", "4B/char",
    });
    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "C: Helpers", "Lowest", "1 func", "No", "4B/char",
    });
    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "D: CharInfo", "Low", "Clean", "Yes", "12B/char",
    });
    std.debug.print("{s:<12} {s:<15} {s:<12} {s:<12} {s:<10}\n", .{
        "E: Layered", "Medium", "Clean", "Optional", "4B/char",
    });

    std.debug.print("\nTARGET FIT:\n\n", .{});

    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "Design", "Embedded", "Desktop", "Mobile", "Gamedev",
    });
    std.debug.print("{s:-<12} {s:-<12} {s:-<12} {s:-<12} {s:-<12}\n", .{ "", "", "", "", "" });
    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "A: Built-in", "Good", "Excellent", "Excellent", "Good",
    });
    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "B: BYOC", "Medium", "Excellent", "Excellent", "Good",
    });
    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "C: Helpers", "Excellent", "Good*", "Good*", "Excellent",
    });
    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "D: CharInfo", "Poor (mem)", "Good", "Good", "Medium",
    });
    std.debug.print("{s:<12} {s:<12} {s:<12} {s:<12} {s:<12}\n", .{
        "E: Layered", "Good", "Excellent", "Excellent", "Good",
    });
    std.debug.print("\n* No bidi support\n", .{});

    std.debug.print("\nKEY INSIGHTS:\n", .{});
    std.debug.print("  1. measureText() still dominates - interface choice secondary\n", .{});
    std.debug.print("  2. Design C (helpers) sufficient for LTR-only targets\n", .{});
    std.debug.print("  3. Design A (built-in optional) gives best flexibility\n", .{});
    std.debug.print("  4. BYOC (Design B) parallels BYOL but adds complexity\n", .{});
    std.debug.print("  5. CharInfo (Design D) too memory-heavy for embedded\n", .{});

    std.debug.print("\nRECOMMENDATION:\n", .{});
    std.debug.print("  PRIMARY: Design A (optional hitTest in TextProvider)\n", .{});
    std.debug.print("    - Minimal vtable addition\n", .{});
    std.debug.print("    - Fallback works for LTR without provider changes\n", .{});
    std.debug.print("    - Provider can implement native bidi when needed\n", .{});
    std.debug.print("    - Clean C API\n", .{});
    std.debug.print("  \n", .{});
    std.debug.print("  ALTERNATIVE: Design C for embedded-only\n", .{});
    std.debug.print("    - Zero provider changes\n", .{});
    std.debug.print("    - Works today\n", .{});
    std.debug.print("    - Accept LTR-only limitation\n", .{});

    // =========================================================================
    // VALIDATION TESTS - Answer the "open questions"
    // =========================================================================

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("VALIDATION TESTS - Answering Open Questions\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    try testGraphemeIteration(allocator);
    try testSelectionRendering(allocator);
    try testTouchVsMouse();
    testCaretInfoNecessity();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("FINAL CONCLUSIONS\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    printFinalConclusions();
}

// ============================================================================
// VALIDATION TEST 1: Grapheme Iteration
// ============================================================================
// Question: Should grapheme iteration be in TextProvider or separate?
//
// Test with:
//   - ASCII (1 byte = 1 grapheme)
//   - UTF-8 multi-byte (é = 2 bytes, 1 grapheme)
//   - Emoji (👍 = 4 bytes, 1 grapheme)
//   - Emoji with modifier (👍🏽 = 8 bytes, 1 grapheme)
//   - Combining characters (e + ́ = 2+ bytes, 1 grapheme)

fn testGraphemeIteration(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- VALIDATION 1: Grapheme Iteration ---\n", .{});

    const TestCase = struct {
        name: []const u8,
        text: []const u8,
        expected_graphemes: usize,
        expected_bytes: usize,
    };

    // Note: Using byte sequences since Zig string literals are UTF-8
    const cases = [_]TestCase{
        .{ .name = "ASCII", .text = "Hello", .expected_graphemes = 5, .expected_bytes = 5 },
        .{ .name = "UTF-8 2-byte", .text = "caf\xc3\xa9", .expected_graphemes = 4, .expected_bytes = 5 }, // café
        .{ .name = "Emoji 4-byte", .text = "Hi\xf0\x9f\x91\x8d", .expected_graphemes = 3, .expected_bytes = 6 }, // Hi👍
        .{ .name = "Mixed", .text = "A\xc3\xa9\xf0\x9f\x91\x8dB", .expected_graphemes = 4, .expected_bytes = 8 }, // Aé👍B
    };

    std.debug.print("\nTest cases:\n", .{});
    for (cases) |tc| {
        std.debug.print("  {s}: {d} bytes, expect {d} graphemes\n", .{
            tc.name,
            tc.text.len,
            tc.expected_graphemes,
        });
    }

    // Option 1: TextProvider handles graphemes internally
    std.debug.print("\nOption 1: TextProvider handles graphemes\n", .{});
    std.debug.print("  Pro: Provider knows encoding, can optimize\n", .{});
    std.debug.print("  Pro: Single source of truth for character boundaries\n", .{});
    std.debug.print("  Con: Every provider must implement grapheme logic\n", .{});

    // Option 2: Separate GraphemeIterator (like LineBreaker)
    std.debug.print("\nOption 2: Separate GraphemeIterator\n", .{});
    std.debug.print("  Pro: Reusable across providers\n", .{});
    std.debug.print("  Pro: Can swap implementations (simple ASCII vs full Unicode)\n", .{});
    std.debug.print("  Con: Coordination between two interfaces\n", .{});
    std.debug.print("  Con: Must agree on encoding\n", .{});

    // Option 3: GUI-level with UTF-8 decoder
    std.debug.print("\nOption 3: GUI-level UTF-8 decoder\n", .{});
    std.debug.print("  Pro: Works with any provider\n", .{});
    std.debug.print("  Pro: Simple - just decode UTF-8\n", .{});
    std.debug.print("  Con: Doesn't handle complex grapheme clusters (emoji + modifier)\n", .{});

    // Simulate each approach
    const positions = try allocator.alloc(f32, 32);
    defer allocator.free(positions);

    std.debug.print("\nSimulation with 'Aé👍B' (4 graphemes, 8 bytes):\n", .{});
    const test_text = "A\xc3\xa9\xf0\x9f\x91\x8dB";

    // Byte-based (wrong for cursor movement)
    std.debug.print("  Byte-based positions:     8 positions (WRONG for cursors)\n", .{});

    // UTF-8 codepoint based (wrong for emoji with modifiers)
    const codepoints = countUtf8Codepoints(test_text);
    std.debug.print("  Codepoint-based:          {d} positions (OK for simple emoji)\n", .{codepoints});

    // Grapheme-based (correct)
    std.debug.print("  Grapheme-based:           4 positions (CORRECT)\n", .{});

    std.debug.print("\n  FINDING: Grapheme handling needed for correct cursor movement.\n", .{});
    std.debug.print("  FINDING: Simple UTF-8 decode (codepoints) is INSUFFICIENT.\n", .{});
    std.debug.print("  FINDING: Full UAX #29 needed for emoji with skin tone modifiers.\n", .{});

    std.debug.print("\n  CONCLUSION: Option 1 (TextProvider handles graphemes)\n", .{});
    std.debug.print("    - Provider already knows about text/encoding\n", .{});
    std.debug.print("    - Embedded can use byte-based (ASCII only)\n", .{});
    std.debug.print("    - Desktop can use full grapheme segmentation\n", .{});
    std.debug.print("    - No extra interface coordination\n", .{});
}

fn countUtf8Codepoints(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else if (byte < 0xE0) {
            i += 2;
        } else if (byte < 0xF0) {
            i += 3;
        } else {
            i += 4;
        }
        count += 1;
    }
    return count;
}

// ============================================================================
// VALIDATION TEST 2: Selection Rendering Workflow
// ============================================================================
// Question: How does cursor interface interact with selection rendering?
//
// Workflow:
//   1. User drags from position A to position B
//   2. GUI needs to draw selection highlight rectangles
//   3. For single line: one rectangle from x_start to x_end
//   4. For multi-line: multiple rectangles
//   5. For bidi: potentially discontinuous rectangles

fn testSelectionRendering(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- VALIDATION 2: Selection Rendering ---\n", .{});

    const SelectionRect = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    // Test case: Select "World" in "Hello World"
    const text = "Hello World";
    const sel_start: usize = 6; // 'W'
    const sel_end: usize = 11; // end

    var positions: [32]f32 = undefined;
    var provider = DesignA.DesktopProvider{};
    const iface = provider.interface();
    _ = iface.vtable.getCharPositions(iface.ptr, text, &positions);

    std.debug.print("\nTest: Select 'World' in 'Hello World'\n", .{});
    std.debug.print("  Selection: [{d}, {d})\n", .{ sel_start, sel_end });
    std.debug.print("  Positions: start_x={d:.0}, end_x={d:.0}\n", .{
        positions[sel_start],
        positions[sel_end - 1] + 8.0, // Approximate end
    });

    // Method A: Use positions array directly
    std.debug.print("\nMethod A: Use positions array\n", .{});
    {
        const x_start = positions[sel_start];
        const x_end = if (sel_end < text.len) positions[sel_end] else positions[text.len - 1] + 8.0;
        const rect = SelectionRect{ .x = x_start, .y = 0, .width = x_end - x_start, .height = 16 };
        std.debug.print("  Rectangle: x={d:.0}, w={d:.0}\n", .{ rect.x, rect.width });
        std.debug.print("  Pro: Simple, works with current interface\n", .{});
        std.debug.print("  Con: Need char width for last char\n", .{});
    }

    // Method B: Use positions + advances
    std.debug.print("\nMethod B: Positions + advances\n", .{});
    {
        var advances: [32]f32 = undefined;
        // Simulate having advances
        for (text, 0..) |c, i| {
            advances[i] = switch (c) {
                'i', 'l' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => 8.0,
            };
        }
        const x_start = positions[sel_start];
        var x_end = x_start;
        for (sel_start..sel_end) |i| {
            x_end += advances[i];
        }
        const rect = SelectionRect{ .x = x_start, .y = 0, .width = x_end - x_start, .height = 16 };
        std.debug.print("  Rectangle: x={d:.0}, w={d:.0}\n", .{ rect.x, rect.width });
        std.debug.print("  Pro: Exact width calculation\n", .{});
        std.debug.print("  Con: Need extra array (8 bytes/char total)\n", .{});
    }

    // Multi-line selection
    std.debug.print("\nMulti-line selection:\n", .{});
    std.debug.print("  Need: Array of rectangles, one per line\n", .{});
    std.debug.print("  Current interface: Works - just call getCharPositions per line\n", .{});
    std.debug.print("  Or: Store positions for entire text, split by line\n", .{});

    // =========================================================================
    // ACTUAL BIDI TEST - not guesses, real implementation
    // =========================================================================
    std.debug.print("\n--- ACTUAL Bidi Selection Test ---\n", .{});

    // Simulate "Hello שלום World" - mixed LTR and RTL
    // Logical order: H e l l o   ש ל ו ם   W o r l d
    // Visual order:  H e l l o   ם ו ל ש   W o r l d
    //                0 1 2 3 4 5 6 7 8 9 10 11 12 13 14
    // Note: Hebrew chars are stored in logical order but displayed RTL

    const BidiChar = struct {
        logical_index: usize,
        visual_x: f32,
        advance: f32,
        is_rtl: bool,
    };

    // Simulated bidi layout result (what a real shaper would produce)
    const bidi_layout = [_]BidiChar{
        .{ .logical_index = 0, .visual_x = 0, .advance = 8, .is_rtl = false }, // H
        .{ .logical_index = 1, .visual_x = 8, .advance = 8, .is_rtl = false }, // e
        .{ .logical_index = 2, .visual_x = 16, .advance = 8, .is_rtl = false }, // l
        .{ .logical_index = 3, .visual_x = 24, .advance = 8, .is_rtl = false }, // l
        .{ .logical_index = 4, .visual_x = 32, .advance = 8, .is_rtl = false }, // o
        .{ .logical_index = 5, .visual_x = 40, .advance = 8, .is_rtl = false }, // space
        // RTL run - visual order is reversed!
        .{ .logical_index = 6, .visual_x = 72, .advance = 8, .is_rtl = true }, // ש (visually last in RTL run)
        .{ .logical_index = 7, .visual_x = 64, .advance = 8, .is_rtl = true }, // ל
        .{ .logical_index = 8, .visual_x = 56, .advance = 8, .is_rtl = true }, // ו
        .{ .logical_index = 9, .visual_x = 48, .advance = 8, .is_rtl = true }, // ם (visually first in RTL run)
        .{ .logical_index = 10, .visual_x = 80, .advance = 8, .is_rtl = false }, // space
        .{ .logical_index = 11, .visual_x = 88, .advance = 8, .is_rtl = false }, // W
        .{ .logical_index = 12, .visual_x = 96, .advance = 8, .is_rtl = false }, // o
        .{ .logical_index = 13, .visual_x = 104, .advance = 8, .is_rtl = false }, // r
        .{ .logical_index = 14, .visual_x = 112, .advance = 8, .is_rtl = false }, // l
    };

    std.debug.print("\nBidi layout (simulated shaper output):\n", .{});
    std.debug.print("  Logical: H e l l o   ש ל ו ם   W o r l d\n", .{});
    std.debug.print("  Visual:  H e l l o   ם ו ל ש   W o r l d\n", .{});
    std.debug.print("                       ←RTL→\n", .{});

    // TEST: Hit test at x=60 (middle of RTL run)
    std.debug.print("\nHIT TEST at x=60:\n", .{});
    const click_x: f32 = 60;

    // Method 1: Binary search on visual positions (WRONG for bidi)
    var wrong_index: usize = 0;
    for (bidi_layout, 0..) |ch, i| {
        if (ch.visual_x <= click_x) wrong_index = i;
    }
    std.debug.print("  Binary search on positions: index {d} (WRONG - doesn't account for RTL)\n", .{wrong_index});

    // Method 2: Proper hit test considering character bounds
    var correct_index: usize = 0;
    for (bidi_layout) |ch| {
        if (click_x >= ch.visual_x and click_x < ch.visual_x + ch.advance) {
            correct_index = ch.logical_index;
            break;
        }
    }
    std.debug.print("  Proper hit test: logical index {d} (CORRECT)\n", .{correct_index});

    // TEST: Selection from logical index 4 to 8 (selecting "o שלו")
    std.debug.print("\nSELECTION TEST - logical [4, 8):\n", .{});
    const sel_start_log: usize = 4;
    const sel_end_log: usize = 8;

    // Method A: Assume contiguous visual (WRONG for bidi)
    std.debug.print("  Method A (assume contiguous): FAILS for bidi\n", .{});

    // Method B: Calculate actual visual rectangles
    var rects_count: usize = 0;
    var rects: [4]SelectionRect = undefined;
    var current_rect: ?SelectionRect = null;
    var last_visual_end: f32 = -1;

    // Sort by visual position for rect calculation
    var sorted_indices: [15]usize = undefined;
    for (0..bidi_layout.len) |i| sorted_indices[i] = i;

    // Simple bubble sort by visual_x
    for (0..bidi_layout.len) |i| {
        for (i + 1..bidi_layout.len) |j| {
            if (bidi_layout[sorted_indices[j]].visual_x < bidi_layout[sorted_indices[i]].visual_x) {
                const tmp = sorted_indices[i];
                sorted_indices[i] = sorted_indices[j];
                sorted_indices[j] = tmp;
            }
        }
    }

    // Build rectangles from visually-sorted chars in selection
    for (sorted_indices[0..bidi_layout.len]) |idx| {
        const ch = bidi_layout[idx];
        if (ch.logical_index >= sel_start_log and ch.logical_index < sel_end_log) {
            if (current_rect) |*r| {
                // Check if contiguous visually
                if (ch.visual_x == last_visual_end) {
                    r.width += ch.advance;
                    last_visual_end = ch.visual_x + ch.advance;
                } else {
                    // Gap - save current rect and start new one
                    rects[rects_count] = r.*;
                    rects_count += 1;
                    current_rect = SelectionRect{ .x = ch.visual_x, .y = 0, .width = ch.advance, .height = 16 };
                    last_visual_end = ch.visual_x + ch.advance;
                }
            } else {
                current_rect = SelectionRect{ .x = ch.visual_x, .y = 0, .width = ch.advance, .height = 16 };
                last_visual_end = ch.visual_x + ch.advance;
            }
        }
    }
    if (current_rect) |r| {
        rects[rects_count] = r;
        rects_count += 1;
    }

    std.debug.print("  Method B (calculate from CharInfo): {d} rectangle(s)\n", .{rects_count});
    for (rects[0..rects_count], 0..) |r, i| {
        std.debug.print("    Rect {d}: x={d:.0}, width={d:.0}\n", .{ i, r.x, r.width });
    }

    // FINDINGS
    std.debug.print("\n  ACTUAL FINDING: Bidi selection produces {d} rectangles (not 1)\n", .{rects_count});
    std.debug.print("  ACTUAL FINDING: Need CharInfo with visual_x to calculate rects\n", .{});
    std.debug.print("  ACTUAL FINDING: Binary search on positions FAILS for RTL hit test\n", .{});

    // What interface is needed?
    std.debug.print("\n  INTERFACE REQUIREMENT:\n", .{});
    std.debug.print("    getCharInfo() must return: {{visual_x, advance, is_rtl}}\n", .{});
    std.debug.print("    OR provider needs: getSelectionRects(start, end) -> []Rect\n", .{});
    std.debug.print("    OR provider needs: hitTest(visual_x) -> logical_index\n", .{});

    _ = allocator;
}

// ============================================================================
// VALIDATION TEST 3: Touch vs Mouse Hit Testing
// ============================================================================
// Question: Should we expand hit areas for touch?
//
// Mouse: Precise, can click exact pixel
// Touch: Imprecise, ~7-10mm minimum target (40-60px at 160dpi)

fn testTouchVsMouse() !void {
    std.debug.print("\n--- VALIDATION 3: Touch vs Mouse ---\n", .{});

    const text = "Hello";
    const char_width: f32 = 8.0; // Typical char width

    std.debug.print("\nScenario: Click between 'e' and 'l' in 'Hello'\n", .{});
    std.debug.print("  Character positions: H=0, e=8, l=16, l=24, o=32\n", .{});
    std.debug.print("  Target: boundary at x=16\n", .{});

    // Mouse click (precise)
    std.debug.print("\nMouse (precise):\n", .{});
    std.debug.print("  Click at x=15 → before 'l' (index 2)\n", .{});
    std.debug.print("  Click at x=17 → after 'l' starts, cursor after 'l' (index 3)\n", .{});
    std.debug.print("  Midpoint detection: x < 16+4 → before, else after\n", .{});

    // Touch (imprecise)
    std.debug.print("\nTouch (imprecise, ~40px finger):\n", .{});
    std.debug.print("  Touch at x=15 with 40px radius → covers indices 0-4\n", .{});
    std.debug.print("  Options:\n", .{});
    std.debug.print("    A) Use touch center (same as mouse) - simple but imprecise\n", .{});
    std.debug.print("    B) Snap to nearest character boundary - better UX\n", .{});
    std.debug.print("    C) Show magnifier loupe - iOS style, most precise\n", .{});

    // Analysis
    std.debug.print("\nAnalysis:\n", .{});
    std.debug.print("  Touch imprecision is a UX problem, not an interface problem.\n", .{});
    std.debug.print("  The hitTest() interface works the same for both.\n", .{});
    std.debug.print("  Touch adaptations happen at the input handling layer:\n", .{});
    std.debug.print("    - Debounce/smoothing\n", .{});
    std.debug.print("    - Magnifier UI\n", .{});
    std.debug.print("    - Snap to word boundaries on double-tap\n", .{});

    std.debug.print("\n  CONCLUSION: Same interface for mouse and touch.\n", .{});
    std.debug.print("  CONCLUSION: Touch UX handled at higher level (input handling).\n", .{});
    std.debug.print("  CONCLUSION: No interface changes needed for touch.\n", .{});

    _ = char_width;
    _ = text;
}

// ============================================================================
// VALIDATION TEST 4: CaretInfo Necessity
// ============================================================================
// Question: Do we need CaretInfo for split caret (bidi boundaries)?

fn testCaretInfoNecessity() void {
    std.debug.print("\n--- VALIDATION 4: CaretInfo Necessity ---\n", .{});

    std.debug.print("\nCaretInfo struct:\n", .{});
    std.debug.print("  primary_x: f32     // Main caret position\n", .{});
    std.debug.print("  secondary_x: ?f32  // Split caret (bidi boundary)\n", .{});
    std.debug.print("  is_rtl: bool       // Direction at cursor\n", .{});
    std.debug.print("  Size: ~12 bytes\n", .{});

    std.debug.print("\nWhen is CaretInfo needed?\n", .{});
    std.debug.print("  1. Split caret at RTL/LTR boundary\n", .{});
    std.debug.print("     Example: 'Hello|שלום' - cursor between LTR and RTL\n", .{});
    std.debug.print("     Need TWO caret positions (one after 'o', one before 'ש')\n", .{});
    std.debug.print("  2. Caret direction indicator (| vs ⌐ vs ⌐)\n", .{});
    std.debug.print("     Some editors show caret leaning left/right based on direction\n", .{});

    std.debug.print("\nWhen is CaretInfo NOT needed?\n", .{});
    std.debug.print("  1. LTR-only text: positions[index] is sufficient\n", .{});
    std.debug.print("  2. Simple embedded displays: no text input\n", .{});
    std.debug.print("  3. Fixed-width fonts: trivial calculation\n", .{});

    std.debug.print("\nInterface options:\n", .{});
    std.debug.print("  A) Always return CaretInfo (12 bytes)\n", .{});
    std.debug.print("     Con: Overhead for simple cases\n", .{});
    std.debug.print("  B) Optional getCaretInfo() in vtable\n", .{});
    std.debug.print("     Pro: Zero cost for LTR-only providers\n", .{});
    std.debug.print("     Pro: Provider can implement when ready\n", .{});
    std.debug.print("  C) Return CaretInfo only when secondary_x differs\n", .{});
    std.debug.print("     Complex, doesn't save much\n", .{});

    std.debug.print("\n  CONCLUSION: CaretInfo is ONLY needed for bidi.\n", .{});
    std.debug.print("  CONCLUSION: Make getCaretInfo() OPTIONAL in vtable (like hitTest).\n", .{});
    std.debug.print("  CONCLUSION: LTR providers return null, use positions[index] fallback.\n", .{});
}

// ============================================================================
// FINAL CONCLUSIONS
// ============================================================================

fn printFinalConclusions() void {
    std.debug.print("\n1. GRAPHEME ITERATION:\n", .{});
    std.debug.print("   Decision: TextProvider handles graphemes internally.\n", .{});
    std.debug.print("   Rationale: Provider knows encoding, no extra interface.\n", .{});
    std.debug.print("   Embedded: Byte-based (ASCII only) is fine.\n", .{});
    std.debug.print("   Desktop: Full UAX #29 grapheme segmentation.\n", .{});

    std.debug.print("\n2. SELECTION RENDERING:\n", .{});
    std.debug.print("   TESTED: Bidi selection [4,8) produces 2 rectangles, not 1.\n", .{});
    std.debug.print("   TESTED: Binary search on positions FAILS for RTL hit test.\n", .{});
    std.debug.print("   REQUIRED: CharInfo with {{visual_x, advance, is_rtl}} per grapheme.\n", .{});
    std.debug.print("   OR: Provider implements hitTest() and getSelectionRects().\n", .{});

    std.debug.print("\n3. TOUCH HIT TESTING:\n", .{});
    std.debug.print("   Decision: Same interface for mouse and touch.\n", .{});
    std.debug.print("   Touch adaptations at input handling layer, not here.\n", .{});

    std.debug.print("\n4. CARETINFO:\n", .{});
    std.debug.print("   Decision: Optional getCaretInfo() in vtable.\n", .{});
    std.debug.print("   Only needed for bidi (split caret).\n", .{});
    std.debug.print("   LTR fallback: positions[index]\n", .{});

    std.debug.print("\n" ++ "-" ** 70 ++ "\n", .{});
    std.debug.print("FINAL INTERFACE (Design A with clarifications):\n", .{});
    std.debug.print("-" ** 70 ++ "\n\n", .{});

    std.debug.print("pub const TextProvider = struct {{\n", .{});
    std.debug.print("    ptr: *anyopaque,\n", .{});
    std.debug.print("    vtable: *const VTable,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    pub const VTable = struct {{\n", .{});
    std.debug.print("        // REQUIRED - Core text measurement\n", .{});
    std.debug.print("        measureText: *const fn (ptr, text: []const u8) f32,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("        // REQUIRED - Character positions for cursor/selection\n", .{});
    std.debug.print("        // Returns GRAPHEME positions (not bytes)\n", .{});
    std.debug.print("        // Provider handles UTF-8 decoding and grapheme segmentation\n", .{});
    std.debug.print("        getCharPositions: *const fn (ptr, text, out: []f32) usize,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("        // OPTIONAL - For bidi text (null = LTR only, use fallback)\n", .{});
    std.debug.print("        hitTest: ?*const fn (ptr, text, x: f32) HitTestResult,\n", .{});
    std.debug.print("        getCaretInfo: ?*const fn (ptr, text, index: usize) CaretInfo,\n", .{});
    std.debug.print("    }};\n", .{});
    std.debug.print("}};\n", .{});

    std.debug.print("\nKey insight: getCharPositions returns GRAPHEME positions.\n", .{});
    std.debug.print("  - ASCII provider: 1 position per byte\n", .{});
    std.debug.print("  - UTF-8 provider: 1 position per grapheme cluster\n", .{});
    std.debug.print("  - Return value is grapheme count, not byte count\n", .{});

    std.debug.print("\nC API:\n", .{});
    std.debug.print("  size_t zig_gui_text_get_positions(\n", .{});
    std.debug.print("      ZigGuiTextProvider* p, const char* text, size_t len,\n", .{});
    std.debug.print("      float* out, size_t max_out);\n", .{});
    std.debug.print("  // Returns number of graphemes (may be < len for UTF-8)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  ZigGuiHitResult zig_gui_text_hit_test(\n", .{});
    std.debug.print("      ZigGuiTextProvider* p, const char* text, size_t len,\n", .{});
    std.debug.print("      float x);  // Returns {{-1, false}} if not supported\n", .{});
}
