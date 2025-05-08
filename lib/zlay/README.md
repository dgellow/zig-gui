# Zlay - A Hyper-Efficient Zig Layout Library

Zlay is a data-oriented GUI layout library written in Zig, inspired by [Clay](https://github.com/nicbarker/clay). It provides a minimal, hyper-efficient API for creating and managing UI layouts with a laser focus on performance, predictability, and low overhead.

## Key Features

- **Extreme Performance**: Designed for game engines, embedded systems, and performance-critical applications
- **Data-Oriented Design**: Optimized memory layout and cache-friendly processing
- **Zero Dependencies**: Bring your own rendering, text measurement, and event handling
- **Minimal Memory Footprint**: Suitable for resource-constrained environments
- **Efficient Layout Algorithm**: Predictable, fast layout calculations
- **C API**: Easy integration with any language
- **Clear Boundaries**: Focused solely on layout with clean extension points

## Design Philosophy

Zlay follows a "bring your own X" philosophy, focusing purely on the layout calculations while allowing integrators to provide their own rendering, input handling, and other systems. This separation of concerns keeps the library focused and highly optimized.

### What's IN Scope for zlay
- Layout engine (positioning and sizing elements)
- Element hierarchy management
- Basic styling that affects layout (padding, margin, alignment)
- Position and size calculations with constraints
- Text measurement abstractions
- Scrollable container calculations
- Hit testing fundamentals

### What's OUT of Scope
- Rendering implementation (handled by pluggable renderers)
- Image loading (only dimensions matter for layout)
- Event dispatching (beyond basic hit testing)
- Animation system
- State management
- Custom component behaviors

## Basic Usage

```zig
const std = @import("std");
const zlay = @import("zlay");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create context
    var ctx = try zlay.init(allocator);
    defer ctx.deinit();
    
    // Begin frame
    try ctx.beginFrame();
    
    // Create a container
    const container = try ctx.beginElement(.container, "container");
    
    // Add a button
    const button = try ctx.beginElement(.button, "button");
    ctx.elements.items[button].text = "Click Me";
    ctx.elements.items[button].style.background_color = zlay.Color.rgb(50, 150, 50);
    ctx.elements.items[button].style.text_color = zlay.Color.white;
    ctx.elements.items[button].style.corner_radius = 5;
    ctx.elements.items[button].style.setPadding(10);
    try ctx.endElement(); // button
    
    // End container
    try ctx.endElement(); // container
    
    // Compute layout
    try ctx.computeLayout(800, 600);
    
    // Attach your renderer
    // ctx.setRenderer(&your_renderer);
    
    // Render
    // try ctx.render();
}
```

## C API Example

```c
#include "zlay.h"
#include <stdio.h>

void begin_frame(ZlayRenderer* renderer) {
    printf("Begin frame\n");
}

void end_frame(ZlayRenderer* renderer) {
    printf("End frame\n");
}

void clear(ZlayRenderer* renderer, ZlayColor color) {
    printf("Clear: rgba(%d, %d, %d, %d)\n", color.r, color.g, color.b, color.a);
}

void draw_rect(ZlayRenderer* renderer, float x, float y, float width, float height, ZlayColor fill) {
    printf("Draw rect: x=%.2f, y=%.2f, w=%.2f, h=%.2f, color=rgba(%d, %d, %d, %d)\n",
        x, y, width, height, fill.r, fill.g, fill.b, fill.a);
}

// Other renderer functions...

int main() {
    // Create context
    ZlayContext* ctx = zlay_create_context();
    
    // Create renderer
    ZlayRenderer* renderer = zlay_create_renderer(
        NULL, begin_frame, end_frame, clear, draw_rect,
        /* other functions... */
    );
    
    // Set renderer
    zlay_set_renderer(ctx, renderer);
    
    // Begin frame
    zlay_begin_frame(ctx);
    
    // Create UI elements
    zlay_begin_element(ctx, ZLAY_ELEMENT_CONTAINER, "container");
    zlay_begin_element(ctx, ZLAY_ELEMENT_BUTTON, "button");
    
    // Set text
    zlay_set_text(ctx, "Click Me");
    
    // Configure style
    ZlayStyle style = {0};
    ZlayColor bg_color = zlay_rgb(50, 150, 50);
    ZlayColor text_color = zlay_rgb(255, 255, 255);
    style.background_color = &bg_color;
    style.text_color = &text_color;
    style.corner_radius = 5;
    style.padding_left = 10;
    style.padding_right = 10;
    style.padding_top = 10;
    style.padding_bottom = 10;
    zlay_set_style(ctx, &style);
    
    // End elements
    zlay_end_element(ctx);
    zlay_end_element(ctx);
    
    // Compute layout and render
    zlay_compute_layout(ctx, 800, 600);
    zlay_render(ctx);
    
    // Cleanup
    zlay_destroy_renderer(renderer);
    zlay_destroy_context(ctx);
    
    return 0;
}
```

## Building

```bash
# Build the library
zig build

# Run the example
zig build run-example
```

## License

MIT