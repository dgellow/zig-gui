# zig-gui Public Layout API

## Design Goals

1. **Impress senior C engineers**: Simple, orthogonal, predictable
2. **Cross-platform excellence**: WASM, embedded, Python FFI, Zig native
3. **Zero hidden costs**: No allocations in hot paths, explicit memory ownership
4. **Minimal surface area**: ~20 functions that compose infinitely

## Architecture: Three Layers

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

// Sentinel value for "no node" / "no parent"
#define ZGL_NULL ((ZglNode)0xFFFFFFFF)

// Result rectangle (16 bytes, cache-line friendly)
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

// Use -1.0f for "auto" dimensions
#define ZGL_AUTO (-1.0f)

// Use INFINITY for "no constraint"
#define ZGL_NONE (1e30f)

typedef struct {
    // === Flexbox properties (4 bytes) ===
    ZglDirection direction;     // row or column
    ZglJustify justify;         // main-axis alignment
    ZglAlign align;             // cross-axis alignment
    uint8_t _reserved;          // padding for alignment

    // === Flex item properties (8 bytes) ===
    float flex_grow;            // 0.0 = don't grow
    float flex_shrink;          // 1.0 = can shrink

    // === Dimensions (24 bytes) ===
    float width;                // ZGL_AUTO = content-sized
    float height;               // ZGL_AUTO = content-sized
    float min_width;            // 0.0 = no minimum
    float min_height;           // 0.0 = no minimum
    float max_width;            // ZGL_NONE = no maximum
    float max_height;           // ZGL_NONE = no maximum

    // === Spacing (20 bytes) ===
    float gap;                  // gap between children
    float padding_top;
    float padding_right;
    float padding_bottom;
    float padding_left;
} ZglStyle;

// Default style initializer (C99 designated initializers)
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
    .padding_top = 0.0f, \
    .padding_right = 0.0f, \
    .padding_bottom = 0.0f, \
    .padding_left = 0.0f, \
})

// Convenience macros for common patterns
#define ZGL_ROW_STYLE ((ZglStyle){ ...ZGL_STYLE_DEFAULT, .direction = ZGL_ROW })
#define ZGL_CENTER_STYLE ((ZglStyle){ ...ZGL_STYLE_DEFAULT, \
    .justify = ZGL_JUSTIFY_CENTER, .align = ZGL_ALIGN_CENTER })
```

**Why this design:**
- 56 bytes fits in a cache line
- No pointers = trivially serializable
- Enums are u8 = stable ABI across compilers
- Default initializer = no "uninitialized style" bugs

---

## Layer 1: Layout Engine (Pure Computation)

The layout engine is a pure function: `(tree, styles) → rects`

No rendering, no input handling, no platform dependencies.

```c
// ============================================================================
// Layout Engine API (~12 functions)
// ============================================================================

// --- Lifecycle ---

// Create a layout engine with given capacity
// Returns NULL on allocation failure
ZglLayout* zgl_layout_create(uint32_t max_nodes);

// Destroy layout engine and free all memory
void zgl_layout_destroy(ZglLayout* layout);

// --- Tree Building ---

// Add a node to the tree. Returns node handle or ZGL_NULL on error.
// parent=ZGL_NULL creates a root node.
ZglNode zgl_layout_add(ZglLayout* layout, ZglNode parent, const ZglStyle* style);

// Remove a node and all its descendants. Freed indices are recycled.
void zgl_layout_remove(ZglLayout* layout, ZglNode node);

// Update a node's style. Marks node dirty for recomputation.
void zgl_layout_set_style(ZglLayout* layout, ZglNode node, const ZglStyle* style);

// Move node to a new parent. Marks both old and new parent dirty.
void zgl_layout_reparent(ZglLayout* layout, ZglNode node, ZglNode new_parent);

// --- Computation ---

// Compute layout for all dirty nodes within given constraints.
// This is the main "work" function - call once per frame.
void zgl_layout_compute(ZglLayout* layout, float available_width, float available_height);

// --- Queries ---

// Get computed rectangle for a node. Returns zero rect if node invalid.
ZglRect zgl_layout_get_rect(const ZglLayout* layout, ZglNode node);

// Get parent of a node. Returns ZGL_NULL for root or invalid node.
ZglNode zgl_layout_get_parent(const ZglLayout* layout, ZglNode node);

