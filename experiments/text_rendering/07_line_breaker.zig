//! Experiment 7: Line Breaking Interface (BYOL)
//!
//! Goal: Validate the "Bring Your Own Line Breaker" design pattern.
//!
//! Key insight: Line breaking complexity varies wildly:
//!   - Embedded: ASCII spaces only (~50 lines of code)
//!   - Desktop Latin: Word boundaries + hyphenation
//!   - Desktop i18n: UAX #14 (40+ page Unicode spec)
//!   - Platform-native: ICU, macOS CTLine, Win32 Uniscribe
//!
//! Like BYOR (rendering) and BYOT (text), line breaking should be pluggable.
//!
//! Run:
//!   zig run experiments/text_rendering/07_line_breaker.zig

const std = @import("std");

// ============================================================================
// LineBreaker Interface (BYOL)
// ============================================================================

pub const LineBreaker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Find valid break positions in text.
        /// Returns indices where breaks are allowed (after the character at that index).
        /// Caller provides output buffer (zero allocation in hot path).
        findBreakPoints: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            out_breaks: []BreakPoint,
        ) usize,
    };

    /// A position where a line break is allowed or required
    pub const BreakPoint = struct {
        /// Byte offset in text (break allowed AFTER this index)
        index: u32,
        /// Type of break opportunity
        kind: BreakKind,
    };

    pub const BreakKind = enum(u8) {
        /// Mandatory break (newline, paragraph separator)
        mandatory,
        /// Word boundary (space, tab)
        word,
        /// Soft hyphen or hyphenation opportunity
        hyphen,
        /// CJK ideograph boundary (can break between any two)
        ideograph,
        /// Emergency break (anywhere, last resort)
        emergency,
    };

    // Convenience wrapper
    pub fn findBreakPoints(self: LineBreaker, text: []const u8, out: []BreakPoint) usize {
        return self.vtable.findBreakPoints(self.ptr, text, out);
    }
};

// ============================================================================
// SimpleBreaker - Built-in ASCII/Latin word breaker
// ============================================================================

/// Minimal line breaker for ASCII/Latin text.
/// Breaks on spaces, tabs, and newlines. No hyphenation.
/// ~50 lines of code, suitable for embedded.
pub const SimpleBreaker = struct {
    const Self = @This();

    // Stateless - no fields needed
    pub fn interface() LineBreaker {
        return .{
            .ptr = undefined, // Not used - stateless
            .vtable = &vtable,
        };
    }

    const vtable = LineBreaker.VTable{
        .findBreakPoints = findBreaksImpl,
    };

    fn findBreaksImpl(_: *anyopaque, text: []const u8, out: []LineBreaker.BreakPoint) usize {
        var count: usize = 0;

        for (text, 0..) |char, i| {
            if (count >= out.len) break;

            switch (char) {
                '\n' => {
                    out[count] = .{
                        .index = @intCast(i),
                        .kind = .mandatory,
                    };
                    count += 1;
                },
                ' ', '\t' => {
                    out[count] = .{
                        .index = @intCast(i),
                        .kind = .word,
                    };
                    count += 1;
                },
                else => {},
            }
        }

        return count;
    }
};

// ============================================================================
// GreedyBreaker - Adds basic CJK support
// ============================================================================

