const std = @import("std");
const zlay = @import("zlay");

const DemoRenderer = struct {
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
    
    fn create() DemoRenderer {
        return .{
            .renderer = .{
                .vtable = &vtable,
                .user_data = null,
            },
        };
    }
    
    fn beginFrame(renderer: *zlay.Renderer) void {
        std.debug.print("Begin frame\n", .{});
        _ = renderer;
    }
    
    fn endFrame(renderer: *zlay.Renderer) void {
        std.debug.print("End frame\n", .{});
        _ = renderer;
    }
    
    fn clear(renderer: *zlay.Renderer, color: zlay.Color) void {
        std.debug.print("Clear: rgba({}, {}, {}, {})\n", .{
            color.r, color.g, color.b, color.a,
        });
        _ = renderer;
    }
    
    fn drawRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, fill: zlay.Color) void {
        std.debug.print("Draw rect: x={d}, y={d}, w={d}, h={d}, color=rgba({}, {}, {}, {})\n", .{
            x, y, width, height, fill.r, fill.g, fill.b, fill.a,
        });
        _ = renderer;
    }
    
    fn drawRoundedRect(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32, radius: f32, fill: zlay.Color) void {
        std.debug.print("Draw rounded rect: x={d}, y={d}, w={d}, h={d}, r={d}, color=rgba({}, {}, {}, {})\n", .{
            x, y, width, height, radius, fill.r, fill.g, fill.b, fill.a,
        });
        _ = renderer;
    }
    
    fn drawText(renderer: *zlay.Renderer, text: []const u8, x: f32, y: f32, font_size: f32, color: zlay.Color) void {
        std.debug.print("Draw text: \"{s}\" at x={d}, y={d}, size={d}, color=rgba({}, {}, {}, {})\n", .{
            text, x, y, font_size, color.r, color.g, color.b, color.a,
        });
        _ = renderer;
    }
    
    fn drawImage(renderer: *zlay.Renderer, image_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        std.debug.print("Draw image: id={}, x={d}, y={d}, w={d}, h={d}\n", .{
            image_id, x, y, width, height,
        });
        _ = renderer;
    }
    
    fn clipBegin(renderer: *zlay.Renderer, x: f32, y: f32, width: f32, height: f32) void {
        std.debug.print("Clip begin: x={d}, y={d}, w={d}, h={d}\n", .{
            x, y, width, height,
        });
        _ = renderer;
    }
    
    fn clipEnd(renderer: *zlay.Renderer) void {
        std.debug.print("Clip end\n", .{});
        _ = renderer;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create context with minimal settings to avoid text measurement issues
    var ctx = try zlay.initMinimal(allocator);
    defer ctx.deinit();
    
    // Create renderer
    var demo_renderer = DemoRenderer.create();
    ctx.setRenderer(&demo_renderer.renderer);
    
    // Begin frame
    try ctx.beginFrame();
    
    // Root container
    _ = try ctx.beginElement(.container, "root");
    
    // Header
    const header_idx = try ctx.beginElement(.container, "header");
    {
        ctx.elements.items[header_idx].style.background_color = zlay.Color.rgb(50, 50, 200);
        ctx.elements.items[header_idx].style.setPadding(10);
        
        // Logo
        const logo_idx = try ctx.beginElement(.box, "logo");
        ctx.elements.items[logo_idx].style.background_color = zlay.Color.rgb(200, 50, 50);
        ctx.elements.items[logo_idx].style.corner_radius = 5;
        try ctx.endElement(); // logo
        
        // Title
        const title_idx = try ctx.beginElement(.text, "title");
        ctx.elements.items[title_idx].text = "Zlay Demo";
        ctx.elements.items[title_idx].style.text_color = zlay.Color.white;
        ctx.elements.items[title_idx].style.font_size = 24;
        try ctx.endElement(); // title
    }
    try ctx.endElement(); // header
    
    // Content
    const content_idx = try ctx.beginElement(.container, "content");
    {
        ctx.elements.items[content_idx].style.setPadding(20);
        ctx.elements.items[content_idx].style.background_color = zlay.Color.rgb(240, 240, 240);
        
        // Button
        const button_idx = try ctx.beginElement(.button, "button");
        ctx.elements.items[button_idx].text = "Click Me";
        ctx.elements.items[button_idx].style.background_color = zlay.Color.rgb(50, 150, 50);
        ctx.elements.items[button_idx].style.text_color = zlay.Color.white;
        ctx.elements.items[button_idx].style.corner_radius = 5;
        ctx.elements.items[button_idx].style.setPadding(10);
        try ctx.endElement(); // button
    }
    try ctx.endElement(); // content
    
    // Footer
    const footer_idx = try ctx.beginElement(.container, "footer");
    {
        ctx.elements.items[footer_idx].style.background_color = zlay.Color.rgb(50, 50, 50);
        ctx.elements.items[footer_idx].style.setPadding(10);
        
        // Footer text
        const footer_text_idx = try ctx.beginElement(.text, "footer_text");
        ctx.elements.items[footer_text_idx].text = "Zlay - A Zig Layout Library";
        ctx.elements.items[footer_text_idx].style.text_color = zlay.Color.rgb(200, 200, 200);
        try ctx.endElement(); // footer_text
    }
    try ctx.endElement(); // footer
    
    // End root
    try ctx.endElement(); // root
    
    // Compute layout
    try ctx.computeLayout(800, 600);
    
    // Render
    try ctx.render();
    
    std.debug.print("\nZlay Demo Completed!\n", .{});
}