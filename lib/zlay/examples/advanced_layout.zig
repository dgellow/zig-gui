const std = @import("std");
const zlay = @import("zlay");

/// This example demonstrates the advanced layout capabilities of zlay
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
    
    // Create a root container with row direction
    const root_idx = try ctx.beginElement(.container, "root");
    ctx.elements.items[root_idx].style.direction = .row;  // Row layout (horizontal)
    
    // Left panel (30% width)
    const left_panel = try ctx.beginElement(.container, "left_panel");
    ctx.elements.items[left_panel].style.direction = .column;  // Column layout (vertical)
    ctx.elements.items[left_panel].width_percent = 30;  // 30% of parent width
    ctx.elements.items[left_panel].style.background_color = zlay.Color.rgb(200, 200, 200);
    
    // Add some items to the left panel
    for (0..5) |i| {
        // Use static strings for IDs to avoid memory issues
        const id = switch (i) {
            0 => "left_item_0",
            1 => "left_item_1",
            2 => "left_item_2",
            3 => "left_item_3",
            4 => "left_item_4",
            else => unreachable,
        };
        
        const item_idx = try ctx.beginElement(.box, id);
        ctx.elements.items[item_idx].style.background_color = zlay.Color.rgb(150, 150, 150);
        ctx.elements.items[item_idx].style.setMargin(5);
        ctx.elements.items[item_idx].height = 30;  // Fixed height
        try ctx.endElement();
    }
    
    try ctx.endElement(); // end left_panel
    
    // Center content (flex grow to fill available space)
    const center_panel = try ctx.beginElement(.container, "center_panel");
    ctx.elements.items[center_panel].style.direction = .column;
    ctx.elements.items[center_panel].style.flex_grow = 1;  // Take remaining width
    ctx.elements.items[center_panel].style.background_color = zlay.Color.rgb(220, 220, 220);
    
    // Header in center panel (fixed height)
    const header = try ctx.beginElement(.box, "header");
    ctx.elements.items[header].height = 50;
    ctx.elements.items[header].style.background_color = zlay.Color.rgb(100, 100, 200);
    ctx.elements.items[header].text = "Header";
    ctx.elements.items[header].style.text_color = zlay.Color.rgb(255, 255, 255);
    try ctx.endElement();
    
    // Content area (grows to fill available space)
    const content = try ctx.beginElement(.container, "content");
    ctx.elements.items[content].style.flex_grow = 1;
    ctx.elements.items[content].style.direction = .row;  // Row of items
    ctx.elements.items[content].style.background_color = zlay.Color.rgb(240, 240, 240);
    
    // Some content items with different sizing modes
    // Fixed width item
    const fixed_item = try ctx.beginElement(.box, "fixed");
    ctx.elements.items[fixed_item].width = 100;
    ctx.elements.items[fixed_item].style.background_color = zlay.Color.rgb(255, 200, 200);
    ctx.elements.items[fixed_item].style.setMargin(10);
    try ctx.endElement();
    
    // Percentage width item
    const percent_item = try ctx.beginElement(.box, "percent");
    ctx.elements.items[percent_item].width_percent = 30;  // 30% of parent
    ctx.elements.items[percent_item].style.background_color = zlay.Color.rgb(200, 255, 200);
    ctx.elements.items[percent_item].style.setMargin(10);
    try ctx.endElement();
    
    // Flex item (grows to fill remaining space)
    const flex_item = try ctx.beginElement(.box, "flex");
    ctx.elements.items[flex_item].style.flex_grow = 1;
    ctx.elements.items[flex_item].style.background_color = zlay.Color.rgb(200, 200, 255);
    ctx.elements.items[flex_item].style.setMargin(10);
    try ctx.endElement();
    
    try ctx.endElement(); // end content
    
    // Footer (fixed height)
    const footer = try ctx.beginElement(.box, "footer");
    ctx.elements.items[footer].height = 30;
    ctx.elements.items[footer].style.background_color = zlay.Color.rgb(100, 100, 200);
    ctx.elements.items[footer].text = "Footer";
    ctx.elements.items[footer].style.text_color = zlay.Color.rgb(255, 255, 255);
    try ctx.endElement();
    
    try ctx.endElement(); // end center_panel
    
    try ctx.endElement(); // end root
    
    // Calculate layout
    try ctx.computeLayout(800, 600);
    
    // Render the layout
    std.debug.print("\n\n=== Advanced Layout Demo ===\n\n", .{});
    try ctx.render();
    
    // Print layout properties of some key elements
    printElementInfo(&ctx, "root");
    printElementInfo(&ctx, "left_panel");
    printElementInfo(&ctx, "center_panel");
    printElementInfo(&ctx, "content");
    printElementInfo(&ctx, "fixed");
    printElementInfo(&ctx, "percent");
    printElementInfo(&ctx, "flex");
}

