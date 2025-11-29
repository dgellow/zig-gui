# The Ultimate Cross-Platform GUI Library Specification

**zig-gui**: The first UI library that solves the fundamental tradeoffs of GUI development.

## 🎯 The Revolutionary Vision

zig-gui is the **first GUI library** to solve the impossible trinity of UI development:

1. **⚡ Performance**: 0% CPU when idle, 120+ FPS when needed
2. **🎨 Developer Experience**: Immediate-mode simplicity with hot reload
3. **🌍 Universality**: Same code from microcontrollers to AAA games

**We achieve this through a breakthrough hybrid architecture that combines:**
- **Event-driven execution** (no wasted CPU cycles)
- **Immediate-mode developer experience** (simple, predictable)
- **Data-oriented foundations** (cache-friendly, SIMD-ready)
- **Smart invalidation** (only redraw what changed)

## 🏗️ Core Architecture

### The Hybrid Engine

```zig
// Same API, different execution strategies
// State uses Tracked Signals for efficient change detection
const AppState = struct {
    counter: Tracked(i32) = .{ .value = 0 },
};

pub fn MyApp(gui: *GUI, state: *AppState) !void {
    try gui.window("My App", .{}, struct {
        fn content(g: *GUI, s: *AppState) !void {
            try g.text("Counter: {}", .{s.counter.get()});

            if (try g.button("Increment")) {
                s.counter.set(s.counter.get() + 1); // O(1), triggers redraw via version change
            }
        }
    }.content);
}

// App(State) is generic over state type for type-safe UI functions
// Desktop email client: Event-driven (0% idle CPU)
var desktop_app = try App(AppState).init(allocator, .{ .mode = .event_driven });
try desktop_app.run(MyApp, &state);

// Game UI: Continuous loop (60+ FPS)
var game_app = try App(AppState).init(allocator, .{ .mode = .game_loop });
try game_app.run(MyApp, &state);

// Embedded device: Ultra-low power
var embedded_app = try App(AppState).init(allocator, .{ .mode = .minimal });
try embedded_app.run(MyApp, &state);
```

### Foundation: Data-Oriented zlay

At the core lies **zlay** - our data-oriented layout engine:

```zig
// zlay handles layout with data-oriented design
// - Elements stored in contiguous arrays (cache-friendly)
// - SIMD-optimized calculations where possible
// - Minimal memory allocations
// - Predictable performance characteristics

const LayoutEngine = struct {
    elements: []Element,        // Structure of Arrays
    positions: []Point,         // Parallel arrays for cache efficiency
    sizes: []Size,
    styles: []Style,
    
    pub fn computeLayout(self: *LayoutEngine) void {
        // Vectorized layout calculations
        // O(n) complexity, cache-friendly access patterns
    }
};
```

## 🚀 Performance Characteristics

### Desktop Applications (Event-Driven Mode)
- **Idle CPU usage**: 0% (blocks on events)
- **Memory usage**: < 1MB for typical apps
- **Startup time**: < 50ms
- **Event response**: < 5ms latency
- **Redraw performance**: Only changed regions

### Game Applications (Game Loop Mode)
- **Frame rate**: 60-240+ FPS consistently
- **Frame time**: < 8ms (120 FPS target)
- **Memory allocations**: Zero per frame
- **UI overhead**: < 5% of frame budget

### Embedded Systems (Minimal Mode)
- **Memory footprint**: < 32KB RAM
- **Flash usage**: < 128KB
- **Update time**: < 1ms per interaction
- **Power consumption**: Minimal (event-driven wake)

## 🌟 Developer Experience

### Immediate-Mode Simplicity

```zig
fn TodoApp(gui: *GUI, state: *TodoState) !void {
    try gui.container(.{ .padding = 20 }, struct {
        fn render(g: *GUI, s: *TodoState) !void {
            // Add new todo
            if (try g.button("Add Todo")) {
                try s.addTodo("New task");
            }
            
            // List existing todos
            for (s.todos, 0..) |todo, i| {
                try g.row(.{}, struct {
                    fn todo_row(gg: *GUI, ss: *TodoState, index: usize, item: Todo) !void {
                        if (try gg.checkbox(item.completed)) {
                            ss.todos[index].completed = !item.completed;
                        }
                        
                        try gg.text("{s}", .{item.text});
                        
                        if (try gg.button("Delete")) {
                            try ss.removeTodo(index);
                        }
                    }
                }.todo_row, s, i, todo);
            }
        }
    }.render);
}
```

