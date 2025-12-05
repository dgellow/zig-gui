//! Experiment 10: Text Input Cursor & Selection
//!
//! Validates the text input workflow that getCharPositions() must support:
//!
//! 1. Click → find character index under cursor (hit testing)
//! 2. Arrow keys → move cursor by one logical position
//! 3. Shift+Arrow → extend selection
//! 4. Triple-click → select line
//! 5. Home/End → line boundaries
//! 6. Word navigation (Ctrl+Arrow on Windows, Option+Arrow on Mac)
//!
//! CRITICAL LIMITATION: This experiment is LTR-only.
//! Bidi (RTL) is deferred to Phase 3 - see analysis below.

const std = @import("std");

// ============================================================================
// THE PROBLEM: Visual vs Logical Position
// ============================================================================
//
// For LTR text like "Hello World", visual and logical are the same:
//
//   Logical index:  0  1  2  3  4  5  6  7  8  9  10
//   Text:           H  e  l  l  o     W  o  r  l  d
//   Visual x:       0  8  16 24 32 40 48 56 64 72 80
//
// But for mixed RTL/LTR like "Hello שלום World":
//
//   Logical index:  0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16
//   Text (stored):  H  e  l  l  o     ש  ל  ו  ם     W  o  r  l  d
//   Visual render:  H  e  l  l  o     ם  ו  ל  ש     W  o  r  l  d
//   Visual x:       0  8  16 24 32 40 72 64 56 48 80 88 96 ...
//                                     ←  RTL  →
//
// getCharPositions() returns VISUAL positions (for rendering).
// Cursor movement uses LOGICAL positions (UTF-8 byte offsets).
// Click hit-testing must map VISUAL x → LOGICAL index.
//
// For Phase 1 (LTR only): visual == logical, no problem.
// For Phase 3 (Bidi): Need additional API or flag.

// ============================================================================
// INTERFACE OPTIONS
// ============================================================================

/// Option A: Current design - just x positions
/// Pro: Simple, works for LTR
/// Con: Doesn't handle RTL hit testing correctly
pub const PositionsOnlyProvider = struct {
    char_width: f32 = 8.0,

    pub fn getCharPositions(
        self: *PositionsOnlyProvider,
        text: []const u8,
        out: []f32,
    ) usize {
        var x: f32 = 0;
        var count: usize = 0;

        for (text) |c| {
            if (count >= out.len) break;

            // Variable width simulation
            const w: f32 = switch (c) {
                'i', 'l', '!' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => self.char_width,
            };

            out[count] = x;
            x += w;
            count += 1;
        }

        return count;
    }
};

/// Option B: Return both position and advance
/// Pro: Can calculate both x position AND width of each char
/// Con: More memory (16 bytes per char vs 4)
pub const PositionWithAdvance = struct {
    x: f32, // Start position of this character
    advance: f32, // Width of this character
};

pub const AdvanceProvider = struct {
    char_width: f32 = 8.0,

    pub fn getCharMetrics(
        self: *AdvanceProvider,
        text: []const u8,
        out: []PositionWithAdvance,
    ) usize {
        var x: f32 = 0;
        var count: usize = 0;

        for (text) |c| {
            if (count >= out.len) break;

            const w: f32 = switch (c) {
                'i', 'l', '!' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => self.char_width,
            };

            out[count] = .{ .x = x, .advance = w };
            x += w;
            count += 1;
        }

        return count;
    }
};

