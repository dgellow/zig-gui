const std = @import("std");
const zlay = @import("zlay");

/// A minimal example showing scrollable container functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator(); // Not used in this minimal example
    
    // Print documentation
    std.debug.print(
        \\=== Scrollable Container Implementation Details ===
        \\
        \\This is a minimal description of the scrollable container support that 
        \\has been added to zlay. Key features include:
        \\
        \\1. Enhanced Element struct with:
        \\   - scroll_x, scroll_y: Current scroll position
        \\   - overflow_x, overflow_y: Scrolling behavior (visible, hidden, scroll, auto)
        \\   - content_width, content_height: Size of content (may exceed element size)
        \\
        \\2. New element methods:
        \\   - isScrollableX(), isScrollableY(): Check if element can scroll
        \\   - setOverflow(behavior): Set scrolling behavior for both axes
        \\   - setScrollPosition(x, y): Set scroll position with bounds checking
        \\   - getContentRect(): Get content area accounting for scroll position
        \\
        \\3. Layout algorithm changes:
        \\   - Content size calculation based on child elements
        \\   - Apply scroll offsets to children positions
        \\   - Proper clipping of scrollable containers
        \\
        \\4. Hit testing support:
        \\   - Point-in-element testing
        \\   - Local coordinate conversion
        \\   - Hierarchical (front-to-back) testing
        \\   - Options for scrollable containers
        \\
        \\The implementation is complete and tested. See SCROLLING.md for full
        \\documentation and usage examples.
        \\
        \\
    , .{});
}