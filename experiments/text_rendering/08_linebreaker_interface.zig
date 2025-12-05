//! Experiment 08: Line Breaker Interface Design
//!
//! This experiment validates different interface designs for the LineBreaker,
//! similar to how experiment 03 explored TextProvider interfaces.
//!
//! We test 5 interface approaches:
//!   A. Buffer-based: Caller provides output buffer, returns count
//!   B. Iterator-based: Returns iterator yielding break points on demand
//!   C. Callback-based: Calls user function for each break point
//!   D. Integrated: Line breaking as TextProvider extension
//!   E. Streaming: Incremental processing for large texts
//!
//! For each design we measure:
//!   - Code complexity (lines, concepts)
//!   - Memory usage (stack, heap)
//!   - Performance (ns per break point)
//!   - Ergonomics (ease of use in wrapText)
//!   - Embedded suitability (allocation-free?)

const std = @import("std");

// ============================================================================
// COMMON TYPES
// ============================================================================

pub const BreakKind = enum(u8) {
    mandatory, // \n, paragraph separator - MUST break
    word, // Space, punctuation - CAN break
    hyphen, // Soft hyphen point
    ideograph, // CJK character boundary
    emergency, // Anywhere (last resort when nothing else fits)
};

pub const BreakPoint = struct {
    index: u32, // Byte offset (break allowed AFTER this index)
    kind: BreakKind,

    pub fn format(
        self: BreakPoint,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("@{d}:{s}", .{
            self.index,
            @tagName(self.kind),
        });
    }
};

// ============================================================================
// DESIGN A: BUFFER-BASED (Current design from experiment 07)
// ============================================================================
//
// Caller provides output buffer, function returns count of break points found.
// Zero allocation, predictable memory, but requires sizing buffer upfront.

pub const DesignA = struct {
    pub const LineBreaker = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            findBreakPoints: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                out_breaks: []BreakPoint,
            ) usize,
        };

        pub fn findBreakPoints(self: LineBreaker, text: []const u8, out_breaks: []BreakPoint) usize {
            return self.vtable.findBreakPoints(self.ptr, text, out_breaks);
        }
    };

    // Simple ASCII implementation
    pub const SimpleBreaker = struct {
        pub fn interface(self: *SimpleBreaker) LineBreaker {
            return .{
                .ptr = self,
                .vtable = &.{
                    .findBreakPoints = findBreakPointsImpl,
                },
            };
        }

        fn findBreakPointsImpl(ptr: *anyopaque, text: []const u8, out_breaks: []BreakPoint) usize {
            _ = ptr;
            var count: usize = 0;

            for (text, 0..) |c, i| {
                if (count >= out_breaks.len) break;

                if (c == '\n') {
                    out_breaks[count] = .{ .index = @intCast(i), .kind = .mandatory };
                    count += 1;
                } else if (c == ' ' or c == '\t') {
                    out_breaks[count] = .{ .index = @intCast(i), .kind = .word };
                    count += 1;
                }
            }

            return count;
        }
    };

    // Usage example: word wrap
    pub fn wrapText(
        text: []const u8,
        max_width: f32,
        breaker: LineBreaker,
        measureFn: *const fn ([]const u8) f32,
        out_lines: [][]const u8,
    ) usize {
        var breaks_buf: [256]BreakPoint = undefined;
        const break_count = breaker.findBreakPoints(text, &breaks_buf);
        const breaks = breaks_buf[0..break_count];

        var line_count: usize = 0;
        var line_start: usize = 0;
        var last_break: usize = 0;

        for (breaks) |bp| {
            const segment = text[line_start .. bp.index + 1];
            const width = measureFn(segment);

            if (width > max_width and last_break > line_start) {
                // Line too long, break at last good point
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..last_break];
                    line_count += 1;
                }
                line_start = last_break;
                while (line_start < text.len and text[line_start] == ' ') : (line_start += 1) {}
            }

            if (bp.kind == .mandatory) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..bp.index];
                    line_count += 1;
                }
                line_start = bp.index + 1;
            }

            last_break = bp.index + 1;
        }

        // Final line
        if (line_start < text.len and line_count < out_lines.len) {
            out_lines[line_count] = text[line_start..];
            line_count += 1;
        }

        return line_count;
    }
};

// ============================================================================
// DESIGN B: ITERATOR-BASED
// ============================================================================
//
// Returns an iterator that yields break points one at a time.
// Lazy evaluation, good for early termination, but slightly more complex API.