/// Option C: Separate hit-test function
/// Pro: Cleaner separation, can handle bidi internally
/// Con: Two functions instead of one
pub const HitTestProvider = struct {
    char_width: f32 = 8.0,

    /// Get visual x positions for rendering cursor/selection
    pub fn getCharPositions(
        self: *HitTestProvider,
        text: []const u8,
        out: []f32,
    ) usize {
        var x: f32 = 0;
        var count: usize = 0;

        for (text) |c| {
            if (count >= out.len) break;

            const w: f32 = switch (c) {
                'i', 'l', '!' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => self.char_width,
            };

            out[count] = x;
            x += w;
            count += 1;
        }

        return count;
    }

    /// Hit test: given visual x coordinate, return logical character index
    /// Returns the index of the character that the point is in/after
    pub fn hitTest(
        self: *HitTestProvider,
        text: []const u8,
        visual_x: f32,
    ) HitTestResult {
        var x: f32 = 0;

        for (text, 0..) |c, i| {
            const w: f32 = switch (c) {
                'i', 'l', '!' => 4.0,
                'm', 'w', 'M', 'W' => 12.0,
                else => self.char_width,
            };

            const mid = x + w / 2;

            if (visual_x < mid) {
                // Click is in left half of this char - cursor before char
                return .{
                    .index = i,
                    .trailing = false,
                };
            }

            x += w;
        }

        // Past end of text - cursor at end
        return .{
            .index = text.len,
            .trailing = true,
        };
    }

    pub const HitTestResult = struct {
        index: usize, // Logical character index (byte offset for ASCII)
        trailing: bool, // true = after character, false = before
    };
};

// ============================================================================
// CURSOR MODEL
// ============================================================================

/// Text cursor with selection support
pub const TextCursor = struct {
    /// Anchor: where selection started (or same as focus if no selection)
    anchor: usize,
    /// Focus: current cursor position (the "moving" end of selection)
    focus: usize,

    const Self = @This();

    pub fn init(pos: usize) Self {
        return .{ .anchor = pos, .focus = pos };
    }

    /// Is there an active selection?
    pub fn hasSelection(self: Self) bool {
        return self.anchor != self.focus;
    }

    /// Get selection range (start <= end)
    pub fn getSelection(self: Self) struct { start: usize, end: usize } {
        return .{
            .start = @min(self.anchor, self.focus),
            .end = @max(self.anchor, self.focus),
        };
    }

    /// Move cursor, optionally extending selection
    pub fn moveTo(self: *Self, pos: usize, extend_selection: bool) void {
        self.focus = pos;
        if (!extend_selection) {
            self.anchor = pos;
        }
    }

    /// Move by delta positions
    pub fn moveBy(self: *Self, delta: i32, text_len: usize, extend: bool) void {
        const new_pos: usize = if (delta < 0)
            self.focus -| @as(usize, @intCast(-delta))
        else
            @min(self.focus + @as(usize, @intCast(delta)), text_len);

        self.moveTo(new_pos, extend);
    }

    /// Collapse selection to cursor position
    pub fn collapseToFocus(self: *Self) void {
        self.anchor = self.focus;
    }

    /// Select all
    pub fn selectAll(self: *Self, text_len: usize) void {
        self.anchor = 0;
        self.focus = text_len;
    }

    /// Select word at position (simplified: whitespace-delimited)
    pub fn selectWord(self: *Self, text: []const u8, pos: usize) void {
        // Find word start
        var start = pos;
        while (start > 0 and text[start - 1] != ' ') : (start -= 1) {}

        // Find word end
        var end = pos;
        while (end < text.len and text[end] != ' ') : (end += 1) {}

        self.anchor = start;
        self.focus = end;
    }

    /// Select line (up to \n or end)
    pub fn selectLine(self: *Self, text: []const u8, pos: usize) void {
        // Find line start
        var start = pos;
        while (start > 0 and text[start - 1] != '\n') : (start -= 1) {}

        // Find line end
        var end = pos;
        while (end < text.len and text[end] != '\n') : (end += 1) {}

        self.anchor = start;
        self.focus = end;
    }
};

// ============================================================================
// INPUT ACTIONS
// ============================================================================

pub const InputAction = enum {
    // Cursor movement
    move_left,
    move_right,
    move_up,
    move_down,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    move_doc_start,
    move_doc_end,

    // Selection (same as move but extends selection)
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_all,

    // Mouse
    click, // Set cursor at position
    shift_click, // Extend selection to position
    double_click, // Select word
    triple_click, // Select line

    // Editing
    backspace,
    delete,
    insert_char,
    insert_newline,
};

// ============================================================================
// TEXT FIELD STATE
// ============================================================================

