const std = @import("std");
const Element = @import("element.zig").Element;
const Context = @import("context.zig").Context;
const zlay = @import("zlay.zig");

/// Result of a hit test operation
pub const HitTestResult = struct {
    /// Index of the hit element, or null if no element was hit
    element_idx: ?usize = null,
    
    /// Whether the point is in the element's content area (inside padding)
    in_content_area: bool = false,
    
    /// Local coordinates relative to the hit element
    local_x: f32 = 0,
    local_y: f32 = 0,
};

/// Options for hit testing
pub const HitTestOptions = struct {
    /// Whether to include disabled elements in the hit test
    include_disabled: bool = false,
    
    /// Whether to only hit test visible elements (almost always true)
    only_visible: bool = true,
    
    /// Whether to consider elements outside the element's scroll view
    include_outside_scroll: bool = false,
};

/// Functions for hit testing elements in a layout
pub const HitTesting = struct {
    /// Test if a point is inside an element's bounds
    pub fn isPointInElement(
        element: *const Element, 
        x: f32, 
        y: f32
    ) bool {
        return x >= element.x and
               x <= element.x + element.width and
               y >= element.y and
               y <= element.y + element.height;
    }
    
    /// Test if a point is inside an element's content area (inside padding)
    pub fn isPointInContentArea(
        element: *const Element, 
        x: f32, 
        y: f32
    ) bool {
        const content_area = element.getPaddedBounds();
        return x >= content_area.x and
               x <= content_area.x + content_area.width and
               y >= content_area.y and
               y <= content_area.y + content_area.height;
    }
    
    /// Find the topmost element at a point
    pub fn elementAtPoint(
        ctx: *Context,
        x: f32,
        y: f32,
        options: HitTestOptions
    ) HitTestResult {
        // Start with top-level elements
        var top_elements = std.ArrayList(usize).init(ctx.arena_pool.allocator());
        defer top_elements.deinit();
        
        // Get top-level elements
        for (ctx.elements.items, 0..) |element, i| {
            if (element.parent == null) {
                top_elements.append(i) catch continue;
            }
        }
        
        // Reverse the order to test front-to-back
        std.mem.reverse(usize, top_elements.items);
        
        // Perform the hit test
        return elementAtPointInList(ctx, top_elements.items, x, y, options);
    }
    
    /// Find the topmost element in a list of elements
    fn elementAtPointInList(
        ctx: *Context,
        elements: []const usize,
        x: f32,
        y: f32,
        options: HitTestOptions
    ) HitTestResult {
        // Iterate through elements in reverse order (front to back)
        var i: usize = elements.len;
        while (i > 0) {
            i -= 1;
            const element_idx = elements[i];
            const element = &ctx.elements.items[element_idx];
            
            // Skip invisible elements if requested
            if (options.only_visible and !element.visible) {
                continue;
            }
            
            // Skip disabled elements if requested
            if (!options.include_disabled and !element.enabled) {
                continue;
            }
            
            // Check if point is inside element bounds
            if (isPointInElement(element, x, y)) {
                // For scrollable containers, apply scroll offset for hit testing children
                var child_x = x;
                var child_y = y;
                
                // Adjust for scrolling if needed
                if (element.isScrollableX()) {
                    child_x += element.scroll_x;
                }
                
                if (element.isScrollableY()) {
                    child_y += element.scroll_y;
                }
                
                // Check bounds for scrollable content
                if (!options.include_outside_scroll) {
                    // For scrollable containers, ensure the point is within the visible area
                    const content_area = element.getPaddedBounds();
                    
                    if (element.isScrollableX() and 
                        (child_x < content_area.x or child_x > content_area.x + content_area.width)) {
                        continue;
                    }
                    
                    if (element.isScrollableY() and 
                        (child_y < content_area.y or child_y > content_area.y + content_area.height)) {
                        continue;
                    }
                }
                
                // Check if the element has children
                if (ctx.getChildren(element_idx)) |children| {
                    // Recursively test children
                    const child_result = elementAtPointInList(ctx, children, child_x, child_y, options);
                    
                    if (child_result.element_idx != null) {
                        // A child was hit, return that result
                        return child_result;
                    }
                }
                
                // No children were hit, check if hit is in content area
                const in_content = isPointInContentArea(element, x, y);
                
                // Return this element as the result
                return HitTestResult{
                    .element_idx = element_idx,
                    .in_content_area = in_content,
                    .local_x = x - element.x,
                    .local_y = y - element.y,
                };
            }
        }
        
        // No element was hit
        return HitTestResult{
            .element_idx = null,
            .in_content_area = false,
            .local_x = x,
            .local_y = y,
        };
    }
};