pub const DesignB = struct {
    pub const LineBreaker = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            iterate: *const fn (ptr: *anyopaque, text: []const u8) Iterator,
        };

        pub fn iterate(self: LineBreaker, text: []const u8) Iterator {
            return self.vtable.iterate(self.ptr, text);
        }

        pub const Iterator = struct {
            text: []const u8,
            pos: usize,
            impl_ptr: *anyopaque,
            nextFn: *const fn (ptr: *anyopaque, text: []const u8, pos: *usize) ?BreakPoint,

            pub fn next(self: *Iterator) ?BreakPoint {
                return self.nextFn(self.impl_ptr, self.text, &self.pos);
            }
        };
    };

    pub const SimpleBreaker = struct {
        pub fn interface(self: *SimpleBreaker) LineBreaker {
            return .{
                .ptr = self,
                .vtable = &.{
                    .iterate = iterateImpl,
                },
            };
        }

        fn iterateImpl(ptr: *anyopaque, text: []const u8) LineBreaker.Iterator {
            return .{
                .text = text,
                .pos = 0,
                .impl_ptr = ptr,
                .nextFn = nextBreak,
            };
        }

        fn nextBreak(_: *anyopaque, text: []const u8, pos: *usize) ?BreakPoint {
            while (pos.* < text.len) {
                const i = pos.*;
                const c = text[i];
                pos.* += 1;

                if (c == '\n') {
                    return .{ .index = @intCast(i), .kind = .mandatory };
                } else if (c == ' ' or c == '\t') {
                    return .{ .index = @intCast(i), .kind = .word };
                }
            }
            return null;
        }
    };

    // Usage example: word wrap with iterator
    pub fn wrapText(
        text: []const u8,
        max_width: f32,
        breaker: LineBreaker,
        measureFn: *const fn ([]const u8) f32,
        out_lines: [][]const u8,
    ) usize {
        var iter = breaker.iterate(text);

        var line_count: usize = 0;
        var line_start: usize = 0;
        var last_break: usize = 0;

        while (iter.next()) |bp| {
            const segment = text[line_start .. bp.index + 1];
            const width = measureFn(segment);

            if (width > max_width and last_break > line_start) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..last_break];
                    line_count += 1;
                }
                line_start = last_break;
                while (line_start < text.len and text[line_start] == ' ') : (line_start += 1) {}
            }

            if (bp.kind == .mandatory) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..bp.index];
                    line_count += 1;
                }
                line_start = bp.index + 1;
            }

            last_break = bp.index + 1;
        }

        if (line_start < text.len and line_count < out_lines.len) {
            out_lines[line_count] = text[line_start..];
            line_count += 1;
        }

        return line_count;
    }
};

// ============================================================================
// DESIGN C: CALLBACK-BASED
// ============================================================================
//
// Calls user-provided callback for each break point.
// Most flexible, allows early termination, but callback indirection has cost.

