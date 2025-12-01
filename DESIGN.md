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

fn myApp(gui: *GUI, state: *AppState) !void {
    try gui.text("Counter: {}", .{state.counter.get()});

    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1);
    }

    if (try gui.button("Add Item")) {
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

### ID Stack

Hierarchical scoping for complex UIs:

```zig
pub const IdStack = struct {
    stack: [16]u32 = undefined,  // 64 bytes, fits in cache line
    depth: u8 = 0,
    current_hash: u32 = 0,

    // Debug only
    debug_path: if (builtin.mode == .Debug) std.ArrayList([]const u8) else void,

    pub fn push(self: *IdStack, comptime label: []const u8) void {
        self.pushHash(comptime std.hash.Wyhash.hash(0, label));
        if (builtin.mode == .Debug) self.debug_path.append(label);
    }

    pub fn pushIndex(self: *IdStack, index: usize) void {
        self.pushHash(@truncate(index));
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

### Zig Usage (Zero Cost)

```zig
fn myApp(gui: *GUI, state: *AppState) !void {
    // Simple: label is ID (hash computed at comptime)
    if (try gui.button("Settings")) {
        // ...
    }

    // Scoped: hierarchical IDs
    try gui.pushId("settings_panel");
    defer gui.popId();

    if (try gui.button("Save")) {   // ID = hash("settings_panel") ^ hash("Save")
        // ...
    }

    // Loops: index-based composition
    for (state.items.items, 0..) |item, i| {
        gui.pushIndex(i);
        defer gui.popId();

        try gui.text(item.name);
        if (try gui.button("Delete")) {  // ID = hash("settings_panel") ^ i ^ hash("Delete")
            state.items.ptr().orderedRemove(i);
        }
    }
}
```

### Debug Support

In debug builds, collision detection and path tracing:

```zig
// Debug mode only
pub fn debugIdPath(self: *const GUI) []const u8 {
    // Returns: "settings_panel > 3 > Delete"
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
- O(n) complexity
- SIMD-optimized constraint clamping
- Dirty tracking for incremental updates
- 176 bytes per element

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

### Dirty Tracking

```zig
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
fn myUI(gui: *GUI, state: *AppState) !void {
    if (try gui.button("Save")) { ... }  // Called every frame
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

while (running) {
    zgl_gui_set_mouse(gui, mouse_x, mouse_y, mouse_down);
    zgl_gui_begin_frame(gui);

    // Toolbar
    ZglStyle toolbar = { .direction = ZGL_ROW, .height = 48, .gap = 8 };
    zgl_gui_begin(gui, zgl_id("toolbar"), &toolbar);
    {
        ZglStyle button = { .width = 80, .height = 32 };

        zgl_gui_widget(gui, zgl_id("file"), &button);
        if (zgl_gui_clicked(gui, zgl_id("file"))) {
            open_file_menu();
        }

        zgl_gui_widget(gui, zgl_id("edit"), &button);
        zgl_gui_widget(gui, zgl_id("view"), &button);
    }
    zgl_gui_end(gui);

    // Dynamic list
    zgl_gui_begin(gui, zgl_id("content"), &ZGL_STYLE_DEFAULT);
    {
        for (int i = 0; i < item_count; i++) {
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

        // Comptime ID hashing - zero runtime cost
        gui.begin("toolbar", .{ .direction = .row, .height = 48 });
        defer gui.end();

        if (gui.widget("file", .{ .width = 80 }).clicked()) {
            try openFileMenu();
        }

        for (items, 0..) |_, i| {
            if (gui.widget("item", i, .{ .height = 40 }).clicked()) {
                selectItem(i);
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
        with gui.container("toolbar", direction="row", height=48):
            if gui.widget("file", width=80, height=32).clicked:
                open_file_menu()

        with gui.container("content"):
            for i, item in enumerate(items):
                if gui.widget(f"item_{i}", height=40).clicked:
                    select_item(i)
```

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

            if gui.button("Increment"):
                self.count += 1

            # Loops with automatic index scoping
            with gui.scope("items"):
                for i, item in enumerate(self.items):
                    with gui.scope(i):
                        gui.text(item.name)
                        if gui.button("Delete"):
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

            if (gui.button("Increment")) {
                this.count++;
            }

            gui.scope("items", () => {
                this.items.forEach((item, i) => {
                    gui.scope(i, () => {
                        gui.text(item.name);
                        if (gui.button("Delete")) {
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

1. **Spineless Traversal**: Only process dirty elements
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