/// Extended line breaker with CJK ideograph support.
/// Still simple, but handles more cases than SimpleBreaker.
pub const GreedyBreaker = struct {
    const Self = @This();

    pub fn interface() LineBreaker {
        return .{
            .ptr = undefined,
            .vtable = &vtable,
        };
    }

    const vtable = LineBreaker.VTable{
        .findBreakPoints = findBreaksImpl,
    };

    fn findBreaksImpl(_: *anyopaque, text: []const u8, out: []LineBreaker.BreakPoint) usize {
        var count: usize = 0;
        var i: usize = 0;

        while (i < text.len) {
            if (count >= out.len) break;

            const char = text[i];

            // ASCII fast path
            if (char < 0x80) {
                switch (char) {
                    '\n' => {
                        out[count] = .{ .index = @intCast(i), .kind = .mandatory };
                        count += 1;
                    },
                    ' ', '\t' => {
                        out[count] = .{ .index = @intCast(i), .kind = .word };
                        count += 1;
                    },
                    // Punctuation that allows break after
                    ',', '.', ';', ':', '!', '?', ')', ']', '}' => {
                        out[count] = .{ .index = @intCast(i), .kind = .word };
                        count += 1;
                    },
                    else => {},
                }
                i += 1;
                continue;
            }

            // UTF-8 decode for CJK detection
            const codepoint = decodeUtf8(text[i..]) orelse {
                i += 1;
                continue;
            };

            // CJK Unified Ideographs and common ranges
            if (isCjkIdeograph(codepoint.value)) {
                out[count] = .{ .index = @intCast(i), .kind = .ideograph };
                count += 1;
            }

            i += codepoint.len;
        }

        return count;
    }

    const Codepoint = struct { value: u21, len: u3 };

    fn decodeUtf8(bytes: []const u8) ?Codepoint {
        if (bytes.len == 0) return null;

        const first = bytes[0];
        if (first < 0x80) {
            return .{ .value = first, .len = 1 };
        } else if (first & 0xE0 == 0xC0 and bytes.len >= 2) {
            return .{
                .value = (@as(u21, first & 0x1F) << 6) | (bytes[1] & 0x3F),
                .len = 2,
            };
        } else if (first & 0xF0 == 0xE0 and bytes.len >= 3) {
            return .{
                .value = (@as(u21, first & 0x0F) << 12) |
                    (@as(u21, bytes[1] & 0x3F) << 6) |
                    (bytes[2] & 0x3F),
                .len = 3,
            };
        } else if (first & 0xF8 == 0xF0 and bytes.len >= 4) {
            return .{
                .value = (@as(u21, first & 0x07) << 18) |
                    (@as(u21, bytes[1] & 0x3F) << 12) |
                    (@as(u21, bytes[2] & 0x3F) << 6) |
                    (bytes[3] & 0x3F),
                .len = 4,
            };
        }
        return null;
    }

    fn isCjkIdeograph(cp: u21) bool {
        // CJK Unified Ideographs
        if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
        // CJK Extension A
        if (cp >= 0x3400 and cp <= 0x4DBF) return true;
        // Hiragana
        if (cp >= 0x3040 and cp <= 0x309F) return true;
        // Katakana
        if (cp >= 0x30A0 and cp <= 0x30FF) return true;
        // Hangul Syllables
        if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
        return false;
    }
};

// ============================================================================
// Mock TextProvider for testing word wrap
// ============================================================================

const MockTextMetrics = struct {
    width: f32,
    height: f32,
};

/// Simple mock that assumes monospace 10px per character
fn mockMeasureText(text: []const u8) MockTextMetrics {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * 10.0,
        .height = 16.0,
    };
}

// ============================================================================
// Word Wrap Algorithm using LineBreaker
// ============================================================================

pub const Line = struct {
    start: usize,
    end: usize,
    width: f32,
};

/// Wrap text to fit within max_width.
/// Uses LineBreaker to find valid break points.
/// Uses measureSegment to measure text width.
pub fn wrapText(
    text: []const u8,
    max_width: f32,
    line_breaker: LineBreaker,
    measureSegment: *const fn ([]const u8) MockTextMetrics,
    out_lines: []Line,
) usize {
    if (text.len == 0) return 0;

    // Get all break points
    var breaks: [1024]LineBreaker.BreakPoint = undefined;
    const break_count = line_breaker.findBreakPoints(text, &breaks);

    var line_count: usize = 0;
    var line_start: usize = 0;
    var last_break: usize = 0;
    var last_break_width: f32 = 0;

    var break_idx: usize = 0;

    while (break_idx <= break_count and line_count < out_lines.len) {
        // Determine the end of current segment
        const segment_end = if (break_idx < break_count)
            breaks[break_idx].index + 1 // Include the break character
        else
            text.len;

        const segment = text[line_start..segment_end];
        const metrics = measureSegment(segment);

        // Check if this segment fits
        if (metrics.width <= max_width) {
            // Fits - remember this as a valid break point
            if (break_idx < break_count) {
                last_break = segment_end;
                last_break_width = metrics.width;

                // Mandatory break forces new line
                if (breaks[break_idx].kind == .mandatory) {
                    out_lines[line_count] = .{
                        .start = line_start,
                        .end = last_break,
                        .width = last_break_width,
                    };
                    line_count += 1;
                    line_start = last_break;
                    last_break = line_start;
                    last_break_width = 0;
                }
            }
            break_idx += 1;
        } else {
            // Doesn't fit - break at last valid point
            if (last_break > line_start) {
                out_lines[line_count] = .{
                    .start = line_start,
                    .end = last_break,
                    .width = last_break_width,
                };
                line_count += 1;
                line_start = last_break;
                // Skip whitespace at start of new line
                while (line_start < text.len and (text[line_start] == ' ' or text[line_start] == '\t')) {
                    line_start += 1;
                }
                last_break = line_start;
                last_break_width = 0;
                // Don't advance break_idx - retry with new line_start
            } else {
                // No valid break point - emergency break
                // In real impl, would break mid-word
                break_idx += 1;
            }
        }
    }

    // Add final line if there's remaining text
    if (line_start < text.len and line_count < out_lines.len) {
        const final_segment = text[line_start..];
        const metrics = measureSegment(final_segment);
        out_lines[line_count] = .{
            .start = line_start,
            .end = text.len,
            .width = metrics.width,
        };
        line_count += 1;
    }

    return line_count;
}