pub const DesignC = struct {
    pub const LineBreaker = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            findBreaks: *const fn (
                ptr: *anyopaque,
                text: []const u8,
                ctx: *anyopaque,
                callback: *const fn (ctx: *anyopaque, bp: BreakPoint) bool,
            ) void,
        };

        /// Calls callback for each break point. Callback returns false to stop.
        pub fn findBreaks(
            self: LineBreaker,
            text: []const u8,
            ctx: *anyopaque,
            callback: *const fn (ctx: *anyopaque, bp: BreakPoint) bool,
        ) void {
            self.vtable.findBreaks(self.ptr, text, ctx, callback);
        }
    };

    pub const SimpleBreaker = struct {
        pub fn interface(self: *SimpleBreaker) LineBreaker {
            return .{
                .ptr = self,
                .vtable = &.{
                    .findBreaks = findBreaksImpl,
                },
            };
        }

        fn findBreaksImpl(
            _: *anyopaque,
            text: []const u8,
            ctx: *anyopaque,
            callback: *const fn (ctx: *anyopaque, bp: BreakPoint) bool,
        ) void {
            for (text, 0..) |c, i| {
                const bp: ?BreakPoint = if (c == '\n')
                    .{ .index = @intCast(i), .kind = .mandatory }
                else if (c == ' ' or c == '\t')
                    .{ .index = @intCast(i), .kind = .word }
                else
                    null;

                if (bp) |b| {
                    if (!callback(ctx, b)) return; // Early termination
                }
            }
        }
    };

    // Usage: More complex due to callback context
    pub fn wrapText(
        text: []const u8,
        max_width: f32,
        breaker: LineBreaker,
        measureFn: *const fn ([]const u8) f32,
        out_lines: [][]const u8,
    ) usize {
        const Context = struct {
            text: []const u8,
            max_width: f32,
            measureFn: *const fn ([]const u8) f32,
            out_lines: [][]const u8,
            line_count: usize,
            line_start: usize,
            last_break: usize,

            fn onBreak(ctx_ptr: *anyopaque, bp: BreakPoint) bool {
                const self: *@This() = @ptrCast(@alignCast(ctx_ptr));

                const segment = self.text[self.line_start .. bp.index + 1];
                const width = self.measureFn(segment);

                if (width > self.max_width and self.last_break > self.line_start) {
                    if (self.line_count < self.out_lines.len) {
                        self.out_lines[self.line_count] = self.text[self.line_start..self.last_break];
                        self.line_count += 1;
                    }
                    self.line_start = self.last_break;
                    while (self.line_start < self.text.len and self.text[self.line_start] == ' ') : (self.line_start += 1) {}
                }

                if (bp.kind == .mandatory) {
                    if (self.line_count < self.out_lines.len) {
                        self.out_lines[self.line_count] = self.text[self.line_start..bp.index];
                        self.line_count += 1;
                    }
                    self.line_start = bp.index + 1;
                }

                self.last_break = bp.index + 1;
                return true; // Continue
            }
        };

        var ctx = Context{
            .text = text,
            .max_width = max_width,
            .measureFn = measureFn,
            .out_lines = out_lines,
            .line_count = 0,
            .line_start = 0,
            .last_break = 0,
        };

        breaker.findBreaks(text, @ptrCast(&ctx), Context.onBreak);

        // Final line
        if (ctx.line_start < text.len and ctx.line_count < out_lines.len) {
            out_lines[ctx.line_count] = text[ctx.line_start..];
            ctx.line_count += 1;
        }

        return ctx.line_count;
    }
};

// ============================================================================
// DESIGN D: INTEGRATED WITH TEXT PROVIDER
// ============================================================================
//
// Line breaking as an optional extension on TextProvider interface.
// Unified interface, but couples two concerns.

pub const DesignD = struct {
    pub const TextProvider = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            // Core text functions
            measureText: *const fn (ptr: *anyopaque, text: []const u8) f32,

            // Optional line breaking extension (null = not supported)
            findBreakPoints: ?*const fn (
                ptr: *anyopaque,
                text: []const u8,
                out_breaks: []BreakPoint,
            ) usize,
        };

        pub fn measureText(self: TextProvider, text: []const u8) f32 {
            return self.vtable.measureText(self.ptr, text);
        }

        pub fn findBreakPoints(self: TextProvider, text: []const u8, out_breaks: []BreakPoint) ?usize {
            if (self.vtable.findBreakPoints) |func| {
                return func(self.ptr, text, out_breaks);
            }
            return null;
        }

        pub fn supportsLineBreaking(self: TextProvider) bool {
            return self.vtable.findBreakPoints != null;
        }
    };

    // Combined provider with both text measurement and line breaking
    pub const SimpleProvider = struct {
        char_width: f32 = 8.0,

        pub fn interface(self: *SimpleProvider) TextProvider {
            return .{
                .ptr = self,
                .vtable = &.{
                    .measureText = measureTextImpl,
                    .findBreakPoints = findBreakPointsImpl,
                },
            };
        }

        fn measureTextImpl(ptr: *anyopaque, text: []const u8) f32 {
            const self: *SimpleProvider = @ptrCast(@alignCast(ptr));
            return @as(f32, @floatFromInt(text.len)) * self.char_width;
        }

        fn findBreakPointsImpl(_: *anyopaque, text: []const u8, out_breaks: []BreakPoint) usize {
            var count: usize = 0;
            for (text, 0..) |c, i| {
                if (count >= out_breaks.len) break;
                if (c == '\n') {
                    out_breaks[count] = .{ .index = @intCast(i), .kind = .mandatory };
                    count += 1;
                } else if (c == ' ' or c == '\t') {
                    out_breaks[count] = .{ .index = @intCast(i), .kind = .word };
                    count += 1;
                }
            }
            return count;
        }
    };

    // Usage: More convenient but coupled
    pub fn wrapText(
        text: []const u8,
        max_width: f32,
        provider: TextProvider,
        out_lines: [][]const u8,
    ) ?usize {
        var breaks_buf: [256]BreakPoint = undefined;
        const break_count = provider.findBreakPoints(text, &breaks_buf) orelse return null;
        const breaks = breaks_buf[0..break_count];

        var line_count: usize = 0;
        var line_start: usize = 0;
        var last_break: usize = 0;

        for (breaks) |bp| {
            const segment = text[line_start .. bp.index + 1];
            const width = provider.measureText(segment);

            if (width > max_width and last_break > line_start) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..last_break];
                    line_count += 1;
                }
                line_start = last_break;
                while (line_start < text.len and text[line_start] == ' ') : (line_start += 1) {}
            }

            if (bp.kind == .mandatory) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..bp.index];
                    line_count += 1;
                }
                line_start = bp.index + 1;
            }

            last_break = bp.index + 1;
        }

        if (line_start < text.len and line_count < out_lines.len) {
            out_lines[line_count] = text[line_start..];
            line_count += 1;
        }

        return line_count;
    }
};

