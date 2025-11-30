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
    .size = .{ .width = .{ .pixels = 800 }, .height = .{ .pixels = 600 } },
});
const header = try engine.addElement(root, .{
    .size = .{ .height = .{ .pixels = 60 } },
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
engine.setStyle(element_index, .{ .size = .{ .height = .{ .pixels = 100 } } }); // Auto-marks dirty
```

### Performance Monitoring

```zig
const stats = engine.getCacheStats();
// stats.hits, stats.misses, stats.hit_rate

const dirty_count = engine.getDirtyCount();
const total_count = engine.getElementCount();
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

## C API

### Design Principles

1. **Zero-overhead**: Direct mapping to Zig internals
2. **Memory safety**: Clear ownership, no double-frees
3. **Error handling**: Explicit error codes
4. **Thread safety**: Well-defined threading model
5. **ABI stability**: Versioned interface

### Core Types

```c
typedef struct ZigGuiPlatform ZigGuiPlatform;
typedef struct ZigGuiApp ZigGuiApp;
typedef struct ZigGuiPlatformInterface ZigGuiPlatformInterface;

typedef enum {
    ZIG_GUI_OK = 0,
    ZIG_GUI_ERROR_OUT_OF_MEMORY = 1,
    ZIG_GUI_ERROR_PLATFORM = 2,
    ZIG_GUI_ERROR_INVALID_ARGUMENT = 3,
} ZigGuiError;

typedef enum {
    ZIG_GUI_EVENT_DRIVEN = 0,
    ZIG_GUI_GAME_LOOP = 1,
    ZIG_GUI_MINIMAL = 2,
    ZIG_GUI_SERVER_SIDE = 3,
} ZigGuiExecutionMode;
```

### Lifecycle

```c
// Platform first (owns OS resources)
ZigGuiPlatform* platform = zig_gui_sdl_platform_create(800, 600, "My App");
ZigGuiPlatformInterface interface = zig_gui_platform_interface(platform);

// App second (borrows platform)
ZigGuiApp* app = zig_gui_app_create(interface, ZIG_GUI_EVENT_DRIVEN);

// Use...
ZigGuiError err = zig_gui_app_run(app, my_ui_func, user_data);

// Destroy in reverse order
zig_gui_app_destroy(app);
zig_gui_platform_destroy(platform);
```

### UI Functions

```c
typedef void (*ZigGuiUIFunction)(ZigGuiContext* ctx, void* user_data);

void my_ui(ZigGuiContext* ctx, void* user_data) {
    MyState* state = (MyState*)user_data;

    zig_gui_text(ctx, "Counter: %d", state->counter);

    if (zig_gui_button(ctx, "Increment")) {
        state->counter++;
    }
}
```

### ID System

```c
// ID stack - for hierarchical scoping
void zig_gui_push_id(ZigGuiContext* ctx, const char* id);
void zig_gui_push_index(ZigGuiContext* ctx, size_t index);
void zig_gui_pop_id(ZigGuiContext* ctx);

// Debug (debug builds only, no-op in release)
const char* zig_gui_debug_id_path(ZigGuiContext* ctx);
void zig_gui_debug_check_collisions(ZigGuiContext* ctx);
```

### Widgets

```c
// Text
void zig_gui_text(ZigGuiContext* ctx, const char* fmt, ...);

// Buttons - label is used as ID (hashed at runtime)
bool zig_gui_button(ZigGuiContext* ctx, const char* label);

// Buttons with explicit ID (when label differs from ID)
bool zig_gui_button_id(ZigGuiContext* ctx, const char* id, const char* label);

// Input
bool zig_gui_text_input(ZigGuiContext* ctx, const char* label, char* buffer, size_t buffer_size);
bool zig_gui_checkbox(ZigGuiContext* ctx, const char* label, bool* value);
bool zig_gui_slider_float(ZigGuiContext* ctx, const char* label, float* value, float min, float max);

// Layout containers
void zig_gui_push_row(ZigGuiContext* ctx, const ZigGuiLayoutOptions* options);
void zig_gui_push_column(ZigGuiContext* ctx, const ZigGuiLayoutOptions* options);
void zig_gui_pop_layout(ZigGuiContext* ctx);
```

### C Usage Example

```c
void settings_panel(ZigGuiContext* ctx, SettingsState* state) {
    zig_gui_push_id(ctx, "settings");

    zig_gui_text(ctx, "Settings");

    if (zig_gui_button(ctx, "Save")) {
        save_settings(state);
    }

    // Same label, different IDs
    zig_gui_button_id(ctx, "reset_audio", "Reset");
    zig_gui_button_id(ctx, "reset_video", "Reset");

    // Loop with index-based IDs
    for (size_t i = 0; i < state->item_count; i++) {
        zig_gui_push_index(ctx, i);

        zig_gui_text(ctx, state->items[i].name);
        if (zig_gui_button(ctx, "Delete")) {
            delete_item(state, i);
        }

        zig_gui_pop_id(ctx);
    }

    zig_gui_pop_id(ctx);
}
```

### State Management

```c
// Type-safe accessors
void zig_gui_state_set_int(ZigGuiState* state, const char* key, int32_t value);
int32_t zig_gui_state_get_int(ZigGuiState* state, const char* key, int32_t default_value);

void zig_gui_state_set_float(ZigGuiState* state, const char* key, float value);
float zig_gui_state_get_float(ZigGuiState* state, const char* key, float default_value);

void zig_gui_state_set_string(ZigGuiState* state, const char* key, const char* value);
const char* zig_gui_state_get_string(ZigGuiState* state, const char* key, const char* default_value);
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
