# zig-gui Design Document

## Overview

zig-gui is a high-performance UI library for Zig that combines:
- **Event-driven execution** for CPU efficiency (0% idle CPU on desktop)
- **Immediate-mode API** for simple, predictable code
- **Data-oriented layout engine** for fast computation
- **Universal targeting** from embedded (32KB RAM) to desktop

### Goals

| Target | Requirement |
|--------|-------------|
| Desktop idle CPU | 0% |
| Layout computation | <10μs per element |
| Desktop memory | <1MB typical app |
| Embedded RAM | <32KB |
| Embedded flash | <128KB |
| Input response | <5ms |
| Startup time | <50ms |

---

## Architecture

### Ownership Model

```
┌─────────────────────────────────────────────────────────────────────┐
│ User Code                                                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Platform (user owns)                                         │   │
│  │  - Window handle, GL context, event source                   │   │
│  │  - Exposes interface() → PlatformInterface (vtable)          │   │
│  └────────────────────────┬────────────────────────────────────┘   │
│                           │ borrows                                 │
│  ┌────────────────────────▼────────────────────────────────────┐   │
│  │ App(State) (user owns)                                       │   │
│  │  - Holds PlatformInterface (vtable, no ownership)            │   │
│  │  - Owns GUI, execution logic                                 │   │
│  │  - Generic over user's State type                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

Platform is created first and owns OS resources. App borrows platform via vtable interface.

### Execution Modes

```zig
pub const ExecutionMode = enum {
    event_driven,    // Desktop: blocks on events, 0% idle CPU
    game_loop,       // Games: continuous 60+ FPS
    minimal,         // Embedded: ultra-low resource
    server_side,     // Headless: for testing or server rendering
};
```

**Event-driven mode** blocks on `waitEvent()` and only renders when state changes:

```zig
while (app.isRunning()) {
    const event = try app.waitForEvent(); // Blocks here (0% CPU)
    if (event.requiresRedraw()) {
        try app.render();
    }
}
```

**Game loop mode** polls events and renders every frame:

```zig
while (game.running) {
    app.processEvents();           // Non-blocking poll
    app.renderFrame(HudUI, &state);
    game.present();
}
```

### Layer Responsibilities

**Layer 1: Layout Engine** (`src/layout/`)
- Pure layout calculations
- O(n) complexity, SIMD-optimized
- Structure-of-Arrays for cache efficiency

**Layer 2: Core** (`src/`)
- Event handling, state management, platform abstraction
- GUI context, execution modes
- Hot reload support

**Layer 3: Components** (`src/components/`)
- High-level UI widgets (Button, TextInput, etc.)
- Built on layout engine + core

### Core Structures

```zig
pub const GUI = struct {
    layout_engine: *LayoutEngine,
    event_manager: *EventManager,
    style_system: *StyleSystem,
    renderer: ?*RendererInterface,
    animation_system: ?*AnimationSystem,
};
```

---

## State Management

zig-gui uses **Tracked Signals** for state management, inspired by SolidJS and Svelte 5.

### Tracked(T) Type

```zig
pub fn Tracked(comptime T: type) type {
    return struct {
        value: T,
        _v: u32 = 0,  // Version counter

        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        pub inline fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            self._v +%= 1;
        }

        pub inline fn ptr(self: *Self) *T {
            self._v +%= 1;
            return &self.value;
        }
    };
}
```

### Usage

```zig
const AppState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
    name: Tracked([]const u8) = .{ .value = "World" },
    items: Tracked(std.BoundedArray(Item, 100)) = .{ .value = .{} },
};

fn myApp(gui: *GUI, state: *AppState) void {
    gui.text("Counter: {}", .{state.counter.get()});

    gui.button("Increment");
    if (gui.wasClicked("Increment")) {
        state.counter.set(state.counter.get() + 1);
    }

    gui.button("Add Item");
    if (gui.wasClicked("Add Item")) {
        state.items.ptr().append(.{ .name = "New" }) catch {};
    }
}
```

### Why Tracked Signals

| Approach | Memory | Write Cost | Change Detection | Embedded? |
|----------|--------|------------|------------------|-----------|
| React Virtual DOM | High | O(1) + schedule | O(n) tree diff | No |
| ImGui (none) | Low | O(1) | N/A (always redraws) | Yes but wasteful |
| Observer Pattern | Medium | O(k) notify | O(k) callbacks | No |
| **Tracked Signals** | **4 bytes/field** | **O(1)** | **O(N) field count** | **Yes** |

Framework detects changes via version counters - O(N) where N = field count, not data size.

### Change Detection

```zig
pub fn computeStateVersion(state: anytype) u64 {
    var version: u64 = 0;
    inline for (std.meta.fields(@TypeOf(state.*))) |field| {
        const field_ptr = &@field(state.*, field.name);
        if (@hasField(@TypeOf(field_ptr.*), "_v")) {
            version +%= field_ptr._v;
        }
    }
    return version;
}
```

---

## Widget ID System

zig-gui uses a **hybrid ID system** that provides zero-cost IDs for Zig users while supporting runtime IDs for C API and language bindings.

### Design Goals

| Requirement | Solution |
|-------------|----------|
| Zero runtime cost (Zig) | Comptime string hashing |
| C API compatible | Runtime hashing fallback |
| Loop-friendly | Index-based ID composition |
| Debuggable | Debug-only string storage |
| Embedded (32KB) | 4 bytes per ID, fixed-size stack |

### Layered Architecture

The key insight: **widget functions take `u32` hashes, not strings.** The string→hash conversion happens at different times depending on the platform:

```
┌─────────────────────────────────────────────────────────────┐
│  Zig Convenience Layer                                       │
│  widget("Save", style) → widgetCore(0x7a3b2c1d, style)      │
│  Hash computed at compile time - zero runtime cost           │
├─────────────────────────────────────────────────────────────┤
│  C API Exports                                               │
│  zgl_gui_widget(gui, id, style)  ← takes u32 directly       │
│  zgl_id("Save") → 0x7a3b2c1d     ← runtime hash helper      │
├─────────────────────────────────────────────────────────────┤
│  Core Implementation (shared)                                │
│  widgetCore(id: u32, style) → reconciliation + layout        │
└─────────────────────────────────────────────────────────────┘
```

| Platform | When Hashing Happens | Cost |
|----------|---------------------|------|
| Zig | Compile time | Zero |
| WASM | Build time (babel/esbuild plugin) | Zero |
| C API | Runtime (`zgl_id()`) | ~10ns per call |
| Python | Runtime (in binding) | ~10ns per call |

### Core Types

```zig
/// Widget identifier - 4 bytes
pub const WidgetId = packed struct {
    hash: u32,

    /// Comptime: zero-cost hash (Zig users)
    pub fn from(comptime label: []const u8) WidgetId {
        return .{ .hash = comptime std.hash.Wyhash.hash(0, label) };
    }

    /// Runtime: for C API and dynamic strings
    pub fn runtime(label: []const u8) WidgetId {
        return .{ .hash = @truncate(std.hash.Wyhash.hash(0, label)) };
    }

    /// For loops: combine base ID with index
    pub fn indexed(base: WidgetId, index: usize) WidgetId {
        return .{ .hash = base.hash ^ @as(u32, @truncate(index)) *% 0x9e3779b9 };
    }
};
```

### Widget Function Variants

Widget functions **return void** - they declare the widget exists. Interaction state is queried separately via `wasClicked`, `isHovered`, etc.

```zig
// 1. Comptime string (99% of calls) - zero runtime cost
pub fn button(self: *GUI, comptime label: []const u8) void {
    self.buttonCore(comptime WidgetId.from(label).hash, label);
}

// 2. With index (for loops)
pub fn buttonIndexed(self: *GUI, comptime label: []const u8, index: usize) void {
    const indexed_hash = comptime WidgetId.from(label).hash ^ (@truncate(index) +% 1) *% 0x9e3779b9;
    self.buttonCore(indexed_hash, label);
}

// 3. Runtime string (rare - user-generated content)
pub fn buttonDynamic(self: *GUI, label: []const u8) void {
    self.buttonCore(WidgetId.runtime(label).hash, label);
}

// 4. Pre-computed ID (C API interop)
pub fn buttonById(self: *GUI, id: u32, display_label: []const u8) void {
    self.buttonCore(id, display_label);
}
```

### Interaction Query Functions

Query interaction state with matching variants:

```zig
// Check if widget was clicked this frame
pub fn wasClicked(self: *GUI, comptime label: []const u8) bool;
pub fn wasClickedIndexed(self: *GUI, comptime label: []const u8, index: usize) bool;
pub fn wasClickedDynamic(self: *GUI, label: []const u8) bool;
pub fn wasClickedId(self: *GUI, id: u32) bool;