pub const TextField = struct {
    text: std.ArrayList(u8),
    cursor: TextCursor,
    // Cache of character positions (invalidated on text change)
    positions_cache: ?[]f32,
    positions_allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .text = std.ArrayList(u8).init(allocator),
            .cursor = TextCursor.init(0),
            .positions_cache = null,
            .positions_allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.positions_cache) |cache| {
            self.positions_allocator.free(cache);
        }
        self.text.deinit();
    }

    pub fn setText(self: *Self, new_text: []const u8) !void {
        self.invalidateCache();
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(new_text);
        self.cursor = TextCursor.init(@min(self.cursor.focus, new_text.len));
    }

    pub fn getText(self: *Self) []const u8 {
        return self.text.items;
    }

    fn invalidateCache(self: *Self) void {
        if (self.positions_cache) |cache| {
            self.positions_allocator.free(cache);
            self.positions_cache = null;
        }
    }

    // Simple action handlers (no params)
    pub fn moveLeft(self: *Self) void {
        self.cursor.moveBy(-1, self.text.items.len, false);
    }

    pub fn moveRight(self: *Self) void {
        self.cursor.moveBy(1, self.text.items.len, false);
    }

    pub fn selectLeft(self: *Self) void {
        self.cursor.moveBy(-1, self.text.items.len, true);
    }

    pub fn selectRight(self: *Self) void {
        self.cursor.moveBy(1, self.text.items.len, true);
    }

    pub fn moveLineStart(self: *Self) void {
        const line_start = self.findLineStart(self.cursor.focus);
        self.cursor.moveTo(line_start, false);
    }

    pub fn moveLineEnd(self: *Self) void {
        const line_end = self.findLineEnd(self.cursor.focus);
        self.cursor.moveTo(line_end, false);
    }

    pub fn moveWordLeft(self: *Self) void {
        const word_start = self.findWordStart(self.cursor.focus);
        self.cursor.moveTo(word_start, false);
    }

    pub fn moveWordRight(self: *Self) void {
        const word_end = self.findWordEnd(self.cursor.focus);
        self.cursor.moveTo(word_end, false);
    }

    pub fn selectAll(self: *Self) void {
        self.cursor.selectAll(self.text.items.len);
    }

    pub fn click(self: *Self, pos: usize) void {
        self.cursor.moveTo(pos, false);
    }

    pub fn shiftClick(self: *Self, pos: usize) void {
        self.cursor.moveTo(pos, true);
    }

    pub fn doubleClick(self: *Self, pos: usize) void {
        self.cursor.selectWord(self.text.items, pos);
    }

    pub fn tripleClick(self: *Self, pos: usize) void {
        self.cursor.selectLine(self.text.items, pos);
    }

    pub fn backspace(self: *Self) !void {
        if (self.cursor.hasSelection()) {
            try self.deleteSelection();
        } else if (self.cursor.focus > 0) {
            self.invalidateCache();
            _ = self.text.orderedRemove(self.cursor.focus - 1);
            self.cursor.moveBy(-1, self.text.items.len, false);
        }
    }

    pub fn delete(self: *Self) !void {
        if (self.cursor.hasSelection()) {
            try self.deleteSelection();
        } else if (self.cursor.focus < self.text.items.len) {
            self.invalidateCache();
            _ = self.text.orderedRemove(self.cursor.focus);
        }
    }

    pub fn insertChar(self: *Self, char: u8) !void {
        if (self.cursor.hasSelection()) {
            try self.deleteSelection();
        }

        self.invalidateCache();
        try self.text.insert(self.cursor.focus, char);
        self.cursor.moveBy(1, self.text.items.len, false);
    }

    fn deleteSelection(self: *Self) !void {
        if (!self.cursor.hasSelection()) return;

        const sel = self.cursor.getSelection();
        self.invalidateCache();

        // Remove selected bytes
        const items = self.text.items;
        std.mem.copyForwards(u8, items[sel.start..], items[sel.end..]);
        self.text.shrinkRetainingCapacity(self.text.items.len - (sel.end - sel.start));

        self.cursor.moveTo(sel.start, false);
    }

    fn findLineStart(self: *Self, pos: usize) usize {
        var p = pos;
        while (p > 0 and self.text.items[p - 1] != '\n') : (p -= 1) {}
        return p;
    }

    fn findLineEnd(self: *Self, pos: usize) usize {
        var p = pos;
        while (p < self.text.items.len and self.text.items[p] != '\n') : (p += 1) {}
        return p;
    }

    fn findWordStart(self: *Self, pos: usize) usize {
        var p = pos;
        // Skip current whitespace
        while (p > 0 and self.text.items[p - 1] == ' ') : (p -= 1) {}
        // Skip word chars
        while (p > 0 and self.text.items[p - 1] != ' ') : (p -= 1) {}
        return p;
    }

    fn findWordEnd(self: *Self, pos: usize) usize {
        var p = pos;
        // Skip current word chars
        while (p < self.text.items.len and self.text.items[p] != ' ') : (p += 1) {}
        // Skip whitespace
        while (p < self.text.items.len and self.text.items[p] == ' ') : (p += 1) {}
        return p;
    }
};

