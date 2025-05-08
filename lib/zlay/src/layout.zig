const std = @import("std");
const Element = @import("element.zig").Element;
const Context = @import("context.zig").Context;

/// Layout direction
pub const Direction = enum {
    row,
    column,
};

/// Layout structure for arranging elements
pub const Layout = struct {
    /// Layout algorithm
    pub fn computeLayout(ctx: *Context, container_idx: usize, width: f32, height: f32) !void {
        // This is a simplified layout algorithm
        // A full implementation would handle flexbox-like layouts
        
        const container = &ctx.elements.items[container_idx];
        container.width = width;
        container.height = height;
        
        // Get children
        var children = std.ArrayList(usize).init(ctx.arena_pool.allocator());
        defer children.deinit();
        
        for (ctx.elements.items, 0..) |element, i| {
            if (element.parent != null and element.parent.? == container_idx) {
                try children.append(i);
            }
        }
        
        if (children.items.len == 0) {
            return;
        }
        
        // Determine available space after padding
        const avail_width = width - container.style.padding_left - container.style.padding_right;
        const avail_height = height - container.style.padding_top - container.style.padding_bottom;
        
        // For now, just divide space equally (very simplified!)
        const direction = Direction.column; // Default layout direction
        
        switch (direction) {
            .row => {
                const item_width = avail_width / @as(f32, @floatFromInt(children.items.len));
                
                for (children.items, 0..) |child_idx, i| {
                    const child = &ctx.elements.items[child_idx];
                    
                    child.x = container.style.padding_left + @as(f32, @floatFromInt(i)) * item_width;
                    child.y = container.style.padding_top;
                    child.width = item_width;
                    child.height = avail_height;
                    
                    // Apply margin (simplified)
                    child.x += child.style.margin_left;
                    child.y += child.style.margin_top;
                    child.width -= child.style.margin_left + child.style.margin_right;
                    child.height -= child.style.margin_top + child.style.margin_bottom;
                }
            },
            .column => {
                const item_height = avail_height / @as(f32, @floatFromInt(children.items.len));
                
                for (children.items, 0..) |child_idx, i| {
                    const child = &ctx.elements.items[child_idx];
                    
                    child.x = container.style.padding_left;
                    child.y = container.style.padding_top + @as(f32, @floatFromInt(i)) * item_height;
                    child.width = avail_width;
                    child.height = item_height;
                    
                    // Apply margin (simplified)
                    child.x += child.style.margin_left;
                    child.y += child.style.margin_top;
                    child.width -= child.style.margin_left + child.style.margin_right;
                    child.height -= child.style.margin_top + child.style.margin_bottom;
                }
            },
        }
        
        // Recursively layout children
        for (children.items) |child_idx| {
            const child = &ctx.elements.items[child_idx];
            try computeLayout(ctx, child_idx, child.width, child.height);
        }
    }
};

test "basic layout" {
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    
    try ctx.beginFrame();
    
    const container = try ctx.beginElement(.container, "container");
    _ = try ctx.beginElement(.box, "child1");
    try ctx.endElement();
    _ = try ctx.beginElement(.box, "child2");
    try ctx.endElement();
    try ctx.endElement();
    
    try Layout.computeLayout(&ctx, container, 100, 100);
    
    const child1 = ctx.getElementById("child1").?;
    const child2 = ctx.getElementById("child2").?;
    
    try std.testing.expectEqual(@as(f32, 0), child1.x);
    try std.testing.expectEqual(@as(f32, 0), child1.y);
    try std.testing.expectEqual(@as(f32, 100), child1.width);
    try std.testing.expectEqual(@as(f32, 50), child1.height);
    
    try std.testing.expectEqual(@as(f32, 0), child2.x);
    try std.testing.expectEqual(@as(f32, 50), child2.y);
    try std.testing.expectEqual(@as(f32, 100), child2.width);
    try std.testing.expectEqual(@as(f32, 50), child2.height);
}