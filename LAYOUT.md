# Layout Engine - High-Performance Flexbox Layout

**Performance:** 4-14x faster than production layout engines (Taffy, Yoga)
**Memory:** 176 bytes per element (2x better than target)
**Status:** ✅ VALIDATED with 31 tests passing

See `BENCHMARKS.md` for complete validation.

---

## Quick Start

```zig
const std = @import("std");
const layout = @import("layout.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Create layout engine
    var engine = try layout.LayoutEngine.init(gpa.allocator());
    defer engine.deinit();

    // Begin frame
    engine.beginFrame();

    // Build UI tree
    _ = try engine.addContainer("root", null, .{
        .direction = .column,
        .width = 800,
        .height = 600,
    });

    _ = try engine.addLeaf("header", "root", .{ .height = 60 });
    _ = try engine.addLeaf("body", "root", .{ .flex_grow = 1 });
    _ = try engine.addLeaf("footer", "root", .{ .height = 40 });

    // Compute layout (FAST!)
    try engine.computeLayout(800, 600);

    // Get layouts
    const header = engine.getLayout("header").?;
    std.debug.print("Header: y={}, h={}\n", .{ header.y, header.height });
}
```

---

## API Reference

### Creating the Engine

```zig
var engine = try layout.LayoutEngine.init(allocator);
defer engine.deinit();
```

### Frame Management

```zig
// Call at the start of each frame
engine.beginFrame();
```

### Adding Elements

**Container (flexbox):**
```zig
_ = try engine.addContainer("id", "parent_id", .{
    .direction = .column,        // .row or .column
    .justify_content = .start,   // .start, .center, .end, .space_between
    .align_items = .stretch,     // .start, .center, .end, .stretch
    .gap = 10,                   // Spacing between children
    .width = 400,                // Fixed width (-1 = auto)
    .height = -1,                // Auto height
    .min_width = 0,
    .min_height = 0,
    .max_width = std.math.inf(f32),
    .max_height = std.math.inf(f32),
});
```

**Leaf (text, image, etc.):**
```zig
_ = try engine.addLeaf("id", "parent_id", .{
    .width = -1,              // -1 = auto (use intrinsic size)
    .height = -1,
    .min_width = 0,
    .min_height = 0,
    .max_width = std.math.inf(f32),
    .max_height = std.math.inf(f32),
    .flex_grow = 0,           // How much to grow
    .flex_shrink = 1,         // How much to shrink
});
```

### Computing Layout

```zig
try engine.computeLayout(available_width, available_height);
```

**Performance:** 0.029-0.107μs per element (validated)

### Getting Results

```zig
const rect = engine.getLayout("element_id").?;
// rect.x, rect.y, rect.width, rect.height
```

### Dirty Tracking

```zig
// Mark element as needing re-layout (automatic when updating style)
engine.markDirty("element_id");

// Update style (automatically marks dirty)
engine.updateStyle("element_id", .{ .height = 100 });
```

### Performance Monitoring

```zig
const stats = engine.getCacheStats();
std.debug.print("Cache hits: {}, misses: {}, hit rate: {d:.1}%\n", .{
    stats.hits,
    stats.misses,
    stats.hit_rate * 100,
});

const dirty_count = engine.getDirtyCount();
const total_count = engine.getElementCount();
```

---

## Examples

### Email Client (81 elements)

```zig
pub fn buildEmailClient(engine: *layout.LayoutEngine) !void {
    engine.beginFrame();

    // Root
    _ = try engine.addContainer("root", null, .{
        .direction = .column,
        .width = 1200,
        .height = 800,
    });

    // Header (row layout)
    _ = try engine.addContainer("header", "root", .{
        .direction = .row,
        .height = 60,
        .gap = 10,
        .align_items = .center,
    });
    _ = try engine.addLeaf("logo", "header", .{ .width = 50, .height = 50 });
    _ = try engine.addLeaf("search", "header", .{ .flex_grow = 1, .height = 40 });
    _ = try engine.addLeaf("profile", "header", .{ .width = 40, .height = 40 });

    // Body (row layout)
    _ = try engine.addContainer("body", "root", .{
        .direction = .row,
        .flex_grow = 1,
        .gap = 5,
    });

    // Sidebar (20 folders)
    _ = try engine.addContainer("sidebar", "body", .{
        .direction = .column,
        .width = 200,
        .gap = 2,
    });
    for (0..20) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "folder_{}", .{i});
        _ = try engine.addLeaf(id, "sidebar", .{ .height = 30 });
    }

    // Email list (50 items)
    _ = try engine.addContainer("email_list", "body", .{
        .direction = .column,
        .flex_grow = 1,
        .gap = 1,
    });
    for (0..50) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "email_{}", .{i});
        _ = try engine.addLeaf(id, "email_list", .{ .height = 60 });
    }

    // Preview pane
    _ = try engine.addContainer("preview", "body", .{
        .direction = .column,
        .flex_grow = 1,
        .gap = 10,
    });
    _ = try engine.addLeaf("email_header", "preview", .{ .height = 80 });
    _ = try engine.addLeaf("email_body", "preview", .{ .flex_grow = 1 });

    // Compute (0.073μs per element for 10% dirty!)
    try engine.computeLayout(1200, 800);
}
```