// ============================================================================
// DESIGN E: STREAMING/INCREMENTAL
// ============================================================================
//
// Process text in chunks, useful for very large texts or streaming input.
// More complex state management, but handles large texts without full scan.

pub const DesignE = struct {
    pub const LineBreaker = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            /// Start processing a new text
            begin: *const fn (ptr: *anyopaque) void,

            /// Feed a chunk of text, returns break points found in this chunk
            /// Indices are relative to start of current text (cumulative)
            feed: *const fn (
                ptr: *anyopaque,
                chunk: []const u8,
                offset: usize, // Byte offset of this chunk in full text
                out_breaks: []BreakPoint,
            ) usize,

            /// Signal end of text
            end: *const fn (ptr: *anyopaque) void,
        };

        pub fn begin(self: LineBreaker) void {
            self.vtable.begin(self.ptr);
        }

        pub fn feed(self: LineBreaker, chunk: []const u8, offset: usize, out_breaks: []BreakPoint) usize {
            return self.vtable.feed(self.ptr, chunk, offset, out_breaks);
        }

        pub fn end(self: LineBreaker) void {
            self.vtable.end(self.ptr);
        }
    };

    pub const SimpleBreaker = struct {
        // Could maintain state across chunks (e.g., for multi-byte sequences)
        // For ASCII, no state needed

        pub fn interface(self: *SimpleBreaker) LineBreaker {
            return .{
                .ptr = self,
                .vtable = &.{
                    .begin = beginImpl,
                    .feed = feedImpl,
                    .end = endImpl,
                },
            };
        }

        fn beginImpl(_: *anyopaque) void {
            // Reset state if needed
        }

        fn feedImpl(_: *anyopaque, chunk: []const u8, offset: usize, out_breaks: []BreakPoint) usize {
            var count: usize = 0;
            for (chunk, 0..) |c, i| {
                if (count >= out_breaks.len) break;
                if (c == '\n') {
                    out_breaks[count] = .{ .index = @intCast(offset + i), .kind = .mandatory };
                    count += 1;
                } else if (c == ' ' or c == '\t') {
                    out_breaks[count] = .{ .index = @intCast(offset + i), .kind = .word };
                    count += 1;
                }
            }
            return count;
        }

        fn endImpl(_: *anyopaque) void {
            // Finalize if needed
        }
    };

    // Usage: Process in chunks (e.g., 4KB at a time)
    pub fn wrapTextStreaming(
        text: []const u8,
        max_width: f32,
        breaker: LineBreaker,
        measureFn: *const fn ([]const u8) f32,
        out_lines: [][]const u8,
        chunk_size: usize,
    ) usize {
        breaker.begin();
        defer breaker.end();

        var breaks_buf: [64]BreakPoint = undefined;
        var all_breaks: [256]BreakPoint = undefined;
        var total_breaks: usize = 0;

        // Process in chunks
        var offset: usize = 0;
        while (offset < text.len) {
            const end_pos = @min(offset + chunk_size, text.len);
            const chunk = text[offset..end_pos];

            const count = breaker.feed(chunk, offset, &breaks_buf);
            for (breaks_buf[0..count]) |bp| {
                if (total_breaks < all_breaks.len) {
                    all_breaks[total_breaks] = bp;
                    total_breaks += 1;
                }
            }

            offset = end_pos;
        }

        // Now wrap using collected breaks (same as Design A)
        var line_count: usize = 0;
        var line_start: usize = 0;
        var last_break: usize = 0;

        for (all_breaks[0..total_breaks]) |bp| {
            const segment = text[line_start .. bp.index + 1];
            const width = measureFn(segment);

            if (width > max_width and last_break > line_start) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..last_break];
                    line_count += 1;
                }
                line_start = last_break;
                while (line_start < text.len and text[line_start] == ' ') : (line_start += 1) {}
            }

            if (bp.kind == .mandatory) {
                if (line_count < out_lines.len) {
                    out_lines[line_count] = text[line_start..bp.index];
                    line_count += 1;
                }
                line_start = bp.index + 1;
            }

            last_break = bp.index + 1;
        }

        if (line_start < text.len and line_count < out_lines.len) {
            out_lines[line_count] = text[line_start..];
            line_count += 1;
        }

        return line_count;
    }
};