### Hot Reload Magic

```zig
// Development mode: Instant feedback
// App(MyState) is generic over your state type
var app = try App(MyState).init(allocator, .{
    .mode = .event_driven,
    .hot_reload = true,
});

// Change any file -> See results in < 100ms
// - Style changes: Instant visual update
// - Logic changes: Hot-swapped functions
// - Asset changes: Automatic reload
```

## 🌍 Universal Platform Support

### Execution Modes

```zig
pub const ExecutionMode = enum {
    event_driven,    // Desktop apps: 0% idle CPU
    game_loop,       // Games: Continuous 60+ FPS
    minimal,         // Embedded: Ultra-low resource usage
    server_side,     // Headless: Generate UI for web/mobile
};

pub const PlatformBackend = enum {
    software,        // Pure software rendering
    opengl,          // Hardware-accelerated desktop
    vulkan,          // High-performance graphics
    direct2d,        // Windows native
    metal,           // macOS/iOS native
    framebuffer,     // Linux framebuffer (embedded)
    custom,          // Bring your own renderer
};
```

### Platform Integration Examples

```zig
// Desktop (Windows/macOS/Linux)
var desktop = try Platform.desktop(.{
    .backend = .opengl,
    .window = .{ .width = 1200, .height = 800, .title = "My App" },
});

// Mobile (iOS/Android via C API)
var mobile = try Platform.mobile(.{
    .backend = .metal, // or .vulkan for Android
    .orientation = .portrait,
});

// Embedded (Teensy, ESP32, etc.)
var embedded = try Platform.embedded(.{
    .backend = .framebuffer,
    .display = .{ .width = 320, .height = 240, .spi_config = spi_cfg },
});

// Web (via WebAssembly + C API)
var web = try Platform.web(.{
    .backend = .canvas,
    .container_id = "app-root",
});

// Game Engine (Unity, Unreal, Godot via C API)
var game_engine = try Platform.plugin(.{
    .backend = .custom,
    .renderer = game_engine_renderer,
});
```

## 🔌 World-Class C API

### Design Principles

1. **Zero-overhead abstractions**: Direct mapping to Zig internals
2. **Memory safety**: Clear ownership and lifetime management
3. **Error handling**: Explicit error codes, no exceptions
4. **Thread safety**: Well-defined threading model
5. **ABI stability**: Versioned interface, backward compatibility

### C API Preview

```c
#include "zig_gui.h"

// Simple, clean initialization
ZigGuiApp* app = zig_gui_app_create(ZIG_GUI_EVENT_DRIVEN);
ZigGuiState* state = zig_gui_state_create();

// Type-safe state management
zig_gui_state_set_int(state, "counter", 0);

// Main application loop
while (zig_gui_app_is_running(app)) {
    // Event-driven: This blocks until events occur (0% CPU idle)
    ZigGuiEvent event = zig_gui_app_wait_event(app);
    
    // Handle events
    if (event.type == ZIG_GUI_EVENT_REDRAW_NEEDED) {
        // Begin UI definition
        zig_gui_begin_frame(app);
        
        // Simple, immediate-mode API
        zig_gui_window_begin(app, "My App", NULL);
        
        int counter = zig_gui_state_get_int(state, "counter");
        zig_gui_text_formatted(app, "Counter: %d", counter);
        
        if (zig_gui_button(app, "Increment")) {
            zig_gui_state_set_int(state, "counter", counter + 1);
        }
        
        zig_gui_window_end(app);
        
        // End frame - renders only if needed
        zig_gui_end_frame(app);
    }
}

// Clean shutdown
zig_gui_state_destroy(state);
zig_gui_app_destroy(app);
```

### Language Bindings

The C API is designed to be trivially wrapped in any language:

```python
# Python binding example
import zig_gui

app = zig_gui.App(mode=zig_gui.EventDriven)
state = zig_gui.State()

@app.ui
def main_window(gui, state):
    gui.text(f"Counter: {state.counter}")
    if gui.button("Increment"):
        state.counter += 1

app.run()
```

```javascript
// JavaScript/Node.js binding example
const { App, State } = require('zig-gui');

const app = new App({ mode: 'event_driven' });
const state = new State();

app.ui((gui, state) => {
    gui.text(`Counter: ${state.counter}`);
    if (gui.button('Increment')) {
        state.counter++;
    }
});

app.run();
```

