const std = @import("std");
const zlay = @import("zlay");

/// Example demonstrating scrollable containers and hit testing
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create context with minimal settings to avoid text measurement issues
    var ctx = try zlay.initMinimal(allocator);
    defer ctx.deinit();
    
    // Create a renderer to visualize the layout
    var demo_renderer = TextRenderer.create();
    ctx.setRenderer(&demo_renderer.renderer);
    
    // Begin frame
    try ctx.beginFrame();
    
    // Create a root container
    _ = try ctx.beginElement(.container, "root");
    
    // Main content area
    const main_content = try ctx.beginElement(.container, "main_content");
    ctx.elements.items[main_content].style.direction = .row;
    ctx.elements.items[main_content].style.background_color = zlay.Color.rgb(240, 240, 240);
    ctx.elements.items[main_content].style.setPadding(10);
    
    // Sidebar (fixed width, scrollable)
    const sidebar = try ctx.beginElement(.container, "sidebar");
    ctx.elements.items[sidebar].width = 200;
    ctx.elements.items[sidebar].style.background_color = zlay.Color.rgb(230, 230, 230);
    ctx.elements.items[sidebar].style.setPadding(5);
    ctx.elements.items[sidebar].setOverflowY(.auto); // Enable vertical scrolling
    
    // Add many items to the sidebar to make it scrollable
    for (0..20) |i| {
        // Create element without ID to avoid hash map issues
        const item_idx = try ctx.beginElement(.box, null);
        ctx.elements.items[item_idx].height = 40;
        ctx.elements.items[item_idx].style.background_color = zlay.Color.rgb(200, 200, 220);
        ctx.elements.items[item_idx].style.setMargin(5);
        
        // Use item number for text
        var text_buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrintZ(&text_buf, "Item {d}", .{i});
        ctx.elements.items[item_idx].text = try ctx.arena_pool.allocator().dupe(u8, text);
        try ctx.endElement();
    }
    
    try ctx.endElement(); // sidebar
    
    // Content area (scrollable with lots of content)
    const content = try ctx.beginElement(.container, "content");
    ctx.elements.items[content].style.flex_grow = 1;
    ctx.elements.items[content].style.background_color = zlay.Color.rgb(250, 250, 250);
    ctx.elements.items[content].style.setPadding(10);
    ctx.elements.items[content].setOverflow(.auto); // Enable both horizontal and vertical scrolling
    
    // Add a grid of items to make the content scrollable
    for (0..10) |row| {
        for (0..10) |col| {
            // Create element without ID to avoid hash map issues
            const item_idx = try ctx.beginElement(.box, null);
            
            // Position items in a grid
            ctx.elements.items[item_idx].x = @as(f32, @floatFromInt(col)) * 120;
            ctx.elements.items[item_idx].y = @as(f32, @floatFromInt(row)) * 120;
            ctx.elements.items[item_idx].width = 100;
            ctx.elements.items[item_idx].height = 100;
            
            // Alternate colors
            const color = if ((row + col) % 2 == 0) 
                zlay.Color.rgb(200, 220, 240) 
            else 
                zlay.Color.rgb(240, 200, 220);
                
            ctx.elements.items[item_idx].style.background_color = color;
            
            // Create text label
            var text_buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrintZ(&text_buf, "{d},{d}", .{ row, col });
            ctx.elements.items[item_idx].text = try ctx.arena_pool.allocator().dupe(u8, text);
            
            try ctx.endElement();
        }
    }
    
    try ctx.endElement(); // content
    
    try ctx.endElement(); // main_content
    
    try ctx.endElement(); // root
    
    // Calculate layout
    try ctx.computeLayout(800, 600);
    
    // Set initial scroll positions (for demonstration)
    if (ctx.getElementById("sidebar")) |sidebar_element| {
        sidebar_element.setScrollPosition(0, 50); // Scroll down 50px
    }
    
    if (ctx.getElementById("content")) |content_element| {
        content_element.setScrollPosition(100, 100); // Scroll down and right
    }
    
    // Render the layout
    std.debug.print("\n\n=== Scrollable Container Demo ===\n\n", .{});
    try ctx.render();
    
    // Demonstrate hit testing
    std.debug.print("\n=== Hit Testing Demo ===\n", .{});
    
    // Hit test at various points
    const test_points = [_]struct { x: f32, y: f32 }{
        .{ .x = 100, .y = 100 },
        .{ .x = 400, .y = 300 },
        .{ .x = 600, .y = 500 },
    };
    
    for (test_points) |point| {
        const hit = zlay.HitTesting.elementAtPoint(&ctx, point.x, point.y, .{});
        
        if (hit.element_idx) |idx| {
            const element = ctx.elements.items[idx];
            const id_str = if (element.id) |id| id else "unknown";
            
            std.debug.print("Hit at ({d}, {d}): Element '{s}' (local: {d}, {d})", .{
                point.x, point.y, id_str, hit.local_x, hit.local_y
            });
            
            if (hit.in_content_area) {
                std.debug.print(" [in content area]\n", .{});
            } else {
                std.debug.print("\n", .{});
            }
        } else {
            std.debug.print("No element hit at ({d}, {d})\n", .{point.x, point.y});
        }
    }
    
    // Print information about scrollable containers
    if (ctx.getElementById("sidebar")) |sidebar_element| {
        std.debug.print("\nSidebar:\n", .{});
        std.debug.print("  Size: {d} x {d}\n", .{sidebar_element.width, sidebar_element.height});
        std.debug.print("  Content Size: {d} x {d}\n", .{sidebar_element.content_width, sidebar_element.content_height});
        std.debug.print("  Scroll Position: {d}, {d}\n", .{sidebar_element.scroll_x, sidebar_element.scroll_y});
        std.debug.print("  Is Scrollable X: {}\n", .{sidebar_element.isScrollableX()});
        std.debug.print("  Is Scrollable Y: {}\n", .{sidebar_element.isScrollableY()});
    }
    
    if (ctx.getElementById("content")) |content_element| {
        std.debug.print("\nContent Area:\n", .{});
        std.debug.print("  Size: {d} x {d}\n", .{content_element.width, content_element.height});
        std.debug.print("  Content Size: {d} x {d}\n", .{content_element.content_width, content_element.content_height});
        std.debug.print("  Scroll Position: {d}, {d}\n", .{content_element.scroll_x, content_element.scroll_y});
        std.debug.print("  Is Scrollable X: {}\n", .{content_element.isScrollableX()});
        std.debug.print("  Is Scrollable Y: {}\n", .{content_element.isScrollableY()});
    }
}