/// Simple renderer that outputs text representation of layout
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
        std.debug.print("Begin rendering layout...\n", .{});
    }
    
    fn endFrame(renderer: *zlay.Renderer) void {
        _ = renderer;
        std.debug.print("End rendering layout.\n", .{});
    }
    
    fn clear(renderer: *zlay.Renderer, color: zlay.Color) void {
        _ = renderer;
        std.debug.print("Clear screen with color: rgba({}, {}, {}, {})\n", .{
            color.r, color.g, color.b, color.a,
        });
    }
    
    fn drawRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, fill: zlay.Color) void {
        _ = renderer;
        std.debug.print("Draw rect: x={d:.1}, y={d:.1}, w={d:.1}, h={d:.1}, color=rgba({}, {}, {}, {})\n", .{
            x, y, width, height, fill.r, fill.g, fill.b, fill.a,
        });
    }
    
    fn drawRoundedRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: zlay.Color) void {
        _ = renderer;
        std.debug.print("Draw rounded rect: x={d:.1}, y={d:.1}, w={d:.1}, h={d:.1}, r={d:.1}, color=rgba({}, {}, {}, {})\n", .{
            x, y, width, height, radius, fill.r, fill.g, fill.b, fill.a,
        });
    }
    
    fn drawText(renderer: *zlay.Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: zlay.Color) void {
        _ = renderer;
        std.debug.print("Draw text: \"{s}\" at x={d:.1}, y={d:.1}, size={d:.1}, color=rgba({}, {}, {}, {})\n", .{
            text, x, y, font_size, color.r, color.g, color.b, color.a,
        });
    }
    
    fn drawImage(renderer: *zlay.Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        _ = renderer;
        std.debug.print("Draw image: id={}, x={d:.1}, y={d:.1}, w={d:.1}, h={d:.1}\n", .{
            image_id, x, y, width, height,
        });
    }
    
    fn clipBegin(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32) void {
        _ = renderer;
        std.debug.print("Clip begin: x={d:.1}, y={d:.1}, w={d:.1}, h={d:.1}\n", .{
            x, y, width, height,
        });
    }
    
    fn clipEnd(renderer: *zlay.Renderer) void {
        _ = renderer;
        std.debug.print("Clip end\n", .{});
    }
};

/// Print detailed information about an element
fn printElementInfo(ctx: *zlay.Context, id: []const u8) void {
    if (ctx.getElementById(id)) |element| {
        std.debug.print("\nElement '{s}':\n", .{id});
        std.debug.print("  Position: ({d:.1}, {d:.1})\n", .{element.x, element.y});
        std.debug.print("  Size: {d:.1} x {d:.1}\n", .{element.width, element.height});
        
        if (element.width_percent) |w_pct| {
            std.debug.print("  Width as percentage: {d:.1}%\n", .{w_pct});
        }
        
        if (element.height_percent) |h_pct| {
            std.debug.print("  Height as percentage: {d:.1}%\n", .{h_pct});
        }
        
        if (element.style.flex_grow > 0) {
            std.debug.print("  Flex grow: {d:.1}\n", .{element.style.flex_grow});
        }
        
        std.debug.print("  Direction: {s}\n", .{@tagName(element.style.direction)});
    } else {
        std.debug.print("\nElement '{s}' not found\n", .{id});
    }
}