```go
// Go binding example
package main

import "github.com/zig-gui/go-bindings"

func main() {
    app := ziggui.NewApp(ziggui.EventDriven)
    state := ziggui.NewState()
    
    app.UI(func(gui *ziggui.GUI, state *ziggui.State) {
        gui.Text("Counter: %d", state.GetInt("counter"))
        if gui.Button("Increment") {
            state.SetInt("counter", state.GetInt("counter") + 1)
        }
    })
    
    app.Run()
}
```

## 🎯 State Management: Tracked Signals

### The Design Decision

After extensive analysis of React, Flutter, SwiftUI, SolidJS, Svelte, ImGui, and Qt, we chose **Tracked Signals** - a pattern inspired by SolidJS's fine-grained reactivity and Svelte 5's runes.

### Why Tracked Signals?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     STATE MANAGEMENT COMPARISON                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│ Framework        │ Memory/Field │ Write Cost │ Change Detection │ Embedded │
│ ─────────────────┼──────────────┼────────────┼──────────────────┼──────────│
│ React (VDOM)     │ ~100 bytes   │ O(1)+sched │ O(n) tree diff   │ No       │
│ Flutter          │ ~80 bytes    │ O(1)+sched │ O(n) tree diff   │ No       │
│ SwiftUI          │ ~50 bytes    │ O(1)+sched │ O(n) diff        │ Limited  │
│ ImGui            │ 0 bytes      │ O(1)       │ N/A (redraws all)│ Yes*     │
│ Qt (Signals)     │ ~40 bytes    │ O(k) emit  │ O(k) slots       │ No       │
│ ─────────────────┼──────────────┼────────────┼──────────────────┼──────────│
│ zig-gui (Tracked)│ 4 bytes      │ O(1)       │ O(N) field count │ Yes      │
│                                                                             │
│ * ImGui works on embedded but burns CPU constantly                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The Tracked(T) Type

```zig
/// 4 bytes overhead per field - version counter for change detection
pub fn Tracked(comptime T: type) type {
    return struct {
        value: T,
        _v: u32 = 0,  // Version counter

        pub inline fn get(self: *const @This()) T {
            return self.value;
        }

        pub inline fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            self._v +%= 1;  // Increment version
        }

        pub inline fn ptr(self: *Self) *T {
            self._v +%= 1;  // Assume mutation
            return &self.value;
        }
    };
}
```

### Usage Example

```zig
const AppState = struct {
    // Tracked fields - framework knows when they change
    counter: Tracked(i32) = .{ .value = 0 },
    name: Tracked([]const u8) = .{ .value = "World" },
    todos: Tracked(std.BoundedArray(Todo, 100)) = .{ .value = .{} },
};

fn myApp(gui: *GUI, state: *AppState) !void {
    // Read with .get()
    try gui.text("Hello, {s}!", .{state.name.get()});
    try gui.text("Counter: {}", .{state.counter.get()});

    // Write with .set() - O(1), zero allocations
    if (try gui.button("Increment")) {
        state.counter.set(state.counter.get() + 1);
    }

    // Mutate collections with .ptr()
    if (try gui.button("Add Todo")) {
        state.todos.ptr().append(.{ .text = "New task" }) catch {};
    }
}
```

### How It Enables Hybrid Execution

The Tracked system is the **bridge** between immediate-mode API and retained-mode optimization:

```zig
// Event-Driven Mode: Framework checks version sum before rendering
fn runEventDriven(app: *App, ui_fn: anytype, state: anytype) !void {
    var last_version: u64 = 0;

    while (app.isRunning()) {
        const event = try app.waitForEvent();  // BLOCK - 0% CPU
        try app.handleEvent(event, state);

        // O(N) where N = field count, NOT data size
        if (stateChanged(state, &last_version)) {
            try app.render(ui_fn, state);
        }
    }
}

// Game Loop Mode: Always render, but framework can diff internally
fn runGameLoop(app: *App, ui_fn: anytype, state: anytype) !void {
    while (app.isRunning()) {
        while (app.pollEvent()) |event| {
            try app.handleEvent(event, state);
        }
        try app.render(ui_fn, state);  // Internal diffing for batching
    }
}

// Minimal Mode: Track per-field changes for partial updates
fn runMinimal(app: *App, ui_fn: anytype, state: anytype) !void {
    var field_versions: [MAX_FIELDS]u32 = undefined;

    while (app.isRunning()) {
        const event = try app.waitForEventLowPower();  // Deep sleep
        try app.handleEvent(event, state);

        const changed = findChangedFields(state, &field_versions);
        if (changed.len > 0) {
            try app.renderPartial(ui_fn, state, changed);  // Only changed regions
        }
    }
}
```