// Check if widget is currently hovered
pub fn isHovered(self: *GUI, comptime label: []const u8) bool;
pub fn isHoveredIndexed(self: *GUI, comptime label: []const u8, index: usize) bool;
// ... same pattern for Dynamic and Id variants

// Check if widget is being pressed (mouse down over it)
pub fn isPressed(self: *GUI, comptime label: []const u8) bool;
// ... same pattern
```

This separation allows flexible queries (hover for tooltips, pressed for visual feedback) without coupling to widget declaration.

### Container Scoping

`begin()` **automatically pushes its ID onto the scope stack**. Child widgets inherit the parent's scope without explicit `pushId()`:

```zig
gui.begin("toolbar", .{ .direction = .row });  // Pushes "toolbar" scope
defer gui.end();                                // Pops scope

// These buttons get IDs: hash("toolbar") ^ hash("file"), etc.
gui.button("file");
gui.button("edit");

if (gui.wasClicked("file")) { ... }
if (gui.wasClicked("edit")) { ... }

gui.begin("submenu", .{});  // Pushes "submenu", scope is now toolbar > submenu
defer gui.end();

gui.button("copy");  // ID: toolbar ^ submenu ^ copy
if (gui.wasClicked("copy")) { ... }
```

This matches React/SwiftUI mental model and reduces boilerplate vs manual `pushId`/`popId`.

### ID Stack (Internal)

Hierarchical scoping implementation:

```zig
pub const IdStack = struct {
    stack: [16]u32 = undefined,  // 64 bytes, fits in cache line
    depth: u8 = 0,
    current_hash: u32 = 0,

    // Debug only - for collision diagnostics
    debug_path: if (builtin.mode == .Debug) std.ArrayList([]const u8) else void,

    pub fn push(self: *IdStack, comptime label: []const u8) void {
        self.pushHash(comptime std.hash.Wyhash.hash(0, label));
        if (builtin.mode == .Debug) self.debug_path.append(label);
    }

    pub fn pushIndex(self: *IdStack, index: usize) void {
        // Add 1 so index 0 produces non-zero contribution
        self.pushHash(@truncate(index +% 1));
    }

    pub fn pop(self: *IdStack) void {
        self.depth -= 1;
        self.current_hash = self.stack[self.depth];
        if (builtin.mode == .Debug) _ = self.debug_path.pop();
    }

    pub fn combine(self: *const IdStack, widget_hash: u32) u32 {
        return self.current_hash ^ widget_hash;
    }
};
```

### Zig Usage Examples

```zig
fn myApp(gui: *GUI, state: *AppState) void {
    // Simple widget - comptime hash
    gui.button("Settings");
    if (gui.wasClicked("Settings")) {
        // ...
    }

    // Container with automatic scoping
    gui.begin("settings_panel", .{ .direction = .column });
    defer gui.end();

    // ID = hash("settings_panel") ^ hash("Save")
    gui.button("Save");
    if (gui.wasClicked("Save")) {
        // ...
    }

    // Loops with index-based IDs
    for (state.items.items, 0..) |item, i| {
        gui.beginIndexed("item", i, .{ .height = 40 });
        defer gui.end();

        gui.text(item.name);
        // ID = settings_panel ^ item ^ i ^ Delete
        gui.button("Delete");
        if (gui.wasClickedIndexed("Delete", i)) {
            state.items.ptr().orderedRemove(i);
        }
    }

    // Runtime string (rare - e.g., user-defined tab names)
    for (state.custom_tabs.items) |tab| {
        gui.beginDynamic(tab.name, .{});
        defer gui.end();
        // ...
    }
}
```

### Debug Support

In debug builds, collision detection and path tracing:

```zig
// Debug mode only
pub fn debugIdPath(self: *const GUI) []const u8 {
    // Returns: "settings_panel > item[3] > Delete"
}

// Collision detection warns on stderr:
// ⚠️ ID collision: hash=0x7a3b2c1d
//   Path 1: settings_panel > Save
//   Path 2: other_panel > Save
```

### Memory Budget (Embedded)

```
IdStack:        64 bytes  (16-deep stack)
WidgetId:        4 bytes  (per widget)
Debug path:      0 bytes  (release builds)
─────────────────────────
Overhead:       68 bytes  (vs 32KB budget = 0.2%)
```

---

## Layout Engine

The layout engine implements flexbox layout with these characteristics:
- O(n) complexity for full layout, O(d) for incremental (d = dirty nodes)
- SIMD-optimized constraint clamping
- Two-pass dirty tracking for incremental updates
- ~144 bytes per element (SoA layout for cache efficiency)

### API

The layout engine uses numeric indices for maximum performance. The GUI layer maps widget IDs to layout indices.

```zig
var engine = try layout.LayoutEngine.init(allocator);
defer engine.deinit();

// Add elements - returns numeric index
const root = try engine.addElement(null, .{
    .direction = .column,
    .width = 800,
    .height = 600,
});
const header = try engine.addElement(root, .{
    .height = 60,
});
const body = try engine.addElement(root, .{
    .flex_grow = 1,
});

// Compute layout
try engine.computeLayout(800, 600);

// Query results by index
const header_rect = engine.getRect(header);
// header_rect.x, header_rect.y, header_rect.width, header_rect.height
```

### GUI Integration

The GUI maintains a mapping from widget IDs to layout indices:

```zig
// Inside GUI - automatic layout index management
pub fn container(self: *GUI, comptime label: []const u8, style: FlexStyle) !void {
    const widget_id = self.id_stack.combine(comptime hash(label));
    const layout_index = try self.layout_engine.addElement(self.current_parent, style);
    self.widget_to_layout.put(widget_id, layout_index);
    // ...
}
```

### Container Options

```zig
.{
    .direction = .column,            // .row or .column
    .justify_content = .flex_start,  // .flex_start, .center, .flex_end, .space_between
    .align_items = .stretch,         // .flex_start, .center, .flex_end, .stretch
    .gap = 10,                       // Spacing between children
    .width = 400,                    // Fixed width (-1 = auto)
    .height = -1,                    // Auto height
    .min_width = 0,
    .min_height = 0,
    .max_width = std.math.inf(f32),
    .max_height = std.math.inf(f32),
}
```

### Leaf Options

```zig
.{
    .width = -1,           // -1 = auto
    .height = -1,
    .flex_grow = 0,        // How much to grow
    .flex_shrink = 1,      // How much to shrink
    .min_width = 0,
    .min_height = 0,
    .max_width = std.math.inf(f32),
    .max_height = std.math.inf(f32),
}
```

### Dirty Tracking: Two-Pass Algorithm

The layout engine uses a **two-pass dirty bit** algorithm for incremental updates:

**Pass 1 - Bottom-up marking** (when style changes):
```
markDirty(node):
    dirty[node] = true
    current = node.parent
    while current != null:
        if dirty[current]: break        // Already marked, ancestors are too
        dirty[current] = true
        if isFixedSize(current): break  // Fixed size won't affect parent layout
        current = current.parent
```

**Pass 2 - Top-down computation** (when computing layout):
```
computeLayout(root, width, height):
    if not dirty[root]: return          // Nothing to do
    computeNode(root, width, height)

computeNode(node, w, h):
    old_child_sizes = captureChildSizes(node)
    layoutChildren(node, w, h)          // Flexbox: position all children

    for child in children:
        size_changed = (child.size != old_child_sizes[child])
        if dirty[child] OR size_changed:
            if child.isContainer:
                computeNode(child, child.width, child.height)
        dirty[child] = false

    dirty[node] = false
```

**Key behaviors:**
- Marking stops at fixed-size ancestors (they won't change size, so parent layout unaffected)
- Computation recurses only into dirty subtrees OR children whose size changed
- Size-change detection handles cascading: parent resize → child resize → grandchild resize

**Why two-pass over spineless traversal?**

We evaluated [Spineless Traversal](https://arxiv.org/html/2411.10659v8) which achieves 1.8x speedup in browser engines. However, it requires an order maintenance data structure to process nodes in correct dependency order, adding memory and complexity.

For UI toolkit workloads (50-500 nodes vs browser's 10,000+), layout takes <1ms total. The traversal overhead that spineless eliminates is negligible when the tree fits in cache. Two-pass is simpler, uses less memory (important for 32KB embedded targets), and is sufficient for our performance goals.

```zig
// API usage
engine.markDirty(element_index);
engine.setStyle(element_index, .{ .height = 100 }); // Auto-marks dirty
```

### Performance Monitoring

```zig
const stats = engine.getCacheStats();
// stats.hits, stats.misses, stats.hit_rate