// Get first child of a node. Returns ZGL_NULL if no children.
ZglNode zgl_layout_get_first_child(const ZglLayout* layout, ZglNode node);

// Get next sibling. Returns ZGL_NULL if last child.
ZglNode zgl_layout_get_next_sibling(const ZglLayout* layout, ZglNode node);

// --- Statistics ---

// Get number of nodes currently in tree
uint32_t zgl_layout_node_count(const ZglLayout* layout);

// Get number of dirty nodes (will be computed on next zgl_layout_compute)
uint32_t zgl_layout_dirty_count(const ZglLayout* layout);

// Get cache hit rate (0.0 to 1.0) since last reset
float zgl_layout_cache_hit_rate(const ZglLayout* layout);

// Reset statistics counters
void zgl_layout_reset_stats(ZglLayout* layout);
```

**Example usage (pure C, no framework):**

```c
// Create layout engine
ZglLayout* layout = zgl_layout_create(256);

// Build a simple toolbar
ZglStyle toolbar_style = ZGL_STYLE_DEFAULT;
toolbar_style.direction = ZGL_ROW;
toolbar_style.gap = 8.0f;
toolbar_style.padding_left = 16.0f;
toolbar_style.padding_right = 16.0f;
toolbar_style.height = 48.0f;

ZglNode toolbar = zgl_layout_add(layout, ZGL_NULL, &toolbar_style);

ZglStyle button_style = ZGL_STYLE_DEFAULT;
button_style.width = 100.0f;
button_style.height = 32.0f;

ZglNode btn_file = zgl_layout_add(layout, toolbar, &button_style);
ZglNode btn_edit = zgl_layout_add(layout, toolbar, &button_style);
ZglNode btn_view = zgl_layout_add(layout, toolbar, &button_style);

// Compute layout
zgl_layout_compute(layout, 1920.0f, 1080.0f);

// Query results
ZglRect file_rect = zgl_layout_get_rect(layout, btn_file);
printf("File button at (%.0f, %.0f)\n", file_rect.x, file_rect.y);

// Cleanup
zgl_layout_destroy(layout);
```

---

## Layer 2: GUI Context (Immediate-Mode Widgets)

Builds on Layer 1, adds immediate-mode widget API with automatic reconciliation.

```c
// ============================================================================
// GUI Context API (~15 functions)
// ============================================================================

// --- Lifecycle ---

typedef struct {
    uint32_t max_widgets;       // Maximum widgets (default: 4096)
    float viewport_width;       // Initial viewport width
    float viewport_height;      // Initial viewport height
} ZglGuiConfig;

#define ZGL_GUI_CONFIG_DEFAULT ((ZglGuiConfig){ \
    .max_widgets = 4096, \
    .viewport_width = 800.0f, \
    .viewport_height = 600.0f, \
})

ZglGui* zgl_gui_create(const ZglGuiConfig* config);
void zgl_gui_destroy(ZglGui* gui);

// --- Frame Lifecycle ---

// Begin a new frame. Clears "seen" tracking.
void zgl_gui_begin_frame(ZglGui* gui);

// End frame. Removes unseen widgets, computes layout.
void zgl_gui_end_frame(ZglGui* gui);

// Update viewport size (e.g., on window resize)
void zgl_gui_set_viewport(ZglGui* gui, float width, float height);

// --- Widget ID System ---

// Compute widget ID from string (runtime hash)
ZglId zgl_id(const char* label);

// Compute widget ID from string + index (for loops)
ZglId zgl_id_index(const char* label, uint32_t index);

// Combine two IDs (for hierarchical scoping)
ZglId zgl_id_combine(ZglId parent, ZglId child);

// Push ID scope onto stack
void zgl_gui_push_id(ZglGui* gui, ZglId id);

// Pop ID scope from stack
void zgl_gui_pop_id(ZglGui* gui);

// --- Widget Declaration ---

// Declare a widget. Returns true if this is a new widget (first frame).
// Widget ID = current_scope XOR id
bool zgl_gui_widget(ZglGui* gui, ZglId id, const ZglStyle* style);

// Begin a container (pushes onto parent stack)
void zgl_gui_begin(ZglGui* gui, ZglId id, const ZglStyle* style);