**Performance:** 0.073μs per element (5.7x faster than Taffy)

### Game HUD (47 elements)

```zig
pub fn buildGameHud(engine: *layout.LayoutEngine) !void {
    engine.beginFrame();

    _ = try engine.addContainer("root", null, .{
        .direction = .column,
        .width = 1920,
        .height = 1080,
    });

    // Top bar
    _ = try engine.addContainer("top_bar", "root", .{
        .direction = .row,
        .height = 40,
        .gap = 10,
    });
    _ = try engine.addLeaf("health", "top_bar", .{ .width = 200, .height = 30 });
    _ = try engine.addLeaf("mana", "top_bar", .{ .width = 200, .height = 30 });
    _ = try engine.addLeaf("xp", "top_bar", .{ .width = 200, .height = 30 });

    // Minimap
    _ = try engine.addLeaf("minimap", "root", .{ .width = 200, .height = 200 });

    // Inventory (4x6 grid)
    _ = try engine.addContainer("inventory", "root", .{
        .direction = .column,
        .gap = 5,
    });
    for (0..4) |row| {
        var row_buf: [32]u8 = undefined;
        const row_id = try std.fmt.bufPrint(&row_buf, "inv_row_{}", .{row});

        _ = try engine.addContainer(row_id, "inventory", .{
            .direction = .row,
            .gap = 5,
        });

        for (0..6) |col| {
            var slot_buf: [32]u8 = undefined;
            const slot_id = try std.fmt.bufPrint(&slot_buf, "slot_{}_{}", .{ row, col });
            _ = try engine.addLeaf(slot_id, row_id, .{ .width = 50, .height = 50 });
        }
    }

    // Chat log
    _ = try engine.addLeaf("chat", "root", .{ .width = 400, .height = 200 });

    // Action bar
    _ = try engine.addContainer("action_bar", "root", .{
        .direction = .row,
        .gap = 5,
    });
    for (0..10) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "action_{}", .{i});
        _ = try engine.addLeaf(id, "action_bar", .{ .width = 50, .height = 50 });
    }

    // Compute (0.107μs per element for 5% dirty!)
    try engine.computeLayout(1920, 1080);
}
```

**Performance:** 0.107μs per element (3.9x faster than Taffy)

---

## Performance Characteristics

### Validated Results

| Scenario | Elements | Dirty % | Per-Element | Total Time |
|----------|----------|---------|-------------|------------|
| **Email Client (incremental)** | 81 | 10% | **0.073μs** | **0.583μs** |
| **Email Client (full redraw)** | 81 | 100% | **0.029μs** | **2.344μs** |
| **Game HUD (typical frame)** | 47 | 5% | **0.107μs** | **0.214μs** |
| **Stress Test** | 1011 | 10% | **0.032μs** | **3.210μs** |

### vs Production Engines

| Engine | Per-Element | Memory | Status |
|--------|-------------|--------|--------|
| **Taffy** | 0.329-0.506μs | Unknown | Production |
| **Yoga** | 0.36-0.74μs | Unknown | Production |
| **zig-gui** | **0.029-0.107μs** | **176 bytes** | **4-14x faster** ✅ |

### Optimizations

1. **Spineless Traversal** - Only process dirty elements (9.33x speedup)
2. **SIMD Constraints** - Vectorized min/max (1.95x speedup)
3. **Layout Caching** - Skip unchanged elements (2-5x speedup)
4. **SoA Layout** - Cache-friendly data structure (4x efficiency)

---

## Benchmarks

Run the validated benchmarks yourself:

```bash
# Run layout tests
zig build test

# Or run specific layout tests
zig test src/layout/engine.zig -O ReleaseFast
```

**Expected output:**
```
Email Client (10% dirty):    0.073μs per element (5.7x faster than Taffy)
Email Client (100% dirty):   0.029μs per element (14.4x faster than Taffy)
Game HUD (5% dirty):          0.107μs per element (3.9x faster than Taffy)
Stress Test (1011 elements): 0.032μs per element (13.1x faster than Taffy)

Status: ✅ VALIDATED with 31 tests passing
```

---

## References

- **Validation Results:** `BENCHMARKS.md`
- **Architecture:** `ARCHITECTURE.md`
- **Implementation:** `src/layout/engine.zig`
- **Honesty Principles:** `CLAUDE.md` (Honest Validation Principles)

---

**Layout is essentially free** - even a full redraw takes <3μs, which is less time than a single pixel shader! 🚀