### Real-World Performance

**Email Client (Desktop, Event-Driven):**
```
Click to select email:
  React:    setState() → schedule → reconcile → diff 50 items → patch  = ~2ms
  Flutter:  setState() → schedule → build → diff tree → render         = ~1.5ms
  zig-gui:  .set() → version++ → O(5) check → render if changed        = ~0.1ms

Idle state:
  React:    2-5% CPU (timers, observers, GC)
  Flutter:  3-8% CPU (engine overhead)
  zig-gui:  0% CPU (blocked on waitForEvent)
```

**Game HUD (60 FPS):**
```
Per-frame state update (health, mana, score):
  React:    Not suitable (too slow)
  ImGui:    O(1) write, but redraws everything = 15-25% CPU
  zig-gui:  O(1) write, O(6) version check = 0.01% of frame budget

Memory overhead (10 state fields):
  React:    ~1,000 bytes
  ImGui:    ~0 bytes (no tracking)
  zig-gui:  ~40 bytes (10 × 4 byte versions)
```

**Embedded (32KB RAM):**
```
State overhead:
  React-style:  ~1,500 bytes (HashMaps, callbacks, allocations) = 18% of budget
  zig-gui:      ~40 bytes (version counters only) = 0.5% of budget
```

### Future: Comptime Reactive (Option E)

Current design allows seamless optimization without breaking user code:

```zig
// Phase 1 (Current): Tracked(T) wrapper
const AppState = struct {
    counter: Tracked(i32) = .{},
};
state.counter.get() / state.counter.set(v)

// Phase 2: Add Reactive() wrapper for O(1) global check
const WrappedState = Reactive(AppState);  // Wraps Tracked-based struct
if (wrapped.changed(&last)) { ... }  // O(1) instead of O(N)

// Phase 3 (Optional): Migrate to plain structs with comptime methods
const AppState = struct { counter: i32 = 0 };  // No wrapper!
const State = Reactive(AppState);
state.counter()       // comptime-generated getter
state.setCounter(v)   // comptime-generated setter
```

**Migration is non-breaking** - users don't have to change code.

See [STATE_MANAGEMENT.md](STATE_MANAGEMENT.md) for complete design analysis.

---

## 🎮 Use Case Excellence

### Email Client
```zig
fn EmailClient(gui: *GUI, state: *EmailState) !void {
    try gui.horizontalSplit(.{ .ratio = 0.3 }, .{
        // Sidebar: Folders and accounts
        .left = struct {
            fn sidebar(g: *GUI, s: *EmailState) !void {
                for (s.folders) |folder| {
                    if (try g.sidebarItem(folder.name, folder.unread_count)) {
                        s.selected_folder = folder;
                    }
                }
            }
        }.sidebar,
        
        // Main area: Email list and preview
        .right = struct {
            fn main_area(g: *GUI, s: *EmailState) !void {
                try g.verticalSplit(.{ .ratio = 0.4 }, .{
                    .top = EmailList,
                    .bottom = EmailPreview,
                });
            }
        }.main_area,
    });
}

// Performance: 0% CPU when idle, instant response to clicks
```

### Game HUD
```zig
fn GameHUD(gui: *GUI, state: *GameState) !void {
    // Top bar: Health, mana, score
    try gui.topBar(.{}, struct {
        fn top_bar(g: *GUI, s: *GameState) !void {
            try g.healthBar(s.player.health, s.player.max_health);
            try g.manaBar(s.player.mana, s.player.max_mana);
            try g.text("Score: {}", .{s.score});
        }
    }.top_bar);
    
    // Minimap
    try gui.minimap(state.world.map, state.player.position);
    
    // Inventory (only when open)
    if (state.inventory_open) {
        try gui.inventory(state.player.items);
    }
}

// Performance: 120+ FPS, < 5% frame budget
```

### Embedded Control Panel
```zig
fn ControlPanel(gui: *GUI, state: *DeviceState) !void {
    try gui.grid(.{ .cols = 2, .rows = 3 }, .{
        try gui.statusLight("Power", state.power_on),
        try gui.statusLight("Network", state.network_connected),
        
        try gui.slider("Volume", &state.volume, .{ .min = 0, .max = 100 }),
        try gui.slider("Brightness", &state.brightness, .{ .min = 0, .max = 255 }),
        
        if (try gui.button("Reset")) {
            state.requestReset();
        },
        try gui.text("Uptime: {}s", .{state.uptime}),
    });
}

// Performance: < 32KB RAM, < 1ms response time
```

