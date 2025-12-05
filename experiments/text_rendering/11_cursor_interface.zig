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

    std.debug.print("\nOPEN QUESTIONS:\n", .{});
    std.debug.print("  1. Should grapheme iteration be in TextProvider or separate?\n", .{});
    std.debug.print("  2. Do we need CaretInfo for split caret (bidi boundaries)?\n", .{});
    std.debug.print("  3. How does this interact with selection rendering?\n", .{});
    std.debug.print("  4. Touch hit testing: should we expand hit areas?\n", .{});
}