// ============================================================================
// TESTS
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("EXPERIMENT 10: Text Input Cursor & Selection\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    // =========================================================================
    // TEST 1: Hit Testing with Option A (positions only)
    // =========================================================================

    std.debug.print("\n--- TEST 1: Hit Testing (positions only) ---\n", .{});

    var provider_a = PositionsOnlyProvider{};
    const test_text = "Hello World";

    var positions: [64]f32 = undefined;
    const count = provider_a.getCharPositions(test_text, &positions);

    std.debug.print("\nText: \"{s}\" ({d} chars)\n", .{ test_text, count });
    std.debug.print("Positions: ", .{});
    for (positions[0..count]) |p| {
        std.debug.print("{d:.0} ", .{p});
    }
    std.debug.print("\n", .{});

    // Manual hit testing with positions only
    const test_clicks = [_]f32{ 0, 4, 20, 38, 50, 100 };
    std.debug.print("\nHit test (positions only - must do binary search):\n", .{});
    for (test_clicks) |click_x| {
        // Binary search to find character
        var idx: usize = 0;
        for (positions[0..count], 0..) |pos, i| {
            if (pos > click_x) break;
            idx = i;
        }
        std.debug.print("  Click x={d:.0} → char {d} ('{c}')\n", .{
            click_x,
            idx,
            if (idx < test_text.len) test_text[idx] else ' ',
        });
    }

    // =========================================================================
    // TEST 2: Hit Testing with Option C (dedicated hit test)
    // =========================================================================

    std.debug.print("\n--- TEST 2: Hit Testing (dedicated function) ---\n", .{});

    var provider_c = HitTestProvider{};

    std.debug.print("\nHit test (with trailing flag for half-char precision):\n", .{});
    for (test_clicks) |click_x| {
        const result = provider_c.hitTest(test_text, click_x);
        std.debug.print("  Click x={d:.0} → index {d}, trailing={}\n", .{
            click_x,
            result.index,
            result.trailing,
        });
    }

    // =========================================================================
    // TEST 3: Cursor Movement
    // =========================================================================

    std.debug.print("\n--- TEST 3: Cursor Movement ---\n", .{});

    var cursor = TextCursor.init(5);
    std.debug.print("\nStarting at position 5 in \"{s}\"\n", .{test_text});

    cursor.moveBy(-2, test_text.len, false);
    std.debug.print("Move left 2: cursor at {d}\n", .{cursor.focus});

    cursor.moveBy(4, test_text.len, false);
    std.debug.print("Move right 4: cursor at {d}\n", .{cursor.focus});

    cursor.moveBy(-100, test_text.len, false);
    std.debug.print("Move left 100 (clamp): cursor at {d}\n", .{cursor.focus});

    cursor.moveBy(100, test_text.len, false);
    std.debug.print("Move right 100 (clamp): cursor at {d}\n", .{cursor.focus});

    // =========================================================================
    // TEST 4: Selection
    // =========================================================================

    std.debug.print("\n--- TEST 4: Selection ---\n", .{});

    cursor = TextCursor.init(0);
    cursor.moveBy(5, test_text.len, true); // Shift+Right 5 times
    std.debug.print("\nSelect first 5 chars: anchor={d}, focus={d}\n", .{ cursor.anchor, cursor.focus });
    const sel = cursor.getSelection();
    std.debug.print("Selection: \"{s}\"\n", .{test_text[sel.start..sel.end]});

    cursor.selectWord(test_text, 7); // Click in "World"
    std.debug.print("\nDouble-click at 7: \"{s}\"\n", .{test_text[cursor.getSelection().start..cursor.getSelection().end]});

    // =========================================================================
    // TEST 5: TextField Editing
    // =========================================================================

    std.debug.print("\n--- TEST 5: TextField Editing ---\n", .{});

    var field = TextField.init(allocator);
    defer field.deinit();

    try field.setText("Hello World");
    std.debug.print("\nInitial: \"{s}\"\n", .{field.getText()});

    // Select "World" and delete
    field.cursor = TextCursor.init(6);
    field.cursor.selectWord(field.getText(), 6);
    std.debug.print("Selected: \"{s}\"\n", .{field.getText()[field.cursor.getSelection().start..field.cursor.getSelection().end]});

    try field.backspace();
    std.debug.print("After backspace: \"{s}\"\n", .{field.getText()});

    // Type "Zig"
    try field.insertChar('Z');
    try field.insertChar('i');
    try field.insertChar('g');
    std.debug.print("After typing 'Zig': \"{s}\"\n", .{field.getText()});

    // =========================================================================
    // ANALYSIS: Interface Requirements
    // =========================================================================

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("ANALYSIS: What does getCharPositions() need?\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("For LTR-only (Phase 1-2):\n", .{});
    std.debug.print("  Current getCharPositions() is SUFFICIENT.\n", .{});
    std.debug.print("  Hit testing: binary search on returned positions.\n", .{});
    std.debug.print("  Cursor rendering: positions[cursor.focus] gives x.\n", .{});
    std.debug.print("  Selection: positions[sel.start] to positions[sel.end].\n", .{});

    std.debug.print("\nFor Bidi (Phase 3):\n", .{});
    std.debug.print("  PROBLEM: Visual position != logical position.\n", .{});
    std.debug.print("  OPTIONS:\n", .{});
    std.debug.print("    A) Add hitTest(x) -> logical_index to TextProvider\n", .{});
    std.debug.print("    B) Return visual->logical mapping with positions\n", .{});
    std.debug.print("    C) Return CharMetrics with {{x, advance, logical_index, is_rtl}}\n", .{});
    std.debug.print("\n  RECOMMENDATION: Option A (hitTest)\n", .{});
    std.debug.print("    - Minimal vtable addition (1 function)\n", .{});
    std.debug.print("    - Provider handles bidi complexity internally\n", .{});
    std.debug.print("    - GUI code stays simple\n", .{});

    std.debug.print("\nCACHING CONSIDERATION:\n", .{});
    std.debug.print("  getCharPositions() is O(n) per call.\n", .{});
    std.debug.print("  For 1000-char text, that's 1000 measurements.\n", .{});
    std.debug.print("  OPTIONS:\n", .{});
    std.debug.print("    1) Cache in TextField (invalidate on text change)\n", .{});
    std.debug.print("    2) Cache in TextProvider (LRU by text hash)\n", .{});
    std.debug.print("    3) Incremental updates (hard for variable width)\n", .{});
    std.debug.print("\n  RECOMMENDATION: Cache in TextField (Option 1)\n", .{});
    std.debug.print("    - TextField knows when text changes\n", .{});
    std.debug.print("    - Simple invalidation model\n", .{});
    std.debug.print("    - No global state in provider\n", .{});

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("PROPOSED INTERFACE CHANGES\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("PHASE 1-2 (LTR only):\n", .{});
    std.debug.print("  Keep current getCharPositions() as-is.\n", .{});
    std.debug.print("  Add helper: gui.hitTestText(text, x) -> index\n", .{});
    std.debug.print("    (Uses binary search on positions)\n", .{});

    std.debug.print("\nPHASE 3 (Bidi):\n", .{});
    std.debug.print("  Add optional: hitTest(text, x) -> HitTestResult\n", .{});
    std.debug.print("  Add optional: getCaretPositions(text, index) -> {{x, height, is_rtl}}\n", .{});
    std.debug.print("  Document limitation in DESIGN.md NOW.\n", .{});

    std.debug.print("\nNO CHANGES NEEDED TO CURRENT INTERFACE for Phase 1-2.\n", .{});
}