// End a container (pops parent stack)
void zgl_gui_end(ZglGui* gui);

// --- Queries ---

// Get computed rect for a widget
ZglRect zgl_gui_get_rect(const ZglGui* gui, ZglId id);

// Check if point is inside widget
bool zgl_gui_hit_test(const ZglGui* gui, ZglId id, float x, float y);

// --- Input State ---

// Update mouse position (call before begin_frame)
void zgl_gui_set_mouse(ZglGui* gui, float x, float y, bool down);

// Check if widget was clicked this frame
bool zgl_gui_clicked(const ZglGui* gui, ZglId id);

// Check if widget is hovered
bool zgl_gui_hovered(const ZglGui* gui, ZglId id);

// Check if widget is being pressed
bool zgl_gui_pressed(const ZglGui* gui, ZglId id);

// --- Direct Layout Access ---

// Get underlying layout engine (for advanced use)
ZglLayout* zgl_gui_get_layout(ZglGui* gui);
```

**Example usage:**

```c
ZglGui* gui = zgl_gui_create(&ZGL_GUI_CONFIG_DEFAULT);

// Main loop
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

    // Content area with dynamic list
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

    // Render using computed rects
    render_widgets(gui);
}

zgl_gui_destroy(gui);
```

---

## Platform-Specific Optimizations

### Zig Native API

Zero-cost comptime hashing, error unions, slices:

```zig
const zgl = @import("zgl");

pub fn main() !void {
    var gui = try zgl.Gui.init(.{});
    defer gui.deinit();

    while (running) {
        gui.beginFrame();
        defer gui.endFrame();

        // Comptime ID hashing - zero runtime cost
        gui.begin("toolbar", .{ .direction = .row, .height = 48, .gap = 8 });
        defer gui.end();

        if (gui.widget("file", .{ .width = 80, .height = 32 }).clicked()) {
            try openFileMenu();
        }

        // Loop with index - still comptime base hash
        for (items, 0..) |item, i| {
            if (gui.widget("item", i, .{ .height = 40 }).clicked()) {
                selectItem(i);
            }
        }
    }
}
```

### WebAssembly

Pre-computed IDs at build time, minimal call overhead:

```typescript
// Build-time: Generate ID constants
const IDS = {
  toolbar: hash("toolbar"),      // Computed at build time
  file: hash("file"),
  edit: hash("edit"),
  content: hash("content"),
};

// Runtime: Just pass u32 IDs
function render() {
  gui.beginFrame();

  gui.begin(IDS.toolbar, TOOLBAR_STYLE);
  gui.widget(IDS.file, BUTTON_STYLE);
  gui.widget(IDS.edit, BUTTON_STYLE);
  gui.end();

  gui.endFrame();
}

// Style constants (avoid per-frame allocation)
const TOOLBAR_STYLE = new Uint8Array([/* pre-serialized ZglStyle */]);
const BUTTON_STYLE = new Uint8Array([/* pre-serialized ZglStyle */]);
```

### Python FFI

Context managers, Pythonic API:

```python
import zgl

gui = zgl.Gui(max_widgets=1024)

while running:
    gui.set_mouse(mouse_x, mouse_y, mouse_down)

    with gui.frame():
        with gui.container("toolbar", direction="row", height=48, gap=8):
            if gui.widget("file", width=80, height=32).clicked:
                open_file_menu()
            if gui.widget("edit", width=80, height=32).clicked:
                open_edit_menu()

        with gui.container("content"):
            for i, item in enumerate(items):
                if gui.widget(f"item_{i}", height=40).clicked:
                    select_item(i)

# Or declarative style with callbacks:
@gui.window("main")
def main_window():
    with gui.toolbar():
        gui.button("File", on_click=open_file_menu)
        gui.button("Edit", on_click=open_edit_menu)

    with gui.list("items"):
        for item in items:
            gui.list_item(item.name, on_click=lambda: select(item))
```

### Embedded (32KB RAM)

Compile-time configuration, no heap in hot path:

```c
// Compile with: -DZGL_MAX_NODES=64 -DZGL_NO_CACHE

// Stack-allocated layout for embedded
ZglLayoutEmbedded layout_storage;
ZglLayout* layout = zgl_layout_init_embedded(&layout_storage);