test "hit testing basics" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    
    // Create a simple layout for testing
    const root_idx = try ctx.beginElement(.container, "root");
    ctx.elements.items[root_idx].width = 500;
    ctx.elements.items[root_idx].height = 400;
    
    const box1_idx = try ctx.beginElement(.box, "box1");
    ctx.elements.items[box1_idx].x = 50;
    ctx.elements.items[box1_idx].y = 50;
    ctx.elements.items[box1_idx].width = 100;
    ctx.elements.items[box1_idx].height = 100;
    try ctx.endElement();
    
    const box2_idx = try ctx.beginElement(.box, "box2");
    ctx.elements.items[box2_idx].x = 200;
    ctx.elements.items[box2_idx].y = 200;
    ctx.elements.items[box2_idx].width = 150;
    ctx.elements.items[box2_idx].height = 100;
    try ctx.endElement();
    
    try ctx.endElement(); // root
    
    // Test hit testing
    const opts = HitTestOptions{};
    
    // Test hitting box1
    const hit1 = HitTesting.elementAtPoint(&ctx, 75, 75, opts);
    try std.testing.expect(hit1.element_idx != null);
    try std.testing.expectEqual(box1_idx, hit1.element_idx.?);
    try std.testing.expectEqual(@as(f32, 25), hit1.local_x); // 75 - 50
    try std.testing.expectEqual(@as(f32, 25), hit1.local_y); // 75 - 50
    
    // Test hitting box2
    const hit2 = HitTesting.elementAtPoint(&ctx, 250, 250, opts);
    try std.testing.expect(hit2.element_idx != null);
    try std.testing.expectEqual(box2_idx, hit2.element_idx.?);
    
    // Test missing all boxes
    const hit3 = HitTesting.elementAtPoint(&ctx, 400, 300, opts);
    try std.testing.expect(hit3.element_idx != null);
    try std.testing.expectEqual(root_idx, hit3.element_idx.?);
    
    // Test completely outside
    const hit4 = HitTesting.elementAtPoint(&ctx, 600, 600, opts);
    try std.testing.expect(hit4.element_idx == null);
}

// Simplified test for hit testing and scrollable containers
test "simplified scrollable hit testing" {
    var ctx = try zlay.initMinimal(std.testing.allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    
    // Create a simple layout
    const root_idx = try ctx.beginElement(.container, "root");
    ctx.elements.items[root_idx].width = 500;
    ctx.elements.items[root_idx].height = 400;
    
    // Add a container element
    const box_idx = try ctx.beginElement(.box, "box");
    ctx.elements.items[box_idx].x = 100;
    ctx.elements.items[box_idx].y = 100;
    ctx.elements.items[box_idx].width = 100;
    ctx.elements.items[box_idx].height = 100;
    
    try ctx.endElement(); // box
    try ctx.endElement(); // root
    
    // Verify simple hit testing works
    const hit = HitTesting.elementAtPoint(&ctx, 120, 120, .{});
    try std.testing.expect(hit.element_idx != null);
    
    if (hit.element_idx) |idx| {
        try std.testing.expectEqual(box_idx, idx);
        try std.testing.expectEqual(@as(f32, 20), hit.local_x); // 120 - 100
        try std.testing.expectEqual(@as(f32, 20), hit.local_y); // 120 - 100
    }
    
    // Test hit testing outside any element
    const miss = HitTesting.elementAtPoint(&ctx, 300, 300, .{});
    try std.testing.expectEqual(root_idx, miss.element_idx.?);
}