# Scrollable Containers and Hit Testing

## Scrollable Containers

Zlay supports scrollable containers, allowing content that's larger than the visible area to be scrolled.

### Features

- Support for both horizontal and vertical scrolling
- Automatic content size calculation (including nested scrollable containers)
- Configurable overflow behavior (visible, hidden, scroll, auto)
- Clipping to visible area during rendering
- Proper scroll position management
- Automatic culling of off-screen elements for better performance
- Support for nested scrollable containers

### Usage

#### Setting Up a Scrollable Container

```zig
// Create a scrollable container
const container_idx = try ctx.beginElement(.container, "my_scrollable");

// Set dimensions
ctx.elements.items[container_idx].width = 300;
ctx.elements.items[container_idx].height = 200;

// Enable scrolling - several options:
// 1. Enable vertical scrolling only
ctx.elements.items[container_idx].overflow_y = .scroll;

// 2. Or enable horizontal scrolling only
ctx.elements.items[container_idx].overflow_x = .scroll;

// 3. Or enable both (can use .auto to only enable when needed)
ctx.elements.items[container_idx].setOverflow(.auto);

// Add content (can exceed container bounds)
// ...add child elements...

try ctx.endElement();

// Layout will be computed automatically, including content size

// You can scroll programmatically
if (ctx.getElementById("my_scrollable")) |container| {
    // Set scroll position
    container.setScrollPosition(0, 100); // Scroll down 100px
    
    // Scroll by a relative amount
    container.scrollBy(0, 50); // Scroll down 50px more
    
    // Scroll to the beginning/end
    container.scrollToBeginning(); // Scroll to the top/left
    container.scrollToEnd();       // Scroll to the bottom/right
    
    // Get content size
    const content_size = container.getContentSize();
    
    // Get maximum scroll positions
    const max_scroll_x = container.getMaxScrollX();
    const max_scroll_y = container.getMaxScrollY();
    
    // Check if scrollable
    if (container.isScrollableY()) {
        // Vertical scrolling is active
    }
}
```

#### Overflow Behaviors

- `Overflow.visible` - Content that overflows is visible outside the container (default)
- `Overflow.hidden` - Content that overflows is clipped (hidden)
- `Overflow.scroll` - Content can be scrolled (with scrollbars or programmatically)
- `Overflow.auto` - Scrollable only if content overflows the container

#### Performance Optimization

Scrollable containers automatically cull (skip rendering) elements that are completely outside the visible area. This provides a significant performance improvement for containers with many elements, especially on resource-constrained devices.

The culling is done transparently, so you don't need to handle it explicitly in your code. Elements are still present in the layout, but are simply not rendered if they're outside the visible area.

## Hit Testing

Zlay now provides utilities for hit testing, which allows you to find which element is under a particular point. This is crucial for handling user input.

### Features

- Fast element lookup at any coordinate
- Support for scrollable containers
- Hierarchical testing (front-to-back)
- Configurable hit testing options
- Local coordinate conversion

### Usage

#### Basic Hit Testing

```zig
// Import the hit testing module
const zlay = @import("zlay");

// Perform a hit test at a given position
const hit_result = zlay.HitTesting.elementAtPoint(&ctx, mouse_x, mouse_y, .{});

if (hit_result.element_idx) |idx| {
    // An element was hit
    const element = &ctx.elements.items[idx];
    
    // Get the local coordinates relative to the hit element
    const local_x = hit_result.local_x;
    const local_y = hit_result.local_y;
    
    // Check if the hit is in the content area (inside padding)
    if (hit_result.in_content_area) {
        // Hit was inside the content area
    }
    
    // Process the hit
    if (element.id) |id| {
        // Handle specific element
        if (std.mem.eql(u8, id, "button1")) {
            // Handle button click
        }
    }
}
```

#### Hit Testing Options

```zig
// Create options for hit testing
const options = zlay.HitTestOptions{
    // Whether to include disabled elements
    .include_disabled = false,
    
    // Whether to only test visible elements
    .only_visible = true,
    
    // Whether to include elements outside scroll view
    .include_outside_scroll = false,
};

// Perform hit test with options
const hit = zlay.HitTesting.elementAtPoint(&ctx, x, y, options);
```

## Integration Example

See `/examples/scrollable.zig` for a complete example of scrollable containers and hit testing in action.