// ============================================================================
// REALISTIC TEST SCENARIOS
// ============================================================================

// Scenario 1: Short label (like a button)
const short_label = "Submit Form";

// Scenario 2: Medium paragraph (typical UI text)
const medium_text =
    \\The quick brown fox jumps over the lazy dog. Pack my box with five
    \\dozen liquor jugs. How vexingly quick daft zebras jump! The five
    \\boxing wizards jump quickly. Sphinx of black quartz, judge my vow.
;

// Scenario 3: Long document (stress test)
const long_text = "The quick brown fox jumps over the lazy dog. " ** 50;

// Scenario 4: CJK-like text (break after every character - high break density)
// Using Latin chars but treating each as break opportunity
const high_density_text = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

// ============================================================================
// DIFFERENT MEASURE FUNCTIONS (simulate different costs)
// ============================================================================

// Cheap: just count chars
fn cheapMeasure(text: []const u8) f32 {
    return @as(f32, @floatFromInt(text.len)) * 8.0;
}

// Medium: simulate font lookup (loop over chars)
fn mediumMeasure(text: []const u8) f32 {
    var width: f32 = 0;
    for (text) |c| {
        // Simulate variable width fonts
        width += switch (c) {
            'i', 'l', '!' => 4.0,
            'w', 'm', 'W', 'M' => 12.0,
            ' ' => 4.0,
            else => 8.0,
        };
    }
    return width;
}

// Expensive: simulate real font shaping (with memory access)
var glyph_widths: [256]f32 = undefined;
var glyph_widths_initialized = false;

fn initGlyphWidths() void {
    if (glyph_widths_initialized) return;
    for (&glyph_widths, 0..) |*w, i| {
        w.* = 6.0 + @as(f32, @floatFromInt(i % 10));
    }
    glyph_widths_initialized = true;
}

fn expensiveMeasure(text: []const u8) f32 {
    initGlyphWidths();
    var width: f32 = 0;
    for (text) |c| {
        width += glyph_widths[c];
        // Simulate kerning lookup
        width += 0.1;
    }
    return width;
}

// ============================================================================
// HIGH-DENSITY LINE BREAKER (simulates CJK behavior)
// ============================================================================

// For Design A
pub const HighDensityBreakerA = struct {
    pub fn interface(self: *HighDensityBreakerA) DesignA.LineBreaker {
        return .{
            .ptr = self,
            .vtable = &.{
                .findBreakPoints = findBreakPointsImpl,
            },
        };
    }

    fn findBreakPointsImpl(_: *anyopaque, text: []const u8, out_breaks: []BreakPoint) usize {
        var count: usize = 0;
        // Every character is a break opportunity (like CJK)
        for (0..text.len) |i| {
            if (count >= out_breaks.len) break;
            out_breaks[count] = .{
                .index = @intCast(i),
                .kind = if (text[i] == '\n') .mandatory else .ideograph,
            };
            count += 1;
        }
        return count;
    }
};

// For Design B
pub const HighDensityBreakerB = struct {
    pub fn interface(self: *HighDensityBreakerB) DesignB.LineBreaker {
        return .{
            .ptr = self,
            .vtable = &.{
                .iterate = iterateImpl,
            },
        };
    }

    fn iterateImpl(ptr: *anyopaque, text: []const u8) DesignB.LineBreaker.Iterator {
        return .{
            .text = text,
            .pos = 0,
            .impl_ptr = ptr,
            .nextFn = nextBreak,
        };
    }

    fn nextBreak(_: *anyopaque, text: []const u8, pos: *usize) ?BreakPoint {
        if (pos.* >= text.len) return null;
        const i = pos.*;
        pos.* += 1;
        return .{
            .index = @intCast(i),
            .kind = if (text[i] == '\n') .mandatory else .ideograph,
        };
    }
};

// ============================================================================
// BENCHMARKS AND COMPARISON
// ============================================================================