// All operations use fixed-size arrays, no malloc
ZglNode root = zgl_layout_add(layout, ZGL_NULL, &root_style);
ZglNode btn1 = zgl_layout_add(layout, root, &button_style);
ZglNode btn2 = zgl_layout_add(layout, root, &button_style);

zgl_layout_compute(layout, SCREEN_WIDTH, SCREEN_HEIGHT);

// Render to framebuffer
ZglRect r = zgl_layout_get_rect(layout, btn1);
draw_button(framebuffer, r.x, r.y, r.width, r.height);
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

| Configuration | Max Nodes | Per-Node | Total | Target |
|---------------|-----------|----------|-------|--------|
| Embedded | 64 | 80 B | 5 KB | ESP32 |
| Mobile | 1024 | 180 B | 180 KB | iOS/Android |
| Desktop | 4096 | 200 B | 800 KB | Windows/Mac/Linux |
| Server | 16384 | 200 B | 3.2 MB | Headless rendering |

---

## Error Handling

### C API

```c
// Option 1: Return codes
typedef enum {
    ZGL_OK = 0,
    ZGL_ERROR_OUT_OF_MEMORY = 1,
    ZGL_ERROR_CAPACITY_EXCEEDED = 2,
    ZGL_ERROR_INVALID_NODE = 3,
    ZGL_ERROR_CYCLE_DETECTED = 4,
} ZglError;

// For functions that can fail, use out-parameter:
ZglError zgl_layout_add_checked(ZglLayout* layout, ZglNode parent,
                                 const ZglStyle* style, ZglNode* out_node);

// Or return ZGL_NULL and check zgl_get_last_error():
ZglNode node = zgl_layout_add(layout, parent, style);
if (node == ZGL_NULL) {
    ZglError err = zgl_get_last_error();
    // handle error
}
```

### Zig API

```zig
// Error unions for all fallible operations
pub fn addNode(self: *Layout, parent: ?Node, style: Style) !Node {
    return self.allocateIndex() catch return error.OutOfMemory;
}

// Usage:
const node = try layout.addNode(parent, style);
// or
const node = layout.addNode(parent, style) catch |err| switch (err) {
    error.OutOfMemory => return fallbackNode(),
    error.CapacityExceeded => @panic("too many widgets"),
};
```

---

## Thread Safety

```
┌──────────────────────────────────────────────────────────────────┐
│                     Thread Safety Model                          │
├──────────────────────────────────────────────────────────────────┤
│  SINGLE-THREADED: ZglGui, ZglLayout                             │
│  - All API calls must be from the same thread                    │
│  - beginFrame/endFrame must bracket all widget calls             │
│                                                                  │
│  THREAD-SAFE: zgl_id(), zgl_id_index(), zgl_id_combine()        │
│  - Pure functions, no shared state                               │
│  - Can pre-compute IDs on any thread                             │
│                                                                  │
│  IMMUTABLE: ZglStyle, ZglRect                                   │
│  - Plain data, copy freely between threads                       │
└──────────────────────────────────────────────────────────────────┘
```

---

## ABI Versioning

```c
// In header:
#define ZGL_API_VERSION_MAJOR 1
#define ZGL_API_VERSION_MINOR 0
#define ZGL_API_VERSION ((ZGL_API_VERSION_MAJOR << 16) | ZGL_API_VERSION_MINOR)

// Runtime check:
uint32_t zgl_get_version(void);  // Returns ZGL_API_VERSION

// Struct size check for forward compatibility:
size_t zgl_style_size(void);     // Returns sizeof(ZglStyle)
size_t zgl_rect_size(void);      // Returns sizeof(ZglRect)

// Usage:
assert(zgl_get_version() >= ZGL_API_VERSION);
assert(zgl_style_size() == sizeof(ZglStyle));
```

---

## Summary: API Function Count

| Layer | Functions | Purpose |
|-------|-----------|---------|
| **Layer 0** | 0 | Data structures only |
| **Layer 1** | 12 | Pure layout computation |
| **Layer 2** | 15 | Immediate-mode GUI |
| **Total** | 27 | Complete API |

This minimal surface area means:
- Easier to learn (~30 minutes to understand everything)
- Easier to bind (generate bindings for any language)
- Easier to maintain (fewer edge cases)
- Easier to optimize (clear hot paths)