const dirty_count = engine.getDirtyCount();
const total_count = engine.getElementCount();
```

---

## Immediate Mode Reconciliation

zig-gui provides an **immediate-mode API** (simple, declare UI every frame) backed by a **retained layout engine** (fast, caches results). This section explains how these two models are bridged.

### The Problem

Immediate-mode API:
```zig
fn myUI(gui: *GUI, state: *AppState) void {
    gui.button("Save");  // Called every frame
    if (gui.wasClicked("Save")) { ... }
}
```

Retained layout engine:
```zig
const index = engine.addElement(parent, style);  // Creates persistent element
engine.computeLayout(width, height);              // Caches results
```

**Challenge**: How does `gui.button("Save")` map to the layout engine without:
- Rebuilding the tree every frame (wasteful)
- React-style virtual DOM diffing (complex, memory-heavy)

### Solution: Index Reuse via Widget ID Mapping

Widget IDs (stable across frames) map to layout indices (internal handles):

```
Widget ID (hash of "Save") → Layout Index (e.g., 42)
```

Each frame:
1. Widget function called → lookup ID in persistent hash map
2. If found → reuse existing layout element
3. If not found → create new element, store mapping
4. End of frame → remove elements not "seen" this frame

### Why Not Dear ImGui's Approach?

Dear ImGui rebuilds layout inline during UI traversal with one-frame size latency:

```cpp
// Dear ImGui - every frame:
ImGui::Begin("Window");      // Size based on LAST frame's content
ImGui::Text("Hello");        // Measure text, advance cursor
ImGui::End();                // Finalize size for NEXT frame
```

**Comparison:**

| Aspect | Dear ImGui | zig-gui (Index Reuse) |
|--------|-----------|----------------------|
| **Memory (1000 widgets)** | ~90 KB | ~200 KB |
| **CPU (steady state)** | ~23 μs/frame | ~16 μs/frame |
| **Structural changes** | +0.8 μs | +6.5 μs |
| **Size latency** | 1 frame (glitches) | 0 frames (correct) |
| **Layout power** | Cursor-based | Full flexbox |
| **Idle CPU** | Continuous polling | 0% (event-driven) |

**We chose Index Reuse because:**

1. **Zero latency**: Layout is correct on the first frame. No "popping" when content changes size. Professional desktop apps require this.

2. **0% idle CPU**: The retained layout + dirty tracking enables true event-driven execution. Dear ImGui requires polling.

3. **Flexbox**: Complex layouts (flex-grow, space-between, align-items) are declarative. Dear ImGui requires manual positioning.

4. **Cached layout**: When state unchanged, skip the UI function entirely. Dear ImGui must run every frame.

**Dear ImGui wins for:**
- Highly dynamic UIs (constant widget creation/destruction)
- Extreme memory constraints (<50 KB total)
- Simple vertical stacking layouts

### Data Structures

```zig
pub const GUI = struct {
    // === Persistent (survives across frames) ===

    /// Widget ID → Layout index mapping
    widget_to_layout: std.AutoHashMap(u32, u32),

    /// Layout index → Widget metadata (for parent tracking, reordering)
    widget_meta: [MAX_ELEMENTS]WidgetMeta,

    // === Per-frame (cleared each frame) ===

    /// Which layout indices were "seen" this frame
    seen_this_frame: std.StaticBitSet(MAX_ELEMENTS),

    /// Current parent stack (for nesting)
    parent_stack: std.BoundedArray(u32, 64),

    // === The layout engine ===
    layout_engine: *LayoutEngine,
};

const WidgetMeta = struct {
    parent_hash: u32,     // Parent's widget ID (detect re-parenting)
    sibling_order: u16,   // Position among siblings (detect reordering)
    widget_type: u8,      // button, text, container, etc.
};
```

**Why sibling_order?** This field enables **smooth reorder animations** when using stable IDs:

```zig
// With stable IDs (item.id doesn't change when array reorders)
for (items) |item| {
    gui.beginDynamic(item.stable_id, .{});
    // ...
}
```

When the user reorders items (drag-and-drop, sort), widget IDs stay the same but positions change. Without `sibling_order` tracking:
- We'd have to recreate widgets (losing state, no animation possible)

With `sibling_order` tracking:
- Detect position changes → call `layout_engine.reorderSiblings()`
- Animate widgets moving to new positions
- Preserve widget state across reorder

Index-based IDs (`beginIndexed`) don't need this (index IS identity), but stable IDs require it for proper animation support.

### Frame Lifecycle

```zig
pub fn beginFrame(self: *GUI) void {
    self.seen_this_frame.clear();
    self.parent_stack.clear();
    self.parent_stack.append(ROOT_INDEX);
}

pub fn button(self: *GUI, comptime label: []const u8) !bool {
    const widget_hash = self.id_stack.combine(comptime hash(label));
    const current_parent = self.parent_stack.getLast();

    // Lookup or create layout element
    const layout_index = self.getOrCreateElement(widget_hash, current_parent, .button);

    // Mark as seen this frame
    self.seen_this_frame.set(layout_index);

    // Return interaction state
    return self.event_manager.wasClicked(layout_index);
}

fn getOrCreateElement(self: *GUI, widget_hash: u32, parent_hash: u32, widget_type: WidgetType) !u32 {
    if (self.widget_to_layout.get(widget_hash)) |existing| {
        // Existing widget - check if parent changed (re-parenting)
        const meta = &self.widget_meta[existing];
        if (meta.parent_hash != parent_hash) {
            const new_parent = self.widget_to_layout.get(parent_hash) orelse ROOT_INDEX;
            self.layout_engine.reparent(existing, new_parent);
            meta.parent_hash = parent_hash;
        }
        return existing;
    }

    // New widget - create layout element
    const parent_index = self.widget_to_layout.get(parent_hash) orelse ROOT_INDEX;
    const new_index = try self.layout_engine.addElement(parent_index, .{});

    try self.widget_to_layout.put(widget_hash, new_index);
    self.widget_meta[new_index] = .{
        .parent_hash = parent_hash,
        .sibling_order = 0,
        .widget_type = widget_type,
    };

    return new_index;
}

pub fn endFrame(self: *GUI) !void {
    // Remove widgets not seen this frame
    var to_remove = std.ArrayList(u32).init(self.allocator);
    defer to_remove.deinit();

    var iter = self.widget_to_layout.iterator();
    while (iter.next()) |entry| {
        if (!self.seen_this_frame.isSet(entry.value_ptr.*)) {
            try to_remove.append(entry.key_ptr.*);
        }
    }

    for (to_remove.items) |widget_hash| {
        const layout_index = self.widget_to_layout.get(widget_hash).?;
        self.layout_engine.removeElement(layout_index);
        _ = self.widget_to_layout.remove(widget_hash);
    }

    // Compute layout for dirty elements
    try self.layout_engine.computeLayout(self.viewport_width, self.viewport_height);
}
```

### Memory Budget by Platform

| Platform | Max Widgets | Per-Widget | Total | % of Budget |
|----------|-------------|------------|-------|-------------|
| **Desktop** | 4096 | 200 bytes | 800 KB | <1% of 1GB |
| **Mobile** | 1024 | 200 bytes | 200 KB | <0.1% of 200MB |
| **Embedded** | 64 | 80 bytes* | 5 KB | 15% of 32KB |

*Embedded uses compact configuration: smaller FlexStyle, no caching.

### Embedded Optimization

For 32KB RAM targets, use compact mode:

```zig
pub const EmbeddedConfig = struct {
    pub const MAX_ELEMENTS = 64;
    pub const CACHE_ENABLED = false;      // Save 48 bytes/element
    pub const DEBUG_ENABLED = false;      // No debug strings
    pub const FlexStyle = FlexStyleCompact; // 32 bytes vs 56
};

// Compact per-widget cost:
// - FlexStyle:        32 bytes (vs 56)
// - Rect:             16 bytes
// - Tree links:       12 bytes
// - Widget mapping:   12 bytes
// - Widget meta:       7 bytes
// - Seen bit:          0.125 bytes
// ─────────────────────────────
// Total:             ~80 bytes per widget
//
// 64 widgets × 80 bytes = 5 KB (15% of 32KB budget)
```

### Required Layout Engine Extensions

The reconciliation system requires these additions to the layout engine:

```zig
/// Remove element from tree (for widgets that disappeared)
pub fn removeElement(self: *LayoutEngine, index: u32) void {
    // 1. Unlink from parent's child list
    // 2. Recursively remove children
    // 3. Add index to free list for reuse
}