// ============================================================================
// Tests and Demonstrations
// ============================================================================

fn demonstrateSimpleBreaker() void {
    std.debug.print("\n=== SimpleBreaker Demo ===\n\n", .{});

    const breaker = SimpleBreaker.interface();
    const text = "The quick brown fox jumps over the lazy dog.";

    var breaks: [64]LineBreaker.BreakPoint = undefined;
    const count = breaker.findBreakPoints(text, &breaks);

    std.debug.print("Text: \"{s}\"\n", .{text});
    std.debug.print("Found {} break points:\n", .{count});

    for (breaks[0..count], 0..) |bp, i| {
        const kind_str = switch (bp.kind) {
            .mandatory => "mandatory",
            .word => "word",
            .hyphen => "hyphen",
            .ideograph => "ideograph",
            .emergency => "emergency",
        };
        std.debug.print("  [{d}] index={d} ({c}) kind={s}\n", .{
            i,
            bp.index,
            text[bp.index],
            kind_str,
        });
    }
}

fn demonstrateGreedyBreaker() void {
    std.debug.print("\n=== GreedyBreaker Demo (with CJK) ===\n\n", .{});

    const breaker = GreedyBreaker.interface();

    // Mixed English and Japanese
    const text = "Hello \xe4\xb8\x96\xe7\x95\x8c! This is \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e.";

    var breaks: [64]LineBreaker.BreakPoint = undefined;
    const count = breaker.findBreakPoints(text, &breaks);

    std.debug.print("Text: \"{s}\"\n", .{text});
    std.debug.print("Found {} break points:\n", .{count});

    for (breaks[0..count]) |bp| {
        const kind_str = switch (bp.kind) {
            .mandatory => "mandatory",
            .word => "word",
            .hyphen => "hyphen",
            .ideograph => "ideograph",
            .emergency => "emergency",
        };
        std.debug.print("  index={d} kind={s}\n", .{ bp.index, kind_str });
    }
}

fn demonstrateWordWrap() void {
    std.debug.print("\n=== Word Wrap Demo ===\n\n", .{});

    const breaker = SimpleBreaker.interface();
    const text = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.";

    const widths = [_]f32{ 200, 150, 100 };

    for (widths) |max_width| {
        std.debug.print("Max width: {d}px (monospace 10px/char = {d} chars)\n", .{
            max_width,
            @as(u32, @intFromFloat(max_width / 10)),
        });

        var lines: [32]Line = undefined;
        const line_count = wrapText(text, max_width, breaker, mockMeasureText, &lines);

        for (lines[0..line_count], 0..) |line, i| {
            const line_text = text[line.start..line.end];
            std.debug.print("  Line {d}: \"{s}\" (width={d:.0})\n", .{
                i,
                line_text,
                line.width,
            });
        }
        std.debug.print("\n", .{});
    }
}

fn demonstrateMandatoryBreaks() void {
    std.debug.print("\n=== Mandatory Breaks Demo ===\n\n", .{});

    const breaker = SimpleBreaker.interface();
    const text = "Line one\nLine two\nLine three";

    var lines: [32]Line = undefined;
    const line_count = wrapText(text, 500, breaker, mockMeasureText, &lines);

    std.debug.print("Text with newlines:\n", .{});
    for (lines[0..line_count], 0..) |line, i| {
        const line_text = text[line.start..line.end];
        std.debug.print("  Line {d}: \"{s}\"\n", .{ i, line_text });
    }
}