/// Simple text-based renderer for visualization
const TextRenderer = struct {
    renderer: zlay.Renderer,
    
    const vtable = zlay.Renderer.VTable{
        .beginFrame = beginFrame,
        .endFrame = endFrame,
        .clear = clear,
        .drawRect = drawRect,
        .drawRoundedRect = drawRoundedRect,
        .drawText = drawText,
        .drawImage = drawImage,
        .clipBegin = clipBegin,
        .clipEnd = clipEnd,
    };
    
    fn create() TextRenderer {
        return .{
            .renderer = .{
                .vtable = &vtable,
                .user_data = null,
            },
        };
    }
    
    fn beginFrame(renderer: *zlay.Renderer) void {
        _ = renderer;
        std.debug.print("Begin frame\n", .{});
    }
    
    fn endFrame(renderer: *zlay.Renderer) void {
        _ = renderer;
        std.debug.print("End frame\n", .{});
    }
    
    fn clear(renderer: *zlay.Renderer, color: zlay.Color) void {
        _ = renderer;
        std.debug.print("Clear with color: rgba({}, {}, {}, {})\n", .{
            color.r, color.g, color.b, color.a
        });
    }
    
    fn drawRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, fill: zlay.Color) void {
        _ = renderer;
        std.debug.print("DrawRect: ({d:.1},{d:.1}) {d:.1}x{d:.1} rgba({},{},{},{})\n", .{
            x, y, width, height, fill.r, fill.g, fill.b, fill.a
        });
    }
    
    fn drawRoundedRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: zlay.Color) void {
        _ = renderer;
        std.debug.print("DrawRoundedRect: ({d:.1},{d:.1}) {d:.1}x{d:.1} r={d:.1} rgba({},{},{},{})\n", .{
            x, y, width, height, radius, fill.r, fill.g, fill.b, fill.a
        });
    }
    
    fn drawText(renderer: *zlay.Renderer, text: []const u8, x: f32, y: f32, font_size: f32, _: zlay.Color) void {
        _ = renderer;
        if (text.len > 20) {
            // Truncate long text for display
            std.debug.print("DrawText: '{s}...' at ({d:.1},{d:.1}) size={d:.1}\n", .{
                text[0..20], x, y, font_size
            });
        } else {
            std.debug.print("DrawText: '{s}' at ({d:.1},{d:.1}) size={d:.1}\n", .{
                text, x, y, font_size
            });
        }
    }
    
    fn drawImage(renderer: *zlay.Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        _ = renderer;
        std.debug.print("DrawImage: id={} at ({d:.1},{d:.1}) {d:.1}x{d:.1}\n", .{
            image_id, x, y, width, height
        });
    }
    
    fn clipBegin(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32) void {
        _ = renderer;
        std.debug.print("ClipBegin: ({d:.1},{d:.1}) {d:.1}x{d:.1}\n", .{
            x, y, width, height
        });
    }
    
    fn clipEnd(renderer: *zlay.Renderer) void {
        _ = renderer;
        std.debug.print("ClipEnd\n", .{});
    }
};