/// Move element to new parent (for re-parenting)
pub fn reparent(self: *LayoutEngine, index: u32, new_parent: u32) void {
    // 1. Unlink from old parent
    // 2. Link to new parent
    // 3. Mark both parents dirty
}

/// Reorder siblings (for order changes)
pub fn reorderSiblings(self: *LayoutEngine, parent: u32, new_order: []const u32) void {
    // Rebuild sibling linked list in new order
}
```

---

## Draw System

zig-gui uses a **Bring Your Own Renderer (BYOR)** architecture, inspired by Dear ImGui's backend system. The library outputs draw commands; the user implements rendering however they want.

### Why BYOR?

| Approach | Pros | Cons |
|----------|------|------|
| Built-in renderer | Zero setup | Bloated binary, limited customization |
| Single backend abstraction | Consistent API | Leaky abstraction, LCD problem |
| **BYOR (draw commands)** | **Maximum flexibility, minimal core** | **Requires backend implementation** |

BYOR aligns with zig-gui's philosophy:
- **Layered architecture**: Use what you need, bring what you have
- **Embedded support**: 32KB targets can use software rasterizer
- **Game engine integration**: Render with engine's existing pipeline
- **Desktop apps**: Use GPU-accelerated backends (OpenGL, Vulkan, Metal)

### Draw Pipeline

```
Widget Calls → Layout Compute → Draw Generation → Backend Render
    │               │                │                  │
    ▼               ▼                ▼                  ▼