fn benchmarkLineBreaker() void {
    std.debug.print("\n=== Performance Benchmark ===\n\n", .{});

    const simple = SimpleBreaker.interface();
    const greedy = GreedyBreaker.interface();

    const text = "The quick brown fox jumps over the lazy dog. " ** 10;
    var breaks: [1024]LineBreaker.BreakPoint = undefined;

    const iterations = 100_000;

    // Benchmark SimpleBreaker
    {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..iterations) |_| {
            _ = simple.findBreakPoints(text, &breaks);
        }
        const elapsed = timer.read();
        std.debug.print("SimpleBreaker: {} ns/call ({} chars)\n", .{
            elapsed / iterations,
            text.len,
        });
    }

    // Benchmark GreedyBreaker
    {
        var timer = std.time.Timer.start() catch unreachable;
        for (0..iterations) |_| {
            _ = greedy.findBreakPoints(text, &breaks);
        }
        const elapsed = timer.read();
        std.debug.print("GreedyBreaker: {} ns/call ({} chars)\n", .{
            elapsed / iterations,
            text.len,
        });
    }

    // Benchmark word wrap
    {
        var lines: [64]Line = undefined;
        var timer = std.time.Timer.start() catch unreachable;
        for (0..iterations) |_| {
            _ = wrapText(text, 200, simple, mockMeasureText, &lines);
        }
        const elapsed = timer.read();
        std.debug.print("wrapText (200px): {} ns/call\n", .{elapsed / iterations});
    }
}

fn analyzeMemory() void {
    std.debug.print("\n=== Memory Analysis ===\n\n", .{});

    std.debug.print("LineBreaker.BreakPoint: {} bytes\n", .{@sizeOf(LineBreaker.BreakPoint)});
    std.debug.print("LineBreaker.VTable: {} bytes\n", .{@sizeOf(LineBreaker.VTable)});
    std.debug.print("LineBreaker: {} bytes\n", .{@sizeOf(LineBreaker)});
    std.debug.print("Line: {} bytes\n", .{@sizeOf(Line)});

    std.debug.print("\nBuffer sizing for typical use:\n", .{});
    std.debug.print("  64 break points: {} bytes\n", .{64 * @sizeOf(LineBreaker.BreakPoint)});
    std.debug.print("  32 lines: {} bytes\n", .{32 * @sizeOf(Line)});
    std.debug.print("  Total stack usage: {} bytes\n", .{
        64 * @sizeOf(LineBreaker.BreakPoint) + 32 * @sizeOf(Line),
    });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("Experiment 7: Line Breaking Interface (BYOL)\n", .{});
    std.debug.print("=============================================\n", .{});

    demonstrateSimpleBreaker();
    demonstrateGreedyBreaker();
    demonstrateWordWrap();
    demonstrateMandatoryBreaks();
    benchmarkLineBreaker();
    analyzeMemory();

    std.debug.print("\n=== Conclusions ===\n\n", .{});
    std.debug.print("1. BYOL pattern works - interface is minimal (1 function)\n", .{});
    std.debug.print("2. SimpleBreaker covers ASCII/Latin (~50 lines)\n", .{});
    std.debug.print("3. GreedyBreaker adds CJK support (~150 lines)\n", .{});
    std.debug.print("4. wrapText() composes LineBreaker + TextProvider cleanly\n", .{});
    std.debug.print("5. Zero allocation in hot path - caller provides buffers\n", .{});
    std.debug.print("6. Users can bring UAX #14, ICU, or platform implementations\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "SimpleBreaker finds spaces" {
    const breaker = SimpleBreaker.interface();
    var breaks: [16]LineBreaker.BreakPoint = undefined;

    const count = breaker.findBreakPoints("hello world", &breaks);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u32, 5), breaks[0].index);
    try std.testing.expectEqual(LineBreaker.BreakKind.word, breaks[0].kind);
}

test "SimpleBreaker finds newlines" {
    const breaker = SimpleBreaker.interface();
    var breaks: [16]LineBreaker.BreakPoint = undefined;

    const count = breaker.findBreakPoints("line1\nline2", &breaks);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(LineBreaker.BreakKind.mandatory, breaks[0].kind);
}

test "wrapText respects max width" {
    const breaker = SimpleBreaker.interface();
    var lines: [16]Line = undefined;

    // "hello world" with 10px/char = 110px total
    // Max 60px should break into 2 lines
    const count = wrapText("hello world", 60, breaker, mockMeasureText, &lines);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "wrapText handles mandatory breaks" {
    const breaker = SimpleBreaker.interface();
    var lines: [16]Line = undefined;

    const count = wrapText("a\nb", 1000, breaker, mockMeasureText, &lines);
    try std.testing.expectEqual(@as(usize, 2), count);
}