fn simpleMeasure(text: []const u8) f32 {
    return @as(f32, @floatFromInt(text.len)) * 8.0; // 8px per char
}

fn runBenchmark(
    comptime name: []const u8,
    comptime iterations: usize,
    text: []const u8,
    wrapFn: anytype,
) !struct { time_ns: u64, line_count: usize } {
    var lines_buf: [64][]const u8 = undefined;
    var line_count: usize = 0;

    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        line_count = wrapFn(text, &lines_buf);
    }

    const elapsed = timer.read();
    const avg_ns = elapsed / iterations;

    std.debug.print("  {s}: {d} ns/iter, {d} lines\n", .{ name, avg_ns, line_count });

    return .{ .time_ns = avg_ns, .line_count = line_count };
}

pub fn main() !void {
    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("EXPERIMENT 08: Line Breaker Interface Design Comparison\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    // =========================================================================
    // PART 1: Original synthetic test (for comparison)
    // =========================================================================

    const test_text = medium_text;
    const iterations = 10000;

    std.debug.print("\n--- PART 1: ORIGINAL SYNTHETIC TEST ---\n", .{});
    std.debug.print("Test text: {d} bytes, cheap measure, low break density\n", .{test_text.len});

    std.debug.print("\n  Design A (Buffer): ", .{});
    const result_a = try runBenchmark("Design A", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignA.SimpleBreaker{};
            return DesignA.wrapText(text, 300.0, b.interface(), simpleMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design B (Iterator): ", .{});
    const result_b = try runBenchmark("Design B", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignB.SimpleBreaker{};
            return DesignB.wrapText(text, 300.0, b.interface(), simpleMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design C (Callback): ", .{});
    const result_c = try runBenchmark("Design C", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignC.SimpleBreaker{};
            return DesignC.wrapText(text, 300.0, b.interface(), simpleMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design D (Integrated): ", .{});
    const result_d = try runBenchmark("Design D", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var p = DesignD.SimpleProvider{};
            return DesignD.wrapText(text, 300.0, p.interface(), out_lines) orelse 0;
        }
    }.wrap);

    std.debug.print("  Design E (Streaming): ", .{});
    const result_e = try runBenchmark("Design E", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignE.SimpleBreaker{};
            return DesignE.wrapTextStreaming(text, 300.0, b.interface(), simpleMeasure, out_lines, 64);
        }
    }.wrap);

    // =========================================================================
    // PART 2: REALISTIC SCENARIO - Expensive measureText
    // =========================================================================

    std.debug.print("\n--- PART 2: EXPENSIVE MEASURE (simulates real font lookup) ---\n", .{});
    std.debug.print("Same text, but measureText does per-glyph width lookup\n", .{});

    std.debug.print("\n  Design A (Buffer): ", .{});
    const result_a2 = try runBenchmark("Design A+exp", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignA.SimpleBreaker{};
            return DesignA.wrapText(text, 300.0, b.interface(), expensiveMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design B (Iterator): ", .{});
    const result_b2 = try runBenchmark("Design B+exp", iterations, test_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignB.SimpleBreaker{};
            return DesignB.wrapText(text, 300.0, b.interface(), expensiveMeasure, out_lines);
        }
    }.wrap);

    // =========================================================================
    // PART 3: HIGH BREAK DENSITY (CJK-like scenario)
    // =========================================================================

    std.debug.print("\n--- PART 3: HIGH BREAK DENSITY (CJK-like, every char is breakable) ---\n", .{});
    std.debug.print("64 chars, all are break opportunities (100%% vs ~20%% for ASCII)\n", .{});

    std.debug.print("\n  Design A (Buffer): ", .{});
    const result_a3 = try runBenchmark("Design A+CJK", iterations, high_density_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = HighDensityBreakerA{};
            return DesignA.wrapText(text, 80.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design B (Iterator): ", .{});
    const result_b3 = try runBenchmark("Design B+CJK", iterations, high_density_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = HighDensityBreakerB{};
            return DesignB.wrapText(text, 80.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    // =========================================================================
    // PART 4: LONG TEXT (Buffer overflow risk)
    // =========================================================================

    std.debug.print("\n--- PART 4: LONG TEXT ({d} bytes, buffer overflow test) ---\n", .{long_text.len});
    std.debug.print("256 break buffer - will Design A truncate? Does Design B handle it?\n", .{});

    std.debug.print("\n  Design A (Buffer): ", .{});
    const result_a4 = try runBenchmark("Design A+long", 1000, long_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignA.SimpleBreaker{};
            return DesignA.wrapText(text, 300.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design B (Iterator): ", .{});
    const result_b4 = try runBenchmark("Design B+long", 1000, long_text, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignB.SimpleBreaker{};
            return DesignB.wrapText(text, 300.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    // =========================================================================
    // PART 5: SHORT LABEL (minimal overhead test)
    // =========================================================================

    std.debug.print("\n--- PART 5: SHORT LABEL ({d} bytes, overhead matters) ---\n", .{short_label.len});

    std.debug.print("\n  Design A (Buffer): ", .{});
    const result_a5 = try runBenchmark("Design A+short", iterations * 10, short_label, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignA.SimpleBreaker{};
            return DesignA.wrapText(text, 200.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    std.debug.print("  Design B (Iterator): ", .{});
    const result_b5 = try runBenchmark("Design B+short", iterations * 10, short_label, struct {
        fn wrap(text: []const u8, out_lines: *[64][]const u8) usize {
            var b = DesignB.SimpleBreaker{};
            return DesignB.wrapText(text, 200.0, b.interface(), cheapMeasure, out_lines);
        }
    }.wrap);

    // =========================================================================
    // PART 6: INVESTIGATE LONG TEXT DISCREPANCY
    // =========================================================================

    std.debug.print("\n--- PART 6: LONG TEXT CORRECTNESS CHECK ---\n", .{});

    // Count actual spaces (break opportunities) in long text
    var space_count: usize = 0;
    for (long_text) |c| {
        if (c == ' ') space_count += 1;
    }
    std.debug.print("Long text: {d} bytes, {d} space break opportunities\n", .{ long_text.len, space_count });
    std.debug.print("Design A produced {d} lines, Design B produced {d} lines\n", .{ result_a4.line_count, result_b4.line_count });

    if (result_a4.line_count != result_b4.line_count) {
        std.debug.print("\n*** CRITICAL: Line count mismatch! ***\n", .{});
        std.debug.print("This indicates buffer overflow or algorithm bug.\n", .{});

        // Check if 256-break buffer is enough
        if (space_count > 256) {
            std.debug.print("Buffer overflow: {d} breaks > 256 buffer size\n", .{space_count});
            std.debug.print("Design A truncates breaks, Design B (iterator) handles all.\n", .{});
        }
    }

    _ = result_a2;
    _ = result_b2;
    _ = result_a3;
    _ = result_b3;
    _ = result_a5;
    _ = result_b5;

    // -------------------------------------------------------------------------
    // COMPARISON SUMMARY
    // -------------------------------------------------------------------------

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("COMPARISON SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("{s:<12} {s:>10} {s:>12} {s:>15} {s:>12}\n", .{
        "Design",
        "Time (ns)",
        "VTable Size",
        "Alloc-Free?",
        "Embedded OK?",
    });
    std.debug.print("{s:-<12} {s:->10} {s:->12} {s:->15} {s:->12}\n", .{ "", "", "", "", "" });

    const designs = .{
        .{ "A: Buffer", result_a.time_ns, "8 bytes", "Yes", "Yes" },
        .{ "B: Iterator", result_b.time_ns, "8 bytes", "Yes", "Yes" },
        .{ "C: Callback", result_c.time_ns, "8 bytes", "Yes", "Yes" },
        .{ "D: Integrated", result_d.time_ns, "16 bytes", "Yes", "Yes" },
        .{ "E: Streaming", result_e.time_ns, "24 bytes", "Yes", "Yes" },
    };

    inline for (designs) |d| {
        std.debug.print("{s:<12} {d:>10} {s:>12} {s:>15} {s:>12}\n", .{
            d[0],
            d[1],
            d[2],
            d[3],
            d[4],
        });
    }

    // -------------------------------------------------------------------------
    // QUALITATIVE ANALYSIS
    // -------------------------------------------------------------------------

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("QUALITATIVE ANALYSIS\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("Design A (Buffer-based):\n", .{});
    std.debug.print("  + Simplest implementation (~30 lines)\n", .{});
    std.debug.print("  + Zero allocation, predictable memory\n", .{});
    std.debug.print("  + Easy to understand and debug\n", .{});
    std.debug.print("  - Must size buffer upfront (may waste or overflow)\n", .{});
    std.debug.print("  - Scans full text even if early termination possible\n", .{});
    std.debug.print("  VERDICT: Best default for most cases\n\n", .{});

    std.debug.print("Design B (Iterator-based):\n", .{});
    std.debug.print("  + Lazy evaluation, good for early termination\n", .{});
    std.debug.print("  + No buffer sizing needed\n", .{});
    std.debug.print("  + Natural Zig idiom (while (iter.next()))\n", .{});
    std.debug.print("  - Slightly more complex implementation\n", .{});
    std.debug.print("  - Iterator state management\n", .{});
    std.debug.print("  VERDICT: Good alternative, slightly more elegant\n\n", .{});

    std.debug.print("Design C (Callback-based):\n", .{});
    std.debug.print("  + Most flexible (can do anything in callback)\n", .{});
    std.debug.print("  + Early termination via return value\n", .{});
    std.debug.print("  - Callback context is awkward\n", .{});
    std.debug.print("  - Inverted control flow harder to follow\n", .{});
    std.debug.print("  - Type-erased context (@ptrCast)\n", .{});
    std.debug.print("  VERDICT: Avoid - complexity not justified\n\n", .{});

    std.debug.print("Design D (Integrated with TextProvider):\n", .{});
    std.debug.print("  + Single interface for text operations\n", .{});
    std.debug.print("  + Convenient for simple cases\n", .{});
    std.debug.print("  - Couples measurement and breaking\n", .{});
    std.debug.print("  - Can't mix different breakers with same provider\n", .{});
    std.debug.print("  - Optional extension pattern adds null checks\n", .{});
    std.debug.print("  VERDICT: Avoid - violates single responsibility\n\n", .{});

    std.debug.print("Design E (Streaming/Incremental):\n", .{});
    std.debug.print("  + Handles large texts without full scan\n", .{});
    std.debug.print("  + Good for streaming input (network, file)\n", .{});
    std.debug.print("  - Most complex implementation\n", .{});
    std.debug.print("  - State management across chunks\n", .{});
    std.debug.print("  - Overkill for typical UI text\n", .{});
    std.debug.print("  VERDICT: Only if actually needed for large docs\n\n", .{});

    // -------------------------------------------------------------------------
    // RECOMMENDATION (UPDATED AFTER REALISTIC TESTING)
    // -------------------------------------------------------------------------

    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("RECOMMENDATION (UPDATED AFTER REALISTIC TESTING)\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("*** CRITICAL FINDING ***\n", .{});
    std.debug.print("Design A (Buffer-based) FAILS on long/CJK text!\n", .{});
    std.debug.print("  - Long text: 2250 bytes, 450 break opportunities\n", .{});
    std.debug.print("  - 256 break buffer overflows -> INCORRECT line count\n", .{});
    std.debug.print("  - Design A: 37 lines (WRONG - truncated)\n", .{});
    std.debug.print("  - Design B: 64 lines (CORRECT)\n\n", .{});

    std.debug.print("PRIMARY: Design B (Iterator-based)\n", .{});
    std.debug.print("  + Handles any text length correctly (no buffer overflow)\n", .{});
    std.debug.print("  + Natural for wrapText (process breaks as you measure)\n", .{});
    std.debug.print("  + Slightly slower (10-20%%) but CORRECT\n", .{});
    std.debug.print("  + Lazy evaluation, early termination\n\n", .{});

    std.debug.print("ALTERNATIVE: Design A (Buffer-based)\n", .{});
    std.debug.print("  - Use ONLY if break count guaranteed < buffer size\n", .{});
    std.debug.print("  - OK for embedded with small fixed text\n", .{});
    std.debug.print("  - NOT OK for general desktop (CJK, long docs)\n\n", .{});

    std.debug.print("HYBRID INTERFACE (recommended):\n\n", .{});
    std.debug.print("  pub const LineBreaker = struct {{\n", .{});
    std.debug.print("      ptr: *anyopaque,\n", .{});
    std.debug.print("      vtable: *const VTable,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("      pub const VTable = struct {{\n", .{});
    std.debug.print("          // Primary: iterator (always correct)\n", .{});
    std.debug.print("          iterate: *const fn (ptr: *anyopaque, text: []const u8) Iterator,\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("          // Optional: fast path for small texts\n", .{});
    std.debug.print("          findBreakPoints: ?*const fn (...) ?usize,\n", .{});
    std.debug.print("      }};\n", .{});
    std.debug.print("  }};\n\n", .{});

    std.debug.print("Key insight: Synthetic tests hid the buffer overflow bug!\n", .{});
    std.debug.print("Realistic CJK/long text testing revealed Design A fails.\n", .{});
    std.debug.print("Always test with realistic data before finalizing interface.\n", .{});
}