## 🔥 Competitive Advantages

### vs React/Flutter
- **Startup**: 50ms vs 2-5 seconds
- **Memory**: 1MB vs 50-200MB
- **CPU idle**: 0% vs 2-5%
- **Binary size**: 2MB vs 50-200MB

### vs ImGui/CEGUI
- **CPU efficiency**: Event-driven vs continuous redraw
- **Cross-platform**: Embedded to desktop vs desktop-only
- **Language support**: C API vs C++ only

### vs Native (Qt/GTK/Cocoa)
- **Complexity**: Functions vs object hierarchies
- **Performance**: Direct rendering vs layered abstractions
- **Portability**: One codebase vs platform-specific

### vs Game Engines (Unity/Unreal UI)
- **Lightweight**: 2MB vs 2GB+ engines
- **Performance**: 120+ FPS vs 30-60 FPS UI
- **Flexibility**: Any renderer vs engine-locked

## 📈 Development Roadmap

### Phase 1: Core Foundation (Weeks 1-4)
**Goal**: Prove the hybrid architecture works

- [ ] Event-driven execution engine
- [ ] zlay integration for layout
- [ ] Basic immediate-mode API
- [ ] Simple platform backends (SDL, software)
- [ ] Proof-of-concept: Desktop app with 0% idle CPU

**Milestone**: Todo app that uses no CPU when idle

### Phase 2: Developer Experience (Weeks 5-8)
**Goal**: Make it a joy to develop with

- [ ] Hot reload system
- [ ] Rich component library
- [ ] Style system with live editing
- [ ] Developer tools (inspector, profiler)
- [ ] Documentation and examples

**Milestone**: Complex email client with hot reload

### Phase 3: Platform Excellence (Weeks 9-12)
**Goal**: Universal platform support

- [ ] OpenGL/Vulkan/Metal backends
- [ ] Mobile platform support
- [ ] Embedded platform optimizations
- [ ] Web assembly target
- [ ] Game engine plugins

**Milestone**: Same app running on desktop, mobile, and Teensy

### Phase 4: Production Polish (Weeks 13-16)
**Goal**: Ready for production use

- [ ] Performance optimizations
- [ ] Memory usage optimizations
- [ ] Comprehensive testing
- [ ] ABI-stable C API
- [ ] Language bindings (Python, Go, JS, Rust)

**Milestone**: Shipping applications in production

### Phase 5: Advanced Features (Weeks 17-20)
**Goal**: Advanced capabilities

- [ ] Animation system
- [ ] Accessibility support
- [ ] Advanced graphics (gradients, shadows, effects)
- [ ] Data visualization components
- [ ] Audio/video integration

**Milestone**: Feature-complete UI library

## 🎯 Success Metrics

### Performance Targets
- **Desktop idle CPU**: 0.0%
- **Game UI frame time**: < 4ms (250 FPS capable)
- **Memory usage**: < 1MB for typical apps
- **Startup time**: < 50ms
- **Hot reload time**: < 100ms

### Developer Experience Targets
- **Learning curve**: Productive in < 1 hour
- **API surface**: < 50 core functions
- **Documentation**: 100% coverage
- **Examples**: 20+ real-world examples
- **Community**: 1000+ GitHub stars in first year

### Platform Targets
- **Desktop**: Windows, macOS, Linux
- **Mobile**: iOS, Android (via C API)
- **Embedded**: Teensy, ESP32, STM32, Raspberry Pi
- **Web**: WebAssembly + Canvas
- **Game Engines**: Unity, Unreal, Godot plugins

## 🌟 The Ultimate Vision

**zig-gui will be the first UI library that developers actually LOVE to use.**

- **Systems programmers** will finally have a GUI option that doesn't make them cry
- **Game developers** will get better performance than Unity's UI system
- **App developers** will get native performance with web-like development experience
- **Embedded developers** will build rich interfaces that actually fit in memory
- **Language ecosystems** will adopt it because the C API is so clean

**We're not just building a UI library - we're solving the fundamental problems that have plagued GUI development for decades.**

The future of UI development is:
- ⚡ **Fast** (0% idle CPU, 120+ FPS when needed)
- 🎨 **Simple** (immediate-mode DX, hot reload)
- 🌍 **Universal** (embedded to desktop, any language)
- 💎 **Beautiful** (great defaults, easy customization)
- 🚀 **Reliable** (Zig safety, predictable performance)

**Let's build it.**