Store render   Flexbox          Generate          User-provided
info (labels,  positions        DrawCommands      implementation
colors, etc.)  computed         from widgets      renders to screen
```

**Key insight**: Widget functions store render info (labels, colors), but draw commands are generated **after** layout computation. This enables:
- Correct clipping (need final positions)
- Proper z-ordering (layer system)
- Batched rendering (sort by texture, shader)

### Draw Primitives

```zig
pub const DrawPrimitive = union(enum) {
    /// Filled rectangle (backgrounds, buttons)
    fill_rect: FillRect,

    /// Stroked rectangle (borders, outlines)
    stroke_rect: StrokeRect,

    /// Text rendering
    text: TextDraw,

    /// Line segment
    line: LineDraw,

    /// Custom vertices (advanced: gradients, custom shapes)
    vertices: VerticesDraw,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
        corner_radius: f32 = 0,
    };

    pub const StrokeRect = struct {
        rect: Rect,
        color: Color,
        stroke_width: f32 = 1,
        corner_radius: f32 = 0,
    };

    pub const TextDraw = struct {
        position: Point,
        text: []const u8,       // Pointer to string (lifetime: frame)
        color: Color,
        font_size: f32 = 14,
        font_id: u16 = 0,       // Backend-specific font handle
    };

    pub const LineDraw = struct {
        start: Point,
        end: Point,
        color: Color,
        width: f32 = 1,
    };

    pub const VerticesDraw = struct {
        vertices: []const Vertex,
        indices: []const u16,
        texture_id: u32 = 0,    // 0 = no texture
    };

    pub const Vertex = struct {
        pos: [2]f32,
        uv: [2]f32 = .{ 0, 0 },
        color: [4]u8,           // RGBA
    };
};
```

### Draw Command

```zig
pub const DrawCommand = struct {
    /// The primitive to draw
    primitive: DrawPrimitive,

    /// Clip rectangle (null = no clipping)
    clip_rect: ?Rect = null,

    /// Layer for z-ordering (higher = on top)
    layer: u16 = 0,

    /// Source widget ID (for debugging, hit testing)
    widget_id: u32 = 0,
};
```

### Draw List

The `DrawList` accumulates commands during draw generation:

```zig
pub const DrawList = struct {
    commands: std.ArrayList(DrawCommand),
    allocator: std.mem.Allocator,

    // State stacks for hierarchical rendering
    clip_stack: std.BoundedArray(Rect, 16) = .{},
    layer_stack: std.BoundedArray(u16, 16) = .{},

    current_layer: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{
            .commands = std.ArrayList(DrawCommand).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.commands.deinit();
    }

    pub fn clear(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.clip_stack.len = 0;
        self.layer_stack.len = 0;
        self.current_layer = 0;
    }

    // === Drawing functions ===

    pub fn addFilledRect(self: *DrawList, rect: Rect, color: Color) void {
        self.addFilledRectEx(rect, color, 0);
    }

    pub fn addFilledRectEx(self: *DrawList, rect: Rect, color: Color, corner_radius: f32) void {
        self.commands.append(.{
            .primitive = .{ .fill_rect = .{
                .rect = rect,
                .color = color,
                .corner_radius = corner_radius,
            }},
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addStrokeRect(self: *DrawList, rect: Rect, color: Color, width: f32) void {
        self.commands.append(.{
            .primitive = .{ .stroke_rect = .{
                .rect = rect,
                .color = color,
                .stroke_width = width,
            }},
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addText(self: *DrawList, pos: Point, text: []const u8, color: Color) void {
        self.commands.append(.{
            .primitive = .{ .text = .{
                .position = pos,
                .text = text,
                .color = color,
            }},
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    pub fn addLine(self: *DrawList, start: Point, end: Point, color: Color, width: f32) void {
        self.commands.append(.{
            .primitive = .{ .line = .{
                .start = start,
                .end = end,
                .color = color,
                .width = width,
            }},
            .clip_rect = self.currentClip(),
            .layer = self.current_layer,
        }) catch {};
    }

    // === Clip stack ===

    pub fn pushClip(self: *DrawList, rect: Rect) void {
        const clipped = if (self.currentClip()) |current|
            rect.intersect(current)
        else
            rect;
        self.clip_stack.append(clipped) catch {};
    }

    pub fn popClip(self: *DrawList) void {
        _ = self.clip_stack.pop();
    }

    pub fn currentClip(self: *const DrawList) ?Rect {
        if (self.clip_stack.len == 0) return null;
        return self.clip_stack.buffer[self.clip_stack.len - 1];
    }

    // === Layer stack ===

    pub fn pushLayer(self: *DrawList) void {
        self.layer_stack.append(self.current_layer) catch {};
        self.current_layer += 1;
    }

    pub fn popLayer(self: *DrawList) void {
        if (self.layer_stack.pop()) |prev| {
            self.current_layer = prev;
        }
    }
};
```

### Draw Data

The output passed to backends:

```zig
pub const DrawData = struct {
    /// All draw commands for this frame
    commands: []const DrawCommand,

    /// Display dimensions
    display_size: Size,

    /// Framebuffer scale (for high-DPI: 2.0 on Retina)
    framebuffer_scale: f32 = 1.0,

    /// Total vertex count (for backends that pre-allocate)
    total_vertex_count: u32 = 0,

    /// Total index count
    total_index_count: u32 = 0,
};
```

### Render Backend Interface

Backends implement this vtable:

```zig
pub const RenderBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called at start of frame
        beginFrame: *const fn (ptr: *anyopaque, data: *const DrawData) void,

        /// Render all commands
        render: *const fn (ptr: *anyopaque, data: *const DrawData) void,

        /// Called at end of frame (present, swap buffers)
        endFrame: *const fn (ptr: *anyopaque) void,

        /// Create texture from pixel data, returns texture ID
        createTexture: *const fn (
            ptr: *anyopaque,
            width: u32,
            height: u32,
            pixels: []const u8,
        ) u32,

        /// Destroy texture
        destroyTexture: *const fn (ptr: *anyopaque, texture_id: u32) void,

        /// Get text dimensions (for layout)
        measureText: *const fn (
            ptr: *anyopaque,
            text: []const u8,
            font_size: f32,
            font_id: u16,
        ) Size,
    };

    // Convenience wrappers
    pub fn beginFrame(self: RenderBackend, data: *const DrawData) void {
        self.vtable.beginFrame(self.ptr, data);
    }

    pub fn render(self: RenderBackend, data: *const DrawData) void {
        self.vtable.render(self.ptr, data);
    }

    pub fn endFrame(self: RenderBackend) void {
        self.vtable.endFrame(self.ptr);
    }

    pub fn measureText(self: RenderBackend, text: []const u8, font_size: f32, font_id: u16) Size {
        return self.vtable.measureText(self.ptr, text, font_size, font_id);
    }
};
```

### Widget Render Info

Widgets store render information during the UI function, which is used later to generate draw commands:

```zig
pub const WidgetRenderInfo = struct {
    /// Widget type for dispatch
    widget_type: WidgetType,

    /// Display label (for buttons, text)
    /// Points to comptime string = zero cost
    /// Points to runtime string = must outlive frame
    label: ?[]const u8 = null,

    /// Colors (null = use theme defaults)
    background_color: ?Color = null,
    text_color: ?Color = null,
    border_color: ?Color = null,

    /// Visual state
    is_hovered: bool = false,
    is_pressed: bool = false,
    is_focused: bool = false,
    is_disabled: bool = false,

    pub const WidgetType = enum(u8) {
        container,
        button,
        text,
        text_input,
        checkbox,
        slider,
        separator,
        image,
        custom,
    };
};
```

### GUI Integration

The GUI generates draw commands after layout:

```zig
pub const GUI = struct {
    // ... existing fields ...

    draw_list: DrawList,
    render_info: std.AutoHashMap(u32, WidgetRenderInfo),
    backend: ?RenderBackend = null,

    /// Called after endFrame() computes layout
    pub fn generateDrawCommands(self: *GUI) void {
        self.draw_list.clear();

        // Traverse widgets in tree order (for proper z-ordering)
        self.generateForSubtree(ROOT_INDEX);
    }

    fn generateForSubtree(self: *GUI, layout_index: u32) void {
        const rect = self.layout_engine.getRect(layout_index);
        const widget_id = self.layout_to_widget.get(layout_index) orelse return;
        const info = self.render_info.get(widget_id) orelse return;

        // Push clip for containers with overflow: hidden
        const needs_clip = self.shouldClip(layout_index);
        if (needs_clip) self.draw_list.pushClip(rect);

        // Generate draw commands based on widget type
        switch (info.widget_type) {
            .button => self.drawButton(rect, info),
            .text => self.drawText(rect, info),
            .container => self.drawContainer(rect, info),
            // ... other widget types
            else => {},
        }

        // Recurse to children
        var child = self.layout_engine.getFirstChild(layout_index);
        while (child != NULL_INDEX) {
            self.generateForSubtree(child);
            child = self.layout_engine.getNextSibling(child);
        }

        if (needs_clip) self.draw_list.popClip();
    }

    fn drawButton(self: *GUI, rect: Rect, info: WidgetRenderInfo) void {
        const theme = self.style_system.theme;

        // Background
        const bg_color = if (info.is_pressed)
            theme.button_pressed
        else if (info.is_hovered)
            theme.button_hovered
        else
            info.background_color orelse theme.button_normal;

        self.draw_list.addFilledRectEx(rect, bg_color, theme.corner_radius);

        // Border
        if (info.is_focused) {
            self.draw_list.addStrokeRect(rect, theme.focus_color, 2);
        }

        // Label
        if (info.label) |label| {
            const text_color = info.text_color orelse theme.text_primary;
            const text_pos = self.centerTextInRect(label, rect);
            self.draw_list.addText(text_pos, label, text_color);
        }
    }

    fn drawText(self: *GUI, rect: Rect, info: WidgetRenderInfo) void {
        if (info.label) |label| {
            const color = info.text_color orelse self.style_system.theme.text_primary;
            self.draw_list.addText(.{ .x = rect.x, .y = rect.y }, label, color);
        }
    }

    fn drawContainer(self: *GUI, rect: Rect, info: WidgetRenderInfo) void {
        // Only draw background if explicitly set
        if (info.background_color) |bg| {
            self.draw_list.addFilledRect(rect, bg);
        }
        if (info.border_color) |border| {
            self.draw_list.addStrokeRect(rect, border, 1);
        }
    }

    /// Get final draw data for backend
    pub fn getDrawData(self: *const GUI) DrawData {
        return .{
            .commands = self.draw_list.commands.items,
            .display_size = .{
                .width = self.viewport_width,
                .height = self.viewport_height,
            },
            .framebuffer_scale = self.framebuffer_scale,
        };
    }
};
```

### Example Backend: SDL + OpenGL

```zig
pub const SdlOpenGlBackend = struct {
    window: *SDL_Window,
    gl_context: SDL_GLContext,
    shader_program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    ebo: GLuint,

    pub fn init(window: *SDL_Window) !SdlOpenGlBackend {
        const gl_context = SDL_GL_CreateContext(window);
        // ... compile shaders, create buffers ...
        return .{ ... };
    }

    pub fn interface(self: *SdlOpenGlBackend) RenderBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = RenderBackend.VTable{
        .beginFrame = beginFrameImpl,
        .render = renderImpl,
        .endFrame = endFrameImpl,
        .createTexture = createTextureImpl,
        .destroyTexture = destroyTextureImpl,
        .measureText = measureTextImpl,
    };

    fn renderImpl(ptr: *anyopaque, data: *const DrawData) void {
        const self: *SdlOpenGlBackend = @ptrCast(@alignCast(ptr));

        glUseProgram(self.shader_program);
        glBindVertexArray(self.vao);

        for (data.commands) |cmd| {
            // Apply clip rect as scissor
            if (cmd.clip_rect) |clip| {
                glEnable(GL_SCISSOR_TEST);
                glScissor(
                    @intFromFloat(clip.x * data.framebuffer_scale),
                    @intFromFloat((data.display_size.height - clip.y - clip.height) * data.framebuffer_scale),
                    @intFromFloat(clip.width * data.framebuffer_scale),
                    @intFromFloat(clip.height * data.framebuffer_scale),
                );
            } else {
                glDisable(GL_SCISSOR_TEST);
            }

            // Dispatch by primitive type
            switch (cmd.primitive) {
                .fill_rect => |r| self.renderFilledRect(r),
                .stroke_rect => |r| self.renderStrokeRect(r),
                .text => |t| self.renderText(t),
                .line => |l| self.renderLine(l),
                .vertices => |v| self.renderVertices(v),
            }
        }
    }

    fn endFrameImpl(ptr: *anyopaque) void {
        const self: *SdlOpenGlBackend = @ptrCast(@alignCast(ptr));
        SDL_GL_SwapWindow(self.window);
    }
};
```

### Example Backend: Software Rasterizer (Embedded)

```zig
pub const SoftwareBackend = struct {
    framebuffer: []u32,  // ARGB pixels
    width: u32,
    height: u32,

    pub fn init(buffer: []u32, width: u32, height: u32) SoftwareBackend {
        return .{
            .framebuffer = buffer,
            .width = width,
            .height = height,
        };
    }

    pub fn interface(self: *SoftwareBackend) RenderBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = RenderBackend.VTable{
        .beginFrame = beginFrameImpl,
        .render = renderImpl,
        .endFrame = endFrameImpl,
        .createTexture = createTextureImpl,
        .destroyTexture = destroyTextureImpl,
        .measureText = measureTextImpl,
    };

    fn renderImpl(ptr: *anyopaque, data: *const DrawData) void {
        const self: *SoftwareBackend = @ptrCast(@alignCast(ptr));

        for (data.commands) |cmd| {
            switch (cmd.primitive) {
                .fill_rect => |r| self.fillRect(r, cmd.clip_rect),
                .stroke_rect => |r| self.strokeRect(r, cmd.clip_rect),
                .text => |t| self.drawText(t, cmd.clip_rect),
                .line => |l| self.drawLine(l, cmd.clip_rect),
                .vertices => {}, // Skip complex primitives on embedded
            }
        }
    }

    fn fillRect(self: *SoftwareBackend, r: FillRect, clip: ?Rect) void {
        const bounds = if (clip) |c| r.rect.intersect(c) else r.rect;
        const x0 = @max(0, @as(i32, @intFromFloat(bounds.x)));
        const y0 = @max(0, @as(i32, @intFromFloat(bounds.y)));
        const x1 = @min(self.width, @as(u32, @intFromFloat(bounds.x + bounds.width)));
        const y1 = @min(self.height, @as(u32, @intFromFloat(bounds.y + bounds.height)));

        const color = r.color.toARGB();
        var y: u32 = @intCast(y0);
        while (y < y1) : (y += 1) {
            var x: u32 = @intCast(x0);
            while (x < x1) : (x += 1) {
                self.framebuffer[y * self.width + x] = color;
            }
        }
    }
};
```

### Memory Budget (Embedded)

```
DrawCommand:      ~48 bytes (primitive union + clip + layer + id)
DrawList:         ~64 bytes base + commands array

Typical frame (32 widgets × 2 commands each = 64 commands):
64 × 48 = 3 KB

Total draw system overhead:
- DrawList struct:          64 bytes
- Commands (64 max):     3,072 bytes
- Render info (32 max):    512 bytes
─────────────────────────────────────
Total:                   ~3.6 KB (11% of 32KB budget)
```

For extreme memory constraints, use immediate rendering mode (no command buffering):

```zig
// Immediate mode: render directly during traversal
pub fn renderImmediate(self: *GUI, backend: RenderBackend) void {
    backend.beginFrame(&.{ .display_size = self.display_size });
    self.renderSubtreeImmediate(ROOT_INDEX, backend);
    backend.endFrame();
}
```

### Provided Backends

zig-gui will ship reference implementations:

| Backend | Target | Dependencies |
|---------|--------|--------------|
| `SdlOpenGlBackend` | Desktop (Windows, Linux, macOS) | SDL2, OpenGL 3.3 |
| `SdlSoftwareBackend` | Desktop (no GPU) | SDL2 |
| `SoftwareBackend` | Embedded, Headless | None |
| `WebGpuBackend` | Browser | WebGPU |
| `MetalBackend` | macOS, iOS | Metal |
| `VulkanBackend` | Desktop, Android | Vulkan |

Users can also implement custom backends (game engine integration, etc.).

---

## Platform Integration

### Desktop (SDL)

```zig
pub const SdlPlatform = struct {
    window: *SDL_Window,
    gl_context: SDL_GLContext,
    renderer: Renderer,

    pub fn init(allocator: std.mem.Allocator, config: SdlConfig) !SdlPlatform {
        // Initialize SDL, create window and GL context
    }

    pub fn deinit(self: *SdlPlatform) void {
        // Release GL context, destroy window, quit SDL
    }

    pub fn interface(self: *SdlPlatform) PlatformInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .waitEvent = waitEventImpl,
                .pollEvent = pollEventImpl,
                .present = presentImpl,
            },
        };
    }
};

// Usage
var platform = try SdlPlatform.init(allocator, .{ .width = 800, .height = 600 });
defer platform.deinit();

var app = try App(MyState).init(allocator, platform.interface(), .{ .mode = .event_driven });
defer app.deinit();

try app.run(MyUI, &state);
```

### Game Engine

```zig
var platform = GameEnginePlatform.init(engine_renderer);
var app = try App(HudState).init(allocator, platform.interface(), .{ .mode = .game_loop });

while (game.running) {
    game.update(dt);
    app.processEvents();
    app.renderFrame(HudUI, &state);
    game.present();
}
```

### Embedded

```zig
var platform = FramebufferPlatform.init(.{
    .buffer = display_buffer,
    .width = 320,
    .height = 240,
});
var app = try App(DeviceState).init(arena.allocator(), platform.interface(), .{ .mode = .minimal });

fn buttonIsr() void {
    platform.injectEvent(.{ .button_press = .a });
    app.renderFrame(ControlPanelUI, &state);
}
```

### Headless (Testing)

```zig
var headless = HeadlessPlatform.init();
var app = try App(TestState).init(testing.allocator, headless.interface(), .{});
defer app.deinit();

headless.injectClick(100, 50);
try app.processEvents();

try testing.expectEqual(1, state.counter.get());
```

---

## Public API

The public API is designed to impress senior C engineers while working seamlessly across WASM, embedded, Python FFI, and Zig native.

### Architecture: Three Layers

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Language Bindings (Python, TypeScript, etc.)      │
│  - Pythonic context managers, closures, generators          │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: GUI Context (immediate-mode widgets)              │
│  - Widget functions, input handling, rendering              │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Layout Engine (pure layout, no UI)                │
│  - Flexbox computation, tree management                     │
├─────────────────────────────────────────────────────────────┤
│  Layer 0: Style (data only, no functions)                   │
│  - Plain C structs, serializable, versionable               │
└─────────────────────────────────────────────────────────────┘
```

**Use cases by layer:**
- Game engine HUD: Layer 1 only (bring your own rendering)
- Desktop app: Layer 2 (full immediate-mode GUI)
- Python tool: Layer 3 (ergonomic bindings)
- Custom widget library: Layer 1 + custom rendering

### Design Principles

1. **u32 handles everywhere** - No pointers in API (WASM-friendly, stable ABI)
2. **56-byte `ZglStyle`** - Cache-line aligned, trivially serializable
3. **Sentinel values** - `ZGL_AUTO` / `ZGL_NONE` instead of optional types
4. **Separate layers** - Use only what you need
5. **~27 total functions** - Minimal surface area, maximum composability

---

## Layer 0: Style (Data Structures)

Plain C structs with no methods. Fully serializable. Stable ABI.

```c
// ============================================================================
// Core Types (ABI stable, versioned)
// ============================================================================

#define ZGL_API_VERSION 1

// Opaque handle type - u32 for WASM compatibility
typedef uint32_t ZglNode;
typedef uint32_t ZglId;

// Sentinel values
#define ZGL_NULL  ((ZglNode)0xFFFFFFFF)
#define ZGL_AUTO  (-1.0f)
#define ZGL_NONE  (1e30f)

// Result rectangle (16 bytes)
typedef struct {
    float x, y, width, height;
} ZglRect;

// ============================================================================
// Style Structure (56 bytes, cache-line aligned)
// ============================================================================

typedef enum : uint8_t {
    ZGL_ROW = 0,
    ZGL_COLUMN = 1,
} ZglDirection;

typedef enum : uint8_t {
    ZGL_JUSTIFY_START = 0,
    ZGL_JUSTIFY_CENTER = 1,
    ZGL_JUSTIFY_END = 2,
    ZGL_JUSTIFY_SPACE_BETWEEN = 3,
    ZGL_JUSTIFY_SPACE_AROUND = 4,
    ZGL_JUSTIFY_SPACE_EVENLY = 5,
} ZglJustify;

typedef enum : uint8_t {
    ZGL_ALIGN_START = 0,
    ZGL_ALIGN_CENTER = 1,
    ZGL_ALIGN_END = 2,
    ZGL_ALIGN_STRETCH = 3,
} ZglAlign;

typedef struct {
    // Flexbox properties (4 bytes)
    ZglDirection direction;
    ZglJustify justify;
    ZglAlign align;
    uint8_t _reserved;

    // Flex item properties (8 bytes)
    float flex_grow;
    float flex_shrink;

    // Dimensions (24 bytes)
    float width;        // ZGL_AUTO = content-sized
    float height;
    float min_width;
    float min_height;
    float max_width;    // ZGL_NONE = no maximum
    float max_height;

    // Spacing (20 bytes)
    float gap;
    float padding_top;
    float padding_right;
    float padding_bottom;
    float padding_left;
} ZglStyle;

// Default style initializer
#define ZGL_STYLE_DEFAULT ((ZglStyle){ \
    .direction = ZGL_COLUMN, \
    .justify = ZGL_JUSTIFY_START, \
    .align = ZGL_ALIGN_STRETCH, \
    .flex_grow = 0.0f, \
    .flex_shrink = 1.0f, \
    .width = ZGL_AUTO, \
    .height = ZGL_AUTO, \
    .min_width = 0.0f, \
    .min_height = 0.0f, \
    .max_width = ZGL_NONE, \
    .max_height = ZGL_NONE, \
    .gap = 0.0f, \
})
```

---

## Layer 1: Layout Engine API

Pure layout computation. No rendering, no input handling, no platform dependencies.

```c
// ============================================================================
// Layout Engine (~12 functions)
// ============================================================================

// --- Lifecycle ---
ZglLayout* zgl_layout_create(uint32_t max_nodes);
void       zgl_layout_destroy(ZglLayout* layout);

// --- Tree Building ---
ZglNode zgl_layout_add(ZglLayout* layout, ZglNode parent, const ZglStyle* style);
void    zgl_layout_remove(ZglLayout* layout, ZglNode node);
void    zgl_layout_set_style(ZglLayout* layout, ZglNode node, const ZglStyle* style);
void    zgl_layout_reparent(ZglLayout* layout, ZglNode node, ZglNode new_parent);

// --- Computation ---
void zgl_layout_compute(ZglLayout* layout, float width, float height);

// --- Queries ---
ZglRect zgl_layout_get_rect(const ZglLayout* layout, ZglNode node);
ZglNode zgl_layout_get_parent(const ZglLayout* layout, ZglNode node);
ZglNode zgl_layout_get_first_child(const ZglLayout* layout, ZglNode node);
ZglNode zgl_layout_get_next_sibling(const ZglLayout* layout, ZglNode node);

// --- Statistics ---
uint32_t zgl_layout_node_count(const ZglLayout* layout);
float    zgl_layout_cache_hit_rate(const ZglLayout* layout);
```

### Layer 1 Example (Pure C, No Framework)

```c
ZglLayout* layout = zgl_layout_create(256);

// Build a toolbar
ZglStyle toolbar_style = ZGL_STYLE_DEFAULT;
toolbar_style.direction = ZGL_ROW;
toolbar_style.gap = 8.0f;
toolbar_style.height = 48.0f;

ZglNode toolbar = zgl_layout_add(layout, ZGL_NULL, &toolbar_style);

ZglStyle btn_style = ZGL_STYLE_DEFAULT;
btn_style.width = 100.0f;
btn_style.height = 32.0f;

ZglNode btn_file = zgl_layout_add(layout, toolbar, &btn_style);
ZglNode btn_edit = zgl_layout_add(layout, toolbar, &btn_style);

// Compute layout
zgl_layout_compute(layout, 1920.0f, 1080.0f);

// Query results
ZglRect r = zgl_layout_get_rect(layout, btn_file);
printf("File button at (%.0f, %.0f)\n", r.x, r.y);

zgl_layout_destroy(layout);
```

---

## Layer 2: GUI Context API

Immediate-mode widgets with automatic reconciliation.

```c
// ============================================================================
// GUI Context (~15 functions)
// ============================================================================

// --- Lifecycle ---
typedef struct {
    uint32_t max_widgets;
    float viewport_width;
    float viewport_height;
} ZglGuiConfig;

ZglGui* zgl_gui_create(const ZglGuiConfig* config);
void    zgl_gui_destroy(ZglGui* gui);

// --- Frame Lifecycle ---
void zgl_gui_begin_frame(ZglGui* gui);
void zgl_gui_end_frame(ZglGui* gui);
void zgl_gui_set_viewport(ZglGui* gui, float width, float height);

// --- Widget ID System ---
ZglId zgl_id(const char* label);
ZglId zgl_id_index(const char* label, uint32_t index);
ZglId zgl_id_combine(ZglId parent, ZglId child);

void zgl_gui_push_id(ZglGui* gui, ZglId id);
void zgl_gui_pop_id(ZglGui* gui);

// --- Widget Declaration ---
bool zgl_gui_widget(ZglGui* gui, ZglId id, const ZglStyle* style);
void zgl_gui_begin(ZglGui* gui, ZglId id, const ZglStyle* style);
void zgl_gui_end(ZglGui* gui);

// --- Queries ---
ZglRect zgl_gui_get_rect(const ZglGui* gui, ZglId id);
bool    zgl_gui_hit_test(const ZglGui* gui, ZglId id, float x, float y);

// --- Input State ---
void zgl_gui_set_mouse(ZglGui* gui, float x, float y, bool down);
bool zgl_gui_clicked(const ZglGui* gui, ZglId id);
bool zgl_gui_hovered(const ZglGui* gui, ZglId id);

// --- Direct Layout Access ---
ZglLayout* zgl_gui_get_layout(ZglGui* gui);
```

### Layer 2 Example

```c
ZglGui* gui = zgl_gui_create(&(ZglGuiConfig){
    .max_widgets = 1024,
    .viewport_width = 800,
    .viewport_height = 600,
});

// Cache IDs at init time (or use static initialization)
// This avoids repeated hashing in the render loop
static ZglId id_toolbar, id_file, id_edit, id_view, id_content;
id_toolbar = zgl_id("toolbar");
id_file = zgl_id("file");
id_edit = zgl_id("edit");
id_view = zgl_id("view");
id_content = zgl_id("content");

while (running) {
    zgl_gui_set_mouse(gui, mouse_x, mouse_y, mouse_down);
    zgl_gui_begin_frame(gui);

    // Toolbar - begin() auto-pushes ID scope
    ZglStyle toolbar = { .direction = ZGL_ROW, .height = 48, .gap = 8 };
    zgl_gui_begin(gui, id_toolbar, &toolbar);
    {
        ZglStyle button = { .width = 80, .height = 32 };

        // Child IDs are scoped: toolbar ^ file, toolbar ^ edit, etc.
        zgl_gui_widget(gui, id_file, &button);
        if (zgl_gui_clicked(gui, id_file)) {
            open_file_menu();
        }

        zgl_gui_widget(gui, id_edit, &button);
        zgl_gui_widget(gui, id_view, &button);
    }
    zgl_gui_end(gui);  // Pops toolbar scope

    // Dynamic list - use zgl_id_index for loops
    zgl_gui_begin(gui, id_content, &ZGL_STYLE_DEFAULT);
    {
        for (int i = 0; i < item_count; i++) {
            // zgl_id_index combines base + index efficiently
            ZglId item_id = zgl_id_index("item", i);
            zgl_gui_widget(gui, item_id, &item_style);

            if (zgl_gui_clicked(gui, item_id)) {
                select_item(i);
            }
        }
    }
    zgl_gui_end(gui);

    zgl_gui_end_frame(gui);
    render(gui);
}

zgl_gui_destroy(gui);
```

**Best practice**: Cache frequently-used IDs as static variables. The `zgl_id()` function is pure (~10ns), but caching eliminates even that overhead in hot loops.

---

## Platform-Specific Optimizations

### Zig Native

Zero-cost comptime hashing:

```zig
pub fn main() !void {
    var gui = try zgl.Gui.init(.{});
    defer gui.deinit();

    while (running) {
        gui.beginFrame();
        defer gui.endFrame();

        // begin() auto-pushes ID scope + comptime hash
        gui.begin("toolbar", .{ .direction = .row, .height = 48 });
        defer gui.end();

        gui.button("file");  // ID: toolbar ^ file
        if (gui.wasClicked("file")) {
            try openFileMenu();
        }

        // For loops: use beginIndexed
        for (items, 0..) |item, i| {
            gui.beginIndexed("item", i, .{ .height = 40 });
            defer gui.end();

            gui.text(item.name);
            gui.button("delete");  // ID: toolbar ^ item ^ i ^ delete
            if (gui.wasClickedIndexed("delete", i)) {
                items.remove(i);
            }
        }
    }
}
```

### WebAssembly

Pre-computed IDs at build time:

```typescript
// Build-time: Generate ID constants
const IDS = {
    toolbar: hash("toolbar"),  // Computed at build time
    file: hash("file"),
};

// Runtime: Just pass u32 IDs
function render() {
    gui.beginFrame();
    gui.begin(IDS.toolbar, TOOLBAR_STYLE);
    gui.widget(IDS.file, BUTTON_STYLE);
    gui.end();
    gui.endFrame();
}
```

### Python FFI

Context managers for ergonomic API:

```python
gui = zgl.Gui(max_widgets=1024)

while running:
    gui.set_mouse(mouse_x, mouse_y, mouse_down)

    with gui.frame():
        # container() auto-pushes ID scope
        with gui.container("toolbar", direction="row", height=48):
            if gui.widget("file", width=80, height=32).clicked:
                open_file_menu()

        with gui.container("content"):
            for i, item in enumerate(items):
                # Use widget_indexed for loops - avoids string allocation
                # ID = content ^ item ^ i (computed efficiently)
                if gui.widget_indexed("item", i, height=40).clicked:
                    select_item(i)

        # For user-generated content, use widget_dynamic
        for tab in user_tabs:
            with gui.container_dynamic(tab.name):
                render_tab_content(tab)
```

**Best practice**: Use `widget_indexed("base", i)` for loops instead of f-strings like `f"item_{i}"`. This avoids string allocation and uses efficient index-based hashing.

### Embedded (32KB RAM)

Stack allocation, no heap in hot path:

```c
// Compile with: -DZGL_MAX_NODES=64

ZglLayoutEmbedded layout_storage;
ZglLayout* layout = zgl_layout_init_embedded(&layout_storage);

// All operations use fixed-size arrays
ZglNode root = zgl_layout_add(layout, ZGL_NULL, &root_style);
zgl_layout_compute(layout, SCREEN_WIDTH, SCREEN_HEIGHT);

ZglRect r = zgl_layout_get_rect(layout, root);
draw_to_framebuffer(r);
```

---

## Memory Model

### Ownership Rules

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Application                        │
│  - Owns: ZglGui*, ZglLayout* handles                       │
│  - Owns: Style structs (stack or heap, your choice)         │
│  - Borrows: ZglRect results (valid until next compute)      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     zgl Library                             │
│  - Owns: Internal node arrays, hash maps, free lists        │
│  - Allocates: Once at create(), frees at destroy()          │
│  - Hot path: Zero allocations                               │
└─────────────────────────────────────────────────────────────┘
```

### Memory Budget

| Platform | Max Nodes | Per-Node | Total |
|----------|-----------|----------|-------|
| Embedded | 64 | 80 B | 5 KB |
| Mobile | 1024 | 180 B | 180 KB |
| Desktop | 4096 | 200 B | 800 KB |

---

## Error Handling

```c
typedef enum {
    ZGL_OK = 0,
    ZGL_ERROR_OUT_OF_MEMORY = 1,
    ZGL_ERROR_CAPACITY_EXCEEDED = 2,
    ZGL_ERROR_INVALID_NODE = 3,
} ZglError;

// Get last error
ZglError zgl_get_last_error(void);

// Checked version returns error code
ZglError zgl_layout_add_checked(ZglLayout* layout, ZglNode parent,
                                 const ZglStyle* style, ZglNode* out_node);
```

---

## Thread Safety

```
SINGLE-THREADED: ZglGui, ZglLayout
  - All API calls must be from the same thread

THREAD-SAFE: zgl_id(), zgl_id_index(), zgl_id_combine()
  - Pure functions, no shared state
  - Can pre-compute IDs on any thread

IMMUTABLE: ZglStyle, ZglRect
  - Plain data, copy freely between threads
```

---

## ABI Versioning

```c
#define ZGL_API_VERSION_MAJOR 1
#define ZGL_API_VERSION_MINOR 0

uint32_t zgl_get_version(void);    // Runtime version check
size_t   zgl_style_size(void);     // Struct size for compatibility
```

---

## Language Bindings

The C API enables idiomatic bindings for any language. Below are reference patterns.

### Python (Context Managers)

```python
from zig_gui import GUI, Tracked

class Counter:
    count = Tracked(0)

    def render(self, gui: GUI):
        with gui.column():
            gui.text(f"Count: {self.count}")

            gui.button("Increment")
            if gui.was_clicked("Increment"):
                self.count += 1

            # Loops with automatic index scoping
            with gui.scope("items"):
                for i, item in enumerate(self.items):
                    with gui.scope(i):
                        gui.text(item.name)
                        gui.button("Delete")
                        if gui.was_clicked("Delete"):
                            self.items.remove(item)
```

The wrapper is thin:

```python
@contextmanager
def scope(self, id):
    if isinstance(id, int):
        _lib.zig_gui_push_index(self._ctx, id)
    else:
        _lib.zig_gui_push_id(self._ctx, str(id).encode())
    try:
        yield
    finally:
        _lib.zig_gui_pop_id(self._ctx)

@contextmanager
def column(self, **options):
    _lib.zig_gui_push_column(self._ctx, options)
    try:
        yield
    finally:
        _lib.zig_gui_pop_layout(self._ctx)
```

### TypeScript (Closures)

```typescript
class Counter {
    count = tracked(0);

    render(gui: GUI) {
        gui.column(() => {
            gui.text(`Count: ${this.count}`);

            gui.button("Increment");
            if (gui.wasClicked("Increment")) {
                this.count++;
            }

            gui.scope("items", () => {
                this.items.forEach((item, i) => {
                    gui.scope(i, () => {
                        gui.text(item.name);
                        gui.button("Delete");
                        if (gui.wasClicked("Delete")) {
                            this.items.splice(i, 1);
                        }
                    });
                });
            });
        });
    }
}
```

### WebAssembly

WASM target uses the same C API with build-time optimization:

```typescript
// Source (developer writes)
gui.button("Settings");

// After esbuild/babel plugin (build output)
gui._buttonHash(0x7a3b2c1d, "Settings");  // Hash pre-computed!
```

Benefits:
- Zero runtime hashing (like Zig comptime)
- Strings still available for display
- Minimal WASM ↔ JS boundary crossing

### Declarative Layer (Optional)

For React/SwiftUI-like DX, a virtual DOM layer can be built on top:

```typescript
// JSX syntax (requires build step)
function SettingsPanel() {
    const [volume, setVolume] = useGuiState(50);

    return (
        <Column>
            <Text>Volume: {volume}</Text>
            <Slider value={volume} onChange={setVolume} min={0} max={100} />
            <Button onClick={() => setVolume(50)}>Reset</Button>
        </Column>
    );
}
```

The framework reconciles JSX → immediate-mode C API calls.

### Binding Architecture

```
┌─────────────────────────────────────┐
│  Declarative Layer (optional)       │
│  - Virtual DOM / Element tree       │
│  - Diffing & reconciliation         │
├─────────────────────────────────────┤
│  Language Bindings                  │
│  - Python: context managers         │
│  - TypeScript: closures             │
│  - Swift: property wrappers         │
├─────────────────────────────────────┤
│  C API (immediate mode)             │
│  - ~20 functions                    │
│  - Runtime string hashing           │
├─────────────────────────────────────┤
│  Zig Core                           │
│  - Comptime string hashing          │
│  - Layout engine                    │
│  - Rendering                        │
└─────────────────────────────────────┘
```

---

## Performance

### Targets

| Metric | Target |
|--------|--------|
| Layout per element | <10μs |
| Desktop idle CPU | 0% |
| Memory per element | <350 bytes |
| Input-to-render latency | <5ms |

### Measured Results

From `BENCHMARKS.md` (run with `zig build test`):

| Scenario | Elements | Dirty % | Per-Element | Total |
|----------|----------|---------|-------------|-------|
| Email Client (incremental) | 81 | 10% | 0.073μs | 0.583μs |
| Email Client (full) | 81 | 100% | 0.029μs | 2.344μs |
| Game HUD | 47 | 5% | 0.107μs | 0.214μs |
| Stress Test | 1011 | 10% | 0.032μs | 3.210μs |

### Comparison

| Engine | Per-Element |
|--------|-------------|
| Taffy | 0.329-0.506μs |
| Yoga | 0.36-0.74μs |
| zig-gui | 0.029-0.107μs |

### Optimizations

1. **Two-Pass Dirty Tracking**: Only recompute dirty subtrees and size-changed children
2. **SIMD Constraints**: Vectorized min/max clamping
3. **Layout Caching**: Skip unchanged elements
4. **SoA Layout**: Cache-friendly data structure

### Validation Methodology

Performance claims must:
1. Measure complete operations (not cherry-picked)
2. Use realistic scenarios
3. Force cache invalidation (vary constraints)
4. Compare same operations across engines
5. Be reproducible

```zig
// Force cache invalidation by varying constraints
for (0..iterations) |iter| {
    const width = 1920.0 + @as(f32, @floatFromInt(iter % 10));
    const height = 1080.0 + @as(f32, @floatFromInt(iter % 10));
    try engine.computeLayout(width, height);
}
```

---

## Profiling

### Zero-Cost Design

Profiling compiles to nothing when disabled:

```zig
// With -Denable_profiling=false (default): zero overhead
// With -Denable_profiling=true: ~30-50ns per zone
```

### Usage

```zig
const profiler = @import("profiler");

fn renderUI(gui: *GUI) !void {
    profiler.zone(@src(), "renderUI", .{});
    defer profiler.endZone();

    // ...
}
```

### Frame Analysis

```zig
profiler.frameStart();
defer profiler.frameEnd();

// After run:
const stats = profiler.getFrameStats();
// stats.frame_number, stats.duration_ms
```

### Export

```bash
# Export to Chrome Tracing format
zig build run -- --export-profile profile.json

# View in chrome://tracing
```

### Build Configuration

```bash
# Development with profiling
zig build -Denable_profiling=true

# Release (profiling disabled)
zig build -Doptimize=ReleaseFast

# Profile optimized build
zig build -Doptimize=ReleaseFast -Denable_profiling=true
```

---

## Development Phases

### Phase 1: Core Foundation
- App execution modes (event_driven, game_loop, minimal)
- Layout engine integration
- Basic immediate-mode API (button, text, container)
- Simple platform backend (SDL)
- Proof of concept: Desktop app with 0% idle CPU

### Phase 2: Developer Experience
- Hot reload system
- Rich components (text input, data table, charts)
- Style system with live editing
- Developer tools (inspector, profiler)

### Phase 3: Platform Support
- Multiple renderers (OpenGL, Vulkan, Metal, Direct2D)
- Mobile support (iOS, Android via C API)
- Web target (WebAssembly + Canvas)
- Game engine plugins (Unity, Unreal, Godot)

### Phase 4: Production
- Performance optimization
- Memory optimization (pooling, arena allocation)
- ABI-stable C API with versioning
- Language bindings (Python, Go, Rust, etc.)
